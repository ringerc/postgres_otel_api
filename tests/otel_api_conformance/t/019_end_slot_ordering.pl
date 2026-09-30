# Copyright (c) 2026, PostgreSQL Global Development Group
#
# end_slot()/release_slot() ordering: forgetting the resource-owner entry
# must happen before the span is dispatched, so a failure there (the
# owner is already releasing) leaves the span untouched for the owner's
# own release to export exactly once, instead of exporting it once from
# end_slot() and then leaving the slot stuck, half-released, for the
# owner to reach again.  otel_api P2 edge-case plan, item 3
# (postgres-cdq.9.3; see docs/plans/otel-api-dispatch-fixes-handover.md,
# "To fix" item 3).
#
# Producer calls from inside an emit hook are now refused (t/017), so the
# "a sibling span, ended from inside the misbehaving span's own dispatch"
# route no longer reaches this ordering at all.  This file reaches it a
# different way: a RegisterResourceReleaseCallback callback (as in
# t/015) that calls otel_span_end() directly on a still-owned span,
# combined with the "otel-api-oom-owner-forget" injection point
# (otel_producer.c) to force ResourceOwnerForget() to fail on an
# ordinary (non-abort) explicit end, where the real resource-owner
# machinery can't be made to reproduce "the owner is already releasing"
# any other way.
#
# otel_api_conformance_arm_abort_hook('release', 'end_target') plus
# otel_api_conformance_set_abort_target_ref(ref) arms a one-shot
# RegisterResourceReleaseCallback callback that calls otel_span_end() on
# a pre-started span instead of starting a new one (see
# conformance_abort_action()'s CONFORMANCE_ABORT_END_TARGET case).
#
# otel_api_conformance_oom_arm()/_disarm() attach/detach a real
# injection point per call (InjectionPointAttach errors "already
# defined" on a second attach with no detach in between), so every case
# below arms and disarms the site within the same script.  Every case
# reads counters/captured spans/otel_span_current back in the same
# psql invocation that produced them (backend-local state; see the
# handover's "Lessons").  A void-returning SQL function (otel_api_
# conformance_end() among others) still produces one (blank) output
# row in --tuples-only mode, so results are matched by content, not by
# line position (as t/017/t/018 do), not by $lines[N].

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
restart_after_crash = on
otel_api.emit_spans_to_log = on
EOCONF
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_api_conformance');

sub parse_spans
{
	my ($out) = @_;
	return () if !defined $out || $out eq '';
	return @{ decode_json($out) };
}

sub reset_all
{
	$node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_reset();
SELECT otel_api_conformance_misbehaviour_reset();
SELECT otel_api_conformance_abort_hook_reset();
SQL
}

# {spans_line, counters_line/status_line (first "{...}" match), all}.
sub run_sql
{
	my ($sql, %opts) = @_;
	my ($ret, $stdout, $stderr) =
	  $node->psql('postgres', $sql, on_error_stop => ($opts{on_error_stop} // 1));
	my @lines = grep { $_ ne '' } split /\n/, $stdout;
	my @braces = grep { /^\{/ } @lines;
	my @brackets = grep { /^\[/ } @lines;
	return {
		ret => $ret,
		stdout => $stdout,
		stderr => $stderr,
		spans => @brackets ? [ parse_spans($brackets[-1]) ] : [],
		objects => [ map { decode_json($_) } @braces ],
	};
}

my $available = $node->safe_psql('postgres', 'SELECT otel_api_conformance_oom_available()');
my $have_injection = ($available eq 't');
note("injection points available: $available");

# ----------------------------------------------------------------
# Case 1: a normal otel_span_end() with a live owner.  Baseline: the
# span is exported exactly once, with OK status, the stack is empty
# afterwards, and (where injection points exist) the forget site is
# hit exactly once, and succeeds.
# ----------------------------------------------------------------
{
	reset_all();
	my $sql = '';
	$sql .= "SELECT otel_api_conformance_oom_arm('owner-forget', 0, 0);\n" if $have_injection;
	$sql .= <<'SQL';
BEGIN;
SELECT otel_api_conformance_end(otel_api_conformance_start('conformance.case1', owner_mode => 'toptxn'));
COMMIT;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' = 'conformance.case1';
SELECT otel_api_conformance_span_current();
SQL
	$sql .= "SELECT otel_api_conformance_oom_status('owner-forget');\n" if $have_injection;
	$sql .= "SELECT otel_api_conformance_oom_disarm('owner-forget');\n" if $have_injection;

	my $r = run_sql($sql);
	is($r->{ret}, 0, "case1: the script completes") or diag($r->{stderr});
	is(scalar(@{ $r->{spans} }), 1, "case1: the span is exported exactly once") or diag($r->{stdout});
	is($r->{spans}[0]{status}, 0, "case1: status is OK") if @{ $r->{spans} };
	like($r->{stdout}, qr/(?:^|\n)0(?:\n|$)/, "case1: the stack is empty afterwards (span_current = 0)");

	if ($have_injection)
	{
		my ($status) = grep { exists $_->{hits} } @{ $r->{objects} };
		is($status->{hits}, 1, "case1: the forget site was hit exactly once") if $status;
		is($status->{fails}, 0, "case1: it was not forced to fail") if $status;
	}

	my $followup = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_end(otel_api_conformance_start('conformance.case1_followup'));
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' = 'conformance.case1_followup';
SQL
	is(scalar(parse_spans($followup)), 1, "case1: the slot is reusable -- a following span starts and ends");
}

SKIP:
{
	skip "no injection points in this build (USE_INJECTION_POINTS)", 45 unless $have_injection;

	# ----------------------------------------------------------------
	# Case 2: otel_span_end(), called from a resource-release callback,
	# of a span owned by the owner being released.  The injected
	# "owner-forget" failure stands in for core's real
	# ResourceOwnerForget() "already releasing" ERROR (see the file
	# header).  Run for both top-level and subtransaction abort.
	# ----------------------------------------------------------------
	for my $kind (qw(xact subxact))
	{
		reset_all();
		my $name = "conformance.case2_$kind";
		my $sql = '';
		# fail every hit (not just the first): which real call reaches the
		# forget site first differs between the xact and subxact trigger
		# points (which resource owner's release the one-shot callback
		# happens to catch first), so the test doesn't assume a specific
		# hit is "the" one that fails -- only that whichever real call
		# reaches otel_span_end() while the injected failure is armed
		# gets refused, and that the eventual outcome (single correct
		# export, no double dispatch) holds regardless.
		$sql .= "SELECT otel_api_conformance_oom_arm('owner-forget', 0, -1);\n";
		$sql .= "BEGIN;\n";
		$sql .= "SELECT otel_api_conformance_start('$name', owner_mode => 'toptxn') AS victim \\gset\n";
		$sql .= "SELECT otel_api_conformance_set_abort_target_ref(:victim);\n";
		$sql .= "SELECT otel_api_conformance_arm_abort_hook('release', 'end_target');\n";
		if ($kind eq 'xact')
		{
			$sql .= "SELECT 1/0;\n";
			$sql .= "ROLLBACK;\n";
		}
		else
		{
			$sql .= "DO \$do\$\nBEGIN\n\tBEGIN\n\t\tPERFORM 1/0;\n\tEXCEPTION WHEN OTHERS THEN\n\t\tNULL;\n\tEND;\nEND;\n\$do\$;\n";
			$sql .= "ROLLBACK;\n";	# the victim is toptxn-owned; roll back the whole thing
		}
		$sql .= "SELECT otel_api_conformance_abort_hook_status();\n";
		$sql .= "SELECT otel_api_conformance_counters();\n";
		$sql .= "SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' = '$name';\n";
		$sql .= "SELECT otel_api_conformance_span_current();\n";
		$sql .= "SELECT otel_api_conformance_oom_status('owner-forget');\n";
		$sql .= "SELECT otel_api_conformance_oom_disarm('owner-forget');\n";

		my $r = run_sql($sql, on_error_stop => 0);
		is($r->{ret}, 0, "case2/$kind: the psql script completes") or diag($r->{stderr});

		my ($status) = grep { exists $_->{ran} } @{ $r->{objects} };
		my ($counters) = grep { exists $_->{spans_started} } @{ $r->{objects} };
		my ($forget_status) = grep { exists $_->{hits} } @{ $r->{objects} };

		# subxact: the callback runs during a child owner's release, while
		# the victim's (toptxn) owner still tracks it, so its
		# otel_span_end() reaches the forget and the injected failure.
		# xact: the callback runs only once TopTransactionResourceOwner
		# has already released the victim, so its end is a stale handle
		# and never reaches the forget.  It checks the plain abort path.
		note("case2/$kind: abort_hook_status = " . ($status ? encode_json($status) : '<none>')
			  . "; oom_status(owner-forget) = " . ($forget_status ? encode_json($forget_status) : '<none>'));
		if ($kind eq 'subxact')
		{
			cmp_ok($forget_status->{fails}, '>=', 1,
				"case2/$kind: the callback's end reached the forget, and the injected failure fired");
		}
		else
		{
			is($forget_status->{hits}, 0, "case2/$kind: the callback's end didn't reach the forget");
		}
		ok($status && $status->{ran}, "case2/$kind: the resource-release callback ran") or diag($r->{stdout});

		my %by_id;
		$by_id{ $_->{span_id} }++ for @{ $r->{spans} };
		my @dups = grep { $by_id{$_} > 1 } keys %by_id;
		is(scalar(@dups), 0, "case2/$kind: no span was exported twice (by span_id)")
		  or diag($r->{stdout});
		is(scalar(@{ $r->{spans} }), 1, "case2/$kind: the span was exported exactly once")
		  or diag($r->{stdout});
		is($r->{spans}[0]{status}, 2,
			"case2/$kind: it has ERROR status (the owner's own unwind)")
		  if @{ $r->{spans} };
		is($counters->{unwound}, 1, "case2/$kind: unwound exactly once, by the owner's own release")
		  if $counters;
		like($r->{stdout}, qr/(?:^|\n)0(?:\n|$)/, "case2/$kind: the stack is empty afterwards (span_current = 0)");

		my $followup = $node->safe_psql('postgres', <<SQL);
SELECT otel_api_conformance_end(otel_api_conformance_start('conformance.case2_${kind}_followup'));
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' = 'conformance.case2_${kind}_followup';
SQL
		is(scalar(parse_spans($followup)), 1,
			"case2/$kind: the backend is usable afterwards -- a following span starts and ends");
	}

	# ----------------------------------------------------------------
	# Case 3: an ERROR from the emit hook during dispatch, after the
	# forget succeeded.  The slot is still reset, the span exported
	# once, and the (already-forgotten) owner never releases it again
	# -- checked across both a commit and an abort of the enclosing
	# transaction.
	# ----------------------------------------------------------------
	for my $end_kind (qw(commit abort))
	{
		reset_all();
		my $name = "conformance.case3_$end_kind";
		my $sql = '';
		$sql .= "SELECT otel_api_conformance_set_emit_misbehaviour('error', '$name');\n";
		$sql .= "BEGIN;\n";
		$sql .= "SELECT otel_api_conformance_end(otel_api_conformance_start('$name', owner_mode => 'toptxn'));\n";
		$sql .= $end_kind eq 'commit' ? "COMMIT;\n" : "SELECT 1/0;\nROLLBACK;\n";
		$sql .= "SELECT otel_api_conformance_counters();\n";
		$sql .= "SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' = '$name';\n";

		my $r = run_sql($sql, on_error_stop => 0);
		is($r->{ret}, 0, "case3/$end_kind: the psql script completes") or diag($r->{stderr});

		my ($counters) = grep { exists $_->{spans_started} } @{ $r->{objects} };
		is(scalar(@{ $r->{spans} }), 1, "case3/$end_kind: the span was exported exactly once")
		  or diag($r->{stdout});
		cmp_ok($counters->{emit_hook_errors}, '>=', 1,
			"case3/$end_kind: the emit hook's ERROR was caught by dispatch_span()")
		  if $counters;
		is($counters->{unwound}, 0,
			"case3/$end_kind: not unwound -- the explicit end (and its forget) already completed")
		  if $counters;

		my $followup = $node->safe_psql('postgres', <<SQL);
SELECT otel_api_conformance_end(otel_api_conformance_start('conformance.case3_${end_kind}_followup'));
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' = 'conformance.case3_${end_kind}_followup';
SQL
		is(scalar(parse_spans($followup)), 1,
			"case3/$end_kind: the backend is usable afterwards -- a following span starts and ends");
	}

	# ----------------------------------------------------------------
	# Case 4: an allocation failure in lower_error_event() (the existing
	# "otel-api-oom-exception-attrs" injection point) after the forget.
	# otel_api_conformance_capture_error_scenario() starts a span,
	# captures a PG_CATCH'd error into it (slot->err.used = true), and
	# ends it explicitly -- all with the calling statement's own portal
	# as owner (live, not releasing), so end_slot()'s forget succeeds
	# for real and lower_error_event() runs on the normal explicit-end
	# path (see t/003_errors.pl for the same helper).
	# ----------------------------------------------------------------
	{
		reset_all();
		my $sql = '';
		$sql .= "SELECT otel_api_conformance_oom_arm('exception-attrs', 0, 1);\n";
		$sql .= "SELECT otel_api_conformance_oom_arm('owner-forget', 0, 0);\n";
		$sql .= "SELECT otel_api_conformance_capture_error_scenario('conformance.case4');\n";
		$sql .= "SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' = 'conformance.case4';\n";
		$sql .= "SELECT otel_api_conformance_span_current();\n";
		$sql .= "SELECT otel_api_conformance_oom_status('owner-forget');\n";
		$sql .= "SELECT otel_api_conformance_oom_disarm('exception-attrs');\n";
		$sql .= "SELECT otel_api_conformance_oom_disarm('owner-forget');\n";

		my $r = run_sql($sql);
		is($r->{ret}, 0, "case4: the script completes") or diag($r->{stderr});
		is(scalar(@{ $r->{spans} }), 1, "case4: the span is still exported despite the injected allocation failure")
		  or diag($r->{stdout});
		is($r->{spans}[0]{status}, 2, "case4: status is ERROR") if @{ $r->{spans} };
		like($r->{stdout}, qr/(?:^|\n)0(?:\n|$)/, "case4: the stack is empty afterwards (span_current = 0)");

		my ($forget_status) = grep { exists $_->{hits} } @{ $r->{objects} };
		is($forget_status->{hits}, 1, "case4: the forget site was hit once, and succeeded") if $forget_status;
		is($forget_status->{fails}, 0, "case4: it was not the one armed to fail") if $forget_status;

		my $followup = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_end(otel_api_conformance_start('conformance.case4_followup'));
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' = 'conformance.case4_followup';
SQL
		is(scalar(parse_spans($followup)), 1,
			"case4: the slot is reusable -- a following span starts and ends");
	}

	# ----------------------------------------------------------------
	# Case 5: a span ended by the owner's own release
	# (otel_span_release_resource(), where the owner has already
	# forgotten it): exported once, and the forget site is never hit
	# at all (slot->owner is already NULL by the time end_slot() runs).
	# ----------------------------------------------------------------
	{
		reset_all();
		my $sql = '';
		$sql .= "SELECT otel_api_conformance_oom_arm('owner-forget', 0, 0);\n";
		$sql .= <<'INNERSQL';
BEGIN;
SELECT otel_api_conformance_start('conformance.case5', owner_mode => 'toptxn');
SELECT 1/0;
ROLLBACK;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' = 'conformance.case5';
SELECT otel_api_conformance_counters();
INNERSQL
		$sql .= "SELECT otel_api_conformance_oom_status('owner-forget');\n";
		$sql .= "SELECT otel_api_conformance_oom_disarm('owner-forget');\n";

		my $r = run_sql($sql, on_error_stop => 0);
		my ($counters) = grep { exists $_->{spans_started} } @{ $r->{objects} };
		my ($forget_status) = grep { exists $_->{hits} } @{ $r->{objects} };

		is(scalar(@{ $r->{spans} }), 1, "case5: the span is exported exactly once, by the owner's own release")
		  or diag($r->{stdout});
		is($r->{spans}[0]{status}, 2, "case5: status is ERROR (unwound)") if @{ $r->{spans} };
		is($counters->{unwound}, 1, "case5: counted as unwound, not as an explicit end") if $counters;
		is($forget_status->{hits}, 0, "case5: the forget site was never hit") if $forget_status;

		my $followup = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_end(otel_api_conformance_start('conformance.case5_followup'));
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' = 'conformance.case5_followup';
SQL
		is(scalar(parse_spans($followup)), 1,
			"case5: the backend is usable afterwards -- a following span starts and ends");
	}

	# ----------------------------------------------------------------
	# Case 6: a session span (no resource owner at all): ended
	# normally, the forget site is never hit.
	# ----------------------------------------------------------------
	{
		reset_all();
		my $sql = '';
		$sql .= "SELECT otel_api_conformance_oom_arm('owner-forget', 0, 0);\n";
		$sql .= "SELECT otel_api_conformance_end(otel_api_conformance_start_session('conformance.case6'));\n";
		$sql .= "SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' = 'conformance.case6';\n";
		$sql .= "SELECT otel_api_conformance_oom_status('owner-forget');\n";
		$sql .= "SELECT otel_api_conformance_oom_disarm('owner-forget');\n";

		my $r = run_sql($sql);
		my ($forget_status) = grep { exists $_->{hits} } @{ $r->{objects} };
		is(scalar(@{ $r->{spans} }), 1, "case6: the session span is exported exactly once") or diag($r->{stdout});
		is($r->{spans}[0]{status}, 0, "case6: status is OK") if @{ $r->{spans} };
		is($forget_status->{hits}, 0, "case6: the forget site was never hit (no owner)") if $forget_status;
	}
}

$node->stop;
done_testing();
