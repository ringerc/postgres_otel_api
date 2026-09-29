# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Ownership: the default resource owner; TopTransactionResourceOwner
# for spans across statements; a caller-created owner; session spans
# (across transactions, and in a background worker outside any
# transaction); the leak warning at commit.  otel_api P2 design,
# "Conformance test suite" > "Ownership".
#
# See the header comment in t/001_construction.pl for the general
# same-connection / ownership rules this file follows.

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
# Default owner: starts and ends within one statement, so its portal
# owner never gets a chance to release it as a leak.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_end(otel_api_conformance_start('conformance.default_owner')) AS r \gset
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my @s = parse_spans($out);
	ok((grep { $_->{name} eq 'conformance.default_owner' } @s), 'default-owner span emitted normally');
}

# ----------------------------------------------------------------
# TopTransactionResourceOwner: a span kept open across two statements
# in the same transaction, ended in a third.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
BEGIN;
SELECT otel_api_conformance_start('conformance.toptxn', owner_mode => 'toptxn') AS s \gset
SELECT otel_api_conformance_set_int(:s, 'conformance.step', 2) AS r1 \gset
SELECT otel_api_conformance_end(:s) AS r2 \gset
COMMIT;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my @s = parse_spans($out);
	ok((grep { $_->{name} eq 'conformance.toptxn' } @s),
		'TopTransactionResourceOwner span survives across statements and ends cleanly');
}

# ----------------------------------------------------------------
# Caller-created owner, released explicitly (commit and abort paths).
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_create_owner('conformance.custom_owner') AS oid \gset
SELECT otel_api_conformance_start('conformance.custom_commit', owner_mode => 'custom', owner_id => :oid, detached => true) AS s \gset
SELECT otel_api_conformance_end(:s) AS r1 \gset
SELECT otel_api_conformance_release_owner(:oid, true) AS r2 \gset
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my @s = parse_spans($out);
	ok((grep { $_->{name} eq 'conformance.custom_commit' } @s),
		'caller-created owner, ended explicitly, then released (commit)');
}

{
	# Leave the span open; releasing the owner with do_commit=false
	# unwinds it, exporting it with ERROR status, rather than committing it.
	my $out = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_create_owner('conformance.custom_owner2') AS oid \gset
SELECT otel_api_conformance_start('conformance.custom_abort', owner_mode => 'custom', owner_id => :oid, detached => true) AS s \gset
SELECT otel_api_conformance_release_owner(:oid, false) AS r \gset
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my @s = parse_spans($out);
	my ($span) = grep { $_->{name} eq 'conformance.custom_abort' } @s;
	ok($span, 'releasing a custom owner with do_commit=false unwinds an open span, exporting it');
	is($span->{status}, 2, 'ERROR status on a custom-owner unwind') if $span;
}

# ----------------------------------------------------------------
# Session spans across several transactions.
# ----------------------------------------------------------------
{
	my $out = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_start_session('conformance.session_multi_txn') AS s \gset
BEGIN;
SELECT otel_api_conformance_set_int(:s, 'conformance.txn', 1) AS r1 \gset
COMMIT;
BEGIN;
SELECT otel_api_conformance_set_int(:s, 'conformance.txn', 2) AS r2 \gset
COMMIT;
SELECT otel_api_conformance_end(:s) AS r3 \gset
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SQL
	my @s = parse_spans($out);
	ok((grep { $_->{name} eq 'conformance.session_multi_txn' } @s),
		'session span ended normally after spanning several transactions');
}

# ----------------------------------------------------------------
# Background worker: emits a session span outside any transaction and
# a default-owner child span inside a transaction.  Its emitted spans
# live in the worker's own backend-local capture list, not visible to
# this session, so we check the side effect it leaves behind instead.
# ----------------------------------------------------------------
{
	$node->safe_psql('postgres', 'SELECT otel_api_conformance_launch_bgworker()');
	my $count = $node->safe_psql('postgres',
		"SELECT count(*) FROM otel_api_conformance_log WHERE event = 'bgworker_ran'");
	cmp_ok($count, '>=', 1,
		'background worker ran: session span + transactional child span + SPI insert completed');
}

# ----------------------------------------------------------------
# Leak at commit: a span left open when its owner is released on
# commit is dropped (not emitted), counted, and core prints "resource
# was not closed".
# ----------------------------------------------------------------
{
	my ($ret, $stdout, $stderr) = $node->psql('postgres', <<'SQL');
BEGIN;
SELECT otel_api_conformance_start('conformance.leaked', owner_mode => 'toptxn', detached => true);
COMMIT;
SQL
	is($ret, 0, 'commit with an open toptxn-owned span does not fail the transaction');
	like($stderr, qr/resource was not closed/, 'core warns "resource was not closed" on the leak');

	my $out = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_reset() AS rreset \gset
BEGIN;
SELECT otel_api_conformance_start('conformance.leaked2', owner_mode => 'toptxn', detached => true) AS s \gset
COMMIT;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;
SELECT otel_api_conformance_counters();
SQL
	my ($spans_line, $counters_line) = split /\n/, $out, 2;
	my @s = parse_spans($spans_line);
	is(scalar(grep { $_->{name} eq 'conformance.leaked2' } @s), 0,
		'the leaked span is dropped, not emitted');
	my $c = decode_json($counters_line);
	cmp_ok($c->{leaked_at_commit}, '>=', 1, 'leaked_at_commit counter increased');
}

$node->stop;
done_testing();
