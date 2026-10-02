# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Error caught by a BEGIN ... EXCEPTION block: that subtransaction's
# abort force-ends (with ERROR status) every span opened inside it,
# including statement spans whose stmt_end is never reached; the
# enclosing function span (opened before the subtransaction started)
# must stay open and end normally (OK) once the function returns; and a
# statement AFTER the handler must still parent correctly to the
# function span -- proving this module's stack-resync in
# otel_plpgsql_stmt_end() (discarding, never re-ending, the stale
# entries an error unwound past) actually works, rather than crashing or
# warning about stale-handle / out-of-order misuse.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf', <<EOCONF);
shared_preload_libraries = 'otel_api,otel_plpgsql,test_otel_exporter'
log_min_messages = warning
EOCONF
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_plpgsql; '
	. 'CREATE EXTENSION test_otel_exporter');

$node->safe_psql(
	'postgres', q{
CREATE FUNCTION otc_catcher() RETURNS void AS $BODY$
BEGIN
	BEGIN
		PERFORM 1 / 0;
	EXCEPTION WHEN division_by_zero THEN
		NULL;
	END;
	PERFORM 2;
END;
$BODY$ LANGUAGE plpgsql;
});

sub parse_kv
{
	my ($text) = @_;
	my %h;
	for my $line (split /\n/, $text // '')
	{
		if ($line =~ /^attr=([^=]+)=(.*)$/) { $h{attr}{$1} = $2; }
		elsif ($line =~ /^([^=]+)=(.*)$/)   { $h{$1} = $2; }
	}
	return \%h;
}

# Must be appended to the SAME safe_psql() script that produced the
# spans: the capture ring is per-backend state, and safe_psql() starts a
# new backend on every call (see t/001_function_spans.pl's header
# comment).  Popping 32 times (CAPTURE_RING_SIZE) is always safe.
my $pop_all_spans_sql = join('',
	map { "SELECT '===SPAN===' || coalesce(test_otel_pop_span(), '');\n" }
	(1 .. 32));

sub parse_popped_spans
{
	my ($out) = @_;
	my @chunks = split /===SPAN===/, $out;
	shift @chunks;
	my @spans;
	for my $c (@chunks)
	{
		next if $c !~ /\S/;
		push @spans, parse_kv($c);
	}
	return @spans;
}

my $combined = $node->safe_psql(
	'postgres', q{
	SET otel_plpgsql.trace_statements = on;
	SELECT test_otel_clear();
	SELECT otc_catcher();
} . $pop_all_spans_sql);

my @spans = parse_popped_spans($combined);

my @func = grep { $_->{name} eq 'pg.plpgsql.function' } @spans;
is(scalar(@func), 1, 'one function span');

# This module never calls otel_span_set_status() explicitly, so a span
# that completes normally keeps status=0 (OTEL_STATUS_UNSET), not
# OTEL_STATUS_OK (1) --- UNSET is the implicit-success case; what matters
# here is that it is NOT 2 (OTEL_STATUS_ERROR), i.e. the caught error did
# NOT propagate out to the enclosing function span.
isnt($func[0]->{status}, '2',
	'function span does not end with ERROR status despite the caught error inside it')
	if @func;

my @stmt = grep { $_->{name} eq 'pg.plpgsql.stmt' } @spans;
cmp_ok(scalar(@stmt), '>=', 3,
	'at least 3 statement spans (outer block, inner block, PERFORM 2; '
	. 'the PERFORM 1/0 itself may or may not have its own span depending '
	. 'on expression-statement internals)');

my @error_stmts = grep { ($_->{status} // '') eq '2' } @stmt;
cmp_ok(scalar(@error_stmts), '>=', 1,
	'at least one statement span inside the EXCEPTION-protected block ends with ERROR status');

my @ok_stmts = grep { ($_->{status} // '') ne '2' } @stmt;
cmp_ok(scalar(@ok_stmts), '>=', 2,
	'the inner BEGIN...EXCEPTION block itself and PERFORM 2 (after the handler) both end OK');

# Every captured span must share one trace_id (the function call's root),
# and every non-root span must have a parent_span_id that matches some
# other captured span's span_id -- proving nothing got orphaned by the
# resync, including the statement(s) that ran after the handler.
my %span_ids = map { $_->{span_id} => 1 } @spans;
my $trace_id = $spans[0]->{trace_id};
my $all_same_trace = 1;
my $all_parented = 1;
for my $s (@spans)
{
	$all_same_trace = 0 if $s->{trace_id} ne $trace_id;
	next if $s->{parent_span_id} eq '';    # the one root
	$all_parented = 0 unless $span_ids{ $s->{parent_span_id} };
}
ok($all_same_trace, 'every captured span shares the same trace_id');
ok($all_parented,
	'every non-root span (including anything after the exception handler) '
	. 'has a parent among the captured spans');

# No stale-handle / out-of-order misuse was logged: otel_api counts and
# (in cassert builds) asserts on that, so its absence from the log is
# this module's resync logic actually doing its job, not luck.
ok( !$node->log_contains(qr/stale|out of (order|LIFO|lifo)/i),
	'no stale-handle or out-of-order warning in the server log');

$node->stop;
done_testing();
