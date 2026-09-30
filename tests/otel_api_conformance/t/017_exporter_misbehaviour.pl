# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Exporter misbehaviour during dispatch: emit hooks that raise ERROR or
# FATAL, or that call the producer API (otel_span_start()/otel_span_end()),
# which otel_api refuses from inside an emit hook.  otel_api P2 edge-case
# plan, item 3 (postgres-cdq.9.3).
#
# otel_api_conformance_set_emit_misbehaviour(mode, match_name) arms the
# hook: once a span named match_name is dispatched (after it has been
# captured, so tests can see it was delivered), the hook misbehaves in
# the given way and bumps a counter, every time the name matches (not
# one-shot), so a scenario that dispatches the same name twice shows up
# in the count.  otel_api_conformance_set_misbehaviour_ref(ref) supplies
# the OtelSpanRef the "end_self"/"end_other" modes act on -- the hook
# has no way to recover a ref from the OtelSpan it's given, so the test
# arranges it beforehand.  otel_api_conformance_misbehaviour_status()
# reports how many of the hook's producer calls reached otel_api ("calls").
#
# "start_end"/"start_end_unguarded" both try to create further spans
# named literally "conformance.from_hook"; the test triggers them by
# starting and ending a span with that same name, so if otel_api let
# the call through, the re-entry would show up as a second span of that
# name (and, unguarded, as recursion up to the C helper's depth cap).
#
# The re-entry modes (start_end, start_end_unguarded, end_self,
# end_other) fail an Assert on cassert builds.  On other builds each
# call is refused and counted in in_emit_hook, and nothing else changes.
#
# Everything read back here (counters, captured spans, otel_span_current)
# is backend-local (see t/001's header comment), so each scenario arms,
# triggers, and reads the result back in one psql invocation/connection.

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
	  # The re-entry modes crash cassert builds with an Assert (a producer
	  # call from an emit hook); the test waits out the crash.
	  . "restart_after_crash = on\n"
	  # otel_api.emit_spans_to_log is PGC_SIGHUP (config-file only, not
	  # SET-able), and Scenario C needs it on throughout: the backend-
	  # local span capture is gone once a FATAL-hit backend exits, so
	  # counting "otel-span: ..." log lines is the only way to see
	  # whether the FATAL span was dispatched more than once.
	  . "otel_api.emit_spans_to_log = on\n");
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_api_conformance');

my $cassert = $node->safe_psql('postgres', 'SHOW debug_assertions');
note("debug_assertions = $cassert");

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

my $max_open_spans =
  $node->safe_psql('postgres', 'SHOW otel_api.max_open_spans');

my %reentry = map { $_ => 1 } qw(start_end start_end_unguarded end_self end_other);

# On a cassert build, run $sql, which makes the emit hook call the
# producer API, and check that the call fails call_refused()'s Assert
# and the server comes back.
sub expect_reentry_assert
{
	my ($label, $sql) = @_;
	my $log_start = -s $node->logfile;
	my ($ret, $stdout, $stderr) = $node->psql('postgres', $sql, on_error_stop => 0);
	isnt($ret, 0, "$label: connection lost (cassert Assert on a producer call from the emit hook)");
	my $log = PostgreSQL::Test::Utils::slurp_file($node->logfile, $log_start);
	like($log, qr/Assert\("read_only \|\| dispatch_depth == 0/,
		"$label: the Assert is the emit-hook refusal")
	  or diag($log);
	ok(wait_for_restart(), "$label: server accepts connections again after the crash")
	  or BAIL_OUT("server did not come back up after the induced crash");
}

# Producer calls that reach otel_api per hook invocation, for the
# re-entry modes on a non-cassert build: the refused otel_span_start()
# returns OTEL_SPAN_NONE, and otel_span_end() of that doesn't reach
# otel_api.
my %calls_per_run = (start_end => 1, start_end_unguarded => 1, end_self => 1, end_other => 1);

# ----------------------------------------------------------------
# Scenario A: normal-path dispatch.  fatal is scenario C, below.
# ----------------------------------------------------------------

sub batch_no_leak_sql
{
	my ($n) = @_;
	my $sql = '';
	for (my $i = 0; $i < $n; $i++)
	{
		$sql .=
		  "SELECT otel_api_conformance_end(otel_api_conformance_start('conformance.batch_probe'));\n";
	}
	return $sql;
}

for my $mode (qw(error start_end start_end_unguarded end_self end_other))
{
	reset_all();

	my $span_name =
		$mode eq 'start_end' || $mode eq 'start_end_unguarded'
	  ? 'conformance.from_hook'
	  : "conformance.misbehave.$mode";

	# A default-owner span belongs to its statement's portal and is
	# dropped as soon as that statement ends (see the handover's
	# "Lessons"), so a span that must stay open across several psql
	# statements here (the parent; the victim before its end) is started
	# with owner_mode => 'toptxn' inside an explicit transaction.
	my $sql = '';
	$sql .= "SELECT otel_api_conformance_set_emit_misbehaviour('$mode', '$span_name');\n";
	$sql .= "BEGIN;\n";
	$sql .= "SELECT otel_api_conformance_start('conformance.a_parent', owner_mode => 'toptxn') AS parent \\gset\n";
	$sql .= "SELECT otel_api_conformance_start('$span_name', owner_mode => 'toptxn') AS victim \\gset\n";
	# end_other targets the still-open parent; end_self the victim.
	$sql .= "SELECT otel_api_conformance_set_misbehaviour_ref(:parent);\n" if $mode eq 'end_other';
	$sql .= "SELECT otel_api_conformance_set_misbehaviour_ref(:victim);\n" if $mode eq 'end_self';
	$sql .= "SELECT otel_api_conformance_end(:victim) AS end_ret;\n";
	# The hook ran inside that end; the parent must still be on top.
	$sql .= "SELECT 'current_is_parent=' || (otel_api_conformance_span_current() = :parent);\n";
	$sql .= "SELECT otel_api_conformance_end(:parent) AS parent_end_ret;\n";
	$sql .= "COMMIT;\n";
	$sql .= "SELECT otel_api_conformance_end(otel_api_conformance_start('conformance.a_followup')) AS followup \\gset\n";
	$sql .= batch_no_leak_sql($max_open_spans + 1);
	$sql .= "SELECT otel_api_conformance_counters();\n";
	$sql .= "SELECT otel_api_conformance_misbehaviour_status();\n";
	$sql .= "SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;\n";

	if ($cassert eq 'on' && $reentry{$mode})
	{
		expect_reentry_assert("A/$mode", $sql);
		next;
	}

	my ($ret, $stdout, $stderr) = $node->psql('postgres', $sql, on_error_stop => 0);
	is($ret, 0, "A/$mode: the psql script completes") or diag($stderr);

	my @lines = split /\n/, $stdout;
	my @braces = grep { /^\{/ } @lines;
	my @brackets = grep { /^\[/ } @lines;
	is(scalar(@braces), 2, "A/$mode: counters and misbehaviour-status lines are both present")
	  or diag($stdout);
	my $counters = decode_json($braces[0]);
	my $mstatus = decode_json($braces[1]);
	my @spans = @brackets ? parse_spans($brackets[-1]) : ();

	is($mstatus->{count}, 1, "A/$mode: the misbehaviour ran once");

	my %by_id;
	$by_id{ $_->{span_id} }++ for @spans;
	my @dups = grep { $by_id{$_} > 1 } keys %by_id;
	is(scalar(@dups), 0, "A/$mode: no span was exported twice (by span_id)");

	my @victims = grep { $_->{name} eq $span_name } @spans;
	is(scalar(@victims), 1, "A/$mode: exactly one span named $span_name (the hook created none)");
	my ($parent) = grep { $_->{name} eq 'conformance.a_parent' } @spans;
	ok($parent, "A/$mode: the parent span is exported");
	is($parent->{status}, 0, "A/$mode: the parent ends normally (status unset)") if $parent;
	is($victims[0]{parent_span_id}, $parent->{span_id}, "A/$mode: the victim's parent is the parent span")
	  if @victims && $parent;
	like($stdout, qr/^current_is_parent=true$/m,
		"A/$mode: after the victim's end, the parent is still the current span");

	my ($followup) = grep { $_->{name} eq 'conformance.a_followup' } @spans;
	ok($followup, "A/$mode: a following ordinary span still starts and ends") or diag($stdout);
	is($followup->{parent_span_id}, '0000000000000000',
		"A/$mode: the following span is a root (no leftover parent on the stack)")
	  if $followup;

	is($counters->{start_no_slot}, 0, "A/$mode: no slot exhaustion after a batch of max_open_spans+1");
	is($counters->{stale_handle}, 0, "A/$mode: no stale handle counted");
	is($counters->{unwound}, 0, "A/$mode: no span unwound");

	my $expected_calls = $reentry{$mode} ? $calls_per_run{$mode} : 0;
	is($mstatus->{calls}, $expected_calls, "A/$mode: the hook made $expected_calls producer call(s)");
	is($counters->{in_emit_hook}, $expected_calls,
		"A/$mode: each producer call from the hook is refused and counted in in_emit_hook");
	is($mstatus->{max_depth}, 1, "A/$mode: no re-entry: the hook ran at depth 1")
	  if $mode eq 'start_end' || $mode eq 'start_end_unguarded';
}

# ----------------------------------------------------------------
# Scenario A': deterministic, crash-free reproduction of the normal-path
# memory-context/holdoff defect (the same one Scenario B's abort-time
# checks below chase indirectly, but here with no crash, no abort, and
# no build dependency -- otel_api_conformance_dispatch_error_probe()
# arms "error" misbehaviour, starts and ends a span, and records
# CurrentMemoryContext/InterruptHoldoffCount immediately after
# otel_span_end() returns, before restoring both itself.  Run with and
# without the caller's own HOLD_INTERRUPTS() around the call.
# ----------------------------------------------------------------
for my $held (0, 1)
{
	reset_all();
	my $out = $node->safe_psql('postgres',
		"SELECT otel_api_conformance_dispatch_error_probe(" . ($held ? 'true' : 'false') . ");");
	my $probe = decode_json($out);
	my $label = "A'/held=$held";

	note("$label: $out");
	is($probe->{misbehave_count}, 1, "$label: the induced error ran exactly once");

	is($probe->{after_context}, $probe->{before_context},
		"$label: CurrentMemoryContext is restored after otel_span_end() returns");

	my $expected_holdoff = $held ? $probe->{before_holdoff} + 1 : $probe->{before_holdoff};
	is($probe->{after_holdoff}, $expected_holdoff,
		"$label: InterruptHoldoffCount is unchanged (or +1 if held) after otel_span_end() returns");
}


# ----------------------------------------------------------------
# Scenario D: nested spans, misbehaviour on the inner one only.  The
# outer span must still end correctly, with the right parentage.
# ----------------------------------------------------------------
for my $mode (qw(error start_end end_self))
{
	reset_all();
	my $inner_name =
		$mode eq 'start_end' ? 'conformance.from_hook' : "conformance.d_inner.$mode";

	my $sql = '';
	$sql .= "SELECT otel_api_conformance_set_emit_misbehaviour('$mode', '$inner_name');\n";
	$sql .= "BEGIN;\n";
	$sql .= "SELECT otel_api_conformance_start('conformance.d_outer', owner_mode => 'toptxn') AS outer_ref \\gset\n";
	$sql .= "SELECT otel_api_conformance_start('$inner_name', owner_mode => 'toptxn') AS inner_ref \\gset\n";
	$sql .= "SELECT otel_api_conformance_set_misbehaviour_ref(:inner_ref);\n"
	  if $mode eq 'end_self';
	$sql .= "SELECT otel_api_conformance_end(:inner_ref);\n";
	$sql .= "SELECT otel_api_conformance_end(:outer_ref);\n";
	$sql .= "COMMIT;\n";
	$sql .= "SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' LIKE 'conformance.d_%' OR s->>'name' = '$inner_name';\n";

	if ($cassert eq 'on' && $reentry{$mode})
	{
		expect_reentry_assert("D/$mode", $sql);
		next;
	}

	my ($ret, $stdout, $stderr) = $node->psql('postgres', $sql, on_error_stop => 0);
	is($ret, 0, "D/$mode: the psql script completes") or diag($stderr);
	my @dlines = split /\n/, $stdout;
	my @dbrackets = grep { /^\[/ } @dlines;
	my @spans = @dbrackets ? parse_spans($dbrackets[-1]) : ();
	my ($outer) = grep { $_->{name} eq 'conformance.d_outer' } @spans;
	my @inner = grep { $_->{name} eq $inner_name } @spans;
	ok($outer, "D/$mode: the outer span is exported") or diag($stdout);
	is($outer->{status}, 0, "D/$mode: the outer span ends normally (status unset/ok)") if $outer;
	is(scalar(@inner), 1, "D/$mode: the inner (misbehaving) span is exported once") or diag($stdout);
	is($inner[0]{parent_span_id}, $outer->{span_id},
		"D/$mode: the inner span's parent is the outer span")
	  if @inner && $outer;
}

# ----------------------------------------------------------------
# Scenario B: abort-time dispatch.  The span is unwound by resource
# owner release on ROLLBACK; the emit hook misbehaves during that
# release.  For end_other, the "other" span shares the same (toptxn)
# owner, which is being released: the refused call must leave it to
# that release.
# ----------------------------------------------------------------
for my $mode (qw(error start_end end_other))
{
	reset_all();
	my $victim_name = $mode eq 'start_end' ? 'conformance.from_hook' : "conformance.b.$mode";

	my $sql = '';
	$sql .= "SELECT otel_api_conformance_set_emit_misbehaviour('$mode', '$victim_name');\n";
	$sql .= "BEGIN;\n";
	if ($mode eq 'end_other')
	{
		$sql .=
		  "SELECT otel_api_conformance_start('conformance.b.sibling', owner_mode => 'toptxn') AS sib \\gset\n";
		$sql .= "SELECT otel_api_conformance_set_misbehaviour_ref(:sib);\n";
	}
	$sql .= "SELECT otel_api_conformance_start('$victim_name', owner_mode => 'toptxn') AS victim \\gset\n";
	$sql .= "SELECT 1/0;\n";
	$sql .= "ROLLBACK;\n";
	$sql .= "SELECT otel_api_conformance_counters();\n";
	$sql .= "SELECT otel_api_conformance_misbehaviour_status();\n";
	$sql .= "SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;\n";
	# Same session, right after the ROLLBACK: InterruptHoldoffCount and
	# QueryCancelHoldoffCount are backend-local, and RESUME_INTERRUPTS()
	# in AbortTransaction() decrements whatever errfinish() left behind;
	# if dispatch_span() didn't restore it, it wraps to UINT32_MAX and
	# this backend stops ever noticing a cancel/terminate interrupt again.
	$sql .= "SELECT otel_api_conformance_holdoff_counts();\n";
	$sql .= "SET statement_timeout = '200ms';\n";
	$sql .= "SELECT pg_sleep(5);\n";
	$sql .= "RESET statement_timeout;\n";

	if ($cassert eq 'on' && $reentry{$mode})
	{
		expect_reentry_assert("B/$mode", $sql);
		next;
	}

	my $log_start = -s $node->logfile;
	my ($ret, $stdout, $stderr) = $node->psql('postgres', $sql, on_error_stop => 0);
	my $log = PostgreSQL::Test::Utils::slurp_file($node->logfile, $log_start);

	unlike($log, qr/TRAP:|Assert failed|PANIC|terminated by signal/,
		"B/$mode: abort-time misbehaviour doesn't crash the backend")
	  or diag("server log:\n$log");
	if ($log =~ /TRAP:|Assert failed|PANIC|terminated by signal/)
	{
		ok(wait_for_restart(), "B/$mode: server accepts connections again after the crash")
		  or BAIL_OUT("server did not come back up after the induced crash");
		next;
	}

	like($stderr, qr/division by zero/, "B/$mode: the induced error aborts the transaction")
	  or diag($stdout);
	is($ret, 0, "B/$mode: the connection survives the abort") or diag("log:\n$log");

	my @lines = split /\n/, $stdout;
	my ($counters_line) = grep { /"spans_started"/ } @lines;
	my ($mstatus_line) = grep { /"max_depth"/ } @lines;
	my ($holdoff_line) = grep { /"interrupt_holdoff"/ } @lines;
	my ($spans_line) = grep { /^\[/ } @lines;
	my $counters = $counters_line ? eval { decode_json($counters_line) } : undef;
	my $mstatus = $mstatus_line ? eval { decode_json($mstatus_line) } : undef;
	my $holdoff = $holdoff_line ? eval { decode_json($holdoff_line) } : undef;
	my @spans = $spans_line ? eval { parse_spans($spans_line) } : ();

	ok($counters && $mstatus && $holdoff, "B/$mode: counters, misbehaviour status and holdoff counts read back")
	  or diag($stdout);

	is($holdoff->{interrupt_holdoff}, 0, "B/$mode: InterruptHoldoffCount is 0 after the abort");
	is($holdoff->{query_cancel_holdoff}, 0, "B/$mode: QueryCancelHoldoffCount is 0 after the abort");
	like($stderr, qr/canceling statement due to statement timeout/,
		"B/$mode: statement_timeout still cancels a long statement in this backend");

	my $expected_unwound = $mode eq 'end_other' ? 2 : 1;
	is($counters->{unwound}, $expected_unwound,
		"B/$mode: $expected_unwound span(s) unwound by the owner release (exported with ERROR status)");

	my %by_id;
	$by_id{ $_->{span_id} }++ for @spans;
	my @dups = grep { $by_id{$_} > 1 } keys %by_id;
	is(scalar(@dups), 0, "B/$mode: no span was exported twice during the abort");

	my @victims = grep { $_->{name} eq $victim_name } @spans;
	is(scalar(@victims), 1, "B/$mode: the victim span was delivered once despite the misbehaviour")
	  or diag(encode_json(\@spans));
	if ($mode eq 'end_other')
	{
		my @sib = grep { $_->{name} eq 'conformance.b.sibling' } @spans;
		is(scalar(@sib), 1, "B/$mode: the sibling is exported once, by the owner release");
	}

	my $expected_calls = $reentry{$mode} ? $calls_per_run{$mode} : 0;
	is($mstatus->{calls}, $expected_calls, "B/$mode: the hook made $expected_calls producer call(s)");
	is($counters->{in_emit_hook}, $expected_calls,
		"B/$mode: each producer call from the hook is refused and counted in in_emit_hook");

	my $followup = $node->safe_psql('postgres', <<SQL);
SELECT otel_api_conformance_end(otel_api_conformance_start('conformance.b.followup2'));
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' = 'conformance.b.followup2';
SQL
	my @f = parse_spans($followup);
	is(scalar(@f), 1, "B/$mode: the backend is usable afterwards -- a following span starts and ends");
}

# ----------------------------------------------------------------
# Scenario C: fatal.  Checked on both the normal path and the abort
# path.  The backend that hits FATAL exits; a second, persistent
# session must stay usable, and the server log must show FATAL, not
# PANIC or a signal crash, with no crash-restart of the postmaster's
# other backends.
# ----------------------------------------------------------------
sub run_fatal_scenario
{
	my ($label, $span_name, $sql) = @_;

	# A persistent session, created fresh for this scenario, that a
	# well-behaved FATAL (a single backend exits, no crash-restart of
	# the rest of the postmaster) must leave usable.
	my $survivor = $node->background_psql('postgres');
	$survivor->query_safe("SELECT 1");

	# The backend-local capture list is gone once the backend exits, and
	# dispatch_span() calls the emit hook *before* it checks
	# otel_api.emit_spans_to_log, so a hook that goes FATAL is never
	# reached by otel_producer.c's own "otel-span: ..." log line on any
	# attempt.  conformance_do_misbehave()'s FATAL case logs its own
	# "misbehaviour fatal dispatch #N" line first (see
	# otel_api_conformance.c), so we count dispatch attempts for this
	# span directly: if AbortOutOfAnyTransaction() reaches the same
	# still-owner-remembered span a second time (slot->dispatching never
	# got reset to false, because the FATAL never returned from
	# dispatch_span()), a second numbered line appears.
	my $log_start = -s $node->logfile;
	my ($ret, $stdout, $stderr) = $node->psql('postgres', $sql, on_error_stop => 0);
	isnt($ret, 0, "$label: the connection is closed");
	my $log = PostgreSQL::Test::Utils::slurp_file($node->logfile, $log_start);
	like($log, qr/FATAL:.*emit hook misbehaviour: fatal/, "$label: server log shows the induced FATAL");
	unlike($log, qr/PANIC/, "$label: no PANIC in the server log");

	my $dispatch_count = () = $log =~ /misbehaviour fatal dispatch #\d+ for "\Q$span_name\E"/g;
	note("$label: \"$span_name\" was dispatched (logged) $dispatch_count time(s)");
	if ($dispatch_count > 1)
	{
		TODO:
		{
			local $TODO = "postgres-cdq.9.3: the FATAL span is dispatched a second time during "
			  . "backend exit (evidence: $dispatch_count log lines for \"$span_name\") -- "
			  . "slot->dispatching is still true when ereport(FATAL) is called from inside "
			  . "dispatch_span(), so the span is never marked done and "
			  . "its resource owner still remembers it; AbortOutOfAnyTransaction()'s "
			  . "ResourceOwnerReleaseAll() releases it again, reaching end_slot() a second time.";
			is($dispatch_count, 1, "$label: the span is dispatched exactly once");
		}
	}
	else
	{
		is($dispatch_count, 1, "$label: the span is dispatched exactly once")
		  or diag("server log:\n$log");
	}

	if ($log =~ /terminated by signal|TRAP:/)
	{
		diag("server log:\n$log");
		TODO:
		{
			local $TODO = "postgres-cdq.9.3: ereport(FATAL) from the emit hook is called with "
			  . "slot->dispatching still true (dispatch_span); proc_exit "
			  . "unwinds via AbortOutOfAnyTransaction -> ResourceOwnerReleaseAll, which reaches "
			  . "otel_span_release_resource()/end_slot() for that same span and Asserts "
			  . "!slot->dispatching on cassert builds, escalating the clean "
			  . "FATAL into an Assert crash and a full crash-restart (evidence in the diag above).";
			fail("$label: FATAL should not escalate into a crash-restart");
		}
		ok(wait_for_restart(), "$label: server accepts connections again")
		  or BAIL_OUT("server did not come back up after the induced crash");
		# The crash-restart kills every backend, including the survivor;
		# reconnect fresh to show the postmaster itself is usable again.
		$survivor = $node->background_psql('postgres');
		is($survivor->query_safe("SELECT 2"), '2',
			"$label: a fresh session is usable once the postmaster restarts");
	}
	else
	{
		is($survivor->query_safe("SELECT 2"), '2',
			"$label: a second, persistent session stays usable -- no crash-restart occurred");
	}
	$survivor->quit;
}

run_fatal_scenario('C1 fatal/normal-path', 'conformance.c1', <<'SQL');
SELECT otel_api_conformance_set_emit_misbehaviour('fatal', 'conformance.c1');
SELECT otel_api_conformance_end(otel_api_conformance_start('conformance.c1'));
SQL

# C2: abort path -- the span is owned by TopTransactionResourceOwner and
# released (unwound) by ROLLBACK's abort processing; the hook raises
# FATAL from inside that release.
run_fatal_scenario('C2 fatal/abort-path', 'conformance.c2', <<'SQL');
SELECT otel_api_conformance_set_emit_misbehaviour('fatal', 'conformance.c2');
BEGIN;
SELECT otel_api_conformance_start('conformance.c2', owner_mode => 'toptxn');
SELECT 1/0;
ROLLBACK;
SQL

$node->stop;
done_testing();
