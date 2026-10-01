\echo Use "CREATE EXTENSION otel_api_microbench_stub" to load this file. \quit

CREATE FUNCTION otel_api_microbench_stub(
	scenario text,
	iters int,
	nattrs int,
	OUT ns_per_iter float8,
	OUT bytes_per_iter int8
) RETURNS record
AS 'MODULE_PATHNAME', 'otel_api_microbench_main'
LANGUAGE C STRICT VOLATILE;
