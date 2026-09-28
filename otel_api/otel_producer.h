/*-------------------------------------------------------------------------
 *
 * otel_producer.h
 *	  The producer API: for extensions that create spans.
 *
 * otel_api owns all span storage.  A producer holds an 8-byte
 * OtelSpanRef handle, never a span struct:
 *
 *	   static OtelTracer my_tracer = {.name = "my_ext", .version = "1.0"};
 *
 *	   OtelSpanRef s = otel_span_start(.tracer = &my_tracer,
 *									   .name = "my_ext.work",
 *									   .unwind = OTEL_UNWIND_ERROR);
 *	   otel_span_set_int(s, "my_ext.rows", nrows);
 *	   ... work ...
 *	   otel_span_end(s);
 *
 * Every function accepts any handle, including OTEL_SPAN_NONE, so no
 * "is tracing on?" check is needed around the calls.  All the functions
 * are inline wrappers: for a span that isn't recording, a setter is one
 * compare and no call.  Build an expensive value only when it will be
 * used:
 *
 *	   if (otel_span_recording(s))
 *		   otel_span_set_str(s, "db.query.text", deparse(...));
 *
 * or use OTEL_SPAN_SET_STR_IF_RECORDING(), which does the same.
 *
 * Rules, all checked:
 *	 - Never call the API in a critical section.  cassert builds fail an
 *	   Assert; other builds get OTEL_SPAN_NONE or a no-op.
 *	 - A handle is dead after otel_span_end().  Using it again is a no-op
 *	   that is counted, and fails an Assert in cassert builds.
 *	 - Spans on the active stack should end in LIFO order.  Ending a span
 *	   with others above it ends those first (each under its own unwind
 *	   policy), with a WARNING, and fails an Assert in cassert builds.
 *
 * Lifetime.  Every recording span belongs to a resource owner: by default
 * CurrentResourceOwner, or the one given in .owner.  When the owner is
 * released on abort, the span ends under its unwind policy.  When it is
 * released on commit with the span still open, that is a leak: core
 * prints "resource was not closed", otel_api counts it, and the span is
 * dropped.  With no resource owner (outside a transaction, e.g. in a
 * background worker loop), or with .owner = OTEL_OWNER_SESSION, the span
 * is a session span: it lives until it is ended, or until backend exit,
 * and session spans have their own budget (otel_api.max_session_spans).
 *
 * All strings passed in are copied.  Attribute values longer than
 * otel_api.attr_value_max bytes are truncated.
 *
 * To make otel_api an optional dependency, include otel_producer_stub.h
 * instead of this header when otel_api's headers aren't available.  It
 * declares the same names as no-ops.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 * otel_api/otel_producer.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef OTEL_PRODUCER_H
#define OTEL_PRODUCER_H

#include "miscadmin.h"
#include "utils/elog.h"
#include "utils/resowner.h"
#include "utils/timestamp.h"

#include "otel_api.h"

#define OTEL_PRODUCER_API_MAJOR		1
#define OTEL_PRODUCER_API_MINOR		0
#define OTEL_PRODUCER_API_VERSION	OTEL_MAKE_VERSION(OTEL_PRODUCER_API_MAJOR, \
													  OTEL_PRODUCER_API_MINOR)

/*
 * Handle to a span.
 *	 v > 0	a recording span
 *	 v < 0	an unsampled span: it has a trace context that propagates, but
 *			records nothing
 *	 v == 0	no span (OTEL_SPAN_NONE)
 * Opaque otherwise.  Valid only in the backend that created it.
 */
typedef struct OtelSpanRef
{
	int64		v;
} OtelSpanRef;

#define OTEL_SPAN_NONE	((OtelSpanRef) {0})

static inline bool
otel_span_recording(OtelSpanRef s)
{
	return s.v > 0;
}

/*
 * A producer's tracer (OTel InstrumentationScope).  Declare one static
 * per producer, with name set; otel_api fills scope on first use.
 */
typedef struct OtelTracer
{
	const char *name;
	const char *version;		/* may be NULL */
	const char *schema_url;		/* may be NULL */
	const OtelInstrumentationScope *scope;	/* set by otel_api */
} OtelTracer;

/* Where a new span's parent comes from. */
typedef enum OtelSpanParent
{
	/*
	 * The top of the active stack.  If the stack is empty: in a parallel
	 * worker, the leader's published context; otherwise the backend's
	 * root context (the 'M' protocol header, otel_api.traceparent, or
	 * sqlcommenter).  If there is none, a new trace.
	 */
	OTEL_PARENT_ACTIVE = 0,
	OTEL_PARENT_CONTEXT,		/* .parent_ctx; NULL or invalid = new trace */
	OTEL_PARENT_SPAN,			/* .parent_span; OTEL_SPAN_NONE = new trace */
	OTEL_PARENT_ROOT,			/* always a new trace */
} OtelSpanParent;

/* Special value for OtelSpanStartArgs.owner. */
#define OTEL_OWNER_SESSION	((ResourceOwner) (uintptr_t) 1)

typedef struct OtelSpanStartArgs
{
	uint32		struct_size;	/* set by otel_span_start() */
	OtelTracer *tracer;
	const char *name;			/* copied; required */
	OtelSpanKind kind;
	OtelSpanParent parent;
	const OtelSpanContext *parent_ctx;
	OtelSpanRef parent_span;
	OtelSpanUnwindPolicy unwind;

	/*
	 * NULL: CurrentResourceOwner, or the session if there is none.
	 * OTEL_OWNER_SESSION: the session.  Otherwise this owner.
	 */
	ResourceOwner owner;

	/*
	 * Don't push onto the active stack.  For spans that aren't nested in
	 * the C call stack, e.g. a transaction span ended from a later
	 * callback.  Children must name it with OTEL_PARENT_SPAN.
	 */
	bool		detached;

	/*
	 * The span must end in this C stack frame or one of its callees.
	 * cassert builds fail an Assert when a later start or end finds the
	 * frame has returned with the span still open (a leak via early
	 * return).  No effect in other builds.
	 */
	bool		scoped;

	/* Start time; 0 means now. */
	TimestampTz start_time;
} OtelSpanStartArgs;

typedef struct OtelProducerApi
{
	uint32		version;		/* OTEL_PRODUCER_API_VERSION */
	uint32		struct_size;	/* sizeof(OtelProducerApi) */

	/*
	 * false when no span can be recorded: no emit hook is registered and
	 * log emission is off.  Read inline by otel_span_start() so that case
	 * costs no call.
	 */
	const bool *recording_possible;

	OtelSpanRef (*span_start) (const OtelSpanStartArgs *args);
	void		(*span_end) (OtelSpanRef s, TimestampTz end_time);

	void		(*span_set_str) (OtelSpanRef s, const char *key, const char *val);
	void		(*span_set_int) (OtelSpanRef s, const char *key, int64 val);
	void		(*span_set_double) (OtelSpanRef s, const char *key, double val);
	void		(*span_set_bool) (OtelSpanRef s, const char *key, bool val);
	void		(*span_set_vprintf) (OtelSpanRef s, const char *key,
									 const char *fmt, va_list ap)
				pg_attribute_printf(3, 0);

	/* Rename the span, e.g. once the operation is known. */
	void		(*span_set_name) (OtelSpanRef s, const char *name);
	void		(*span_set_status) (OtelSpanRef s, OtelSpanStatus code,
									const char *description);
	void		(*span_add_event) (OtelSpanRef s, const char *name,
								   TimestampTz ts, const OtelAttribute *attrs,
								   int n_attrs);
	void		(*span_add_link) (OtelSpanRef s, const OtelSpanContext *target);

	/*
	 * Copy the error currently being handled into the span and set ERROR
	 * status.  For PG_CATCH blocks, before FlushErrorState() or a
	 * re-throw.  Errors that reach the top level are captured
	 * automatically; this is for errors that are caught.
	 */
	void		(*span_capture_error) (OtelSpanRef s);
	/* The same, from an ErrorData the caller already has. */
	void		(*span_record_error) (OtelSpanRef s, const ErrorData *edata);

	/* The top of the active stack, or OTEL_SPAN_NONE. */
	OtelSpanRef (*span_current) (void);

	/*
	 * Fill *out with the span's context, for propagation.  For
	 * OTEL_SPAN_NONE, the context a new child would inherit: the top of
	 * the active stack, else the root or parallel-leader context.
	 * Returns false, with *out zeroed, if there is no context.  The
	 * tracestate pointer is valid until the stack or root context
	 * changes.
	 */
	bool		(*span_context_of) (OtelSpanRef s, OtelSpanContext *out);

	/* Add or replace a process-level Resource attribute.  Copied. */
	void		(*resource_add) (const char *key, const char *value);
} OtelProducerApi;


/* ----------------------------------------------------------------
 * Inline entry points.  Use these, not the table.
 * ---------------------------------------------------------------- */

/* The producer table, or NULL.  Cached per translation unit. */
static inline const OtelProducerApi *
otel_producer_api(void)
{
	static const void *cache = NULL;

	if (likely(cache != NULL))
		return cache == OTEL_API_MISSING ? NULL
			: (const OtelProducerApi *) cache;
	{
		const OtelApi *api = otel_api_get();
		const OtelProducerApi *p = api ? api->producer : NULL;

		if (p == NULL ||
			!otel_api_table_ok("producer", p->version, p->struct_size,
							   OTEL_PRODUCER_API_MAJOR,
							   OTEL_PRODUCER_API_MINOR,
							   sizeof(OtelProducerApi)))
		{
			cache = OTEL_API_MISSING;
			return NULL;
		}
		cache = p;
		return p;
	}
}

static inline OtelSpanRef
otel_span_start_args(const OtelSpanStartArgs *args)
{
	const OtelProducerApi *p = otel_producer_api();

	if (p == NULL || !*p->recording_possible)
		return OTEL_SPAN_NONE;
	return p->span_start(args);
}

/* otel_span_start(.name = ..., ...): designated initialisers for args. */
#define otel_span_start(...) \
	otel_span_start_args(&(OtelSpanStartArgs) { \
		.struct_size = sizeof(OtelSpanStartArgs), __VA_ARGS__ })

static inline void
otel_span_end(OtelSpanRef s)
{
	if (s.v != 0)
		otel_producer_api()->span_end(s, 0);
}

static inline void
otel_span_end_at(OtelSpanRef s, TimestampTz end_time)
{
	if (s.v != 0)
		otel_producer_api()->span_end(s, end_time);
}

static inline void
otel_span_set_str(OtelSpanRef s, const char *key, const char *val)
{
	if (s.v > 0)
		otel_producer_api()->span_set_str(s, key, val);
}

static inline void
otel_span_set_int(OtelSpanRef s, const char *key, int64 val)
{
	if (s.v > 0)
		otel_producer_api()->span_set_int(s, key, val);
}

static inline void
otel_span_set_double(OtelSpanRef s, const char *key, double val)
{
	if (s.v > 0)
		otel_producer_api()->span_set_double(s, key, val);
}

static inline void
otel_span_set_bool(OtelSpanRef s, const char *key, bool val)
{
	if (s.v > 0)
		otel_producer_api()->span_set_bool(s, key, val);
}

static inline void otel_span_set_printf(OtelSpanRef s, const char *key,
										const char *fmt,...) pg_attribute_printf(3, 4);

static inline void
otel_span_set_printf(OtelSpanRef s, const char *key, const char *fmt,...)
{
	if (s.v > 0)
	{
		va_list		ap;

		va_start(ap, fmt);
		otel_producer_api()->span_set_vprintf(s, key, fmt, ap);
		va_end(ap);
	}
}

/* Evaluate expr only if s is recording. */
#define OTEL_SPAN_SET_STR_IF_RECORDING(s, key, expr) \
	do { \
		OtelSpanRef _otel_s = (s); \
		if (otel_span_recording(_otel_s)) \
			otel_span_set_str(_otel_s, (key), (expr)); \
	} while (0)

static inline void
otel_span_set_name(OtelSpanRef s, const char *name)
{
	if (s.v > 0)
		otel_producer_api()->span_set_name(s, name);
}

static inline void
otel_span_set_status(OtelSpanRef s, OtelSpanStatus code, const char *description)
{
	if (s.v > 0)
		otel_producer_api()->span_set_status(s, code, description);
}

static inline void
otel_span_add_event(OtelSpanRef s, const char *name, TimestampTz ts,
					const OtelAttribute *attrs, int n_attrs)
{
	if (s.v > 0)
		otel_producer_api()->span_add_event(s, name, ts, attrs, n_attrs);
}

static inline void
otel_span_add_link(OtelSpanRef s, const OtelSpanContext *target)
{
	if (s.v > 0)
		otel_producer_api()->span_add_link(s, target);
}

static inline void
otel_span_capture_error(OtelSpanRef s)
{
	if (s.v > 0)
		otel_producer_api()->span_capture_error(s);
}

static inline void
otel_span_record_error(OtelSpanRef s, const ErrorData *edata)
{
	if (s.v > 0)
		otel_producer_api()->span_record_error(s, edata);
}

static inline OtelSpanRef
otel_span_current(void)
{
	const OtelProducerApi *p = otel_producer_api();

	return p ? p->span_current() : OTEL_SPAN_NONE;
}

static inline bool
otel_span_context_of(OtelSpanRef s, OtelSpanContext *out)
{
	const OtelProducerApi *p = otel_producer_api();

	if (p == NULL)
	{
		memset(out, 0, sizeof(*out));
		return false;
	}
	return p->span_context_of(s, out);
}

static inline void
otel_resource_add(const char *key, const char *value)
{
	const OtelProducerApi *p = otel_producer_api();

	if (p != NULL)
		p->resource_add(key, value);
}

#endif							/* OTEL_PRODUCER_H */
