/* tests/otel_api_conformance/otel_api_conformance--0.1.sql */

\echo Use "CREATE EXTENSION otel_api_conformance" to load this file. \quit

-- ----------------------------------------------------------------
-- Exporter side: captured spans, counters, sampler-call count.
-- ----------------------------------------------------------------

CREATE FUNCTION otel_api_conformance_reset()
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_reset'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_spans()
RETURNS SETOF jsonb
AS 'MODULE_PATHNAME', 'otel_api_conformance_spans'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_counters()
RETURNS jsonb
AS 'MODULE_PATHNAME', 'otel_api_conformance_counters'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_sampler_calls()
RETURNS bigint
AS 'MODULE_PATHNAME', 'otel_api_conformance_sampler_calls'
LANGUAGE C VOLATILE STRICT;

-- ----------------------------------------------------------------
-- Producer side: construction, parentage, ownership.
-- ----------------------------------------------------------------

CREATE FUNCTION otel_api_conformance_start(
	name text,
	producer text DEFAULT 'a',
	kind text DEFAULT 'internal',
	parent_mode text DEFAULT 'active',
	parent_ctx bytea DEFAULT NULL,
	parent_ref bigint DEFAULT NULL,
	owner_mode text DEFAULT 'default',
	owner_id bigint DEFAULT NULL,
	detached boolean DEFAULT false,
	scoped boolean DEFAULT false
) RETURNS bigint
AS 'MODULE_PATHNAME', 'otel_api_conformance_start'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_end(ref bigint)
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_end'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_recording(ref bigint)
RETURNS boolean
AS 'MODULE_PATHNAME', 'otel_api_conformance_recording'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_set_str(ref bigint, key text, val text)
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_set_str'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_set_int(ref bigint, key text, val bigint)
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_set_int'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_set_double(ref bigint, key text, val double precision)
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_set_double'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_set_bool(ref bigint, key text, val boolean)
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_set_bool'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_set_printf(ref bigint, key text, val text)
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_set_printf'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_set_name(ref bigint, name text)
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_set_name'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_set_status(ref bigint, code text, description text)
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_set_status'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_add_event(
	ref bigint, name text,
	str_val text, int_val bigint, dbl_val double precision, bool_val boolean
) RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_add_event'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_add_link(ref bigint, ctx bytea)
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_add_link'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_if_recording_scenario(ref bigint)
RETURNS bigint
AS 'MODULE_PATHNAME', 'otel_api_conformance_if_recording_scenario'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_side_effect_count()
RETURNS bigint
AS 'MODULE_PATHNAME', 'otel_api_conformance_side_effect_count'
LANGUAGE C VOLATILE STRICT;

-- ----------------------------------------------------------------
-- Ownership: caller-created resource owners, session spans.
-- ----------------------------------------------------------------

CREATE FUNCTION otel_api_conformance_create_owner(name text)
RETURNS bigint
AS 'MODULE_PATHNAME', 'otel_api_conformance_create_owner'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_release_owner(owner_id bigint, do_commit boolean DEFAULT true)
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_release_owner'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_start_session(name text)
RETURNS bigint
AS 'MODULE_PATHNAME', 'otel_api_conformance_start_session'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_launch_bgworker()
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_launch_bgworker'
LANGUAGE C VOLATILE;

-- ----------------------------------------------------------------
-- Error paths.
-- ----------------------------------------------------------------

CREATE FUNCTION otel_api_conformance_capture_error_scenario(name text)
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_capture_error_scenario'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_record_error_scenario(name text)
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_record_error_scenario'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_start_and_ereport(name text, elevel text)
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_start_and_ereport'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_injection_scenario(name text)
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_injection_scenario'
LANGUAGE C VOLATILE STRICT;

-- ----------------------------------------------------------------
-- Limits and stress.
-- ----------------------------------------------------------------

CREATE FUNCTION otel_api_conformance_exhaust_open(n integer, owner_mode text DEFAULT 'toptxn')
RETURNS integer
AS 'MODULE_PATHNAME', 'otel_api_conformance_exhaust_open'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_exhaust_session(n integer)
RETURNS integer
AS 'MODULE_PATHNAME', 'otel_api_conformance_exhaust_session'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_stress(n bigint)
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_stress'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_backend_mem_bytes()
RETURNS bigint
AS 'MODULE_PATHNAME', 'otel_api_conformance_backend_mem_bytes'
LANGUAGE C VOLATILE STRICT;

-- ----------------------------------------------------------------
-- Propagation.
-- ----------------------------------------------------------------

CREATE FUNCTION otel_api_conformance_traceparent_roundtrip(tp text)
RETURNS text
AS 'MODULE_PATHNAME', 'otel_api_conformance_traceparent_roundtrip'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_context_send(
	trace_id_hex text, span_id_hex text, flags integer, tracestate text DEFAULT NULL
) RETURNS bytea
AS 'MODULE_PATHNAME', 'otel_api_conformance_context_send'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_context_recv(wire bytea)
RETURNS text
AS 'MODULE_PATHNAME', 'otel_api_conformance_context_recv'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_context_of(ref bigint)
RETURNS bytea
AS 'MODULE_PATHNAME', 'otel_api_conformance_context_of'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_current_context()
RETURNS bytea
AS 'MODULE_PATHNAME', 'otel_api_conformance_current_context'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_start_from_context(wire bytea, name text)
RETURNS bigint
AS 'MODULE_PATHNAME', 'otel_api_conformance_start_from_context'
LANGUAGE C VOLATILE STRICT;

-- ----------------------------------------------------------------
-- Parallel workers.
-- ----------------------------------------------------------------

CREATE FUNCTION otel_api_conformance_publish_leader_context(ref bigint)
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_publish_leader_context'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_clear_leader_context()
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_clear_leader_context'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_parallel_worker_probe()
RETURNS text
AS 'MODULE_PATHNAME', 'otel_api_conformance_parallel_worker_probe'
LANGUAGE C VOLATILE PARALLEL SAFE;

-- ----------------------------------------------------------------
-- Misuse (cassert builds only fail an Assert; see docs in the .c file).
-- ----------------------------------------------------------------

CREATE FUNCTION otel_api_conformance_misuse_use_after_end()
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_misuse_use_after_end'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_misuse_double_end()
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_misuse_double_end'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_misuse_non_lifo()
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_misuse_non_lifo'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_misuse_critical_section()
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_misuse_critical_section'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_misuse_crit_section_op(op text)
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_misuse_crit_section_op'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_misuse_scoped_leak()
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_misuse_scoped_leak'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_misuse_foreign_handle()
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_misuse_foreign_handle'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_misuse_open_at_commit()
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_misuse_open_at_commit'
LANGUAGE C VOLATILE;

-- ----------------------------------------------------------------
-- plpgsql recursion (t/011) and interleaving (t/012).
-- ----------------------------------------------------------------

CREATE FUNCTION otel_api_conformance_span_current()
RETURNS bigint
AS 'MODULE_PATHNAME', 'otel_api_conformance_span_current'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_discard(ref bigint)
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_discard'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_with_span(name text, sql text)
RETURNS bigint
AS 'MODULE_PATHNAME', 'otel_api_conformance_with_span'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_with_span_catch(name text, sql text,
	after_name text DEFAULT NULL)
RETURNS bigint
AS 'MODULE_PATHNAME', 'otel_api_conformance_with_span_catch'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_detached_chain(n integer, order_mode text, seed bigint DEFAULT NULL)
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_detached_chain'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_parent_ends_first()
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_parent_ends_first'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_mixed_non_lifo_detached()
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_mixed_non_lifo_detached'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_two_producer_interleave()
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_two_producer_interleave'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_wide_fanout(n_children integer, seed bigint DEFAULT NULL, n_over_limit integer DEFAULT 0)
RETURNS jsonb
AS 'MODULE_PATHNAME', 'otel_api_conformance_wide_fanout'
LANGUAGE C VOLATILE;

CREATE FUNCTION otel_api_conformance_stress_ops(seed bigint, n_ops integer, mode text DEFAULT 'legal')
RETURNS jsonb
AS 'MODULE_PATHNAME', 'otel_api_conformance_stress_ops'
LANGUAGE C VOLATILE STRICT;

-- ----------------------------------------------------------------
-- Spans started from abort-time code (t/015).
-- ----------------------------------------------------------------

CREATE FUNCTION otel_api_conformance_arm_abort_hook(which text, mode text DEFAULT 'start_end')
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_arm_abort_hook'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_abort_hook_status()
RETURNS jsonb
AS 'MODULE_PATHNAME', 'otel_api_conformance_abort_hook_status'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION otel_api_conformance_abort_hook_reset()
RETURNS void
AS 'MODULE_PATHNAME', 'otel_api_conformance_abort_hook_reset'
LANGUAGE C VOLATILE STRICT;
