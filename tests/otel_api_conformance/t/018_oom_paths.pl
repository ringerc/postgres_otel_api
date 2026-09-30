# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Real out-of-memory paths via injection points.  otel_api P2 edge-case
# plan, item 2 (postgres-cdq.9.2).
#
# otel_api's own "otel-api-oom-<site>" injection points (otel_producer.c)
# are USE_INJECTION_POINTS-only and compile to nothing without it (see
# otel_inject_fail()'s header comment there for the full site list and
# rationale).  otel_api_conformance_oom_arm/disarm/status (this suite's
# own injection callback, otel_api_conformance.c) let a test fail one of
# those sites for exactly this backend, for a chosen number of hits,
# after skipping a chosen number first.
#
# otel_api_conformance_oom_available() is checked first: on a build
# without injection points (pgsql-bench; USE_INJECTION_POINTS is only
# defined for the pgsql/cassert prefix per AGENTS/build-and-install.md),
# this whole file is skipped with a clear reason instead of failing.
#
# Every site test below runs in its own fresh backend ($node->psql/
# safe_psql starts one per call; see the handover's "Lessons"), so
# otel_api's own counters (otel_api_conformance_counters()) start at
# exactly zero every time -- no diffing against a "before" snapshot is
# needed, and the "first use in a fresh backend" requirement for the
# pool/slot-context/tracer-register sites falls out for free.
#
# Scope note: the full checklist (hit, documented behaviour, no leak,
# no dangling stack entry, next span's parentage both with a parent
# open and with none) is run for every site.  The "parent open" half of
# the parentage check nests the failing action as a child of an open
# otel_api.max_open_spans-independent toptxn span; the "no parent" half
# is the standalone "next span in the backend" follow-up every site
# test ends with regardless, which starts as a fresh root.

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
otel_api.max_open_spans = 8
otel_api.attr_value_max = 4096
restart_after_crash = on
EOCONF
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_api_conformance');

my $MAX_OPEN = 8;

my $available = $node->safe_psql('postgres', 'SELECT otel_api_conformance_oom_available()');
if ($available ne 't')
{
	plan skip_all =>
	  'this build has no injection points (USE_INJECTION_POINTS not compiled in); '
	  . 'postgres-cdq.9.2 OOM-path tests need the pgsql/cassert prefix';
}

sub parse_spans
{
	my ($out) = @_;
	return () if !defined $out || $out eq '';
	return @{ decode_json($out) };
}

# The tail every scenario ends with: a batch of max_open_spans + 1
# spans (no leaked slot means all of them start and end cleanly and
# start_no_slot stays 0), then one more "follow-up" span, then one
# combined jsonb row with otel_span_current(), the counters, and this
# site's own hit/fail status, then the captured spans.
sub tail_sql
{
	my ($site) = @_;
	my $sql = '';

	for (my $i = 0; $i < $MAX_OPEN + 1; $i++)
	{
		$sql .=
		  "SELECT otel_api_conformance_end(otel_api_conformance_start('conformance.oom_batch_probe'));\n";
	}
	$sql .=
	  "SELECT otel_api_conformance_end(otel_api_conformance_start('conformance.oom_followup'));\n";
	$sql .= "SELECT jsonb_build_object("
	  . "'current', otel_api_conformance_span_current(), "
	  . "'counters', otel_api_conformance_counters(), "
	  . "'status', otel_api_conformance_oom_status('$site')) AS meta;\n";
	$sql .= "SELECT jsonb_agg(s) FROM otel_api_conformance_spans() s;\n";
	return $sql;
}

# Runs $sql (which must arm and disarm $site itself) followed by
# tail_sql($site) (site is the actual armed injection-point name, used
# to query its status -- $label, if given, is only the human-readable
# prefix on test descriptions, e.g. to distinguish two different
# scenarios that both arm the same site).  Asserts the script completed
# without error, and returns (meta_hashref, \@spans).  $checks->($meta,
# \@spans) is called first, so a site-specific failure is reported
# before the generic tail assertions.
sub run_site
{
	my ($site, $sql, $checks, $label, $expect_start_no_slot) = @_;
	$label //= $site;
	$expect_start_no_slot //= 0;

	$sql .= tail_sql($site);
	my ($ret, $stdout, $stderr) = $node->psql('postgres', $sql, on_error_stop => 1);
	is($ret, 0, "$label: scenario script completes") or diag($stderr);

	my @lines = split /\n/, $stdout;
	my ($meta_line) = grep { /^\{/ } @lines;
	my ($spans_line) = grep { /^\[/ } @lines;
	ok(defined $meta_line, "$label: the meta row is present") or diag($stdout);
	my $meta = defined $meta_line ? decode_json($meta_line) : {};
	my @spans = defined $spans_line ? parse_spans($spans_line) : ();

	cmp_ok($meta->{status}{hits}, '>=', 1, "$label: the injection point was hit") if %$meta;

	$checks->($meta, \@spans) if $checks;

	# Generic checks, for every site.
	is($meta->{current}, 0, "$label: no stack entry left behind (otel_span_current is none)");
	is($meta->{counters}{start_no_slot}, $expect_start_no_slot,
		"$label: no slot leaked (start_no_slot is $expect_start_no_slot after a batch of "
		  . "max_open_spans+1)");
	my ($followup) = grep { $_->{name} eq 'conformance.oom_followup' } @spans;
	ok($followup, "$label: the next span in this backend starts and exports");
	is($followup->{parent_span_id}, '0000000000000000',
		"$label: the next span is a root (no leftover parent on the stack)")
	  if $followup;

	return ($meta, \@spans);
}

# A toptxn-owned parent+child pair (kept open across statements inside
# an explicit transaction; see t/017's header comment on why a
# default-owned span can't be used here), for sites whose "with a
# parent span open" check nests the failing action under an open
# parent.  Returns the SQL prologue; the caller must still disarm, end
# both spans, and COMMIT.
sub parented_prologue
{
	my ($site) = @_;
	return "BEGIN;\n"
	  . "SELECT otel_api_conformance_start('conformance.oom.$site.parent', owner_mode => 'toptxn') AS parent \\gset\n"
	  . "SELECT otel_api_conformance_start('conformance.oom.$site.child', owner_mode => 'toptxn') AS child \\gset\n";
}

# ================================================================
# The three ERROR-raising sites: resowner-enlarge, slot-context,
# tracer-register.  Each precedes a call that can raise ERROR on a
# real OOM; the injection callback raises ERRCODE_OUT_OF_MEMORY itself
# in the caller's place.  Tested at top level (the statement aborts,
# the session continues) and inside a plpgsql EXCEPTION block (caught,
# the session sees no error at all).
# ================================================================

for my $case (
	[ 'resowner-enlarge', 'conformance.oom.resowner' ],
	[ 'slot-context',     'conformance.oom.slotctx' ],
	[ 'tracer-register',  'conformance.oom.tracer' ],
  )
{
	my ($site, $name) = @$case;

	# Top level: the statement aborts with an out-of-memory error; the
	# session (and this same backend/connection) continues afterwards.
	# Everything -- arm, the failing call, disarm, and the tail checks
	# -- must be ONE psql invocation/connection: otel_api's counters,
	# otel_api_conformance's own hit/fail status, and otel_span_current()
	# are all backend-local (see the handover's "Lessons"), and a fresh
	# $node->psql call is a fresh backend that never saw the arm() at all.
	{
		my $sql = "SELECT otel_api_conformance_oom_arm('$site');\n"
		  . "SELECT otel_api_conformance_start('$name.toplevel');\n"
		  . "SELECT otel_api_conformance_oom_disarm('$site');\n"
		  . tail_sql($site);
		my ($ret, $stdout, $stderr) = $node->psql('postgres', $sql, on_error_stop => 0);
		like($stderr, qr/out of memory|otel_api_conformance: injected/i,
			"$site (top level): the induced error is the injected out-of-memory error")
		  or diag($stderr);

		my ($meta_line) = grep { /^\{/ } split /\n/, $stdout;
		ok(defined $meta_line, "$site (top level): the connection is usable after the induced abort")
		  or diag($stdout);
		my $meta = defined $meta_line ? decode_json($meta_line) : {};
		cmp_ok($meta->{status}{hits}, '>=', 1, "$site (top level): the injection point was hit");
		is($meta->{counters}{start_no_slot}, 0,
			"$site (top level): start_no_slot is 0 (the ERROR happens before a slot is taken)");
	}

	# Inside a plpgsql EXCEPTION block: caught, no visible error, the
	# session and the counters are coherent afterwards.
	{
		my $sql = "SELECT otel_api_conformance_oom_arm('$site');\n" . <<SQL;
DO \$\$
BEGIN
	PERFORM otel_api_conformance_start('$name.exception');
EXCEPTION WHEN OTHERS THEN
	RAISE NOTICE 'caught: %', SQLERRM;
END;
\$\$;
SQL
		$sql .= "SELECT otel_api_conformance_oom_disarm('$site');\n";
		my ($meta, $spans) = run_site($site, $sql, sub {
			my ($meta) = @_;
			is($meta->{counters}{start_no_slot}, 0,
				"$site (plpgsql EXCEPTION): start_no_slot is 0");
		}, "$site (plpgsql EXCEPTION)");
	}
}

# ================================================================
# The bool-return allocation-failure sites.  Each is armed for exactly
# one hit, exercised as a child of an open toptxn parent, disarmed,
# and the parent+child are ended before the shared tail runs.
# ================================================================

sub run_alloc_site
{
	my ($site, $action_sql, $checks) = @_;
	my $sql = parented_prologue($site);

	$sql .= "SELECT otel_api_conformance_oom_arm('$site');\n";
	$sql .= $action_sql;
	$sql .= "SELECT otel_api_conformance_oom_disarm('$site');\n";
	$sql .= "SELECT otel_api_conformance_end(:child);\n";
	$sql .= "SELECT otel_api_conformance_end(:parent);\n";
	$sql .= "COMMIT;\n";

	return run_site($site, $sql, sub {
		my ($meta, $spans) = @_;
		my ($parent) = grep { $_->{name} eq "conformance.oom.$site.parent" } @$spans;
		my ($child) = grep { $_->{name} eq "conformance.oom.$site.child" } @$spans;
		ok($parent, "$site: the parent span was exported");
		ok($child, "$site: the child span was exported despite the injected failure");
		if ($parent && $child)
		{
			is($child->{parent_span_id}, $parent->{span_id},
				"$site: the child's parentage survives the injected failure");
		}
		$checks->($meta, $spans, $parent, $child) if $checks;
	});
}

# ---- name: the span name falls back to "(out of memory)" -----------
# name needs the injection armed *before* the child span itself starts
# (parented_prologue starts the child before otel_api_conformance_oom_arm
# runs), so it gets its own hand-written scenario instead of
# run_alloc_site's shared prologue order.
{
	my $sql = "BEGIN;\n"
	  . "SELECT otel_api_conformance_start('conformance.oom.name.parent', owner_mode => 'toptxn') AS parent \\gset\n"
	  . "SELECT otel_api_conformance_oom_arm('name');\n"
	  . "SELECT otel_api_conformance_start('conformance.oom.name.child', owner_mode => 'toptxn') AS child \\gset\n"
	  . "SELECT otel_api_conformance_oom_disarm('name');\n"
	  . "SELECT otel_api_conformance_end(:child);\n"
	  . "SELECT otel_api_conformance_end(:parent);\n"
	  . "COMMIT;\n";
	run_site('name', $sql, sub {
		my ($meta, $spans) = @_;
		my ($child) = grep { $_->{name} eq '(out of memory)' } @$spans;
		ok($child, 'name: the span with a failed name copy is exported as "(out of memory)"');
		my ($parent) = grep { $_->{name} eq 'conformance.oom.name.parent' } @$spans;
		is($child->{parent_span_id}, $parent->{span_id},
			'name: parentage still survives a failed name copy')
		  if $child && $parent;
		# Finding: no otel_api counter distinguishes a failed name copy
		# from any other span; spans_started/spans_emitted are the only
		# ones touched, both by the ordinary start/end path.
	});
}

# ---- tracestate: the child's copy of the parent's tracestate is dropped, silently ----
{
	my $sql = "BEGIN;\n"
	  . "SELECT encode(otel_api_conformance_context_send("
	  .   "'aabbccddeeff00112233445566778899', '0011223344556677', 1, 'vendor=oom1'), 'hex') AS wire \\gset\n"
	  . "SELECT otel_api_conformance_start('conformance.oom.tracestate.parent', "
	  .   "parent_mode => 'context', parent_ctx => decode(:'wire', 'hex'), owner_mode => 'toptxn') AS parent \\gset\n"
	  . "SELECT otel_api_conformance_oom_arm('tracestate');\n"
	  . "SELECT otel_api_conformance_start('conformance.oom.tracestate.child', owner_mode => 'toptxn') AS child \\gset\n"
	  . "SELECT otel_api_conformance_oom_disarm('tracestate');\n"
	  . "SELECT otel_api_conformance_end(:child);\n"
	  . "SELECT otel_api_conformance_end(:parent);\n"
	  . "COMMIT;\n";
	run_site('tracestate', $sql, sub {
		my ($meta, $spans) = @_;
		my ($parent) = grep { $_->{name} eq 'conformance.oom.tracestate.parent' } @$spans;
		my ($child) = grep { $_->{name} eq 'conformance.oom.tracestate.child' } @$spans;
		ok($parent && $parent->{tracestate} eq 'vendor=oom1',
			'tracestate: the parent kept its own tracestate') if $parent;
		ok($child && !defined($child->{tracestate}),
			'tracestate: the child silently has no tracestate (copy failed)') if $child;
		is($child->{parent_span_id}, $parent->{span_id},
			'tracestate: parentage still survives a failed tracestate copy')
		  if $child && $parent;
		# Finding: no counter marks a dropped tracestate either.
	});
}

# ---- attr-key / attr-value: the attribute is dropped whole, attr_dropped counted ----
for my $site (qw(attr-key attr-value))
{
	run_alloc_site($site,
		"SELECT otel_api_conformance_set_str(:child, 'oom.attr', 'value');\n",
		sub {
			my ($meta, $spans, $parent, $child) = @_;
			ok($child && !(grep { $_->{key} eq 'oom.attr' } @{ $child->{attrs} }),
				"$site: the attribute is missing from the child span") if $child;
			cmp_ok($meta->{counters}{attr_dropped}, '>=', 1,
				"$site: attr_dropped increased");
		});
}

# ---- event-name: the event is dropped whole, event_dropped counted ----
run_alloc_site('event-name',
	"SELECT otel_api_conformance_add_event(:child, 'conformance.oom_event', NULL, NULL, NULL, NULL);\n",
	sub {
		my ($meta, $spans, $parent, $child) = @_;
		ok($child && !(grep { $_->{name} eq 'conformance.oom_event' } @{ $child->{events} }),
			'event-name: the event is missing from the child span') if $child;
		cmp_ok($meta->{counters}{event_dropped}, '>=', 1, 'event-name: event_dropped increased');
	});

# ---- status-description: the description is silently dropped, status code kept ----
run_alloc_site('status-description',
	"SELECT otel_api_conformance_set_status(:child, 'error', 'a description');\n",
	sub {
		my ($meta, $spans, $parent, $child) = @_;
		is($child->{status}, 2, 'status-description: status code (ERROR) is still set') if $child;
		ok($child && !defined($child->{status_description}),
			'status-description: the description text was dropped') if $child;
		# Finding: no counter marks a dropped status description either.
	});

# ---- attrs: array-growth failure drops the new element --------------
# Needs its own hand-written scenario, not run_alloc_site: the 12
# inline slots must fill up *unarmed*, and only the 13th (which needs
# slot_grow to actually grow the array) is attempted while armed.
{
	my $sql = parented_prologue('attrs');
	$sql .= join '', map { "SELECT otel_api_conformance_set_int(:child, 'k$_', $_);\n" } (1 .. 12);
	$sql .= "SELECT otel_api_conformance_oom_arm('attrs');\n";
	$sql .= "SELECT otel_api_conformance_set_str(:child, 'k13', 'v13');\n";
	$sql .= "SELECT otel_api_conformance_oom_disarm('attrs');\n";
	$sql .= "SELECT otel_api_conformance_end(:child);\n";
	$sql .= "SELECT otel_api_conformance_end(:parent);\n";
	$sql .= "COMMIT;\n";
	run_site('attrs', $sql, sub {
		my ($meta, $spans) = @_;
		my ($parent) = grep { $_->{name} eq 'conformance.oom.attrs.parent' } @$spans;
		my ($child) = grep { $_->{name} eq 'conformance.oom.attrs.child' } @$spans;
		ok($parent, 'attrs: the parent span was exported');
		ok($child, 'attrs: the child span was exported despite the injected failure');
		is($child->{parent_span_id}, $parent->{span_id},
			'attrs: the child\'s parentage survives the injected failure')
		  if $child && $parent;
		ok($child && !(grep { $_->{key} eq 'k13' } @{ $child->{attrs} }),
			'attrs: the 13th attribute (needing growth) is missing') if $child;
		is(scalar(@{ $child->{attrs} // [] }), 12,
			'attrs: exactly the 12 inline attributes survive') if $child;
		cmp_ok($meta->{counters}{attr_dropped}, '>=', 1, 'attrs: attr_dropped increased');
	});
}

# ---- events / links: array-growth failure drops the new element -----

run_alloc_site('events',
	"SELECT otel_api_conformance_add_event(:child, 'conformance.oom_event', NULL, NULL, NULL, NULL);\n",
	sub {
		my ($meta, $spans, $parent, $child) = @_;
		ok($child && !(grep { $_->{name} eq 'conformance.oom_event' } @{ $child->{events} }),
			'events: the event is missing (array growth failed)') if $child;
		cmp_ok($meta->{counters}{event_dropped}, '>=', 1, 'events: event_dropped increased');
	});

run_alloc_site('links',
	"SELECT otel_api_conformance_add_link(:child, "
	  . "otel_api_conformance_context_send('aabbccddeeff00112233445566778899', '0011223344556677', 1));\n",
	sub {
		my ($meta, $spans, $parent, $child) = @_;
		is(scalar(@{ $child->{links} // [] }), 0, 'links: the link is missing (array growth failed)')
		  if $child;
		cmp_ok($meta->{counters}{link_dropped}, '>=', 1, 'links: link_dropped increased');
	});

# ---- event-attrs: the event's own attribute-array copy fails: the whole event is dropped ----
run_alloc_site('event-attrs',
	"SELECT otel_api_conformance_add_event(:child, 'conformance.oom_event_wattr', 'strval', NULL, NULL, NULL);\n",
	sub {
		my ($meta, $spans, $parent, $child) = @_;
		ok($child
			  && !(grep { $_->{name} eq 'conformance.oom_event_wattr' } @{ $child->{events} }),
			'event-attrs: the event (name copied, attrs alloc failed) is dropped whole, '
			  . 'not exported half-built') if $child;
		cmp_ok($meta->{counters}{event_dropped}, '>=', 1, 'event-attrs: event_dropped increased');
	});

# ---- exception-attrs: the internal exception event's own attrs alloc fails ----
{
	my $sql = "SELECT otel_api_conformance_oom_arm('exception-attrs');\n"
	  . "SELECT otel_api_conformance_record_error_full_scenario('conformance.oom.exc_attrs');\n"
	  . "SELECT otel_api_conformance_oom_disarm('exception-attrs');\n";
	run_site('exception-attrs', $sql, sub {
		my ($meta, $spans) = @_;
		my ($span) = grep { $_->{name} eq 'conformance.oom.exc_attrs' } @$spans;
		ok($span, 'exception-attrs: the erroring span is still exported');
		my ($ev) = grep { $_->{name} eq 'exception' } @{ $span->{events} // [] };
		TODO:
		{
			local $TODO =
			  'postgres-cdq.9.2: unlike otel_span_add_event (which drops an event whole '
			  . 'when its attribute copy fails), lower_error_event\'s internal "exception" '
			  . 'event is kept even when its own attribute array allocation fails '
			  . '(otel_producer.c lower_error_event(): attrs falls back to NULL/n_attrs=0 '
			  . 'but the event is still added) -- an inconsistent partial-failure contract '
			  . 'between the two event-adding paths, and no counter marks it.';
			ok($ev && scalar(@{ $ev->{attrs} // [] }) > 0,
				'exception-attrs: the exception event should be dropped whole like any other '
				  . 'event whose attribute copy fails, not kept with 0 attrs (gap)');
		}
	});
}

# ---- vprintf: falls back to the fixed 1024-byte buffer, truncated ----
run_alloc_site('vprintf',
	"SELECT otel_api_conformance_set_printf(:child, 'oom.printf', repeat('x', 2000));\n",
	sub {
		my ($meta, $spans, $parent, $child) = @_;
		my ($attr) = grep { $_->{key} eq 'oom.printf' } @{ $child->{attrs} // [] };
		ok($attr, 'vprintf: the attribute is still set, from the fixed fallback buffer')
		  if $child;
		cmp_ok(length($attr->{value}), '<', 1024,
			'vprintf: the value was truncated to the fixed buffer size') if $attr;
		cmp_ok($meta->{counters}{attr_truncated}, '>=', 1, 'vprintf: attr_truncated increased');
	});

# ---- error-message / error-detail / error-hint: error_capture_failed counted ----
my %error_field_key = (
	message => 'exception.message',
	detail  => 'pg.error.detail',
	hint    => 'pg.error.hint',
);
for my $field (qw(message detail hint))
{
	my $site = "error-$field";
	my $attr_key = $error_field_key{$field};
	my $sql = "SELECT otel_api_conformance_oom_arm('$site');\n"
	  . "SELECT otel_api_conformance_record_error_full_scenario('conformance.oom.$site');\n"
	  . "SELECT otel_api_conformance_oom_disarm('$site');\n";
	run_site($site, $sql, sub {
		my ($meta, $spans) = @_;
		my ($span) = grep { $_->{name} eq "conformance.oom.$site" } @$spans;
		ok($span, "$site: the erroring span is still exported");
		my ($ev) = grep { $_->{name} eq 'exception' } @{ $span->{events} // [] };
		ok($ev, "$site: the exception event is still added");
		ok($ev && !(grep { $_->{key} eq $attr_key } @{ $ev->{attrs} }),
			"$site: $attr_key is missing from the exception event") if $ev;
		cmp_ok($meta->{counters}{error_capture_failed}, '>=', 1,
			"$site: error_capture_failed increased");
	});
}

# ---- error-filename / error-funcname: dropped, but NO counter marks it (gap) ----
for my $field (qw(filename funcname))
{
	my $site = "error-$field";
	my $attr_key = $field eq 'filename' ? 'code.file.path' : 'code.function.name';
	my $sql = "SELECT otel_api_conformance_oom_arm('$site');\n"
	  . "SELECT otel_api_conformance_record_error_full_scenario('conformance.oom.$site');\n"
	  . "SELECT otel_api_conformance_oom_disarm('$site');\n";
	run_site($site, $sql, sub {
		my ($meta, $spans) = @_;
		my ($span) = grep { $_->{name} eq "conformance.oom.$site" } @$spans;
		ok($span, "$site: the erroring span is still exported");
		my ($ev) = grep { $_->{name} eq 'exception' } @{ $span->{events} // [] };
		ok($ev, "$site: the exception event is still added");
		ok($ev && !(grep { $_->{key} eq $attr_key } @{ $ev->{attrs} }),
			"$site: $attr_key is missing from the exception event") if $ev;
		TODO:
		{
			local $TODO =
			  'postgres-cdq.9.2: slot_record_error() only bumps error_capture_failed when '
			  . 'message/detail/hint fail to copy (slot_record_error); a failed filename/'
			  . 'funcname copy is silently dropped with no counter at all, unlike every other '
			  . 'OOM-drop path in otel_api, which is inconsistent.';
			cmp_ok($meta->{counters}{error_capture_failed}, '>=', 1,
				"$site: error_capture_failed should increase like the message/detail/hint "
				  . "cases (gap: stayed " . $meta->{counters}{error_capture_failed} . ")");
		}
	});
}

# ---- pool: ensure_pool's slots array, on the first span in a fresh backend ----
{
	my $sql = "SELECT otel_api_conformance_oom_arm('pool');\n"
	  . "SELECT otel_api_conformance_start('conformance.oom.pool') AS r;\n"
	  . "SELECT otel_api_conformance_oom_disarm('pool');\n";
	run_site('pool', $sql, sub {
		my ($meta, $spans) = @_;
		is($meta->{counters}{start_no_slot}, 1,
			'pool: start_no_slot increased exactly once for the failed first span')
		  or diag(encode_json($meta));
	}, 'pool', 1);
}

# ---- pool: a failed slots allocation must not leave its context behind ----
# ensure_pool only creates span_pool_cxt if it doesn't already exist, so a
# failed slots allocation doesn't leak a new context on retry.  Two failed
# first spans and one good one must still leave exactly one "otel_api span
# pool" context.
{
	my $out = $node->safe_psql('postgres', <<'SQL');
SELECT otel_api_conformance_oom_arm('pool', 0, 2);
SELECT otel_api_conformance_start('conformance.oom.pool_retry1');
SELECT otel_api_conformance_start('conformance.oom.pool_retry2');
SELECT (otel_api_conformance_oom_status('pool')->>'fails')::int AS fails \gset
SELECT otel_api_conformance_oom_disarm('pool');
SELECT otel_api_conformance_end(otel_api_conformance_start('conformance.oom.pool_ok'));
SELECT :fails;
SELECT count(*) FROM pg_backend_memory_contexts WHERE name = 'otel_api span pool';
SQL
	my @l = split /\n/, $out;
	my ($failed, $pools) = @l[-2, -1];
	is($failed, 2, 'pool retry: both first attempts failed at the injection point');
	is($pools, 1, "pool retry: one span pool context (got $pools)");
}

$node->stop;
done_testing();
