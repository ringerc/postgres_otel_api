#!/usr/bin/env bash
#
# run-plpgsql.sh --- otel_plpgsql overhead: pgbench's TPC-B-like
# transaction as a plpgsql function calling four helpers, across the
# benchmark states.  Local work only, no IPC.  See README.md.
#
# Spans per transaction: 5 pg.plpgsql.function spans; with
# otel_plpgsql.trace_statements on, also 18 pg.plpgsql.stmt spans (each
# function body block, its statements, and its implicit RETURN): 23 in all.
#
# Inputs (environment), besides those in lib.sh:
#   SCALE        pgbench scale factor (default: 50)
#   DURATION     seconds per measured run (default: 30)
#   REPEATS      repeats per cell (default: 3)
#   STATES       default: "S0 S1 S2 S3 S4 S5 S6"
#   STMT_SPANS   otel_plpgsql.trace_statements values to run (default: "on off")
#   CLIENTS      default: "1 8"
#
# The install must have otel_api, test_otel_exporter, otel_plpgsql and
# otel_plpgsql_stub.  synchronous_commit is off, so the commit's disk sync
# doesn't hide span costs.
#
# Output: CSV on stdout --- state,stmt_spans,clients,rep,tps,lat_ms,cycles_per_tx,instr_per_tx
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib.sh"

WORKLOAD_DIR="$SCRIPT_DIR/../../otel_plpgsql/bench"
SCALE=${SCALE:-50}
DURATION=${DURATION:-30}
REPEATS=${REPEATS:-3}
STATES=${STATES:-"S0 S1 S2 S3 S4 S5 S6"}
STMT_SPANS=${STMT_SPANS:-"on off"}
CLIENTS=${CLIENTS:-"1 8"}

bench_init otel_plpgsql_bench
echo "# SCALE=$SCALE DURATION=$DURATION REPEATS=$REPEATS STATES='$STATES' STMT_SPANS='$STMT_SPANS' CLIENTS='$CLIENTS'" >&2

# Loaded per backend, so the real and stub builds can be swapped between
# states without touching the states' shared_preload_libraries.
CONSUMER_CONF="$SCRATCH/consumer.conf"
cat >>"$PGDATA/postgresql.conf" <<EOF
synchronous_commit = off
include = '$CONSUMER_CONF'
EOF

consumer_for_state() {
	case "$1" in
	S0) echo otel_plpgsql_stub ;;
	*) echo otel_plpgsql ;;
	esac
}

configure_consumer() {
	echo "session_preload_libraries = '$(consumer_for_state "$1")'" >"$CONSUMER_CONF"
}

echo "state,stmt_spans,clients,rep,$PGBENCH_CSV_HEADER"

configure_consumer S1
configure_state S1
start_pg
"$BINDIR/pgbench" -h "$SOCKDIR" -p "$PGPORT" -U postgres -i -q -s "$SCALE" postgres >&2
psql_q -f "$WORKLOAD_DIR/tpcb_plpgsql.sql" >&2
stop_pg

for state in $STATES; do
	echo "# state $state" >&2
	configure_consumer "$state"
	configure_state "$state"
	start_pg
	setup_state_extensions "$state"

	for stmt in $STMT_SPANS; do
		for clients in $CLIENTS; do
			# Same starting point for every cell: drop the history rows and
			# the dead row versions the previous cell left.
			psql_q -c "TRUNCATE pgbench_history" -c "VACUUM (ANALYZE)" -c "CHECKPOINT" >&2
			export PGOPTIONS="-c otel_plpgsql.trace_statements=$stmt"
			echo "# $state stmt_spans=$stmt c=$clients: warm-up" >&2
			pgbench_run "$WORKLOAD_DIR/tpcb_plpgsql.pgbench" "$clients" 5 >&2 || true

			for rep in $(seq 1 "$REPEATS"); do
				echo "$state,$stmt,$clients,$rep,$(pgbench_cell "$WORKLOAD_DIR/tpcb_plpgsql.pgbench" "$clients" "$DURATION")"
			done
			unset PGOPTIONS
		done
	done

	stop_pg
done

echo "# done" >&2
