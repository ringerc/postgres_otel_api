# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Construction and parentage: OTEL_PARENT_ACTIVE, OTEL_PARENT_CONTEXT,
# OTEL_PARENT_SPAN, OTEL_PARENT_ROOT, and detached spans.  otel_api P2
# design, "Conformance test suite" > "Construction and parentage".
#
# Test-writing notes (see also the file header of otel_api_conformance.c):
#  - otel_api_conformance_spans()/_counters() are backend-local, so the
#    read-back query must be the LAST statement of the SAME psql
#    invocation that ran the scenario -- $node->safe_psql() forks a new
#    psql process (a new backend) on every call, so a separate call
#    would just see an empty/reset backend.
#  - A span's default owner is the CURRENT STATEMENT's own portal, which
#    is released at the end of that statement -- even within one psql
#    invocation, each "...;\n" line is a separate top-level statement
#    with its own portal.  A span meant to survive across statements
#    needs an explicit BEGIN...COMMIT with owner_mode => 'toptxn'; one
#    that only needs to survive within a single statement can be built
#    with otel_api_conformance_end(otel_api_conformance_start(...)) so
#    both calls share one statement/portal.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use JSON::PP;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'otel_api,otel_api_conformance'\n");
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_api_conformance');

sub parse_spans
{
	my ($out) = @_;
	return () if !defined $out || $out eq '';
	return @{ decode_json($out) };
}

# ----------------------------------------------------------------
# active parent: a child started while a parent is on the active stack
# picks it up automatically.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
BEGIN;
SELECT otel_api_conformance_start('conformance.parent', owner_mode => 'toptxn') AS parent \gset
SELECT otel_api_conformance_start('conformance.child', parent_mode => 'active', owner_mode => 'toptxn') AS child \gset
SELECT otel_api_conformance_end(:child) AS r1 \gset
SELECT otel_api_conformance_end(:parent) AS r2 \gset
COMMIT;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my @s = parse_spans($out);
	is(scalar(@s), 2, 'active-parent scenario emitted parent + child');
	my ($parent) = grep { $_->{name} eq 'conformance.parent' } @s;
	my ($child) = grep { $_->{name} eq 'conformance.child' } @s;
	ok($parent && $child, 'both spans captured');
	is($child->{parent_span_id}, $parent->{span_id},
		'child parent_span_id equals parent span_id (OTEL_PARENT_ACTIVE)');
	is($child->{trace_id}, $parent->{trace_id}, 'child shares trace_id with parent');
}

# ----------------------------------------------------------------
# OTEL_PARENT_ROOT: always a new trace, even with an active parent.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
BEGIN;
SELECT otel_api_conformance_start('conformance.parent', owner_mode => 'toptxn') AS parent \gset
SELECT otel_api_conformance_start('conformance.root_child', parent_mode => 'root', owner_mode => 'toptxn') AS rootchild \gset
SELECT otel_api_conformance_end(:rootchild) AS r1 \gset
SELECT otel_api_conformance_end(:parent) AS r2 \gset
COMMIT;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my @s = parse_spans($out);
	my ($parent) = grep { $_->{name} eq 'conformance.parent' } @s;
	my ($rootchild) = grep { $_->{name} eq 'conformance.root_child' } @s;
	ok($parent && $rootchild, 'both spans captured');
	isnt($rootchild->{trace_id}, $parent->{trace_id},
		'OTEL_PARENT_ROOT starts a new trace even with an active parent');
	is($rootchild->{parent_span_id}, '0' x 16, 'root child has no parent span id');
}

# ----------------------------------------------------------------
# OTEL_PARENT_SPAN: explicit parent by handle, independent of the
# active stack.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
BEGIN;
SELECT otel_api_conformance_start('conformance.detached_parent', detached => true, owner_mode => 'toptxn') AS dparent \gset
SELECT otel_api_conformance_start('conformance.span_child', parent_mode => 'span', parent_ref => :dparent, owner_mode => 'toptxn') AS spanchild \gset
SELECT otel_api_conformance_end(:spanchild) AS r1 \gset
SELECT otel_api_conformance_end(:dparent) AS r2 \gset
COMMIT;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my @s = parse_spans($out);
	my ($dparent) = grep { $_->{name} eq 'conformance.detached_parent' } @s;
	my ($spanchild) = grep { $_->{name} eq 'conformance.span_child' } @s;
	ok($dparent && $spanchild, 'both spans captured');
	is($spanchild->{parent_span_id}, $dparent->{span_id},
		'OTEL_PARENT_SPAN uses the explicitly named parent, not the active stack');
	is($spanchild->{trace_id}, $dparent->{trace_id}, 'shares trace_id with the named parent');
}

# ----------------------------------------------------------------
# OTEL_PARENT_CONTEXT: explicit remote parent context.  Built and
# ended in one statement (nested calls), so default ownership is fine.
# ----------------------------------------------------------------
{
	my $trace_id = 'aabbccddeeff00112233445566778899';
	my $span_id  = '0011223344556677';
	my $out = $node->safe_psql('postgres', <<SQL);
SELECT otel_api_conformance_end(otel_api_conformance_start('conformance.ctx_child',
	parent_mode => 'context',
	parent_ctx => otel_api_conformance_context_send('$trace_id', '$span_id', 1))) AS r \\gset
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my @s = parse_spans($out);
	my ($ctxchild) = grep { $_->{name} eq 'conformance.ctx_child' } @s;
	ok($ctxchild, 'ctx_child span captured');
	is($ctxchild->{trace_id}, $trace_id, 'child inherits the explicit remote trace_id');
	is($ctxchild->{parent_span_id}, $span_id, 'child parent_span_id is the remote span_id');
}

# ----------------------------------------------------------------
# detached: not pushed on the active stack, so an unrelated span
# started meanwhile does not parent under it.  Each span is started
# and ended within its own statement, so default ownership is fine.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_end(otel_api_conformance_start('conformance.detached', detached => true)) AS r1 \gset
SELECT otel_api_conformance_end(otel_api_conformance_start('conformance.unrelated', parent_mode => 'active')) AS r2 \gset
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my @s = parse_spans($out);
	my ($det) = grep { $_->{name} eq 'conformance.detached' } @s;
	my ($unrel) = grep { $_->{name} eq 'conformance.unrelated' } @s;
	ok($det && $unrel, 'both spans captured');
	isnt($unrel->{parent_span_id}, $det->{span_id},
		'a detached span is not on the active stack, so a sibling does not parent under it');
}

$node->stop;
done_testing();
