# Copyright (c) 2026, PostgreSQL Global Development Group
#
# A nonatomic DO/CALL (session-owned spans, see otel_plpgsql_func_beg())
# whose body calls an ordinary ATOMIC plpgsql function that raises. The
# inner function's own spans are default-owned (tied to a resource
# owner), and they sit ABOVE this module's session-owned spans on
# otel_api's active stack. otel_api releases default-owned spans during
# ResourceOwnerRelease(..., RESOURCE_RELEASE_BEFORE_LOCKS, ...), which
# AbortSubTransaction()/AbortTransaction() call AFTER
# CallSubXactCallbacks(SUBXACT_EVENT_ABORT_SUB)/CallXactCallbacks(XACT_EVENT_ABORT)
# --- so a SubXactCallback/XactCallback-based fix that ends this
# module's session spans runs TOO EARLY: the default-owned span above it
# is still open, and ending the session span first is a LIFO violation
# (otel_api: WARNING, and on a cassert build, an Assert failure that
# crashes the backend --- the same failure mode as
# t/011_nonatomic_caught_exception.pl, from the opposite direction).
#
# Two variants: the inner raise caught by naf_do_catch()'s own
# BEGIN...EXCEPTION (the inner call's statement span and this module's
# wrapping "PERFORM ..." statement span for it are BOTH pushed once
# already inside that block's subtransaction, so they share a nest
# level, with the inner call's own default-owned span on top); and
# uncaught (propagates out through the whole nonatomic call with no
# subtransaction at all, so every span --- some default-owned, some
# session-owned --- shares nest level 1, with the inner default-owned
# span innermost).

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
CREATE FUNCTION naf_inner_raises() RETURNS void AS $BODY$
BEGIN
	RAISE EXCEPTION 'naf_inner: induced';
END;
$BODY$ LANGUAGE plpgsql;

CREATE PROCEDURE naf_do_catch() LANGUAGE plpgsql AS $BODY$
BEGIN
	BEGIN
		PERFORM naf_inner_raises();
	EXCEPTION WHEN OTHERS THEN
		NULL;
	END;
	PERFORM 1;
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

# --------------------------------------------------------------------
# Caught: naf_do_catch()'s own BEGIN...EXCEPTION catches the inner
# atomic function's error.
# --------------------------------------------------------------------
my $combined = $node->safe_psql(
	'postgres', q{
	SET otel_plpgsql.trace_statements = on;
	SELECT test_otel_clear();
	CALL naf_do_catch();
} . $pop_all_spans_sql);

my @spans = parse_popped_spans($combined);
my @func = grep { $_->{name} eq 'pg.plpgsql.function' } @spans;
cmp_ok(scalar(@func), '>=', 2,
	'(caught) both naf_do_catch and naf_inner_raises got function spans');
isnt((( grep { ($_->{attr}{'code.function.name'} // '') =~ /^naf_do_catch\(/ } @func)[0]->{status} // ''),
	'2', '(caught) the outer CALL\'s own function span does not end with ERROR status')
  if @func;

ok(!$node->log_contains(qr/stale|out of (order|LIFO|lifo)/i),
	'(caught) no stale-handle or out-of-order misuse warning in the server log');

$node->safe_psql('postgres', 'SELECT test_otel_clear()');

# --------------------------------------------------------------------
# Uncaught: naf_inner_raises()'s error propagates all the way out of
# the DO block, with no subtransaction/EXCEPTION block involved at all.
# --------------------------------------------------------------------
$node->safe_psql(
	'postgres', q{
CREATE PROCEDURE naf_do_uncaught() LANGUAGE plpgsql AS $BODY$
BEGIN
	PERFORM naf_inner_raises();
END;
$BODY$;
});

my $out;
$node->psql(
	'postgres', q{
	SET otel_plpgsql.trace_statements = on;
	SELECT test_otel_clear();
	CALL naf_do_uncaught();
} . $pop_all_spans_sql,
	stdout => \$out,
	on_error_stop => 0);

my @uspans = parse_popped_spans($out);
cmp_ok(scalar(@uspans), '>=', 2,
	'(uncaught) at least the CALL\'s own span and the inner function\'s span were captured');

ok(!$node->log_contains(qr/stale|out of (order|LIFO|lifo)/i),
	'(uncaught) no stale-handle or out-of-order misuse warning in the server log');

# The backend must still be alive and usable afterwards in both cases.
is($node->safe_psql('postgres', 'SELECT 1'), '1',
	'the backend is still alive and queryable afterwards');

$node->stop;
done_testing();
