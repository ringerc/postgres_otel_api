# Copyright (c) 2026, PostgreSQL Global Development Group
#
# A plpgsql call with no otel_api span yet active must still pick up the
# backend's ROOT context (otel_api.traceparent / sqlcommenter / the 'M'
# header) when one is propagated, rather than always starting a brand
# new, disconnected trace: otherwise a client that propagates a trace
# context sees plpgsql spans land in a separate trace whenever
# otel_postgres_tracing (or anything else that would otherwise have put
# a span on the active stack first) isn't also loaded.  func_beg must
# use the default parent (OTEL_PARENT_ACTIVE), which already falls back
# to the root context when the active stack is empty, and to a fresh
# trace only when there is no context at all either --- so sampling is
# still decided per outermost call either way.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf', <<EOCONF);
shared_preload_libraries = 'otel_api,otel_plpgsql,test_otel_exporter'
log_min_messages = warning
EOCONF
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_plpgsql; '
	. 'CREATE EXTENSION test_otel_exporter');

$node->safe_psql(
	'postgres', q{
CREATE FUNCTION ocp_fn() RETURNS void AS $BODY$
BEGIN
	PERFORM 1;
END;
$BODY$ LANGUAGE plpgsql;
});

my $TRACE_ID = 'aabbccddeeff00112233445566778899';
my $SPAN_ID  = '0011223344556677';
my $FLAGS    = '01';
my $TRACEPARENT = "00-$TRACE_ID-$SPAN_ID-$FLAGS";

# --------------------------------------------------------------------
# A propagated root context (otel_api.traceparent): the function span
# must land IN that trace, as a direct child of the propagated span.
# --------------------------------------------------------------------
my $out = $node->safe_psql(
	'postgres', qq{
	SET otel_api.traceparent = '$TRACEPARENT';
	SELECT test_otel_clear();
	SELECT ocp_fn();
	SELECT test_otel_pop_span_by_name('pg.plpgsql.function');
});

like($out, qr/^trace_id=\Q$TRACE_ID\E$/m,
	'the function span is in the propagated trace, not a disconnected one');
like($out, qr/^parent_span_id=\Q$SPAN_ID\E$/m,
	'the function span is a direct child of the propagated span');

# --------------------------------------------------------------------
# No propagated context, no other active span: two separate top-level
# calls still land in two DIFFERENT traces (the default parent falls
# back to "a new trace" only when there is truly no context at all, and
# that decision -- and the sampling that goes with it -- is still made
# fresh for each outermost call).
# --------------------------------------------------------------------
my $combined = $node->safe_psql(
	'postgres', q{
	RESET otel_api.traceparent;
	SELECT test_otel_clear();
	SELECT ocp_fn();
	SELECT test_otel_pop_span_by_name('pg.plpgsql.function');
	SELECT ocp_fn();
	SELECT test_otel_pop_span_by_name('pg.plpgsql.function');
});
my @trace_ids = $combined =~ /^trace_id=([0-9a-f]{32})$/mg;
is(scalar(@trace_ids), 2, 'two function spans captured (one per call)');
isnt($trace_ids[0], $trace_ids[1],
	'two separate top-level calls with no propagated context still get independent trace_ids');

$node->stop;
done_testing();
