# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Spans started from another extension's abort-time code: an
# XACT_EVENT_ABORT callback, a SUBXACT_EVENT_ABORT_SUB callback, and a
# RegisterResourceReleaseCallback callback.  otel_api P2 edge-case plan,
# item 4 (postgres-cdq.9.4).
#
# otel_api_conformance_arm_abort_hook('xact'|'subxact'|'release', mode)
# arms a one-shot callback of the given kind; otel_api_conformance_
# abort_hook_status() reports whether it ran and what it did.  Arming,
# state, and counters are all backend-local (see t/001's header
# comment), so every scenario below arms, triggers the abort, and reads
# back the result in one psql invocation on one connection.
#
# RegisterResourceReleaseCallback's callback is global (not tied to one
# resource owner): it fires for every owner's every release phase, with
# CurrentResourceOwner set to the owner currently releasing and that
# owner's internal "releasing" flag already true (see resowner.c).  So a
# default-owner otel_span_start() from it always targets an owner that
# is mid-release, which makes ResourceOwnerEnlarge() (called inside
# otel_span_start()) raise "ResourceOwnerEnlarge called after release
# started" -- this is the "starting on an owner that is already
# releasing" case the plan asks about, and it is exercised here without
# any special-casing: it's just where the callback always runs.

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
# XACT_EVENT_ABORT: arm the hook, run a top-level transaction that
# fails, check what its callback managed to do -- all in one
# connection.  At XACT_EVENT_ABORT, AtAbort_ResourceOwner() has already
# pointed CurrentResourceOwner at TopTransactionResourceOwner, and that
# owner's release hasn't started yet (ResourceOwnerRelease(
# TopTransactionResourceOwner, ...) runs later in AbortTransaction())
# -- so a default-owner span started here is not on an owner that is
# already releasing, and should start and end without any
# ResourceOwnerEnlarge complaint.
# ----------------------------------------------------------------
{
	my ($ret, $stdout, $stderr) = $node->psql(
		'postgres', <<'SQL',
SELECT otel_api_conformance_reset() AS r1 \gset
SELECT otel_api_conformance_abort_hook_reset() AS r2 \gset
SELECT otel_api_conformance_arm_abort_hook('xact', 'start_end') AS r3 \gset
BEGIN;
SELECT 1/0;
ROLLBACK;
SELECT otel_api_conformance_abort_hook_status();
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' = 'conformance.abort.xact_event';
SELECT otel_api_conformance_end(otel_api_conformance_start('conformance.abort.followup')) AS r4 \gset
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' = 'conformance.abort.followup';
SQL
		on_error_stop => 0);
	like($stderr, qr/division by zero/, 'xact_event: the induced error aborts the transaction');

	my @lines = split /\n/, $stdout;
	my $status = decode_json($lines[0]);
	ok($status->{ran}, 'xact_event: the XACT_EVENT_ABORT callback ran');
	is($status->{started}, 1, 'xact_event: it started one span');
	is($status->{ended}, 1, 'xact_event: it ended that span normally, no ResourceOwnerEnlarge error');
	is($status->{error_caught}, 0, 'xact_event: no ERROR was raised starting the span');
	is($status->{span_current}, 0, 'xact_event: no stack entry left behind afterwards');

	my @s = parse_spans($lines[1]);
	is(scalar(@s), 1, 'xact_event: exactly one span was exported');

	# Follow-up: the next ordinary span in this backend still works --
	# no slot or stack entry was left behind.
	my @f = parse_spans($lines[2]);
	is(scalar(@f), 1, 'xact_event: a following ordinary span still starts and ends fine');
}

# ----------------------------------------------------------------
# XACT_EVENT_ABORT, "leave_open" variant: the callback starts a span
# and abandons it without ending it.  Since CurrentResourceOwner there
# is TopTransactionResourceOwner and its release hasn't started, the
# abandoned span is picked up by that owner's own release moments
# later and unwound (exported with ERROR status), exactly like any
# other span left open across an abort.
# ----------------------------------------------------------------
{
	my ($ret, $stdout, $stderr) = $node->psql(
		'postgres', <<'SQL',
SELECT otel_api_conformance_reset() AS r1 \gset
SELECT otel_api_conformance_abort_hook_reset() AS r2 \gset
SELECT otel_api_conformance_arm_abort_hook('xact', 'leave_open') AS r3 \gset
BEGIN;
SELECT 1/0;
ROLLBACK;
SELECT otel_api_conformance_abort_hook_status();
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' = 'conformance.abort.xact_event';
SELECT otel_api_conformance_counters();
SQL
		on_error_stop => 0);

	my @lines = split /\n/, $stdout;
	my $status = decode_json($lines[0]);
	ok($status->{ran}, 'xact_event leave_open: the callback ran');
	is($status->{started}, 1, 'xact_event leave_open: it started one span');
	is($status->{ended}, 0, 'xact_event leave_open: it did not end the span itself');
	is($status->{span_current}, 0,
		'xact_event leave_open: the span is off the active stack afterwards (unwound, not leaked)');

	my ($span) = grep { $_->{name} eq 'conformance.abort.xact_event' } parse_spans($lines[1]);
	ok($span, 'xact_event leave_open: the abandoned span was exported, not dropped as a leak');
	is($span->{status}, 2, 'xact_event leave_open: it was exported with ERROR status') if $span;

	my $c = decode_json($lines[2]);
	cmp_ok($c->{unwound}, '>=', 1, 'xact_event leave_open: the unwound counter moved');
	is($c->{leaked_at_commit}, 0, 'xact_event leave_open: not counted as a commit-time leak');
}

# ----------------------------------------------------------------
# XACT_EVENT_ABORT, session-span variant: starting (and ending) a
# session span from abort-time code is unaffected by the abort, since
# a session span has no resource owner at all.
# ----------------------------------------------------------------
{
	my ($ret, $stdout, $stderr) = $node->psql(
		'postgres', <<'SQL',
SELECT otel_api_conformance_reset() AS r1 \gset
SELECT otel_api_conformance_abort_hook_reset() AS r2 \gset
SELECT otel_api_conformance_arm_abort_hook('xact', 'session') AS r3 \gset
BEGIN;
SELECT 1/0;
ROLLBACK;
SELECT otel_api_conformance_abort_hook_status();
SQL
		on_error_stop => 0);

	my @lines = split /\n/, $stdout;
	my $status = decode_json($lines[0]);
	is($status->{started}, 1, 'xact_event session: it started one session span');
	is($status->{ended}, 1, 'xact_event session: it ended that session span normally');
	is($status->{error_caught}, 0, 'xact_event session: no ERROR starting a session span in abort-time code');
}

# ----------------------------------------------------------------
# SUBXACT_EVENT_ABORT_SUB: a plpgsql EXCEPTION block's implicit
# subtransaction abort triggers the subtransaction callback instead of
# the top-level one (same pattern as t/013_unwind_export.pl's subxact
# case).
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_reset() AS r1 \gset
SELECT otel_api_conformance_abort_hook_reset() AS r2 \gset
SELECT otel_api_conformance_arm_abort_hook('subxact', 'start_end') AS r3 \gset
DO $do$
BEGIN
	BEGIN
		PERFORM 1/0;
	EXCEPTION WHEN OTHERS THEN
		NULL;
	END;
END;
$do$;
SELECT otel_api_conformance_abort_hook_status();
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' = 'conformance.abort.subxact_event';
SQL

	my @lines = split /\n/, $out;
	my $status = decode_json($lines[0]);
	ok($status->{ran}, 'subxact_event: the SUBXACT_EVENT_ABORT_SUB callback ran');
	is($status->{started}, 1, 'subxact_event: it started one span');
	is($status->{ended}, 1, 'subxact_event: it ended that span, no ResourceOwnerEnlarge error');
	is($status->{error_caught}, 0, 'subxact_event: no ERROR was raised starting the span');

	is(scalar(parse_spans($lines[1])), 1, 'subxact_event: exactly one span was exported');
}

# ----------------------------------------------------------------
# RegisterResourceReleaseCallback: this callback fires with
# CurrentResourceOwner pointing at an owner that has started releasing.
# A default-owner otel_span_start() there fails in core's
# ResourceOwnerEnlarge() with "called after release started", before
# otel_api takes a slot.  The helper catches the ERROR and restores
# InterruptHoldoffCount, as errfinish() requires of a handler inside a
# holdoff section.
# ----------------------------------------------------------------
{
	my ($ret, $stdout, $stderr) = $node->psql(
		'postgres', <<'SQL',
SELECT otel_api_conformance_reset() AS r1 \gset
SELECT otel_api_conformance_abort_hook_reset() AS r2 \gset
SELECT otel_api_conformance_arm_abort_hook('release', 'start_end') AS r3 \gset
BEGIN;
SELECT 1/0;
ROLLBACK;
SELECT otel_api_conformance_abort_hook_status();
SQL
		on_error_stop => 0);

	like($stderr, qr/division by zero/, 'release_callback: the induced error aborts the transaction');

	my @lines = split /\n/, $stdout;
	my $status = decode_json($lines[0]);
	ok($status->{ran}, 'release_callback: the RegisterResourceReleaseCallback callback ran');
	is($status->{error_caught}, 1,
		'release_callback: starting a span on an owner already releasing raised ERROR, caught here');
	is($status->{started}, 0,
		'release_callback: the span never actually started (ResourceOwnerEnlarge failed first)');
	is($status->{span_current}, 0, 'release_callback: no stack entry was left behind');

	# The backend is usable afterwards: no lingering slot or stack state.
	my $followup = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_end(otel_api_conformance_start('conformance.abort.release_followup')) AS r \gset
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' = 'conformance.abort.release_followup';
SELECT otel_api_conformance_counters();
SQL
	my @f = split /\n/, $followup;
	is(scalar(parse_spans($f[0])), 1,
		'release_callback: the backend is unaffected -- a following span starts and ends fine');
	my $c = decode_json($f[1]);
	is($c->{start_bad_args}, 0,
		"release_callback: the failed start was not counted as start_bad_args (it never "
		. "reached otel_api at all -- the ERROR came from core's ResourceOwnerEnlarge, before otel_api "
		. "took a slot)");
}

$node->stop;
done_testing();
