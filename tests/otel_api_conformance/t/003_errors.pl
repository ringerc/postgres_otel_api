# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Error paths: a span ended by its resource owner's release on abort is
# always exported with ERROR status, on top-level and subtransaction
# abort alike; otel_span_capture_error / otel_span_record_error in
# PG_CATCH; automatic top-level ERROR capture; ERROR injected between
# start and end via injection_points (skipped cleanly if unavailable).
# otel_api P2 design, "Conformance test suite" > "Error paths".
#
# Test-writing note: a span's default owner is the CURRENT STATEMENT's
# own portal.  A bare "SELECT otel_api_conformance_start(...);" followed
# later by a separate "ROLLBACK TO ...;" statement does NOT exercise
# subtransaction-abort unwind for a default-owned span: the start
# statement's own portal is released as a normal commit (a leak) the
# moment IT finishes successfully, before the later ROLLBACK TO ever
# runs.  The two genuine ways to exercise abort-unwind for a
# default-owned span are (a) the error happens within the SAME
# statement that started the span (its own portal then aborts, not
# commits) -- the injection_points scenario below -- or (b) the whole
# BEGIN/EXCEPTION block is itself one statement, e.g. a DO block, so
# the span's CurrentResourceOwner is plpgsql's own internal
# subtransaction owner throughout.  Top-level (real ROLLBACK, not
# ROLLBACK TO a savepoint) abort of a longer-lived span is tested with
# owner_mode => 'toptxn' instead.
# See also the header comment in t/001_construction.pl.

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
# otel_span_capture_error in PG_CATCH before FlushErrorState: the span
# carries an "exception" event with exception.type = SQLSTATE and
# exception.message.  (One self-contained C scenario: start, PG_TRY,
# ereport, PG_CATCH+capture, end -- all in one statement/portal.)
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_capture_error_scenario('conformance.captured_error') AS r \gset
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my @s = parse_spans($out);
	is(scalar(@s), 1, 'captured-error span was emitted (explicitly ended)');
	my $span = $s[0];
	is($span->{status}, 2, 'status is OTEL_STATUS_ERROR (2)');
	my ($ev) = grep { $_->{name} eq 'exception' } @{ $span->{events} };
	ok($ev, 'span has an "exception" event');
	my %eattrs = map { $_->{key} => $_ } @{ $ev->{attrs} };
	ok(exists $eattrs{'exception.type'}, 'exception event has exception.type');
	ok(exists $eattrs{'exception.message'}, 'exception event has exception.message');
	like($eattrs{'exception.message'}{value}, qr/induced error \(capture\)/,
		'exception.message carries the error text');
}

# ----------------------------------------------------------------
# otel_span_record_error, from an ErrorData the caller already has.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_record_error_scenario('conformance.recorded_error') AS r \gset
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my @s = parse_spans($out);
	my $span = $s[0];
	my ($ev) = grep { $_->{name} eq 'exception' } @{ $span->{events} };
	ok($ev, 'span has an "exception" event via record_error');
}

# ----------------------------------------------------------------
# Automatic capture of a top-level ERROR: a WARNING/LOG-level ereport
# does not abort, and the span ends normally.  An ERROR-level ereport
# aborts the statement (and hence its own default-owned span); the
# span is still emitted, by resource-owner release, with ERROR status.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_start_and_ereport('conformance.warned', 'warning') AS r \gset
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my @s = parse_spans($out);
	my ($span) = grep { $_->{name} eq 'conformance.warned' } @s;
	ok($span, 'WARNING-level ereport does not abort; span ends normally');
}

{
	# The span is not explicitly ended (ERROR aborts its own
	# statement/portal first), but otel_api's ResourceOwnerDesc release
	# on that abort exports it with ERROR status.  One connection
	# throughout: on_error_stop => 0 so the read-back after the
	# expected error still runs.
	my ($ret, $stdout, $stderr) = $node->psql(
		'postgres', <<'SQL',
SELECT otel_api_conformance_start_and_ereport('conformance.errored', 'error');
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SELECT otel_api_conformance_counters();
SQL
		on_error_stop => 0);
	like($stderr, qr/otel_api_conformance test ereport at error/,
		'the ERROR-level ereport aborts the statement');
	my ($spans_line, $counters_line) = split /\n/, $stdout, 2;
	my @s = parse_spans($spans_line);
	my ($span) = grep { $_->{name} eq 'conformance.errored' } @s;
	ok($span, 'the span is exported on its own statement abort');
	is($span->{status}, 2, 'unwound span has ERROR status') if $span;
	my $c = decode_json($counters_line);
	cmp_ok($c->{unwound}, '>=', 1, 'unwound counter increased');
}

# ----------------------------------------------------------------
# Top-level (real) transaction abort: a longer-lived (toptxn-owned)
# span, still open, is exported with ERROR status.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
BEGIN;
SELECT otel_api_conformance_start('conformance.toptxn_errored', owner_mode => 'toptxn') AS s1 \gset
ROLLBACK;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SELECT otel_api_conformance_counters();
SQL
	my ($spans_line, $counters_line) = split /\n/, $out, 2;
	my @s = parse_spans($spans_line);
	my ($span) = grep { $_->{name} eq 'conformance.toptxn_errored' } @s;
	ok($span, 'a toptxn-owned span is emitted on real ROLLBACK');
	is($span->{status}, 2, 'ERROR status on ROLLBACK unwind') if $span;
	my $c = decode_json($counters_line);
	cmp_ok($c->{unwound}, '>=', 1, 'unwound counter increased');
}

# ----------------------------------------------------------------
# plpgsql EXCEPTION block: the internal BEGIN/EXCEPTION subtransaction
# is CurrentResourceOwner for the span started inside it, all within
# one DO statement, so a default-owned span genuinely unwinds via
# subtransaction abort here.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
DO $$
BEGIN
	BEGIN
		PERFORM otel_api_conformance_start('conformance.plpgsql_caught', owner_mode => 'default');
		RAISE EXCEPTION 'conformance induced plpgsql error';
	EXCEPTION WHEN OTHERS THEN
		NULL;
	END;
END;
$$;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my @s = parse_spans($out);
	my ($span) = grep { $_->{name} eq 'conformance.plpgsql_caught' } @s;
	ok($span, 'span started inside a plpgsql EXCEPTION block is emitted (block-local abort)');
	is($span->{status}, 2, 'ERROR status on plpgsql-block unwind') if $span;
}

# ----------------------------------------------------------------
# ERROR injected between start and end via injection_points.  The
# injected error aborts the SAME statement that started the span, so
# a default-owned span genuinely unwinds here too.  Skipped cleanly if
# the injection_points module isn't installed, or if the injection
# point doesn't actually fire (core not built --enable-injection-points).
# ----------------------------------------------------------------
{
	my ($ret) = $node->psql('postgres', 'CREATE EXTENSION injection_points');
	if ($ret != 0)
	{
		diag('injection_points extension is not installed; skipping injection-point scenario');
		pass('injection-point scenario skipped (extension unavailable)');
	}
	else
	{
		$node->safe_psql('postgres',
			"SELECT injection_points_attach('otel_api_conformance-mid-span', 'error')");
		# Everything, including the read-back, must be ONE connection.
		# on_error_stop => 0: psql defaults to ON_ERROR_STOP=1, which
		# would abort this whole script at the expected error and never
		# reach the ROLLBACK TO / COMMIT / read-back that follow it.
		my ($eret, $stdout, $stderr) = $node->psql(
			'postgres', <<'SQL',
BEGIN;
SAVEPOINT sp1;
SELECT otel_api_conformance_injection_scenario('conformance.injected');
ROLLBACK TO sp1;
COMMIT;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
			on_error_stop => 0);
		if ($stderr !~ /otel_api_conformance-mid-span/ && $stderr !~ /injection/)
		{
			diag("injection point did not fire (core likely built without "
				. "--enable-injection-points); stderr was: $stderr");
			pass('injection-point scenario skipped (point did not fire)');
		}
		else
		{
			my @s = parse_spans($stdout);
			my ($span) = grep { $_->{name} eq 'conformance.injected' } @s;
			ok($span, 'span is exported with ERROR status when the injected error aborts the subxact');
			is($span->{status}, 2, 'ERROR status on injected abort') if $span;
		}
		$node->safe_psql('postgres',
			"SELECT injection_points_detach('otel_api_conformance-mid-span')");
	}
}

$node->stop;
done_testing();
