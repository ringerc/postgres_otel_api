# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Uncaught ERROR: func_end/stmt_end are not called, so the function's
# (and each still-open statement's) span must end through otel_api's own
# resource-owner release at the aborting statement's abort, with ERROR
# status --- nothing special is needed in this module for that to work.
#
# Uses $node->psql(..., on_error_stop => 0) rather than safe_psql: the
# erroring statement must NOT stop the script, so later statements in the
# same backend/session can read back what was captured (test_otel_exporter
# state is per-backend).

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
CREATE FUNCTION ots_boom() RETURNS void AS $BODY$
BEGIN
	PERFORM 1;
	RAISE EXCEPTION 'ots_boom: induced, uncaught';
END;
$BODY$ LANGUAGE plpgsql;
});

my $out;
$node->psql(
	'postgres', q{
	SET otel_plpgsql.trace_statements = off;
	SELECT test_otel_clear();
	SELECT ots_boom();
	SELECT 'FUNC:' || test_otel_pop_span_by_name('pg.plpgsql.function');
},
	stdout => \$out,
	on_error_stop => 0);

like($out, qr/^name=pg\.plpgsql\.function$/m,
	'the function span was captured despite the uncaught error');
like($out, qr/^status=2$/m,
	'the function span ends with ERROR status (released on abort)');
like($out, qr/^status_description=.*ots_boom: induced, uncaught/m,
	'ERROR status_description carries the exception message ("SQLSTATE / message")');

my $out2;
$node->psql(
	'postgres',
	q{SELECT test_otel_span_count(); SELECT test_otel_clear();},
	stdout => \$out2,
	on_error_stop => 0);
my ($remaining) = $out2 =~ /^\s*(\d+)/;
is($remaining, '0', 'no leftover spans after the uncaught error');

$node->stop;
done_testing();
