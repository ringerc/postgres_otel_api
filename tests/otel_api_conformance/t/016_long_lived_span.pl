# Copyright (c) 2026, PostgreSQL Global Development Group
#
# A long-lived (session) span that accumulates an event and an
# attribute in each of many transactions, past otel_api.max_span_bytes.
# otel_api P2 edge-case plan, item 5 (postgres-cdq.9.5).
#
# Today: capped by otel_api.max_span_bytes; data past the cap is
# dropped and counted (event_dropped / attr_dropped, and the span's own
# dropped_events / dropped_attrs), memory stays bounded, and the span
# ends and exports cleanly regardless.  There is no flush-at-overflow
# marker.
#
# Approved future direction (design decision pending; see
# docs/plans/otel-api-edge-case-tests.md and the bead): when the cap is
# about to be reached, otel_api adds one overflow event and one
# overflow attribute of its own (the budget reserves room so they
# always fit), then drops everything else -- but does NOT set ERROR
# status (it describes the operation, not the telemetry pipe).  The
# names used below, otel_api.overflow (event) and
# otel_api.span.overflowed (attribute), are placeholders picked for
# this test; they are not final.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use JSON::PP;
use Time::HiRes qw(time);

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'otel_api,otel_api_conformance'\n"
	# Many small commits in the big-n scenario below; this is test
	# infrastructure speed, not something otel_api cares about.
	. "synchronous_commit = off\n"
	. "fsync = off\n");
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_api_conformance');

sub parse_spans
{
	my ($out) = @_;
	return () if !defined $out || $out eq '';
	return @{ decode_json($out) };
}

$node->safe_psql('postgres', <<'SQL');
CREATE OR REPLACE PROCEDURE conformance_long_lived_loop(ref bigint, n integer) LANGUAGE plpgsql AS $body$
DECLARE
	i integer;
BEGIN
	FOR i IN 1..n LOOP
		PERFORM otel_api_conformance_add_event(ref, 'conformance.tick', NULL, i::bigint, NULL, NULL);
		PERFORM otel_api_conformance_set_int(ref, format('conformance.attr.%s', i), i);
		COMMIT;
	END LOOP;
END;
$body$;
SQL

# ----------------------------------------------------------------
# Low cap: otel_api.max_span_bytes set small, so the loop overflows it
# quickly.  Runs in a fraction of a second.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
SET otel_api.max_span_bytes = 4096;
SELECT otel_api_conformance_reset() AS r1 \gset
SELECT otel_api_conformance_start_session('conformance.long_lived.low_cap') AS ref \gset
CALL conformance_long_lived_loop(:ref, 300);
SELECT otel_api_conformance_backend_mem_bytes() AS mem_mid \gset
SELECT :mem_mid;
CALL conformance_long_lived_loop(:ref, 300);
SELECT otel_api_conformance_backend_mem_bytes() AS mem_after \gset
SELECT :mem_after;
SELECT otel_api_conformance_end(:ref) AS r2 \gset
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' = 'conformance.long_lived.low_cap';
SELECT otel_api_conformance_counters();
SQL
	my @lines = split /\n/, $out;
	my ($mem_mid, $mem_after) = ($lines[0], $lines[1]);
	my ($span) = grep { $_->{name} eq 'conformance.long_lived.low_cap' } parse_spans($lines[2]);
	my $c = decode_json($lines[3]);

	ok($span, 'low cap: the session span still ends and exports cleanly after overflowing the cap');
	cmp_ok($span->{dropped_events}, '>', 0, 'low cap: the span itself counts dropped events') if $span;
	cmp_ok($span->{dropped_attrs}, '>', 0, 'low cap: the span itself counts dropped attributes') if $span;
	cmp_ok($c->{event_dropped}, '>', 0, 'low cap: event_dropped counter moved');
	cmp_ok($c->{attr_dropped}, '>', 0, 'low cap: attr_dropped counter moved');
	# The first 300-iteration pass already overflows a 4KB cap; a
	# second 300-iteration pass on top of that should add only a small,
	# roughly constant amount of backend memory (bookkeeping for 300
	# more otherwise-dropped attempts), not another ~4KB+ of real span
	# growth -- generously, well under half of what a second full quota
	# would cost if the cap weren't enforced.
	cmp_ok($mem_after - $mem_mid, '<', 2 * 4096,
		"low cap: memory growth from a further 300 (all-dropped) iterations stays small "
		. "(+" . ($mem_after - $mem_mid) . " bytes)");
	isnt($span->{status}, 2, 'low cap: overflow alone does not give the span ERROR status') if $span;
	cmp_ok(scalar(@{ $span->{events} // [] }), '<', 300,
		"low cap: far fewer than 300 events actually made it into the export") if $span;

	{
		local $TODO = 'desired future behaviour (design decision pending): otel_api should add its own '
			. 'overflow event once the cap is about to be reached (placeholder name otel_api.overflow, '
			. 'not final)';
		ok((grep { $_->{name} eq 'otel_api.overflow' } @{ $span->{events} // [] }),
			'low cap: [desired] an otel_api.overflow event is present') if $span;
	}
	{
		local $TODO = 'desired future behaviour (design decision pending): otel_api should add its own '
			. 'overflow attribute once the cap is about to be reached (placeholder name '
			. 'otel_api.span.overflowed, not final)';
		ok((grep { $_->{key} eq 'otel_api.span.overflowed' } @{ $span->{attrs} // [] }),
			'low cap: [desired] an otel_api.span.overflowed attribute is present') if $span;
	}
}

# ----------------------------------------------------------------
# Default cap, a real stress size (>= 10000 transactions), to show the
# ordinary-sized budget also holds up under sustained pressure and the
# run stays fast.  otel_api_conformance.capture_spans is turned off for
# this one so the *test extension's* own capture list doesn't grow
# without bound -- that's this test's memory, not otel_api's; otel_api's
# own memory is what otel_api_conformance_backend_mem_bytes() measures,
# and TopMemoryContext includes both, so the comparison below still
# only means something if the test's own growth is disabled here.
# ----------------------------------------------------------------
{
	my $n = 10000;
	my $t0 = time();
	my $out = $node->safe_psql('postgres', <<SQL);
SET otel_api_conformance.capture_spans = off;
SELECT otel_api_conformance_reset() AS r1 \\gset
SELECT otel_api_conformance_start_session('conformance.long_lived.default_cap') AS ref \\gset
SELECT otel_api_conformance_backend_mem_bytes() AS mem_before \\gset
SELECT :mem_before;
CALL conformance_long_lived_loop(:ref, $n / 2);
SELECT otel_api_conformance_backend_mem_bytes() AS mem_mid \\gset
SELECT :mem_mid;
CALL conformance_long_lived_loop(:ref, $n / 2);
SELECT otel_api_conformance_backend_mem_bytes() AS mem_after \\gset
SELECT :mem_after;
SET otel_api_conformance.capture_spans = on;
SELECT otel_api_conformance_end(:ref) AS r2 \\gset
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' = 'conformance.long_lived.default_cap';
SELECT otel_api_conformance_counters();
SQL
	my $elapsed = time() - $t0;
	cmp_ok($elapsed, '<', 60, "default cap: $n transactions with an event+attribute each complete in under 60s "
		. "(took ${elapsed}s)");

	my @lines = split /\n/, $out;
	my ($mem_before, $mem_mid, $mem_after) = ($lines[0], $lines[1], $lines[2]);
	my ($span) = grep { $_->{name} eq 'conformance.long_lived.default_cap' } parse_spans($lines[3]);
	my $c = decode_json($lines[4]);

	ok($span, "default cap: the session span still ends and exports cleanly after $n transactions");
	cmp_ok($c->{event_dropped}, '>', 0,
		"default cap: $n unique-keyed attributes plus events still overflow the default 64KB budget");
	cmp_ok($c->{attr_dropped}, '>', 0, 'default cap: attr_dropped counter moved');

	my $growth_first_half = $mem_mid - $mem_before;
	my $growth_second_half = $mem_after - $mem_mid;
	cmp_ok($growth_second_half, '<', $growth_first_half,
		"default cap: memory growth plateaus once the cap is hit (first half +$growth_first_half bytes, "
		. "second half +$growth_second_half bytes)");
}

$node->stop;
done_testing();
