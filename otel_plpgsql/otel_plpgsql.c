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
 * isn't caught below this module.  For an ordinary (atomic) call, that's
 * fine without any help from this module: otel_api's own resource-owner
 * release at transaction (or subtransaction) abort ends every still-open
 * default-owned span with ERROR status.  An error caught by a BEGIN ...
 * EXCEPTION block is similar: plpgsql runs the protected statements in a
 * subtransaction, and when one of them raises, plpgsql's own PG_CATCH
 * rolls that subtransaction back (which releases --- and so ends, with
 * ERROR status --- every default-owned span opened inside it) and then
 * runs the exception handler's statements, all before this module's
 * stmt_end is ever called for the block.  So our own bookkeeping (a
 * stack of {stmtid, span} pushed in stmt_beg) can hold entries whose span
 * handle is already gone by the time stmt_end for an *enclosing*
 * statement runs; see otel_plpgsql_stmt_end() below for how that's
 * resynced --- the rule is simply: never call the producer API again on
 * a stack entry that isn't the exact one stmt_end was called for, because
 * the ones underneath might already be stale (a stale handle is a
 * counted no-op in production builds, but an Assert failure in cassert
 * builds).
 *
 * A nonatomic invocation (PlpgsqlSpanState.use_session_owner, below) uses
 * OTEL_OWNER_SESSION instead, which has no resource owner at all, so
 * NOTHING auto-ends those spans on abort; this module's own
 * SubXactCallback/XactCallback (otel_plpgsql_subxact_callback(),
 * otel_plpgsql_xact_callback()) do that job instead, against a registry
 * of this backend's currently-open session spans
 * (otel_plpgsql_session_push()/_forget(), and the comment on
 * PlpgsqlSessionSpan) --- by the time stmt_end's resync above ever runs,
 * any session span that needed force-ending has already been, so the
 * same resync logic (discard the stale bookkeeping, never touch the
 * handle again) is correct for both owner modes without needing to know
 * which one it's looking at.
 *
 * plpgsql_stmt_typename() is declared PGDLLEXPORT by plpgsql itself
 * (plpgsql.h), but is resolved lazily, through a function pointer
 * (otel_plpgsql_stmt_typename() below) via
 * load_external_function("$libdir/plpgsql", ...) on first use, rather
 * than called directly: a direct call is a link-time reference that
 * RTLD_NOW must resolve the moment this module itself is dlopen'd, which
 * fails with "undefined symbol: plpgsql_stmt_typename" if plpgsql.so
 * hasn't been loaded yet --- and for shared_preload_libraries, dlopen
 * happens at postmaster start in whatever order the GUC lists the
 * libraries, so a direct call would require 'plpgsql' to appear before
 * this module (or otel_plpgsql_stub) in that list.  Resolving it lazily
 * instead means load order doesn't matter: by the time any plugin hook
 * can possibly run, plpgsql has necessarily already loaded itself (it's
 * the one invoking the hooks).
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

#include "access/xact.h"
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
 * Lazily-resolved plpgsql_stmt_typename(); see the file header comment.
 */
typedef const char *(*PlpgsqlStmtTypenameFn) (PLpgSQL_stmt *stmt);

static PlpgsqlStmtTypenameFn otel_plpgsql_stmt_typename_fn = NULL;
static bool otel_plpgsql_stmt_typename_resolved = false;

static const char *
otel_plpgsql_stmt_typename(PLpgSQL_stmt *stmt)
{
	if (!otel_plpgsql_stmt_typename_resolved)
	{
		otel_plpgsql_stmt_typename_fn = (PlpgsqlStmtTypenameFn)
			load_external_function("$libdir/plpgsql", "plpgsql_stmt_typename",
								   true, NULL);
		otel_plpgsql_stmt_typename_resolved = true;
	}
	return otel_plpgsql_stmt_typename_fn(stmt);
}

/*
 * Registry of this backend's currently-open OTEL_OWNER_SESSION spans
 * (every span opened during a nonatomic invocation --- see the comment
 * on PlpgsqlSpanState.use_session_owner below), across every plpgsql
 * invocation on the C stack right now.  A session span has no resource
 * owner, so nothing auto-ends it the way otel_api ends a default-owned
 * span on abort; left alone, an invocation that never reaches its own
 * func_end/stmt_end (an uncaught ERROR, or a BEGIN...EXCEPTION block
 * that catches one without this module's bookkeeping knowing to end the
 * span itself) would leak it forever: still open, and still sitting on
 * otel_api's active stack, silently becoming the parent of whatever the
 * backend does next.
 *
 * This is a workaround for the fact that an otel_api span owner can only
 * be a ResourceOwner or the whole session (postgres-cdq.9.1 is the open
 * design question for a real third option, an owner tied to the
 * top-level CALL/DO's own portal, which would make this registry
 * unnecessary).
 *
 * nest_level is GetCurrentTransactionNestLevel() at the time the span
 * was opened.  Entries are pushed in call order and so are always
 * non-decreasing in nest_level from index 0 (oldest/shallowest) to the
 * top (newest/deepest) --- subtransaction nesting can only get deeper
 * one level at a time, never jump to a shallower level without first
 * ending everything opened at the deeper ones. That means every entry
 * this module ever needs to force-end on an abort is exactly a
 * contiguous suffix of this array, and ending from the top down is
 * automatically innermost-first.
 *
 * Closing a span normally (func_end/stmt_end reaching it without any
 * abort in between) always removes the top entry: these spans close in
 * the same properly-nested order they were opened in, same as each
 * invocation's own local stmt stack, and anything pushed after a given
 * entry but not yet closed has always already been force-closed by the
 * callbacks below before stmt_end's resync (otel_plpgsql_stmt_end())
 * can run.
 *
 * Lives in TopMemoryContext: it must survive the aborted statement's
 * own context being reset (the longjmp past an uncaught ERROR skips
 * func_end, so otel_plpgsql_func_setup() never gets to free this itself
 * the way it frees everything else), and it must survive as backend-wide
 * state since nothing here is tied to one specific invocation's memory.
 */
typedef struct PlpgsqlSessionSpan
{
	OtelSpanRef span;
	int			nest_level;
} PlpgsqlSessionSpan;

static PlpgsqlSessionSpan *otel_plpgsql_session_stack = NULL;
static int	otel_plpgsql_session_depth = 0;
static int	otel_plpgsql_session_capacity = 0;

static void
otel_plpgsql_session_push(OtelSpanRef span)
{
	if (span.v == 0)
		return;

	if (otel_plpgsql_session_stack == NULL)
	{
		otel_plpgsql_session_capacity = 8;
		otel_plpgsql_session_stack = (PlpgsqlSessionSpan *)
			MemoryContextAlloc(TopMemoryContext,
							  sizeof(PlpgsqlSessionSpan) * otel_plpgsql_session_capacity);
	}
	else if (otel_plpgsql_session_depth == otel_plpgsql_session_capacity)
	{
		otel_plpgsql_session_capacity *= 2;
		otel_plpgsql_session_stack = (PlpgsqlSessionSpan *)
			repalloc(otel_plpgsql_session_stack,
					sizeof(PlpgsqlSessionSpan) * otel_plpgsql_session_capacity);
	}

	otel_plpgsql_session_stack[otel_plpgsql_session_depth].span = span;
	otel_plpgsql_session_stack[otel_plpgsql_session_depth].nest_level =
		GetCurrentTransactionNestLevel();
	otel_plpgsql_session_depth++;
}

/*
 * Forget a session span this module is about to end itself, normally,
 * from func_end/stmt_end.  Always the top entry; see the file-scope
 * comment on PlpgsqlSessionSpan.
 */
static void
otel_plpgsql_session_forget(OtelSpanRef span)
{
	if (span.v == 0)
		return;

	Assert(otel_plpgsql_session_depth > 0);
	Assert(otel_plpgsql_session_stack[otel_plpgsql_session_depth - 1].span.v == span.v);

	if (otel_plpgsql_session_depth > 0)
		otel_plpgsql_session_depth--;
}

/* End a leaked session span with ERROR status; never touch it again. */
static void
otel_plpgsql_end_leaked_session_span(OtelSpanRef span)
{
	otel_span_set_status(span, OTEL_STATUS_ERROR,
						 "otel_plpgsql: ended at transaction/subtransaction abort "
						 "(an OTEL_OWNER_SESSION span opened during a nonatomic "
						 "PL/pgSQL call, with no resource owner to release it "
						 "automatically)");
	otel_span_end(span);
}

/*
 * SubXactCallback: a subtransaction abort doesn't touch a session span
 * (it has no resource owner), but it still needs to end --- with ERROR
 * status --- everything this module opened at or below the aborting
 * level, same as otel_api's own resource-owner release does for a
 * default-owned span.  Ending from the top (innermost/deepest) down
 * guarantees each end() finds its target already at the top of otel_api's
 * active stack too, so this never triggers otel_api's own
 * out-of-order/LIFO-violation unwind path.
 */
static void
otel_plpgsql_subxact_callback(SubXactEvent event, SubTransactionId mySubid,
							  SubTransactionId parentSubid, void *arg)
{
	int			current_level;

	if (event != SUBXACT_EVENT_ABORT_SUB)
		return;

	current_level = GetCurrentTransactionNestLevel();
	while (otel_plpgsql_session_depth > 0 &&
		   otel_plpgsql_session_stack[otel_plpgsql_session_depth - 1].nest_level
		   >= current_level)
	{
		otel_plpgsql_session_depth--;
		otel_plpgsql_end_leaked_session_span(
			otel_plpgsql_session_stack[otel_plpgsql_session_depth].span);
	}
}

/*
 * XactCallback: a top-level abort (or a parallel worker's) undoes every
 * subtransaction at once, so drain the whole registry, innermost first.
 * Nothing to do on commit: by then every session span this module ever
 * opened should already have been ended, normally, by its own
 * func_end/stmt_end --- if one wasn't, that is a bug to notice, not to
 * silently paper over here.
 */
static void
otel_plpgsql_xact_callback(XactEvent event, void *arg)
{
	if (event != XACT_EVENT_ABORT && event != XACT_EVENT_PARALLEL_ABORT)
		return;

	while (otel_plpgsql_session_depth > 0)
	{
		otel_plpgsql_session_depth--;
		otel_plpgsql_end_leaked_session_span(
			otel_plpgsql_session_stack[otel_plpgsql_session_depth].span);
	}
}

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
	 * from func_end/stmt_end.  Because a session span then has nothing
	 * auto-ending it on abort either, every span opened this way is also
	 * registered with otel_plpgsql_session_push() (see the comment on
	 * PlpgsqlSessionSpan), so an uncaught error --- or one caught by a
	 * BEGIN...EXCEPTION block inside the same nonatomic call --- still
	 * ends it, with ERROR status, via this module's own abort callbacks
	 * instead of otel_api's resource-owner release.  See
	 * t/008_call_commit.pl, t/010_nonatomic_uncaught_error.pl and
	 * t/011_nonatomic_caught_exception.pl.
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

#ifdef HAVE_OTEL_API
	/*
	 * Nothing can record (no exporter, no log emission): skip allocating
	 * our own bookkeeping too, not just the spans.  otel_recording_possible_()
	 * is otel_producer.h's own internal gate for otel_span_start(); the
	 * stub header has no equivalent (every call there is already free), so
	 * this check only exists in the HAVE_OTEL_API build.
	 */
	if (!otel_recording_possible_())
	{
		estate->plugin_info = NULL;
		return;
	}
#endif

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

	if (st->use_session_owner)
		otel_plpgsql_session_push(st->func_span);

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

	if (st->use_session_owner)
		otel_plpgsql_session_forget(st->func_span);

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

		if (st->use_session_owner)
			otel_plpgsql_session_push(span);

		if (otel_span_recording(span))
		{
			otel_span_set_str(span, OTEL_PG_PLPGSQL_STMT_TYPE,
							  otel_plpgsql_stmt_typename(stmt));
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
	if (st->use_session_owner)
		otel_plpgsql_session_forget(st->stack[st->depth].span);
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
	 * Keep the OTEL_OWNER_SESSION registry in sync on abort; see the
	 * file-scope comment on PlpgsqlSessionSpan.  Registered unconditionally
	 * (cheap no-op drains of an empty registry when nothing nonatomic is
	 * running, or when otel_plpgsql.enabled is off).
	 */
	RegisterXactCallback(otel_plpgsql_xact_callback, NULL);
	RegisterSubXactCallback(otel_plpgsql_subxact_callback, NULL);

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
