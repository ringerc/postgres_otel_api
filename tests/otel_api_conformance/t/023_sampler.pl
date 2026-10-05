# Copyright (c) 2026, PostgreSQL Global Development Group
#
# otel_api owns the sampler policy (otel_api.sampler / otel_api.sampler_arg,
# postgres-cdq.18): there is no sampler hook or set_sampler_policy any
# more.  This walks the sampler matrix for each OTEL_TRACES_SAMPLER-style
# value, for a brand-new root (parent_mode => 'root') and for a remote
# parent with each W3C sampled bit (parent_mode => 'context', built with
# otel_api_conformance_context_send so the trace ID and sampled bit are
# exact and deterministic); traceidratio at p=1.0, p=0.0 and p=0.5 using
# two fixed trace IDs chosen to fall on each side of the p=0.5 rejection
# threshold (consistent probability sampling on the trace ID's low 56
# bits); otel_api.sampler_arg range validation; and PGC_SUSET
# enforcement.
#
# Not covered here (documented limitation, not a bug): a genuinely new
# root's trace ID is generated internally by otel_producer.c and can't
# be pinned from SQL, so parentbased_traceidratio's new-root fallback
# path isn't exercised with a fixed trace ID.  The traceidratio math
# itself is exactly the same function otel_run_sampler() calls for a
# new root and for a remote parent (it only ever looks at the trace ID
# bytes), so the fixed-trace-ID cases below already cover it; what's
# not separately re-proven is that a *new root specifically* reaches
# that function with the W3C random flag set (true by construction --
# see new_trace_id()/OTEL_TRACE_FLAG_RANDOM in otel_producer.c --
# but not asserted on here).
#
# force_sample recording a new root under otel_api.sampler =
# traceidratio/0 and parentbased_always_off, and NOT doing so under
# plain always_off (a full off switch), is covered by
# t/022_force_sample.pl, not repeated here.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'otel_api,otel_api_conformance'\n");
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_api_conformance');
$node->safe_psql('postgres',
	"CREATE ROLE sampler_nonsuper LOGIN");

my $span_id = '0011223344556677';

# Two trace IDs with the same first 9 bytes but opposite low-56-bit
# randomness: BELOW has all-zero low 7 bytes (R=0, always below any
# positive-ratio threshold); ABOVE has all-0xff low 7 bytes (R =
# 2^56-1, always at/above any sub-1.0 threshold).  p=0.5's threshold
# is exactly 2^55, so these two are not a near-miss on either side --
# they are about as unambiguous as it gets.
my $trace_below = '01020304050607080900000000000000';
my $trace_above = '010203040506070809ffffffffffffff';

# ----------------------------------------------------------------
# Helper: start+end a span under a given sampler/arg and parent kind,
# return whether it was recorded ('t'/'f').
# ----------------------------------------------------------------
sub sample_cell
{
	my ($sampler, $arg, $parent_mode, $trace_id, $sampled_bit) = @_;

	my $sql = "SET otel_api.sampler = '$sampler';\n";
	$sql .= "SET otel_api.sampler_arg = $arg;\n";
	$sql .= "BEGIN;\n";
	if ($parent_mode eq 'context')
	{
		$sql .= "SELECT encode(otel_api_conformance_context_send("
		  . "'$trace_id', '$span_id', $sampled_bit), 'hex') AS wire \\gset\n";
		$sql .= "SELECT otel_api_conformance_start('conformance.sampler_matrix', "
		  . "parent_mode => 'context', parent_ctx => decode(:'wire', 'hex'), "
		  . "owner_mode => 'toptxn') AS s \\gset\n";
	}
	else
	{
		$sql .= "SELECT otel_api_conformance_start('conformance.sampler_matrix', "
		  . "parent_mode => 'root', owner_mode => 'toptxn') AS s \\gset\n";
	}
	$sql .= "SELECT otel_api_conformance_recording(:s) AS recording;\n";
	$sql .= "SELECT otel_api_conformance_end(:s) AS r1 \\gset\n";
	$sql .= "COMMIT;\n";

	my $out = $node->safe_psql('postgres', $sql);
	return $out;
}

sub check_cell
{
	my ($label, $sampler, $arg, $parent_mode, $trace_id, $sampled_bit, $expected) = @_;
	my $recording = sample_cell($sampler, $arg, $parent_mode, $trace_id, $sampled_bit);
	is($recording, $expected, $label);
}

# ----------------------------------------------------------------
# New root (parent_mode => 'root'): always_on/always_off record per
# their own name; parentbased_* fall back to the same behaviour as
# the non-parentbased sampler of the same name, since there is no
# parent to inherit a decision from.
# ----------------------------------------------------------------
check_cell('new root, always_on: recorded',
	'always_on', 1.0, 'root', undef, undef, 't');
check_cell('new root, always_off: dropped',
	'always_off', 1.0, 'root', undef, undef, 'f');
check_cell('new root, parentbased_always_on: recorded (root fallback)',
	'parentbased_always_on', 1.0, 'root', undef, undef, 't');
check_cell('new root, parentbased_always_off: dropped (root fallback)',
	'parentbased_always_off', 1.0, 'root', undef, undef, 'f');

# ----------------------------------------------------------------
# Remote parent, sampled=1 and sampled=0: parentbased_* follow the
# remote bit; the non-parentbased samplers ignore it entirely.
# ----------------------------------------------------------------
for my $row (
	[ 'always_on',             1, 't' ],
	[ 'always_on',             0, 't' ],
	[ 'always_off',            1, 'f' ],
	[ 'always_off',            0, 'f' ],
	[ 'parentbased_always_on',  1, 't' ],
	[ 'parentbased_always_on',  0, 'f' ],
	[ 'parentbased_always_off', 1, 't' ],
	[ 'parentbased_always_off', 0, 'f' ],
  )
{
	my ($sampler, $bit, $expected) = @$row;
	check_cell(
		"remote parent sampled=$bit, $sampler: recording=$expected",
		$sampler, 1.0, 'context', $trace_below, $bit, $expected);
}

# ----------------------------------------------------------------
# traceidratio: ignores the remote sampled bit; decides purely on the
# trace ID's low 56 bits versus the ratio's rejection threshold.
# ----------------------------------------------------------------
for my $row (
	[ $trace_below, 1.0, 1, 't' ],	# ratio=1.0 always samples
	[ $trace_above, 1.0, 0, 't' ],
	[ $trace_below, 0.0, 1, 'f' ],	# ratio=0.0 never samples
	[ $trace_above, 0.0, 0, 'f' ],
	[ $trace_below, 0.5, 0, 'f' ],	# below the p=0.5 threshold
	[ $trace_above, 0.5, 1, 't' ],	# at/above the p=0.5 threshold
  )
{
	my ($trace_id, $ratio, $bit, $expected) = @$row;
	check_cell(
		"traceidratio ratio=$ratio, trace="
		  . ($trace_id eq $trace_below ? 'below' : 'above')
		  . ", wire=$bit: recording=$expected",
		'traceidratio', $ratio, 'context', $trace_id, $bit, $expected);
}

# ----------------------------------------------------------------
# parentbased_traceidratio with a remote parent: the remote's sampled
# bit decides, exactly like parentbased_always_on/off -- the ratio
# is not consulted at all.  Proven by pairing ratio=0.0 (would always
# drop under plain traceidratio) with a sampled=1 remote parent, and
# ratio=1.0 (would always sample) with a sampled=0 remote parent.
# ----------------------------------------------------------------
check_cell(
	'parentbased_traceidratio, ratio=0.0, remote sampled=1: follows the remote bit',
	'parentbased_traceidratio', 0.0, 'context', $trace_below, 1, 't');
check_cell(
	'parentbased_traceidratio, ratio=1.0, remote sampled=0: follows the remote bit',
	'parentbased_traceidratio', 1.0, 'context', $trace_above, 0, 'f');

# ----------------------------------------------------------------
# otel_api.sampler_arg range validation: outside [0.0, 1.0] is
# rejected by the GUC machinery.
# ----------------------------------------------------------------
{
	my ($stdout, $stderr) = ('', '');
	my $rc = $node->psql('postgres', 'SET otel_api.sampler_arg = 1.5',
		stdout => \$stdout, stderr => \$stderr);
	isnt($rc, 0, 'otel_api.sampler_arg = 1.5 is rejected');
	like($stderr, qr/outside the valid range/,
		'rejection names the valid range');
}
{
	my ($stdout, $stderr) = ('', '');
	my $rc = $node->psql('postgres', 'SET otel_api.sampler_arg = -0.1',
		stdout => \$stdout, stderr => \$stderr);
	isnt($rc, 0, 'otel_api.sampler_arg = -0.1 is rejected');
}

# ----------------------------------------------------------------
# PGC_SUSET: an ordinary role cannot raise the sample rate.
# ----------------------------------------------------------------
{
	my ($stdout, $stderr) = ('', '');
	my $rc = $node->psql('postgres', "SET otel_api.sampler = 'always_on'",
		stdout => \$stdout, stderr => \$stderr,
		extra_params => [ '-U', 'sampler_nonsuper' ]);
	isnt($rc, 0, 'a non-superuser cannot SET otel_api.sampler');
	like($stderr, qr/permission denied/,
		'the error is a permission-denied, not something else');
}
{
	my ($stdout, $stderr) = ('', '');
	my $rc = $node->psql('postgres', "SET otel_api.sampler_arg = 1.0",
		stdout => \$stdout, stderr => \$stderr,
		extra_params => [ '-U', 'sampler_nonsuper' ]);
	isnt($rc, 0, 'a non-superuser cannot SET otel_api.sampler_arg');
}

$node->stop;
done_testing();
