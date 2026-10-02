/*-------------------------------------------------------------------------
 *
 * otel_plpgsql.c
 *	  OpenTelemetry tracing consumer for PL/pgSQL, via the PLpgSQL_plugin
 *	  rendezvous API (func_setup/func_beg/func_end, stmt_beg/stmt_end).
 *	  plpgsql itself is not modified.
 *
 * One span per function/procedure call (pg.plpgsql.function), nested by
 * call: the default parent (OTEL_PARENT_ACTIVE) picks up the top of
 * otel_api's active stack when there is one (an enclosing
 * otel_postgres_tracing statement span, an outer plpgsql call/statement,
 * or anything else a producer activated), and otherwise the backend's
 * propagated root context (otel_api.traceparent / sqlcommenter / the 'M'
 * header) if there is one, so a client that propagates trace context
 * gets plpgsql spans in that trace even with nothing else on the active
 * stack.  Only with no active span AND no root context does a call start
 * a brand-new trace --- still decided (and sampled) fresh per outermost
 * call in that case, since there is nothing to inherit from.
 *
 * Optionally, one span per statement (pg.plpgsql.stmt), gated by
 * otel_plpgsql.trace_statements.
 *
 * func_end/stmt_end are not called when a statement raises an ERROR that
 * isn't caught below this module: otel_api's own resource-owner release
 * at transaction abort ends every still-open span with ERROR status, so
 * nothing special is needed here for that path.  An error caught by a
 * BEGIN ... EXCEPTION block is different: plpgsql runs the protected
 * statements in a subtransaction, and when one of them raises, plpgsql's
 * own PG_CATCH rolls that subtransaction back (which releases --- and so
 * ends, with ERROR status --- every span owned by it or a nested one)
 * and then runs the exception handler's statements, all before this
 * module's stmt_end is ever called for the block.  So our own bookkeeping
 * (a stack of {stmtid, span} pushed in stmt_beg) can hold entries whose
 * span handle is already gone by the time stmt_end for an *enclosing*
 * statement runs; see otel_plpgsql_stmt_end() below for how that's
 * resynced --- the rule is simply: never call the producer API again on
 * a stack entry that isn't the exact one stmt_end was called for, because
 * the ones underneath might already be stale (a stale handle is a
 * counted no-op in production builds, but an Assert failure in cassert
 * builds).
 *
 * plpgsql_stmt_typename() is declared PGDLLEXPORT by plpgsql itself
 * (plpgsql.h) and called directly here, resolved at load time against
 * whatever already-loaded copy of plpgsql.so exports it --- there is no
 * link-time dependency.  Because this module is meant for
 * shared_preload_libraries, 'plpgsql' itself must appear in that same
 * list BEFORE this module (or otel_plpgsql_stub): preloaded libraries
 * are dlopen'd eagerly with every symbol resolved immediately, not
 * lazily on first use, so if plpgsql.so hasn't been loaded yet when this
 * module is, the postmaster fails to start with "undefined symbol:
 * plpgsql_stmt_typename".  (plpgsql isn't preloaded by default; it's
 * normally dlopen'd lazily on the first plpgsql function call.  This is
 * the same reason plprofiler/plpgsql_check document
 * shared_preload_libraries = 'plpgsql,<themselves>'.)
 *
 * Built TWICE from this one source (see Makefile), the same way
 * tests/otel_api_microbench is:
 *
 *   otel_plpgsql       -DHAVE_OTEL_API, against otel_api/otel_producer.h
 *   otel_plpgsql_stub  against the vendored otel_producer_stub.h (+
 *                      otel_types.h) copies in this directory, i.e. S0
 *                      "otel_api hooks compiled out"
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 * otel_plpgsql/otel_plpgsql.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "fmgr.h"
#include "miscadmin.h"
#include "utils/guc.h"
#include "utils/memutils.h"

#include "plpgsql.h"

#ifdef HAVE_OTEL_API
#include "otel_api/otel_producer.h"
#include "otel_api/otel_semconv.h"
#else
#include "otel_producer_stub.h"
/* otel_semconv.h defines these as plain strings; vendoring the whole
 * header for two names isn't worth it since the stub build never sends
 * an attribute anywhere --- the keys are simply never read. */
#define OTEL_SC_CODE_FUNCTION_NAME	"code.function.name"
#define OTEL_SC_CODE_LINE_NUMBER	"code.line.number"
#endif

PG_MODULE_MAGIC;

/* Attributes this module defines; nothing in otel_semconv.h fits. */
#define OTEL_PG_PLPGSQL_FUNCTION_OID	"pg.plpgsql.function_oid"
#define OTEL_PG_PLPGSQL_STMT_TYPE		"pg.plpgsql.stmt_type"

void		_PG_init(void);

static OtelTracer otel_plpgsql_tracer = {.name = "otel_plpgsql", .version = "1.0"};

/* GUCs */
static bool otel_plpgsql_enabled = true;
static bool otel_plpgsql_trace_statements = true;

/*
 * One stack entry per currently-open PL/pgSQL statement in this function
 * invocation.  stmtid is PLpgSQL_stmt->stmtid (unique within the
 * function, assigned at parse time, so it is stable identity to match a
 * stmt_beg against its stmt_end even across an exception-handler resync).
 * span may be OTEL_SPAN_NONE, either because nothing could record, or
 * because otel_plpgsql.trace_statements was off when stmt_beg pushed it
 * --- ending or discarding OTEL_SPAN_NONE is always a safe no-op, so the
 * stack always has exactly one entry per open stmt_beg regardless of that
 * GUC, which keeps the stmtid matching in otel_plpgsql_stmt_end() simple
 * and exact.
 */
typedef struct PlpgsqlStmtSpan
{
	unsigned int stmtid;
	OtelSpanRef span;
} PlpgsqlStmtSpan;

/*
 * Per plpgsql function invocation (estate->plugin_info).  Allocated in
 * func_setup, in whatever is CurrentMemoryContext there --- the
 * function's own per-call execution context (see plpgsql_estate_setup()),
 * freed automatically when the call ends, including on ERROR.
 */
typedef struct PlpgsqlSpanState
{
	OtelSpanRef func_span;

	/*
	 * True for a nonatomic invocation (estate->atomic == false): a
	 * top-level CALL to a procedure, or a top-level DO block, run
	 * outside an explicit transaction block.  PLPGSQL_STMT_COMMIT /
	 * PLPGSQL_STMT_ROLLBACK are only legal in exactly this case
	 * (postgres-cdq.9.1 --- open design question for where a
	 * transaction-controlling CALL's own span should attach).  A plain
	 * resource-owner-owned span open across an internal COMMIT gets
	 * force-released (as a "leak") by that commit, which would leave our
	 * own handles stale; ending a stale handle a second time at
	 * func_end/stmt_end is a counted no-op in production builds but an
	 * Assert failure in cassert builds, i.e. a crash.  To avoid that,
	 * every span this module opens during a nonatomic invocation uses
	 * OTEL_OWNER_SESSION instead of the default (CurrentResourceOwner):
	 * a session span isn't tied to any resource owner, so it survives an
	 * inner COMMIT/ROLLBACK untouched and we close it ourselves as usual
	 * from func_end/stmt_end.  The trade-off, confined to this narrow
	 * case: an uncaught ERROR no longer auto-ends these spans (there is
	 * no owner release to do it), so they leak for the rest of the
	 * session instead of being exported with ERROR status.  See
	 * t/008_call_commit.pl.
	 */
	bool		use_session_owner;

	int			depth;
	int			capacity;
	PlpgsqlStmtSpan *stack;
} PlpgsqlSpanState;

#define PLPGSQL_STMT_STACK_INIT_CAPACITY 8

static void otel_plpgsql_func_setup(PLpgSQL_execstate *estate, PLpgSQL_function *func);
static void otel_plpgsql_func_beg(PLpgSQL_execstate *estate, PLpgSQL_function *func);
static void otel_plpgsql_func_end(PLpgSQL_execstate *estate, PLpgSQL_function *func);
static void otel_plpgsql_stmt_beg(PLpgSQL_execstate *estate, PLpgSQL_stmt *stmt);
static void otel_plpgsql_stmt_end(PLpgSQL_execstate *estate, PLpgSQL_stmt *stmt);

static PLpgSQL_plugin otel_plpgsql_plugin_funcs =
{
	.func_setup = otel_plpgsql_func_setup,
	.func_beg = otel_plpgsql_func_beg,
	.func_end = otel_plpgsql_func_end,
	.stmt_beg = otel_plpgsql_stmt_beg,
	.stmt_end = otel_plpgsql_stmt_end,
};

static inline ResourceOwner
otel_plpgsql_owner(const PlpgsqlSpanState *st)
{
	return st->use_session_owner ? OTEL_OWNER_SESSION : NULL;
}

static void
otel_plpgsql_stack_push(PlpgsqlSpanState *st, unsigned int stmtid, OtelSpanRef span)
{
	if (st->depth == st->capacity)
	{
		st->capacity *= 2;
		st->stack = (PlpgsqlStmtSpan *)
			repalloc(st->stack, sizeof(PlpgsqlStmtSpan) * st->capacity);
	}
	st->stack[st->depth].stmtid = stmtid;
	st->stack[st->depth].span = span;
	st->depth++;
}

static void
otel_plpgsql_func_setup(PLpgSQL_execstate *estate, PLpgSQL_function *func)
{
	PlpgsqlSpanState *st;

	if (!otel_plpgsql_enabled)
	{
		estate->plugin_info = NULL;
		return;
	}

	st = (PlpgsqlSpanState *) palloc(sizeof(PlpgsqlSpanState));
	st->func_span = OTEL_SPAN_NONE;

	/*
	 * NOT estate->atomic here: plpgsql_estate_setup() (which calls
	 * func_setup, at its very end) unconditionally sets estate->atomic =
	 * true before returning; only the CALLER OF THAT (plpgsql_exec_function
	 * et al) overwrites it with the real value afterwards, and only once
	 * plpgsql_estate_setup() has already returned. So estate->atomic is
	 * always (wrongly) true by the time func_setup runs --- it's read in
	 * func_beg instead, by which point it holds the real value.
	 */
	st->use_session_owner = false;
	st->depth = 0;
	st->capacity = PLPGSQL_STMT_STACK_INIT_CAPACITY;
	st->stack = (PlpgsqlStmtSpan *)
		palloc(sizeof(PlpgsqlStmtSpan) * st->capacity);

	estate->plugin_info = st;
}

static void
otel_plpgsql_func_beg(PLpgSQL_execstate *estate, PLpgSQL_function *func)
{
	PlpgsqlSpanState *st = (PlpgsqlSpanState *) estate->plugin_info;

	if (st == NULL)
		return;

	/* The real value; see the comment in otel_plpgsql_func_setup(). */
	st->use_session_owner = !estate->atomic;

	/*
	 * Default parent (OTEL_PARENT_ACTIVE): top of the active stack if
	 * one is there (an outer plpgsql function/statement span, a
	 * statement span from otel_postgres_tracing, or anything else a
	 * producer activated); otherwise the backend's root context
	 * (otel_api.traceparent, sqlcommenter, or the 'M' protocol header),
	 * so a client that propagates trace context gets plpgsql spans IN
	 * that trace even when nothing else put a span on the active stack
	 * first; and only when there is no context at all either does this
	 * start a brand-new trace --- still decided (and sampled) fresh for
	 * each outermost call, since nothing is on the stack and there is no
	 * root context to inherit from.
	 */
	st->func_span = otel_span_start(.tracer = &otel_plpgsql_tracer,
									.name = "pg.plpgsql.function",
									.kind = OTEL_SPAN_KIND_INTERNAL,
									.owner = otel_plpgsql_owner(st));

	if (otel_span_recording(st->func_span))
	{
		otel_span_set_str(st->func_span, OTEL_SC_CODE_FUNCTION_NAME,
						  func->fn_signature);
		otel_span_set_int(st->func_span, OTEL_PG_PLPGSQL_FUNCTION_OID,
						  (int64) func->fn_oid);
	}
}

static void
otel_plpgsql_func_end(PLpgSQL_execstate *estate, PLpgSQL_function *func)
{
	PlpgsqlSpanState *st = (PlpgsqlSpanState *) estate->plugin_info;

	if (st == NULL)
		return;

	/*
	 * Normally empty already (the outermost statement --- the function
	 * body block --- balances its own stmt_beg/stmt_end around every
	 * nested statement, see otel_plpgsql_stmt_end()).  Defensive only:
	 * never touch a leftover handle here, same reasoning as
	 * otel_plpgsql_stmt_end().
	 */
	st->depth = 0;

	otel_span_end(st->func_span);
	st->func_span = OTEL_SPAN_NONE;
}

static void
otel_plpgsql_stmt_beg(PLpgSQL_execstate *estate, PLpgSQL_stmt *stmt)
{
	PlpgsqlSpanState *st = (PlpgsqlSpanState *) estate->plugin_info;
	OtelSpanRef span = OTEL_SPAN_NONE;

	if (st == NULL)
		return;

	if (otel_plpgsql_trace_statements)
	{
		/* Default .parent = OTEL_PARENT_ACTIVE: nests under the function
		 * span, or the enclosing statement's span, whichever is
		 * currently on top of otel_api's active stack. */
		span = otel_span_start(.tracer = &otel_plpgsql_tracer,
							   .name = "pg.plpgsql.stmt",
							   .kind = OTEL_SPAN_KIND_INTERNAL,
							   .owner = otel_plpgsql_owner(st));

		if (otel_span_recording(span))
		{
			otel_span_set_str(span, OTEL_PG_PLPGSQL_STMT_TYPE,
							  plpgsql_stmt_typename(stmt));
			otel_span_set_int(span, OTEL_SC_CODE_LINE_NUMBER, stmt->lineno);
		}
	}

	otel_plpgsql_stack_push(st, stmt->stmtid, span);
}

static void
otel_plpgsql_stmt_end(PLpgSQL_execstate *estate, PLpgSQL_stmt *stmt)
{
	PlpgsqlSpanState *st = (PlpgsqlSpanState *) estate->plugin_info;

	if (st == NULL)
		return;

	/*
	 * Discard (never end/discard via the producer API) any entries above
	 * the one matching this stmt: those belong to statements an ERROR
	 * unwound straight past (their stmt_end was never called) on its way
	 * to a BEGIN ... EXCEPTION block that caught it below us. That
	 * block's own PG_CATCH already rolled back the subtransaction those
	 * entries' spans were (by default) owned by, which force-ended each
	 * of them with ERROR status via resource-owner release.  Their
	 * handles may now be stale, and the producer API treats using a
	 * stale handle again as misuse (a counted no-op normally, an Assert
	 * failure in cassert builds) --- so the only safe thing to do with
	 * them here is drop our own bookkeeping and move on.
	 */
	while (st->depth > 0 && st->stack[st->depth - 1].stmtid != stmt->stmtid)
		st->depth--;

	if (st->depth == 0)
		return;					/* no matching entry; nothing to end */

	st->depth--;
	otel_span_end(st->stack[st->depth].span);
}

void
_PG_init(void)
{
	PLpgSQL_plugin **plugin_ptr;

	DefineCustomBoolVariable("otel_plpgsql.enabled",
							 "Trace PL/pgSQL function and procedure calls.",
							 "Master switch for this module's PLpgSQL_plugin hooks. When off, "
							 "func_beg/func_end/stmt_beg/stmt_end do nothing and allocate "
							 "nothing per call.",
							 &otel_plpgsql_enabled,
							 true,
							 PGC_USERSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("otel_plpgsql.trace_statements",
							 "Emit a span per executed PL/pgSQL statement.",
							 "When off, only the per-call pg.plpgsql.function span is produced; "
							 "individual statements inside the function are not. Has no effect "
							 "when otel_plpgsql.enabled is off.",
							 &otel_plpgsql_trace_statements,
							 true,
							 PGC_USERSET,
							 0,
							 NULL, NULL, NULL);

	MarkGUCPrefixReserved("otel_plpgsql");

	/*
	 * Rendezvous with plpgsql: find_rendezvous_variable() creates the
	 * slot (initialised to NULL) if plpgsql hasn't claimed it yet in this
	 * backend --- plpgsql's own pl_handler.c does the same lookup lazily,
	 * on first use, so whichever of us runs first wins the race to
	 * create the (shared, backend-local) slot; only who WRITES a
	 * non-NULL pointer into it matters, and that's decided below. Only
	 * one plugin may hold it: a plprofiler or plpgsql_check already
	 * loaded first wins, and we just warn and stay inert.
	 */
	plugin_ptr = (PLpgSQL_plugin **) find_rendezvous_variable("PLpgSQL_plugin");

	if (*plugin_ptr != NULL)
	{
		ereport(WARNING,
				(errmsg("otel_plpgsql: the PL/pgSQL plugin slot is already in use"),
				 errdetail("Another module (e.g. plprofiler or plpgsql_check) has already "
						   "registered a PLpgSQL_plugin. PL/pgSQL tracing is disabled for "
						   "this backend.")));
		return;
	}

	*plugin_ptr = &otel_plpgsql_plugin_funcs;
}
