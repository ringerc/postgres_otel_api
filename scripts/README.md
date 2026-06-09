# scripts/

Helpers for repo maintenance.

## `refresh-splits.sh`

Derive per-extension branches from the main branch so each can be
`git subtree add`'d at a different prefix in a postgres source tree.

Run from the repo root:

```bash
./scripts/refresh-splits.sh           # split + push to origin
./scripts/refresh-splits.sh --no-push # split locally only
```

This produces four local (and, by default, remote) branches:

- `split/otel_api`
- `split/otel_postgres_tracing`
- `split/otel_demo_exporter`
- `split/otel_test_exporter`

Each contains only the matching subdirectory's history,
flattened so the subdir's contents are at the root of the branch.
Subtree-merging from these branches lands the extensions at the
right prefixes in the postgres tree.

See the [Subtree-merging into a postgres source tree][subtree]
section of the top-level README for the `git subtree add` /
`git subtree pull` invocations.

[subtree]: ../README.md#subtree-merging-into-a-postgres-source-tree

Re-run this script after every meaningful change to the main branch
that should be picked up by downstream subtree consumers.
