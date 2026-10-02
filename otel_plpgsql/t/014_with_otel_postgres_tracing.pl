# Copyright (c) 2026, PostgreSQL Global Development Group
#
# With otel_postgres_tracing also loaded (otel.trace_all_queries = on):
# every SQL statement plpgsql runs internally via SPI --- including each
# PERFORM/SELECT inside a function or DO block --- gets its own
# default-owned pg.sql-ish statement span from THAT module, sitting
# directly above whatever this module pushed for the same plpgsql
# statement.  For an ordinary atomic call that's harmless (both layers
# are default-owned, released together, normal LIFO order).  For a
# nonatomic DO/CALL (session-owned spans), it reproduces the same
# ordering hazard as t/013_nonatomic_inner_atomic_raise.pl without
# needing any inner function call at all: just one statement erroring
# inside a nonatomic call, caught or not.
#
# Also checks the ordinary (atomic, no otel_plpgsql session-ownership
# involved at all) case nests cleanly under otel_postgres_tracing's own
# statement span, with no warnings, on success and on caught/uncaught
# errors --- a baseline that should already hold regardless of the
# nonatomic-specific fix.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf', <<EOCONF);
shared_preload_libraries = 'otel_api,otel_plpgsql,otel_postgres_tracing,test_otel_exporter'
log_min_messages = warning
otel.trace_all_queries = on
EOCONF
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_plpgsql; '
	. 'CREATE EXTENSION otel_postgres_tracing; '
	. 'CREATE EXTENSION test_otel_exporter');

$node->safe_psql(
	'postgres', q{
CREATE FUNCTION owt_ok() RETURNS void AS $BODY$
BEGIN
	PERFORM 1;
END;
$BODY$ LANGUAGE plpgsql;

CREATE FUNCTION owt_raises() RETURNS void AS $BODY$
BEGIN
	RAISE EXCEPTION 'owt_raises: induced';
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
# Baseline: an ordinary (atomic) call, success.
# --------------------------------------------------------------------
my $ok_out = $node->safe_psql(
	'postgres', q{
	SET otel_plpgsql.trace_statements = on;
	SELECT test_otel_clear();
	SELECT owt_ok();
} . $pop_all_spans_sql);
my @ok_spans = parse_popped_spans($ok_out);
cmp_ok(scalar(@ok_spans), '>=', 2,
	'(atomic, success) both otel_postgres_tracing and otel_plpgsql spans were captured');
ok(!$node->log_contains(qr/stale|out of (order|LIFO|lifo)/i),
	'(atomic, success) no misuse warning');

# --------------------------------------------------------------------
# Baseline: an ordinary (atomic) call, uncaught error.
# --------------------------------------------------------------------
my $atomic_err_out;
$node->psql(
	'postgres', q{
	SELECT test_otel_clear();
	SELECT owt_raises();
} . $pop_all_spans_sql,
	stdout => \$atomic_err_out,
	on_error_stop => 0);
ok(defined $atomic_err_out, '(atomic, uncaught error) backend survived and responded');
ok(!$node->log_contains(qr/stale|out of (order|LIFO|lifo)/i),
	'(atomic, uncaught error) no misuse warning');

# --------------------------------------------------------------------
# Nonatomic DO, uncaught: a single failing statement, no inner function
# call needed --- otel_postgres_tracing's own default-owned span for
# that one statement already sits above this module's session-owned
# spans.
# --------------------------------------------------------------------
my $do_uncaught_out;
$node->psql(
	'postgres', q{
	SELECT test_otel_clear();
	DO $DO$ BEGIN PERFORM owt_raises(); END; $DO$;
} . $pop_all_spans_sql,
	stdout => \$do_uncaught_out,
	on_error_stop => 0);
ok(defined $do_uncaught_out,
	'(nonatomic DO, uncaught, otel_postgres_tracing loaded) backend survived and responded');
ok(!$node->log_contains(qr/stale|out of (order|LIFO|lifo)/i),
	'(nonatomic DO, uncaught) no misuse warning');

# --------------------------------------------------------------------
# Nonatomic DO, caught by its own BEGIN...EXCEPTION.
# --------------------------------------------------------------------
my $do_caught_out = $node->safe_psql(
	'postgres', q{
	SELECT test_otel_clear();
	DO $DO$
	BEGIN
		BEGIN
			PERFORM owt_raises();
		EXCEPTION WHEN OTHERS THEN
			NULL;
		END;
		PERFORM 1;
	END;
	$DO$;
} . $pop_all_spans_sql);
ok(defined $do_caught_out,
	'(nonatomic DO, caught, otel_postgres_tracing loaded) ran to completion');
ok(!$node->log_contains(qr/stale|out of (order|LIFO|lifo)/i),
	'(nonatomic DO, caught) no misuse warning');

is($node->safe_psql('postgres', 'SELECT 1'), '1',
	'the backend is still alive and queryable after all of the above');

$node->stop;
done_testing();
