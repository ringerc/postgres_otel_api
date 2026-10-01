# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Cross-statement cursor spans (DECLARE .. FETCH .. CLOSE).  otel_api
# P2 edge-case plan, postgres-cdq.10 / postgres-cdq.9.7 / postgres-cdq.9.16.
#
# A cursor's underlying "pgsql.execute" span is started by ExecutorStart
# at DECLARE time and only ended by ExecutorEnd at CLOSE time, but every
# statement in between (the DECLARE's own utility span, each FETCH's
# utility span, ...) pushes and pops its own span on otel_api's active
# stack.  Before postgres-cdq.10, that cursor span was not .detached,
# so it sat on the active stack across the statement boundary: as soon
# as the DECLARE statement's own wrapping span tried to end (it is
# BELOW the still-open cursor span on the stack, since the cursor
# executor span was pushed inside it and never popped), otel_api's
# "ended with spans still open above it" non-LIFO path fired --
# unwinding (exporting with ERROR status) the cursor's own span right
# after DECLARE, before any FETCH ever runs.  In a cassert build that
# path is not just a WARNING, it is Assert(false) in
# nonlifo_warning(): DECLARE CURSOR alone crashed the backend (see
# otel_producer.c's nonlifo_warning()).
#
# postgres-cdq.10 fixes this: the cursor's executor span is now
# .detached (otel_declaring_cursor_portal in otel_trace.c), and
# otel_ExecutorRun() calls otel_span_activate()/otel_span_deactivate()
# around just the one ExecutorRun call that belongs to each FETCH, so
# work done while materialising rows parents to the cursor span, and
# the span itself stays open from DECLARE to CLOSE.
#
# Spans/counters are backend-local (see t/001's header comment): each
# scenario below is one psql invocation/connection so capture and
# readback see the same backend.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'otel_api,otel_postgres_tracing,test_otel_exporter'\n"
	  . "restart_after_crash = on\n"
	  . "log_min_messages = warning\n");
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_postgres_tracing; CREATE EXTENSION test_otel_exporter'
);

my $cassert = $node->safe_psql('postgres', 'SHOW debug_assertions');
note("debug_assertions = $cassert");

# ----------------------------------------------------------------------
# Scenario 1: plain DECLARE CURSOR, no FETCH yet.  Pre-fix this alone
# crashed a cassert backend (and logged the non-LIFO WARNING on every
# build); post-fix, neither happens.
# ----------------------------------------------------------------------

{
	my $log_start = -s $node->logfile;
	my ($ret, $stdout, $stderr) = $node->psql(
		'postgres', q{
			SET otel.trace_all_queries = on;
			BEGIN;
			DECLARE c CURSOR FOR SELECT i FROM generate_series(1,5) i;
			CLOSE c;
			COMMIT;
		},
		on_error_stop => 0);
	is($ret, 0, 'DECLARE CURSOR no longer crashes/errors (fixed)');
	my $log = PostgreSQL::Test::Utils::slurp_file($node->logfile, $log_start);
	unlike(
		$log,
		qr/otel_api: span ended with spans still open above it/,
		'no non-LIFO WARNING for a plain DECLARE CURSOR .. CLOSE');
	unlike($log, qr/TRAP:|Assert/, 'no Assert/crash in the log');
}

# ----------------------------------------------------------------------
# Scenario 2: the cursor's span stays open across FETCHes, and ends
# normally (status UNSET, not ERROR) only at CLOSE.  Also: a WARNING
# raised while materialising a FETCH's rows attaches to the cursor
# span, not the FETCH utility span or nothing -- proof that the cursor
# span is the active parent during the FETCH's ExecutorRun.
# ----------------------------------------------------------------------

{
	$node->safe_psql(
		'postgres', q{
			CREATE OR REPLACE FUNCTION cursor_test_warn(i int) RETURNS int AS $f$
			BEGIN
				RAISE WARNING 'from fetch %', i;
				RETURN i;
			END $f$ LANGUAGE plpgsql;
		});

	my $log_start = -s $node->logfile;
	my $out = $node->safe_psql(
		'postgres', q{
			SET otel.trace_all_queries = on;
			SELECT test_otel_clear();
			BEGIN;
			DECLARE c CURSOR FOR SELECT cursor_test_warn(i) FROM generate_series(1,2) i;
			FETCH 1 FROM c;
			FETCH 1 FROM c;
			CLOSE c;
			COMMIT;
			SELECT test_otel_pop_span_by_name('pgsql.execute')
			  FROM generate_series(1, 20);
		});
	my $log = PostgreSQL::Test::Utils::slurp_file($node->logfile, $log_start);
	unlike($log, qr/otel_api: span ended with spans still open above it/,
		'no non-LIFO WARNING while fetching from the cursor');

	# Find the span whose db.query.text is the DECLARE (the ring also
	# holds "SELECT test_otel_clear()" and the SELECT
	# test_otel_pop_span_by_name() calls' own spans, all also named
	# "pgsql.execute").
	my ($cursor_span) = grep { /db\.query\.text=DECLARE c CURSOR/ }
	  split /(?=scope\.name=)/, $out;
	ok(defined $cursor_span, 'found the cursor\'s own span in the ring');

	like($cursor_span, qr/status=0\n/,
		'cursor span ends normally (UNSET), not unwound with ERROR');
	like(
		$cursor_span,
		qr/event\.name=exception\n/,
		'a WARNING raised during FETCH is captured as an event');
	# slot_record_error() (otel_producer.c) keeps the latest message on
	# a tie (both are WARNING-level), so "from fetch 2" (the second
	# FETCH's warning) is what is captured -- on the cursor span
	# itself, not on either FETCH's own utility span or nowhere: proof
	# that the cursor span is the active parent throughout the
	# FETCHes, not just the first one.
	like(
		$cursor_span,
		qr/event\.attr=exception\.message=from fetch 2/,
		'...the WARNING from a FETCH lands on the cursor span itself (parentage proof)'
	);
}

# ----------------------------------------------------------------------
# Scenario 3: two cursors, opened and closed out of order.
# ----------------------------------------------------------------------

{
	my $log_start = -s $node->logfile;
	my $out = $node->safe_psql(
		'postgres', q{
			SET otel.trace_all_queries = on;
			BEGIN;
			DECLARE a CURSOR FOR SELECT i FROM generate_series(1,3) i;
			DECLARE b CURSOR FOR SELECT i FROM generate_series(10,13) i;
			FETCH 1 FROM a;
			FETCH 1 FROM b;
			FETCH 1 FROM a;
			CLOSE b;
			FETCH 1 FROM a;
			CLOSE a;
			COMMIT;
		});
	my $log = PostgreSQL::Test::Utils::slurp_file($node->logfile, $log_start);
	unlike($log, qr/otel_api: span ended with spans still open above it/,
		'two interleaved cursors, closed out of order: no non-LIFO WARNING'
	);
	unlike($log, qr/TRAP:|Assert/, 'no crash');
}

# ----------------------------------------------------------------------
# Scenario 4: a WITH HOLD cursor survives COMMIT and is still fetchable
# afterwards (PersistHoldablePortal() re-runs the executor via
# ExecutorRun, exercised through the same activate/deactivate path).
# ----------------------------------------------------------------------

{
	my $log_start = -s $node->logfile;
	my $out = $node->safe_psql(
		'postgres', q{
			SET otel.trace_all_queries = on;
			BEGIN;
			DECLARE h CURSOR WITH HOLD FOR SELECT i FROM generate_series(1,5) i;
			FETCH 1 FROM h;
			COMMIT;
			FETCH 1 FROM h;
			CLOSE h;
		});
	my $log = PostgreSQL::Test::Utils::slurp_file($node->logfile, $log_start);
	unlike($log, qr/otel_api: span ended with spans still open above it/,
		'WITH HOLD cursor across COMMIT: no non-LIFO WARNING');
	unlike($log, qr/TRAP:|Assert/, 'no crash');
}

# ----------------------------------------------------------------------
# Scenario 5: a FETCH that errors deactivates the cursor span cleanly
# (PG_FINALLY in otel_ExecutorRun()) rather than crashing or leaving
# the active stack imbalanced.
#
# Note: recovering the session afterwards (ROLLBACK, or ROLLBACK TO
# SAVEPOINT) while otel.trace_all_queries is on hits an unrelated,
# pre-existing defect in otel_trace.c's start_stmt_span(): it calls
# get_database_name() unconditionally, which asserts
# IsTransactionState() and crashes when a utility statement's span is
# started while the transaction is in aborted-block state (i.e. for
# the ROLLBACK/ROLLBACK TO SAVEPOINT that recovers from *any* error
# inside an explicit BEGIN, not just a cursor's). That is out of scope
# for postgres-cdq.10 (not related to otel_span_activate/deactivate or
# .detached) and is not exercised further here; this scenario only
# checks the FETCH error itself, not recovery from it.
# ----------------------------------------------------------------------

{
	my $log_start = -s $node->logfile;
	my ($ret, $stdout, $stderr) = $node->psql(
		'postgres', q{
			SET otel.trace_all_queries = on;
			BEGIN;
			DECLARE e CURSOR FOR SELECT 1/(i-2) FROM generate_series(1,3) i;
			FETCH 1 FROM e;
			FETCH 1 FROM e;
		},
		on_error_stop => 0);
	like($stderr, qr/division by zero/,
		'the second FETCH reports the division-by-zero error');
	my $log = PostgreSQL::Test::Utils::slurp_file($node->logfile, $log_start);
	unlike($log, qr/TRAP:|Assert/,
		'no crash from the erroring FETCH itself');

	# The postmaster, and other backends, are unaffected.
	is($node->safe_psql('postgres', 'SELECT 1'), '1',
		'the postmaster is healthy after the erroring FETCH');
}

done_testing();
