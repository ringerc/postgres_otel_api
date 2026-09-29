# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Misuse, each caught in cassert builds: a stale handle (use after end,
# double end); ending a span that isn't top of stack; calling the API
# in a critical section; a .scoped span whose frame returned; a span
# open at commit.  otel_api P2 design, "Conformance test suite" >
# "Misuse".
#
# In cassert builds each of the first four crashes the backend with an
# Assert; this file expects that and checks the log.  In non-cassert
# builds these are no-ops plus a counter, so the file instead checks
# the counters.  "span open at commit" is a WARNING in every build
# (see 004_ownership.pl); it is exercised there, not here, since the
# P2 design's "Ownership" section documents it as a WARNING+counter in
# all builds, not a cassert-only Assert -- see the final report for
# this apparent tension between that section and the "Misuse" list.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use JSON::PP;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'otel_api,otel_api_conformance'\n"
	  # Misuse Asserts crash the backend in cassert builds; the test
	  # waits for crash recovery and carries on.
	  . "restart_after_crash = on\n");
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_api_conformance');

my $cassert = $node->safe_psql('postgres', 'SHOW debug_assertions');
note("debug_assertions = $cassert");

sub counters
{
	my $out = $node->safe_psql('postgres', 'SELECT otel_api_conformance_counters()');
	return decode_json($out);
}

# After an expected crash, the postmaster terminates every other
# backend and reinitializes shared memory before it will accept new
# connections again.  Rather than scan the log for a specific message
# (fragile: offset bookkeeping across repeated crashes, timing between
# the crash and the postmaster beginning recovery), just retry a
# trivial query until it succeeds or a deadline passes.  This is the
# standard, robust way to wait out an intentional backend crash.
sub wait_for_restart
{
	my $deadline = time() + $PostgreSQL::Test::Utils::timeout_default;
	while (time() < $deadline)
	{
		# During the brief window right after the crash, the postmaster
		# may not yet be listening at all: psql() itself can die (e.g.
		# "ack Broken pipe" from IPC::Run) rather than return a nonzero
		# status.  Treat that the same as "not up yet".
		my $ok = eval {
			my ($ret, $stdout, $stderr) =
				$node->psql('postgres', 'SELECT 1', on_error_stop => 0);
			return $ret == 0;
		};
		return 1 if $ok;
		# A short, bounded wait between retries; not a long leading sleep.
		select(undef, undef, undef, 0.2);
	}
	return 0;
}

# Runs $sql (a SELECT of a conformance_misuse_* function) and checks
# either that the backend crashed with an Assert (cassert builds) or
# that it completed and the given counter increased (other builds).
sub check_misuse
{
	my ($desc, $sql, $counter_key) = @_;

	if ($cassert eq 'on')
	{
		my $log_start = -s $node->logfile;
		my ($ret, $stdout, $stderr) = $node->psql('postgres', $sql);
		isnt($ret, 0, "$desc: connection lost (cassert build should Assert)");
		my $log_contents = PostgreSQL::Test::Utils::slurp_file($node->logfile, $log_start);
		like($log_contents, qr/TRAP:|Assert/,
			"$desc: server log shows an Assert failure");
		ok(wait_for_restart(), "$desc: server accepts connections again after the crash")
			or BAIL_OUT("server did not come back up after the induced crash");
	}
	else
	{
		# otel_api_conformance's counters are backend-local (see
		# t/001_construction.pl's header comment): the counter read-back
		# must be part of the SAME psql invocation/connection that ran
		# $sql, not a separate counters() call (which would open a new,
		# fresh backend reporting all-zero counters).
		my ($ret, $stdout, $stderr) = $node->psql('postgres',
			"$sql;\nSELECT otel_api_conformance_counters();");
		is($ret, 0, "$desc: completes without crashing (non-cassert build)") or diag($stderr);
		if (defined $counter_key)
		{
			my $c = decode_json($stdout);
			cmp_ok($c->{$counter_key}, '>=', 1, "$desc: $counter_key counter increased");
		}
	}
}

check_misuse('use-after-end',
	'SELECT otel_api_conformance_misuse_use_after_end()',
	'stale_handle');

check_misuse('double-end',
	'SELECT otel_api_conformance_misuse_double_end()',
	'stale_handle');

check_misuse('non-LIFO end',
	'SELECT otel_api_conformance_misuse_non_lifo()',
	'non_lifo_end');

check_misuse('call in a critical section',
	'SELECT otel_api_conformance_misuse_critical_section()',
	'in_crit_section');

# Every other producer call, made inside a critical section on a span
# opened before it.  The span must come out unchanged and still usable.
my @crit_ops = qw(end discard set_str set_int set_double set_bool set_printf
  set_name set_status add_event add_link record_error capture_error
  current context_of resource_add);
for my $op (@crit_ops)
{
	check_misuse("$op in a critical section",
		"SELECT otel_api_conformance_misuse_crit_section_op('$op')",
		'in_crit_section');

	next if $cassert eq 'on';

	my $out = $node->safe_psql('postgres', <<SQL);
SELECT otel_api_conformance_reset() AS r \\gset
SELECT otel_api_conformance_misuse_crit_section_op('$op') AS r2 \\gset
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' LIKE 'conformance.misuse.crit_op%';
SELECT otel_api_conformance_counters();
SQL
	my @lines = split /\n/, $out;
	my @spans = @{ decode_json($lines[0] || "[]") };
	my $c = decode_json($lines[1]);
	is($c->{in_crit_section}, 1, "$op in a critical section: counted once");
	is(scalar(@spans), 1, "$op in a critical section: the span is exported once, after the critical section");
	my $sp = $spans[0] or next;
	is($sp->{name}, 'conformance.misuse.crit_op', "$op in a critical section: name unchanged");
	is($sp->{status}, 0, "$op in a critical section: status unchanged");
	is(scalar(@{ $sp->{events} }), 0, "$op in a critical section: no event added");
	is(scalar(@{ $sp->{links} }), 0, "$op in a critical section: no link added");
	ok(!(grep { $_->{key} eq 'conformance.crit' } @{ $sp->{attrs} }),
		"$op in a critical section: no attribute added");
	ok((grep { $_->{key} eq 'conformance.after_crit' } @{ $sp->{attrs} }),
		"$op in a critical section: the span is usable after the critical section");
}

check_misuse('.scoped span whose frame returned',
	'SELECT otel_api_conformance_misuse_scoped_leak()',
	undef);

check_misuse('foreign/bogus handle',
	'SELECT otel_api_conformance_misuse_foreign_handle()',
	'stale_handle');

$node->stop;
done_testing();
