# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Every span ended by its resource owner's release on abort is exported
# with ERROR status: otel_api owns all span storage now, so exporting on
# unwind is always memory-safe, and there is no more DROP/ERROR unwind
# policy to choose between.  A child that ended normally before the abort
# must still be exported with its parent_span_id intact, and the parent
# itself must show up in the export with ERROR status: no exported span
# may have a missing parent.  Covers both a real (top-level) transaction
# abort and a subtransaction abort.

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

# No exported span in @spans has a parent that isn't either the zero root
# or another member of @spans.  Same pattern as t/012_interleaving.pl (a).
sub assert_no_orphans
{
	my ($spans, $label) = @_;
	my %span_ids = map { $_->{span_id} => 1 } @$spans;
	my @orphans = grep {
		$_->{parent_span_id} ne '0000000000000000'
		  && !$span_ids{ $_->{parent_span_id} }
	} @$spans;
	is(scalar(@orphans), 0, "$label: no exported span has a missing parent");
}

# ----------------------------------------------------------------
# Real (top-level) transaction abort: a toptxn-owned parent, still open
# when a later statement in the same transaction errors out, is unwound
# by the resource-owner release that ROLLBACK triggers.  Its child ended
# normally beforehand and was already exported.
# ----------------------------------------------------------------
{
	$node->safe_psql('postgres', 'SELECT otel_api_conformance_reset()');
	my ($ret, $stdout, $stderr) = $node->psql(
		'postgres', <<'SQL',
BEGIN;
SELECT otel_api_conformance_start('conformance.unwind_parent', owner_mode => 'toptxn') AS parent \gset
SELECT otel_api_conformance_start('conformance.unwind_child', owner_mode => 'toptxn') AS child \gset
SELECT otel_api_conformance_end(:child);
SELECT 1/0;
ROLLBACK;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' LIKE 'conformance.unwind_%';
SQL
		on_error_stop => 0);
	like($stderr, qr/division by zero/, 'the induced error aborts the transaction');

	my @s = parse_spans($stdout);
	my ($parent) = grep { $_->{name} eq 'conformance.unwind_parent' } @s;
	my ($child) = grep { $_->{name} eq 'conformance.unwind_child' } @s;

	ok($parent, 'top-level abort: the still-open parent is exported');
	is($parent->{status}, 2, 'top-level abort: the parent has ERROR status') if $parent;
	ok($child, 'top-level abort: the already-ended child is exported');
	is($child->{parent_span_id}, $parent->{span_id},
		"top-level abort: the child's parent_span_id is the parent's span_id")
		if $child && $parent;
	assert_no_orphans(\@s, 'top-level abort');
}

# ----------------------------------------------------------------
# Subtransaction abort: a default-owned parent, started inside a plpgsql
# EXCEPTION block's implicit subtransaction, is unwound when that
# subtransaction (not the whole top-level transaction) aborts.  Its
# child ended normally beforehand.
# ----------------------------------------------------------------
{
	$node->safe_psql('postgres', 'SELECT otel_api_conformance_reset()');
	my $out = $node->safe_psql('postgres', <<'SQL');
DO $$
DECLARE
	parent_ref bigint;
	child_ref bigint;
BEGIN
	BEGIN
		parent_ref := otel_api_conformance_start('conformance.unwind_sub_parent');
		child_ref := otel_api_conformance_start('conformance.unwind_sub_child');
		PERFORM otel_api_conformance_end(child_ref);
		RAISE EXCEPTION 'conformance induced subxact abort';
	EXCEPTION WHEN OTHERS THEN
		NULL;
	END;
END;
$$;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' LIKE 'conformance.unwind_sub_%';
SQL
	my @s = parse_spans($out);
	my ($parent) = grep { $_->{name} eq 'conformance.unwind_sub_parent' } @s;
	my ($child) = grep { $_->{name} eq 'conformance.unwind_sub_child' } @s;

	ok($parent, 'subxact abort: the still-open parent is exported');
	is($parent->{status}, 2, 'subxact abort: the parent has ERROR status') if $parent;
	ok($child, 'subxact abort: the already-ended child is exported');
	is($child->{parent_span_id}, $parent->{span_id},
		"subxact abort: the child's parent_span_id is the parent's span_id")
		if $child && $parent;
	assert_no_orphans(\@s, 'subxact abort');
}

$node->stop;
done_testing();
