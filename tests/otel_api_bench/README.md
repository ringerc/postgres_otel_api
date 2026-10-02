# otel_api overhead benchmark harnesses

Measure what `otel_api` instrumentation costs a consumer extension, across the
states an operator can put a server in.

- `lib.sh`: shared code: a throwaway cluster, the states, `perf stat`
  counting, and a `pgbench` cell runner. Sourced by the harness scripts.
- `run-fdw.sh`: `postgres_fdw` against a loopback foreign server in the same
  instance, under `pgbench`.
- `run-plpgsql.sh`: `otel_plpgsql` tracing pgbench's TPC-B-like transaction
  written as a plpgsql function calling four helpers. Local work, no IPC.
  Statement spans on and off (`STMT_SPANS`); scale `SCALE`.
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
| S5o | 1% sampled, real export | `$EXPORTER_LIB` OTLP exporter to a collector; `traceidratio`, `0.01` |
| S6o | 100% sampled, real export | `$EXPORTER_LIB` OTLP exporter to a collector; `traceidratio`, `1.0` |

The null exporter is `test_otel_exporter` with `test_otel_exporter.capture =
off`: it counts spans and discards them. Sampling is decided per new root
span and inherited by its children, so the rates apply per trace.

S5o/S6o load `$EXPORTER_LIB` (default `postgres_otel_tracing_demo`, the
Rust OTLP exporter) instead of the null exporter, with the postmaster's
environment pointed at a real OpenTelemetry Collector
(`OTEL_TRACES_EXPORTER=otlp`, `OTEL_EXPORTER_OTLP_ENDPOINT`,
`OTEL_EXPORTER_OTLP_PROTOCOL=grpc`). `$EXPORTER_LIB` has no control file and
is never `CREATE EXTENSION`'d; it's a plain shared-preloaded module. Use
`state_start`/`state_stop` (not `configure_state`/`start_pg`/
`setup_state_extensions`/`stop_pg` directly) to drive any state set that
includes S5o/S6o --- they also start/stop the collector and set/unset the
`OTEL_*` env for the postmaster.

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

For S5o/S6o:

- `EXPORTER_LIB` (default `postgres_otel_tracing_demo`): the exporter's
  shared library name (no `.so`), already installed in `PG_CONFIG`'s
  pkglibdir.
- `OTELCOL` (default `otelcol` on `PATH`): the collector binary, when the
  harness starts its own.
- `COLLECTOR_CPUS` (default: unpinned): `taskset` list for a
  harness-started collector. **Does not work under `cpu-run.sh`** (see
  "Collector and the cpuset" below) --- leave it unset there and use
  `COLLECTOR_ENDPOINT`/`COLLECTOR_METRICS_URL` instead.
- `COLLECTOR_ENDPOINT`, `COLLECTOR_METRICS_URL`: when both are set, the
  harness treats the collector as externally managed (started and stopped
  by the caller) and just uses these endpoints; otherwise it starts and
  stops its own `$OTELCOL` per S5o/S6o state.

Output is CSV on stdout; diagnostics go to stderr.

## Collector and the cpuset

A collector the harness starts itself (`COLLECTOR_CPUS`, no
`COLLECTOR_ENDPOINT`) is `taskset` to those CPUs, but `taskset` can only
narrow a process's affinity *within* its cgroup cpuset --- it cannot widen it
past CPUs the cpuset already excludes. `cpu-run.sh` confines the whole
harness (and everything it forks, collector included) to `BENCH_CPUS`
(default `0-9`); a `taskset -c 10-15` child of that scope fails with
`sched_setaffinity: Invalid argument`. Checked: a `systemd-run --user --scope`
child confined to `AllowedCPUs=0-9` cannot `taskset` onto CPU 10.

So under `cpu-run.sh`, run the collector yourself, outside its cpuset, and
pass its endpoints in:

```
cat > /tmp/otel-collector.yaml <<EOF
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 127.0.0.1:14317
exporters:
  nop:
service:
  telemetry:
    metrics:
      readers:
        - pull:
            exporter:
              prometheus: {host: 127.0.0.1, port: 18888}
  pipelines:
    traces: {receivers: [otlp], exporters: [nop]}
EOF
taskset -c 10-15 otelcol --config /tmp/otel-collector.yaml &

export COLLECTOR_ENDPOINT=http://127.0.0.1:14317
export COLLECTOR_METRICS_URL=http://127.0.0.1:18888/metrics
```

The harness never starts or stops an externally managed collector; stop it
yourself when done.

## Counting

Counts come from `perf stat -p` and need `kernel.perf_event_paranoid <= 1`.
`run-fdw.sh` attaches to the postmaster, so every backend forked during the
window is counted, including the loopback connections. perf is given a fixed
window and never signalled, because `perf stat -p` can hang on SIGINT or
SIGTERM.

`pgbench_cell` also reports, per transaction:

- `exporter_thread_ns_per_tx`, `other_thread_ns_per_tx`: on-CPU time of the
  exporter's tokio worker threads (`pg-otel-demo`, one per backend) and of
  every other backend thread, in every state. Read from
  `/proc/<backend>/task/*/schedstat` every 100 ms, first and last reading per
  thread, so up to one interval per thread is missed, including the
  exporter's flush at backend exit. perf's counts already include the
  exporter threads; this splits CPU time, it doesn't add to it. Span
  conversion runs in the backend's main thread, so compare
  `other_thread_ns_per_tx` with S6.
- S5o/S6o only: `spans_accepted_per_tx`, `spans_refused_per_tx` from the
  collector's `otelcol_receiver_{accepted,refused}_spans` counters, read
  before and after the cell, 2 s after the backends exit.
  `spans_expected_per_tx` is the workload's spans per sampled transaction
  times the state's sampling ratio; `spans_dropped_per_tx` is expected minus
  accepted. At 1% it is noisy. A real shortfall means the exporter's batch
  queue (`OTEL_BSP_MAX_QUEUE_SIZE`, default 2048) overflowed.

`thread_acct_stop` sets globals rather than printing: calling it as
`$(thread_acct_stop)` while perf's background job is outstanding can hang.
