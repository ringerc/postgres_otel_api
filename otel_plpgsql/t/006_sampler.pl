# Copyright (c) 2026, PostgreSQL Global Development Group
#
# otel_api.sampler = traceidratio with otel_api.sampler_arg = 0: every
# outermost plpgsql call starts a new root (OTEL_PARENT_ROOT), so this
# sampler setting must drop every one of them -- no spans captured, and
# critically no errors/crashes from running fully unsampled (unsampled
# spans still propagate a context and still go through this module's
# ownership/stack bookkeeping; only otel_api's internal recording is
# skipped).

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
otel_api.sampler = 'traceidratio'
otel_api.sampler_arg = 0
EOCONF
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_plpgsql; '
	. 'CREATE EXTENSION test_otel_exporter');

$node->safe_psql(
	'postgres', q{
CREATE FUNCTION srz_child() RETURNS void AS $BODY$
BEGIN
	PERFORM 1;
END;
$BODY$ LANGUAGE plpgsql;

CREATE FUNCTION srz_parent() RETURNS void AS $BODY$
BEGIN
	PERFORM srz_child();
	PERFORM srz_child();
END;
$BODY$ LANGUAGE plpgsql;
});

my $combined = $node->safe_psql(
	'postgres', q{
	SET otel_plpgsql.trace_statements = on;
	SELECT test_otel_clear();
	SELECT srz_parent();
	SELECT srz_parent();
	SELECT 'COUNT:' || test_otel_span_count();
});
my ($count) = $combined =~ /^COUNT:(\d+)$/m;
is($count, '0',
	'traceidratio=0 drops every root (and so every nested) span; nothing captured');

ok(!$node->log_contains(qr/\b(ERROR|PANIC):|stale|out of (order|LIFO|lifo)/i),
	'no errors, crashes, or misuse warnings while running fully unsampled');

$node->stop;
done_testing();
