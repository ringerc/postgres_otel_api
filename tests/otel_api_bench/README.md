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

For S5o/S6o, `pgbench_cell` also reports (empty for every other state):

- `exporter_thread_ns_per_tx`, `other_thread_ns_per_tx`: on-CPU time (ns)
  per transaction, split between `$EXPORTER_LIB`'s per-backend tokio worker
  thread (named `pg-otel-demo`) and every other backend thread. Sampled from
  `/proc/<backend>/task/*/{comm,schedstat}` every ~100ms for the cell's
  duration, keeping the first and last reading seen per thread id so a
  thread that exits mid-cell still contributes. `perf stat -p <postmaster>`
  already includes `pg-otel-demo` threads in its totals; this only splits
  that total, it doesn't add to it.
- `spans_accepted_per_tx`, `spans_refused_per_tx`: the collector's
  `otelcol_receiver_accepted_spans`/`_refused_spans` counters, read before
  and after the cell and divided by the transaction count. The exporter
  flushes its batch at backend exit, so the harness waits ~2s past backend
  exit before the second read. Current otelcol (0.146) exposes these with a
  `_total` suffix (`otelcol_receiver_accepted_spans_total`); matched with or
  without it.
- `spans_expected_per_tx`, `spans_dropped_per_tx`: a hardcoded
  spans-per-transaction figure per script (`spans_per_tx` in `run-fdw.sh`;
  only `select_point` is characterised: 2, from `pg.fdw.cursor` +
  `pg.fdw.fetch`, checked with `otel_api.emit_spans_to_log` against the real
  `postgres_fdw` port) minus what the collector actually accepted. At low
  sample rates (S5o) this mostly reflects unsampled transactions, not real
  exporter-side drops; at 100% (S6o) a nonzero value means the batch
  processor's queue (`OTEL_BSP_MAX_QUEUE_SIZE`, default 2048) overflowed.

A footgun found while wiring this up: don't capture `thread_acct_stop`'s
result via `$(thread_acct_stop)` / `<(thread_acct_stop)` while another
backgrounded job (e.g. `perf_start`'s `perf`) is still outstanding in the
same shell --- the `wait` inside it, run from the extra subshell a command
or process substitution forks, can hang indefinitely. `thread_acct_stop`
sets `THREAD_ACCT_EXP_NS`/`THREAD_ACCT_OTHER_NS` instead; call it as a plain
statement.
