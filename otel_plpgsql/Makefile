# otel_plpgsql/Makefile
#
# otel_plpgsql.c is built TWICE from this one source (see the file header
# comment there), the same way tests/otel_api_microbench is:
#
#   otel_plpgsql       VARIANT=main, -DHAVE_OTEL_API, against
#                      otel_api/otel_producer.h (the real API)
#   otel_plpgsql_stub  VARIANT=stub, against the otel_producer_stub.h +
#                      otel_types.h copies vendored into this directory
#                      (S0, "otel_api hooks compiled out")
#
# A bare `make ... install` (no VARIANT set) fans out into both variant
# sub-builds below, each in its own subdirectory of the out-of-tree build
# dir so the two compiles of the same .c file (different EXTENSION /
# MODULE_big / PG_CPPFLAGS) never collide over one .o/.so.  This keeps the
# single standard out-of-tree invocation used for every other extension in
# this repo working unchanged for this one too: build a separate out-of-tree
# directory per install prefix, with VPATH pointing at this source directory
# and PG_CONFIG at that prefix's pg_config, then `make ... install`.
#
# `installcheck` is NOT fanned to both variants: only the main variant has
# TAP_TESTS wired up (otel_plpgsql_stub has NO_INSTALLCHECK).  Run it from
# the main subdirectory once both variants are installed into the target
# prefix (the stub build is exercised by t/007_stub_build.pl, loaded as
# its own extension from inside the main variant's test suite).

MAKEFILE_PATH := $(abspath $(lastword $(MAKEFILE_LIST)))

ifndef VARIANT

.PHONY: all install installcheck clean
all install clean:
	mkdir -p main stub
	$(MAKE) -C main -f $(MAKEFILE_PATH) VARIANT=main $@
	$(MAKE) -C stub -f $(MAKEFILE_PATH) VARIANT=stub $@

installcheck:
	mkdir -p main
	$(MAKE) -C main -f $(MAKEFILE_PATH) VARIANT=main $@

else

OBJS = $(WIN32RES) otel_plpgsql.o
PGFILEDESC = "otel_plpgsql - OpenTelemetry tracing for PL/pgSQL functions and procedures"

# Lazily-expanded (`=`, not `:=`): $(srcdir) isn't defined until
# Makefile.global is pulled in by the PGXS include below, but PG_CPPFLAGS
# itself is only expanded later, when the compile rule actually runs (same
# pattern as otel_api/Makefile, otel_postgres_tracing/Makefile and
# tests/otel_api_microbench/Makefile).
ifeq ($(VARIANT),main)
MODULE_big = otel_plpgsql
EXTENSION = otel_plpgsql
DATA = otel_plpgsql--0.1.sql
# <otel_api/otel_producer.h> resolves from the otel_api SOURCE tree (this
# module's sibling directory), not any installed copy --- see
# otel_postgres_tracing/Makefile's comment on the same pattern.
PG_CPPFLAGS = -DHAVE_OTEL_API -I$(srcdir)/..
TAP_TESTS = 1
else
MODULE_big = otel_plpgsql_stub
EXTENSION = otel_plpgsql_stub
DATA = otel_plpgsql_stub--0.1.sql
NO_INSTALLCHECK = 1
endif

REGRESS =
ISOLATION =

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/otel_plpgsql
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif

endif # VARIANT
