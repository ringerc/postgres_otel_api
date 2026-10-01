# Copyright (c) 2026, PostgreSQL Global Development Group
#
# otel_span_activate()/otel_span_deactivate(): scoped activation of a
# .detached span (postgres-cdq.10). Covers: activating a non-.detached
# span; a span already active; deactivating with a stale or wrong
# token; deactivating twice; ending a span while it is still
# activated; an activation with spans pushed above it since
# (LIFO-checked exactly like otel_span_end()); OTEL_SPAN_NONE; and
# activating an unsampled (negative-handle) span.
#
# In cassert builds, each misuse (activating a non-.detached span, an
# already-active span, a stale/wrong deactivate token, or a double
# deactivate) crashes the backend with an Assert; this file expects
# that and checks the log, same as t/008_misuse.pl. Non-cassert builds
# are refused as a counted no-op instead.

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
	  . "restart_after_crash = on\n");
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_api_conformance');

my $cassert = $node->safe_psql('postgres', 'SHOW debug_assertions');
note("debug_assertions = $cassert");

# See t/008_misuse.pl for the rationale (retry until the postmaster is
# accepting connections again, rather than scanning the log for timing).
sub wait_for_restart
{
	my $deadline = time() + $PostgreSQL::Test::Utils::timeout_default;
	while (time() < $deadline)
	{
		my $ok = eval {
			my ($ret, $stdout, $stderr) =
			  $node->psql('postgres', 'SELECT 1', on_error_stop => 0);
			return $ret == 0;
		};
		return 1 if $ok;
		select(undef, undef, undef, 0.2);
	}
	return 0;
}

# Runs $sql (ending in a SELECT of the counters, for non-cassert
# builds) and checks either that the backend crashed with an Assert
# (cassert builds) or that it completed and the given counter
# increased (other builds). Mirrors t/008_misuse.pl's check_misuse().
sub check_misuse
{
	my ($desc, $sql, $counter_key) = @_;

	if ($cassert eq 'on')
	{
		my $log_start = -s $node->logfile;
		my ($ret, $stdout, $stderr) = $node->psql('postgres', $sql);
		isnt($ret, 0, "$desc: connection lost (cassert build should Assert)");
		my $log_contents =
		  PostgreSQL::Test::Utils::slurp_file($node->logfile, $log_start);
		like($log_contents, qr/TRAP:|Assert/,
			"$desc: server log shows an Assert failure");
		ok(wait_for_restart(),
			"$desc: server accepts connections again after the crash")
		  or BAIL_OUT("server did not come back up after the induced crash");
	}
	else
	{
		my ($ret, $stdout, $stderr) = $node->psql('postgres',
			"$sql;\nSELECT otel_api_conformance_counters();");
		is($ret, 0, "$desc: completes without crashing (non-cassert build)")
		  or diag($stderr);
		if (defined $counter_key)
		{
			my $c = decode_json($stdout);
			cmp_ok($c->{$counter_key}, '>=', 1,
				"$desc: $counter_key counter increased");
		}
	}
}

# ----------------------------------------------------------------
# Well-behaved use: activate makes the span current; deactivate pops
# it again, restoring what was current before.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_start('conformance.activate.detached', owner_mode := 'session', detached := true) AS s \gset
SELECT otel_api_conformance_span_current() = 0 AS none_current_before;
SELECT otel_api_conformance_activate(:s) AS tok \gset
SELECT :tok <> 0 AS token_nonzero;
SELECT otel_api_conformance_span_current() = :s AS span_is_current;
SELECT otel_api_conformance_deactivate(:tok);
SELECT otel_api_conformance_span_current() = 0 AS none_current_after;
SELECT otel_api_conformance_end(:s);
SQL
	my @lines = grep { length } split /\n/, $out;
	is($lines[0], 't', 'nothing current before activation');
	is($lines[1], 't', 'otel_span_activate() returns a nonzero token');
	is($lines[2], 't', 'the detached span is current while activated');
	is($lines[3], 't', 'nothing current after deactivation');
}

# ----------------------------------------------------------------
# A child started while the detached span is active parents to it
# (OTEL_PARENT_ACTIVE, the default).
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_start('conformance.activate.parent', owner_mode := 'session', detached := true) AS s \gset
SELECT otel_api_conformance_activate(:s) AS tok \gset
SELECT otel_api_conformance_start('conformance.activate.child', owner_mode := 'session') AS child \gset
SELECT otel_api_conformance_end(:child);
SELECT otel_api_conformance_deactivate(:tok);
SELECT otel_api_conformance_end(:s);
SELECT otel_api_conformance_spans();
SQL
	like($out, qr/"name":\s*"conformance\.activate\.child".*"parent_span_id"/s,
		'child span recorded');
}

# ----------------------------------------------------------------
# Misuse: activating a non-.detached span (it is already on the
# active stack from otel_span_start()).
# ----------------------------------------------------------------
check_misuse(
	'activate a non-.detached span',
	q{SELECT otel_api_conformance_start('conformance.activate.misuse.not_detached', owner_mode := 'session') AS s \gset
SELECT otel_api_conformance_activate(:s);
SELECT otel_api_conformance_end(:s);},
	'activate_not_detached');

# ----------------------------------------------------------------
# Misuse: activating a span that is already active.
# ----------------------------------------------------------------
check_misuse(
	'activate an already-active span',
	q{SELECT otel_api_conformance_start('conformance.activate.misuse.already_active', owner_mode := 'session', detached := true) AS s \gset
SELECT otel_api_conformance_activate(:s) AS tok \gset
SELECT otel_api_conformance_activate(:s);
SELECT otel_api_conformance_deactivate(:tok);
SELECT otel_api_conformance_end(:s);},
	'activate_already_active');

# ----------------------------------------------------------------
# Ending a span while it is still activated pops it off the active
# stack exactly like any other stack entry -- this is NOT misuse, and
# must not bump any misuse counter.  The activation token is then
# stale (the span is gone), same as using any handle after
# otel_span_end() elsewhere.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_start('conformance.activate.end_while_active', owner_mode := 'session', detached := true) AS s \gset
SELECT otel_api_conformance_activate(:s) AS tok \gset
SELECT otel_api_conformance_span_current() = :s AS span_is_current;
SELECT otel_api_conformance_end(:s);
SELECT otel_api_conformance_span_current() = 0 AS none_current_after_end;
SELECT otel_api_conformance_counters();
SQL
	my @lines = grep { length } split /\n/, $out;
	is($lines[0], 't', 'span is current before ending it');
	is($lines[1], 't',
		'ending an activated span pops it cleanly (nothing current after)');
	my $c = decode_json($lines[2]);
	is($c->{non_lifo_end}, 0,
		'ending an activated span is not a non-LIFO violation');
	is($c->{stale_handle}, 0,
		'ending an activated span does not count as a stale handle');
}

# ----------------------------------------------------------------
# Misuse: deactivating with a stale token (the span has already
# ended).  Continues the previous scenario's token.
# ----------------------------------------------------------------
check_misuse(
	'deactivate with a stale token (span already ended)',
	q{SELECT otel_api_conformance_start('conformance.activate.misuse.stale', owner_mode := 'session', detached := true) AS s \gset
SELECT otel_api_conformance_activate(:s) AS tok \gset
SELECT otel_api_conformance_end(:s);
SELECT otel_api_conformance_deactivate(:tok);},
	'stale_handle');

# ----------------------------------------------------------------
# Misuse: deactivating twice (the span is still open, but the
# activation was already popped).
# ----------------------------------------------------------------
check_misuse(
	'deactivate twice',
	q{SELECT otel_api_conformance_start('conformance.activate.misuse.double_deactivate', owner_mode := 'session', detached := true) AS s \gset
SELECT otel_api_conformance_activate(:s) AS tok \gset
SELECT otel_api_conformance_deactivate(:tok);
SELECT otel_api_conformance_deactivate(:tok);
SELECT otel_api_conformance_end(:s);},
	'deactivate_not_active');

# ----------------------------------------------------------------
# Deactivating with spans pushed above it since is checked exactly
# like otel_span_end(): a LIFO violation, counted and logged (and, in
# a cassert build, Assert(false) in nonlifo_warning() -- same as any
# other non-LIFO end, so this goes through check_misuse() too). The
# span above the deactivated one is unwound (ended, exported with
# ERROR status).
# ----------------------------------------------------------------
check_misuse(
	'deactivate with a span pushed above it since',
	q{SELECT otel_api_conformance_start('conformance.activate.nonlifo', owner_mode := 'session', detached := true) AS s \gset
SELECT otel_api_conformance_activate(:s) AS tok \gset
SELECT otel_api_conformance_start('conformance.activate.nonlifo.above', owner_mode := 'session') AS above \gset
SELECT otel_api_conformance_deactivate(:tok);
SELECT otel_api_conformance_end(:s);},
	'non_lifo_end');

# ----------------------------------------------------------------
# otel_span_activate(OTEL_SPAN_NONE) is a no-op: no token, no counter.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_activate(0) AS tok \gset
SELECT :tok AS tok_value;
SELECT otel_api_conformance_counters();
SQL
	my @lines = grep { length } split /\n/, $out;
	is($lines[0], '0', 'activating OTEL_SPAN_NONE returns 0, not a token');
	my $c = decode_json($lines[1]);
	is($c->{activate_not_detached}, 0, 'no misuse counted for OTEL_SPAN_NONE');
	is($c->{activate_already_active}, 0, 'no misuse counted for OTEL_SPAN_NONE');
}

# ----------------------------------------------------------------
# An unsampled (negative-handle) .detached span can be activated too:
# its context still propagates to children even though nothing
# records.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
SET otel_api_conformance.sampler = 'drop';
BEGIN;
SELECT otel_api_conformance_start('conformance.activate.unsampled', owner_mode := 'session', detached := true) AS s \gset
SELECT :s < 0 AS unsampled;
SELECT otel_api_conformance_recording(:s) AS recording;
SELECT otel_api_conformance_activate(:s) AS tok \gset
SELECT :tok < 0 AS token_negative_too;
SELECT otel_api_conformance_span_current() = :s AS unsampled_span_is_current;
SELECT otel_api_conformance_deactivate(:tok);
SELECT otel_api_conformance_end(:s);
COMMIT;
SQL
	my @lines = grep { length } split /\n/, $out;
	is($lines[0], 't', 'the span is unsampled (negative handle)');
	is($lines[1], 'f', 'and not recording');
	is($lines[2], 't', 'its activation token is negative too');
	is($lines[3], 't', 'the unsampled span is current while activated');
}

done_testing();
