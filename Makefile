# postgres_otel_api top-level Makefile.
#
# Recurses into the three production extensions for `make all`,
# `make install`, and `make check`. The test-only otel_test_exporter
# under tests/ participates in `make check` (it's required for the
# TAP suites that exercise the otel_api API), but is excluded from
# `make install` --- if you do want it installed (for example, to
# use it as a known-good span sink in your own development work),
# run `make install-test-modules` explicitly.
#
# All targets here are pure delegators; the per-extension Makefiles
# are PGXS-aware and handle the actual build, install, and feature-
# probe decisions. See the per-extension Makefiles for details on
# the ENABLE_PROTOCOL_HEADERS and ENABLE_ERRANNOT overrides.
#
# Usage:
#
#   make                      # build all four extensions
#   make install              # install production three (not test_otel_exporter)
#   make install-test-modules # install test_otel_exporter only
#   make install-all          # install all four
#   make check                # run TAP tests across all four
#   make clean                # clean all build trees
#
# Out-of-tree builds need `pg_config` on $PATH or an explicit
# PG_CONFIG=... on the command line; the per-extension Makefiles
# pick it up from there.

PROD_DIRS = otel_api otel_postgres_tracing otel_demo_exporter
TEST_DIRS = tests/otel_test_exporter
ALL_DIRS  = $(PROD_DIRS) $(TEST_DIRS)

# Forward any user-supplied PG_CONFIG / USE_PGXS / ENABLE_* settings
# to the recursive make invocations. Default to USE_PGXS=1 because
# out-of-tree is the standalone repo's primary path; in-tree builds
# happen when these directories are copied into a postgres source
# tree (see scripts/install-into-contrib.sh).
USE_PGXS ?= 1

.PHONY: all install install-test-modules install-all check clean

all:
	@for d in $(ALL_DIRS); do \
	    $(MAKE) -C $$d USE_PGXS=$(USE_PGXS) all || exit $$?; \
	done

install:
	@for d in $(PROD_DIRS); do \
	    $(MAKE) -C $$d USE_PGXS=$(USE_PGXS) install || exit $$?; \
	done

install-test-modules:
	@for d in $(TEST_DIRS); do \
	    $(MAKE) -C $$d USE_PGXS=$(USE_PGXS) install || exit $$?; \
	done

install-all: install install-test-modules

check:
	@for d in $(ALL_DIRS); do \
	    $(MAKE) -C $$d USE_PGXS=$(USE_PGXS) check || exit $$?; \
	done

clean:
	@for d in $(ALL_DIRS); do \
	    $(MAKE) -C $$d USE_PGXS=$(USE_PGXS) clean || exit $$?; \
	done
