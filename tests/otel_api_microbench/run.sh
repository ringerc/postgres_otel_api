#!/usr/bin/env bash
#
# run.sh --- drive otel_api_microbench across the states in
# docs/plans/otel-overhead-bench.md ("States" table) and print a CSV of
# the results.
#
# Expects otel_api, test_otel_exporter, otel_api_microbench and
# otel_api_microbench_stub to already be installed into $PREFIX (see
# AGENTS/build-and-install.md and this directory's Makefile).
#
# Env overrides (all optional):
#   ROOT          repo root (default: inferred from this script's path)
#   PREFIX        install prefix to test (default: $ROOT/pgsql-bench)
#   OTEL_BENCH_SCRATCH  required: a directory on a real disk.  Each run makes
#                       its own subdirectory there.  Not /tmp: tmpfs hides
#                       I/O costs.
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
ROOT=${ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}
PREFIX=${PREFIX:-$ROOT/pgsql-bench}
: "${OTEL_BENCH_SCRATCH:?set OTEL_BENCH_SCRATCH to a directory on a real disk (not tmpfs)}"
SCRATCH=$(mktemp -d "$OTEL_BENCH_SCRATCH/otel_api_microbench.XXXXXX")
ITERS=${ITERS:-200000}
REPEATS=${REPEATS:-3}
NATTRS_LIST=${NATTRS_LIST:-"0 4"}
PERF_WINDOW=${PERF_WINDOW:-3}

source "$ROOT/bench/perf-csv-lib.sh"

PGDATA="$SCRATCH/pgdata"
PSQL="$PREFIX/bin/psql"
INITDB="$PREFIX/bin/initdb"
PG_CTL="$PREFIX/bin/pg_ctl"

# Unix-domain socket paths are capped at ~107 bytes; the scratchpad dir's
# own path is usually already close to that limit, so the socket itself
# goes in a short mktemp'd dir under /tmp rather than under $SCRATCH.
SOCKDIR=$(mktemp -d /tmp/otel-mb-sock.XXXXXX)

echo "# PREFIX=$PREFIX SCRATCH=$SCRATCH ITERS=$ITERS REPEATS=$REPEATS NATTRS_LIST=$NATTRS_LIST" >&2

# ----------------------------------------------------------------------
# perf availability --- kernel.perf_event_paranoid <= 1 is needed to
# attach `perf stat` to another process as a non-root user.  Detect once;
# if unavailable, leave the instructions_per_iter column empty rather
# than failing the whole run.
# ----------------------------------------------------------------------
PERF_OK=0
if command -v perf >/dev/null 2>&1; then
	paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 999)
	if [ "$paranoid" -le 1 ]; then
		PERF_OK=1
	else
		echo "WARNING: kernel.perf_event_paranoid=$paranoid (need <= 1); instructions_per_iter will be empty" >&2
	fi
else
	echo "WARNING: perf not found on PATH; instructions_per_iter will be empty" >&2
fi

find_free_port() {
	python3 - <<'EOF'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
EOF
}

PGPORT=$(find_free_port)
echo "# using port $PGPORT" >&2

cleanup() {
	if [ -f "$PGDATA/postmaster.pid" ]; then
		"$PG_CTL" -D "$PGDATA" -m fast stop >&2 2>&1 || true
	fi
	rm -rf "$SOCKDIR"
	rm -rf "$PGDATA"	# keep the logs in $SCRATCH, not the cluster
}
trap cleanup EXIT

"$INITDB" -D "$PGDATA" -U postgres --auth=trust --no-sync >&2

cat >>"$PGDATA/postgresql.conf" <<EOF
port = $PGPORT
listen_addresses = ''
unix_socket_directories = '$SOCKDIR'
log_min_messages = warning
EOF

psql_q() {
	"$PSQL" -h "$SOCKDIR" -p "$PGPORT" -U postgres -d postgres -X -t -A "$@"
}

start_pg() {
	# Pin the postmaster (and thus its forked backends, which inherit
	# affinity) to a single P-core so the measured backend's instruction
	# count isn't diluted by running on an E-core/LP-E-core.
	taskset -c 2 "$PG_CTL" -D "$PGDATA" -l "$SCRATCH/server.log" -w start >&2
}

stop_pg() {
	"$PG_CTL" -D "$PGDATA" -m fast -w stop >&2 2>/dev/null || true
}

# ----------------------------------------------------------------------
# One row per state: shared_preload_libraries, extra GUCs, which
# microbench extension/function to call, and whether otel_api /
# test_otel_exporter should be CREATE EXTENSIONed.
#
# S3 and S4 take the same code path at present (see otel-overhead-bench.md,
# postgres-cdq.23): any registered exporter makes recording_possible true,
# so S3 (sampler=always_off) and S4 (traceidratio, arg=0) are both expected
# to come out close to each other and well above S2.
# ----------------------------------------------------------------------
configure_state() {
	local state=$1
	local extra_conf="$SCRATCH/state_extra.conf"
	: >"$extra_conf"

	case "$state" in
	S0 | S1)
		# No preload at all.  S0 uses the stub module (hooks compiled
		# out at build time); S1 uses the real module but otel_api
		# isn't in shared_preload_libraries, so otel_producer_api()
		# resolves to NULL at runtime.
		;;
	S2)
		echo "shared_preload_libraries = 'otel_api'" >>"$extra_conf"
		echo "otel_api.emit_spans_to_log = off" >>"$extra_conf"
		;;
	S3)
		echo "shared_preload_libraries = 'otel_api,test_otel_exporter'" >>"$extra_conf"
		echo "otel_api.sampler = 'always_off'" >>"$extra_conf"
		echo "test_otel_exporter.capture = off" >>"$extra_conf"
		;;
	S4)
		echo "shared_preload_libraries = 'otel_api,test_otel_exporter'" >>"$extra_conf"
		echo "otel_api.sampler = 'traceidratio'" >>"$extra_conf"
		echo "otel_api.sampler_arg = 0" >>"$extra_conf"
		echo "test_otel_exporter.capture = off" >>"$extra_conf"
		;;
	S5)
		echo "shared_preload_libraries = 'otel_api,test_otel_exporter'" >>"$extra_conf"
		echo "otel_api.sampler = 'traceidratio'" >>"$extra_conf"
		echo "otel_api.sampler_arg = 0.01" >>"$extra_conf"
		echo "test_otel_exporter.capture = off" >>"$extra_conf"
		;;
	S6)
		echo "shared_preload_libraries = 'otel_api,test_otel_exporter'" >>"$extra_conf"
		echo "otel_api.sampler = 'traceidratio'" >>"$extra_conf"
		echo "otel_api.sampler_arg = 1.0" >>"$extra_conf"
		echo "test_otel_exporter.capture = off" >>"$extra_conf"
		;;
	*)
		echo "unknown state $state" >&2
		exit 1
		;;
	esac

	# Replace any previous state's extra config block.
	grep -v '^include_if_exists' "$PGDATA/postgresql.conf" >"$PGDATA/postgresql.conf.new" || true
	mv "$PGDATA/postgresql.conf.new" "$PGDATA/postgresql.conf"
	echo "include_if_exists = '$extra_conf'" >>"$PGDATA/postgresql.conf"
}

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

	case "$state" in
	S2)
		psql_q -c "CREATE EXTENSION IF NOT EXISTS otel_api" >&2
		;;
	S3 | S4 | S5 | S6)
		psql_q -c "CREATE EXTENSION IF NOT EXISTS otel_api" >&2
		psql_q -c "CREATE EXTENSION IF NOT EXISTS test_otel_exporter" >&2
		;;
	esac
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

	coproc PGCOPROC { "$PSQL" -h "$SOCKDIR" -p "$PGPORT" -U postgres -d postgres -X -t -A; }
	echo "SELECT pg_backend_pid();" >&"${PGCOPROC[1]}"
	local pid
	read -r pid <&"${PGCOPROC[0]}"

	local perf_out="$SCRATCH/perf_out.$$"
	local perf_pid=""
	if [ "$PERF_OK" -eq 1 ]; then
		perf stat -x, -e instructions -p "$pid" -o "$perf_out" -- sleep "$PERF_WINDOW" >&2 2>&1 &
		perf_pid=$!
		sleep 0.2
	fi

	echo "SELECT ns_per_iter, bytes_per_iter FROM $fn('$scenario', $ITERS, $nattrs);" >&"${PGCOPROC[1]}"
	local result
	read -r result <&"${PGCOPROC[0]}"

	if [ -n "$perf_pid" ]; then
		wait "$perf_pid" 2>/dev/null || true
	fi

	echo "\\q" >&"${PGCOPROC[1]}" 2>/dev/null || true
	wait "$PGCOPROC_PID" 2>/dev/null || true

	local ns_per_iter bytes_per_iter instr instr_per_iter
	ns_per_iter=$(echo "$result" | cut -d'|' -f1)
	bytes_per_iter=$(echo "$result" | cut -d'|' -f2)

	instr_per_iter=""
	if [ -n "$perf_pid" ] && [ -f "$perf_out" ]; then
		instr=$(sum_perf_csv_event "$perf_out" "instructions")
		if [ -n "${instr:-}" ]; then
			instr_per_iter=$(echo "scale=4; $instr/$ITERS" | bc)
		fi
	fi
	rm -f "$perf_out"

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
