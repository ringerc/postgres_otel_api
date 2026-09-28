/*-------------------------------------------------------------------------
 *
 * otel_api.c
 *	  The published API tables, hook registration and sampling policy.
 *
 * otel_api publishes one root table (OtelApi) through a rendezvous
 * variable, pointing to one table per audience.  The producer table
 * lives in otel_producer.c with the span machinery; the exporter and
 * internal tables are here.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  otel_api/otel_api.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "fmgr.h"

#include "otel_internal.h"

#ifdef PG_HAVE_XACT_TRACE_CONTEXT
#include "access/xact.h"
#endif

static otel_span_emit_hook_type otel_span_emit_hook = NULL;
static otel_sampler_hook_type otel_sampler_hook = NULL;
static OtelSamplerHookPolicy otel_sampler_hook_policy =
	OTEL_SAMPLER_HOOK_ON_UNSAMPLED_BIT;

/*
 * True when a finished span has somewhere to go: an emit hook, or log
 * emission.  Producers read it inline through the producer table, so
 * "otel_api loaded, nothing consuming spans" costs no call per span.
 */
bool		otel_recording_possible = false;

void
otel_update_recording_possible(void)
{
	otel_recording_possible = otel_span_emit_hook != NULL ||
		otel_emit_spans_to_log;
}

static void
api_register_emit_hook(otel_span_emit_hook_type new_hook,
					   otel_span_emit_hook_type *prev_out)
{
	if (prev_out)
		*prev_out = otel_span_emit_hook;
	otel_span_emit_hook = new_hook;
	otel_update_recording_possible();
}

static void
api_register_sampler_hook(otel_sampler_hook_type new_hook,
						  otel_sampler_hook_type *prev_out)
{
	if (prev_out)
		*prev_out = otel_sampler_hook;
	otel_sampler_hook = new_hook;
}

static void
api_set_sampler_policy(OtelSamplerHookPolicy policy)
{
	otel_sampler_hook_policy = policy;
}

otel_span_emit_hook_type
otel_get_span_emit_hook(void)
{
	return otel_span_emit_hook;
}

/*
 * The sampling decision for a span with no local parent to inherit from:
 * a new trace (in->parent == NULL), or a remote parent whose sampled bit
 * is remote_sampled.  See OtelSamplerHookPolicy.
 */
OtelSamplerDecision
otel_run_sampler(const OtelSamplerInput *in, bool remote_sampled)
{
	bool		new_trace = in->parent == NULL;

	switch (otel_sampler_hook_policy)
	{
		case OTEL_SAMPLER_HOOK_NEVER_ALWAYS_SAMPLE:
			return OTEL_SAMPLE_RECORD_AND_SAMPLE;
		case OTEL_SAMPLER_HOOK_NEVER_RESPECT_BIT:
			return (new_trace || remote_sampled)
				? OTEL_SAMPLE_RECORD_AND_SAMPLE : OTEL_SAMPLE_DROP;
		case OTEL_SAMPLER_HOOK_ALWAYS:
			break;
		case OTEL_SAMPLER_HOOK_ON_UNSAMPLED_BIT:
		default:
			if (!new_trace && remote_sampled)
				return OTEL_SAMPLE_RECORD_AND_SAMPLE;
			if (!new_trace && otel_sampler_hook == NULL)
				return OTEL_SAMPLE_DROP;
			break;
	}
	if (otel_sampler_hook == NULL)
		return OTEL_SAMPLE_RECORD_AND_SAMPLE;
	return otel_sampler_hook(in);
}

static void
api_get_root_context(OtelRootContext *out)
{
	*out = otel_root_ctx;
	out->ctx.tracestate = (otel_tracestate_guc && otel_tracestate_guc[0])
		? otel_tracestate_guc : NULL;
}

static void
api_reset_root_context(void)
{
	otel_root_ctx_reset();
}

static void
api_get_counters(OtelApiCounters *out)
{
	*out = otel_counters;
}

#ifdef PG_HAVE_XACT_TRACE_CONTEXT
/*
 * Commit-record trace context: record the context of the span active at
 * commit, if it is sampled.
 */
static bool
otel_commit_trace_context_cb(xl_xact_trace_context *tc)
{
	OtelSpanContext ctx;

	if (!otel_producer_api_table.span_context_of(OTEL_SPAN_NONE, &ctx) ||
		!otel_span_context_sampled(&ctx))
		return false;
	StaticAssertStmt(sizeof(tc->trace_id) == OTEL_TRACE_ID_BYTES &&
					 sizeof(tc->span_id) == OTEL_SPAN_ID_BYTES,
					 "xl_xact_trace_context ID sizes");
	memcpy(tc->trace_id, ctx.trace_id.b, OTEL_TRACE_ID_BYTES);
	memcpy(tc->span_id, ctx.span_id.b, OTEL_SPAN_ID_BYTES);
	tc->trace_flags = ctx.trace_flags;
	memset(tc->pad, 0, sizeof(tc->pad));
	return true;
}
#endif							/* PG_HAVE_XACT_TRACE_CONTEXT */

static const OtelExporterApi otel_exporter_api_table = {
	.version = OTEL_EXPORTER_API_VERSION,
	.struct_size = sizeof(OtelExporterApi),
	.register_emit_hook = api_register_emit_hook,
	.register_sampler_hook = api_register_sampler_hook,
	.set_sampler_policy = api_set_sampler_policy,
	.get_resource_attributes = otel_resource_attrs_get,
};

static const OtelInternalApi otel_internal_api_table = {
	.version = OTEL_INTERNAL_API_VERSION,
	.struct_size = sizeof(OtelInternalApi),
	.get_root_context = api_get_root_context,
	.reset_root_context = api_reset_root_context,
	.try_apply_sqlcommenter_context = otel_try_apply_sqlcommenter_context,
	.parallel_publish_leader_context = otel_parallel_publish_leader_context,
	.parallel_clear_leader_context = otel_parallel_clear_leader_context,
	.parallel_get_leader_context = otel_parallel_get_leader_context,
	.get_counters = api_get_counters,
};

static const OtelApi otel_api_root = {
	.version = OTEL_ROOT_API_VERSION,
	.struct_size = sizeof(OtelApi),
	.producer = &otel_producer_api_table,
	.exporter = &otel_exporter_api_table,
	.internal = &otel_internal_api_table,
};

/*
 * Publish the root table and register everything exporters queued
 * before otel_api loaded.  Called from _PG_init.
 */
void
otel_api_publish_rendezvous(void)
{
	void	  **slot = find_rendezvous_variable(OTEL_API_RENDEZVOUS_NAME);
	void	  **pending = find_rendezvous_variable(OTEL_EXPORTER_PENDING_NAME);
	OtelPendingRegistration *req = (OtelPendingRegistration *) *pending;

	*slot = (void *) &otel_api_root;
	*pending = NULL;

	/* The list is LIFO; the last-queued registration ends up outermost. */
	for (; req != NULL; req = req->next)
	{
		if (req->emit_hook)
			api_register_emit_hook(req->emit_hook, req->emit_prev_out);
		if (req->sampler_hook)
			api_register_sampler_hook(req->sampler_hook, req->sampler_prev_out);
	}

#ifdef PG_HAVE_XACT_TRACE_CONTEXT
	commit_trace_context_hook = otel_commit_trace_context_cb;
#endif
}
