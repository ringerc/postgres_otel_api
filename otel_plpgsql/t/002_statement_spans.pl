# Copyright (c) 2026, PostgreSQL Global Development Group
#
# otel_plpgsql.trace_statements on/off: with it on, each executed
# statement (including the function's own top-level block) gets its own
# pg.plpgsql.stmt span nested under pg.plpgsql.function; with it off,
# only the function span is produced.

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
CREATE FUNCTION ots_two_stmts() RETURNS void AS $BODY$
BEGIN
	PERFORM 1;
	PERFORM 2;
END;
$BODY$ LANGUAGE plpgsql;
});

# --------------------------------------------------------------------
# trace_statements on (the default): at least 3 pg.plpgsql.stmt spans
# (the top-level block + the two PERFORM statements), plus 1
# pg.plpgsql.function span.
# --------------------------------------------------------------------
my $combined_on = $node->safe_psql(
	'postgres', q{
	SET otel_plpgsql.trace_statements = on;
	SELECT test_otel_clear();
	SELECT ots_two_stmts();
	SELECT 'FUNC:' || test_otel_count_spans_by_name('pg.plpgsql.function');
	SELECT 'STMT:' || test_otel_count_spans_by_name('pg.plpgsql.stmt');
});
my ($func_on) = $combined_on =~ /^FUNC:(\d+)$/m;
my ($stmt_on) = $combined_on =~ /^STMT:(\d+)$/m;
is($func_on, '1', 'trace_statements=on: one function span');
cmp_ok($stmt_on, '>=', 3,
	'trace_statements=on: at least 3 statement spans (block + 2 PERFORMs)');

# --------------------------------------------------------------------
# trace_statements off: the function span is still produced, but no
# statement spans at all.
# --------------------------------------------------------------------
my $combined_off = $node->safe_psql(
	'postgres', q{
	SET otel_plpgsql.trace_statements = off;
	SELECT test_otel_clear();
	SELECT ots_two_stmts();
	SELECT 'FUNC:' || test_otel_count_spans_by_name('pg.plpgsql.function');
	SELECT 'STMT:' || test_otel_count_spans_by_name('pg.plpgsql.stmt');
});
my ($func_off) = $combined_off =~ /^FUNC:(\d+)$/m;
my ($stmt_off) = $combined_off =~ /^STMT:(\d+)$/m;
is($func_off, '1', 'trace_statements=off: still one function span');
is($stmt_off, '0', 'trace_statements=off: no statement spans');

$node->stop;
done_testing();
