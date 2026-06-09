#!/bin/sh
# scripts/refresh-splits.sh
#
# Derive per-extension branches from postgres_otel_api's main branch
# so each can be subtree-added at a different prefix in a postgres
# source tree.
#
# Run from the repo root. Pushes the resulting `split/*` branches to
# `origin` (use --no-push to skip).
#
# Background: git subtree's `add` and `pull` operate on a single
# prefix in the destination. Our four destinations are different
# prefixes (`contrib/otel_api`, `contrib/otel_postgres_tracing`,
# `contrib/otel_demo_exporter`, `src/test/modules/otel_test_exporter`)
# corresponding to four source subdirectories of this repo. Each
# destination needs its own source branch containing only the
# matching subdir's history, which `git subtree split` produces.

set -e

PUSH=1
case "${1:-}" in
    --no-push) PUSH=0 ;;
esac

# Map of source-subdir -> split-branch-name. The branch names match
# the postgres-tree destination prefix's final path component, which
# keeps subtree commands readable.
split() {
    src="$1"
    branch="$2"
    echo "splitting $src -> $branch"
    # --rejoin keeps the split branch's history attached to main so
    # future `subtree pull` from the destination side cleanly fast-
    # forwards; --branch creates/updates the local branch.
    git subtree split --prefix="$src" --branch="$branch"
}

split otel_api                     split/otel_api
split otel_postgres_tracing        split/otel_postgres_tracing
split otel_demo_exporter           split/otel_demo_exporter
split tests/otel_test_exporter     split/otel_test_exporter

if [ "$PUSH" = "1" ]; then
    echo "pushing split branches to origin"
    git push --force-with-lease origin \
        split/otel_api \
        split/otel_postgres_tracing \
        split/otel_demo_exporter \
        split/otel_test_exporter
else
    echo "skipping push (--no-push); split branches available locally"
fi
