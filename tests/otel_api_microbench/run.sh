#!/usr/bin/env bash
#
# run.sh --- drive otel_api_microbench across the states in
# ../otel_api_bench/README.md and print a CSV of the results.
#
# Expects otel_api, test_otel_exporter, otel_api_microbench and
# otel_api_microbench_stub to already be installed (see this directory's
# Makefile).  Uses ../otel_api_bench/lib.sh; its inputs (PG_CONFIG,
# OTEL_BENCH_SCRATCH, SERVER_CPUS) apply.  Set SERVER_CPUS to one CPU, so
# the measured backend always runs on the same core type.
#
# Env overrides (all optional):
#   ITERS         iterations per cell (default: 200000; large enough for
#                 >= 1s on every scenario at this cost scale)
#   REPEATS       repeats per cell (default: 3)
#   NATTRS_LIST   space-separated nattrs values (default: "0 4")
#   PERF_WINDOW   seconds `perf stat -p <backend pid>` is left attached for
#                 per cell (default: 3; must comfortably exceed one cell's
#                 wall time --- see ITERS above). perf is not signalled
#                 early: its own target pid is otherwise idle (blocked on
#                 the socket) before/after the measured call, so it
#                 accrues ~0 extra counted instructions outside the call,
#                 and letting it exit on its own avoids relying on signal
#                 delivery to a non-self pid (unreliable in some
#                 containerized/sandboxed environments).
#
# Output: CSV on stdout --- state,scenario,nattrs,rep,ns_per_iter,bytes_per_iter,instructions_per_iter
# Diagnostics go to stderr.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../otel_api_bench/lib.sh"

ITERS=${ITERS:-200000}
REPEATS=${REPEATS:-3}
NATTRS_LIST=${NATTRS_LIST:-"0 4"}
PERF_WINDOW=${PERF_WINDOW:-3}

bench_init otel_api_microbench
echo "# ITERS=$ITERS REPEATS=$REPEATS NATTRS_LIST=$NATTRS_LIST" >&2

mb_function_for_state() {
	case "$1" in
	S0) echo "otel_api_microbench_stub" ;;
	*) echo "otel_api_microbench" ;;
	esac
}

mb_extension_for_state() {
	mb_function_for_state "$1"
}

setup_extensions() {
	local state=$1
	local mb_ext
	mb_ext=$(mb_extension_for_state "$state")

	setup_state_extensions "$state"
	psql_q -c "CREATE EXTENSION IF NOT EXISTS $mb_ext" >&2
}

# ----------------------------------------------------------------------
# One (state,scenario,nattrs,rep) cell.  Runs the bench call over a
# persistent psql coprocess so `perf stat -p <backend pid>` (when
# available) brackets that one call.  perf is given a fixed PERF_WINDOW
# and is not signalled early to stop it (signal delivery to a non-self
# pid was found to be unreliable --- perf can hang indefinitely instead
# of exiting on SIGINT/SIGTERM); the backend is idle outside the call, so
# the extra bracketed time costs ~0 counted instructions.
# ----------------------------------------------------------------------
run_cell() {
	local state=$1 scenario=$2 nattrs=$3 rep=$4
	local fn
	fn=$(mb_function_for_state "$state")

	coproc PGCOPROC { "$BINDIR/psql" -h "$SOCKDIR" -p "$PGPORT" -U postgres -d postgres -X -t -A; }
	echo "SELECT pg_backend_pid();" >&"${PGCOPROC[1]}"
	local pid
	read -r pid <&"${PGCOPROC[0]}"

	perf_start "$pid" "$PERF_WINDOW"

	echo "SELECT ns_per_iter, bytes_per_iter FROM $fn('$scenario', $ITERS, $nattrs);" >&"${PGCOPROC[1]}"
	local result
	read -r result <&"${PGCOPROC[0]}"

	perf_finish

	echo "\\q" >&"${PGCOPROC[1]}" 2>/dev/null || true
	wait "$PGCOPROC_PID" 2>/dev/null || true

	local ns_per_iter bytes_per_iter instr_per_iter
	ns_per_iter=$(echo "$result" | cut -d'|' -f1)
	bytes_per_iter=$(echo "$result" | cut -d'|' -f2)

	instr_per_iter=""
	if [ -n "$PERF_INSTR" ]; then
		instr_per_iter=$(echo "scale=4; $PERF_INSTR/$ITERS" | bc)
	fi

	echo "$state,$scenario,$nattrs,$rep,$ns_per_iter,$bytes_per_iter,$instr_per_iter"
}

echo "state,scenario,nattrs,rep,ns_per_iter,bytes_per_iter,instructions_per_iter"

for state in S0 S1 S2 S3 S4 S5 S6; do
	echo "# state $state" >&2
	configure_state "$state"
	start_pg
	setup_extensions "$state"

	for scenario in empty root root_attrs; do
		for nattrs in $NATTRS_LIST; do
			for rep in $(seq 1 "$REPEATS"); do
				run_cell "$state" "$scenario" "$nattrs" "$rep"
			done
		done
	done

	stop_pg
done

echo "# done" >&2
