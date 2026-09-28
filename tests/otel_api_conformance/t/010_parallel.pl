# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Parallel workers: a parallel query at top level, and one run from
# inside a plpgsql function.  Worker-side spans parent to the leader's
# published context.  otel_api_conformance is not otel_postgres_tracing,
# so the leader context is published manually via the internal table's
# parallel_publish_leader_context(), as the assignment brief directs.
# otel_api P2 design, "Conformance test suite" > "Propagation" (parallel
# workers item).
#
# Test-writing note: the leader span, the published leader context,
# and the actual parallel query must all run in ONE connection/backend
# -- the leader's span handle and the published context are both
# backend-local, so a separate psql invocation (a different backend)
# would see neither (see t/001_construction.pl's header comment).
# Each case below is one multi-statement psql invocation.
#
# Whether workers actually launch depends on the environment (small
# test tables, restricted worker budgets, etc); rather than parse
# EXPLAIN output (fragile, and beside the point), this file just looks
# at whether any row the query itself returned reports having run in a
# parallel worker, and only asserts parentage for those; if none did,
# it reports (does not fail) that no workers ran.

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
max_parallel_workers_per_gather = 4
parallel_setup_cost = 0
parallel_tuple_cost = 0
min_parallel_table_scan_size = 0
EOCONF
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_api_conformance');
$node->safe_psql('postgres', <<'SQL');
CREATE TABLE conformance_big AS SELECT g FROM generate_series(1, 200000) g;
ANALYZE conformance_big;
-- A plpgsql function running a query that can use parallel workers.
-- Not every plpgsql statement can: SELECT INTO runs the executor with a
-- row limit, and a limited run never uses workers; a set-returning SQL
-- function can be suspended between rows, which rules parallel query out
-- too.  RETURN QUERY runs to completion.
CREATE FUNCTION conformance_parallel_query() RETURNS SETOF text
LANGUAGE plpgsql AS $$
BEGIN
	RETURN QUERY
	SELECT DISTINCT split_part(otel_api_conformance_parallel_worker_probe(),
							   ';my_trace', 1)
	  FROM conformance_big;
END
$$;
SQL

sub run_parallel_probe
{
	my ($query) = @_;

	my $out = $node->safe_psql('postgres', <<SQL);
BEGIN;
SELECT otel_api_conformance_start('conformance.parallel_leader', detached => true, owner_mode => 'toptxn') AS leader \\gset
SELECT otel_api_conformance_publish_leader_context(:leader) AS r1 \\gset
SELECT encode(otel_api_conformance_context_of(:leader), 'hex') AS wire \\gset
SELECT otel_api_conformance_context_recv(decode(:'wire', 'hex')) AS leader_ctx;
SELECT array_to_json(array_agg(x)) FROM ($query) AS t(x);
SELECT otel_api_conformance_clear_leader_context() AS r2 \\gset
SELECT otel_api_conformance_end(:leader) AS r3 \\gset
COMMIT;
SQL
	my ($leader_ctx, $results_json) = split /\n/, $out, 2;
	my ($leader_trace, $leader_span) = split /;/, $leader_ctx;
	my @results = $results_json ne '' ? @{ decode_json($results_json) } : ();

	return ($leader_trace, $leader_span, @results);
}

for my $case (
	[ 'top-level parallel query', 'SELECT otel_api_conformance_parallel_worker_probe() FROM conformance_big' ],
	[ 'parallel query from inside plpgsql',
	  'SELECT conformance_parallel_query()' ],
  )
{
	my ($desc, $query) = @$case;
	my ($leader_trace, $leader_span, @results) = run_parallel_probe($query);

	my @worker_rows = grep { /in_parallel_worker=1/ } @results;
	if (scalar(@worker_rows) == 0)
	{
		diag("$desc: no probe row ran in a parallel worker in this environment; "
			. "skipping parentage assertion");
		fail("$desc: no parallel workers ran the probe");
		next;
	}

	my $all_match = 1;
	for my $row (@worker_rows)
	{
		$all_match = 0
			unless $row =~ /parent_trace=\Q$leader_trace\E;parent_span=\Q$leader_span\E/;
	}
	ok($all_match,
		"$desc: every worker-side probe picked up the leader's published context as its parent");
}

$node->stop;
done_testing();
