# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Unsampled traces: with otel_api.sampler=always_off, a parent span is
# unsampled (negative handle, otel_span_recording false); its children
# are unsampled too, without a fresh sampling decision (PARENT_NREC
# just inherits); nothing is emitted; otel_span_context_of on the child
# returns a valid context with sampled=0 and the same trace_id as the
# parent.  otel_api P2 design, "Conformance test suite" > "Unsampled
# traces".
#
# Test-writing note: an unsampled span started with the DEFAULT owner
# is a non-recording stack entry with no resource owner at all --
# otel_api's transaction-end callback (otel_xact_callback) drops every
# such entry at COMMIT or ABORT of the current transaction
# (drop_nrecs_from_level(1)), same as it would on abort.  Since every
# top-level "...;\n" statement runs in its own implicit transaction
# (even without an explicit BEGIN), a default-owned unsampled parent
# started in one top-level statement is *already gone* by the next
# one, so that scenario runs inside one explicit BEGIN...COMMIT.
#
# An unsampled span started with .owner = OTEL_OWNER_SESSION (or with
# no CurrentResourceOwner at all) is NOT dropped at transaction end,
# so it -- and the parentage it establishes -- survives across several
# separate transactions in the same backend.

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

# trace_flags is the whole W3C flags byte, not just the sampled bit
# (bit 0): a random-trace-id flag (bit 1) may also be set (see
# OTEL_TRACE_FLAG_RANDOM in otel_types.h), so an unsampled context can
# legitimately show flags=2, not just flags=0.
sub flags_unsampled
{
	my ($flags) = @_;
	return ($flags & 1) == 0;
}

# ----------------------------------------------------------------
# Default-owned unsampled parent + child, both within one transaction.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
SET otel_api.sampler = 'always_off';
BEGIN;
SELECT otel_api_conformance_start('conformance.unsampled_parent') AS parent \gset
SELECT :parent < 0 AS parent_negative;
SELECT otel_api_conformance_recording(:parent) AS parent_recording;
SELECT otel_api_conformance_start('conformance.unsampled_child', parent_mode => 'active') AS child \gset
SELECT otel_api_conformance_recording(:child) AS child_recording;
SELECT encode(otel_api_conformance_context_of(:child), 'hex') AS wire \gset
SELECT encode(otel_api_conformance_context_of(:parent), 'hex') AS parent_wire \gset
SELECT otel_api_conformance_end(:child) AS r1 \gset
SELECT otel_api_conformance_end(:parent) AS r2 \gset
COMMIT;
SELECT otel_api_conformance_context_recv(decode(:'wire', 'hex')) AS child_ctx;
SELECT otel_api_conformance_context_recv(decode(:'parent_wire', 'hex')) AS parent_ctx;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my @lines = split /\n/, $out;
	my ($parent_negative, $parent_recording,
		$child_recording, $child_ctx, $parent_ctx, $spans_line) = @lines;

	is($parent_negative, 't', 'unsampled root span gets a negative handle');
	is($parent_recording, 'f', 'otel_span_recording() is false for the unsampled parent');
	is($child_recording, 'f', 'the child of an unsampled parent is also unsampled');

	my ($c_trace, $c_span, $c_flags) = split /;/, $child_ctx;
	my ($p_trace) = split /;/, $parent_ctx;
	ok(flags_unsampled($c_flags),
		"otel_span_context_of on the unsampled child returns sampled=0 (flags=$c_flags)");
	is($c_trace, $p_trace, 'the unsampled child shares the parent trace_id');

	$spans_line //= '';
	is($spans_line, '',
		'nothing is emitted for the unsampled parent or its unsampled child');
}

# ----------------------------------------------------------------
# Session-owned unsampled parent: survives across transactions, and a
# later child (named explicitly via OTEL_PARENT_SPAN, since a session
# span is detached and never sits on any one transaction's active
# stack) is unsampled too, without a further sampler call.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
SET otel_api.sampler = 'always_off';
BEGIN;
SELECT otel_api_conformance_start_session('conformance.session_unsampled_parent') AS parent \gset
SELECT :parent < 0 AS parent_negative;
COMMIT;
BEGIN;
SELECT otel_api_conformance_start('conformance.session_unsampled_child', parent_mode => 'span', parent_ref => :parent) AS child \gset
SELECT otel_api_conformance_recording(:child) AS child_recording;
SELECT encode(otel_api_conformance_context_of(:child), 'hex') AS wire \gset
SELECT encode(otel_api_conformance_context_of(:parent), 'hex') AS parent_wire \gset
SELECT otel_api_conformance_end(:child) AS r1 \gset
COMMIT;
SELECT otel_api_conformance_context_recv(decode(:'wire', 'hex')) AS child_ctx;
SELECT otel_api_conformance_context_recv(decode(:'parent_wire', 'hex')) AS parent_ctx;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my @lines = split /\n/, $out;
	my ($parent_negative, $child_recording, $child_ctx, $parent_ctx, $spans_line) = @lines;

	is($parent_negative, 't', 'session-owned unsampled parent gets a negative handle');
	is($child_recording, 'f',
		'the child, started in a later transaction, is also unsampled');

	my ($c_trace) = split /;/, $child_ctx;
	my ($p_trace) = split /;/, $parent_ctx;
	is($c_trace, $p_trace,
		'the child shares the session-owned parent trace_id across transactions');

	$spans_line //= '';
	is($spans_line, '', 'nothing is emitted for either span');
}

$node->stop;
done_testing();
