# Copyright (c) 2026, PostgreSQL Global Development Group
#
# The S0 "otel_api hooks compiled out" build (otel_plpgsql_stub): loads
# and runs PL/pgSQL functions identically to the main build, but every
# hook is a no-op against otel_producer_stub.h, so nothing is ever
# captured even with otel_api and a real exporter loaded alongside it.
#
# A separate node/cluster (not otel_plpgsql + otel_plpgsql_stub together,
# that's t/005_plugin_slot_taken.pl) so this is a genuine standalone check
# of the stub variant, not shadowed by the main build winning the
# PLpgSQL_plugin rendezvous race.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf', <<EOCONF);
shared_preload_libraries = 'plpgsql,otel_api,otel_plpgsql_stub,test_otel_exporter'
log_min_messages = warning
EOCONF
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_plpgsql_stub; '
	. 'CREATE EXTENSION test_otel_exporter');

$node->safe_psql(
	'postgres', q{
CREATE FUNCTION stb_child() RETURNS int AS $BODY$
BEGIN
	RETURN 1;
END;
$BODY$ LANGUAGE plpgsql;

CREATE FUNCTION stb_parent() RETURNS int AS $BODY$
DECLARE
	r int;
BEGIN
	r := stb_child();
	RETURN r + 1;
END;
$BODY$ LANGUAGE plpgsql;
});

my $combined = $node->safe_psql(
	'postgres', q{
	SET otel_plpgsql.trace_statements = on;
	SELECT test_otel_clear();
	SELECT 'RESULT:' || stb_parent();
	SELECT 'COUNT:' || test_otel_span_count();
});

my ($result) = $combined =~ /^RESULT:(\d+)$/m;
is($result, '2', 'the stub build runs the functions correctly (same results as the main build)');

my ($count) = $combined =~ /^COUNT:(\d+)$/m;
is($count, '0', 'the stub build captures no spans at all');

$node->stop;
done_testing();
