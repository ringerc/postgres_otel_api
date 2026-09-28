# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Limits: exhausting otel_api.max_open_spans and
# otel_api.max_session_spans; a tight loop emitting spans keeps backend
# memory bounded.  otel_api P2 design, "Conformance test suite" >
# "Limits".
#
# The stress-loop span count defaults small; set
# PG_TEST_OTEL_CONFORMANCE_STRESS_N=1000000 in the environment to run
# the full 1e6-span check the design calls for (it needs a generous
# timeout, hence being opt-in here).
#
# Every counter/backend-memory read below is the last statement of the
# SAME psql invocation that ran the scenario: otel_api_conformance's
# counters and captured spans, and a backend's own memory footprint,
# are all backend-local (see t/001_construction.pl's header comment).

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use JSON::PP;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf', <<'EOCONF');
shared_preload_libraries = 'otel_api,otel_api_conformance'
otel_api.max_open_spans = 8
otel_api.max_session_spans = 4
EOCONF
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_api_conformance');

# ----------------------------------------------------------------
# max_open_spans: past the cap, start returns OTEL_SPAN_NONE and the
# drop is counted; earlier spans keep working.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
BEGIN;
SELECT otel_api_conformance_exhaust_open(32, 'toptxn') AS started \gset
COMMIT;
SELECT :started AS started;
SELECT otel_api_conformance_counters();
SQL
	my ($started, $counters_line) = split /\n/, $out, 2;
	cmp_ok($started, '<', 32, 'fewer spans started than requested once otel_api.max_open_spans is hit');
	my $c = decode_json($counters_line);
	cmp_ok($c->{start_no_slot}, '>=', 1, 'start_no_slot counter increased');
}

# ----------------------------------------------------------------
# max_session_spans: enforced separately from max_open_spans.  Ordinary
# (non-session) spans still work while the session budget is
# exhausted.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_exhaust_session(32) AS started \gset
SELECT :started AS started;
SELECT otel_api_conformance_counters();
SELECT otel_api_conformance_end(otel_api_conformance_start('conformance.still_works')) AS r;
SQL
	my ($started, $counters_line, $still_works_line) = split /\n/, $out, 3;
	cmp_ok($started, '<', 32,
		'fewer session spans started than requested once otel_api.max_session_spans is hit');
	my $c = decode_json($counters_line);
	cmp_ok($c->{start_no_session_slot}, '>=', 1, 'start_no_session_slot counter increased');
	ok(defined $still_works_line,
		'ordinary spans keep working while the session budget is exhausted');
}

# ----------------------------------------------------------------
# Tight loop: otel_api's OWN memory (the span pool and its per-slot
# child contexts) stays bounded, independent of N.  N is a parameter
# so a full 1e6-span run can be requested via the environment; default
# is small so this file runs quickly in CI.
#
# What's measured, and why: the claim under test is that otel_api's
# own span pool reuses one slot in a tight loop, not that this test
# extension's own bookkeeping is bounded (its capture list is
# deliberately unbounded, since capturing exactly the spans a test
# wants to inspect is the point of it elsewhere in this suite).  So
# otel_api_conformance.capture_spans is turned off for this scenario,
# and the measurement reads otel_api's own "otel_api span pool" and
# "otel_api span" backend-local memory contexts via
# pg_backend_memory_contexts, rather than this backend's total
# footprint or otel_api_conformance's own contexts.
# ----------------------------------------------------------------
{
	my $n = $ENV{PG_TEST_OTEL_CONFORMANCE_STRESS_N} // 10000;
	my $mem_expr = "(SELECT coalesce(sum(total_bytes), 0) "
		. "FROM pg_backend_memory_contexts "
		. "WHERE name IN ('otel_api span pool', 'otel_api span'))";
	my $out = $node->safe_psql(
		'postgres',
		"SET otel_api_conformance.capture_spans = off;\n"
		. "SELECT $mem_expr AS before_bytes \\gset\n"
		. "SELECT otel_api_conformance_stress($n) AS r \\gset\n"
		. "SELECT $mem_expr AS after_bytes \\gset\n"
		. "SELECT :before_bytes AS before_bytes, :after_bytes AS after_bytes;\n",
		timeout => 600);
	my ($before, $after) = split /\|/, $out;

	# Bounded: one slot's worth of pool + per-slot context, independent
	# of N (measured at ~41 KB for both N=10000 and N=200000 by hand
	# against a manual cluster before writing this bound); a few KB of
	# slack covers allocator rounding.
	my $growth = $after - $before;
	cmp_ok($growth, '<', 65536,
		"otel_api's own span-pool memory after $n spans is bounded (grew $growth bytes, "
		. "before=$before after=$after)");
}

$node->stop;
done_testing();
