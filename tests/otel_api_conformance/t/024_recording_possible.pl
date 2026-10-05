# Copyright (c) 2026, PostgreSQL Global Development Group
#
# otel_recording_possible(): false when no span started now could be
# recorded, true otherwise.  True does not mean a span will be
# sampled.
#
# otel_api_conformance registers its own emit hook, so with otel_api
# loaded and otel_api.sampler not always_off, recording is always
# possible here.  Plain always_off is a full off switch (folded into
# this gate, not just a per-span sampling decision): it makes
# recording_possible false even with an emit hook registered.
# parentbased_always_off and traceidratio with sampler_arg = 0 are NOT
# full off switches -- they only affect the per-span sampling
# decision, so recording stays possible under them.

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
	'f', 'emit hook registered, but sampler = always_off: not possible');

is($node->safe_psql('postgres',
		"SET otel_api.sampler = 'always_on'; "
		  . "SELECT otel_api_conformance_recording_possible()"),
	't', 'switching the sampler away from always_off in-session makes it possible again');

is($node->safe_psql('postgres',
		"SET otel_api.sampler = 'always_off'; "
		  . "SET otel_api.sampler = 'parentbased_always_off'; "
		  . "SELECT otel_api_conformance_recording_possible()"),
	't', 'parentbased_always_off is not a full off switch: still possible');

is($node->safe_psql('postgres',
		"SET otel_api.sampler = 'always_off'; "
		  . "SET otel_api.sampler = 'traceidratio'; "
		  . "SET otel_api.sampler_arg = 0; "
		  . "SELECT otel_api_conformance_recording_possible()"),
	't', 'traceidratio with sampler_arg = 0 is not a full off switch: still possible');

# ----------------------------------------------------------------
# Switching the sampler to always_off while a recording span is open:
# the span still ends and exports normally; a new span started while
# always_off is in effect returns OTEL_SPAN_NONE; the context a new
# child would propagate (span_context_of(OTEL_SPAN_NONE)) still gives
# the still-open span's own context, taken from the active stack, not
# from the (irrelevant) sampler setting.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
SET otel_api.sampler = 'always_on';
BEGIN;
SELECT otel_api_conformance_start('conformance.recording_possible.open', owner_mode => 'toptxn') AS s \gset
SET otel_api.sampler = 'always_off';
SELECT otel_api_conformance_recording_possible() AS possible_now;
SELECT otel_api_conformance_start('conformance.recording_possible.new_while_off') AS fresh \gset
SELECT :fresh AS fresh_is_none;
SELECT encode(otel_api_conformance_current_context(), 'hex') AS wire \gset
SELECT encode(otel_api_conformance_context_of(:s), 'hex') AS span_wire \gset
SELECT otel_api_conformance_end(:s) AS r1 \gset
COMMIT;
SELECT :'wire' = :'span_wire' AS contexts_match;
SELECT jsonb_agg(sp) FROM otel_api_conformance_spans() sp WHERE sp->>'name' = 'conformance.recording_possible.open';
SQL
	my @lines = split /\n/, $out;
	my ($possible_now, $fresh_is_none, $contexts_match, $spans_line) = @lines;

	is($possible_now, 'f',
		'recording_possible() is false right after switching to always_off mid-span');
	is($fresh_is_none, '0',
		'a span started while always_off returns OTEL_SPAN_NONE');
	is($contexts_match, 't',
		'span_context_of(OTEL_SPAN_NONE) still resolves to the still-open span\'s context');

	$spans_line //= '';
	like($spans_line, qr/"name":\s*"conformance\.recording_possible\.open"/,
		'the span that was open when the sampler switched to always_off still exports normally');
}

# ----------------------------------------------------------------
# Pass-through: an incoming W3C context is unaffected by always_off.
# span_context_of(OTEL_SPAN_NONE) -- what a producer would propagate
# to a child, or forward to a remote call -- reads the active stack
# or the root context directly; it never consults the sampler or
# recording_possible, so this holds regardless of otel_api.sampler.
# With no incoming context at all, it reports none either way.
#
# Note: because this path never touches the sampler, these three
# assertions hold before this feature too (they'd already pass against
# the pre-always_off-as-off-switch code) -- they're here to pin down,
# not merely assume, the "incoming context still propagates unchanged"
# claim this feature's documentation makes. The parallel-worker case
# (leader-published context read by a worker with an empty stack) goes
# through the same otel_span_context_of() path and isn't re-tested
# here; t/010_parallel.pl's own setup (parallel query plans, a
# generated table, non-deterministic worker launch) is too heavy to
# fold in just for this.
# ----------------------------------------------------------------
{
	my $trace_id = 'aabbccddeeff00112233445566778899';
	my $span_id  = '0011223344556677';
	my $tp       = "00-$trace_id-$span_id-01";

	my $out = $node->safe_psql('postgres', <<SQL);
SET otel_api.sampler = 'always_off';
SET otel_api.traceparent = '$tp';
SELECT encode(otel_api_conformance_current_context(), 'hex') AS wire \\gset
SELECT otel_api_conformance_context_recv(decode(:'wire', 'hex')) AS ctx;
SQL
	is($out, "$trace_id;$span_id;1;",
		'always_off: an incoming context passes through span_context_of(NONE) exactly (trace_id, span_id, flags)'
	);
}

{
	my $out = $node->safe_psql('postgres', <<'SQL');
SET otel_api.sampler = 'always_off';
RESET otel_api.traceparent;
SELECT otel_api_conformance_current_context() IS NULL AS no_context;
SQL
	is($out, 't',
		'always_off: with no incoming context, span_context_of(NONE) reports none');
}

# Contrast: under traceidratio/0, the same incoming context still
# reaches the sampler via otel_span_start() (it's not a full off
# switch), is dropped (nrec), but gets a freshly minted span_id -- the
# same trace_id, a different span_id than the one that came in. This
# is pre-existing sampler behaviour, unchanged by this feature; shown
# here only to contrast with always_off's exact pass-through above.
{
	my $trace_id = 'aabbccddeeff00112233445566778899';
	my $span_id  = '0011223344556677';
	my $tp       = "00-$trace_id-$span_id-01";

	my $out = $node->safe_psql('postgres', <<SQL);
SET otel_api.sampler = 'traceidratio';
SET otel_api.sampler_arg = 0;
SET otel_api.traceparent = '$tp';
BEGIN;
SELECT otel_api_conformance_start('conformance.recording_possible.passthrough_child',
	owner_mode => 'toptxn') AS s \\gset
SELECT otel_api_conformance_recording(:s) AS recording;
SELECT encode(otel_api_conformance_context_of(:s), 'hex') AS wire \\gset
SELECT otel_api_conformance_end(:s) AS r1 \\gset
COMMIT;
SELECT otel_api_conformance_context_recv(decode(:'wire', 'hex')) AS ctx;
SQL
	my @lines  = split /\n/, $out;
	my ($recording, $ctx_line) = @lines;
	is($recording, 'f', 'traceidratio/0: the child of the remote context is dropped (nrec)');

	my ($child_trace, $child_span) = split /;/, $ctx_line;
	is($child_trace, $trace_id,
		'traceidratio/0: the dropped child still shares the incoming trace_id');
	isnt($child_span, $span_id,
		"traceidratio/0: ...but gets a freshly minted span_id, unlike always_off's exact pass-through"
	);
}

$node->stop;
done_testing();
