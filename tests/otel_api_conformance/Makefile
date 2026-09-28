# tests/otel_api_conformance/Makefile
#
# Conformance test extension for the otel_api MAJOR 3 producer/exporter/
# internal API.  It is simultaneously an exporter (captures every emitted
# span plus a sampler hook) and a producer (SQL-callable scenarios that
# exercise otel_span_start/set/end and friends), so that a single TAP
# suite can drive a scenario and inspect what it produced.
#
# otel_api_conformance_stub_check.c is a second translation unit compiled
# against otel_producer_stub.h instead of otel_producer.h, to prove the
# stub header stays in step with the real one.  It calls every producer
# entry point once; all stub functions are static inline, so it links
# into the same .so with no symbol clashes.
#
# Built like a normal PGXS extension.  Not installed by `make install` at
# the top level (test-only), matching tests/otel_test_exporter.

MODULE_big = otel_api_conformance
OBJS = \
	$(WIN32RES) \
	otel_api_conformance.o \
	otel_api_conformance_stub_check.o
PGFILEDESC = "otel_api_conformance - conformance test extension for otel_api"

EXTENSION = otel_api_conformance
DATA = otel_api_conformance--0.1.sql

TAP_TESTS = 1

# See otel_api/Makefile for the rationale: empty REGRESS / ISOLATION make
# PGXS's installcheck a no-op for the SQL-regression and isolation
# runners (which can't reconfigure shared_preload_libraries), while
# leaving NO_INSTALLCHECK unset so prove_installcheck still runs the TAP
# suite under t/.
REGRESS =
ISOLATION =

ifdef USE_PGXS
PG_CONFIG = pg_config
PG_CPPFLAGS = -I$(shell $(PG_CONFIG) --includedir-server)/extension \
	-I$(srcdir)/../../otel_api
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
PG_CPPFLAGS = -I$(top_srcdir)/contrib -I$(top_srcdir)/contrib/otel_api
subdir = src/test/modules/otel_api_conformance
top_builddir = ../../../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
