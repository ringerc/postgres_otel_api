/*-------------------------------------------------------------------------
 *
 * otel_api_microbench.c
 *
 * Throwaway microbenchmark for the cost of the otel_api producer API in
 * isolation (postgres-cdq.24).  Built TWICE from this one source, into
 * two separate extensions that can be installed side by side:
 *
 *   otel_api_microbench       -DHAVE_OTEL_API, against otel_api/otel_producer.h
 *   otel_api_microbench_stub  against the local copy of otel_producer_stub.h
 *                             (+ otel_types.h), i.e. S0 "hooks compiled out"
 *
 * States and runner: ../otel_api_bench/README.md, run.sh.
 *
 * NOT part of otel_api; do not link against it.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <string.h>

#include "access/htup_details.h"
#include "fmgr.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "portability/instr_time.h"
#include "utils/builtins.h"
#include "utils/memutils.h"

#ifdef HAVE_OTEL_API
#include "otel_api/otel_producer.h"
#else
#include "otel_producer_stub.h"
#endif

PG_MODULE_MAGIC;

static OtelTracer microbench_tracer = {.name = "otel_api_microbench", .version = "1.0"};

typedef enum MbScenario
{
	MB_EMPTY,
	MB_ROOT,
	MB_ROOT_ATTRS,
} MbScenario;

/* Attribute keys, built outside the timed loop. */
#define MB_MAX_ATTRS 16
static const char *const mb_keys[MB_MAX_ATTRS] = {
	"mb.attr0", "mb.attr1", "mb.attr2", "mb.attr3",
	"mb.attr4", "mb.attr5", "mb.attr6", "mb.attr7",
	"mb.attr8", "mb.attr9", "mb.attr10", "mb.attr11",
	"mb.attr12", "mb.attr13", "mb.attr14", "mb.attr15",
};

static MbScenario
parse_scenario(const char *scenario)
{
	if (strcmp(scenario, "empty") == 0)
		return MB_EMPTY;
	if (strcmp(scenario, "root") == 0)
		return MB_ROOT;
	if (strcmp(scenario, "root_attrs") == 0)
		return MB_ROOT_ATTRS;
	elog(ERROR, "otel_api_microbench: unknown scenario \"%s\"", scenario);
	pg_unreachable();
}

/*
 * One iteration of a scenario.  Every iteration starts a brand-new root
 * (OTEL_PARENT_ROOT): sampling is decided per new root and otherwise
 * would be inherited from whatever's on the active stack, which would
 * make every iteration after the first measure the wrong thing.
 */
static void
run_one(MbScenario scenario, int nattrs)
{
	OtelSpanRef root;

	if (scenario == MB_EMPTY)
		return;					/* harness baseline: loop overhead only */

	root = otel_span_start(.tracer = &microbench_tracer,
						   .name = "microbench.root",
						   .kind = OTEL_SPAN_KIND_INTERNAL,
						   .parent = OTEL_PARENT_ROOT);

	if (scenario == MB_ROOT_ATTRS)
	{
		for (int i = 0; i < nattrs; i++)
		{
			if (i % 2 == 0)
				otel_span_set_int(root, mb_keys[i], (int64) i);
			else
				otel_span_set_str(root, mb_keys[i], "short-val");
		}
	}

	otel_span_end(root);
}

/*
 * otel_api_microbench(scenario, iters, nattrs) -> (ns_per_iter, bytes_per_iter)
 *
 * Bytes: a single MemoryContextMemAllocated(TopMemoryContext, true) delta
 * around the whole loop, divided by iters.  otel_api's span storage lives
 * in its own pool context created as a child of TopMemoryContext (see
 * span_pool_cxt in otel_producer.c), not under CurrentMemoryContext at the
 * call site, so TopMemoryContext is the context that actually sees the
 * allocations this benchmark cares about.  recurse=true walks that whole
 * subtree.  This is a first-pass, lightweight number (whole-loop delta,
 * not a per-call breakdown) --- good enough to compare scenarios/states,
 * not an exhaustive allocation accounting.
 */
PG_FUNCTION_INFO_V1(otel_api_microbench_main);
Datum
otel_api_microbench_main(PG_FUNCTION_ARGS)
{
	text	   *scenario_t = PG_GETARG_TEXT_PP(0);
	int32		iters = PG_GETARG_INT32(1);
	int32		nattrs = PG_GETARG_INT32(2);
	MbScenario	scenario = parse_scenario(text_to_cstring(scenario_t));
	TupleDesc	tupdesc;
	Datum		values[2];
	bool		nulls[2] = {false, false};
	HeapTuple	tuple;
	instr_time	t0,
				t1;
	int64		total_ns;
	Size		mem_before,
				mem_after;
	int			i;

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "otel_api_microbench: return type must be composite");
	tupdesc = BlessTupleDesc(tupdesc);

	if (nattrs < 0 || nattrs > MB_MAX_ATTRS)
		elog(ERROR, "otel_api_microbench: nattrs must be 0..%d", MB_MAX_ATTRS);

	/* Warm up, untimed, so pool growth isn't counted as per-span cost. */
	for (i = 0; i < Min(iters, 1000); i++)
		run_one(scenario, nattrs);

	mem_before = MemoryContextMemAllocated(TopMemoryContext, true);

	INSTR_TIME_SET_CURRENT(t0);
	for (i = 0; i < iters; i++)
		run_one(scenario, nattrs);
	INSTR_TIME_SET_CURRENT(t1);
	INSTR_TIME_SUBTRACT(t1, t0);
	total_ns = INSTR_TIME_GET_NANOSEC(t1);

	mem_after = MemoryContextMemAllocated(TopMemoryContext, true);

	values[0] = Float8GetDatum((double) total_ns / (double) iters);
	values[1] = Int64GetDatum(
							   (int64) (mem_after - mem_before) / (int64) iters);

	tuple = heap_form_tuple(tupdesc, values, nulls);
	PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}
