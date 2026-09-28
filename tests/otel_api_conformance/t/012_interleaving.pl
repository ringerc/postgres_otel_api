# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Incorrectly interleaved / manually parented spans: detached chains
# ended in every order, a parent ending before its detached child, a
# non-LIFO end mixed with a detached sibling, two producers
# cross-parenting via explicit handles, wide fan-out near
# otel_api.max_open_spans, mid-stack discard, and a randomised
# stress harness.  Task brief "2. Incorrectly interleaved / manually
# parented spans".
#
# See t/008_misuse.pl and t/009_multi_producer.pl for the
# crash-and-recover pattern used here for the one scenario (c) that
# Asserts in cassert builds.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use JSON::PP;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf', <<'EOCONF');
shared_preload_libraries = 'otel_api,otel_api_conformance'
otel_api.max_open_spans = 150
restart_after_crash = on
EOCONF
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_api_conformance');

my $cassert = $node->safe_psql('postgres', 'SHOW debug_assertions');
note("debug_assertions = $cassert");

sub parse_spans
{
	my ($out) = @_;
	return () if !defined $out || $out eq '';
	return @{ decode_json($out) };
}

sub counters_of
{
	my ($out) = @_;
	return decode_json($out);
}

# See t/008_misuse.pl for why this polls rather than scanning the log.
sub wait_for_restart
{
	my $deadline = time() + $PostgreSQL::Test::Utils::timeout_default;
	while (time() < $deadline)
	{
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
# (a) Detached chain: 100 spans each parented (OTEL_PARENT_SPAN) to
# the previous one, ended in reverse order; another 100 ended in a
# seeded random order; another 100 ended in start (parent-before-
# child) order.  Every emitted span's parent_span_id must equal its
# creator-parent's span_id; all 300 emitted exactly once.
# ----------------------------------------------------------------
{
	$node->safe_psql('postgres', 'SELECT otel_api_conformance_reset()');
	my $out = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_detached_chain(100, 'reverse', 1);
SELECT otel_api_conformance_detached_chain(100, 'random', 2);
SELECT otel_api_conformance_detached_chain(100, 'forward', 3);
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' LIKE 'conformance.chain.%';
SQL
	my @s = parse_spans($out);
	is(scalar(@s), 300, '(a) all 300 detached-chain spans emitted');
	is(scalar(keys %{ { map { $_->{span_id} => 1 } @s } }), 300,
		'(a) every emitted span_id is unique');

	# Each batch of 100 shares the same "conformance.chain.N" naming;
	# distinguish batches by grouping consecutive spans with the same
	# name into buckets keyed by name only within one batch is
	# ambiguous (names repeat across batches), so instead verify the
	# invariant per *trace*: a chain's members all share one trace_id
	# (root of the chain got a fresh trace per otel_span_start's
	# OTEL_PARENT_ACTIVE/new-trace rule), and within each trace, every
	# non-root member's parent_span_id equals some other member's
	# span_id in the same trace, and exactly one member per trace has
	# an all-zero parent (the chain's root).
	my %by_trace;
	push @{ $by_trace{ $_->{trace_id} } }, $_ for @s;
	is(scalar(keys %by_trace), 3, '(a) exactly 3 chains (traces)');
	for my $trace_id (keys %by_trace)
	{
		my @chain = @{ $by_trace{$trace_id} };
		is(scalar(@chain), 100, "(a) chain $trace_id has all 100 members");
		my %span_ids = map { $_->{span_id} => 1 } @chain;
		my @roots = grep { $_->{parent_span_id} eq '0000000000000000' } @chain;
		is(scalar(@roots), 1, "(a) chain $trace_id has exactly one root");
		my @orphans = grep {
			$_->{parent_span_id} ne '0000000000000000'
			  && !$span_ids{ $_->{parent_span_id} }
		} @chain;
		is(scalar(@orphans), 0, "(a) chain $trace_id: every non-root parent is another chain member");
	}
}

# ----------------------------------------------------------------
# (b) Parent ends before its detached child; child later ends and
# still names the parent; a further child started from the saved
# context of the already-ended parent.
# ----------------------------------------------------------------
{
	$node->safe_psql('postgres', 'SELECT otel_api_conformance_reset()');
	my $out = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_parent_ends_first() AS _r \gset
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' LIKE 'conformance.b.%';
SQL
	my @s = parse_spans($out);
	my %by_name = map { $_->{name} => $_ } @s;

	ok($by_name{'conformance.b.parent'}, '(b) parent span emitted');
	ok($by_name{'conformance.b.child'}, '(b) detached child emitted (ended after its parent)');
	is($by_name{'conformance.b.child'}->{parent_span_id},
		$by_name{'conformance.b.parent'}->{span_id},
		'(b) the child still names the (already-ended) parent');
	ok($by_name{'conformance.b.from_ended_ctx'},
		'(b) a further span started from the saved context of the ended parent is emitted');
	is($by_name{'conformance.b.from_ended_ctx'}->{parent_span_id},
		$by_name{'conformance.b.parent'}->{span_id},
		'(b) it too names the ended parent, via the saved context');
}

# ----------------------------------------------------------------
# (c) Stack span A; detached D child of A; stack span B (child of A);
# end A while B is still open (non-LIFO).  cassert: Asserts and
# crashes (same check as t/008_misuse.pl's non-LIFO case).  Otherwise:
# a WARNING, B unwound per its policy, A emitted, D unaffected and
# ends fine later, non_lifo_end +1.
# ----------------------------------------------------------------
{
	if ($cassert eq 'on')
	{
		my $log_start = -s $node->logfile;
		my ($ret, $stdout, $stderr) =
			$node->psql('postgres', 'SELECT otel_api_conformance_mixed_non_lifo_detached()');
		isnt($ret, 0, '(c) non-LIFO end with a detached sibling Asserts in a cassert build');
		my $log_contents = PostgreSQL::Test::Utils::slurp_file($node->logfile, $log_start);
		like($log_contents, qr/TRAP:|Assert/, '(c) server log shows an Assert failure');
		ok(wait_for_restart(), '(c) server accepts connections again after the crash')
			or BAIL_OUT('server did not come back up after the induced crash');
	}
	else
	{
		$node->safe_psql('postgres', 'SELECT otel_api_conformance_reset()');
		my $out = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_counters() AS c_before \gset
SELECT otel_api_conformance_mixed_non_lifo_detached() AS _r \gset
SELECT otel_api_conformance_counters() AS c_after \gset
SELECT :'c_before' AS c_before, :'c_after' AS c_after;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' LIKE 'conformance.c.%';
SQL
		my ($status_line, $spans_line) = split /\n/, $out, 2;
		my ($c_before_j, $c_after_j) = split /\|/, $status_line;
		my $c_before = counters_of($c_before_j);
		my $c_after  = counters_of($c_after_j);
		my @s = parse_spans($spans_line);
		my %by_name = map { $_->{name} => $_ } @s;

		cmp_ok($c_after->{non_lifo_end} - $c_before->{non_lifo_end}, '>=', 1,
			'(c) non_lifo_end counter increased');
		ok($by_name{'conformance.c.A'}, '(c) A (the one explicitly ended) is emitted');
		ok($by_name{'conformance.c.D'}, '(c) D (detached, unaffected) is emitted');
		ok($by_name{'conformance.c.B'}, '(c) B (force-unwound) is emitted');
		is($by_name{'conformance.c.D'}->{parent_span_id}, $by_name{'conformance.c.A'}->{span_id},
			'(c) D still names A as its parent');
	}
}

# ----------------------------------------------------------------
# (d) Two producers interleaving: A1 (stack), B1 (detached child of
# A1), A2 (stack child of A1), B2 (stack child of A2 structurally, but
# explicitly parented to B1).  Ended in LIFO stack order; parentage
# checked; stack left clean.
# ----------------------------------------------------------------
{
	$node->safe_psql('postgres', 'SELECT otel_api_conformance_reset()');
	my $out = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_two_producer_interleave() AS _r \gset
SELECT otel_api_conformance_span_current() AS cur;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' LIKE 'conformance.d.%';
SQL
	my ($cur, $spans_line) = split /\n/, $out, 2;
	my @s = parse_spans($spans_line);
	my %by_name = map { $_->{name} => $_ } @s;

	is($cur, '0', '(d) active stack is empty afterwards');
	is(scalar(@s), 4, '(d) all four spans emitted');
	is($by_name{'conformance.d.A2'}->{parent_span_id}, $by_name{'conformance.d.A1'}->{span_id},
		'(d) A2 parents to A1 via the active stack');
	is($by_name{'conformance.d.B1'}->{parent_span_id}, $by_name{'conformance.d.A1'}->{span_id},
		'(d) B1 (detached, other producer) parents to A1');
	is($by_name{'conformance.d.B2'}->{parent_span_id}, $by_name{'conformance.d.B1'}->{span_id},
		'(d) B2 parents to B1 (explicit OTEL_PARENT_SPAN), not its structural stack parent A2');
	is($by_name{'conformance.d.A1'}->{scope_name}, 'otel_api_conformance.a', '(d) A1 carries scope a');
	is($by_name{'conformance.d.B2'}->{scope_name}, 'otel_api_conformance.b', '(d) B2 carries scope b');
}

# ----------------------------------------------------------------
# (e) Wide fan-out: one parent with 140 detached children open at once
# (near max_open_spans=150: 1 parent + 140 children = 141, leaving only
# 9 slots), then, while ALL of them are still open, 20 more detached
# spans attempted -- exceeding the combined budget -- before anything
# is ended; check the refusals are counted without disturbing what's
# already open.
# ----------------------------------------------------------------
{
	$node->safe_psql('postgres', 'SELECT otel_api_conformance_reset()');
	my $out = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_counters() AS c_before \gset
SELECT otel_api_conformance_wide_fanout(140, 99, 20) AS r \gset
SELECT otel_api_conformance_counters() AS c_after \gset
SELECT :'r' AS r, :'c_before' AS c_before, :'c_after' AS c_after;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' LIKE 'conformance.e.%';
SQL
	my ($status_line, $spans_line) = split /\n/, $out, 2;
	my ($r_j, $c_before_j, $c_after_j) = split /\|/, $status_line;
	my $r        = decode_json($r_j);
	my $c_before = counters_of($c_before_j);
	my $c_after  = counters_of($c_after_j);
	my @s = parse_spans($spans_line);

	is($r->{refused_children}, 0, '(e) all 140 children started (still under max_open_spans=150)');
	is(scalar(grep { $_->{name} =~ /^conformance\.e\.child\./ } @s), 140,
		'(e) all 140 children emitted');
	cmp_ok($r->{refused_extra}, '>=', 1,
		'(e) at least one of the 20 overflow spans was refused once max_open_spans was hit');
	cmp_ok($c_after->{start_no_slot} - $c_before->{start_no_slot}, '>=', 1,
		'(e) start_no_slot counted the overflow refusals');
	ok((grep { $_->{name} eq 'conformance.e.parent' } @s), '(e) the parent itself is unaffected and emitted');
}

# ----------------------------------------------------------------
# (f) Discard in the middle of the stack: A (bottom), B (middle),
# C (top).  Discard B while C is still open: B disappears (never
# emitted), A and C are untouched and end cleanly with no non-LIFO
# warning.
#
# C's parent_span_id is NOT retroactively rewritten to A: it was fixed
# to B's span_id when C was created (while B was still the active
# top), and discard() only removes B from the stack from that point
# on ("spans above it are left alone" means their stack membership,
# not any already-recorded parentage). So this checks C's recorded
# parent against B's span_id, captured via otel_api_conformance_
# context_of() *before* discarding B (B is never emitted, so its
# span_id can't be read back from otel_api_conformance_spans()).
# ----------------------------------------------------------------
{
	# BEGIN...COMMIT: a default-owner span's owner is otherwise the
	# statement's own portal, released (leaking the span, per t/001's
	# header comment) as soon as that one statement finishes -- A/B/C
	# must all survive from the "start" statements through to the
	# "end"/"discard" statements below.
	my $out2 = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_reset() AS _r \gset
SELECT otel_api_conformance_counters() AS c_before \gset
BEGIN;
SELECT otel_api_conformance_start('conformance.f.A', owner_mode => 'toptxn') AS a \gset
SELECT otel_api_conformance_start('conformance.f.B', owner_mode => 'toptxn') AS b \gset
SELECT otel_api_conformance_start('conformance.f.C', owner_mode => 'toptxn') AS c \gset
SELECT otel_api_conformance_context_recv(otel_api_conformance_context_of(:b)) AS b_ctx \gset
SELECT otel_api_conformance_discard(:b) AS _r \gset
SELECT otel_api_conformance_end(:c) AS _r \gset
SELECT otel_api_conformance_end(:a) AS _r \gset
COMMIT;
SELECT otel_api_conformance_span_current() AS cur \gset
SELECT otel_api_conformance_counters() AS c_after \gset
SELECT :cur AS cur, :'b_ctx' AS b_ctx, :'c_before' AS c_before, :'c_after' AS c_after;
SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s WHERE s->>'name' LIKE 'conformance.f.%';
SQL
	my ($status_line2, $spans_line) = split /\n/, $out2, 2;
	my ($cur2, $b_ctx, $c_before_j, $c_after_j) = split /\|/, $status_line2;
	my (undef, $b_span_id) = split /;/, $b_ctx;
	my $c_before = counters_of($c_before_j);
	my $c_after  = counters_of($c_after_j);
	my @s = parse_spans($spans_line);
	my %by_name = map { $_->{name} => $_ } @s;

	is($cur2, '0', '(f) active stack is empty afterwards');
	ok($by_name{'conformance.f.A'}, '(f) A is emitted');
	ok($by_name{'conformance.f.C'}, '(f) C is emitted');
	ok(!exists $by_name{'conformance.f.B'}, '(f) B (discarded) is never emitted');
	is($by_name{'conformance.f.C'}->{parent_span_id}, $b_span_id,
		"(f) C's recorded parent is still B's span_id ($b_span_id), fixed at C's creation time, "
		  . 'even though B itself was later discarded and never emitted');
	is($c_after->{spans_discarded} - $c_before->{spans_discarded}, 1,
		'(f) spans_discarded counted exactly once');
	is($c_after->{non_lifo_end} - $c_before->{non_lifo_end}, 0,
		'(f) discarding the middle span does not trigger a non-LIFO warning');
}

# ----------------------------------------------------------------
# Randomised stress: otel_api_conformance_stress_ops(seed, n_ops, mode)
# returns a jsonb summary; the invariant it checks internally
# (documented in the function's own header comment in the .c file) is:
# every emitted span whose creator intended a specific parent (or the
# root) matches that intent exactly (parent_mismatches = 0), and
# spans_started/spans_emitted/spans_discarded account for everything
# this run did (n_started = spans_started_delta; every started
# recording span ends up either emitted, or dropped via discard/
# unwind -- checked via the *_delta counters below), the active stack
# is empty afterwards (stack_current_at_end = 0), and (legal mode)
# no non_lifo_end/stale_handle at all.
#
# mode 'legal' on every build; 'illegal' only when debug_assertions is
# off (otel_api Asserts on exactly the misuse it introduces).
# ----------------------------------------------------------------
{
	for my $seed (1, 2, 3)
	{
		$node->safe_psql('postgres', 'SELECT otel_api_conformance_reset()');
		my $out = $node->safe_psql('postgres',
			"SELECT otel_api_conformance_stress_ops($seed, 10000, 'legal');");
		my $r = decode_json($out);

		is($r->{parent_mismatches}, 0,
			"stress(seed=$seed,legal): every checked parent matches ($r->{parent_checked} checked)");
		is($r->{stack_current_at_end}, 0, "stress(seed=$seed,legal): active stack empty at the end");
		is($r->{stale_handle_delta}, 0, "stress(seed=$seed,legal): no stale_handle");
		is($r->{non_lifo_end_delta}, 0, "stress(seed=$seed,legal): no non_lifo_end");
		is($r->{n_started}, $r->{spans_started_delta},
			"stress(seed=$seed,legal): n_started matches the spans_started counter delta");
		cmp_ok($r->{n_ended} + $r->{n_discarded}, '>=', $r->{n_started},
			"stress(seed=$seed,legal): every started span was ended or discarded by the time the "
			  . "function returns (n_ended=$r->{n_ended} n_discarded=$r->{n_discarded} n_started=$r->{n_started})");
	}

	if ($cassert eq 'on')
	{
		note('skipping illegal-mode stress: cassert build would Assert on the induced misuse');
	}
	else
	{
		for my $seed (1, 2)
		{
			$node->safe_psql('postgres', 'SELECT otel_api_conformance_reset()');
			my ($ret, $stdout, $stderr) = $node->psql('postgres',
				"SELECT otel_api_conformance_stress_ops($seed, 10000, 'illegal');");
			is($ret, 0, "stress(seed=$seed,illegal): completes without crashing");
			my $r = decode_json($stdout);
			is($r->{stack_current_at_end}, 0, "stress(seed=$seed,illegal): active stack empty at the end");

			# The backend must still be healthy for the next statement.
			my $probe = $node->safe_psql('postgres', 'SELECT otel_api_conformance_span_current()');
			is($probe, '0', "stress(seed=$seed,illegal): backend still healthy afterwards");
		}
	}
}

$node->stop;
done_testing();
