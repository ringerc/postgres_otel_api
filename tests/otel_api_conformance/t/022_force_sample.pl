# Copyright (c) 2026, PostgreSQL Global Development Group
#
# force_sample: applies only to a brand-new root span (no parent
# context at all).  It must never override the sampling decision for a
# span that has a parent, because recording a child under a parent
# that is itself not recorded (and so never exported) produces an
# orphan span.  postgres-cdq.19.
#
# Four parent kinds, each with force_sample => true:
#   (a) no parent at all (parent_mode => 'root')        -> recorded
#   (b) remote parent, sampled=0 (parent_mode => 'context') -> NOT recorded
#   (c) remote parent, sampled=1 (parent_mode => 'context') -> recorded
#   (d) unsampled local parent (parent_mode => 'active')  -> NOT recorded
#
# Test-writing note: each scenario runs inside an explicit
# BEGIN...COMMIT, same as t/007_unsampled.pl --- a default-owned span
# started in one top-level ("...;\n") statement is otherwise force-
# closed (WARNING "resource was not closed") at that statement's own
# implicit transaction end, before the next statement can inspect it.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'otel_api,otel_api_conformance'\n");
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_api_conformance');

my $trace_id = 'aabbccddeeff00112233445566778899';
my $span_id  = '0011223344556677';

# ----------------------------------------------------------------
# (a) No parent context: force_sample records the new root even
# though the sampler hook would otherwise drop it.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
SET otel_api_conformance.sampler = 'drop';
BEGIN;
SELECT otel_api_conformance_start('conformance.force_root',
	parent_mode => 'root', owner_mode => 'toptxn', force_sample => true) AS s \gset
SELECT otel_api_conformance_recording(:s) AS recording;
SELECT otel_api_conformance_end(:s) AS r1 \gset
COMMIT;
SQL
	my ($recording) = split /\n/, $out;
	is($recording, 't',
		'force_sample records a new root even when the sampler would drop it');
}

# ----------------------------------------------------------------
# (b) Remote parent, sampled=0: force_sample must NOT record the
# child.  The context still propagates (same trace_id).
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<SQL);
BEGIN;
SELECT encode(otel_api_conformance_context_send('$trace_id', '$span_id', 0), 'hex') AS wire \\gset
SELECT otel_api_conformance_start('conformance.force_unsampled_remote',
	parent_mode => 'context', parent_ctx => decode(:'wire', 'hex'),
	owner_mode => 'toptxn', force_sample => true) AS s \\gset
SELECT otel_api_conformance_recording(:s) AS recording;
SELECT encode(otel_api_conformance_context_of(:s), 'hex') AS child_wire \\gset
SELECT otel_api_conformance_end(:s) AS r1 \\gset
COMMIT;
SELECT otel_api_conformance_context_recv(decode(:'child_wire', 'hex')) AS child_ctx;
SQL
	my ($recording, $child_ctx) = split /\n/, $out;
	is($recording, 'f',
		'force_sample does not record a child of an unsampled remote parent');
	my ($c_trace) = split /;/, $child_ctx;
	is($c_trace, $trace_id,
		'the context still propagates (same trace_id) even though nothing is recorded');
}

# ----------------------------------------------------------------
# (c) Remote parent, sampled=1: recorded, same as without
# force_sample --- it simply follows the parent's own decision.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<SQL);
BEGIN;
SELECT encode(otel_api_conformance_context_send('$trace_id', '$span_id', 1), 'hex') AS wire \\gset
SELECT otel_api_conformance_start('conformance.force_sampled_remote',
	parent_mode => 'context', parent_ctx => decode(:'wire', 'hex'),
	owner_mode => 'toptxn', force_sample => true) AS s \\gset
SELECT otel_api_conformance_recording(:s) AS recording;
SELECT otel_api_conformance_end(:s) AS r1 \\gset
COMMIT;
SELECT jsonb_agg(sp) FROM otel_api_conformance_spans() sp;
SQL
	my @lines = split /\n/, $out;
	my ($recording, $spans_line) = @lines;
	is($recording, 't', 'force_sample leaves a sampled remote parent\'s child recorded');

	$spans_line //= '';
	like($spans_line, qr/"parent_span_id":\s*"$span_id"/,
		'the recorded child parents to the sampled remote span_id');
}

# ----------------------------------------------------------------
# (d) Unsampled local parent: force_sample on the child must NOT
# record it, even though the child itself asked to force sampling.
# Mirrors t/007_unsampled.pl's default-owned-parent transaction shape.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
SET otel_api_conformance.sampler = 'drop';
BEGIN;
SELECT otel_api_conformance_start('conformance.local_unsampled_parent') AS parent \gset
SELECT otel_api_conformance_recording(:parent) AS parent_recording;
SELECT otel_api_conformance_start('conformance.force_child_of_unsampled_local',
	parent_mode => 'active', owner_mode => 'toptxn', force_sample => true) AS child \gset
SELECT otel_api_conformance_recording(:child) AS child_recording;
SELECT otel_api_conformance_end(:child) AS r1 \gset
SELECT otel_api_conformance_end(:parent) AS r2 \gset
COMMIT;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my @lines = split /\n/, $out;
	my ($parent_recording, $child_recording, $spans_line) = @lines;

	is($parent_recording, 'f', 'the local parent is unsampled (sampler=drop)');
	is($child_recording, 'f',
		'force_sample does not record a child of an unsampled local parent');

	$spans_line //= '';
	is($spans_line, '',
		'nothing is emitted for either the parent or the forced child');
}

$node->stop;
done_testing();
