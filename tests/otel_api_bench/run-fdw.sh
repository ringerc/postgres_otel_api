#!/usr/bin/env bash
#
# run-fdw.sh --- postgres_fdw overhead: pgbench against a loopback foreign
# server in the same instance, across the benchmark states.  See README.md.
#
# Inputs (environment), besides those in lib.sh (which also covers the
# exporter/collector inputs for S5o/S6o: EXPORTER_LIB, OTELCOL,
# COLLECTOR_CPUS, COLLECTOR_ENDPOINT/COLLECTOR_METRICS_URL):
#   FDW_SO       required: postgres_fdw.so built with otel_api tracing
#                (-DHAVE_OTEL_API)
#   FDW_STUB_SO  required: postgres_fdw.so built against the stub header
#                (S0)
#   DURATION     seconds per measured run (default: 30)
#   REPEATS      repeats per cell (default: 3)
#   STATES       default: "S0 S1 S2 S3 S4 S5 S6" (S5o/S6o: real OTLP
#                exporter + collector)
#   SCRIPTS      default: "select_point select_range update_point"
#   CLIENTS      default: "1 8"
#
# The install must already have otel_api, test_otel_exporter and
# postgres_fdw's SQL and control files, and (for S5o/S6o) $EXPORTER_LIB's
# .so in the pkglibdir.  The harness copies FDW_SO or FDW_STUB_SO into the
# pkglibdir for each state, and puts back what was there on exit.
#
# Output: CSV on stdout --- state,script,clients,rep,$PGBENCH_CSV_HEADER
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib.sh"

: "${FDW_SO:?set FDW_SO to the otel_api-enabled postgres_fdw.so}"
: "${FDW_STUB_SO:?set FDW_STUB_SO to the stub-header postgres_fdw.so}"
DURATION=${DURATION:-30}
REPEATS=${REPEATS:-3}
STATES=${STATES:-"S0 S1 S2 S3 S4 S5 S6"}
SCRIPTS=${SCRIPTS:-"select_point select_range update_point"}
CLIENTS=${CLIENTS:-"1 8"}

# Spans per transaction each script's foreign-table access produces when
# sampled, for the spans-dropped column.  Checked with
# otel_api.emit_spans_to_log against the postgres_fdw tracing port:
# select_point is one cursor open + one fetch
# (pg.fdw.cursor, pg.fdw.fetch); select_range and update_point aren't
# characterised yet, so they're left out (empty spans_expected_per_tx).
spans_per_tx() {
	case "$1" in
	select_point) echo 2 ;;
	*) echo "" ;;
	esac
}

bench_init otel_fdw_bench
echo "# DURATION=$DURATION REPEATS=$REPEATS STATES='$STATES' SCRIPTS='$SCRIPTS' CLIENTS='$CLIENTS'" >&2

INSTALLED_FDW_SO="$PKGLIBDIR/postgres_fdw.so"
BACKUP_FDW_SO="$SCRATCH/postgres_fdw.so.orig"
[ -f "$INSTALLED_FDW_SO" ] && cp "$INSTALLED_FDW_SO" "$BACKUP_FDW_SO"

bench_cleanup_hook() {
	if [ -f "$BACKUP_FDW_SO" ]; then
		cp "$BACKUP_FDW_SO" "$INSTALLED_FDW_SO"
	else
		rm -f "$INSTALLED_FDW_SO"
	fi
}

install_fdw_so() {
	case "$1" in
	S0) cp "$FDW_STUB_SO" "$INSTALLED_FDW_SO" ;;
	*) cp "$FDW_SO" "$INSTALLED_FDW_SO" ;;
	esac
}

setup_schema() {
	psql_q -c "CREATE EXTENSION IF NOT EXISTS postgres_fdw" >&2
	psql_q -c "CREATE SERVER loopback FOREIGN DATA WRAPPER postgres_fdw
	           OPTIONS (host '$SOCKDIR', port '$PGPORT', dbname 'postgres')" >&2
	psql_q -c "CREATE USER MAPPING FOR postgres SERVER loopback OPTIONS (user 'postgres')" >&2
	psql_q -c "CREATE TABLE t_local (id int PRIMARY KEY, v text)" >&2
	psql_q -c "INSERT INTO t_local SELECT i, 'v' || i FROM generate_series(1, 100000) i" >&2
	psql_q -c "CREATE FOREIGN TABLE ft (id int, v text) SERVER loopback
	           OPTIONS (table_name 't_local', fetch_size '100')" >&2
	psql_q -c "ANALYZE t_local" >&2
}

echo "state,script,clients,rep,$PGBENCH_CSV_HEADER"

install_fdw_so S1
configure_state S1
start_pg
setup_schema
stop_pg

for state in $STATES; do
	echo "# state $state" >&2
	install_fdw_so "$state"
	state_start "$state"

	for script in $SCRIPTS; do
		expected=$(spans_per_tx "$script")
		for clients in $CLIENTS; do
			# Start every cell from the same table. update_point moves rows
			# out of id order, so later select_range scans touch more heap
			# pages. VACUUM FULL keeps the physical order; CLUSTER restores
			# id order.
			psql_q -c "CLUSTER t_local USING t_local_pkey" -c "ANALYZE t_local" -c "CHECKPOINT" >&2
			echo "# $state/$script c=$clients: warm-up" >&2
			pgbench_run "$SCRIPT_DIR/scripts/$script.sql" "$clients" 5 >&2 || true

			for rep in $(seq 1 "$REPEATS"); do
				echo "$state,$script,$clients,$rep,$(pgbench_cell "$SCRIPT_DIR/scripts/$script.sql" "$clients" "$DURATION" 3 "$expected")"
			done
		done
	done

	state_stop
done

echo "# done" >&2
