# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Propagation: otel_traceparent_format/parse round trip incl. invalid
# inputs; otel_span_context_send/recv round trip incl. tracestate,
# unknown version skipped, truncated message errors; a simulated
# cross-node hop.  otel_api P2 design, "Conformance test suite" >
# "Propagation".

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use JSON::PP;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'otel_api,otel_api_conformance'\n");
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_api_conformance');

sub parse_spans
{
	my ($out) = @_;
	return () if !defined $out || $out eq '';
	return @{ decode_json($out) };
}

my $trace_id = 'aabbccddeeff00112233445566778899';
my $span_id  = '0011223344556677';

# ----------------------------------------------------------------
# traceparent round trip.
# ----------------------------------------------------------------
{
	my $tp = "00-$trace_id-$span_id-01";
	my $out = $node->safe_psql('postgres',
		"SELECT otel_api_conformance_traceparent_roundtrip('$tp')");
	is($out, $tp, 'valid version-00 traceparent round-trips exactly');
}

for my $case (
	[ 'uppercase trace id',
		"00-" . uc($trace_id) . "-$span_id-01" ],
	[ 'all-zero trace id',
		"00-" . ('0' x 32) . "-$span_id-01" ],
	[ 'all-zero span id',
		"00-$trace_id-" . ('0' x 16) . "-01" ],
	[ 'version ff',
		"ff-$trace_id-$span_id-01" ],
	[ 'wrong length (truncated)',
		"00-$trace_id-$span_id-0" ],
  )
{
	my ($desc, $tp) = @$case;
	my $out = $node->safe_psql('postgres',
		"SELECT otel_api_conformance_traceparent_roundtrip('$tp')");
	is($out, '', "invalid traceparent ($desc) is rejected");
}

# Future version with a trailing field: version 01, 56 chars means an
# extra '-' plus field after the flags byte is tolerated (parsed as the
# known prefix; anything past position 55 is ignored).
{
	my $tp = "01-$trace_id-$span_id-01-extra";
	my $out = $node->safe_psql('postgres',
		"SELECT otel_api_conformance_traceparent_roundtrip('$tp')");
	isnt($out, '', 'a future version with a trailing field is accepted (known prefix parsed)');
}

# ----------------------------------------------------------------
# Binary send/recv round trip, incl. tracestate.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<SQL);
SELECT encode(otel_api_conformance_context_send('$trace_id', '$span_id', 1, 'vendor=1'), 'hex') AS wire \\gset
SELECT otel_api_conformance_context_recv(decode(:'wire', 'hex'));
SQL
	is($out, "$trace_id;$span_id;1;vendor=1", 'binary context round-trips incl. tracestate');
}

# Truncated message: recv should raise an ERROR (per its documented
# contract), not silently succeed.
{
	my ($ret, $stdout, $stderr) = $node->psql('postgres', <<SQL);
SELECT encode(otel_api_conformance_context_send('$trace_id', '$span_id', 1), 'hex') AS wire \\gset
SELECT otel_api_conformance_context_recv(decode(substr(:'wire', 1, 10), 'hex'));
SQL
	isnt($ret, 0, 'a truncated binary context message raises an ERROR on recv');
}

# Unknown format version: recv should skip the record and report
# "invalid" (NULL from our wrapper), not crash.
{
	# Byte 0 is the format version; 99 (0x63) is not
	# OTEL_SPAN_CONTEXT_WIRE_V1 (1).  Build a well-formed-otherwise
	# record so the length prefix lets recv skip it cleanly.
	my $out = $node->safe_psql('postgres', <<SQL);
SELECT encode(otel_api_conformance_context_send('$trace_id', '$span_id', 1), 'hex') AS wire \\gset
SELECT otel_api_conformance_context_recv(decode('63' || substr(:'wire', 3), 'hex'));
SQL
	is($out, '', 'an unknown format version is skipped and reported as invalid, not crashed on');
}

# ----------------------------------------------------------------
# Simulated cross-node hop: serialise a span's context, then start a
# child of it "on the other side" (a second, independent call, but
# still within one connection so the captured spans are visible; see
# t/001_construction.pl's header comment).  Both spans use owner_mode
# => 'toptxn' inside one BEGIN...COMMIT since each is started and
# ended in separate statements.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
BEGIN;
SELECT otel_api_conformance_start('conformance.sender', detached => true, owner_mode => 'toptxn') AS sender \gset
SELECT encode(otel_api_conformance_context_of(:sender), 'hex') AS wire \gset
SELECT otel_api_conformance_end(otel_api_conformance_start_from_context(decode(:'wire', 'hex'), 'conformance.receiver')) AS r1 \gset
SELECT otel_api_conformance_end(:sender) AS r2 \gset
COMMIT;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my @s = parse_spans($out);
	my ($sender) = grep { $_->{name} eq 'conformance.sender' } @s;
	my ($receiver) = grep { $_->{name} eq 'conformance.receiver' } @s;
	ok($sender && $receiver, 'both sides of the simulated hop captured');
	is($receiver->{trace_id}, $sender->{trace_id}, 'receiver shares the sender trace_id');
	is($receiver->{parent_span_id}, $sender->{span_id}, 'receiver parents to the sender span_id');
}

$node->stop;
done_testing();
