# Copyright (c) 2026, PostgreSQL Global Development Group
#
# A top-level CALL to a procedure that COMMITs internally
# (postgres-cdq.9.1, explicitly open/unsettled: where should a
# transaction-controlling CALL's own span attach?).  Out of scope for
# this module beyond: don't crash, don't flood the log with misuse
# warnings, and document what actually happens.
#
# PLPGSQL_STMT_COMMIT/ROLLBACK are only legal in a NONATOMIC invocation
# (estate->atomic == false): a top-level CALL or DO run outside an
# explicit transaction block.  This module detects that case
# (otel_plpgsql_func_setup()) and uses OTEL_OWNER_SESSION for every span
# it opens during it instead of the default resource-owner ownership, so
# an inner COMMIT doesn't force-release (and so go stale) spans that are
# still open across it.  The documented trade-off: an UNCAUGHT error in
# a nonatomic call no longer auto-ends those spans via owner release
# (there is none), so they leak until something else ends the session
# (not exercised destructively here --- see the "no crash" assertions
# instead, which is what's actually in scope).

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf', <<EOCONF);
shared_preload_libraries = 'plpgsql,otel_api,otel_plpgsql,test_otel_exporter'
log_min_messages = warning
EOCONF
$node->start;

$node->safe_psql('postgres',
	'CREATE EXTENSION otel_api; CREATE EXTENSION otel_plpgsql; '
	. 'CREATE EXTENSION test_otel_exporter');

$node->safe_psql(
	'postgres', q{
CREATE TABLE occ_log (i int);

CREATE PROCEDURE occ_commits() LANGUAGE plpgsql AS $BODY$
BEGIN
	INSERT INTO occ_log VALUES (1);
	COMMIT;
	INSERT INTO occ_log VALUES (2);
	COMMIT;
END;
$BODY$;
});

# CALL must be a top-level statement (not inside an explicit transaction
# block) for an internal COMMIT to be legal at all.
my $combined = $node->safe_psql(
	'postgres', q{
	SET otel_plpgsql.trace_statements = on;
	SELECT test_otel_clear();
	CALL occ_commits();
	SELECT 'ROWS:' || count(*) FROM occ_log;
	SELECT 'COUNT:' || test_otel_span_count();
});

my ($rows) = $combined =~ /^ROWS:(\d+)$/m;
is($rows, '2', 'the procedure actually ran both COMMITs (no crash, work was committed)');

# Whether the function/statement spans were captured at all (session
# ownership means nothing forces them closed early, so they should
# survive to a normal func_end/stmt_end and get exported) is secondary
# to "did anything crash or misbehave"; still worth recording what
# actually happens today.
my ($span_count) = $combined =~ /^COUNT:(\d+)$/m;
note("spans captured for a CALL with internal COMMIT: $span_count");

ok(!$node->log_contains(qr/\b(PANIC|FATAL):|stale|out of (order|LIFO|lifo)/i),
	'no crash, and no stale-handle/out-of-order misuse warning, '
	. 'despite the internal COMMIT');

# The backend must still be alive and usable afterwards.
is($node->safe_psql('postgres', 'SELECT 1'), '1',
	'the backend is still alive and queryable after CALL with internal COMMIT');

$node->stop;
done_testing();
