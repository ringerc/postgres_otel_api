# postgres_otel_api

> [!NOTE]
> This repository was prepared with significant LLM assistance.
> Review the code, the wire-protocol claims, and the build paths
> critically before relying on them. The TAP test suites are inherited
> verbatim from the postgres source tree they came from and have been
> exercised there, but the standalone out-of-tree build has not been
> independently audited.

OpenTelemetry trace-context plumbing for PostgreSQL, packaged as a
set of installable extensions. Builds against an unpatched PostgreSQL
14+ via PGXS, or in-tree as part of a custom postgres source build.

## What's in here

Four extensions in one repo:

| Directory | Extension | What it does |
|---|---|---|
| [`otel_api/`](otel_api/) | `otel_api` | The API and in-process plumbing. Publishes the `OtelTracingApi` rendezvous table, owns trace-context state, parallel-worker propagation, the producer API, resource attributes. Consumers depend on this. |
| [`otel_postgres_tracing/`](otel_postgres_tracing/) | `otel_postgres_tracing` | Query-instrumentation consumer. Hooks `ExecutorStart`/`End` for statement spans, `emit_log_hook` for log-event correlation, `ProcessUtility_hook` for utility-command spans. |
| [`otel_demo_exporter/`](otel_demo_exporter/) | `otel_demo_exporter` | Bare-minimum file exporter — writes one JSON line per emitted span to a file. Useful for development; not for production. |
| [`tests/otel_test_exporter/`](tests/otel_test_exporter/) | `test_otel_exporter` | Test-only span exporter used by the TAP suites. Built but **not installed by default** (`make install` skips it). Available via `make install-test-modules` if you want it for your own development. |

All four are loadable PostgreSQL modules (`.so`) activated via
`shared_preload_libraries`. `otel_api` must come first in the
preload list; the others depend on its rendezvous variable.

## Status

Pre-release, version 0.1.x. The on-wire and on-disk APIs are
unstable; minor versions may break compatibility. Major version 0
signals "do not pin against this for production".

## Companion repositories

This repo is part of a set:

| Repository | What |
|---|---|
| [`ringerc/postgres`][pg] @ `postgres-otel-tracing` | Patched PostgreSQL combining the core changes that unlock Mode 4 trace context propagation ([PR #2][pr2] elog trace-context fields, [PR #3][pr3] protocol headers, [PR #4][pr4] `pre_ready_for_query_hook`, [PR #5][pr5] generic elog annotations) **and** this repo's extensions subtree-merged at `contrib/otel_api`, `contrib/otel_postgres_tracing`, `contrib/otel_demo_exporter`, and `src/test/modules/otel_test_exporter` — so a single `./configure && make install` builds patched server + extensions together as one tree (umbrella [PR #1][pr1], draft). `otel_api` auto-detects PR #2–#5 at compile time and falls back gracefully if absent, so it also builds against stock postgres 14+. |
| [`ringerc/postgres_otel_tracing_demo`][demo] | A real-`opentelemetry-rust` SDK consumer of `otel_api`'s span-emit hook. Writes spans via OTLP/gRPC. |
| [`ringerc/postgres_otel_tracing_bench`][bench] | Go benchmark harness measuring trace-context-propagation overhead, including against the M-message mode unlocked by the patched postgres. |
| [`ringerc/pgx_patches`][pgxp] @ `m-protocol-headers` | pgx (Go driver) fork that adds `'M'` wire support for the patched postgres. |

[pg]: https://github.com/ringerc/postgres/tree/postgres-otel-tracing
[demo]: https://github.com/ringerc/postgres_otel_tracing_demo
[bench]: https://github.com/ringerc/postgres_otel_tracing_bench
[pgxp]: https://github.com/ringerc/pgx_patches/tree/m-protocol-headers
[pr1]: https://github.com/ringerc/postgres/pull/1
[pr2]: https://github.com/ringerc/postgres/pull/2
[pr3]: https://github.com/ringerc/postgres/pull/3
[pr4]: https://github.com/ringerc/postgres/pull/4
[pr5]: https://github.com/ringerc/postgres/pull/5

## Installing (out-of-tree, against an existing PostgreSQL)

You need PostgreSQL 14+, the `pg_config` binary on your `$PATH` (or
exported as `PG_CONFIG`), and standard build tools (`gcc`, `make`).

```bash
git clone https://github.com/ringerc/postgres_otel_api.git
cd postgres_otel_api
make            # builds all four
sudo make install
```

By default this installs the three production extensions
(`otel_api`, `otel_postgres_tracing`, `otel_demo_exporter`) and
**not** `test_otel_exporter`. If you want the test exporter too:

```bash
sudo make install-test-modules
```

Then in `postgresql.conf`:

```ini
shared_preload_libraries = 'otel_api,otel_postgres_tracing,otel_demo_exporter'
# otel_api MUST come first --- it publishes the rendezvous variable
# that the other two consume.
```

Restart, then in each database that wants the extension:

```sql
CREATE EXTENSION otel_api;
CREATE EXTENSION otel_postgres_tracing;
CREATE EXTENSION otel_demo_exporter;
```

## Installing (in-tree, as part of a postgres source build)

Copy the four directories into a postgres source tree's `contrib/`
and `src/test/modules/` respectively (the
[subtree-mergeable layout][subtree] keeps the postgres tree's
canonical content in sync with this repo automatically):

```text
postgres/contrib/otel_api/
postgres/contrib/otel_postgres_tracing/
postgres/contrib/otel_demo_exporter/
postgres/src/test/modules/otel_test_exporter/
```

Then build postgres normally (`meson setup builddir && ninja -C
builddir install`). Both the in-tree meson build and the standard
postgres `make` build pick up the extensions automatically.

[subtree]: #subtree-merging-into-a-postgres-source-tree

## Feature detection — patched vs unpatched core

`otel_api` is designed to build against an unpatched PostgreSQL by
detecting optional core features at compile time. Two such features:

| Macro | What it unlocks | Source |
|---|---|---|
| `OTEL_HAVE_PROTOCOL_HEADERS` | `'M'` RequestHeaders message handler, `RegisterProtocolHeaderHandler` API. Lets clients attach trace context to queries via the wire protocol. Without it, trace context can only enter via `SET otel.traceparent` or sqlcommenter SQL comments. | [ringerc/postgres PR #3][pr3] |
| `OTEL_HAVE_ERRANNOT` | Generic `errannot()` / `errannotf()` helpers on `ErrorData`, `%A` / `%{key}A` in `log_line_prefix`, JSON/CSV log output for annotations. Trace context surfaces as named log annotations. Without it, `emit_log_hook` injects trace context into `edata->context` as a textual fallback. | [ringerc/postgres PR #5][pr5] |

[pr3]: https://github.com/ringerc/postgres/pull/3
[pr5]: https://github.com/ringerc/postgres/pull/5

Auto-detected by the Makefile probing the installed
`include/server/utils/elog.h` and `include/server/libpq/protocol_headers.h`.
Force the result either way with command-line overrides:

```bash
make ENABLE_PROTOCOL_HEADERS=1     # force enable
make ENABLE_PROTOCOL_HEADERS=0     # force disable
make ENABLE_ERRANNOT=1             # force enable
make ENABLE_ERRANNOT=0             # force disable
```

The meson (in-tree) path uses the same probes but doesn't yet
expose overrides — patch the `meson.build` files directly if you
need to override there.

## Tests

TAP test suites live in `t/` directories alongside each extension.
Each suite spins up its own temp cluster via `PostgreSQL::Test::Cluster`
and configures `shared_preload_libraries` per-test, so the suites work
the same regardless of how they're driven.

The pg_regress (SQL regression) and isolation runners are **not** used
by this project --- the extensions need `shared_preload_libraries`,
which a plain `installcheck` cannot reconfigure.

Suite status:

| Extension | TAP files | In-tree | Out-of-tree (PGXS) |
|---|---|---|---|
| `otel_api`               | `t/001_otel.pl`              | yes | yes |
| `otel_postgres_tracing`  | `t/001_*..008_*.pl` (8 files) | yes | TODO |
| `otel_demo_exporter`     | `t/001_file_exporter.pl`     | yes | TODO |
| `tests/otel_test_exporter` | (test harness)             | yes | TODO |

For the suites marked TODO, the Makefile still has `NO_INSTALLCHECK = 1`
so `make installcheck` is a no-op. The fix is the same shape that was
applied to `otel_api/Makefile`: replace `NO_INSTALLCHECK = 1` with
empty `REGRESS =` and `ISOLATION =` so PGXS skips those runners but
still drives `prove_installcheck`.

### In-tree (subtree-merged into a postgres source tree)

With the extensions dropped into a postgres source tree (see
[Subtree-merging](#subtree-merging-into-a-postgres-source-tree) below)
the standard postgres build invokes the TAPs as part of the regular
test sweep:

```bash
# from the postgres source root:
make check-world                       # autotools build
# or
meson test --suite setup --suite contrib  # meson build
```

To run a single extension's TAPs only:

```bash
# autotools:
make -C contrib/otel_api check
# meson:
meson test -C builddir otel_api
```

### Out-of-tree (PGXS, this repo as-is)

Requires an installed postgres whose `pg_config` is on `$PATH` (or
passed explicitly as `PG_CONFIG=...`). The TAP runner needs the
PostgreSQL test perl modules from that install (`include/server/`
shipped alongside the postgres binaries).

```bash
# build + install each extension first; the TAPs run against the
# installed copy, not the build directory.
make USE_PGXS=1
sudo make USE_PGXS=1 install

# then run the TAP suite:
make USE_PGXS=1 installcheck
```

If `pg_config` points somewhere other than the postgres you want
to test against:

```bash
make USE_PGXS=1 PG_CONFIG=/path/to/postgres/bin/pg_config installcheck
```

Both `otel_api` and `otel_postgres_tracing` must be installed before
running either suite --- the otel_api TAPs preload both extensions
to exercise the log-annotation path that lives in
`otel_postgres_tracing`.

## Building from a custom checkout into a postgres tree

The `scripts/refresh-splits.sh` helper produces per-extension
branches (`split/otel_api`, `split/otel_postgres_tracing`,
`split/otel_demo_exporter`, `split/otel_test_exporter`) suitable for
`git subtree add` from a postgres tree. See `scripts/README.md`.

### Subtree-merging into a postgres source tree

Recommended workflow for users integrating these extensions into a
custom postgres fork:

```bash
# in your postgres source tree, one-time setup:
git remote add otel_api https://github.com/ringerc/postgres_otel_api.git
git fetch otel_api

git subtree add --prefix=contrib/otel_api otel_api split/otel_api --squash
git subtree add --prefix=contrib/otel_postgres_tracing otel_api split/otel_postgres_tracing --squash
git subtree add --prefix=contrib/otel_demo_exporter otel_api split/otel_demo_exporter --squash
git subtree add --prefix=src/test/modules/otel_test_exporter otel_api split/otel_test_exporter --squash

# later, to pull updates from the standalone repo:
git subtree pull --prefix=contrib/otel_api otel_api split/otel_api --squash
# ... and so on for the other three.
```

## License

PostgreSQL License — see [LICENSE](LICENSE).
