/*-------------------------------------------------------------------------
 *
 * otel_exporter.h
 *	  The exporter API: for extensions that receive finished spans.
 *
 * An exporter registers an emit hook, and optionally a sampler hook,
 * from _PG_init with otel_exporter_register_when_ready().  It works
 * whichever of otel_api and the exporter loads first.
 *
 * The emit hook receives a const OtelSpan *.  The span, and every pointer
 * reachable from it, is owned by otel_api and valid only during the
 * call.  An exporter that defers work must copy what it needs.  The hook
 * may run during abort processing, after an out-of-memory error, so an
 * exporter that allocates must expect it to fail.  An ERROR raised by
 * the hook is caught and discarded.
 *
 * The hook must not call the producer API (otel_producer.h), except for
 * otel_span_current() and otel_span_context_of().  Other calls are
 * refused: cassert builds fail an Assert, and other builds count the
 * call in otel_api_counters() as in_emit_hook and do nothing.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 * otel_api/otel_exporter.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef OTEL_EXPORTER_H
#define OTEL_EXPORTER_H

#include "datatype/timestamp.h"

#include "otel_api.h"

#define OTEL_EXPORTER_API_MAJOR		1
#define OTEL_EXPORTER_API_MINOR		0
#define OTEL_EXPORTER_API_VERSION	OTEL_MAKE_VERSION(OTEL_EXPORTER_API_MAJOR, \
													  OTEL_EXPORTER_API_MINOR)

/* Mirrors the OTel SDK SamplingDecision. */
typedef enum OtelSamplerDecision
{
	OTEL_SAMPLE_DROP = 0,
	OTEL_SAMPLE_RECORD_ONLY = 1,	/* record, but propagate sampled=0 */
	OTEL_SAMPLE_RECORD_AND_SAMPLE = 2,
} OtelSamplerDecision;

/*
 * A span event.  An error captured on the span is exported as an event
 * named "exception", with the error's fields as attributes.
 */
typedef struct OtelSpanEvent
{
	const char *name;
	TimestampTz time;
	int			n_attrs;
	const OtelAttribute *attrs;
} OtelSpanEvent;

/*
 * A finished span, as the emit hook sees it.
 *
 * struct_size is the first field and is sizeof(OtelSpan) in the
 * otel_api that built the span.  Fields are only appended within a
 * MAJOR.  An exporter compiled against a newer header than the running
 * otel_api must drop spans whose struct_size is smaller than its own
 * sizeof(OtelSpan); otel_exporter_span_ok() does the check.
 *
 * The dropped_* counts say how many attributes, events and links were
 * discarded (by the per-span limits or allocation failure).  They map
 * onto OTLP's dropped_*_count fields.
 */
typedef struct OtelSpan
{
	uint32		struct_size;
	OtelSpanKind kind;
	const OtelInstrumentationScope *scope;

	OtelTraceId trace_id;
	OtelSpanId	span_id;
	OtelSpanId	parent_span_id; /* all zero for a root span */
	uint8		trace_flags;
	const char *tracestate;		/* may be NULL */

	const char *name;
	OtelSpanStatus status;
	OtelSamplerDecision sampler_decision;
	const char *status_description; /* may be NULL */

	TimestampTz start_time;
	TimestampTz end_time;

	int			n_attrs;
	uint32		dropped_attrs;
	const OtelAttribute *attrs;

	int			n_events;
	uint32		dropped_events;
	const OtelSpanEvent *events;

	int			n_links;
	uint32		dropped_links;
	const OtelSpanContext *links;
} OtelSpan;

static inline bool
otel_exporter_span_ok(const OtelSpan *span)
{
	return span->struct_size >= sizeof(OtelSpan);
}

/*
 * Input to the sampler hook, for a span with no recording or unsampled
 * parent to inherit from.  All pointers are valid only during the call.
 * The hook must be fast and should not allocate.
 */
typedef struct OtelSamplerInput
{
	const OtelTraceId *trace_id;	/* the new span's trace ID */
	const OtelSpanContext *parent;	/* remote parent, or NULL for a new trace */
	const char *name;
	OtelSpanKind kind;
} OtelSamplerInput;

typedef OtelSamplerDecision (*otel_sampler_hook_type) (const OtelSamplerInput *in);
typedef void (*otel_span_emit_hook_type) (const OtelSpan *span);

/*
 * When the sampler hook is consulted.  "Remote parent" is a context from
 * outside this backend: the 'M' header, otel_api.traceparent,
 * sqlcommenter, a parallel leader, or OTEL_PARENT_CONTEXT.  A child of a
 * span in this backend always inherits its parent's decision.
 *
 * With no hook registered, a new trace is recorded, as with the OTel SDK
 * default sampler (ParentBased(AlwaysOn)).  A producer that shouldn't
 * start traces on its own (e.g. query tracing without trace context)
 * checks otel_span_context_of(OTEL_SPAN_NONE, ...) before starting.
 *
 *	 ON_UNSAMPLED_BIT (default): W3C ParentBased.  A remote parent with
 *		sampled=1 is recorded without asking.  A remote parent with
 *		sampled=0 goes to the hook (no hook: not recorded).  A new trace
 *		goes to the hook (no hook: recorded).
 *	 ALWAYS: the hook decides for every remote parent and every new trace
 *		(no hook: recorded).
 *	 NEVER_RESPECT_BIT: no hook; a remote parent's sampled bit decides,
 *		and a new trace is recorded.
 *	 NEVER_ALWAYS_SAMPLE: no hook; everything is recorded.
 */
typedef enum OtelSamplerHookPolicy
{
	OTEL_SAMPLER_HOOK_ON_UNSAMPLED_BIT = 0,
	OTEL_SAMPLER_HOOK_ALWAYS = 1,
	OTEL_SAMPLER_HOOK_NEVER_RESPECT_BIT = 2,
	OTEL_SAMPLER_HOOK_NEVER_ALWAYS_SAMPLE = 3,
} OtelSamplerHookPolicy;

typedef struct OtelResourceAttribute
{
	const char *key;
	const char *value;
} OtelResourceAttribute;

typedef struct OtelExporterApi
{
	uint32		version;		/* OTEL_EXPORTER_API_VERSION */
	uint32		struct_size;	/* sizeof(OtelExporterApi) */

	/*
	 * Chainable hooks.  *prev_out receives the previous hook, which the
	 * new hook must call.  Call from _PG_init only.
	 */
	void		(*register_emit_hook) (otel_span_emit_hook_type new_hook,
									   otel_span_emit_hook_type *prev_out);
	void		(*register_sampler_hook) (otel_sampler_hook_type new_hook,
										  otel_sampler_hook_type *prev_out);
	void		(*set_sampler_policy) (OtelSamplerHookPolicy policy);

	/*
	 * The process Resource.  The array and strings are owned by otel_api
	 * and stay valid, but producers may add attributes later
	 * (resource_add), so re-read rather than caching the count.
	 */
	const OtelResourceAttribute *(*get_resource_attributes) (int *n_out);
} OtelExporterApi;

static inline const OtelExporterApi *
otel_exporter_api(void)
{
	static const void *cache = NULL;

	if (likely(cache != NULL))
		return cache == OTEL_API_MISSING ? NULL
			: (const OtelExporterApi *) cache;
	{
		const OtelApi *api = otel_api_get();
		const OtelExporterApi *e = api ? (const OtelExporterApi *) api->exporter : NULL;

		if (e == NULL ||
			!otel_api_table_ok("exporter", e->version, e->struct_size,
							   OTEL_EXPORTER_API_MAJOR,
							   OTEL_EXPORTER_API_MINOR,
							   sizeof(OtelExporterApi)))
		{
			cache = OTEL_API_MISSING;
			return NULL;
		}
		cache = e;
		return e;
	}
}

/*
 * Registration that works in either load order.  If otel_api is already
 * loaded, registers now; otherwise queues *req, and otel_api registers
 * it from its own _PG_init.  *req must be static or in TopMemoryContext.
 * Unused fields must be NULL.
 */
#define OTEL_EXPORTER_PENDING_NAME	"OtelApi.v3.pending"

typedef struct OtelPendingRegistration
{
	otel_span_emit_hook_type emit_hook;
	otel_span_emit_hook_type *emit_prev_out;
	otel_sampler_hook_type sampler_hook;
	otel_sampler_hook_type *sampler_prev_out;
	struct OtelPendingRegistration *next;
} OtelPendingRegistration;

static inline void
otel_exporter_register_when_ready(OtelPendingRegistration *req)
{
	/*
	 * Look at the rendezvous slot directly rather than via otel_api_get():
	 * this runs in _PG_init, where caching "absent" would be wrong.
	 */
	void	  **slot = find_rendezvous_variable(OTEL_API_RENDEZVOUS_NAME);
	const OtelApi *api = (const OtelApi *) *slot;

	if (api != NULL)
	{
		const OtelExporterApi *e = (const OtelExporterApi *) api->exporter;

		if (!otel_api_table_ok("root", api->version, api->struct_size,
							   OTEL_ROOT_API_MAJOR, OTEL_ROOT_API_MINOR,
							   sizeof(OtelApi)) ||
			!otel_api_table_ok("exporter", e->version, e->struct_size,
							   OTEL_EXPORTER_API_MAJOR,
							   OTEL_EXPORTER_API_MINOR,
							   sizeof(OtelExporterApi)))
			return;
		if (req->emit_hook)
			e->register_emit_hook(req->emit_hook, req->emit_prev_out);
		if (req->sampler_hook)
			e->register_sampler_hook(req->sampler_hook, req->sampler_prev_out);
		return;
	}
	{
		void	  **pending = find_rendezvous_variable(OTEL_EXPORTER_PENDING_NAME);

		req->next = (OtelPendingRegistration *) *pending;
		*pending = req;
	}
}

#endif							/* OTEL_EXPORTER_H */
