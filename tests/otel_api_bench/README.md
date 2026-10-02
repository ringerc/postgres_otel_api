# otel_api overhead benchmark harnesses

Measure what `otel_api` instrumentation costs a consumer extension, across the
states an operator can put a server in.

- `lib.sh`: shared code: a throwaway cluster, the states, `perf stat`
  counting, and a `pgbench` cell runner. Sourced by the harness scripts.
- `run-fdw.sh`: `postgres_fdw` against a loopback foreign server in the same
  instance, under `pgbench`.
- `../otel_api_microbench/run.sh`: per-span cost in isolation.

## States

| ID | State | Setup |
|---|---|---|
| S0 | Hooks compiled out | consumer built against `otel_producer_stub.h` |
| S1 | `otel_api` not loaded | real consumer build; not in `shared_preload_libraries` |
| S2 | Loaded, nothing consuming | `otel_api` only; `emit_spans_to_log = off` |
| S3 | Exporter loaded, tracing off | null exporter; `otel_api.sampler = always_off` |
| S4 | Tracing on, nothing sampled | null exporter; `traceidratio`, `sampler_arg = 0` |
| S5 | 1% sampled | null exporter; `traceidratio`, `0.01` |
| S6 | 100% sampled | null exporter; `traceidratio`, `1.0` |

The null exporter is `test_otel_exporter` with `test_otel_exporter.capture =
off`: it counts spans and discards them. Sampling is decided per new root
span and inherited by its children, so the rates apply per trace.

## Inputs

All harnesses:

- `PG_CONFIG`: the install to test (default: `pg_config` on `PATH`). Use an
  optimised build without assertions for numbers.
- `OTEL_BENCH_SCRATCH` (required): a directory on a real disk, not tmpfs.
- `SERVER_CPUS`, `CLIENT_CPUS`: `taskset` CPU lists for the server and for
  `pgbench` (default: unpinned). On hybrid CPUs, keep the server on one core
  type.

`run-fdw.sh` also needs `FDW_SO` and `FDW_STUB_SO`: `postgres_fdw.so` built
with `-DHAVE_OTEL_API` and against the stub header. It copies the right one
into the install for each state and puts back what was there on exit. Knobs:
`DURATION`, `REPEATS`, `STATES`, `SCRIPTS`, `CLIENTS`.

Output is CSV on stdout; diagnostics go to stderr.

## Counting

Counts come from `perf stat -p` and need `kernel.perf_event_paranoid <= 1`.
`run-fdw.sh` attaches to the postmaster, so every backend forked during the
window is counted, including the loopback connections. perf is given a fixed
window and never signalled, because `perf stat -p` can hang on SIGINT or
SIGTERM.
