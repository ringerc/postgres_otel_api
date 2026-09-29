# Copyright (c) 2026, PostgreSQL Global Development Group
#
# plpgsql recursion: a span open *across* a recursive call (started
# before recursing, ended after it returns), at depths that stay
# within otel_api's limits, exceed otel_api.max_open_spans/the active
# stack depth, hit an ERROR caught partway down by a plpgsql EXCEPTION
# block, hit core's own "stack depth limit exceeded", and run
# unsampled.  Task brief "1. plpgsql recursion".
#
# otel_api_conformance_with_span(name, sql) is the C helper: it
# starts a span, runs `sql` via SPI (which may recurse straight back
# into a plpgsql wrapper that calls this function again), and ends the
# span -- so the span's lifetime spans the whole recursive call below
# it.  A default-owner span would normally be released at the end of
# its own statement (see t/001_construction.pl's header comment); that
# doesn't apply here because start and end happen inside the SAME C
# function call, which is itself inside one outer SQL statement.
#
# conformance_recurse(level, max_depth, catch_level, raise_at_bottom)
# is a plpgsql helper (created below) that, at each level, opens a span
# via with_span() around the call to the next level; at catch_level it
# wraps that one recursive call in an EXCEPTION block; past max_depth
# it either returns (raise_at_bottom = false) or RAISEs (true).
#
# Every scenario ends with a same-connection "clean" check: the active
# stack is empty (otel_api_conformance_span_current() = 0), and no
# unexpected non_lifo_end/stale_handle counters.

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
max_stack_depth = '7MB'
EOCONF
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_api_conformance');

$node->safe_psql('postgres', <<'SQL');
CREATE FUNCTION conformance_recurse(level int, max_depth int,
	catch_level int DEFAULT -1, raise_at_bottom boolean DEFAULT false)
RETURNS void AS $BODY$
BEGIN
	IF level > max_depth THEN
		IF raise_at_bottom THEN
			RAISE EXCEPTION 'otel_api_conformance recursion bottom reached'
				USING ERRCODE = 'RC000';
		END IF;
		RETURN;
	END IF;
	IF level = catch_level THEN
		-- The catch level's span, the subtransaction that catches the
		-- error, and the after-catch child all live inside one C call,
		-- as they would in C code using PG_TRY.  Starting a stack span in
		-- one plpgsql statement and ending it in another would not be
		-- LIFO once another producer wraps each statement in its own
		-- span (otel_postgres_tracing does).
		PERFORM otel_api_conformance_with_span_catch('level_' || level,
			format('SELECT conformance_recurse(%s,%s,%s,%L)',
				level + 1, max_depth, catch_level, raise_at_bottom),
			'level_' || level || '_after_catch');
	ELSE
		PERFORM otel_api_conformance_with_span('level_' || level,
			format('SELECT conformance_recurse(%s,%s,%s,%L)',
				level + 1, max_depth, catch_level, raise_at_bottom));
	END IF;
END;
$BODY$ LANGUAGE plpgsql;

CREATE FUNCTION conformance_recurse_entry(max_depth int,
	catch_level int DEFAULT -1, raise_at_bottom boolean DEFAULT false)
RETURNS void AS $BODY$
BEGIN
	PERFORM otel_api_conformance_with_span('level_1',
		format('SELECT conformance_recurse(2,%s,%s,%L)',
			max_depth, catch_level, raise_at_bottom));
END;
$BODY$ LANGUAGE plpgsql;
SQL

my $cassert = $node->safe_psql('postgres', 'SHOW debug_assertions');
note("debug_assertions = $cassert");

my $sampled_traceparent =
  '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01';
my $unsampled_traceparent =
  '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00';

sub parse_spans
{
	my ($out) = @_;
	return () if !defined $out || $out eq '';
	return @{ decode_json($out) };
}

sub counters
{
	my ($out) = @_;
	return decode_json($out);
}

# Same-connection clean check: run as the LAST few statements of the
# scenario's own psql invocation, right after otel_api_conformance_reset()
# would have wiped things -- so instead we take a counters-before/after
# delta, passed in by the caller.
sub check_clean
{
	my ($desc, $span_current, $c_before, $c_after) = @_;

	is($span_current, '0', "$desc: active stack is empty afterwards");
	is($c_after->{non_lifo_end} - $c_before->{non_lifo_end}, 0,
		"$desc: no unexpected non_lifo_end");
	is($c_after->{stale_handle} - $c_before->{stale_handle}, 0,
		"$desc: no unexpected stale_handle");
}

# ----------------------------------------------------------------
# (a) Depth 10, sampled: 10 spans, correct parent chain, LIFO clean.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<SQL);
SET otel_api.traceparent = '$sampled_traceparent';
SELECT otel_api_conformance_reset() AS _r \\gset
SELECT otel_api_conformance_counters() AS c_before \\gset
SELECT conformance_recurse_entry(10) AS _r \\gset
SELECT otel_api_conformance_span_current() AS cur \\gset
SELECT otel_api_conformance_counters() AS c_after \\gset
SELECT :cur AS cur, :'c_before' AS c_before, :'c_after' AS c_after;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my ($status_line, $spans_line) = split /\n/, $out, 2;
	my ($cur, $c_before_j, $c_after_j) = split /\|/, $status_line;
	my $c_before = counters($c_before_j);
	my $c_after  = counters($c_after_j);
	my @s = parse_spans($spans_line);

	is(scalar(@s), 10, '(a) depth 10: exactly 10 spans recorded');
	my %by_name = map { $_->{name} => $_ } @s;
	for my $n (1 .. 10)
	{
		ok(exists $by_name{"level_$n"}, "(a) level_$n span exists");
	}
	for my $n (2 .. 10)
	{
		is($by_name{"level_$n"}->{parent_span_id},
			$by_name{"level_" . ($n - 1)}->{span_id},
			"(a) level_$n parents to level_" . ($n - 1));
	}
	is($by_name{level_1}->{parent_span_id}, '00f067aa0ba902b7',
		'(a) level_1 parents to the root context (the traceparent\'s span_id), not a leftover span');
	check_clean('(a)', $cur, $c_before, $c_after);
}

# ----------------------------------------------------------------
# (b) Depth 200, sampled: > stack depth (128) and > max_open_spans
# (64).  The binding limit here is max_open_spans: the stack never
# reaches 128, because otel_span_start's slot-allocation check
# (ensure_pool()/take_slot(), checked AFTER the stack-depth check)
# starts failing once 64 spans are open, well before the stack could
# reach 128 -- so every failure beyond level 64 is start_no_slot, never
# start_stack_full, and nothing pushes onto the stack once a start
# fails.  Expect exactly 64 recorded, 136 refused (200 - 64).
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<SQL);
SET otel_api.traceparent = '$sampled_traceparent';
SELECT otel_api_conformance_reset() AS _r \\gset
SELECT otel_api_conformance_counters() AS c_before \\gset
SELECT conformance_recurse_entry(200) AS _r \\gset
SELECT otel_api_conformance_span_current() AS cur \\gset
SELECT otel_api_conformance_counters() AS c_after \\gset
SELECT :cur AS cur, :'c_before' AS c_before, :'c_after' AS c_after;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my ($status_line, $spans_line) = split /\n/, $out, 2;
	my ($cur, $c_before_j, $c_after_j) = split /\|/, $status_line;
	my $c_before = counters($c_before_j);
	my $c_after  = counters($c_after_j);
	my @s = parse_spans($spans_line);

	is(scalar(@s), 64, '(b) depth 200: exactly 64 spans recorded (max_open_spans)');
	is($c_after->{start_no_slot} - $c_before->{start_no_slot}, 136,
		'(b) exactly 136 refusals counted as start_no_slot');
	is($c_after->{start_stack_full} - $c_before->{start_stack_full}, 0,
		'(b) no start_stack_full: the slot budget bites before the stack could reach 128');
	check_clean('(b)', $cur, $c_before, $c_after);
}

# ----------------------------------------------------------------
# (c) Depth 20, ERROR at the bottom caught by an EXCEPTION block at
# level 10: levels 11..20 unwound and emitted with ERROR status;
# levels 1..10 (plus the post-catch span at level 10) end normally
# with UNSET/OK status; parent chain intact; a span started after the
# catch parents to level 10, not to anything from levels 11..20.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<SQL);
SET otel_api.traceparent = '$sampled_traceparent';
SELECT otel_api_conformance_reset() AS _r \\gset
SELECT otel_api_conformance_counters() AS c_before \\gset
SELECT conformance_recurse_entry(20, 10, true) AS _r \\gset
SELECT otel_api_conformance_span_current() AS cur \\gset
SELECT otel_api_conformance_counters() AS c_after \\gset
SELECT :cur AS cur, :'c_before' AS c_before, :'c_after' AS c_after;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my ($status_line, $spans_line) = split /\n/, $out, 2;
	my ($cur, $c_before_j, $c_after_j) = split /\|/, $status_line;
	my $c_before = counters($c_before_j);
	my $c_after  = counters($c_after_j);
	my @s = parse_spans($spans_line);
	my %by_name = map { $_->{name} => $_ } @s;

	is(scalar(@s), 21, '(c) 20 level spans + 1 post-catch span');
	for my $n (1 .. 10)
	{
		is($by_name{"level_$n"}->{status}, 0, "(c) level_$n (caller side) ends UNSET/OK, got status=$by_name{qq(level_$n)}->{status}");
	}
	for my $n (11 .. 20)
	{
		isnt($by_name{"level_$n"}->{status}, 0,
			"(c) level_$n (inside the caught block) is emitted with non-UNSET status");
	}
	is($by_name{level_20}->{status}, 2, '(c) the innermost span (level_20) carries ERROR status');
	# No exception.type/message event is expected here: the design doc's
	# "Resolved during implementation" section is explicit that
	# automatic error capture is only for an error that reaches the top
	# level; "errors caught before reporting (plpgsql EXCEPTION, C
	# PG_CATCH) still need otel_span_capture_error()", which nothing in
	# this scenario calls.  Confirmed empirically: levels 11..20 here
	# have status=ERROR but an empty events array and the generic
	# "ended by transaction or subtransaction abort" status_description
	# (see (d) below for the contrasting genuinely-uncaught case, which
	# *does* get exception.type via automatic capture).
	is(scalar(@{ $by_name{level_20}->{events} // [] }), 0,
		'(c) a caught error is NOT auto-captured into the span (needs otel_span_capture_error, per the design doc)');
	is($by_name{level_10_after_catch}->{parent_span_id}, $by_name{level_10}->{span_id},
		'(c) the post-catch span at level 10 parents to level_10, not to anything below the catch');
	for my $n (2 .. 20)
	{
		is($by_name{"level_$n"}->{parent_span_id},
			$by_name{"level_" . ($n - 1)}->{span_id},
			"(c) level_$n parents to level_" . ($n - 1));
	}
	check_clean('(c)', $cur, $c_before, $c_after);
}

# ----------------------------------------------------------------
# (d) Recursion until max_stack_depth is exceeded (SQLSTATE 54001):
# every recorded span is unwound, exported with ERROR status, the
# innermost carries exception.type 54001 via automatic capture, backend
# healthy and clean afterwards.
# ----------------------------------------------------------------
{
	# Everything -- the failing recursion AND the read-back -- must be
	# one psql invocation on one connection: otel_api_conformance's
	# counters/captured spans are backend-local (see t/001's header
	# comment), and the induced error only aborts the current
	# transaction, not the connection, so subsequent statements in the
	# same script run fine in a new implicit transaction.  psql (not
	# safe_psql, and no ON_ERROR_STOP) is used because the script
	# contains a statement that is expected to fail.
	# VERBOSITY terse: the induced error carries one CONTEXT line per
	# recursion level (dozens), which otherwise bloats stderr enough to
	# make output capture unreliable for no benefit here.
	my ($ret, $stdout, $stderr) = $node->psql('postgres', <<SQL, on_error_stop => 0);
\\set VERBOSITY terse
SET otel_api.traceparent = '$sampled_traceparent';
SET max_stack_depth = '500kB';
SELECT otel_api_conformance_reset() AS _r \\gset
SELECT conformance_recurse_entry(1000000) AS _r \\gset
SELECT otel_api_conformance_span_current() AS cur;
SELECT otel_api_conformance_counters();
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	like($stderr, qr/stack depth limit exceeded/,
		'(d) core reports "stack depth limit exceeded"');

	my @lines = split /\n/, $stdout;
	my ($cur, $counters_line, $spans_line) = @lines;
	my $c = counters($counters_line);
	my @s = parse_spans($spans_line);

	# Bound by otel_api.max_open_spans (default 64, not overridden by
	# this file), not by the C stack: the recursion keeps opening spans
	# (one per level) until the slot budget is exhausted (level 65
	# onward gets OTEL_SPAN_NONE, counted start_no_slot, and recursion
	# keeps going via SPI regardless), well before the real C stack is
	# exhausted deeper down.
	is(scalar(@s), 64, '(d) exactly 64 spans recorded (bound by max_open_spans, not the stack itself)');
	is($c->{spans_started}, 64, '(d) spans_started counter agrees');
	is($c->{unwound}, 64, '(d) all 64 are unwound and exported with ERROR status');
	is(scalar(grep { $_->{status} != 2 } @s), 0,
		'(d) no recorded span escapes with a non-ERROR status');
	my ($innermost) = sort { $b->{start_time} <=> $a->{start_time} } @s;
	my @exc_events = grep { $_->{name} eq 'exception' } @{ $innermost->{events} // [] };
	ok(@exc_events, '(d) the innermost unwound span has an exception event') or diag(encode_json($innermost));
	my %exc_attrs = map { $_->{key} => $_->{value} } @{ $exc_events[0]->{attrs} // [] };
	is($exc_attrs{'exception.type'}, '54001',
		'(d) the innermost span carries exception.type 54001 via automatic top-level capture');
	like($exc_attrs{'exception.message'}, qr/stack depth limit exceeded/,
		'(d) ... and the matching exception.message');
	is($cur, '0', '(d) active stack is empty after the aborted statement');
}

# ----------------------------------------------------------------
# (e) Unsampled recursion, depth 200: non-recording entries beyond 128
# (the stack-depth/nrec-pool limit) are refused (start_stack_full);
# nothing is emitted; clean afterwards, and a following SAMPLED span
# parents to the root context, not a leftover.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<SQL);
SET otel_api.traceparent = '$unsampled_traceparent';
SELECT otel_api_conformance_reset() AS _r \\gset
SELECT otel_api_conformance_counters() AS c_before \\gset
SELECT conformance_recurse_entry(200) AS _r \\gset
SELECT otel_api_conformance_span_current() AS cur \\gset
SELECT otel_api_conformance_counters() AS c_after \\gset
SELECT :cur AS cur, :'c_before' AS c_before, :'c_after' AS c_after;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
RESET otel_api.traceparent;
SET otel_api.traceparent = '$sampled_traceparent';
SELECT otel_api_conformance_end(otel_api_conformance_start('conformance.e.followup')) AS _r \\gset
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' = 'conformance.e.followup';
SQL
	my ($status_line, $spans_line, $followup_line) = split /\n/, $out, 3;
	my ($cur, $c_before_j, $c_after_j) = split /\|/, $status_line;
	my $c_before = counters($c_before_j);
	my $c_after  = counters($c_after_j);
	my @s = parse_spans($spans_line);

	is(scalar(@s), 0, '(e) nothing is emitted for an unsampled recursive chain');
	cmp_ok($c_after->{start_stack_full} - $c_before->{start_stack_full}, '>=', 1,
		'(e) starts beyond the 128 stack/nrec-pool limit are refused (start_stack_full)');
	check_clean('(e)', $cur, $c_before, $c_after);

	my @followup = parse_spans($followup_line);
	is(scalar(@followup), 1, '(e) a following sampled span is recorded');
	is($followup[0]->{parent_span_id}, '00f067aa0ba902b7',
		'(e) the following sampled span parents to the (sampled) traceparent root context, '
		  . 'not a leftover from the unsampled chain');
}

$node->stop;

# ----------------------------------------------------------------
# (f) With otel_postgres_tracing also loaded: recursion to depth 30
# where each level's with_span() call executes a nested SQL statement
# via SPI, so otel_postgres_tracing's own instrumentation is exercised
# alongside otel_api_conformance's spans in the same backend; and a
# variant that errors at the bottom and is caught mid-way.  This is a
# lighter check than (a)-(e): otel_postgres_tracing's own span shape
# for a SPI-nested statement isn't otherwise pinned down in this
# suite, so the assertions here are about otel_api_conformance's own
# spans (chained and clean) plus "nothing crashed and nothing leaked
# into the next top-level statement", not an exact expected span count
# from otel_postgres_tracing.
# ----------------------------------------------------------------
{
	my $node2 = PostgreSQL::Test::Cluster->new('with_tracing');
	$node2->init;
	$node2->append_conf('postgresql.conf', <<'EOCONF');
shared_preload_libraries = 'otel_api,otel_postgres_tracing,otel_api_conformance'
max_stack_depth = '7MB'
restart_after_crash = on
EOCONF
	$node2->start;
	$node2->safe_psql('postgres',
		'CREATE EXTENSION otel_api; CREATE EXTENSION otel_postgres_tracing; '
		  . 'CREATE EXTENSION otel_api_conformance');
	$node2->safe_psql('postgres', <<'SQL');
CREATE FUNCTION conformance_recurse(level int, max_depth int,
	catch_level int DEFAULT -1, raise_at_bottom boolean DEFAULT false)
RETURNS void AS $BODY$
BEGIN
	IF level > max_depth THEN
		IF raise_at_bottom THEN
			RAISE EXCEPTION 'otel_api_conformance recursion bottom reached'
				USING ERRCODE = 'RC000';
		END IF;
		RETURN;
	END IF;
	IF level = catch_level THEN
		-- The catch level's span, the subtransaction that catches the
		-- error, and the after-catch child all live inside one C call,
		-- as they would in C code using PG_TRY.  Starting a stack span in
		-- one plpgsql statement and ending it in another would not be
		-- LIFO once another producer wraps each statement in its own
		-- span (otel_postgres_tracing does).
		PERFORM otel_api_conformance_with_span_catch('level_' || level,
			format('SELECT conformance_recurse(%s,%s,%s,%L)',
				level + 1, max_depth, catch_level, raise_at_bottom),
			'level_' || level || '_after_catch');
	ELSE
		PERFORM otel_api_conformance_with_span('level_' || level,
			format('SELECT conformance_recurse(%s,%s,%s,%L)',
				level + 1, max_depth, catch_level, raise_at_bottom));
	END IF;
END;
$BODY$ LANGUAGE plpgsql;

CREATE FUNCTION conformance_recurse_entry(max_depth int,
	catch_level int DEFAULT -1, raise_at_bottom boolean DEFAULT false)
RETURNS void AS $BODY$
BEGIN
	PERFORM otel_api_conformance_with_span('level_1',
		format('SELECT conformance_recurse(2,%s,%s,%L)',
			max_depth, catch_level, raise_at_bottom));
END;
$BODY$ LANGUAGE plpgsql;
SQL

	# Clean, no-error variant, depth 30.
	#
	# Note: otel_span_current() is NOT expected to be 0 here even though
	# nothing "leaked" -- with otel_postgres_tracing loaded, every SQL
	# statement (including the very "SELECT otel_api_conformance_
	# span_current()" call doing the checking) is itself wrapped in that
	# extension's own pg.query/pg.execute/pgsql.execute spans, so the
	# active stack is never empty while any statement is executing. This
	# is otel_postgres_tracing's own instrumentation, not a leftover from
	# the recursion, so this file doesn't assert stack emptiness or an
	# exact per-level parent chain here (otel_postgres_tracing interposes
	# its own spans between levels for each nested SPI-executed
	# statement, which is outside what this suite pins down): just that
	# the recursion runs to completion, alongside that other producer,
	# and every one of otel_api_conformance's own spans is still
	# recorded.
	{
		my $out = $node2->safe_psql('postgres', <<SQL);
SET otel_api.traceparent = '$sampled_traceparent';
SELECT otel_api_conformance_reset() AS _r \\gset
SELECT conformance_recurse_entry(30) AS _r \\gset
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' LIKE 'level_%';
SQL
		my @s = parse_spans($out);

		is(scalar(@s), 30, '(f) all 30 conformance level spans recorded alongside otel_postgres_tracing');
	}

	# Error at the bottom, caught mid-way (level 15 of 30).  The catch
	# level runs in one C call (with_span_catch), so spans stay LIFO even
	# though otel_postgres_tracing wraps every nested statement in spans
	# of its own.  Same expectations on every build: no non-LIFO end, no
	# stale handle, levels below the catch unwound as ERROR, the levels
	# down to the catch and the after-catch child ended normally.
	{
		my $out = $node2->safe_psql('postgres', <<SQL);
SET otel_api.traceparent = '$sampled_traceparent';
SELECT otel_api_conformance_reset() AS _r \\gset
SELECT otel_api_conformance_counters() AS c0 \\gset
SELECT conformance_recurse_entry(30, 15, true) AS _r \\gset
SELECT :'c0';
SELECT otel_api_conformance_counters();
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' LIKE 'level_%';
SQL
		my ($c0_json, $c1_json, $spans_json) = split /\n/, $out, 3;
		my $c0 = decode_json($c0_json);
		my $c1 = decode_json($c1_json);
		my @s = @{ decode_json($spans_json) };
		my %by_name = map { $_->{name} => $_ } @s;

		is($c1->{non_lifo_end} - $c0->{non_lifo_end}, 0,
			'(f) caught error mid-recursion: no non-LIFO end alongside otel_postgres_tracing');
		is($c1->{stale_handle} - $c0->{stale_handle}, 0,
			'(f) caught error mid-recursion: no stale handle');
		is(scalar(@s), 31, '(f) 30 level spans plus the after-catch span recorded');
		for my $n (1 .. 15)
		{
			isnt($by_name{"level_$n"}->{status}, 2,
				"(f) level_$n, at or above the catch, is not ERROR");
		}
		for my $n (16 .. 30)
		{
			is($by_name{"level_$n"}->{status}, 2,
				"(f) level_$n, below the catch, was unwound as ERROR");
		}
		is($by_name{level_15_after_catch}->{parent_span_id},
			$by_name{level_15}->{span_id},
			'(f) the after-catch span parents to level_15');
	}

	$node2->stop;
}

done_testing();
