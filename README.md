# postgres_otel_api

> [!NOTE]
> This repository was prepared with significant LLM assistance.
> Review the code, the wire-protocol claims, and the build paths
> critically before relying on them.

OpenTelemetry trace-context plumbing for PostgreSQL, packaged as a
set of installable extensions. Builds against an unpatched PostgreSQL
14+ via PGXS, or in-tree as part of a custom postgres source build.

## An integration point and scaffold for OpenTelemetry in PostgreSQL

PostgreSQL has no built-in support for OpenTelemetry trace-context
propagation, log/trace correlation, or a common API that telemetry
producers and exporter SDKs can target. Today, every observability
vendor and extension builds these primitives from scratch, usually
with fragile workarounds (sqlcommenter parsing, log-line scraping,
custom GUCs) that don't compose and don't survive prepared statements,
parallel workers, and/or proxies. Extensions may also conflict if
they both independently embed the same underlying OpenTelemetry SDK,
especially if different versions are used by each extension. This
project proposes a shared scaffold so that work can be done once and
shared.

> Just want to see what calling the API looks like? Skip ahead to
> [Using `otel_api` from an extension](#using-otel_api-from-an-extension).

The core problem it sets out to solve is **trace-context propagation
from client to server** that is:

* **Ultra-low-cost** — crucially, zero added round trips per query.
* **Compatible with the v3 extended protocol** — works with named
  and anonymous prepared statements, portals, pipelining, etc.
* **Forward- and backwards-compatible and proxy-safe** — negotiated
  via the `_pq_.` reserved startup-packet prefix; only activates if
  the server acknowledges it.
* **Compatible with client-side statement poolers and caches** —
  trace context must NOT vary the SQL text or parameter set, or it
  invalidates the driver's plan cache on every iteration.
* **Statement-scoped** — a single trace context can be attached to
  one statement without leaking into the next.

Additional capabilities that need core PostgreSQL support — and are
addressed by the companion postgres branch listed below — are:

* Automatic trace scoping so spans end when their queries do, even
  in error and abort paths.
* Reliably attaching query outcome and causative error to spans
  without fragile, lossy CONTEXT-string parsing.
* Trace-context propagation into parallel-query workers, PLs, and
  background-worker children.
* Log/trace correlation: trace_id / span_id surfaced as
  first-class fields in CSV, JSON, and `log_line_prefix` text logs.

The companion PRs against PostgreSQL ([#3][pr3] per-message protocol
headers, [#4][pr4] `pre_ready_for_query_hook`, [#5][pr5] generic
elog annotations) deliver those core pieces; this repo delivers the
contrib-side scaffold and APIs that consume them. All four extensions
in this repo also build against **unpatched** PostgreSQL 14+ —
features are detected at compile time and gracefully fall back when
absent (the protocol-header fast path becomes unavailable, but
`SET LOCAL`, session GUCs, and sqlcommenter parsing all keep working).

The expectation is that this scaffold becomes the convergence point
for OpenTelemetry across the PostgreSQL extension ecosystem:

* **Infrastructure extensions** — foreign data wrappers, table
  access methods, logical-replication / multi-master systems, and
  similar — gain end-to-end OpenTelemetry visibility into their
  activity without shipping their own SDK or exporter. They emit
  spans through `otel_api`; the operator picks the exporter.
* **Existing instrumentation extensions** can converge on this API
  to separate *what* they observe inside PostgreSQL from *where*
  the telemetry goes, collapsing per-extension exporter wiring
  into a single shared sink.
* **New extensions and in-database applications** can use the
  producer API to instrument their own work and have it land in
  the same traces as the surrounding query activity.
* **New exporter extensions** can be written against the exporter
  API to ship spans (and, in time, metrics and logs) to any
  backend — Jaeger, Tempo, vendor SaaS, an internal store — without
  each producer having to learn that target's wire format.

The net effect is one SDK, one resource model, and one
trace-context-propagation story per cluster — regardless of how many
tracing-aware extensions are loaded.

> Arguably the APIs exposed by `otel_api` belong in core. Prototyping
> them in contrib lets the API surface be exercised and iterated
> against real exporter SDKs before a core proposal; nothing here
> precludes a later promotion.

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

## Using `otel_api` from an extension

Extensions interact with `otel_api` through a single rendezvous-
discovered struct, [`OtelTracingApi`](otel_api/otel_api.h), populated
by `otel_api`'s `_PG_init`. Look it up once at your own `_PG_init`,
verify the version, then call into it through function pointers. The
typical lookup boilerplate is the same regardless of whether you're
plugging in an exporter, emitting your own spans, or just reading the
current trace context — see the in-repo examples below for the full
shape; the snippets here elide it for brevity.

<details>
<summary><b>Write a span exporter</b> — register a callback that ships
emitted spans somewhere</summary>

```c
#include <otel_api/otel.h>

static otel_span_emit_hook_type prev_hook;

static void
my_exporter_emit(const OtelSpan *span)
{
    /* Serialize and ship: OTLP/gRPC, JSON-lines, vendor SDK, ... */
    ship_to_backend(span);

    /* Always chain to the previous hook to keep the JSON-log
     * fallback and any other registered consumer working. */
    if (prev_hook)
        prev_hook(span);
}

void _PG_init(void) {
    /* ... rendezvous lookup + version check elided ... */
    otel_api->register_emit_hook(my_exporter_emit, &prev_hook);
}
```

Fully worked examples:

* [`otel_demo_exporter/otel_demo_exporter.c`](otel_demo_exporter/otel_demo_exporter.c)
  — minimal C exporter that writes one JSON line per span.
* [`postgres_otel_tracing_demo`][demo] — real Rust exporter built on
  the `opentelemetry-rust` SDK; demonstrates per-backend Tokio
  runtimes, the OTLP/gRPC exporter, and `BatchSpanProcessor`.

</details>

<details>
<summary><b>Produce spans from your own extension</b> — instrument
best-effort sub-spans; if ereport(ERROR) unwinds past span_emit, the
span is silently dropped</summary>

The default unwind policy is `OTEL_UNWIND_DROP`: `otel_api` registers
a `MemoryContextCallback` at push time, so the stack entry is popped
cleanly during ereport unwind and no phantom span is emitted. The
`OtelSpan` allocation can safely live on the C stack because the
callback never dereferences it under this policy.

```c
#include <otel_api/otel.h>

static const OtelInstrumentationScope *my_scope;

void _PG_init(void) {
    /* ... rendezvous lookup + version check elided ... */
    my_scope = otel_api->tracer_register("my_extension", MY_VERSION, NULL);
}

void
do_traced_work(const char *target)
{
    OtelSpan span;

    otel_api->span_init(&span, my_scope, "my_extension.do_work",
                   OTEL_SPAN_KIND_INTERNAL);
    otel_api->span_link_to_active_and_push(&span);
    otel_api->span_add_attribute_string(&span, "my.target", target);

    /* ... do the work; ereport(ERROR) here silently drops the span ... */

    otel_span_set_status(&span, OTEL_STATUS_OK, NULL);
    otel_span_finalize(&span);
    otel_api->span_emit(&span);   /* pops the stack + dispatches */
}
```

Use this shape for sub-spans inside a larger traced operation where
losing a span on error is preferable to emitting a half-populated one.
For statement-level spans where an aborted operation should still
appear in the trace, see the next entry.

Fully worked example:

* [`tests/otel_test_exporter/test_otel_exporter.c`](tests/otel_test_exporter/test_otel_exporter.c)
  (`test_otel_producer_roundtrip`) — single-function round trip:
  `span_init` → push → attrs → status → finalize → `span_emit`.

</details>

<details>
<summary><b>Produce spans that capture and record errors</b> — opt
into OTEL_UNWIND_ERROR so an ereport(ERROR) emits the span with
status=ERROR rather than dropping it</summary>

`OTEL_UNWIND_ERROR` upgrades the safety net: on ereport unwind the
callback still pops the stack entry, but it also sets the span's
status to `OTEL_STATUS_ERROR`, fills in `end_time = now` and a
description from the unwind, and dispatches the span to registered
exporters. This requires the `OtelSpan` allocation to outlive the
unwind because the callback dereferences the borrowed pointer — a
pure on-stack span is **not** safe under this policy. Use a
`MemoryContext`-allocated span, a static slab, or another
unwind-surviving location.

```c
#include <otel_api/otel.h>

static const OtelInstrumentationScope *my_scope;

void _PG_init(void) {
    /* ... rendezvous lookup + version check elided ... */
    my_scope = otel_api->tracer_register("my_extension", MY_VERSION, NULL);
}

void
do_traced_work(const char *target)
{
    /* Must outlive the unwind: palloc'd here, but a static slab
     * (cf. otel_postgres_tracing's span_storage) works too. */
    OtelSpan   *span = MemoryContextAlloc(CurrentMemoryContext,
                                          sizeof(OtelSpan));

    otel_api->span_init(span, my_scope, "my_extension.do_work",
                   OTEL_SPAN_KIND_INTERNAL);
    otel_span_set_unwind_policy(span, OTEL_UNWIND_ERROR);

    otel_api->span_link_to_active_and_push(span);
    otel_api->span_add_attribute_string(span, "my.target", target);

    /* ... do the work; ereport(ERROR) here -> span emitted with
     *     status=ERROR, end_time=now, descriptive message ... */

    otel_span_set_status(span, OTEL_STATUS_OK, NULL);
    otel_span_finalize(span);
    otel_api->span_emit(span);   /* pops the stack + dispatches */
}
```

Fully worked example:

* [`otel_postgres_tracing/otel_trace.c`](otel_postgres_tracing/otel_trace.c)
  — statement-level instrumentation: span_storage is a static slab,
  `unwind_policy = OTEL_UNWIND_ERROR`, spans linked to the
  propagated client context, attributes for `db.system` /
  `db.statement` / `db.user`, parallel-worker leader publishing.

</details>

<details>
<summary><b>Apply a sqlcommenter comment manually, or install a custom
sampler</b> — for the niche cases where the automatic propagation
isn't enough</summary>

You usually don't need either of these. `span_link_to_active_and_push`
already pulls the parent trace context from the active span stack
or (if empty) from the propagated client context, so producers
*just emit spans* and get correct linkage for free. The two
escape hatches here are for cases where the defaults don't fit.

**Manually apply a sqlcommenter comment.** `otel_postgres_tracing`
already calls this from `ExecutorStart` when
`otel_api.parse_sqlcommenter` is on; an extension only needs to
invoke it directly if it sees SQL text that bypasses that hook
(e.g. a custom protocol layer or batched-statement parser):

```c
if (otel_api->try_apply_sqlcommenter_context(query_string)) {
    /* ... a comment-supplied traceparent is now active ... */
}
```

**Install a custom sampling decision.** Hooks are called per
`otel_api`'s sampler policy; see the v2.1 API docs in
[`otel_api/otel_api.h`](otel_api/otel_api.h):

```c
static otel_sampler_hook_type prev_sampler;

static OtelSamplerDecision
my_sampler(const OtelSamplerInput *in)
{
    if (strstr(in->name_hint, "internal."))
        return OTEL_SAMPLER_DROP;
    return prev_sampler ? prev_sampler(in)
                        : OTEL_SAMPLER_RECORD_AND_SAMPLE;
}

void _PG_init(void) {
    /* ... rendezvous lookup elided ... */
    otel_api->register_sampler_hook(my_sampler, &prev_sampler);
}
```

If you do need read-only access to the propagated context for some
other purpose (custom log lines, exporting context to another
signal type), `otel_api->get_root_context_snapshot()` and
`otel_api->span_current_context()` are available — see the header.

Fully worked examples:

* [`tests/otel_test_exporter/test_otel_exporter.c`](tests/otel_test_exporter/test_otel_exporter.c)
  — exercises the sampler-hook policy matrix (`test_otel_set_policy`)
  and the resource-attribute introspection used by the TAP suite.
* [`otel_postgres_tracing/otel_trace.c`](otel_postgres_tracing/otel_trace.c)
  — calls `try_apply_sqlcommenter_context()` from `ExecutorStart`
  when `otel_api.parse_sqlcommenter` is on.

</details>

The full API surface — including parallel-worker context publishing,
resource-attribute introspection, and `OtelInstrumentationScope`
registration — is documented inline in
[`otel_api/otel_api.h`](otel_api/otel_api.h). The data model the
emit-hook receives (`OtelSpan`, `OtelSpanContext`, `OtelEvent`,
attribute storage) lives in [`otel_api/otel.h`](otel_api/otel.h).

## Installing (out-of-tree, against an existing PostgreSQL)

<details>
<summary>Clone, <code>make install</code> against your existing
postgres' <code>pg_config</code>, set <code>shared_preload_libraries</code>,
<code>CREATE EXTENSION</code>.</summary>

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

</details>

## Installing (in-tree, as part of a postgres source build)

<details>
<summary>Drop the four directories into <code>contrib/</code> +
<code>src/test/modules/</code> (or subtree-merge), then build postgres
as usual.</summary>

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

</details>

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

<details>
<summary>Suite status table and run instructions (in-tree
<code>make check-world</code> / <code>meson test</code>, or out-of-tree
<code>make USE_PGXS=1 installcheck</code>).</summary>

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
| `otel_api`                 | `t/001_otel.pl`                | yes | yes |
| `otel_postgres_tracing`    | (none in this dir)\*           | n/a | n/a |
| `otel_demo_exporter`       | `t/001_file_exporter.pl`       | yes | yes |
| `tests/otel_test_exporter` | `t/001_basic.pl` .. `t/008_scope.pl` | yes | yes |

\* The cross-cutting tests that exercise `otel_postgres_tracing`
(log annotations, query tracing, sampler policy, sqlcommenter, …) all
live under `tests/otel_test_exporter/t/` because they need the
test-only exporter to observe captured spans.

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

</details>

## Building from a custom checkout into a postgres tree

<details>
<summary><code>scripts/refresh-splits.sh</code> produces per-extension
<code>split/*</code> branches; <code>git subtree add --squash</code>
them into <code>contrib/</code> and <code>src/test/modules/</code>.</summary>

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

</details>

## License

PostgreSQL License — see [LICENSE](LICENSE).
