# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Span per PL/pgSQL function call (pg.plpgsql.function): nesting across a
# plpgsql-to-plpgsql call, and a fresh root (independent sampling
# decision) for each outermost call.
#
# test_otel_exporter's capture ring is per-backend, so produce and read
# back spans within the same safe_psql() invocation (one backend).

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf', <<EOCONF);
shared_preload_libraries = 'otel_api,otel_plpgsql,test_otel_exporter'
log_min_messages = warning
EOCONF
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_plpgsql; '
	. 'CREATE EXTENSION test_otel_exporter');

$node->safe_psql(
	'postgres', q{
CREATE FUNCTION otp_child() RETURNS void AS $BODY$
BEGIN
	PERFORM 1;
END;
$BODY$ LANGUAGE plpgsql;

CREATE FUNCTION otp_parent() RETURNS void AS $BODY$
BEGIN
	PERFORM otp_child();
END;
$BODY$ LANGUAGE plpgsql;
});

# Parse a flat key=value\n blob (see test_otel_exporter's format_span) into
# a hash.  "attr=key=value" lines (span attributes) nest under $h{attr}
# keyed by the attribute name; everything else is a top-level scalar.
sub parse_kv
{
	my ($text) = @_;
	my %h;
	for my $line (split /\n/, $text // '')
	{
		if ($line =~ /^attr=([^=]+)=(.*)$/)
		{
			$h{attr}{$1} = $2;
		}
		elsif ($line =~ /^([^=]+)=(.*)$/)
		{
			$h{$1} = $2;
		}
	}
	return \%h;
}

# SQL to pop every captured span, marked so the result can be split back
# into per-span chunks: CAPTURE_RING_SIZE in test_otel_exporter.c is 32,
# and popping that many times is always safe (test_otel_pop_span()
# returns NULL, not an error, once the ring is empty).  This must be
# appended to the SAME safe_psql() script that produced the spans: the
# capture ring is per-backend state, and safe_psql() starts a new backend
# on every call, so popping in a separate call would just see an empty
# ring.
my $pop_all_spans_sql = join('',
	map { "SELECT '===SPAN===' || coalesce(test_otel_pop_span(), '');\n" }
	(1 .. 32));

# Split the '===SPAN===' - marked tail of a combined safe_psql() result
# into per-span hashes (see parse_kv above); a NULL pop is empty between
# markers and is dropped.
sub parse_popped_spans
{
	my ($out) = @_;
	my @chunks = split /===SPAN===/, $out;
	shift @chunks;				# text (if any) before the first marker
	my @spans;
	for my $c (@chunks)
	{
		next if $c !~ /\S/;		# NULL pop: nothing but whitespace
		push @spans, parse_kv($c);
	}
	return @spans;
}

# --------------------------------------------------------------------
# One call to otp_parent(), which calls otp_child(): both function spans
# must land in the same trace, and otp_child()'s function span's parent
# must point at something captured from inside otp_parent()'s call (not
# be its own disconnected root).
# --------------------------------------------------------------------
my $combined = $node->safe_psql(
	'postgres', q{
	SELECT test_otel_clear();
	SELECT otp_parent();
	SELECT 'COUNT:' || test_otel_span_count();
} . $pop_all_spans_sql);
my ($count1) = $combined =~ /^COUNT:(\d+)$/m;
cmp_ok($count1, '>=', 2, 'at least a function span for each of parent and child');

my @spans = parse_popped_spans($combined);
my @func_spans = grep { $_->{name} eq 'pg.plpgsql.function' } @spans;
is(scalar(@func_spans), 2, 'exactly 2 pg.plpgsql.function spans (parent + child)');

my @by_fnname = map {
	my $name = $_->{attr}{'code.function.name'};
	{ span => $_, fn => $name }
} @func_spans;

# code.function.name is fn_signature, "name(argtypes)"; these two take no
# arguments, so match the bare "name(" prefix.
my ($parent_rec) = grep { ($_->{fn} // '') =~ /^otp_parent\(/ } @by_fnname;
my ($child_rec)  = grep { ($_->{fn} // '') =~ /^otp_child\(/ } @by_fnname;

ok(defined $parent_rec, 'found function span for otp_parent');
ok(defined $child_rec,  'found function span for otp_child');

SKIP: {
	skip 'missing parent/child span', 4 unless defined $parent_rec && defined $child_rec;

	my $parent_span = $parent_rec->{span};
	my $child_span  = $child_rec->{span};

	is($child_span->{trace_id}, $parent_span->{trace_id},
		'child function span shares a trace_id with the outer call');
	is($parent_span->{parent_span_id}, '',
		'outermost call (otp_parent) is a root: no parent_span_id');
	ok($child_span->{parent_span_id} ne '',
		'otp_child function span has a parent');

	my %span_ids = map { $_->{span_id} => 1 } @spans;
	ok($span_ids{ $child_span->{parent_span_id} },
		"otp_child's parent_span_id matches a span captured from inside otp_parent's call");
}

# --------------------------------------------------------------------
# A second, separate top-level call gets its own fresh root: a
# different trace_id, proving sampling/root creation is decided
# per call, not inherited from the first call's trace.
# --------------------------------------------------------------------
my $combined2 = $node->safe_psql(
	'postgres', q{
	SELECT test_otel_clear();
	SELECT otp_parent();
	SELECT test_otel_pop_span_by_name('pg.plpgsql.function');
});
my ($trace_id_2) = $combined2 =~ /^trace_id=([0-9a-f]{32})$/m;
ok(defined $trace_id_2, 'second invocation also produced a root span');
isnt($trace_id_2, (defined $parent_rec ? $parent_rec->{span}{trace_id} : ''),
	'second top-level call starts a brand-new trace');

$node->stop;
done_testing();
