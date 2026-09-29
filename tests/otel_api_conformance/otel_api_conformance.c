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
#include "common/pg_prng.h"
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
					  "\"spans_discarded\":" UINT64_FORMAT ","
					  "\"start_no_slot\":" UINT64_FORMAT ","
					  "\"start_no_session_slot\":" UINT64_FORMAT ","
					  "\"start_stack_full\":" UINT64_FORMAT ","
					  "\"in_crit_section\":" UINT64_FORMAT ","
					  "\"start_bad_args\":" UINT64_FORMAT ","
					  "\"stale_handle\":" UINT64_FORMAT ","
					  "\"non_lifo_end\":" UINT64_FORMAT ","
					  "\"unwound\":" UINT64_FORMAT ","
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
					  c.spans_started, c.spans_unsampled, c.spans_emitted, c.spans_discarded,
					  c.start_no_slot, c.start_no_session_slot, c.start_stack_full,
					  c.in_crit_section, c.start_bad_args,
					  c.stale_handle, c.non_lifo_end, c.unwound,
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
	char	   *owner_mode_s = PG_ARGISNULL(6) ? "default" : text_to_cstring(PG_GETARG_TEXT_PP(6));
	bool		have_owner_id = !PG_ARGISNULL(7);
	int64		owner_id = have_owner_id ? PG_GETARG_INT64(7) : 0;
	bool		detached = PG_ARGISNULL(8) ? false : PG_GETARG_BOOL(8);
	bool		scoped = PG_ARGISNULL(9) ? false : PG_GETARG_BOOL(9);

	OtelTracer *tracer = (strcmp(producer, "b") == 0) ? &tracer_b : &tracer_a;
	OtelSpanKind kind = kind_from_text(kind_s);
	OtelSpanParent parent_mode = parent_mode_from_text(parent_mode_s);
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

	s = otel_span_start(.tracer = &tracer_a, .name = name);
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

	s = otel_span_start(.tracer = &tracer_a, .name = name);
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
 * span is exported with ERROR status by resource-owner release.
 * Exercises otel_api's automatic capture of ERRORs that reach the top
 * level via emit_log_hook, into the innermost recording span on the
 * stack (this span, since nothing else is open).
 */
PG_FUNCTION_INFO_V1(otel_api_conformance_start_and_ereport);
Datum
otel_api_conformance_start_and_ereport(PG_FUNCTION_ARGS)
{
	char	   *name = text_to_cstring(PG_GETARG_TEXT_PP(0));
	char	   *elevel_s = text_to_cstring(PG_GETARG_TEXT_PP(1));
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

	s = otel_span_start(.tracer = &tracer_a, .name = name);

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
 * never reached: the span is exported with ERROR status by its
 * resource owner's release.  Otherwise this is a complete no-op
 * scenario; the TAP test is responsible for skipping cleanly when
 * injection points aren't available or don't fire.
 */
PG_FUNCTION_INFO_V1(otel_api_conformance_injection_scenario);
Datum
otel_api_conformance_injection_scenario(PG_FUNCTION_ARGS)
{
	char	   *name = text_to_cstring(PG_GETARG_TEXT_PP(0));
	OtelSpanRef s;

	s = otel_span_start(.tracer = &tracer_a, .name = name);
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

/*
 * Start a recording span, run one producer call on it inside a critical
 * section, then end it.  Every call there must be refused: cassert builds
 * Assert, other builds leave the span unchanged.
 */
PG_FUNCTION_INFO_V1(otel_api_conformance_misuse_crit_section_op);
Datum
otel_api_conformance_misuse_crit_section_op(PG_FUNCTION_ARGS)
{
	const char *op = text_to_cstring(PG_GETARG_TEXT_PP(0));
	OtelSpanRef s = otel_span_start(.tracer = &tracer_a,
									.name = "conformance.misuse.crit_op");
	OtelSpanRef cur = OTEL_SPAN_NONE;
	OtelSpanContext ctx;
	OtelAttribute attr = OTEL_ATTR_STR("conformance.crit", "set");
	ErrorData	edata = {.elevel = ERROR,
		.sqlerrcode = ERRCODE_DIVISION_BY_ZERO,
	.message = "conformance crit section"};
	bool		got_ctx = false;
	bool		known = true;

	if (s.v <= 0)
		elog(ERROR, "could not start a recording span");
	memset(&ctx, 0, sizeof(ctx));
	otel_span_context_of(s, &ctx);

	START_CRIT_SECTION();
	if (strcmp(op, "end") == 0)
		otel_span_end(s);
	else if (strcmp(op, "discard") == 0)
		otel_span_discard(s);
	else if (strcmp(op, "set_str") == 0)
		otel_span_set_str(s, "conformance.crit", "set");
	else if (strcmp(op, "set_int") == 0)
		otel_span_set_int(s, "conformance.crit", 1);
	else if (strcmp(op, "set_double") == 0)
		otel_span_set_double(s, "conformance.crit", 1.0);
	else if (strcmp(op, "set_bool") == 0)
		otel_span_set_bool(s, "conformance.crit", true);
	else if (strcmp(op, "set_printf") == 0)
		otel_span_set_printf(s, "conformance.crit", "%d", 1);
	else if (strcmp(op, "set_name") == 0)
		otel_span_set_name(s, "conformance.misuse.crit_op.renamed");
	else if (strcmp(op, "set_status") == 0)
		otel_span_set_status(s, OTEL_STATUS_ERROR, "conformance crit section");
	else if (strcmp(op, "add_event") == 0)
		otel_span_add_event(s, "conformance.crit", 0, &attr, 1);
	else if (strcmp(op, "add_link") == 0)
		otel_span_add_link(s, &ctx);
	else if (strcmp(op, "record_error") == 0)
		otel_span_record_error(s, &edata);
	else if (strcmp(op, "capture_error") == 0)
		otel_span_capture_error(s);
	else if (strcmp(op, "current") == 0)
		cur = otel_span_current();
	else if (strcmp(op, "context_of") == 0)
		got_ctx = otel_span_context_of(s, &ctx);
	else if (strcmp(op, "resource_add") == 0)
		otel_resource_add("conformance.crit", "set");
	else
		known = false;
	END_CRIT_SECTION();

	if (!known)
		elog(ERROR, "unknown op \"%s\"", op);
	if (cur.v != 0)
		elog(ERROR, "otel_span_current() returned a span inside a critical section");
	if (got_ctx)
		elog(ERROR, "otel_span_context_of() succeeded inside a critical section");

	/* Still open and usable after the critical section. */
	otel_span_set_str(s, "conformance.after_crit", "set");
	otel_span_end(s);
	PG_RETURN_VOID();
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

/* ----------------------------------------------------------------
 * SQL surface: plpgsql recursion (t/011) and interleaving (t/012).
 *
 * These scenarios need a span open *across* a recursive call, so the
 * work happens in one C function per "level" rather than several SQL
 * statements (a span with the default owner is released at the end of
 * its own statement -- see the file header and otel_producer.h).
 * ---------------------------------------------------------------- */

PG_FUNCTION_INFO_V1(otel_api_conformance_span_current);
Datum
otel_api_conformance_span_current(PG_FUNCTION_ARGS)
{
	OtelSpanRef s = otel_span_current();

	PG_RETURN_INT64(s.v);
}

PG_FUNCTION_INFO_V1(otel_api_conformance_discard);
Datum
otel_api_conformance_discard(PG_FUNCTION_ARGS)
{
	OtelSpanRef s = {.v = PG_GETARG_INT64(0)};

	otel_span_discard(s);
	PG_RETURN_VOID();
}

/*
 * Starts a span, runs sql via SPI (which may recurse back into a
 * plpgsql wrapper that calls this function again), and ends the span.
 * If sql raises an ERROR, SPI_execute() propagates it straight through
 * this function -- SPI_finish() and otel_span_end() are never reached,
 * so the span is exported with ERROR status by whatever resource owner
 * it belongs to (the default: CurrentResourceOwner at the moment
 * otel_span_start() ran).  That is exactly the plpgsql-recursion
 * pattern this scenario needs: no explicit cleanup code here means the
 * owner/abort machinery is what gets exercised.
 */
PG_FUNCTION_INFO_V1(otel_api_conformance_with_span);
Datum
otel_api_conformance_with_span(PG_FUNCTION_ARGS)
{
	char	   *name = text_to_cstring(PG_GETARG_TEXT_PP(0));
	char	   *sql = text_to_cstring(PG_GETARG_TEXT_PP(1));
	OtelSpanRef s;
	int			ret;

	s = otel_span_start(.tracer = &tracer_a, .name = name);

	SPI_connect();
	ret = SPI_execute(sql, false, 0);
	SPI_finish();

	otel_span_end(s);

	if (ret < 0)
		ereport(ERROR,
				(errmsg("otel_api_conformance_with_span: SPI_execute failed for \"%s\": %d",
						sql, ret)));

	PG_RETURN_INT64(s.v);
}

/*
 * Like with_span, but runs sql in an internal subtransaction and catches
 * any error from it, the way C code with PG_TRY and a subtransaction does.
 * After the catch, a child span named after_name is started and ended.
 * Everything happens inside this one call, so the spans stay LIFO with
 * the C call stack even when other producers wrap each SQL statement in
 * spans of their own.
 */
PG_FUNCTION_INFO_V1(otel_api_conformance_with_span_catch);
Datum
otel_api_conformance_with_span_catch(PG_FUNCTION_ARGS)
{
	char	   *name = text_to_cstring(PG_GETARG_TEXT_PP(0));
	char	   *sql = text_to_cstring(PG_GETARG_TEXT_PP(1));
	char	   *after_name = PG_ARGISNULL(2) ? NULL : text_to_cstring(PG_GETARG_TEXT_PP(2));
	MemoryContext oldcxt = CurrentMemoryContext;
	ResourceOwner oldowner = CurrentResourceOwner;
	OtelSpanRef s;
	bool		caught = false;

	s = otel_span_start(.tracer = &tracer_a, .name = name);

	BeginInternalSubTransaction(NULL);
	MemoryContextSwitchTo(oldcxt);
	PG_TRY();
	{
		SPI_connect();
		(void) SPI_execute(sql, false, 0);
		SPI_finish();
		ReleaseCurrentSubTransaction();
		MemoryContextSwitchTo(oldcxt);
		CurrentResourceOwner = oldowner;
	}
	PG_CATCH();
	{
		MemoryContextSwitchTo(oldcxt);
		FlushErrorState();
		RollbackAndReleaseCurrentSubTransaction();
		MemoryContextSwitchTo(oldcxt);
		CurrentResourceOwner = oldowner;
		caught = true;
	}
	PG_END_TRY();

	if (after_name != NULL)
	{
		OtelSpanRef a = otel_span_start(.tracer = &tracer_a, .name = after_name);

		otel_span_set_bool(a, "conformance.caught", caught);
		otel_span_end(a);
	}
	otel_span_end(s);

	PG_RETURN_INT64(s.v);
}

/* ----------------------------------------------------------------
 * Interleaving scenarios (t/012).
 * ---------------------------------------------------------------- */

/*
 * 100/300 detached spans chained by OTEL_PARENT_SPAN, ended in the
 * given order.  Detached spans aren't subject to the LIFO stack rule
 * at all, so every order below is legal; the point is to check that
 * parent_span_id is recorded correctly regardless of end order.
 */
PG_FUNCTION_INFO_V1(otel_api_conformance_detached_chain);
Datum
otel_api_conformance_detached_chain(PG_FUNCTION_ARGS)
{
	int32		n = PG_GETARG_INT32(0);
	char	   *order_mode = text_to_cstring(PG_GETARG_TEXT_PP(1));
	int64		seed = PG_ARGISNULL(2) ? 42 : PG_GETARG_INT64(2);
	OtelSpanRef *refs;
	int		   *order;
	pg_prng_state rnd;
	OtelSpanRef prev = OTEL_SPAN_NONE;
	int			i;

	if (n <= 0)
		PG_RETURN_VOID();

	refs = palloc(sizeof(OtelSpanRef) * n);
	order = palloc(sizeof(int) * n);

	for (i = 0; i < n; i++)
	{
		char		namebuf[NAMEDATALEN];

		snprintf(namebuf, sizeof(namebuf), "conformance.chain.%d", i);
		refs[i] = otel_span_start(.tracer = &tracer_a, .name = namebuf,
								   .parent = (i == 0) ? OTEL_PARENT_ACTIVE : OTEL_PARENT_SPAN,
								   .parent_span = prev,
								   .detached = true);
		prev = refs[i];
	}

	for (i = 0; i < n; i++)
		order[i] = i;

	if (strcmp(order_mode, "reverse") == 0)
	{
		for (i = 0; i < n; i++)
			order[i] = n - 1 - i;
	}
	else if (strcmp(order_mode, "random") == 0)
	{
		pg_prng_seed(&rnd, (uint64) seed);
		for (i = n - 1; i > 0; i--)
		{
			int			j = (int) pg_prng_uint64_range(&rnd, 0, (uint64) i);
			int			tmp = order[i];

			order[i] = order[j];
			order[j] = tmp;
		}
	}
	else if (strcmp(order_mode, "forward") != 0)
		ereport(ERROR,
				(errmsg("otel_api_conformance_detached_chain: unknown order_mode \"%s\"",
						order_mode)));

	for (i = 0; i < n; i++)
		otel_span_end(refs[order[i]]);

	pfree(refs);
	pfree(order);
	PG_RETURN_VOID();
}

/*
 * A stack span (parent) ends before its detached child; the child ends
 * later and must still carry the parent's span_id.  Also: a further
 * span started from the *saved context* of that now-ended parent (the
 * context is plain data, captured before the parent ended; only the
 * stale OtelSpanRef handle itself would be misuse).
 */
PG_FUNCTION_INFO_V1(otel_api_conformance_parent_ends_first);
Datum
otel_api_conformance_parent_ends_first(PG_FUNCTION_ARGS)
{
	OtelSpanRef parent = otel_span_start(.tracer = &tracer_a, .name = "conformance.b.parent");
	OtelSpanRef child = otel_span_start(.tracer = &tracer_a, .name = "conformance.b.child",
										 .parent = OTEL_PARENT_SPAN, .parent_span = parent,
										 .detached = true);
	OtelSpanContext parent_ctx;
	bool		have_ctx = otel_span_context_of(parent, &parent_ctx);

	otel_span_end(parent);		/* parent ends first */
	otel_span_end(child);		/* detached child ends later; unaffected */

	if (have_ctx)
	{
		OtelSpanRef grandchild = otel_span_start(.tracer = &tracer_a,
												  .name = "conformance.b.from_ended_ctx",
												  .parent = OTEL_PARENT_CONTEXT,
												  .parent_ctx = &parent_ctx);

		otel_span_end(grandchild);
	}
	PG_RETURN_VOID();
}

/*
 * Stack span A; detached D child of A; stack span B child of A; end A
 * while B is still open (non-LIFO).  In a cassert build this trips the
 * same Assert as otel_api_conformance_misuse_non_lifo() (see
 * t/008_misuse.pl) and the backend crashes before reaching the rest of
 * this function; in other builds B is force-unwound and exported with
 * ERROR status, A is emitted normally, and D (detached, never touched
 * by the stack-unwind) ends fine afterwards.
 */
PG_FUNCTION_INFO_V1(otel_api_conformance_mixed_non_lifo_detached);
Datum
otel_api_conformance_mixed_non_lifo_detached(PG_FUNCTION_ARGS)
{
	OtelSpanRef a = otel_span_start(.tracer = &tracer_a, .name = "conformance.c.A");
	OtelSpanRef d = otel_span_start(.tracer = &tracer_a, .name = "conformance.c.D",
									 .parent = OTEL_PARENT_SPAN, .parent_span = a,
									 .detached = true);
	OtelSpanRef b = otel_span_start(.tracer = &tracer_a, .name = "conformance.c.B");

	otel_span_end(a);			/* non-LIFO: B is still open above A */
	otel_span_end(b);			/* stale handle: B was already force-unwound */
	otel_span_end(d);			/* detached: unaffected, ends normally */
	PG_RETURN_VOID();
}

/*
 * Two producer scopes interleaving: A1 (stack), B1 (detached child of
 * A1), A2 (stack child of A1, via the active stack), B2 (stack child
 * of A2 structurally, but its *parent* is explicitly B1 -- a detached
 * span of the other producer -- via OTEL_PARENT_SPAN).  Ended in LIFO
 * stack order (B2, A2, A1), with B1 ended last to show detached order
 * doesn't matter.
 */
PG_FUNCTION_INFO_V1(otel_api_conformance_two_producer_interleave);
Datum
otel_api_conformance_two_producer_interleave(PG_FUNCTION_ARGS)
{
	OtelSpanRef a1 = otel_span_start(.tracer = &tracer_a, .name = "conformance.d.A1");
	OtelSpanRef b1 = otel_span_start(.tracer = &tracer_b, .name = "conformance.d.B1",
									  .parent = OTEL_PARENT_SPAN, .parent_span = a1,
									  .detached = true);
	OtelSpanRef a2 = otel_span_start(.tracer = &tracer_a, .name = "conformance.d.A2",
									  .parent = OTEL_PARENT_ACTIVE);
	OtelSpanRef b2 = otel_span_start(.tracer = &tracer_b, .name = "conformance.d.B2",
									  .parent = OTEL_PARENT_SPAN, .parent_span = b1);

	otel_span_end(b2);
	otel_span_end(a2);
	otel_span_end(a1);
	otel_span_end(b1);
	PG_RETURN_VOID();
}

/*
 * One parent with n_children detached children open at once (the
 * caller picks n_children near otel_api.max_open_spans), ended in a
 * seeded random order; then n_over_limit further detached spans, to
 * push past otel_api.max_open_spans and check the refusals are counted
 * (start_no_slot) without disturbing anything already emitted.
 * Returns {"refused_children": N, "refused_extra": M}.
 */
PG_FUNCTION_INFO_V1(otel_api_conformance_wide_fanout);
Datum
otel_api_conformance_wide_fanout(PG_FUNCTION_ARGS)
{
	int32		n_children = PG_GETARG_INT32(0);
	int64		seed = PG_ARGISNULL(1) ? 7 : PG_GETARG_INT64(1);
	int32		n_over_limit = PG_ARGISNULL(2) ? 0 : PG_GETARG_INT32(2);
	OtelSpanRef parent;
	OtelSpanRef *children;
	int		   *order;
	pg_prng_state rnd;
	int			i;
	int32		refused_children = 0;
	int32		refused_extra = 0;
	StringInfoData buf;

	parent = otel_span_start(.tracer = &tracer_a, .name = "conformance.e.parent");

	children = palloc(sizeof(OtelSpanRef) * Max(n_children, 1));
	order = palloc(sizeof(int) * Max(n_children, 1));
	for (i = 0; i < n_children; i++)
	{
		char		namebuf[NAMEDATALEN];

		snprintf(namebuf, sizeof(namebuf), "conformance.e.child.%d", i);
		children[i] = otel_span_start(.tracer = &tracer_a, .name = namebuf,
									   .parent = OTEL_PARENT_SPAN, .parent_span = parent,
									   .detached = true);
		if (children[i].v == 0)
			refused_children++;
		order[i] = i;
	}

	/*
	 * While the parent + all n_children children are still open (near
	 * otel_api.max_open_spans), try n_over_limit more, keeping every
	 * successful one open too: this is the combined budget that
	 * should be exhausted, not a fresh budget re-tested one span at a
	 * time (which would never accumulate against the cap).
	 */
	{
		OtelSpanRef *extras = palloc(sizeof(OtelSpanRef) * Max(n_over_limit, 1));
		int			n_extras = 0;

		for (i = 0; i < n_over_limit; i++)
		{
			OtelSpanRef extra = otel_span_start(.tracer = &tracer_a,
												 .name = "conformance.e.overflow",
												 .detached = true);

			if (extra.v == 0)
				refused_extra++;
			else
				extras[n_extras++] = extra;
		}
		for (i = 0; i < n_extras; i++)
			otel_span_end(extras[i]);
		pfree(extras);
	}

	pg_prng_seed(&rnd, (uint64) seed);
	for (i = n_children - 1; i > 0; i--)
	{
		int			j = (int) pg_prng_uint64_range(&rnd, 0, (uint64) i);
		int			tmp = order[i];

		order[i] = order[j];
		order[j] = tmp;
	}
	for (i = 0; i < n_children; i++)
		otel_span_end(children[order[i]]);

	otel_span_end(parent);

	initStringInfo(&buf);
	appendStringInfo(&buf, "{\"refused_children\":%d,\"refused_extra\":%d}",
					  refused_children, refused_extra);
	PG_RETURN_DATUM(DirectFunctionCall1(jsonb_in, CStringGetDatum(buf.data)));
}

/* ----------------------------------------------------------------
 * Randomised stress: a seeded walk over start/set/event/end/discard,
 * tracking each recording span's own span_id and the span_id its
 * creator *intended* as its parent, then cross-checking every emitted
 * span's real parent_span_id against that intent.
 *
 * mode 'legal': every operation stays inside the rules (stack spans
 * end LIFO via a maintained stack mirror; only genuinely still-live
 * handles are ever named as a parent, ended, or discarded).  Runs on
 * every build, and the parent-chain and accounting invariants below
 * are asserted in full.
 *
 * mode 'illegal': the same generator, except "end" and "as a parent"
 * targets are drawn from *every* op this run has ever created,
 * including ones already ended or discarded -- reproducing stale-
 * handle reuse, non-LIFO ends and dead handles used as
 * OTEL_PARENT_SPAN without any special-casing.  This is a coarser
 * check (no crash, backend clean afterwards, misuse counters moved),
 * not a full parent-chain reconciliation: once an illegal op runs,
 * this generator's own bookkeeping of "the" active stack no longer
 * corresponds to otel_api's, by design.  Only run when
 * debug_assertions is off (otel_api Asserts on exactly these cases).
 * ---------------------------------------------------------------- */

typedef struct StressOp
{
	OtelSpanRef ref;
	bool		ended;
	bool		discarded;
	bool		detached;
	bool		recording;
	OtelSpanId	span_id;
	OtelSpanId	expected_parent;
	bool		expected_parent_is_root;
} StressOp;

static void
stress_live_remove(int *live, int *n_live, int idx)
{
	int			i;

	for (i = 0; i < *n_live; i++)
	{
		if (live[i] == idx)
		{
			live[i] = live[--(*n_live)];
			return;
		}
	}
}

/*
 * Remove idx from the stack mirror wherever it is, preserving the
 * relative order of the rest (unlike stress_live_remove's swap-with-
 * last): otel_span_discard() legitimately removes a span from any
 * position in the middle of the stack, leaving the ones above it in
 * place -- exactly what this mirrors.
 */
static void
stack_mirror_remove(int *stack_mirror, int *stack_depth, int idx)
{
	int			i;

	for (i = 0; i < *stack_depth; i++)
	{
		if (stack_mirror[i] == idx)
		{
			memmove(&stack_mirror[i], &stack_mirror[i + 1],
					(*stack_depth - i - 1) * sizeof(int));
			(*stack_depth)--;
			return;
		}
	}
}

PG_FUNCTION_INFO_V1(otel_api_conformance_stress_ops);
Datum
otel_api_conformance_stress_ops(PG_FUNCTION_ARGS)
{
	int64		seed = PG_GETARG_INT64(0);
	int32		n_ops = PG_GETARG_INT32(1);
	char	   *mode = text_to_cstring(PG_GETARG_TEXT_PP(2));
	bool		legal = (strcmp(mode, "legal") == 0);
	pg_prng_state rnd;
	StressOp   *ops;
	int			n_alloc = 0;
	int		   *live;			/* legal mode: genuinely-live op indices */
	int			n_live = 0;
	int		   *stack_mirror;	/* legal mode: non-detached live, in stack order */
	int			stack_depth = 0;
	int		   *detached_live_scratch;	/* legal mode: reused scratch for "end" target selection */
	int64		n_started = 0,
				n_ended = 0,
				n_discarded = 0,
				n_set_attr = 0,
				n_events = 0;
	int32		i;
	int32		parent_checked = 0;
	int32		parent_mismatches = 0;
	OtelApiCounters c_before,
				c_after;
	const OtelInternalApi *ia = otel_internal_api();
	StringInfoData buf;

	if (!legal && strcmp(mode, "illegal") != 0)
		ereport(ERROR, (errmsg("otel_api_conformance_stress_ops: unknown mode \"%s\"", mode)));
	if (ia == NULL)
		ereport(ERROR, (errmsg("otel_api_conformance: otel_api internal table is not available")));
	if (n_ops <= 0)
		ereport(ERROR, (errmsg("otel_api_conformance_stress_ops: n_ops must be positive")));

	pg_prng_seed(&rnd, (uint64) seed);
	ops = palloc0(sizeof(StressOp) * n_ops);
	live = palloc(sizeof(int) * n_ops);
	stack_mirror = palloc(sizeof(int) * n_ops);
	detached_live_scratch = palloc(sizeof(int) * n_ops);

	ia->get_counters(&c_before);

	for (i = 0; i < n_ops; i++)
	{
		uint32		choice = pg_prng_uint32(&rnd) % 100;
		/* Target pool for "end"/"discard"/"be a parent": in legal mode,
		 * only genuinely-live ops; in illegal mode, every op ever made
		 * (including dead ones), on purpose. */
		int			pool_n = legal ? n_live : n_alloc;

		if (choice < 55 || pool_n == 0)
		{
			/* start */
			int			idx = n_alloc++;
			StressOp   *op = &ops[idx];
			uint32		pmode = pg_prng_uint32(&rnd) % 4;
			bool		detached = pg_prng_bool(&rnd);
			char		namebuf[NAMEDATALEN];
			OtelTracer *tracer = pg_prng_bool(&rnd) ? &tracer_a : &tracer_b;

			snprintf(namebuf, sizeof(namebuf), "conformance.stress.%d", idx);
			op->expected_parent_is_root = true;
			memset(&op->expected_parent, 0, sizeof(op->expected_parent));

			if (pmode == 0 || pool_n == 0)
			{
				/* OTEL_PARENT_ACTIVE.  In legal mode the expected
				 * parent is the top of our stack mirror (which we keep
				 * in exact sync with otel_api's real one, since every
				 * end/discard in legal mode is itself LIFO-legal).  In
				 * illegal mode we don't track OTEL_PARENT_ACTIVE's
				 * expected parent at all (our bookkeeping can't stay
				 * in sync once a non-LIFO end has happened elsewhere),
				 * so such spans are excluded from the parent check
				 * below. */
				if (legal && stack_depth > 0)
				{
					StressOp   *top = &ops[stack_mirror[stack_depth - 1]];

					if (top->recording)
					{
						op->expected_parent = top->span_id;
						op->expected_parent_is_root = false;
					}
				}
				else if (!legal)
					op->expected_parent_is_root = false;	/* unknown; skip check */
				op->ref = otel_span_start(.tracer = tracer, .name = namebuf,
										   .parent = OTEL_PARENT_ACTIVE,
										   .detached = detached);
			}
			else if (pmode == 1)
			{
				int			pick;
				StressOp   *p;

				pick = legal ? live[pg_prng_uint64_range(&rnd, 0, n_live - 1)]
					: (int) pg_prng_uint64_range(&rnd, 0, n_alloc - 1);
				p = &ops[pick];
				if (p->recording)
				{
					op->expected_parent = p->span_id;
					op->expected_parent_is_root = false;
				}
				else if (!legal)
					op->expected_parent_is_root = false;	/* dead/unsampled; skip check */
				op->ref = otel_span_start(.tracer = tracer, .name = namebuf,
										   .parent = OTEL_PARENT_SPAN,
										   .parent_span = p->ref,
										   .detached = detached);
			}
			else if (pmode == 2)
			{
				int			pick = legal ? live[pg_prng_uint64_range(&rnd, 0, n_live - 1)]
					: (int) pg_prng_uint64_range(&rnd, 0, n_alloc - 1);
				OtelSpanContext ctx;
				bool		have_ctx = otel_span_context_of(ops[pick].ref, &ctx);

				if (have_ctx)
				{
					op->expected_parent = ctx.span_id;
					op->expected_parent_is_root = !otel_span_id_is_valid(&ctx.span_id);
				}
				else if (!legal)
					op->expected_parent_is_root = false;	/* skip check */
				op->ref = otel_span_start(.tracer = tracer, .name = namebuf,
										   .parent = OTEL_PARENT_CONTEXT,
										   .parent_ctx = have_ctx ? &ctx : NULL,
										   .detached = detached);
			}
			else
			{
				/* OTEL_PARENT_ROOT: always a new trace. */
				op->ref = otel_span_start(.tracer = tracer, .name = namebuf,
										   .parent = OTEL_PARENT_ROOT,
										   .detached = detached);
			}

			op->detached = detached;
			op->recording = otel_span_recording(op->ref);
			if (op->recording)
			{
				OtelSpanContext my_ctx;

				if (otel_span_context_of(op->ref, &my_ctx))
					op->span_id = my_ctx.span_id;
				n_started++;
			}
			if (op->ref.v != 0)
			{
				live[n_live++] = idx;
				if (!detached)
					stack_mirror[stack_depth++] = idx;
			}
		}
		else if (choice < 75)
		{
			int			pick = legal ? live[pg_prng_uint64_range(&rnd, 0, n_live - 1)]
				: (int) pg_prng_uint64_range(&rnd, 0, n_alloc - 1);

			otel_span_set_int(ops[pick].ref, "conformance.stress.n", i);
			n_set_attr++;
		}
		else if (choice < 85)
		{
			int			pick = legal ? live[pg_prng_uint64_range(&rnd, 0, n_live - 1)]
				: (int) pg_prng_uint64_range(&rnd, 0, n_alloc - 1);
			OtelAttribute a = OTEL_ATTR_I64("conformance.stress.event_n", i);

			otel_span_add_event(ops[pick].ref, "conformance.stress.event", 0, &a, 1);
			n_events++;
		}
		else if (choice < 93)
		{
			/* end */
			int			pick;

			if (legal)
			{
				/*
				 * Only the top of the stack mirror, or a live detached
				 * handle, is a legal end target -- never an arbitrary
				 * live[] entry, which may be a non-top stack member.
				 * Collect the live detached candidates explicitly
				 * (live[] mixes stack and detached indices).
				 */
				int			n_detached_live = 0;
				int			k;

				for (k = 0; k < n_live; k++)
					if (ops[live[k]].detached)
						detached_live_scratch[n_detached_live++] = live[k];

				if (stack_depth > 0 && (n_detached_live == 0 || pg_prng_bool(&rnd)))
					pick = stack_mirror[stack_depth - 1];
				else if (n_detached_live > 0)
					pick = detached_live_scratch[pg_prng_uint64_range(&rnd, 0, n_detached_live - 1)];
				else
					pick = stack_mirror[stack_depth - 1];
			}
			else
				pick = (int) pg_prng_uint64_range(&rnd, 0, n_alloc - 1);

			otel_span_end(ops[pick].ref);
			if (!ops[pick].ended && !ops[pick].discarded)
				n_ended++;
			ops[pick].ended = true;
			if (legal)
			{
				stress_live_remove(live, &n_live, pick);
				if (!ops[pick].detached && stack_depth > 0 &&
					stack_mirror[stack_depth - 1] == pick)
					stack_depth--;
			}
		}
		else
		{
			/* discard */
			int			pick = legal ? live[pg_prng_uint64_range(&rnd, 0, n_live - 1)]
				: (int) pg_prng_uint64_range(&rnd, 0, n_alloc - 1);

			otel_span_discard(ops[pick].ref);
			if (!ops[pick].ended && !ops[pick].discarded)
				n_discarded++;
			ops[pick].discarded = true;
			if (legal)
			{
				stress_live_remove(live, &n_live, pick);
				if (!ops[pick].detached)
					stack_mirror_remove(stack_mirror, &stack_depth, pick);
			}
		}
	}

	/* End everything still live: the stack mirror LIFO, then any
	 * remaining detached handles. */
	while (stack_depth > 0)
	{
		int			idx = stack_mirror[--stack_depth];

		if (!ops[idx].ended && !ops[idx].discarded)
		{
			otel_span_end(ops[idx].ref);
			ops[idx].ended = true;
			n_ended++;
		}
	}
	for (i = 0; i < n_live; i++)
	{
		int			idx = live[i];

		if (!ops[idx].ended && !ops[idx].discarded)
		{
			otel_span_end(ops[idx].ref);
			ops[idx].ended = true;
			n_ended++;
		}
	}
	if (!legal)
	{
		/* Illegal mode may have left handles neither in `live` nor on
		 * the (unmaintained) stack mirror alive; sweep everything. */
		for (i = 0; i < n_alloc; i++)
			if (!ops[i].ended && !ops[i].discarded && ops[i].ref.v != 0)
			{
				otel_span_end(ops[i].ref);
				ops[i].ended = true;
			}
	}

	ia->get_counters(&c_after);

	/*
	 * Cross-check every emitted span whose creator intended a specific
	 * parent (skips OTEL_SPAN_NONE creations and, in illegal mode, ops
	 * whose intended parent we deliberately didn't track).
	 */
	for (i = 0; i < n_captured; i++)
	{
		int			j;

		for (j = 0; j < n_alloc; j++)
		{
			if (!ops[j].recording)
				continue;
			if (!otel_span_id_equal(&ops[j].span_id, &captured[i].span_id))
				continue;
			if (ops[j].expected_parent_is_root)
			{
				if (otel_span_id_is_valid(&captured[i].parent_span_id))
					parent_mismatches++;
			}
			else if (!otel_span_id_equal(&ops[j].expected_parent, &captured[i].parent_span_id))
				parent_mismatches++;
			parent_checked++;
			break;
		}
	}

	initStringInfo(&buf);
	appendStringInfo(&buf,
					  "{\"mode\":");
	append_json_string(&buf, mode);
	appendStringInfo(&buf,
					  ",\"n_ops\":%d"
					  ",\"n_started\":" INT64_FORMAT
					  ",\"n_ended\":" INT64_FORMAT
					  ",\"n_discarded\":" INT64_FORMAT
					  ",\"n_set_attr\":" INT64_FORMAT
					  ",\"n_events\":" INT64_FORMAT
					  ",\"parent_checked\":%d"
					  ",\"parent_mismatches\":%d"
					  ",\"stack_current_at_end\":" INT64_FORMAT
					  ",\"spans_started_delta\":" UINT64_FORMAT
					  ",\"spans_emitted_delta\":" UINT64_FORMAT
					  ",\"spans_discarded_delta\":" UINT64_FORMAT
					  ",\"stale_handle_delta\":" UINT64_FORMAT
					  ",\"non_lifo_end_delta\":" UINT64_FORMAT
					  ",\"unwound_delta\":" UINT64_FORMAT
					  "}",
					  n_ops, n_started, n_ended, n_discarded, n_set_attr, n_events,
					  parent_checked, parent_mismatches,
					  otel_span_current().v,
					  c_after.spans_started - c_before.spans_started,
					  c_after.spans_emitted - c_before.spans_emitted,
					  c_after.spans_discarded - c_before.spans_discarded,
					  c_after.stale_handle - c_before.stale_handle,
					  c_after.non_lifo_end - c_before.non_lifo_end,
					  c_after.unwound - c_before.unwound);

	PG_RETURN_DATUM(DirectFunctionCall1(jsonb_in, CStringGetDatum(buf.data)));
}

/* ----------------------------------------------------------------
 * Spans started from abort-time code (t/015): an XACT_EVENT_ABORT
 * callback, a SUBXACT_EVENT_ABORT_SUB callback, and a
 * RegisterResourceReleaseCallback callback (the latter fires for every
 * resource owner's every release phase, with CurrentResourceOwner set
 * to the owner being released and that owner's ->releasing flag
 * already true -- so a default-owner otel_span_start() from there
 * always targets an owner that is mid-release; see otel_producer.h's
 * ".owner" rule and ResourceOwnerEnlarge()'s "called after release
 * started" check in resowner.c).  Each hook is armed for one shot and
 * disarms itself so a single scenario doesn't repeat across every
 * owner/phase in the backend.
 * ---------------------------------------------------------------- */

typedef enum ConformanceAbortSpanMode
{
	CONFORMANCE_ABORT_START_END = 0,	/* start, then end immediately */
	CONFORMANCE_ABORT_LEAVE_OPEN,		/* start, deliberately don't end */
	CONFORMANCE_ABORT_SESSION,			/* start a session-owned span, then end it */
} ConformanceAbortSpanMode;

static bool conformance_xact_abort_armed = false;
static bool conformance_subxact_abort_armed = false;
static bool conformance_release_cb_armed = false;
static bool conformance_xact_cb_registered = false;
static bool conformance_subxact_cb_registered = false;
static bool conformance_release_cb_registered = false;
static int	conformance_abort_span_mode = CONFORMANCE_ABORT_START_END;

static bool conformance_abort_hook_ran = false;
static int64 conformance_abort_span_started = 0;
static int64 conformance_abort_span_ended = 0;
static int64 conformance_abort_span_error_caught = 0;

/*
 * Common action run from all three trigger points.  The PG_TRY catches an
 * ERROR from otel_span_start() so that the counters report it.  errfinish()
 * zeroes InterruptHoldoffCount, and abort processing runs with interrupts
 * held, so a handler at this depth has to restore the count and the memory
 * context itself (see the comment in errfinish()).
 */
static void
conformance_abort_action(const char *label)
{
	uint32		save_holdoff = InterruptHoldoffCount;
	MemoryContext save_cxt = CurrentMemoryContext;

	conformance_abort_hook_ran = true;
	PG_TRY();
	{
		OtelSpanRef s;

		if (conformance_abort_span_mode == CONFORMANCE_ABORT_SESSION)
			s = otel_span_start(.tracer = &tracer_a, .name = label,
								 .owner = OTEL_OWNER_SESSION, .detached = true);
		else
			s = otel_span_start(.tracer = &tracer_a, .name = label);

		if (s.v != 0)
			conformance_abort_span_started++;
		otel_span_set_int(s, "conformance.abort_mode", conformance_abort_span_mode);

		if (conformance_abort_span_mode != CONFORMANCE_ABORT_LEAVE_OPEN)
		{
			otel_span_end(s);
			conformance_abort_span_ended++;
		}
		/*
		 * CONFORMANCE_ABORT_LEAVE_OPEN: s is deliberately abandoned here.
		 * It must be cleaned up safely by whatever owns it (the abort
		 * unwind machinery, or backend exit for a session span), not by
		 * this callback.
		 */
	}
	PG_CATCH();
	{
		MemoryContextSwitchTo(save_cxt);
		InterruptHoldoffCount = save_holdoff;
		conformance_abort_span_error_caught++;
		FlushErrorState();
	}
	PG_END_TRY();
}

static void
conformance_xact_abort_callback(XactEvent event, void *arg)
{
	if (!conformance_xact_abort_armed)
		return;
	if (event == XACT_EVENT_ABORT || event == XACT_EVENT_PARALLEL_ABORT)
	{
		conformance_xact_abort_armed = false;
		conformance_abort_action("conformance.abort.xact_event");
	}
}

static void
conformance_subxact_abort_callback(SubXactEvent event, SubTransactionId mySubid,
									SubTransactionId parentSubid, void *arg)
{
	if (!conformance_subxact_abort_armed)
		return;
	if (event == SUBXACT_EVENT_ABORT_SUB)
	{
		conformance_subxact_abort_armed = false;
		conformance_abort_action("conformance.abort.subxact_event");
	}
}

/*
 * Fires for every resource owner's every release phase in the backend
 * (RegisterResourceReleaseCallback is global, not owner-scoped).  Armed
 * for one shot; only acts on the first BEFORE_LOCKS/abort release it
 * sees, which is CurrentResourceOwner's own release (owner->releasing
 * is already true at that point).
 */
static void
conformance_release_callback(ResourceReleasePhase phase, bool isCommit,
							  bool isTopLevel, void *arg)
{
	if (!conformance_release_cb_armed)
		return;
	if (phase != RESOURCE_RELEASE_BEFORE_LOCKS || isCommit)
		return;
	conformance_release_cb_armed = false;
	conformance_abort_action("conformance.abort.release_callback");
}

PG_FUNCTION_INFO_V1(otel_api_conformance_arm_abort_hook);
Datum
otel_api_conformance_arm_abort_hook(PG_FUNCTION_ARGS)
{
	char	   *which = text_to_cstring(PG_GETARG_TEXT_PP(0));
	char	   *mode_s = text_to_cstring(PG_GETARG_TEXT_PP(1));

	if (strcmp(mode_s, "start_end") == 0)
		conformance_abort_span_mode = CONFORMANCE_ABORT_START_END;
	else if (strcmp(mode_s, "leave_open") == 0)
		conformance_abort_span_mode = CONFORMANCE_ABORT_LEAVE_OPEN;
	else if (strcmp(mode_s, "session") == 0)
		conformance_abort_span_mode = CONFORMANCE_ABORT_SESSION;
	else
		ereport(ERROR, (errmsg("otel_api_conformance: unknown abort span mode \"%s\"", mode_s)));

	if (strcmp(which, "xact") == 0)
	{
		if (!conformance_xact_cb_registered)
		{
			RegisterXactCallback(conformance_xact_abort_callback, NULL);
			conformance_xact_cb_registered = true;
		}
		conformance_xact_abort_armed = true;
	}
	else if (strcmp(which, "subxact") == 0)
	{
		if (!conformance_subxact_cb_registered)
		{
			RegisterSubXactCallback(conformance_subxact_abort_callback, NULL);
			conformance_subxact_cb_registered = true;
		}
		conformance_subxact_abort_armed = true;
	}
	else if (strcmp(which, "release") == 0)
	{
		if (!conformance_release_cb_registered)
		{
			RegisterResourceReleaseCallback(conformance_release_callback, NULL);
			conformance_release_cb_registered = true;
		}
		conformance_release_cb_armed = true;
	}
	else
		ereport(ERROR, (errmsg("otel_api_conformance: unknown abort hook \"%s\"", which)));

	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(otel_api_conformance_abort_hook_status);
Datum
otel_api_conformance_abort_hook_status(PG_FUNCTION_ARGS)
{
	StringInfoData buf;

	initStringInfo(&buf);
	appendStringInfo(&buf,
					  "{\"ran\":%s,\"started\":" INT64_FORMAT
					  ",\"ended\":" INT64_FORMAT
					  ",\"error_caught\":" INT64_FORMAT
					  ",\"span_current\":" INT64_FORMAT "}",
					  conformance_abort_hook_ran ? "true" : "false",
					  conformance_abort_span_started,
					  conformance_abort_span_ended,
					  conformance_abort_span_error_caught,
					  otel_span_current().v);
	PG_RETURN_DATUM(DirectFunctionCall1(jsonb_in, CStringGetDatum(buf.data)));
}

PG_FUNCTION_INFO_V1(otel_api_conformance_abort_hook_reset);
Datum
otel_api_conformance_abort_hook_reset(PG_FUNCTION_ARGS)
{
	conformance_abort_hook_ran = false;
	conformance_abort_span_started = 0;
	conformance_abort_span_ended = 0;
	conformance_abort_span_error_caught = 0;
	conformance_xact_abort_armed = false;
	conformance_subxact_abort_armed = false;
	conformance_release_cb_armed = false;
	PG_RETURN_VOID();
}
