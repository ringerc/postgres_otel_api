# tests/otel_api_microbench/Makefile
#
# otel_api_microbench.c is built TWICE from this one source (see the file
# header comment there):
#
#   otel_api_microbench       VARIANT=main, -DHAVE_OTEL_API, against
#                              otel_api/otel_producer.h (the real API)
#   otel_api_microbench_stub  VARIANT=stub, against the otel_producer_stub.h
#                              + otel_types.h copies in this directory
#                              (S0, "hooks compiled out")
#
# A bare `make ... install` (no VARIANT set) fans out into both variant
# sub-builds below, each in its own subdirectory of the out-of-tree build
# dir so the two compiles of the same .c file (different EXTENSION /
# MODULE_big / PG_CPPFLAGS) never collide over one .o/.so.  This keeps the
# single standard out-of-tree invocation used for every other extension in
# this repo (see AGENTS/build-and-install.md) working unchanged for this
# one too.

MAKEFILE_PATH := $(abspath $(lastword $(MAKEFILE_LIST)))

ifndef VARIANT

.PHONY: all install installcheck clean
all install installcheck clean:
	mkdir -p main stub
	$(MAKE) -C main -f $(MAKEFILE_PATH) VARIANT=main $@
	$(MAKE) -C stub -f $(MAKEFILE_PATH) VARIANT=stub $@

else

OBJS = $(WIN32RES) otel_api_microbench.o
PGFILEDESC = "otel_api_microbench - microbenchmark for otel_api producer API cost"

# Lazily-expanded (`=`, not `:=`): $(srcdir) isn't defined until
# Makefile.global is pulled in by the PGXS include below, but PG_CPPFLAGS
# itself is only expanded later, when the compile rule actually runs (same
# pattern as otel_api/Makefile and tests/otel_test_exporter/Makefile).
ifeq ($(VARIANT),main)
MODULE_big = otel_api_microbench
EXTENSION = otel_api_microbench
DATA = otel_api_microbench--0.1.sql
PG_CPPFLAGS = -DHAVE_OTEL_API -I$(srcdir)/../..
else
MODULE_big = otel_api_microbench_stub
EXTENSION = otel_api_microbench_stub
DATA = otel_api_microbench_stub--0.1.sql
endif

REGRESS =
ISOLATION =

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/otel_api_microbench
top_builddir = ../../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif

endif # VARIANT
