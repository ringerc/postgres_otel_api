# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Attributes: every typed setter, lazy/side-effecting values (run only
# when sampled), truncation at otel_api.attr_value_max, the per-span
# byte cap (otel_api.max_span_bytes), events and links.  otel_api P2
# design, "Conformance test suite" > "Attributes".
#
# See the header comment in t/001_construction.pl for why every
# read-back is the last statement of the same psql invocation that ran
# the scenario, and why multi-statement spans use an explicit
# BEGIN...COMMIT with owner_mode => 'toptxn'.

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

# ----------------------------------------------------------------
# Every typed setter, plus set_name/set_status, are visible on the
# emitted span.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
BEGIN;
SELECT otel_api_conformance_start('conformance.attrs', owner_mode => 'toptxn') AS s \gset
SELECT otel_api_conformance_set_str(:s, 'k.str', 'hello') AS r1 \gset
SELECT otel_api_conformance_set_int(:s, 'k.int', 42) AS r2 \gset
SELECT otel_api_conformance_set_double(:s, 'k.double', 3.5) AS r3 \gset
SELECT otel_api_conformance_set_bool(:s, 'k.bool', true) AS r4 \gset
SELECT otel_api_conformance_set_printf(:s, 'k.printf', 'formatted-7') AS r5 \gset
SELECT otel_api_conformance_set_name(:s, 'conformance.attrs.renamed') AS r6 \gset
SELECT otel_api_conformance_set_status(:s, 'ok', NULL) AS r7 \gset
SELECT otel_api_conformance_end(:s) AS r8 \gset
COMMIT;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my @s = parse_spans($out);
	is(scalar(@s), 1, 'one span captured');
	my $span = $s[0];
	is($span->{name}, 'conformance.attrs.renamed', 'set_name renamed the span');
	is($span->{status}, 1, 'set_status(ok) recorded OTEL_STATUS_OK (1)');

	my %attrs = map { $_->{key} => $_ } @{ $span->{attrs} };
	is($attrs{'k.str'}{type}, 'string', 'str attr type');
	is($attrs{'k.str'}{value}, 'hello', 'str attr value');
	is($attrs{'k.int'}{type}, 'int', 'int attr type');
	is($attrs{'k.int'}{value}, 42, 'int attr value');
	is($attrs{'k.double'}{type}, 'double', 'double attr type');
	is($attrs{'k.double'}{value}, 3.5, 'double attr value');
	is($attrs{'k.bool'}{type}, 'bool', 'bool attr type');
	is($attrs{'k.bool'}{value}, JSON::PP::true, 'bool attr value');
	is($attrs{'k.printf'}{value}, 'formatted-7', 'printf attr value');
}

# ----------------------------------------------------------------
# Events with typed attributes, and links.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
BEGIN;
SELECT otel_api_conformance_start('conformance.events', owner_mode => 'toptxn') AS s \gset
SELECT otel_api_conformance_add_event(:s, 'conformance.ev', 'evstr', 7, 1.25, false) AS r1 \gset
SELECT encode(otel_api_conformance_context_of(:s), 'hex') AS ctxhex \gset
SELECT otel_api_conformance_add_link(:s, decode(:'ctxhex', 'hex')) AS r2 \gset
SELECT otel_api_conformance_end(:s) AS r3 \gset
COMMIT;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my @s = parse_spans($out);
	my $span = $s[0];
	is(scalar(@{ $span->{events} }), 1, 'one event captured');
	my $ev = $span->{events}[0];
	is($ev->{name}, 'conformance.ev', 'event name');
	my %eattrs = map { $_->{key} => $_ } @{ $ev->{attrs} };
	is($eattrs{'conformance.str'}{value}, 'evstr', 'event string attr');
	is($eattrs{'conformance.int'}{value}, 7, 'event int attr');
	is($eattrs{'conformance.double'}{value}, 1.25, 'event double attr');
	is($eattrs{'conformance.bool'}{value}, JSON::PP::false, 'event bool attr');

	is(scalar(@{ $span->{links} }), 1, 'one link captured (self-link)');
	is($span->{links}[0]{trace_id}, $span->{trace_id}, 'link trace_id matches its own context');
	is($span->{links}[0]{span_id}, $span->{span_id}, 'link span_id matches its own context');
}

# ----------------------------------------------------------------
# Truncation at otel_api.attr_value_max.
# ----------------------------------------------------------------
{
	# otel_api.attr_value_max's minimum is 16 bytes.
	my $out = $node->safe_psql('postgres', <<'SQL');
SET otel_api.attr_value_max = 16;
BEGIN;
SELECT otel_api_conformance_start('conformance.truncate', owner_mode => 'toptxn') AS s \gset
SELECT otel_api_conformance_set_str(:s, 'k.long', 'this value is much longer than 16 bytes') AS r1 \gset
SELECT otel_api_conformance_end(:s) AS r2 \gset
COMMIT;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SELECT otel_api_conformance_counters();
SQL
	my ($spans_line, $counters_line) = split /\n/, $out, 2;
	my @s = parse_spans($spans_line);
	my $span = $s[0];
	my %attrs = map { $_->{key} => $_ } @{ $span->{attrs} };
	ok(length($attrs{'k.long'}{value}) <= 16,
		'value truncated at otel_api.attr_value_max (got: ' . $attrs{'k.long'}{value} . ')');
	my $c = decode_json($counters_line);
	cmp_ok($c->{attr_truncated}, '>=', 1, 'attr_truncated counter increased');
}

# ----------------------------------------------------------------
# Per-span byte cap: many attributes should eventually be dropped and
# counted, without the span itself failing.
# ----------------------------------------------------------------
{
	my @setters;
	for my $i (1 .. 200)
	{
		push @setters,
			"SELECT otel_api_conformance_set_str(:s, 'k.$i', repeat('x', 64)) AS r$i \\gset";
	}
	# otel_api.max_span_bytes's minimum is 1024 bytes; 200 attrs of
	# ~64+ bytes each comfortably exceeds that.
	my $out = $node->safe_psql('postgres',
		"SET otel_api.attr_value_max = 1024;\n"
		. "SET otel_api.max_span_bytes = 1024;\n"
		. "BEGIN;\n"
		. "SELECT otel_api_conformance_start('conformance.overflow', owner_mode => 'toptxn') AS s \\gset\n"
		. join("\n", @setters)
		. "\nSELECT otel_api_conformance_end(:s) AS rend \\gset\n"
		. "COMMIT;\n"
		. "SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;\n"
		. "SELECT otel_api_conformance_counters();\n");
	my ($spans_line, $counters_line) = split /\n/, $out, 2;
	my @s = parse_spans($spans_line);
	my $span = $s[0];
	ok($span->{dropped_attrs} > 0,
		"dropped_attrs > 0 once otel_api.max_span_bytes is exceeded (got $span->{dropped_attrs})");
	my $c = decode_json($counters_line);
	cmp_ok($c->{attr_dropped}, '>=', 1, 'attr_dropped counter increased');
}

# ----------------------------------------------------------------
# OTEL_SPAN_SET_STR_IF_RECORDING: the expression is evaluated only when
# recording.  Both start+end for the span happen in one statement.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
SET otel_api.sampler = 'always_off';
SELECT otel_api_conformance_side_effect_count() AS before_count \gset
BEGIN;
SELECT otel_api_conformance_start('conformance.unsampled_side_effect', owner_mode => 'toptxn') AS s \gset
SELECT otel_api_conformance_if_recording_scenario(:s) AS r1 \gset
SELECT otel_api_conformance_end(:s) AS r2 \gset
COMMIT;
SELECT otel_api_conformance_side_effect_count() AS after_count \gset
SELECT :before_count AS before_count, :after_count AS after_count;
SQL
	my ($before, $after) = split /\|/, $out;
	is($after, $before,
		'OTEL_SPAN_SET_STR_IF_RECORDING does not evaluate its expression on an unsampled span');
}
{
	my $out = $node->safe_psql('postgres', <<'SQL');
SET otel_api.sampler = 'always_on';
SELECT otel_api_conformance_side_effect_count() AS before_count \gset
BEGIN;
SELECT otel_api_conformance_start('conformance.sampled_side_effect', owner_mode => 'toptxn') AS s \gset
SELECT otel_api_conformance_if_recording_scenario(:s) AS r1 \gset
SELECT otel_api_conformance_end(:s) AS r2 \gset
COMMIT;
SELECT otel_api_conformance_side_effect_count() AS after_count \gset
SELECT :before_count AS before_count, :after_count AS after_count;
SQL
	my ($before, $after) = split /\|/, $out;
	cmp_ok($after, '>', $before,
		'OTEL_SPAN_SET_STR_IF_RECORDING evaluates its expression on a recording span');
}

$node->stop;
done_testing();
