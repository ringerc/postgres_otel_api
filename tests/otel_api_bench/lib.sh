# lib.sh --- shared code for the otel_api overhead benchmark harnesses.
#
# Source it from a harness script, then call bench_init.  Provides a
# throwaway cluster, the benchmark states (S0-S6), perf counting and a
# pgbench cell runner.  See README.md in this directory.
#
# Inputs (environment):
#   PG_CONFIG           pg_config of the install to test (default: the one
#                       on PATH)
#   OTEL_BENCH_SCRATCH  required: a directory on a real disk.  Each run
#                       makes its own subdirectory there.  Not tmpfs: it
#                       hides I/O costs.
#   SERVER_CPUS         taskset CPU list for the postmaster and its
#                       backends (default: unpinned)
#   CLIENT_CPUS         taskset CPU list for pgbench (default: unpinned)

BENCH_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# On hybrid CPUs `perf stat -x,` prints one line per PMU for each event,
# e.g. `904870,,cpu_atom/instructions/,...` and `<not counted>,,cpu_core/
# instructions/,...`.  Sum the counted values across PMUs, treating
# "<not counted>" / "<not supported>" as 0.
#
# Usage: sum_perf_csv_event <perf_stat_csv_file> <event_name>
# Prints the sum, or nothing if nothing was counted.
sum_perf_csv_event() {
	local file=$1 event=$2
	awk -F',' -v ev="$event" '
		$3 ~ ("(^|/)" ev "(/|$)") {
			val = $1
			gsub(/,/, "", val)
			if (val ~ /^[0-9]+$/) { sum += val; have = 1 }
		}
		END { if (have) print sum }
	' "$file"
}

# Prefix a command with taskset when a CPU list is given.
on_cpus() {
	local cpus=$1
	shift
	if [ -n "$cpus" ]; then
		taskset -c "$cpus" "$@"
	else
		"$@"
	fi
}

find_free_port() {
	python3 - <<'EOF'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
EOF
}

# bench_init <name>: resolve the install, make a scratch dir and a fresh
# cluster, and check perf.  Sets BINDIR, PKGLIBDIR, SCRATCH, PGDATA,
# SOCKDIR, PGPORT, PERF_OK.  A harness can define bench_cleanup_hook,
# which runs on exit before the cluster is removed.
bench_init() {
	local name=$1

	PG_CONFIG=${PG_CONFIG:-$(command -v pg_config || true)}
	: "${PG_CONFIG:?set PG_CONFIG, or put pg_config on PATH}"
	: "${OTEL_BENCH_SCRATCH:?set OTEL_BENCH_SCRATCH to a directory on a real disk (not tmpfs)}"
	SERVER_CPUS=${SERVER_CPUS:-}
	CLIENT_CPUS=${CLIENT_CPUS:-}

	BINDIR=$("$PG_CONFIG" --bindir)
	PKGLIBDIR=$("$PG_CONFIG" --pkglibdir)
	SCRATCH=$(mktemp -d "$OTEL_BENCH_SCRATCH/$name.XXXXXX")
	PGDATA="$SCRATCH/pgdata"
	# Unix socket paths are limited to about 107 bytes, so the socket goes
	# in a short directory under /tmp, not under $SCRATCH.
	SOCKDIR=$(mktemp -d /tmp/otel-bench-sock.XXXXXX)
	PGPORT=$(find_free_port)

	PERF_OK=0
	if command -v perf >/dev/null 2>&1; then
		local paranoid
		paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 999)
		if [ "$paranoid" -le 1 ]; then
			PERF_OK=1
		else
			echo "WARNING: kernel.perf_event_paranoid=$paranoid (need <= 1); perf columns will be empty" >&2
		fi
	else
		echo "WARNING: perf not found on PATH; perf columns will be empty" >&2
	fi

	echo "# PG_CONFIG=$PG_CONFIG SCRATCH=$SCRATCH port=$PGPORT SERVER_CPUS='$SERVER_CPUS' CLIENT_CPUS='$CLIENT_CPUS'" >&2

	trap bench_cleanup EXIT

	"$BINDIR/initdb" -D "$PGDATA" -U postgres --auth=trust --no-sync >&2
	cat >>"$PGDATA/postgresql.conf" <<EOF
port = $PGPORT
listen_addresses = ''
unix_socket_directories = '$SOCKDIR'
log_min_messages = warning
EOF
}

bench_cleanup() {
	if [ -f "$PGDATA/postmaster.pid" ]; then
		"$BINDIR/pg_ctl" -D "$PGDATA" -m fast stop >&2 2>&1 || true
	fi
	if declare -F bench_cleanup_hook >/dev/null; then
		bench_cleanup_hook || true
	fi
	rm -rf "$SOCKDIR"
	rm -rf "$PGDATA"	# keep the logs in $SCRATCH, not the cluster
}

psql_q() {
	"$BINDIR/psql" -h "$SOCKDIR" -p "$PGPORT" -U postgres -d postgres -X -t -A "$@"
}

# Backends inherit the postmaster's affinity.
start_pg() {
	on_cpus "$SERVER_CPUS" "$BINDIR/pg_ctl" -D "$PGDATA" -l "$SCRATCH/server.log" -w start >&2
}

stop_pg() {
	"$BINDIR/pg_ctl" -D "$PGDATA" -m fast -w stop >&2 2>/dev/null || true
}

# configure_state <state>: write the state's shared_preload_libraries and
# GUCs to an included file, replacing the previous state's.  States (also
# in README.md):
#   S0  consumer built against otel_producer_stub.h (harness picks the build)
#   S1  real consumer, otel_api not loaded
#   S2  otel_api loaded, no exporter
#   S3  null exporter, sampler always_off
#   S4  null exporter, traceidratio 0
#   S5  null exporter, traceidratio 0.01
#   S6  null exporter, traceidratio 1.0
# The null exporter is test_otel_exporter with capture = off.
configure_state() {
	local state=$1
	local extra_conf="$SCRATCH/state_extra.conf"
	: >"$extra_conf"

	local null_exporter="shared_preload_libraries = 'otel_api,test_otel_exporter'
test_otel_exporter.capture = off"

	case "$state" in
	S0 | S1) ;;
	S2)
		echo "shared_preload_libraries = 'otel_api'" >>"$extra_conf"
		echo "otel_api.emit_spans_to_log = off" >>"$extra_conf"
		;;
	S3)
		echo "$null_exporter" >>"$extra_conf"
		echo "otel_api.sampler = 'always_off'" >>"$extra_conf"
		;;
	S4 | S5 | S6)
		local ratio
		case "$state" in
		S4) ratio=0 ;;
		S5) ratio=0.01 ;;
		S6) ratio=1.0 ;;
		esac
		echo "$null_exporter" >>"$extra_conf"
		echo "otel_api.sampler = 'traceidratio'" >>"$extra_conf"
		echo "otel_api.sampler_arg = $ratio" >>"$extra_conf"
		;;
	*)
		echo "unknown state $state" >&2
		exit 1
		;;
	esac

	grep -v '^include_if_exists' "$PGDATA/postgresql.conf" >"$PGDATA/postgresql.conf.new" || true
	mv "$PGDATA/postgresql.conf.new" "$PGDATA/postgresql.conf"
	echo "include_if_exists = '$extra_conf'" >>"$PGDATA/postgresql.conf"
}

# setup_state_extensions <state>: CREATE EXTENSION what the state loads.
setup_state_extensions() {
	case "$1" in
	S2)
		psql_q -c "CREATE EXTENSION IF NOT EXISTS otel_api" >&2
		;;
	S3 | S4 | S5 | S6)
		psql_q -c "CREATE EXTENSION IF NOT EXISTS otel_api" >&2
		psql_q -c "CREATE EXTENSION IF NOT EXISTS test_otel_exporter" >&2
		;;
	esac
}

# perf_start <pid> <seconds>: count cycles and instructions of <pid> for a
# fixed window.  Children forked after attach are included: their counts
# fold into <pid>'s when they exit.  perf is never signalled to stop:
# `perf stat -p` can hang on SIGINT/SIGTERM, so let its own timer end it.
# Sets PERF_PID and PERF_OUT (empty PERF_PID if perf is unavailable).
perf_start() {
	local pid=$1 seconds=$2
	PERF_PID=""
	PERF_OUT="$SCRATCH/perf_out.$$"
	if [ "$PERF_OK" -eq 1 ]; then
		perf stat -x, -e cycles,instructions -p "$pid" -o "$PERF_OUT" -- sleep "$seconds" >&2 2>&1 &
		PERF_PID=$!
		sleep 0.3
	fi
}

# perf_finish: wait for the perf window to end.  Sets PERF_CYCLES and
# PERF_INSTR (empty if not counted).
perf_finish() {
	PERF_CYCLES=""
	PERF_INSTR=""
	if [ -n "$PERF_PID" ]; then
		wait "$PERF_PID" 2>/dev/null || true
		if [ -f "$PERF_OUT" ]; then
			PERF_CYCLES=$(sum_perf_csv_event "$PERF_OUT" cycles)
			PERF_INSTR=$(sum_perf_csv_event "$PERF_OUT" instructions)
		fi
	fi
	rm -f "$PERF_OUT"
}

# Wait up to 5 s for client backends (other than the one asking) to exit,
# so their counts fold into the postmaster's before the perf window ends.
wait_for_backends_idle() {
	local waited=0 n
	while [ "$waited" -lt 5000 ]; do
		n=$(psql_q -c "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()" 2>/dev/null || echo "")
		if [ "${n:-0}" -eq 0 ] 2>/dev/null; then
			return 0
		fi
		sleep 0.1
		waited=$((waited + 100))
	done
	echo "WARNING: client backends still present after ${waited}ms wait" >&2
}

pgbench_run() {
	local script=$1 clients=$2 seconds=$3
	local jobs=$clients
	[ "$jobs" -gt 4 ] && jobs=4
	on_cpus "$CLIENT_CPUS" "$BINDIR/pgbench" -h "$SOCKDIR" -p "$PGPORT" -U postgres \
		-c "$clients" -j "$jobs" -M prepared -T "$seconds" -f "$script" postgres 2>&1
}

PGBENCH_CSV_HEADER="tps,lat_ms,cycles_per_tx,instr_per_tx"

# pgbench_cell <script file> <clients> <duration> [perf buffer]: one
# measured pgbench run with perf attached to the postmaster, so every
# backend is counted, including any the workload spawns.  The window is
# duration + buffer (default 3 s), to let backends exit and fold in their
# counts.  Prints tps,lat_ms,cycles_per_tx,instr_per_tx.
pgbench_cell() {
	local script=$1 clients=$2 duration=$3 buffer=${4:-3}
	local pmpid out tps lat_ms ntx cpt="" ipt=""

	pmpid=$(head -1 "$PGDATA/postmaster.pid")
	perf_start "$pmpid" "$((duration + buffer))"
	out=$(pgbench_run "$script" "$clients" "$duration")
	[ -n "$PERF_PID" ] && wait_for_backends_idle
	perf_finish

	tps=$(echo "$out" | grep -oP '(?<=^tps = )[0-9.]+' | head -1)
	lat_ms=$(echo "$out" | grep -oP '(?<=^latency average = )[0-9.]+' | head -1)
	ntx=$(echo "$out" | grep -oP '(?<=number of transactions actually processed: )[0-9]+' | head -1)
	if [ -n "${ntx:-}" ] && [ "$ntx" -gt 0 ]; then
		[ -n "$PERF_CYCLES" ] && cpt=$(echo "scale=4; $PERF_CYCLES/$ntx" | bc)
		[ -n "$PERF_INSTR" ] && ipt=$(echo "scale=4; $PERF_INSTR/$ntx" | bc)
	fi
	if [ -z "${tps:-}" ] || [ -z "${lat_ms:-}" ]; then
		echo "WARNING: could not parse pgbench output for $script c=$clients:" >&2
		echo "$out" >&2
	fi
	echo "$tps,$lat_ms,$cpt,$ipt"
}
