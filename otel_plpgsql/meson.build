# Copyright (c) 2026, PostgreSQL Global Development Group
#
# otel_plpgsql.c is built TWICE, into two separate extensions (see the
# file header comment in otel_plpgsql.c and the Makefile):
#
#   otel_plpgsql       -DHAVE_OTEL_API, against otel_api/otel_producer.h
#   otel_plpgsql_stub  against the otel_producer_stub.h + otel_types.h
#                      copies vendored into this directory (S0, "otel_api
#                      hooks compiled out")

otel_plpgsql_sources = files('otel_plpgsql.c')

if host_system == 'windows'
  otel_plpgsql_sources += rc_lib_gen.process(win32ver_rc, extra_args: [
    '--NAME', 'otel_plpgsql',
    '--FILEDESC', 'otel_plpgsql - OpenTelemetry tracing for PL/pgSQL functions and procedures',])
endif

# <otel_api/otel_producer.h> resolves from the otel_api SOURCE tree (this
# module's sibling directory), not any installed copy --- see
# contrib/otel_postgres_tracing/meson.build's comment on the same pattern.
otel_plpgsql = shared_module('otel_plpgsql',
  otel_plpgsql_sources,
  c_args: ['-DHAVE_OTEL_API', '-I' + meson.current_source_dir() / '..'],
  kwargs: contrib_mod_args,
)
contrib_targets += otel_plpgsql

otel_plpgsql_stub = shared_module('otel_plpgsql_stub',
  otel_plpgsql_sources,
  kwargs: contrib_mod_args,
)
contrib_targets += otel_plpgsql_stub

install_data(
  'otel_plpgsql.control',
  'otel_plpgsql--0.1.sql',
  kwargs: contrib_data_args,
)

install_data(
  'otel_plpgsql_stub.control',
  'otel_plpgsql_stub--0.1.sql',
  kwargs: contrib_data_args,
)
