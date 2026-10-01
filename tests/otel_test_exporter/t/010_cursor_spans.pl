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
# after DECLARE, before any FETCH ever runs.
#
# In a cassert build this is not just a WARNING, it is
# Assert(false) in nonlifo_warning(): DECLARE CURSOR alone crashes the
# backend. See otel_producer.c's nonlifo_warning().  This file
# confirms that pre-fix behaviour, then (once postgres-cdq.10's
# otel_postgres_tracing changes land) exercises the fixed behaviour:
# the cursor span is .detached and is otel_span_activate()d only
# around each FETCH's ExecutorRun, so it stays open across statements
# and FETCH's work correctly nests under it.
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
	  # Pre-fix, a cassert build crashes the backend with an Assert on
	  # plain DECLARE CURSOR; the test waits out the crash.
	  . "restart_after_crash = on\n"
	  . "log_min_messages = warning\n");
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_postgres_tracing; CREATE EXTENSION test_otel_exporter'
);

my $cassert = $node->safe_psql('postgres', 'SHOW debug_assertions');
note("debug_assertions = $cassert");

# See t/008_misuse.pl (otel_api_conformance) for the rationale: retry
# until the postmaster is accepting connections again, rather than
# scanning the log for timing.
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

# ----------------------------------------------------------------------
# Scenario 1: plain DECLARE CURSOR, no FETCH yet.
# ----------------------------------------------------------------------

if ($cassert eq 'on')
{
	my $log_start = -s $node->logfile;
	my ($ret, $stdout, $stderr) = $node->psql(
		'postgres', q{
			SET otel.trace_all_queries = on;
			BEGIN;
			DECLARE c CURSOR FOR SELECT i FROM generate_series(1,5) i;
		},
		on_error_stop => 0);
	isnt($ret, 0,
		'pre-fix: DECLARE CURSOR crashes a cassert backend (connection lost)'
	);
	ok(wait_for_restart(), 'postmaster recovered after the crash');
	my $log = PostgreSQL::Test::Utils::slurp_file($node->logfile, $log_start);
	like(
		$log,
		qr/TRAP: failed Assert\("false"\).*otel_producer\.c/s,
		'pre-fix: the crash is otel_api\'s non-LIFO Assert, not something else'
	);
	like(
		$log,
		qr/otel_api: span ended with spans still open above it/,
		'pre-fix: the non-LIFO WARNING is logged just before the crash');
}
else
{
	$node->safe_psql('postgres', 'SELECT test_otel_clear()');
	my $log_offset = -s $node->logfile;
	$node->safe_psql(
		'postgres', q{
			SET otel.trace_all_queries = on;
			BEGIN;
			DECLARE c CURSOR FOR SELECT i FROM generate_series(1,5) i;
			FETCH 1 FROM c;
			FETCH 1 FROM c;
			CLOSE c;
			COMMIT;
		});
	my $log = PostgreSQL::Test::Utils::slurp_file($node->logfile, $log_offset);
	# pre-fix: the non-LIFO WARNING fires right after DECLARE.
	like(
		$log,
		qr/otel_api: span ended with spans still open above it/,
		'pre-fix (non-cassert): non-LIFO WARNING logged for DECLARE CURSOR'
	);

	# pre-fix: the cursor's own "pgsql.execute" span (db.query.text is
	# the DECLARE's query) was unwound -- exported with ERROR status --
	# immediately, instead of staying open across the FETCHes.
	my $span = $node->safe_psql(
		'postgres', q{
			SET otel.trace_all_queries = on;
			SELECT test_otel_clear();
			BEGIN;
			DECLARE c CURSOR FOR SELECT i FROM generate_series(1,5) i;
			FETCH 1 FROM c;
			CLOSE c;
			COMMIT;
			SELECT test_otel_pop_span_by_name('pgsql.execute');
		});

	# The ring is FIFO; the first "pgsql.execute"-named span popped
	# should (post-fix) be the cursor's own span, still showing the
	# DECLARE's query text, but now ended normally (status=0) after
	# CLOSE, not unwound with ERROR (status=2) right after DECLARE.
	like(
		$span,
		qr/db\.query\.text=DECLARE c CURSOR/,
		'the DECLARE-cursor span is the one inspected below');
	TODO:
	{
		local $TODO = 'postgres-cdq.10: cursor span not yet .detached';
		unlike($span, qr/status=2/,
			'cursor span is not unwound with ERROR status before FETCH runs'
		);
	}
}

done_testing();
