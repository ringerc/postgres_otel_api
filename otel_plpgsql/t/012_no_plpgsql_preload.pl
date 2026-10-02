# Copyright (c) 2026, PostgreSQL Global Development Group
#
# otel_plpgsql must load (and work) with 'plpgsql' absent from
# shared_preload_libraries: plpgsql_stmt_typename() is resolved lazily,
# through load_external_function(), on first use rather than called
# directly, so there is no link-time reference for RTLD_NOW to fail on
# at postmaster start regardless of preload order (see the file header
# comment in otel_plpgsql.c). Before that fix, this exact configuration
# made the postmaster fail with "undefined symbol: plpgsql_stmt_typename".

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
CREATE FUNCTION npp_fn() RETURNS void AS $BODY$
BEGIN
	PERFORM 1;
END;
$BODY$ LANGUAGE plpgsql;
});

my $combined = $node->safe_psql(
	'postgres', q{
	SET otel_plpgsql.trace_statements = on;
	SELECT test_otel_clear();
	SELECT npp_fn();
	SELECT 'FUNC:' || test_otel_count_spans_by_name('pg.plpgsql.function');
	SELECT 'STMT:' || test_otel_count_spans_by_name('pg.plpgsql.stmt');
});
my ($func_count) = $combined =~ /^FUNC:(\d+)$/m;
my ($stmt_count) = $combined =~ /^STMT:(\d+)$/m;
is($func_count, '1',
	'the postmaster started and traced a function call with plpgsql absent '
	. 'from shared_preload_libraries');
cmp_ok($stmt_count, '>=', 1,
	'statement spans (which need plpgsql_stmt_typename) work too, '
	. 'proving it really did resolve, not just silently fail to attribute');

$node->stop;
done_testing();
