# Copyright (c) 2026, PostgreSQL Global Development Group
#
# A top-level CALL to a procedure that COMMITs internally
# (postgres-cdq.9.1, explicitly open/unsettled: where should a
# transaction-controlling CALL's own span attach?).  Out of scope for
# this module beyond: don't crash, don't flood the log with misuse
# warnings, and document what actually happens.
#
# PLPGSQL_STMT_COMMIT/ROLLBACK are only legal in a NONATOMIC invocation
# (estate->atomic == false): a top-level CALL or DO run outside an
# explicit transaction block.  This module detects that case
# (otel_plpgsql_func_beg()) and uses OTEL_OWNER_SESSION for every span it
# opens during it instead of the default resource-owner ownership, so an
# inner COMMIT doesn't force-release (and so go stale) spans that are
# still open across it; a plain COMMIT (no error) doesn't run this
# module's abort callbacks either, so the spans should simply survive
# the COMMIT untouched and close normally, via func_end/stmt_end, once
# the CALL itself finishes. This test checks that's actually what
# happens: proper span count, names, parentage and OK status, not just
# "didn't crash". (An uncaught error, or one caught by a nested
# BEGIN...EXCEPTION, in a nonatomic call is covered separately by
# t/010_nonatomic_uncaught_error.pl and t/011_nonatomic_caught_exception.pl.)

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
CREATE TABLE occ_log (i int);

CREATE PROCEDURE occ_commits() LANGUAGE plpgsql AS $BODY$
BEGIN
	INSERT INTO occ_log VALUES (1);
	COMMIT;
	INSERT INTO occ_log VALUES (2);
	COMMIT;
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

# CALL must be a top-level statement (not inside an explicit transaction
# block) for an internal COMMIT to be legal at all.
my $combined = $node->safe_psql(
	'postgres', q{
	SET otel_plpgsql.trace_statements = on;
	SELECT test_otel_clear();
	CALL occ_commits();
	SELECT 'ROWS:' || count(*) FROM occ_log;
} . $pop_all_spans_sql);

my ($rows) = $combined =~ /^ROWS:(\d+)$/m;
is($rows, '2', 'the procedure actually ran both COMMITs (no crash, work was committed)');

my @spans = parse_popped_spans($combined);

my @func = grep { $_->{name} eq 'pg.plpgsql.function' } @spans;
is(scalar(@func), 1, 'exactly one function span for the CALL, surviving both internal COMMITs');
isnt(($func[0]->{status} // ''), '2', 'the function span does not end with ERROR status')
	if @func;

my @stmt = grep { $_->{name} eq 'pg.plpgsql.stmt' } @spans;
cmp_ok(scalar(@stmt), '>=', 5,
	'at least 5 statement spans (the block, 2 INSERTs, 2 COMMITs)');
ok(!(grep { ($_->{status} // '') eq '2' } @stmt),
	'no statement span ends with ERROR status (nothing actually errored)');

# Every span must be properly parented back to the one root (the CALL
# itself): the COMMITs must not have orphaned anything.
my %span_ids = map { $_->{span_id} => 1 } @spans;
my @roots = grep { ($_->{parent_span_id} // '') eq '' } @spans;
is(scalar(@roots), 1, 'exactly one root span (the CALL)');
my $all_parented = 1;
for my $s (@spans)
{
	next if ($s->{parent_span_id} // '') eq '';
	$all_parented = 0 unless $span_ids{ $s->{parent_span_id} };
}
ok($all_parented, 'every non-root span parents to another captured span, across both COMMITs');

ok(!$node->log_contains(qr/\b(PANIC|FATAL):|stale|out of (order|LIFO|lifo)/i),
	'no crash, and no stale-handle/out-of-order misuse warning, '
	. 'despite the internal COMMIT');

# The backend must still be alive and usable afterwards.
is($node->safe_psql('postgres', 'SELECT 1'), '1',
	'the backend is still alive and queryable after CALL with internal COMMIT');

$node->stop;
done_testing();
