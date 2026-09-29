# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Procedures with transaction control: CALL p() where p runs COMMIT or
# ROLLBACK partway through, with a span open under the default owner,
# TopTransactionResourceOwner, and OTEL_OWNER_SESSION.  Also a nested
# (non-atomic) CALL that commits, and a plpgsql EXCEPTION block ahead of
# a COMMIT/ROLLBACK.  otel_api P2 edge-case plan, item 1 (postgres-
# cdq.9.1).
#
# There is no procedure-lifetime span concept in otel_api today: a span
# is owned by whatever resource owner is current when it starts.  The
# design proposal under discussion (see docs/plans/otel-api-edge-case-
# tests.md and the bead) is to tie such a span to the CALL's own portal
# instead, so it survives an inner COMMIT/ROLLBACK with its parentage
# intact and is only exported as ERROR if the CALL itself fails.  This
# file records today's actual behaviour per owner (plain assertions)
# and the proposed future behaviour (TODO blocks, where they differ).
#
# See t/001_construction.pl's header for the general same-connection /
# ownership rule this file follows: state is backend-local, so each
# scenario's setup, trigger and readback happen in one psql invocation.

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

# A parent span under the given owner_mode; optionally an EXCEPTION
# block first; then COMMIT or ROLLBACK (or neither); then a child
# span started via the *active* parent (parent_mode defaults to
# 'active'), to test whether the parent's stack entry survived.
$node->safe_psql('postgres', <<'SQL');
CREATE OR REPLACE PROCEDURE conformance_proc_txn(
	owner_mode text, txn_action text DEFAULT 'none', use_exception boolean DEFAULT false)
LANGUAGE plpgsql AS $body$
DECLARE
	ref bigint;
	child_ref bigint;
BEGIN
	ref := otel_api_conformance_start('conformance.proc.parent.' || owner_mode,
		owner_mode => owner_mode);
	PERFORM otel_api_conformance_set_int(ref, 'conformance.tag', 1);

	IF use_exception THEN
		BEGIN
			RAISE EXCEPTION 'conformance induced (in exception block, before commit/rollback)';
		EXCEPTION WHEN OTHERS THEN
			NULL;
		END;
	END IF;

	IF txn_action = 'commit' THEN
		COMMIT;
	ELSIF txn_action = 'rollback' THEN
		ROLLBACK;
	END IF;

	-- Safe even if ref is now stale: a quiet no-op, counted or not
	-- per otel_producer.h's stale-handle rules.
	PERFORM otel_api_conformance_set_int(ref, 'conformance.after_txn', 1);

	child_ref := otel_api_conformance_start('conformance.proc.child.' || owner_mode);
	PERFORM otel_api_conformance_end(child_ref);
	PERFORM otel_api_conformance_end(ref);
END;
$body$;
SQL

# Runs one (owner_mode, txn_action, use_exception) scenario and returns
# a hashref: { status => {...counters...}, spans => [...], parent =>
# {...}, child => {...} }.
sub run_proc_scenario
{
	my ($owner_mode, $txn_action, $use_exception) = @_;
	my $exc = $use_exception ? 'true' : 'false';
	my $out = $node->safe_psql('postgres', <<SQL);
SELECT otel_api_conformance_reset() AS r1 \\gset
CALL conformance_proc_txn('$owner_mode', '$txn_action', $exc);
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s
	WHERE s->>'name' LIKE 'conformance.proc.%.$owner_mode';
SELECT otel_api_conformance_counters();
SELECT otel_api_conformance_span_current();
SQL
	my @lines = split /\n/, $out;
	my @spans = parse_spans($lines[0]);
	my $counters = decode_json($lines[1]);
	my $stack_after = $lines[2];
	my ($parent) = grep { $_->{name} eq "conformance.proc.parent.$owner_mode" } @spans;
	my ($child) = grep { $_->{name} eq "conformance.proc.child.$owner_mode" } @spans;
	return {
		counters => $counters,
		spans => \@spans,
		parent => $parent,
		child => $child,
		stack_after => $stack_after,
	};
}

# ----------------------------------------------------------------
# session owner: unaffected by COMMIT/ROLLBACK inside the procedure --
# it has no resource owner at all.  Both the parent and its intact
# parentage to the child should survive either transaction action.
# ----------------------------------------------------------------
for my $txn_action (qw(commit rollback))
{
	my $r = run_proc_scenario('session', $txn_action, 0);
	ok($r->{parent}, "session owner, $txn_action: the parent span is exported");
	is($r->{parent}->{status}, 0, "session owner, $txn_action: the parent has UNSET status (not ERROR)")
		if $r->{parent};
	ok($r->{child}, "session owner, $txn_action: the child span is exported");
	is($r->{child}->{parent_span_id}, $r->{parent}->{span_id},
		"session owner, $txn_action: the child parents to the still-open session span")
		if $r->{child} && $r->{parent};
	is($r->{stack_after}, '0', "session owner, $txn_action: nothing left on the active stack afterwards");
}

# ----------------------------------------------------------------
# TopTransactionResourceOwner and the default owner (the CALL portal's
# resource owner).  A COMMIT inside the procedure releases the owner
# with the span still open: today that is a leak (dropped, not
# exported).  A ROLLBACK unwinds it (exported with ERROR status).
# Either way the child, started after the COMMIT/ROLLBACK, is a root.
# ----------------------------------------------------------------
for my $owner_mode (qw(toptxn default))
{
	{
		my $r = run_proc_scenario($owner_mode, 'commit', 0);
		ok(!$r->{parent}, "$owner_mode owner, commit: the parent span is NOT exported (dropped as a leak)");
		is($r->{counters}->{leaked_at_commit}, 1, "$owner_mode owner, commit: leaked_at_commit is 1");
		ok($r->{child}, "$owner_mode owner, commit: the child span is exported");
		is($r->{child}->{parent_span_id}, '0' x 16,
			"$owner_mode owner, commit: the child is a root, not parented to the released parent")
			if $r->{child};
		is($r->{stack_after}, '0', "$owner_mode owner, commit: nothing left on the active stack afterwards");

		local $TODO = 'desired future behaviour (design decision pending): a procedure-lifetime span '
			. 'tied to the CALL portal should survive the inner COMMIT and keep its parentage, not be '
			. 'dropped as a leak';
		ok($r->{parent}, "$owner_mode owner, commit: [desired] the parent span survives the inner COMMIT");
		is($r->{child}->{parent_span_id}, $r->{parent}->{span_id},
			"$owner_mode owner, commit: [desired] the child parents to the procedure span")
			if $r->{child} && $r->{parent};
	}

	{
		my $r = run_proc_scenario($owner_mode, 'rollback', 0);
		ok($r->{parent}, "$owner_mode owner, rollback: the parent span is exported (unwound)");
		is($r->{parent}->{status}, 2, "$owner_mode owner, rollback: ERROR status") if $r->{parent};
		is($r->{counters}->{unwound}, 1, "$owner_mode owner, rollback: unwound is 1");
		ok($r->{child}, "$owner_mode owner, rollback: the child span is exported");
		is($r->{child}->{parent_span_id}, '0' x 16,
			"$owner_mode owner, rollback: the child is a root, not parented to the unwound parent")
			if $r->{child};
		is($r->{stack_after}, '0', "$owner_mode owner, rollback: nothing left on the active stack afterwards");

		local $TODO = 'desired future behaviour (design decision pending): a procedure-lifetime span '
			. 'should only be exported with ERROR status if the CALL itself fails, not merely because '
			. 'it did an internal ROLLBACK';
		is($r->{parent}->{status}, 0,
			"$owner_mode owner, rollback: [desired] the parent keeps UNSET status across a successful CALL")
			if $r->{parent};
	}
}

# ----------------------------------------------------------------
# Nested (non-atomic) CALL: an outer procedure with its own span calls
# an inner procedure (via a plain CALL statement, not a function call),
# and the inner one commits.  PL/pgSQL's nested-CALL support keeps this
# non-atomic, so the inner COMMIT is allowed.
# ----------------------------------------------------------------
$node->safe_psql('postgres', <<'SQL');
CREATE OR REPLACE PROCEDURE conformance_proc_nested_inner(owner_mode text) LANGUAGE plpgsql AS $body$
DECLARE
	ref bigint;
BEGIN
	ref := otel_api_conformance_start('conformance.proc.nested_inner.' || owner_mode, owner_mode => owner_mode);
	COMMIT;
	PERFORM otel_api_conformance_end(ref);
END;
$body$;

CREATE OR REPLACE PROCEDURE conformance_proc_nested_outer(owner_mode text) LANGUAGE plpgsql AS $body$
DECLARE
	ref bigint;
BEGIN
	ref := otel_api_conformance_start('conformance.proc.nested_outer.' || owner_mode, owner_mode => owner_mode);
	CALL conformance_proc_nested_inner(owner_mode);
	PERFORM otel_api_conformance_end(ref);
END;
$body$;
SQL

for my $owner_mode (qw(session toptxn))
{
	my $out = $node->safe_psql('postgres', <<SQL);
SELECT otel_api_conformance_reset() AS r1 \\gset
CALL conformance_proc_nested_outer('$owner_mode');
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s
	WHERE s->>'name' LIKE 'conformance.proc.nested_%.$owner_mode';
SELECT otel_api_conformance_span_current();
SQL
	my @lines = split /\n/, $out;
	my @s = parse_spans($lines[0]);
	my ($outer) = grep { $_->{name} eq "conformance.proc.nested_outer.$owner_mode" } @s;
	my ($inner) = grep { $_->{name} eq "conformance.proc.nested_inner.$owner_mode" } @s;
	if ($owner_mode eq 'session')
	{
		ok($inner, "nested CALL, session owner: the inner procedure's span is exported");
		ok($outer, 'nested CALL, session owner: the outer span survives the inner CALL\'s commit');
	}
	else
	{
		# toptxn: both the outer AND the inner span's owner is the same
		# (still current) top-transaction owner at the moment each
		# starts -- the inner CALL's own COMMIT releases it with both
		# spans still open, so both are dropped as leaks, exactly like
		# the non-nested toptxn/commit case above.
		ok(!$inner, 'nested CALL, toptxn owner: the inner span is NOT exported (dropped as a leak '
			. 'by its own CALL\'s commit)');
		ok(!$outer, 'nested CALL, toptxn owner: the outer span is NOT exported (dropped as a leak '
			. 'by the inner CALL\'s commit)');
	}
	is($lines[1], '0', "nested CALL, $owner_mode owner: nothing left on the active stack afterwards");
}

# ----------------------------------------------------------------
# otel_postgres_tracing variant: with otel.trace_all_queries on, the
# CALL statement gets a default-owner statement span named "CALL".
# Its plpgsql statements before the COMMIT/ROLLBACK are its children;
# the statement after it is a new root.  At a COMMIT the CALL span is
# dropped as a leak, but its children have already been exported, so
# they are orphans (their parent never arrives).  At a ROLLBACK the
# CALL span is exported with ERROR status.
# ----------------------------------------------------------------
{
	my $node2 = PostgreSQL::Test::Cluster->new('tracing');
	$node2->init;
	$node2->append_conf('postgresql.conf',
		"shared_preload_libraries = 'otel_api,otel_postgres_tracing,otel_api_conformance'\n"
		. "otel.trace_all_queries = on\n");
	$node2->start;
	$node2->safe_psql('postgres',
		'CREATE EXTENSION otel_api; CREATE EXTENSION otel_postgres_tracing; '
		. 'CREATE EXTENSION otel_api_conformance');

	$node2->safe_psql('postgres', <<'SQL');
CREATE OR REPLACE PROCEDURE conformance_proc_tracing(txn_action text) LANGUAGE plpgsql AS $body$
BEGIN
	PERFORM pg_sleep(0);
	IF txn_action = 'commit' THEN
		COMMIT;
	ELSIF txn_action = 'rollback' THEN
		ROLLBACK;
	END IF;
	PERFORM pg_sleep(0);
END;
$body$;
SQL

	for my $txn_action (qw(commit rollback))
	{
		my $out = $node2->safe_psql('postgres', <<SQL);
SELECT otel_api_conformance_reset() AS r1 \\gset
CALL conformance_proc_tracing('$txn_action');
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SELECT otel_api_conformance_counters();
SQL
		my @lines = split /\n/, $out;
		my @all = parse_spans($lines[0]);
		my $counters = decode_json($lines[1]);

		my $is_proc_stmt = sub {
			my ($sp, $text) = @_;
			grep { $_->{key} eq 'db.query.text' && $_->{value} =~ $text } @{ $sp->{attrs} };
		};
		my %by_id = map { $_->{span_id} => $_ } @all;
		my ($call) = grep { $_->{name} eq 'CALL' } @all;
		my @sleeps = grep { $_->{name} eq 'pgsql.execute' && $is_proc_stmt->($_, qr/^SELECT pg_sleep\(0\)/) } @all;
		is(scalar(@sleeps), 2, "otel_postgres_tracing, CALL + $txn_action: both pg_sleep statements have a span");
		my ($before, $after) = sort { $a->{start_time} <=> $b->{start_time} } @sleeps;
		my @orphans = grep { $_->{parent_span_id} ne '0' x 16 && !$by_id{ $_->{parent_span_id} } } @all;

		is($after->{parent_span_id}, '0' x 16,
			"otel_postgres_tracing, CALL + $txn_action: the statement after it is a new root")
			if $after;

		if ($txn_action eq 'commit')
		{
			ok(!$call, 'otel_postgres_tracing, CALL + commit: the CALL span is NOT exported (dropped as a leak)');
			is($counters->{leaked_at_commit}, 1, 'otel_postgres_tracing, CALL + commit: leaked_at_commit is 1');
			ok(scalar(@orphans) >= 1 && (grep { $_ == $before } @orphans),
				'otel_postgres_tracing, CALL + commit: statements before the COMMIT are exported as orphans');

			local $TODO = 'desired future behaviour (design decision pending): the CALL statement '
				. 'span should survive the inner COMMIT with parentage intact, not be dropped as a leak';
			ok($call && $call->{status} == 0,
				'otel_postgres_tracing, CALL + commit: [desired] the CALL span is exported with UNSET status');
			is(scalar(@orphans), 0, 'otel_postgres_tracing, CALL + commit: [desired] no orphaned spans');
			is($after->{parent_span_id}, $call->{span_id},
				'otel_postgres_tracing, CALL + commit: [desired] the statement after COMMIT parents to CALL')
				if $after && $call;
		}
		else
		{
			ok($call, 'otel_postgres_tracing, CALL + rollback: the CALL span is exported');
			is($call->{status}, 2, 'otel_postgres_tracing, CALL + rollback: ERROR status (unwound)') if $call;
			is($counters->{unwound}, 1, 'otel_postgres_tracing, CALL + rollback: unwound is 1');
			is($before->{parent_span_id}, $call->{span_id},
				'otel_postgres_tracing, CALL + rollback: the statement before ROLLBACK parents to CALL')
				if $before && $call;
			is(scalar(@orphans), 0, 'otel_postgres_tracing, CALL + rollback: no orphaned spans');
		}
	}

	$node2->stop;
}

$node->stop;
done_testing();
