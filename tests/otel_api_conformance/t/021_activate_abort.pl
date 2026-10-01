# Copyright (c) 2026, PostgreSQL Global Development Group
#
# otel_span_activate()/otel_span_deactivate(): abort- and unwind-time
# safety (postgres-cdq.10 review follow-up).
#
# Defect 1 -- abort with an activation still pushed.  Nothing pops an
# activation entry at (sub)transaction abort unless the span's own
# owner happens to be released too (otel_span_release_resource) or,
# for an unsampled span, drop_nrecs_from_level.  A .detached span owned
# by a longer-lived owner (session, a portal, TopTransactionResource-
# Owner across a SAVEPOINT abort) stays on the active stack after an
# ERROR between otel_span_activate() and otel_span_deactivate() in
# code with no PG_FINALLY -- every later span then wrongly parents to
# it, and it is never "current" again correctly once the real owner
# eventually ends it.
#
# Defect 2 -- unwinding through an activation ends the span.
# stack_unwind_above() (called from otel_span_end()/otel_span_
# deactivate() on a LIFO violation) must not end_slot()/free_nrec() an
# activation entry above the unwound position: that entry only names a
# span another component still owns (e.g. a cursor's executor span);
# ending it out from under that owner is exactly the kind of bug
# postgres-cdq.10 exists to prevent in the first place.
#
# A genuine LIFO violation is, like every other one in this suite
# (e.g. t/009_multi_producer.pl), an Assert(false) in
# nonlifo_warning() on a cassert build -- and that Assert fires
# *before* stack_unwind_above() ever runs, so defect 2's "pop, don't
# end" behaviour can only be observed on a non-cassert build; on
# cassert it is (like any other LIFO violation) just a crash. Defect
# 2's scenarios are written check_misuse()-style accordingly.
#
# Scenarios call otel_api_conformance_start()/_activate()/_deactivate()
# /_span_current()/_recording()/_end() directly -- no new C helper
# needed. State is backend-local (see t/001's header comment) so each
# scenario reads back its result in the same psql invocation. A span
# meant to survive across several top-level statements needs
# owner_mode => 'session' (see t/001's header comment); one that only
# needs to survive within a single statement is built as
# otel_api_conformance_end(otel_api_conformance_start(...)), both in
# the same statement.

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
	  . "restart_after_crash = on\n");
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

# See t/008_misuse.pl (otel_api_conformance) for the rationale (retry
# until the postmaster is accepting connections again, rather than
# scanning the log for timing).
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

# ----------------------------------------------------------------
# Defect 1a: top-level abort.  activate() then an ERROR, no
# deactivate(), ROLLBACK.  The activation must be gone afterwards (not
# left pointing at a stale/reused slot), the span itself must still be
# open (session-owned, so the abort doesn't end it), and a fresh span
# must not wrongly parent to it.
# ----------------------------------------------------------------
{
	my ($ret, $stdout, $stderr) = $node->psql(
		'postgres', <<'SQL',
SELECT otel_api_conformance_reset() AS r1 \gset
BEGIN;
SELECT otel_api_conformance_start('conformance.activate.abort.toplevel', owner_mode := 'session', detached := true) AS s \gset
SELECT otel_api_conformance_activate(:s) AS tok \gset
SELECT 1/0;
ROLLBACK;
SELECT otel_api_conformance_span_current() AS cur;
SELECT otel_api_conformance_recording(:s) AS still_recording;
SELECT otel_api_conformance_end(otel_api_conformance_start('conformance.activate.abort.followup'));
SELECT jsonb_agg(sp) FROM otel_api_conformance_spans() sp WHERE sp->>'name' = 'conformance.activate.abort.followup';
SELECT otel_api_conformance_end(:s);
SQL
		on_error_stop => 0);
	like($stderr, qr/division by zero/,
		'top-level abort: the induced error aborts the transaction');

	my @lines = grep { length } split /\n/, $stdout;
	is($lines[0], '0',
		'top-level abort: no activation left on the active stack afterwards')
	  or diag("stdout: $stdout");
	is($lines[1], 't',
		'top-level abort: the session-owned span is still open (not ended by the abort)'
	);

	my @followup = parse_spans($lines[2]);
	is(scalar(@followup), 1, 'top-level abort: the follow-up span was captured');
	is($followup[0]->{parent_span_id}, '0000000000000000',
		'top-level abort: the follow-up span does NOT parent to the leaked activation'
	) if @followup;
}

# ----------------------------------------------------------------
# Defect 1b: subtransaction abort (SAVEPOINT / ROLLBACK TO).  Same
# shape, but only the inner subtransaction aborts; the outer
# transaction, and the session-owned span, survive.
# ----------------------------------------------------------------
{
	my ($ret, $stdout, $stderr) = $node->psql(
		'postgres', <<'SQL',
SELECT otel_api_conformance_reset() AS r1 \gset
BEGIN;
SELECT otel_api_conformance_start('conformance.activate.abort.subxact', owner_mode := 'session', detached := true) AS s \gset
SAVEPOINT sp1;
SELECT otel_api_conformance_activate(:s) AS tok \gset
SELECT 1/0;
ROLLBACK TO SAVEPOINT sp1;
SELECT otel_api_conformance_span_current() AS cur;
SELECT otel_api_conformance_recording(:s) AS still_recording;
SELECT otel_api_conformance_end(otel_api_conformance_start('conformance.activate.abort.subxact.followup'));
SELECT jsonb_agg(sp) FROM otel_api_conformance_spans() sp WHERE sp->>'name' = 'conformance.activate.abort.subxact.followup';
COMMIT;
SELECT otel_api_conformance_end(:s);
SQL
		on_error_stop => 0);
	like($stderr, qr/division by zero/,
		'subxact abort: the induced error aborts the subtransaction');

	my @lines = grep { length } split /\n/, $stdout;
	is($lines[0], '0',
		'subxact abort: no activation left on the active stack afterwards')
	  or diag("stdout: $stdout");
	is($lines[1], 't',
		'subxact abort: the session-owned span is still open (ROLLBACK TO does not end it)'
	);

	my @followup = parse_spans($lines[2]);
	is(scalar(@followup), 1,
		'subxact abort: the follow-up span was captured');
	is($followup[0]->{parent_span_id}, '0000000000000000',
		'subxact abort: the follow-up span does NOT parent to the leaked activation')
	  if @followup;
}

# ----------------------------------------------------------------
# Defect 1c: a plpgsql EXCEPTION block (an implicit SAVEPOINT/ROLLBACK
# TO under the hood).  Self-checking: RAISEs if the activation leaked
# across the EXCEPTION handler.
# ----------------------------------------------------------------
{
	my ($ret, $stdout, $stderr) = $node->psql(
		'postgres', <<'SQL',
SELECT otel_api_conformance_reset();
DO $do$
DECLARE
	s bigint;
	tok bigint;
BEGIN
	s := otel_api_conformance_start('conformance.activate.abort.plpgsql',
		owner_mode := 'session', detached := true);
	BEGIN
		tok := otel_api_conformance_activate(s);
		PERFORM 1/0;
	EXCEPTION WHEN division_by_zero THEN
		NULL;
	END;
	IF otel_api_conformance_span_current() <> 0 THEN
		RAISE EXCEPTION 'activation leaked across a plpgsql EXCEPTION block';
	END IF;
	IF NOT otel_api_conformance_recording(s) THEN
		RAISE EXCEPTION 'the session-owned span was wrongly ended';
	END IF;
	PERFORM otel_api_conformance_end(s);
END
$do$;
SQL
		on_error_stop => 0);
	is($ret, 0, 'plpgsql EXCEPTION block: no activation leak, no crash')
	  or diag("stderr: $stderr");
}

# ----------------------------------------------------------------
# Defect 1d: the unsampled (nrec) variant -- same top-level-abort
# shape, with otel_api.sampler = 'always_off'.
# ----------------------------------------------------------------
{
	my ($ret, $stdout, $stderr) = $node->psql(
		'postgres', <<'SQL',
SELECT otel_api_conformance_reset() AS r1 \gset
SET otel_api.sampler = 'always_off';
BEGIN;
SELECT otel_api_conformance_start('conformance.activate.abort.nrec', owner_mode := 'session', detached := true) AS s \gset
SELECT :s < 0 AS unsampled;
SELECT otel_api_conformance_activate(:s) AS tok \gset
SELECT 1/0;
ROLLBACK;
SET otel_api.sampler = 'always_off';
SELECT otel_api_conformance_span_current() AS cur;
SELECT otel_api_conformance_end(:s);
SQL
		on_error_stop => 0);
	like($stderr, qr/division by zero/,
		'nrec variant: the induced error aborts the transaction');

	my @lines = grep { length } split /\n/, $stdout;
	is($lines[0], 't', 'nrec variant: the span is unsampled (negative handle)');
	is($lines[1], '0',
		'nrec variant: no activation left on the active stack afterwards')
	  or diag("stdout: $stdout");
}

# ----------------------------------------------------------------
# Defect 2: unwinding through an activation must pop it, not end the
# span it names.  A (detached, activated), B (detached, activated):
# deactivating A while B is still active is a LIFO violation.  On a
# cassert build that is (like any other LIFO violation) a crash,
# before stack_unwind_above() even runs; on a non-cassert build it
# must leave B still open, to be exported normally later -- not ended
# out from under its owner right there.
# ----------------------------------------------------------------
{
	my $sql = <<'SQL';
SELECT otel_api_conformance_reset();
BEGIN;
SELECT otel_api_conformance_start('conformance.activate.unwind.a', owner_mode := 'session', detached := true) AS a \gset
SELECT otel_api_conformance_activate(:a) AS tok_a \gset
SELECT otel_api_conformance_start('conformance.activate.unwind.b', owner_mode := 'session', detached := true) AS b \gset
SELECT otel_api_conformance_activate(:b) AS tok_b \gset
SELECT otel_api_conformance_deactivate(:tok_a);
SQL

	if ($cassert eq 'on')
	{
		my $log_start = -s $node->logfile;
		my ($ret, $stdout, $stderr) = $node->psql('postgres', $sql);
		isnt($ret, 0,
			'defect 2: deactivating out of order crashes a cassert backend (same as any LIFO violation)'
		);
		my $log = PostgreSQL::Test::Utils::slurp_file($node->logfile, $log_start);
		like($log, qr/TRAP:|Assert/, 'defect 2: server log shows an Assert failure');
		ok(wait_for_restart(), 'defect 2: server accepts connections again')
		  or BAIL_OUT("server did not come back up after the induced crash");
	}
	else
	{
		my ($ret, $stdout, $stderr) = $node->psql('postgres',
			$sql . <<'SQL');
SELECT otel_api_conformance_recording(:b) AS b_still_open;
SELECT otel_api_conformance_end(:b);
SELECT jsonb_agg(sp) FROM otel_api_conformance_spans() sp WHERE sp->>'name' = 'conformance.activate.unwind.b';
SELECT otel_api_conformance_end(:a);
COMMIT;
SQL
		is($ret, 0, 'defect 2: completes without crashing (non-cassert build)')
		  or diag("stderr: $stderr");
		my @lines = grep { length } split /\n/, $stdout;
		is($lines[0], 't',
			'defect 2: B is still open after the LIFO-violating deactivate unwound past it'
		);
		my @b = parse_spans($lines[1]);
		is(scalar(@b), 1, 'defect 2: B was exported exactly once');
		isnt($b[0]->{status}, 2,
			'defect 2: B ends with its own normal status, not forced ERROR from being unwound'
		) if @b;
	}
}

# ----------------------------------------------------------------
# Defect 2, variant: a started (non-activation) span above an
# activation keeps the existing behaviour when unwound: it IS ended
# (as unwound, ERROR status) -- only activation entries get the "pop,
# don't end" treatment.
# ----------------------------------------------------------------
{
	my $sql = <<'SQL';
SELECT otel_api_conformance_reset();
BEGIN;
SELECT otel_api_conformance_start('conformance.activate.unwind.started_above.a', owner_mode := 'session', detached := true) AS a \gset
SELECT otel_api_conformance_activate(:a) AS tok_a \gset
SELECT otel_api_conformance_start('conformance.activate.unwind.started_above.c', owner_mode := 'session') AS c \gset
SELECT otel_api_conformance_deactivate(:tok_a);
SQL

	if ($cassert eq 'on')
	{
		my $log_start = -s $node->logfile;
		my ($ret, $stdout, $stderr) = $node->psql('postgres', $sql);
		isnt($ret, 0,
			'defect 2 variant: deactivating out of order crashes a cassert backend'
		);
		my $log = PostgreSQL::Test::Utils::slurp_file($node->logfile, $log_start);
		like($log, qr/TRAP:|Assert/,
			'defect 2 variant: server log shows an Assert failure');
		ok(wait_for_restart(), 'defect 2 variant: server accepts connections again')
		  or BAIL_OUT("server did not come back up after the induced crash");
	}
	else
	{
		my ($ret, $stdout, $stderr) = $node->psql('postgres',
			$sql . <<'SQL');
SELECT jsonb_agg(sp) FROM otel_api_conformance_spans() sp WHERE sp->>'name' = 'conformance.activate.unwind.started_above.c';
SELECT otel_api_conformance_end(:a);
COMMIT;
SQL
		is($ret, 0, 'defect 2 variant: completes without crashing (non-cassert build)')
		  or diag("stderr: $stderr");
		my @lines = grep { length } split /\n/, $stdout;
		my @c = parse_spans($lines[0]);
		is(scalar(@c), 1,
			'defect 2 variant: a started span above the deactivated activation is unwound (ended) as before'
		);
		is($c[0]->{status}, 2,
			'defect 2 variant: ...with ERROR status, unlike an unwound activation')
		  if @c;
	}
}

done_testing();
