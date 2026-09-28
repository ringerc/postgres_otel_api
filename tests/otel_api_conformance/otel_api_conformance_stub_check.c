/*-------------------------------------------------------------------------
 *
 * otel_api_conformance_stub_check.c
 *	  Compiled against otel_producer_stub.h instead of otel_producer.h,
 *	  to prove the stub header stays in step with the real one: it
 *	  declares every name a producer uses, with the same signatures.
 *
 * otel_api_conformance_stub_check() calls every producer entry point
 * once and is called from otel_api_conformance.c's _PG_init, so this
 * isn't just compiled-and-discarded: it actually runs, harmlessly,
 * since every call here is a no-op by construction (the stub never
 * touches otel_api).
 *
 * All otel_producer_stub.h entry points are static inline, so this
 * translation unit's copies of those names have internal linkage and
 * link into the same .so as otel_api_conformance.c (which uses the
 * real otel_producer.h) without any symbol clash.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 * tests/otel_api_conformance/otel_api_conformance_stub_check.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <string.h>

#include "utils/elog.h"

/* otel_types.h is included by otel_producer_stub.h; no otel_api.h here. */
#include "otel_producer_stub.h"

void		otel_api_conformance_stub_check(void);

void
otel_api_conformance_stub_check(void)
{
	OtelTracer	tracer = {.name = "stub_check"};
	OtelSpanRef s;
	OtelSpanContext ctx;
	ErrorData	dummy_edata;

	memset(&ctx, 0, sizeof(ctx));
	memset(&dummy_edata, 0, sizeof(dummy_edata));

	s = otel_span_start(.tracer = &tracer, .name = "stub.smoke");
	otel_span_set_str(s, "k", "v");
	otel_span_set_int(s, "k", 1);
	otel_span_set_double(s, "k", 1.0);
	otel_span_set_bool(s, "k", true);
	otel_span_set_printf(s, "k", "%d", 1);
	OTEL_SPAN_SET_STR_IF_RECORDING(s, "k", "v");
	otel_span_set_name(s, "renamed");
	otel_span_set_status(s, OTEL_STATUS_OK, "ok");
	otel_span_add_event(s, "ev", 0, NULL, 0);
	otel_span_add_link(s, &ctx);
	otel_span_capture_error(s);
	otel_span_record_error(s, &dummy_edata);
	(void) otel_span_current();
	(void) otel_span_context_of(s, &ctx);
	otel_resource_add("k", "v");
	otel_span_end_at(s, 0);
	otel_span_end(s);
	(void) otel_span_recording(s);
}
