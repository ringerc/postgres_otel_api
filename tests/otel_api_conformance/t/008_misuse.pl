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
		my ($ret, $stdout, $stderr) = $node->psql('postgres', $sql);
		is($ret, 0, "$desc: completes without crashing (non-cassert build)") or diag($stderr);
		if (defined $counter_key)
		{
			my $c = counters();
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
	'start_in_crit_section');

check_misuse('.scoped span whose frame returned',
	'SELECT otel_api_conformance_misuse_scoped_leak()',
	undef);

check_misuse('foreign/bogus handle',
	'SELECT otel_api_conformance_misuse_foreign_handle()',
	'stale_handle');

$node->stop;
done_testing();
