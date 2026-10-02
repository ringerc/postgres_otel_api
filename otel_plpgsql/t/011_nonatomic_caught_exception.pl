# Copyright (c) 2026, PostgreSQL Global Development Group
#
# A nonatomic top-level CALL whose body catches an error in its own
# BEGIN ... EXCEPTION block. The subtransaction abort that catches it
# does not touch this module's session-owned spans (no resource owner
# is tied to them, see the comment in otel_plpgsql_func_setup()), but
# before the fix, otel_plpgsql_stmt_end()'s resync still discarded the
# stale stack entries for them WITHOUT ending them (the right thing to
# do for the default-owned case, where they're already gone by then ---
# wrong here, where they're still open and still on otel_api's active
# stack). Expected failure mode: a LIFO-violation WARNING when func_end
# tries to end the function span out from under still-open entries
# above it (an Assert failure on a cassert build), and/or spans that
# never get exported.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf', <<EOCONF);
shared_preload_libraries = 'plpgsql,otel_api,otel_plpgsql,test_otel_exporter'
log_min_messages = warning
EOCONF
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_plpgsql; '
	. 'CREATE EXTENSION test_otel_exporter');

$node->safe_psql(
	'postgres', q{
CREATE PROCEDURE occ_nested_catch() LANGUAGE plpgsql AS $BODY$
BEGIN
	BEGIN
		PERFORM 1 / 0;
	EXCEPTION WHEN division_by_zero THEN
		NULL;
	END;
	PERFORM 2;
END;
$BODY$;
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

# CALL must be top-level (not inside an explicit transaction block) to
# be a nonatomic invocation at all.
my $combined = $node->safe_psql(
	'postgres', q{
	SET otel_plpgsql.trace_statements = on;
	SELECT test_otel_clear();
	CALL occ_nested_catch();
} . $pop_all_spans_sql);

my @spans = parse_popped_spans($combined);

my @func = grep { $_->{name} eq 'pg.plpgsql.function' } @spans;
is(scalar(@func), 1, 'one function span for the CALL');
isnt(($func[0]->{status} // ''), '2', 'the CALL\'s own function span does not end with ERROR status')
	if @func;

my @stmt = grep { $_->{name} eq 'pg.plpgsql.stmt' } @spans;
my @error_stmt = grep { ($_->{status} // '') eq '2' } @stmt;
cmp_ok(scalar(@error_stmt), '>=', 1,
	'at least one statement span inside the EXCEPTION-protected block ends with ERROR status');

# Everything captured must be properly parented: no span left dangling
# as its own disconnected root because the resync dropped its
# bookkeeping without the span itself ever having been ended.
my %span_ids = map { $_->{span_id} => 1 } @spans;
my @roots = grep { ($_->{parent_span_id} // '') eq '' } @spans;
is(scalar(@roots), 1, 'exactly one root span (the CALL itself)');

my $all_parented = 1;
for my $s (@spans)
{
	next if ($s->{parent_span_id} // '') eq '';
	$all_parented = 0 unless $span_ids{ $s->{parent_span_id} };
}
ok($all_parented, 'every non-root span parents to another captured span');

ok(!$node->log_contains(qr/stale|out of (order|LIFO|lifo)/i),
	'no stale-handle or out-of-order misuse warning in the server log');

$node->stop;
done_testing();
