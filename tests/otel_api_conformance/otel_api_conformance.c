/*-------------------------------------------------------------------------
 *
 * otel_api_conformance.c
 *	  Conformance test extension for the otel_api MAJOR 3 API.
 *
 * This module is simultaneously:
 *
 *	 - an exporter: it registers an emit hook (deep-copies every emitted
 *	   span into a backend-local capture list) and a sampler hook (whose
 *	   decision is controlled by the otel_api_conformance.sampler GUC),
 *	   both via otel_exporter_register_when_ready() from _PG_init;
 *
 *	 - a producer: SQL-callable C functions, each running one scenario
 *	   from the P2 design's conformance test-suite list, using two
 *	   distinct OtelTracer scopes (tracer_a / tracer_b, "producer" => a
 *	   or b) to exercise the multi-producer patterns.
 *
 * Design choices worth documenting:
 *
 *	 - The sampler hook is *always* registered (never left unregistered),
 *	   and it consults otel_api_conformance.sampler on every call, rather
 *	   than being conditionally registered based on the GUC.  This keeps
 *	   sampler-call counting available at all times (needed by the
 *	   unsampled-trace tests) without a load-order dependency on when the
 *	   GUC is first set.  "none" approximates the OTel default
 *	   ParentBased(AlwaysOn) sampler using the sampler input's remote
 *	   parent (if any), so that with the GUC left at its default, this
 *	   module behaves like "no sampler hook installed" from a producer's
 *	   point of view, while still counting invocations.
 *
 *	 - Captured spans are kept in an unbounded (repalloc-grown) array in
 *	   a dedicated MemoryContext, not a fixed ring: the conformance suite
 *	   wants exact per-scenario counts, not "last N".
 *	   otel_api_conformance_reset() resets the context and all counters.
 *
 *	 - otel_api_conformance_spans() returns SETOF jsonb: this is the
 *	   simplest representation for a span's variable-shaped attrs/
 *	   events/links, and is one call away from jsonb_pretty() in psql
 *	   for ad hoc debugging.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 * tests/otel_api_conformance/otel_api_conformance.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <string.h>

#include "access/parallel.h"
#include "access/xact.h"
#include "executor/spi.h"
#include "funcapi.h"
#include "lib/stringinfo.h"
#include "libpq/pqformat.h"
#include "miscadmin.h"
#include "postmaster/bgworker.h"
#include "storage/ipc.h"
#include "tcop/tcopprot.h"
#include "utils/builtins.h"
#include "utils/elog.h"
#include "utils/guc.h"
#include "utils/injection_point.h"
#include "utils/memutils.h"
#include "utils/resowner.h"
#include "utils/snapmgr.h"
#include "utils/timestamp.h"

/* The MAJOR 3 headers under test; found via -I$(srcdir)/../../otel_api. */
#include "otel_types.h"
#include "otel_api.h"
#include "otel_producer.h"
#include "otel_exporter.h"
#include "otel_internal_api.h"
#include "otel_semconv.h"

PG_MODULE_MAGIC;

/* jsonb_in() is an ordinary SQL-callable function; not declared in any
 * header we can include, so declare it ourselves (a common pattern for
 * building jsonb from C without libjsonb's internal push/pop API). */
extern Datum jsonb_in(PG_FUNCTION_ARGS);

void		_PG_init(void);
extern void otel_api_conformance_stub_check(void);
pg_noreturn extern PGDLLEXPORT void otel_api_conformance_bgworker_main(Datum main_arg);

/* ----------------------------------------------------------------
 * Tracers: two distinct producer scopes, for the multi-producer tests.
 * ---------------------------------------------------------------- */

static OtelTracer tracer_a = {.name = "otel_api_conformance.a", .version = "0.1"};
static OtelTracer tracer_b = {.name = "otel_api_conformance.b", .version = "0.1"};

/* ----------------------------------------------------------------
 * GUC: what the sampler hook returns.
 * ---------------------------------------------------------------- */

typedef enum ConformanceSamplerMode
{
	CONFORMANCE_SAMPLER_NONE = 0,
	CONFORMANCE_SAMPLER_DROP,
	CONFORMANCE_SAMPLER_RECORD_ONLY,
	CONFORMANCE_SAMPLER_RECORD,
} ConformanceSamplerMode;

static int	conformance_sampler_mode = CONFORMANCE_SAMPLER_NONE;

static const struct config_enum_entry conformance_sampler_options[] = {
	{"none", CONFORMANCE_SAMPLER_NONE, false},
	{"drop", CONFORMANCE_SAMPLER_DROP, false},
	{"record_only", CONFORMANCE_SAMPLER_RECORD_ONLY, false},
	{"record", CONFORMANCE_SAMPLER_RECORD, false},
	{NULL, 0, false},
};

static int64 conformance_sampler_calls = 0;
static int64 conformance_side_effect_calls = 0;

/* ----------------------------------------------------------------
 * Captured spans (exporter side).
 * ---------------------------------------------------------------- */

typedef struct CapturedAttr
{
	char	   *key;
	OtelAttrType type;
	char	   *sval;
	int64		ival;
	double		dval;
	bool		bval;
} CapturedAttr;

typedef struct CapturedEvent
{
	char	   *name;
	TimestampTz time;
	int			n_attrs;
	CapturedAttr *attrs;
} CapturedEvent;

typedef struct CapturedLink
{
	OtelTraceId trace_id;
	OtelSpanId	span_id;
	uint8		trace_flags;
	char	   *tracestate;
} CapturedLink;

typedef struct CapturedSpan
{
	char	   *scope_name;
	char	   *scope_version;
	char	   *scope_schema_url;

	OtelTraceId trace_id;
	OtelSpanId	span_id;
	OtelSpanId	parent_span_id;
	uint8		trace_flags;
	char	   *tracestate;

	char	   *name;
	OtelSpanKind kind;
	OtelSpanStatus status;
	OtelSamplerDecision sampler_decision;
	char	   *status_description;

	TimestampTz start_time;
	TimestampTz end_time;

	int			n_attrs;
	uint32		dropped_attrs;
	CapturedAttr *attrs;

	int			n_events;
	uint32		dropped_events;
	CapturedEvent *events;

	int			n_links;
	uint32		dropped_links;
	CapturedLink *links;
} CapturedSpan;

static MemoryContext capture_cxt = NULL;
static CapturedSpan *captured = NULL;
static int	n_captured = 0;
static int	captured_cap = 0;

static otel_span_emit_hook_type prev_emit_hook = NULL;
static otel_sampler_hook_type prev_sampler_hook = NULL;
static OtelPendingRegistration pending_reg;

/* ----------------------------------------------------------------
 * Caller-created resource owners (for the "custom owner" scenarios).
 * ---------------------------------------------------------------- */

typedef struct ConformanceOwner
{
	int64		id;
	ResourceOwner owner;
} ConformanceOwner;

static MemoryContext owners_cxt = NULL;
static ConformanceOwner *owners = NULL;
static int	n_owners = 0;
static int	owners_cap = 0;
static int64 next_owner_id = 1;

/* ----------------------------------------------------------------
 * Small helpers.
 * ---------------------------------------------------------------- */

static char *
copy_str(const char *s)
{
	if (s == NULL)
		return NULL;
	return MemoryContextStrdup(capture_cxt, s);
}

static bytea *
stringinfo_to_bytea(StringInfo buf)
{
	bytea	   *result = (bytea *) palloc(VARHDRSZ + buf->len);

	SET_VARSIZE(result, VARHDRSZ + buf->len);
	memcpy(VARDATA(result), buf->data, buf->len);
	return result;
}

static void
bytea_to_stringinfo(bytea *b, StringInfo buf)
{
	initStringInfo(buf);
	appendBinaryStringInfo(buf, VARDATA_ANY(b), VARSIZE_ANY_EXHDR(b));
	buf->cursor = 0;
}

static OtelSpanKind
kind_from_text(const char *s)
{
	if (strcmp(s, "internal") == 0)
		return OTEL_SPAN_KIND_INTERNAL;
	if (strcmp(s, "server") == 0)
		return OTEL_SPAN_KIND_SERVER;
	if (strcmp(s, "client") == 0)
		return OTEL_SPAN_KIND_CLIENT;
	if (strcmp(s, "producer") == 0)
		return OTEL_SPAN_KIND_PRODUCER;
	if (strcmp(s, "consumer") == 0)
		return OTEL_SPAN_KIND_CONSUMER;
	ereport(ERROR, (errmsg("otel_api_conformance: unknown kind \"%s\"", s)));
	return OTEL_SPAN_KIND_INTERNAL;	/* unreachable */
}

static OtelSpanUnwindPolicy
unwind_from_text(const char *s)
{
	if (strcmp(s, "drop") == 0)
		return OTEL_UNWIND_DROP;
	if (strcmp(s, "error") == 0)
		return OTEL_UNWIND_ERROR;
	ereport(ERROR, (errmsg("otel_api_conformance: unknown unwind policy \"%s\"", s)));
	return OTEL_UNWIND_DROP;	/* unreachable */
}

static OtelSpanParent
parent_mode_from_text(const char *s)
{
	if (strcmp(s, "active") == 0)
		return OTEL_PARENT_ACTIVE;
	if (strcmp(s, "context") == 0)
		return OTEL_PARENT_CONTEXT;
	if (strcmp(s, "span") == 0)
		return OTEL_PARENT_SPAN;
	if (strcmp(s, "root") == 0)
		return OTEL_PARENT_ROOT;
	ereport(ERROR, (errmsg("otel_api_conformance: unknown parent_mode \"%s\"", s)));
	return OTEL_PARENT_ACTIVE;	/* unreachable */
}

static OtelSpanStatus
status_from_text(const char *s)
{
	if (strcmp(s, "unset") == 0)
		return OTEL_STATUS_UNSET;
	if (strcmp(s, "ok") == 0)
		return OTEL_STATUS_OK;
	if (strcmp(s, "error") == 0)
		return OTEL_STATUS_ERROR;
	ereport(ERROR, (errmsg("otel_api_conformance: unknown status code \"%s\"", s)));
	return OTEL_STATUS_UNSET;	/* unreachable */
}

static ResourceOwner
find_owner(int64 id)
{
	int			i;

	for (i = 0; i < n_owners; i++)
		if (owners[i].id == id)
			return owners[i].owner;
	ereport(ERROR, (errmsg("otel_api_conformance: unknown owner id " INT64_FORMAT, id)));
	return NULL;				/* unreachable */
}

static ResourceOwner
owner_from_mode(const char *mode, bool have_owner_id, int64 owner_id)
{
	if (mode == NULL || strcmp(mode, "default") == 0)
		return NULL;
	if (strcmp(mode, "session") == 0)
		return OTEL_OWNER_SESSION;
	if (strcmp(mode, "toptxn") == 0)
		return TopTransactionResourceOwner;
	if (strcmp(mode, "custom") == 0)
	{
		if (!have_owner_id)
			ereport(ERROR, (errmsg("otel_api_conformance: owner_mode 'custom' requires owner_id")));
		return find_owner(owner_id);
	}
	ereport(ERROR, (errmsg("otel_api_conformance: unknown owner_mode \"%s\"", mode)));
	return NULL;				/* unreachable */
}

/* ----------------------------------------------------------------
 * Hooks.
 * ---------------------------------------------------------------- */

static CapturedAttr *
copy_attrs(const OtelAttribute *src, int n)
{
	CapturedAttr *out;
	int			i;

	if (n <= 0 || src == NULL)
		return NULL;
	out = MemoryContextAllocZero(capture_cxt, sizeof(CapturedAttr) * n);
	for (i = 0; i < n; i++)
	{
		out[i].key = copy_str(src[i].key);
		out[i].type = src[i].type;
		switch (src[i].type)
		{
			case OTEL_ATTR_STRING:
				out[i].sval = copy_str(src[i].v.s);
				break;
			case OTEL_ATTR_INT:
				out[i].ival = src[i].v.i;
				break;
			case OTEL_ATTR_DOUBLE:
				out[i].dval = src[i].v.d;
				break;
			case OTEL_ATTR_BOOL:
				out[i].bval = src[i].v.b;
				break;
		}
	}
	return out;
}

static void
capture_span(const OtelSpan *span)
{
	CapturedSpan *slot;
	MemoryContext old;

	if (!otel_exporter_span_ok(span))
		return;

	old = MemoryContextSwitchTo(capture_cxt);

	if (n_captured == captured_cap)
	{
		captured_cap = captured_cap == 0 ? 64 : captured_cap * 2;
		captured = captured
			? repalloc(captured, sizeof(CapturedSpan) * captured_cap)
			: palloc(sizeof(CapturedSpan) * captured_cap);
	}
	slot = &captured[n_captured++];
	memset(slot, 0, sizeof(*slot));

	if (span->scope)
	{
		slot->scope_name = copy_str(span->scope->name);
		slot->scope_version = copy_str(span->scope->version);
		slot->scope_schema_url = copy_str(span->scope->schema_url);
	}
	slot->trace_id = span->trace_id;
	slot->span_id = span->span_id;
	slot->parent_span_id = span->parent_span_id;
	slot->trace_flags = span->trace_flags;
	slot->tracestate = copy_str(span->tracestate);
	slot->name = copy_str(span->name);
	slot->kind = span->kind;
	slot->status = span->status;
	slot->sampler_decision = span->sampler_decision;
	slot->status_description = copy_str(span->status_description);
	slot->start_time = span->start_time;
	slot->end_time = span->end_time;

	slot->n_attrs = span->n_attrs;
	slot->dropped_attrs = span->dropped_attrs;
	slot->attrs = copy_attrs(span->attrs, span->n_attrs);

	slot->n_events = span->n_events;
	slot->dropped_events = span->dropped_events;
	if (span->n_events > 0)
	{
		CapturedEvent *ev = MemoryContextAllocZero(capture_cxt,
													sizeof(CapturedEvent) * span->n_events);
		int			i;

		for (i = 0; i < span->n_events; i++)
		{
			ev[i].name = copy_str(span->events[i].name);
			ev[i].time = span->events[i].time;
			ev[i].n_attrs = span->events[i].n_attrs;
			ev[i].attrs = copy_attrs(span->events[i].attrs, span->events[i].n_attrs);
		}
		slot->events = ev;
	}

	slot->n_links = span->n_links;
	slot->dropped_links = span->dropped_links;
	if (span->n_links > 0)
	{
		CapturedLink *lk = MemoryContextAllocZero(capture_cxt,
												   sizeof(CapturedLink) * span->n_links);
		int			i;

		for (i = 0; i < span->n_links; i++)
		{
			lk[i].trace_id = span->links[i].trace_id;
			lk[i].span_id = span->links[i].span_id;
			lk[i].trace_flags = span->links[i].trace_flags;
			lk[i].tracestate = copy_str(span->links[i].tracestate);
		}
		slot->links = lk;
	}

	MemoryContextSwitchTo(old);
}

/*
 * GUC: whether the emit hook deep-copies spans into the capture list.
 * Off for the memory-bound stress scenario, so the measurement isolates
 * otel_api's own span-pool memory from this test extension's own
 * (deliberately unbounded, since it's the exact spans a test wants to
 * inspect) capture growth.
 */
static bool conformance_capture_enabled = true;

static void
conformance_emit_hook(const OtelSpan *span)
{
	if (conformance_capture_enabled)
	{
		PG_TRY();
		{
			capture_span(span);
		}
		PG_CATCH();
		{
			FlushErrorState();
		}
		PG_END_TRY();
	}

	if (prev_emit_hook)
		prev_emit_hook(span);
}

/*
 * Always registered; consults otel_api_conformance.sampler on every
 * call.  "none" mirrors the OTel default ParentBased(AlwaysOn) sampler
 * using the remote parent's sampled bit, so leaving the GUC at its
 * default doesn't change behaviour versus no sampler hook at all, while
 * still letting the conformance suite count invocations.
 */
static OtelSamplerDecision
conformance_sampler_hook(const OtelSamplerInput *in)
{
	conformance_sampler_calls++;
	switch (conformance_sampler_mode)
	{
		case CONFORMANCE_SAMPLER_DROP:
			return OTEL_SAMPLE_DROP;
		case CONFORMANCE_SAMPLER_RECORD_ONLY:
			return OTEL_SAMPLE_RECORD_ONLY;
		case CONFORMANCE_SAMPLER_RECORD:
			return OTEL_SAMPLE_RECORD_AND_SAMPLE;
		case CONFORMANCE_SAMPLER_NONE:
		default:
			if (in->parent != NULL && otel_span_context_is_valid(in->parent))
				return otel_span_context_sampled(in->parent)
					? OTEL_SAMPLE_RECORD_AND_SAMPLE : OTEL_SAMPLE_DROP;
			return OTEL_SAMPLE_RECORD_AND_SAMPLE;
	}
}

/* ----------------------------------------------------------------
 * _PG_init
 * ---------------------------------------------------------------- */

void
_PG_init(void)
{
	capture_cxt = AllocSetContextCreate(TopMemoryContext,
										 "otel_api_conformance capture",
										 ALLOCSET_DEFAULT_SIZES);
	owners_cxt = AllocSetContextCreate(TopMemoryContext,
										"otel_api_conformance owners",
										ALLOCSET_SMALL_SIZES);

	DefineCustomEnumVariable("otel_api_conformance.sampler",
							  "Decision returned by otel_api_conformance's sampler hook.",
							  NULL,
							  &conformance_sampler_mode,
							  CONFORMANCE_SAMPLER_NONE,
							  conformance_sampler_options,
							  PGC_USERSET,
							  0,
							  NULL, NULL, NULL);
	DefineCustomBoolVariable("otel_api_conformance.capture_spans",
							  "Whether the emit hook deep-copies spans into the capture list.",
							  "Off for memory-bound stress scenarios, so the measurement isolates "
							  "otel_api's own span-pool memory from this extension's own capture growth.",
							  &conformance_capture_enabled,
							  true,
							  PGC_USERSET,
							  0,
							  NULL, NULL, NULL);
	MarkGUCPrefixReserved("otel_api_conformance");

	memset(&pending_reg, 0, sizeof(pending_reg));
	pending_reg.emit_hook = conformance_emit_hook;
	pending_reg.emit_prev_out = &prev_emit_hook;
	pending_reg.sampler_hook = conformance_sampler_hook;
	pending_reg.sampler_prev_out = &prev_sampler_hook;
	otel_exporter_register_when_ready(&pending_reg);

	/*
	 * Runtime smoke test: compiles and runs otel_producer_stub.h's
	 * no-op entry points once, proving the stub stays in step with
	 * otel_producer.h.  Defined in otel_api_conformance_stub_check.c,
	 * a separate translation unit compiled against the stub header.
	 */
	otel_api_conformance_stub_check();
}

/* ----------------------------------------------------------------
 * JSON rendering of captured spans / counters.
 * ---------------------------------------------------------------- */

static void
append_json_string(StringInfo buf, const char *s)
{
	const char *p;

	if (s == NULL)
	{
		appendStringInfoString(buf, "null");
		return;
	}
	appendStringInfoChar(buf, '"');
	for (p = s; *p; p++)
	{
		unsigned char c = (unsigned char) *p;

		switch (c)
		{
			case '"':
				appendStringInfoString(buf, "\\\"");
				break;
			case '\\':
				appendStringInfoString(buf, "\\\\");
				break;
			case '\n':
				appendStringInfoString(buf, "\\n");
				break;
			case '\r':
				appendStringInfoString(buf, "\\r");
				break;
			case '\t':
				appendStringInfoString(buf, "\\t");
				break;
			default:
				if (c < 0x20)
					appendStringInfo(buf, "\\u%04x", c);
				else
					appendStringInfoChar(buf, (char) c);
		}
	}
	appendStringInfoChar(buf, '"');
}

static void
append_attr_json(StringInfo buf, const CapturedAttr *a)
{
	appendStringInfoChar(buf, '{');
	appendStringInfoString(buf, "\"key\":");
	append_json_string(buf, a->key);
	appendStringInfoString(buf, ",\"type\":");
	switch (a->type)
	{
		case OTEL_ATTR_STRING:
			append_json_string(buf, "string");
			appendStringInfoString(buf, ",\"value\":");
			append_json_string(buf, a->sval);
			break;
		case OTEL_ATTR_INT:
			append_json_string(buf, "int");
			appendStringInfo(buf, ",\"value\":" INT64_FORMAT, a->ival);
			break;
		case OTEL_ATTR_DOUBLE:
			append_json_string(buf, "double");
			appendStringInfo(buf, ",\"value\":%.17g", a->dval);
			break;
		case OTEL_ATTR_BOOL:
			append_json_string(buf, "bool");
			appendStringInfo(buf, ",\"value\":%s", a->bval ? "true" : "false");
			break;
	}
	appendStringInfoChar(buf, '}');
}

static void
append_span_json(StringInfo buf, const CapturedSpan *s)
{
	int			i;
	char		trace_hex[OTEL_TRACE_ID_HEX_LEN + 1];
	char		span_hex[OTEL_SPAN_ID_HEX_LEN + 1];
	char		parent_hex[OTEL_SPAN_ID_HEX_LEN + 1];

	otel_trace_id_to_hex(&s->trace_id, trace_hex);
	otel_span_id_to_hex(&s->span_id, span_hex);
	otel_span_id_to_hex(&s->parent_span_id, parent_hex);

	appendStringInfoChar(buf, '{');
	appendStringInfoString(buf, "\"scope_name\":");
	append_json_string(buf, s->scope_name);
	appendStringInfoString(buf, ",\"scope_version\":");
	append_json_string(buf, s->scope_version);
	appendStringInfoString(buf, ",\"trace_id\":");
	append_json_string(buf, trace_hex);
	appendStringInfoString(buf, ",\"span_id\":");
	append_json_string(buf, span_hex);
	appendStringInfoString(buf, ",\"parent_span_id\":");
	append_json_string(buf, parent_hex);
	appendStringInfo(buf, ",\"trace_flags\":%d", s->trace_flags);
	appendStringInfoString(buf, ",\"tracestate\":");
	append_json_string(buf, s->tracestate);
	appendStringInfoString(buf, ",\"name\":");
	append_json_string(buf, s->name);
	appendStringInfo(buf, ",\"kind\":%d", (int) s->kind);
	appendStringInfo(buf, ",\"status\":%d", (int) s->status);
	appendStringInfo(buf, ",\"sampler_decision\":%d", (int) s->sampler_decision);
	appendStringInfoString(buf, ",\"status_description\":");
	append_json_string(buf, s->status_description);
	appendStringInfo(buf, ",\"start_time\":" INT64_FORMAT, s->start_time);
	appendStringInfo(buf, ",\"end_time\":" INT64_FORMAT, s->end_time);
	appendStringInfo(buf, ",\"dropped_attrs\":%u", s->dropped_attrs);
	appendStringInfo(buf, ",\"dropped_events\":%u", s->dropped_events);
	appendStringInfo(buf, ",\"dropped_links\":%u", s->dropped_links);

	appendStringInfoString(buf, ",\"attrs\":[");
	for (i = 0; i < s->n_attrs; i++)
	{
		if (i > 0)
			appendStringInfoChar(buf, ',');
		append_attr_json(buf, &s->attrs[i]);
	}
	appendStringInfoChar(buf, ']');

	appendStringInfoString(buf, ",\"events\":[");
	for (i = 0; i < s->n_events; i++)
	{
		int			j;

		if (i > 0)
			appendStringInfoChar(buf, ',');
		appendStringInfoChar(buf, '{');
		appendStringInfoString(buf, "\"name\":");
		append_json_string(buf, s->events[i].name);
		appendStringInfo(buf, ",\"time\":" INT64_FORMAT, s->events[i].time);
		appendStringInfoString(buf, ",\"attrs\":[");
		for (j = 0; j < s->events[i].n_attrs; j++)
		{
			if (j > 0)
				appendStringInfoChar(buf, ',');
			append_attr_json(buf, &s->events[i].attrs[j]);
		}
		appendStringInfoChar(buf, ']');
		appendStringInfoChar(buf, '}');
	}
	appendStringInfoChar(buf, ']');

	appendStringInfoString(buf, ",\"links\":[");
	for (i = 0; i < s->n_links; i++)
	{
		char		lt_hex[OTEL_TRACE_ID_HEX_LEN + 1];
		char		ls_hex[OTEL_SPAN_ID_HEX_LEN + 1];

		if (i > 0)
			appendStringInfoChar(buf, ',');
		otel_trace_id_to_hex(&s->links[i].trace_id, lt_hex);
		otel_span_id_to_hex(&s->links[i].span_id, ls_hex);
		appendStringInfoChar(buf, '{');
		appendStringInfoString(buf, "\"trace_id\":");
		append_json_string(buf, lt_hex);
		appendStringInfoString(buf, ",\"span_id\":");
		append_json_string(buf, ls_hex);
		appendStringInfo(buf, ",\"trace_flags\":%d", s->links[i].trace_flags);
		appendStringInfoChar(buf, '}');
	}
	appendStringInfoChar(buf, ']');

	appendStringInfoChar(buf, '}');
}

/* ----------------------------------------------------------------
 * SQL surface: exporter side.
 * ---------------------------------------------------------------- */

PG_FUNCTION_INFO_V1(otel_api_conformance_reset);
Datum
otel_api_conformance_reset(PG_FUNCTION_ARGS)
{
	MemoryContextReset(capture_cxt);
	captured = NULL;
	n_captured = 0;
	captured_cap = 0;
	conformance_sampler_calls = 0;
	conformance_side_effect_calls = 0;
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(otel_api_conformance_spans);
Datum
otel_api_conformance_spans(PG_FUNCTION_ARGS)
{
	FuncCallContext *funcctx;
	int		   *idx;

	if (SRF_IS_FIRSTCALL())
	{
		MemoryContext oldcontext;

		funcctx = SRF_FIRSTCALL_INIT();
		oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);
		idx = (int *) palloc(sizeof(int));
		*idx = 0;
		funcctx->user_fctx = idx;
		MemoryContextSwitchTo(oldcontext);
	}
	funcctx = SRF_PERCALL_SETUP();
	idx = (int *) funcctx->user_fctx;

	if (*idx < n_captured)
	{
		StringInfoData buf;
		Datum		result;

		initStringInfo(&buf);
		append_span_json(&buf, &captured[*idx]);
		result = DirectFunctionCall1(jsonb_in, CStringGetDatum(buf.data));
		(*idx)++;
		SRF_RETURN_NEXT(funcctx, result);
	}
	SRF_RETURN_DONE(funcctx);
}

PG_FUNCTION_INFO_V1(otel_api_conformance_counters);
Datum
otel_api_conformance_counters(PG_FUNCTION_ARGS)
{
	const OtelInternalApi *ia = otel_internal_api();
	OtelApiCounters c;
	StringInfoData buf;

	if (ia == NULL)
		ereport(ERROR, (errmsg("otel_api_conformance: otel_api internal table is not available")));
	ia->get_counters(&c);

	initStringInfo(&buf);
	appendStringInfo(&buf,
					  "{"
					  "\"spans_started\":" UINT64_FORMAT ","
					  "\"spans_unsampled\":" UINT64_FORMAT ","
					  "\"spans_emitted\":" UINT64_FORMAT ","
					  "\"start_no_slot\":" UINT64_FORMAT ","
					  "\"start_no_session_slot\":" UINT64_FORMAT ","
					  "\"start_stack_full\":" UINT64_FORMAT ","
					  "\"start_in_crit_section\":" UINT64_FORMAT ","
					  "\"start_bad_args\":" UINT64_FORMAT ","
					  "\"stale_handle\":" UINT64_FORMAT ","
					  "\"non_lifo_end\":" UINT64_FORMAT ","
					  "\"unwound_error\":" UINT64_FORMAT ","
					  "\"unwound_dropped\":" UINT64_FORMAT ","
					  "\"leaked_at_commit\":" UINT64_FORMAT ","
					  "\"open_at_exit\":" UINT64_FORMAT ","
					  "\"attr_truncated\":" UINT64_FORMAT ","
					  "\"attr_dropped\":" UINT64_FORMAT ","
					  "\"event_dropped\":" UINT64_FORMAT ","
					  "\"link_dropped\":" UINT64_FORMAT ","
					  "\"error_capture_failed\":" UINT64_FORMAT ","
					  "\"emit_hook_errors\":" UINT64_FORMAT ","
					  "\"conformance_sampler_calls\":" INT64_FORMAT ","
					  "\"conformance_side_effect_calls\":" INT64_FORMAT ","
					  "\"conformance_captured\":%d"
					  "}",
					  c.spans_started, c.spans_unsampled, c.spans_emitted,
					  c.start_no_slot, c.start_no_session_slot, c.start_stack_full,
					  c.start_in_crit_section, c.start_bad_args,
					  c.stale_handle, c.non_lifo_end, c.unwound_error, c.unwound_dropped,
					  c.leaked_at_commit, c.open_at_exit,
					  c.attr_truncated, c.attr_dropped, c.event_dropped, c.link_dropped,
					  c.error_capture_failed, c.emit_hook_errors,
					  conformance_sampler_calls, conformance_side_effect_calls,
					  n_captured);
	PG_RETURN_DATUM(DirectFunctionCall1(jsonb_in, CStringGetDatum(buf.data)));
}

PG_FUNCTION_INFO_V1(otel_api_conformance_sampler_calls);
Datum
otel_api_conformance_sampler_calls(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT64(conformance_sampler_calls);
}

/* ----------------------------------------------------------------
 * SQL surface: construction, parentage, ownership, unwind.
 * ---------------------------------------------------------------- */

PG_FUNCTION_INFO_V1(otel_api_conformance_start);
Datum
otel_api_conformance_start(PG_FUNCTION_ARGS)
{
	char	   *name = text_to_cstring(PG_GETARG_TEXT_PP(0));
	char	   *producer = PG_ARGISNULL(1) ? "a" : text_to_cstring(PG_GETARG_TEXT_PP(1));
	char	   *kind_s = PG_ARGISNULL(2) ? "internal" : text_to_cstring(PG_GETARG_TEXT_PP(2));
	char	   *parent_mode_s = PG_ARGISNULL(3) ? "active" : text_to_cstring(PG_GETARG_TEXT_PP(3));
	bytea	   *parent_ctx_bytea = PG_ARGISNULL(4) ? NULL : PG_GETARG_BYTEA_PP(4);
	bool		have_parent_ref = !PG_ARGISNULL(5);
	int64		parent_ref_v = have_parent_ref ? PG_GETARG_INT64(5) : 0;
	char	   *unwind_s = PG_ARGISNULL(6) ? "drop" : text_to_cstring(PG_GETARG_TEXT_PP(6));
	char	   *owner_mode_s = PG_ARGISNULL(7) ? "default" : text_to_cstring(PG_GETARG_TEXT_PP(7));
	bool		have_owner_id = !PG_ARGISNULL(8);
	int64		owner_id = have_owner_id ? PG_GETARG_INT64(8) : 0;
	bool		detached = PG_ARGISNULL(9) ? false : PG_GETARG_BOOL(9);
	bool		scoped = PG_ARGISNULL(10) ? false : PG_GETARG_BOOL(10);

	OtelTracer *tracer = (strcmp(producer, "b") == 0) ? &tracer_b : &tracer_a;
	OtelSpanKind kind = kind_from_text(kind_s);
	OtelSpanParent parent_mode = parent_mode_from_text(parent_mode_s);
	OtelSpanUnwindPolicy unwind = unwind_from_text(unwind_s);
	ResourceOwner owner = owner_from_mode(owner_mode_s, have_owner_id, owner_id);
	OtelSpanContext parent_ctx;
	bool		have_ctx = false;
	OtelSpanRef parent_span = OTEL_SPAN_NONE;
	OtelSpanRef s;

	if (parent_mode == OTEL_PARENT_CONTEXT && parent_ctx_bytea != NULL)
	{
		StringInfoData buf;

		bytea_to_stringinfo(parent_ctx_bytea, &buf);
		have_ctx = otel_span_context_recv(&buf, &parent_ctx);
	}
	if (parent_mode == OTEL_PARENT_SPAN && have_parent_ref)
		parent_span.v = parent_ref_v;

	s = otel_span_start(.tracer = tracer, .name = name, .kind = kind,
						 .parent = parent_mode,
						 .parent_ctx = (parent_mode == OTEL_PARENT_CONTEXT && have_ctx)
						 ? &parent_ctx : NULL,
						 .parent_span = parent_span,
						 .unwind = unwind,
						 .owner = owner,
						 .detached = detached,
						 .scoped = scoped);
	PG_RETURN_INT64(s.v);
}

PG_FUNCTION_INFO_V1(otel_api_conformance_end);
Datum
otel_api_conformance_end(PG_FUNCTION_ARGS)
{
	OtelSpanRef s = {.v = PG_GETARG_INT64(0)};

	otel_span_end(s);
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(otel_api_conformance_recording);
Datum
otel_api_conformance_recording(PG_FUNCTION_ARGS)
{
	OtelSpanRef s = {.v = PG_GETARG_INT64(0)};

	PG_RETURN_BOOL(otel_span_recording(s));
}

PG_FUNCTION_INFO_V1(otel_api_conformance_set_str);
Datum
otel_api_conformance_set_str(PG_FUNCTION_ARGS)
{
	OtelSpanRef s = {.v = PG_GETARG_INT64(0)};
	char	   *key = text_to_cstring(PG_GETARG_TEXT_PP(1));
	char	   *val = text_to_cstring(PG_GETARG_TEXT_PP(2));

	otel_span_set_str(s, key, val);
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(otel_api_conformance_set_int);
Datum
otel_api_conformance_set_int(PG_FUNCTION_ARGS)
{
	OtelSpanRef s = {.v = PG_GETARG_INT64(0)};
	char	   *key = text_to_cstring(PG_GETARG_TEXT_PP(1));
	int64		val = PG_GETARG_INT64(2);

	otel_span_set_int(s, key, val);
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(otel_api_conformance_set_double);
Datum
otel_api_conformance_set_double(PG_FUNCTION_ARGS)
{
	OtelSpanRef s = {.v = PG_GETARG_INT64(0)};
	char	   *key = text_to_cstring(PG_GETARG_TEXT_PP(1));
	float8		val = PG_GETARG_FLOAT8(2);

	otel_span_set_double(s, key, val);
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(otel_api_conformance_set_bool);
Datum
otel_api_conformance_set_bool(PG_FUNCTION_ARGS)
{
	OtelSpanRef s = {.v = PG_GETARG_INT64(0)};
	char	   *key = text_to_cstring(PG_GETARG_TEXT_PP(1));
	bool		val = PG_GETARG_BOOL(2);

	otel_span_set_bool(s, key, val);
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(otel_api_conformance_set_printf);
Datum
otel_api_conformance_set_printf(PG_FUNCTION_ARGS)
{
	OtelSpanRef s = {.v = PG_GETARG_INT64(0)};
	char	   *key = text_to_cstring(PG_GETARG_TEXT_PP(1));
	char	   *val = text_to_cstring(PG_GETARG_TEXT_PP(2));

	otel_span_set_printf(s, key, "%s", val);
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(otel_api_conformance_set_name);
Datum
otel_api_conformance_set_name(PG_FUNCTION_ARGS)
{
	OtelSpanRef s = {.v = PG_GETARG_INT64(0)};
	char	   *name = text_to_cstring(PG_GETARG_TEXT_PP(1));

	otel_span_set_name(s, name);
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(otel_api_conformance_set_status);
Datum
otel_api_conformance_set_status(PG_FUNCTION_ARGS)
{
	OtelSpanRef s;
	char	   *code;
	char	   *desc;

	if (PG_ARGISNULL(0) || PG_ARGISNULL(1))
		ereport(ERROR, (errmsg("otel_api_conformance_set_status: ref and code must not be NULL")));
	s.v = PG_GETARG_INT64(0);
	code = text_to_cstring(PG_GETARG_TEXT_PP(1));
	desc = PG_ARGISNULL(2) ? NULL : text_to_cstring(PG_GETARG_TEXT_PP(2));

	otel_span_set_status(s, status_from_text(code), desc);
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(otel_api_conformance_add_event);
Datum
otel_api_conformance_add_event(PG_FUNCTION_ARGS)
{
	OtelSpanRef s;
	char	   *name;
	OtelAttribute attrs[4];
	int			n = 0;

	if (PG_ARGISNULL(0) || PG_ARGISNULL(1))
		ereport(ERROR, (errmsg("otel_api_conformance_add_event: ref and name must not be NULL")));
	s.v = PG_GETARG_INT64(0);
	name = text_to_cstring(PG_GETARG_TEXT_PP(1));

	if (!PG_ARGISNULL(2))
		attrs[n++] = OTEL_ATTR_STR("conformance.str", text_to_cstring(PG_GETARG_TEXT_PP(2)));
	if (!PG_ARGISNULL(3))
		attrs[n++] = OTEL_ATTR_I64("conformance.int", PG_GETARG_INT64(3));
	if (!PG_ARGISNULL(4))
		attrs[n++] = OTEL_ATTR_F64("conformance.double", PG_GETARG_FLOAT8(4));
	if (!PG_ARGISNULL(5))
		attrs[n++] = OTEL_ATTR_BOOLV("conformance.bool", PG_GETARG_BOOL(5));

	otel_span_add_event(s, name, 0, attrs, n);
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(otel_api_conformance_add_link);
Datum
otel_api_conformance_add_link(PG_FUNCTION_ARGS)
{
	OtelSpanRef s = {.v = PG_GETARG_INT64(0)};
	bytea	   *wire = PG_GETARG_BYTEA_PP(1);
	StringInfoData buf;
	OtelSpanContext ctx;

	bytea_to_stringinfo(wire, &buf);
	if (!otel_span_context_recv(&buf, &ctx))
		ereport(ERROR, (errmsg("otel_api_conformance_add_link: invalid context wire format")));
	otel_span_add_link(s, &ctx);
	PG_RETURN_VOID();
}

/*
 * Exercises OTEL_SPAN_SET_STR_IF_RECORDING(): side_effect_expr() below is
 * only evaluated (and only increments conformance_side_effect_calls) when
 * ref is recording.  otel_api_conformance_side_effect_count() reads the
 * counter back so a TAP test can assert it did or didn't increase.
 */
static const char *
side_effect_expr(void)
{
	conformance_side_effect_calls++;
	return "computed";
}

PG_FUNCTION_INFO_V1(otel_api_conformance_if_recording_scenario);
Datum
otel_api_conformance_if_recording_scenario(PG_FUNCTION_ARGS)
{
	OtelSpanRef s = {.v = PG_GETARG_INT64(0)};

	OTEL_SPAN_SET_STR_IF_RECORDING(s, "conformance.side_effect", side_effect_expr());
	PG_RETURN_INT64(conformance_side_effect_calls);
}

PG_FUNCTION_INFO_V1(otel_api_conformance_side_effect_count);
Datum
otel_api_conformance_side_effect_count(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT64(conformance_side_effect_calls);
}

/* ----------------------------------------------------------------
 * SQL surface: ownership.
 * ---------------------------------------------------------------- */

PG_FUNCTION_INFO_V1(otel_api_conformance_create_owner);
Datum
otel_api_conformance_create_owner(PG_FUNCTION_ARGS)
{
	char	   *name = text_to_cstring(PG_GETARG_TEXT_PP(0));
	MemoryContext old;
	ResourceOwner ro;
	int64		id;

	/*
	 * NULL parent: an independent, top-level owner (per the P2 design's
	 * "a caller-created owner (ResourceOwnerCreate(NULL, ...))"), not a
	 * child of whatever CurrentResourceOwner happens to be right now
	 * (this statement's own portal owner, torn down as soon as this
	 * statement finishes).  A child of that would be release-started
	 * the moment this statement ends, breaking any later use.
	 */
	ro = ResourceOwnerCreate(NULL, name);
	id = next_owner_id++;

	old = MemoryContextSwitchTo(owners_cxt);
	if (n_owners == owners_cap)
	{
		owners_cap = owners_cap == 0 ? 8 : owners_cap * 2;
		owners = owners
			? repalloc(owners, sizeof(ConformanceOwner) * owners_cap)
			: palloc(sizeof(ConformanceOwner) * owners_cap);
	}
	owners[n_owners].id = id;
	owners[n_owners].owner = ro;
	n_owners++;
	MemoryContextSwitchTo(old);

	PG_RETURN_INT64(id);
}

PG_FUNCTION_INFO_V1(otel_api_conformance_release_owner);
Datum
otel_api_conformance_release_owner(PG_FUNCTION_ARGS)
{
	int64		id = PG_GETARG_INT64(0);
	bool		do_commit = PG_ARGISNULL(1) ? true : PG_GETARG_BOOL(1);
	ResourceOwner ro = find_owner(id);
	int			i;

	/*
	 * isTopLevel = true: ro is a top-level (parent-less) owner (see
	 * otel_api_conformance_create_owner), not a child of the current
	 * transaction's owner tree.  ResourceOwnerRelease's LOCKS phase
	 * Asserts owner->parent != NULL whenever isTopLevel is false.
	 */
	ResourceOwnerRelease(ro, RESOURCE_RELEASE_BEFORE_LOCKS, do_commit, true);
	ResourceOwnerRelease(ro, RESOURCE_RELEASE_LOCKS, do_commit, true);
	ResourceOwnerRelease(ro, RESOURCE_RELEASE_AFTER_LOCKS, do_commit, true);
	ResourceOwnerDelete(ro);

	for (i = 0; i < n_owners; i++)
	{
		if (owners[i].id == id)
		{
			memmove(&owners[i], &owners[i + 1],
					sizeof(ConformanceOwner) * (n_owners - i - 1));
			n_owners--;
			break;
		}
	}
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(otel_api_conformance_start_session);
Datum
otel_api_conformance_start_session(PG_FUNCTION_ARGS)
{
	char	   *name = text_to_cstring(PG_GETARG_TEXT_PP(0));
	OtelSpanRef s;

	s = otel_span_start(.tracer = &tracer_a, .name = name,
						 .owner = OTEL_OWNER_SESSION, .detached = true);
	PG_RETURN_INT64(s.v);
}

/*
 * Background worker: emits a session span outside any transaction, then
 * a default-owner (statement-scoped) child span inside a real
 * transaction, and logs progress into otel_api_conformance_log so the
 * launching backend (a different process; it cannot see this worker's
 * captured-span list) can observe that the sequence ran.
 */
void
otel_api_conformance_bgworker_main(Datum main_arg)
{
	OtelSpanRef session_s;
	OtelSpanRef child_s;

	pqsignal(SIGTERM, die);
	BackgroundWorkerUnblockSignals();

	BackgroundWorkerInitializeConnection("postgres", NULL, 0);

	session_s = otel_span_start(.tracer = &tracer_a, .name = "conformance.bgworker.session",
								 .owner = OTEL_OWNER_SESSION, .detached = true);

	StartTransactionCommand();
	SPI_connect();
	/* SPI needs an active snapshot; StartTransactionCommand() alone
	 * doesn't establish one for a bgworker (unlike a normal backend
	 * command, which gets one from the protocol/portal machinery). */
	PushActiveSnapshot(GetTransactionSnapshot());
	child_s = otel_span_start(.tracer = &tracer_a, .name = "conformance.bgworker.txn_child");
	otel_span_set_bool(child_s, "conformance.in_bgworker", true);
	(void) SPI_exec("CREATE TABLE IF NOT EXISTS otel_api_conformance_log (event text)", 0);
	(void) SPI_exec("INSERT INTO otel_api_conformance_log (event) VALUES ('bgworker_ran')", 0);
	otel_span_end(child_s);
	PopActiveSnapshot();
	SPI_finish();
	CommitTransactionCommand();

	otel_span_end(session_s);

	proc_exit(0);
}

PG_FUNCTION_INFO_V1(otel_api_conformance_launch_bgworker);
Datum
otel_api_conformance_launch_bgworker(PG_FUNCTION_ARGS)
{
	BackgroundWorker worker;
	BackgroundWorkerHandle *handle;
	BgwHandleStatus status;
	pid_t		pid;

	memset(&worker, 0, sizeof(worker));
	worker.bgw_flags = BGWORKER_SHMEM_ACCESS | BGWORKER_BACKEND_DATABASE_CONNECTION;
	worker.bgw_start_time = BgWorkerStart_ConsistentState;
	worker.bgw_restart_time = BGW_NEVER_RESTART;
	snprintf(worker.bgw_name, BGW_MAXLEN, "otel_api_conformance worker");
	snprintf(worker.bgw_type, BGW_MAXLEN, "otel_api_conformance worker");
	snprintf(worker.bgw_library_name, MAXPGPATH, "otel_api_conformance");
	snprintf(worker.bgw_function_name, BGW_MAXLEN, "otel_api_conformance_bgworker_main");
	worker.bgw_main_arg = (Datum) 0;
	worker.bgw_notify_pid = MyProcPid;

	if (!RegisterDynamicBackgroundWorker(&worker, &handle))
		ereport(ERROR, (errmsg("otel_api_conformance: could not register background worker")));

	status = WaitForBackgroundWorkerStartup(handle, &pid);
	if (status == BGWH_STOPPED)
		ereport(ERROR, (errmsg("otel_api_conformance: background worker failed to start")));
	else if (status == BGWH_POSTMASTER_DIED)
		ereport(FATAL, (errmsg("otel_api_conformance: postmaster died while starting background worker")));

	status = WaitForBackgroundWorkerShutdown(handle);
	if (status == BGWH_POSTMASTER_DIED)
		ereport(FATAL, (errmsg("otel_api_conformance: postmaster died while waiting for background worker")));

	PG_RETURN_VOID();
}

/* ----------------------------------------------------------------
 * SQL surface: error paths.
 * ---------------------------------------------------------------- */

PG_FUNCTION_INFO_V1(otel_api_conformance_capture_error_scenario);
Datum
otel_api_conformance_capture_error_scenario(PG_FUNCTION_ARGS)
{
	char	   *name = text_to_cstring(PG_GETARG_TEXT_PP(0));
	OtelSpanRef s;

	s = otel_span_start(.tracer = &tracer_a, .name = name, .unwind = OTEL_UNWIND_DROP);
	PG_TRY();
	{
		ereport(ERROR,
				(errcode(ERRCODE_DIVISION_BY_ZERO),
				 errmsg("otel_api_conformance induced error (capture)")));
	}
	PG_CATCH();
	{
		otel_span_capture_error(s);
		FlushErrorState();
	}
	PG_END_TRY();
	otel_span_end(s);
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(otel_api_conformance_record_error_scenario);
Datum
otel_api_conformance_record_error_scenario(PG_FUNCTION_ARGS)
{
	char	   *name = text_to_cstring(PG_GETARG_TEXT_PP(0));
	OtelSpanRef s;
	MemoryContext oldcontext = CurrentMemoryContext;

	s = otel_span_start(.tracer = &tracer_a, .name = name, .unwind = OTEL_UNWIND_DROP);
	PG_TRY();
	{
		ereport(ERROR,
				(errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
				 errmsg("otel_api_conformance induced error (record)")));
	}
	PG_CATCH();
	{
		ErrorData  *edata;

		/*
		 * CopyErrorData() requires CurrentMemoryContext != ErrorContext
		 * (an Assert in cassert builds, per elog.c); PG_CATCH begins
		 * with CurrentMemoryContext left as ErrorContext, so switch back
		 * to the context captured before PG_TRY first.  This is the
		 * ordinary Postgres idiom for catching an error one wants to
		 * inspect; otel_span_capture_error() (used above) does this
		 * switch internally, but a caller using CopyErrorData() directly,
		 * as here, must do it itself.
		 */
		MemoryContextSwitchTo(oldcontext);
		edata = CopyErrorData();
		otel_span_record_error(s, edata);
		FreeErrorData(edata);
		FlushErrorState();
	}
	PG_END_TRY();
	otel_span_end(s);
	PG_RETURN_VOID();
}

/*
 * Starts a span and ereports at the given level.  For WARNING/LOG this
 * returns normally (the span is ended before returning); for ERROR it
 * propagates, so the caller sees the (sub)transaction abort and the
 * span unwinds under `unwind`.  Exercises both explicit unwind and
 * otel_api's automatic capture of ERRORs that reach the top level via
 * emit_log_hook, into the innermost recording span on the stack (this
 * span, since nothing else is open).
 */
PG_FUNCTION_INFO_V1(otel_api_conformance_start_and_ereport);
Datum
otel_api_conformance_start_and_ereport(PG_FUNCTION_ARGS)
{
	char	   *name = text_to_cstring(PG_GETARG_TEXT_PP(0));
	char	   *elevel_s = text_to_cstring(PG_GETARG_TEXT_PP(1));
	char	   *unwind_s = PG_ARGISNULL(2) ? "error" : text_to_cstring(PG_GETARG_TEXT_PP(2));
	OtelSpanUnwindPolicy unwind = unwind_from_text(unwind_s);
	OtelSpanRef s;
	int			elevel;

	if (strcmp(elevel_s, "warning") == 0)
		elevel = WARNING;
	else if (strcmp(elevel_s, "log") == 0)
		elevel = LOG;
	else if (strcmp(elevel_s, "error") == 0)
		elevel = ERROR;
	else
		ereport(ERROR, (errmsg("otel_api_conformance: unknown elevel \"%s\"", elevel_s)));

	s = otel_span_start(.tracer = &tracer_a, .name = name, .unwind = unwind);

	ereport(elevel, (errmsg("otel_api_conformance test ereport at %s", elevel_s)));

	/* Only reached for WARNING/LOG. */
	otel_span_end(s);
	PG_RETURN_VOID();
}

/*
 * Starts a span, hits an injection point between start and end, and
 * ends it.  If the injection_points test module is installed AND core
 * was built --enable-injection-points AND a TAP test has attached
 * "error" behaviour to "otel_api_conformance-mid-span", the
 * INJECTION_POINT() call below raises ERROR and otel_span_end() is
 * never reached: the span unwinds via its resource owner under
 * OTEL_UNWIND_ERROR.  Otherwise this is a complete no-op scenario; the
 * TAP test is responsible for skipping cleanly when injection points
 * aren't available or don't fire.
 */
PG_FUNCTION_INFO_V1(otel_api_conformance_injection_scenario);
Datum
otel_api_conformance_injection_scenario(PG_FUNCTION_ARGS)
{
	char	   *name = text_to_cstring(PG_GETARG_TEXT_PP(0));
	OtelSpanRef s;

	s = otel_span_start(.tracer = &tracer_a, .name = name, .unwind = OTEL_UNWIND_ERROR);
	INJECTION_POINT("otel_api_conformance-mid-span", NULL);
	otel_span_end(s);
	PG_RETURN_VOID();
}

/* ----------------------------------------------------------------
 * SQL surface: limits and stress.
 * ---------------------------------------------------------------- */

PG_FUNCTION_INFO_V1(otel_api_conformance_exhaust_open);
Datum
otel_api_conformance_exhaust_open(PG_FUNCTION_ARGS)
{
	int32		n = PG_GETARG_INT32(0);
	char	   *owner_mode_s = PG_ARGISNULL(1) ? "toptxn" : text_to_cstring(PG_GETARG_TEXT_PP(1));
	ResourceOwner owner = owner_from_mode(owner_mode_s, false, 0);
	int32		i;
	int32		started = 0;

	for (i = 0; i < n; i++)
	{
		OtelSpanRef s = otel_span_start(.tracer = &tracer_a, .name = "conformance.exhaust_open",
										 .owner = owner, .detached = true);

		if (s.v != 0)
			started++;
	}
	PG_RETURN_INT32(started);
}

PG_FUNCTION_INFO_V1(otel_api_conformance_exhaust_session);
Datum
otel_api_conformance_exhaust_session(PG_FUNCTION_ARGS)
{
	int32		n = PG_GETARG_INT32(0);
	int32		i;
	int32		started = 0;

	for (i = 0; i < n; i++)
	{
		OtelSpanRef s = otel_span_start(.tracer = &tracer_a, .name = "conformance.exhaust_session",
										 .owner = OTEL_OWNER_SESSION, .detached = true);

		if (s.v != 0)
			started++;
	}
	PG_RETURN_INT32(started);
}

PG_FUNCTION_INFO_V1(otel_api_conformance_stress);
Datum
otel_api_conformance_stress(PG_FUNCTION_ARGS)
{
	int64		n = PG_GETARG_INT64(0);
	int64		i;

	for (i = 0; i < n; i++)
	{
		OtelSpanRef s = otel_span_start(.tracer = &tracer_a, .name = "conformance.stress");

		otel_span_set_int(s, OTEL_PG_QUERY_ID, i);
		otel_span_end(s);
	}
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(otel_api_conformance_backend_mem_bytes);
Datum
otel_api_conformance_backend_mem_bytes(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT64((int64) MemoryContextMemAllocated(TopMemoryContext, true));
}

/* ----------------------------------------------------------------
 * SQL surface: propagation.
 * ---------------------------------------------------------------- */

PG_FUNCTION_INFO_V1(otel_api_conformance_traceparent_roundtrip);
Datum
otel_api_conformance_traceparent_roundtrip(PG_FUNCTION_ARGS)
{
	char	   *tp = text_to_cstring(PG_GETARG_TEXT_PP(0));
	OtelSpanContext ctx;
	char		out[OTEL_TRACEPARENT_LEN + 1];

	if (!otel_traceparent_parse(tp, &ctx))
		PG_RETURN_NULL();
	otel_traceparent_format(&ctx, out);
	PG_RETURN_TEXT_P(cstring_to_text(out));
}

PG_FUNCTION_INFO_V1(otel_api_conformance_context_send);
Datum
otel_api_conformance_context_send(PG_FUNCTION_ARGS)
{
	char	   *trace_hex = text_to_cstring(PG_GETARG_TEXT_PP(0));
	char	   *span_hex = text_to_cstring(PG_GETARG_TEXT_PP(1));
	int32		flags = PG_GETARG_INT32(2);
	OtelSpanContext ctx;
	StringInfoData buf;

	memset(&ctx, 0, sizeof(ctx));
	if (!otel_trace_id_from_hex(trace_hex, &ctx.trace_id))
		ereport(ERROR, (errmsg("otel_api_conformance_context_send: bad trace_id hex")));
	if (!otel_span_id_from_hex(span_hex, &ctx.span_id))
		ereport(ERROR, (errmsg("otel_api_conformance_context_send: bad span_id hex")));
	ctx.trace_flags = (uint8) flags;
	ctx.tracestate = PG_ARGISNULL(3) ? NULL : text_to_cstring(PG_GETARG_TEXT_PP(3));

	initStringInfo(&buf);
	otel_span_context_send(&buf, &ctx);
	PG_RETURN_BYTEA_P(stringinfo_to_bytea(&buf));
}

PG_FUNCTION_INFO_V1(otel_api_conformance_context_recv);
Datum
otel_api_conformance_context_recv(PG_FUNCTION_ARGS)
{
	bytea	   *wire = PG_GETARG_BYTEA_PP(0);
	StringInfoData buf;
	OtelSpanContext ctx;
	char		trace_hex[OTEL_TRACE_ID_HEX_LEN + 1];
	char		span_hex[OTEL_SPAN_ID_HEX_LEN + 1];
	StringInfoData out;

	bytea_to_stringinfo(wire, &buf);
	if (!otel_span_context_recv(&buf, &ctx))
		PG_RETURN_NULL();

	otel_trace_id_to_hex(&ctx.trace_id, trace_hex);
	otel_span_id_to_hex(&ctx.span_id, span_hex);
	initStringInfo(&out);
	appendStringInfo(&out, "%s;%s;%d;%s", trace_hex, span_hex, ctx.trace_flags,
					  ctx.tracestate ? ctx.tracestate : "");
	PG_RETURN_TEXT_P(cstring_to_text(out.data));
}

PG_FUNCTION_INFO_V1(otel_api_conformance_context_of);
Datum
otel_api_conformance_context_of(PG_FUNCTION_ARGS)
{
	OtelSpanRef s = {.v = PG_GETARG_INT64(0)};
	OtelSpanContext ctx;
	StringInfoData buf;

	if (!otel_span_context_of(s, &ctx))
		PG_RETURN_NULL();
	initStringInfo(&buf);
	otel_span_context_send(&buf, &ctx);
	PG_RETURN_BYTEA_P(stringinfo_to_bytea(&buf));
}

PG_FUNCTION_INFO_V1(otel_api_conformance_current_context);
Datum
otel_api_conformance_current_context(PG_FUNCTION_ARGS)
{
	OtelSpanContext ctx;
	StringInfoData buf;

	if (!otel_span_context_of(OTEL_SPAN_NONE, &ctx))
		PG_RETURN_NULL();
	initStringInfo(&buf);
	otel_span_context_send(&buf, &ctx);
	PG_RETURN_BYTEA_P(stringinfo_to_bytea(&buf));
}

PG_FUNCTION_INFO_V1(otel_api_conformance_start_from_context);
Datum
otel_api_conformance_start_from_context(PG_FUNCTION_ARGS)
{
	bytea	   *wire = PG_GETARG_BYTEA_PP(0);
	char	   *name = text_to_cstring(PG_GETARG_TEXT_PP(1));
	StringInfoData buf;
	OtelSpanContext ctx;
	OtelSpanRef s;

	bytea_to_stringinfo(wire, &buf);
	if (!otel_span_context_recv(&buf, &ctx))
		ereport(ERROR, (errmsg("otel_api_conformance_start_from_context: invalid context wire format")));

	s = otel_span_start(.tracer = &tracer_a, .name = name,
						 .parent = OTEL_PARENT_CONTEXT, .parent_ctx = &ctx);
	PG_RETURN_INT64(s.v);
}

/* ----------------------------------------------------------------
 * SQL surface: parallel workers.
 * ---------------------------------------------------------------- */

PG_FUNCTION_INFO_V1(otel_api_conformance_publish_leader_context);
Datum
otel_api_conformance_publish_leader_context(PG_FUNCTION_ARGS)
{
	OtelSpanRef s = {.v = PG_GETARG_INT64(0)};
	OtelSpanContext ctx;
	const OtelInternalApi *ia = otel_internal_api();

	if (ia == NULL)
		ereport(ERROR, (errmsg("otel_api_conformance: otel_api internal table is not available")));
	if (!otel_span_context_of(s, &ctx))
		ereport(ERROR, (errmsg("otel_api_conformance_publish_leader_context: span has no context")));
	ia->parallel_publish_leader_context(&ctx);
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(otel_api_conformance_clear_leader_context);
Datum
otel_api_conformance_clear_leader_context(PG_FUNCTION_ARGS)
{
	const OtelInternalApi *ia = otel_internal_api();

	if (ia != NULL)
		ia->parallel_clear_leader_context();
	PG_RETURN_VOID();
}

/*
 * Parallel-safe: reports (a) whether it ran in a parallel worker, (b)
 * the context it would have inherited before starting (the published
 * leader context, if run in a worker with an empty active stack), and
 * (c) the trace_id of the span it actually started.  A TAP test
 * compares (b) against the leader's own span identity to prove the
 * worker picked up the published context.
 */
PG_FUNCTION_INFO_V1(otel_api_conformance_parallel_worker_probe);
Datum
otel_api_conformance_parallel_worker_probe(PG_FUNCTION_ARGS)
{
	OtelSpanContext parent_ctx;
	bool		have_parent;
	OtelSpanRef s;
	OtelSpanContext my_ctx;
	char		parent_trace_hex[OTEL_TRACE_ID_HEX_LEN + 1] = {0};
	char		parent_span_hex[OTEL_SPAN_ID_HEX_LEN + 1] = {0};
	char		my_trace_hex[OTEL_TRACE_ID_HEX_LEN + 1] = {0};
	StringInfoData out;

	have_parent = otel_span_context_of(OTEL_SPAN_NONE, &parent_ctx);
	if (have_parent)
	{
		otel_trace_id_to_hex(&parent_ctx.trace_id, parent_trace_hex);
		otel_span_id_to_hex(&parent_ctx.span_id, parent_span_hex);
	}

	s = otel_span_start(.tracer = &tracer_a, .name = "conformance.worker_probe",
						 .parent = OTEL_PARENT_ACTIVE);
	if (otel_span_context_of(s, &my_ctx))
		otel_trace_id_to_hex(&my_ctx.trace_id, my_trace_hex);
	otel_span_end(s);

	initStringInfo(&out);
	appendStringInfo(&out, "in_parallel_worker=%d;parent_trace=%s;parent_span=%s;my_trace=%s",
					  IsParallelWorker() ? 1 : 0,
					  parent_trace_hex, parent_span_hex, my_trace_hex);
	PG_RETURN_TEXT_P(cstring_to_text(out.data));
}

/* ----------------------------------------------------------------
 * SQL surface: misuse (each detected in cassert builds; see the header
 * comments in otel_producer.h and the P2 design's "Ownership, unwind
 * and leaks" section for what each build type does).
 * ---------------------------------------------------------------- */

PG_FUNCTION_INFO_V1(otel_api_conformance_misuse_use_after_end);
Datum
otel_api_conformance_misuse_use_after_end(PG_FUNCTION_ARGS)
{
	OtelSpanRef s = otel_span_start(.tracer = &tracer_a,
									 .name = "conformance.misuse.use_after_end");

	otel_span_end(s);
	/* Stale handle: no-op + counter in production; Assert in cassert. */
	otel_span_set_str(s, "conformance.after", "end");
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(otel_api_conformance_misuse_double_end);
Datum
otel_api_conformance_misuse_double_end(PG_FUNCTION_ARGS)
{
	OtelSpanRef s = otel_span_start(.tracer = &tracer_a,
									 .name = "conformance.misuse.double_end");

	otel_span_end(s);
	otel_span_end(s);			/* stale handle, again */
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(otel_api_conformance_misuse_non_lifo);
Datum
otel_api_conformance_misuse_non_lifo(PG_FUNCTION_ARGS)
{
	OtelSpanRef s1 = otel_span_start(.tracer = &tracer_a, .name = "conformance.misuse.outer");
	OtelSpanRef s2 = otel_span_start(.tracer = &tracer_a, .name = "conformance.misuse.inner");

	/* End s1 while s2 is still on top: non-LIFO. */
	otel_span_end(s1);
	otel_span_end(s2);
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(otel_api_conformance_misuse_critical_section);
Datum
otel_api_conformance_misuse_critical_section(PG_FUNCTION_ARGS)
{
	OtelSpanRef s;

	START_CRIT_SECTION();
	s = otel_span_start(.tracer = &tracer_a, .name = "conformance.misuse.critical");
	END_CRIT_SECTION();

	if (s.v != 0)
		otel_span_end(s);
	PG_RETURN_VOID();
}

/*
 * A span started with .scoped = true, whose C frame (this helper)
 * returns without ending it.  pg_noinline so the frame genuinely
 * exists at the machine level; otherwise an optimizing compiler could
 * inline it away and the later start/end address check would compare
 * against the wrong frame.
 *
 * check_scoped_frames() (otel_producer.c) documents that it "finds
 * leaks, it doesn't prove their absence": it compares the current
 * stack address against the recorded frame, and frames of about the
 * same depth aren't detected.  otel_span_start()'s own recorded
 * scope_frame is the address of its designated-initialiser compound
 * literal, which lives in the immediate caller's frame (misuse_scoped_
 * start_deep below) -- only one level deeper than this file's other
 * misuse helpers.  So that the later checking call (from a much
 * shallower point, seven frames higher) reliably lands deeper than
 * that recorded address on every architecture/build, the scoped span
 * is started from the bottom of a deliberately deep, uninlinable call
 * chain, each frame padded with a stack allocation so the compiler
 * can't collapse them.
 */
#define MISUSE_SCOPED_DEPTH 8

static pg_noinline OtelSpanRef
misuse_scoped_start_deep(void)
{
	return otel_span_start(.tracer = &tracer_a, .name = "conformance.misuse.scoped",
							.scoped = true);
}

static volatile char misuse_scoped_nest_sink;

static pg_noinline OtelSpanRef
misuse_scoped_nest(int depth)
{
	volatile char pad[256];

	pad[0] = (char) depth;
	misuse_scoped_nest_sink = pad[0];
	if (depth <= 0)
		return misuse_scoped_start_deep();
	return misuse_scoped_nest(depth - 1);
}

PG_FUNCTION_INFO_V1(otel_api_conformance_misuse_scoped_leak);
Datum
otel_api_conformance_misuse_scoped_leak(PG_FUNCTION_ARGS)
{
	OtelSpanRef s = misuse_scoped_nest(MISUSE_SCOPED_DEPTH);

	/*
	 * Every frame between here and misuse_scoped_start_deep() has
	 * already returned.  Ending (or starting another span) from here,
	 * at a much shallower stack depth, should trip the cassert-only
	 * Assert that checks whether the .scoped frame is still live.
	 */
	otel_span_end(s);
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(otel_api_conformance_misuse_foreign_handle);
Datum
otel_api_conformance_misuse_foreign_handle(PG_FUNCTION_ARGS)
{
	/* A handle value never returned by otel_span_start: not stale, but
	 * foreign/bogus.  Exercises the same generation check. */
	OtelSpanRef bogus = {.v = 123456789};

	otel_span_set_str(bogus, "conformance.bogus", "x");
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(otel_api_conformance_misuse_open_at_commit);
Datum
otel_api_conformance_misuse_open_at_commit(PG_FUNCTION_ARGS)
{
	/*
	 * Intentionally leaked: the caller commits without ending this
	 * span.  otel_api's ResourceOwnerDesc callback for
	 * TopTransactionResourceOwner fires at commit with the span still
	 * open: core prints "resource was not closed", otel_api counts the
	 * leak (leaked_at_commit) and drops the span without emitting it.
	 */
	OtelSpanRef s = otel_span_start(.tracer = &tracer_a,
									 .name = "conformance.misuse.open_at_commit",
									 .owner = TopTransactionResourceOwner,
									 .detached = true);

	(void) s;
	PG_RETURN_VOID();
}
