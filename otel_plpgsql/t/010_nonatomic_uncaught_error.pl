# Copyright (c) 2026, PostgreSQL Global Development Group
#
# A nonatomic top-level call (a DO block or a CALL, both run outside an
# explicit transaction block) that raises an uncaught error: unlike an
# ordinary (atomic) call, this module's spans for it are OTEL_OWNER_SESSION
# (not resource-owner-owned, see the comment in otel_plpgsql_func_setup()
# --- that's what lets a nonatomic call's own internal COMMIT survive
# without going stale). A session span has no resource owner, so nothing
# auto-ends it on abort the way a default-owned span is. Before the fix
# this module simply leaked them: still "open" and still on otel_api's
# active stack forever (within that backend), silently becoming the
# parent of whatever runs next.
#
# This test produces that scenario and checks both ends of it: the next,
# unrelated call must NOT become a child of the leaked DO span (it must
# start its own fresh trace, same as the no-context case in
# t/009_context_propagation.pl), and the DO's own span must actually be
# exported, with ERROR status, not simply vanish or stay uncounted.

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
CREATE FUNCTION onu_after() RETURNS void AS $BODY$
BEGIN
	PERFORM 1;
END;
$BODY$ LANGUAGE plpgsql;
});

sub parse_kv
{
	my ($text) = @_;
	my %h;
	for my $line (split /\n/, $text // '')
	{
		if ($line =~ /^attr=([^=]+)=(.*)$/) { $h{attr}{$1} = $2; }
		elsif ($line =~ /^([^=]+)=(.*)$/)   { $h{$1} = $2; }
	}
	return \%h;
}

my $pop_all_spans_sql = join('',
	map { "SELECT '===SPAN===' || coalesce(test_otel_pop_span(), '');\n" }
	(1 .. 32));

sub parse_popped_spans
{
	my ($out) = @_;
	my @chunks = split /===SPAN===/, $out;
	shift @chunks;
	my @spans;
	for my $c (@chunks)
	{
		next if $c !~ /\S/;
		push @spans, parse_kv($c);
	}
	return @spans;
}

my $out;
$node->psql(
	'postgres', q{
	SET otel_plpgsql.trace_statements = on;
	SELECT test_otel_clear();
	DO $DO$ BEGIN RAISE EXCEPTION 'onu: induced, uncaught, in a DO block'; END; $DO$;
	SELECT onu_after();
} . $pop_all_spans_sql,
	stdout => \$out,
	on_error_stop => 0);

my @spans = parse_popped_spans($out);
cmp_ok(scalar(@spans), '>=', 2,
	'at least the DO block\'s own function span and onu_after()\'s');

my @func = grep { $_->{name} eq 'pg.plpgsql.function' } @spans;
my ($after_span) = grep { ($_->{attr}{'code.function.name'} // '') =~ /^onu_after\(/ } @func;
ok(defined $after_span, 'found onu_after()\'s function span');

# Everything else captured belongs to the DO block (it has no
# code.function.name of its own worth matching on).
my @do_spans = grep { $_ != ($after_span // 0) } @spans;
cmp_ok(scalar(@do_spans), '>=', 1, 'at least one span captured for the DO block itself');

SKIP: {
	skip 'no onu_after() span captured', 3 unless defined $after_span;

	my %do_span_ids = map { $_->{span_id} => 1 } @do_spans;

	isnt($after_span->{trace_id}, $do_spans[0]->{trace_id},
		'onu_after() starts its own trace, not a child of the leaked DO spans')
	  if @do_spans;

	ok(!$do_span_ids{ $after_span->{parent_span_id} // '' },
		'onu_after() does not parent under any span left open by the DO block');

	my @do_func = grep { $_->{name} eq 'pg.plpgsql.function' } @do_spans;
	cmp_ok(scalar(@do_func), '>=', 1, 'the DO block got its own pg.plpgsql.function span');
	ok((grep { ($_->{status} // '') eq '2' } @do_func),
		'the DO block\'s function span was exported with ERROR status, not merely leaked');
}

$node->stop;
done_testing();
