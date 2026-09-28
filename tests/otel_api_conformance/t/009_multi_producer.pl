# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Multiple producers: two OtelTracer scopes (tracer_a / tracer_b, both
# inside otel_api_conformance) interleaving spans, including out of
# LIFO order, and one of them erroring.  otel_api P2 design,
# "Conformance test suite" > "Multiple producers".
#
# See the header comment in t/001_construction.pl for why every
# read-back is the last statement of the same psql invocation, and why
# a span meant to survive across statements needs owner_mode =>
# 'toptxn' inside an explicit BEGIN...COMMIT.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use JSON::PP;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'otel_api,otel_api_conformance'\n"
	  # Misuse Asserts crash the backend in cassert builds; the test
	  # waits for crash recovery and carries on.
	  . "restart_after_crash = on\n");
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_api_conformance');

my $cassert = $node->safe_psql('postgres', 'SHOW debug_assertions');

sub parse_spans
{
	my ($out) = @_;
	return () if !defined $out || $out eq '';
	return @{ decode_json($out) };
}

# See t/008_misuse.pl for why this polls rather than scanning the log.
sub wait_for_restart
{
	my $deadline = time() + $PostgreSQL::Test::Utils::timeout_default;
	while (time() < $deadline)
	{
		# See t/008_misuse.pl: psql() itself can die right after the
		# crash, before the postmaster is listening again.
		my $ok = eval {
			my ($ret, $stdout, $stderr) =
				$node->psql('postgres', 'SELECT 1', on_error_stop => 0);
			return $ret == 0;
		};
		return 1 if $ok;
		select(undef, undef, undef, 0.2);
	}
	return 0;
}

# ----------------------------------------------------------------
# Two producers interleaving LIFO-correctly.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
BEGIN;
SELECT otel_api_conformance_start('conformance.a1', producer => 'a', owner_mode => 'toptxn') AS a1 \gset
SELECT otel_api_conformance_start('conformance.b1', producer => 'b', parent_mode => 'active', owner_mode => 'toptxn') AS b1 \gset
SELECT otel_api_conformance_end(:b1) AS r1 \gset
SELECT otel_api_conformance_end(:a1) AS r2 \gset
COMMIT;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my @s = parse_spans($out);
	my ($a1) = grep { $_->{name} eq 'conformance.a1' } @s;
	my ($b1) = grep { $_->{name} eq 'conformance.b1' } @s;
	ok($a1 && $b1, 'both producers emitted a span');
	is($a1->{scope_name}, 'otel_api_conformance.a', 'a1 carries the "a" scope');
	is($b1->{scope_name}, 'otel_api_conformance.b', 'b1 carries the "b" scope');
	is($b1->{parent_span_id}, $a1->{span_id}, 'producer b nested correctly under producer a');
}

# ----------------------------------------------------------------
# Out-of-LIFO order: producer a starts, producer b starts nested, but
# a ends first (while b is still open).  Ending an outer span unwinds
# the ones above it under their own policy, with a WARNING -- and, per
# otel_producer.h's documented rules, an Assert in cassert builds (this
# is the same check otel_api_conformance_misuse_non_lifo() exercises in
# t/008_misuse.pl; here it's the same situation arising incidentally
# between two different producers, not a dedicated misuse call).
# ----------------------------------------------------------------
{
	my $log_start = -s $node->logfile;
	my ($ret, $stdout, $stderr) = $node->psql('postgres', <<'SQL');
BEGIN;
SELECT otel_api_conformance_start('conformance.a2', producer => 'a', owner_mode => 'toptxn') AS a2 \gset
SELECT otel_api_conformance_start('conformance.b2', producer => 'b', parent_mode => 'active', owner_mode => 'toptxn') AS b2 \gset
SELECT otel_api_conformance_end(:a2) AS r1 \gset
COMMIT;
SQL
	if ($cassert eq 'on')
	{
		isnt($ret, 0, 'a non-LIFO end between two producers Asserts in a cassert build');
		my $log_contents = PostgreSQL::Test::Utils::slurp_file($node->logfile, $log_start);
		like($log_contents, qr/WARNING.*ended with spans still open/,
			'a WARNING is logged for the non-LIFO end before the Assert');
		like($log_contents, qr/TRAP:|Assert/, 'server log shows an Assert failure');
		ok(wait_for_restart(), 'server accepts connections again after the crash')
			or BAIL_OUT('server did not come back up after the induced crash');
	}
	else
	{
		is($ret, 0, 'ending the outer span while the inner is still open does not error out');
		like($stderr, qr/WARNING/i, 'a WARNING is logged for the non-LIFO end');
	}
}

# ----------------------------------------------------------------
# One producer erroring while the other has an open span: a's
# toptxn-owned span (unwind=drop) is dropped when the whole
# transaction later rolls back; b's error-scenario span is
# self-contained (started, errored, captured and ended all within its
# own single statement) and was already emitted well before that.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
BEGIN;
SELECT otel_api_conformance_start('conformance.a3', producer => 'a', owner_mode => 'toptxn', unwind => 'drop') AS a3 \gset
SELECT otel_api_conformance_capture_error_scenario('conformance.b3_captured') AS r \gset
ROLLBACK;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my @s = parse_spans($out);
	is(scalar(grep { $_->{name} eq 'conformance.a3' } @s), 0,
		"producer a's open span (unwind=drop) is discarded on the transaction abort");
	ok((grep { $_->{name} eq 'conformance.b3_captured' } @s),
		"producer b's explicitly-ended, error-captured span was emitted before the abort");
}

$node->stop;
done_testing();
