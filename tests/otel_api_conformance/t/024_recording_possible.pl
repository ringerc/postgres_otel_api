# Copyright (c) 2026, PostgreSQL Global Development Group
#
# otel_recording_possible(): false when no span started now could be
# recorded, true otherwise.  True does not mean a span will be sampled.
#
# otel_api_conformance registers its own emit hook, so with otel_api
# loaded recording is always possible here.  The false case is otel_api
# not loaded at all.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'otel_api_conformance'\n");
$node->start;
$node->safe_psql('postgres', 'CREATE EXTENSION otel_api_conformance');

is($node->safe_psql('postgres', 'SELECT otel_api_conformance_recording_possible()'),
	'f', 'otel_api not loaded: not possible');

$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'otel_api,otel_api_conformance'\n"
	  . "otel_api.sampler = 'always_off'\n");
$node->restart;
$node->safe_psql('postgres', 'CREATE EXTENSION otel_api');
is($node->safe_psql('postgres', 'SELECT otel_api_conformance_recording_possible()'),
	't', 'emit hook registered: possible, even with sampler always_off');

$node->stop;
done_testing();
