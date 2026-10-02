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
#   EXPORTER_LIB        shared library name (without .so) of the real OTLP
#                       exporter used by states S5o/S6o (default:
#                       postgres_otel_tracing_demo).  Must already be
#                       installed in the pkglibdir of PG_CONFIG's install.
#   OTELCOL             the OpenTelemetry Collector binary used by S5o/S6o
#                       (default: otelcol on PATH)
#   COLLECTOR_CPUS      taskset CPU list for the collector the harness
#                       starts (default: unpinned).  A cpuset-confined
#                       harness (e.g. run under cpu-run.sh) cannot taskset a
#                       child onto CPUs outside its own cpuset --
#                       sched_setaffinity fails with EINVAL.  In that case
#                       leave COLLECTOR_CPUS unset and instead run the
#                       collector yourself outside the harness's cpuset and
#                       set COLLECTOR_ENDPOINT / COLLECTOR_METRICS_URL (see
#                       collector_start below).
#   COLLECTOR_ENDPOINT, COLLECTOR_METRICS_URL
#                       when both are set, the harness treats the collector
#                       as externally managed: it uses these endpoints as-is
#                       and does not start or stop a collector of its own.
#                       Otherwise the harness starts/stops its own otelcol
#                       per S5o/S6o state and sets these itself.

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
	EXPORTER_LIB=${EXPORTER_LIB:-postgres_otel_tracing_demo}
	OTELCOL=${OTELCOL:-otelcol}
	COLLECTOR_CPUS=${COLLECTOR_CPUS:-}

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
	collector_stop
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
#   S0   consumer built against otel_producer_stub.h (harness picks the build)
#   S1   real consumer, otel_api not loaded
#   S2   otel_api loaded, no exporter
#   S3   null exporter, sampler always_off
#   S4   null exporter, traceidratio 0
#   S5   null exporter, traceidratio 0.01
#   S6   null exporter, traceidratio 1.0
#   S5o  real OTLP exporter (EXPORTER_LIB), traceidratio 0.01
#   S6o  real OTLP exporter (EXPORTER_LIB), traceidratio 1.0
# The null exporter is test_otel_exporter with capture = off.  S5o/S6o need
# collector_start to have set COLLECTOR_ENDPOINT first (see state_start).
configure_state() {
	local state=$1
	local extra_conf="$SCRATCH/state_extra.conf"
	: >"$extra_conf"
	# Sampling ratio of a new root in this state, for expected span counts.
	STATE_SAMPLE_RATIO=

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
		STATE_SAMPLE_RATIO=$ratio
		echo "$null_exporter" >>"$extra_conf"
		echo "otel_api.sampler = 'traceidratio'" >>"$extra_conf"
		echo "otel_api.sampler_arg = $ratio" >>"$extra_conf"
		;;
	S5o | S6o)
		: "${COLLECTOR_ENDPOINT:?configure_state $state needs COLLECTOR_ENDPOINT; call collector_start first}"
		local ratio
		case "$state" in
		S5o) ratio=0.01 ;;
		S6o) ratio=1.0 ;;
		esac
		STATE_SAMPLE_RATIO=$ratio
		echo "shared_preload_libraries = 'otel_api,$EXPORTER_LIB'" >>"$extra_conf"
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
# S5o/S6o load $EXPORTER_LIB as a plain shared-preloaded module (it has no
# control file and nothing to CREATE EXTENSION for); only otel_api needs the
# extension.
setup_state_extensions() {
	case "$1" in
	S2)
		psql_q -c "CREATE EXTENSION IF NOT EXISTS otel_api" >&2
		;;
	S3 | S4 | S5 | S6)
		psql_q -c "CREATE EXTENSION IF NOT EXISTS otel_api" >&2
		psql_q -c "CREATE EXTENSION IF NOT EXISTS test_otel_exporter" >&2
		;;
	S5o | S6o)
		psql_q -c "CREATE EXTENSION IF NOT EXISTS otel_api" >&2
		;;
	esac
}

# is_exporter_state <state>: true for the real-OTLP-exporter states.
is_exporter_state() {
	case "$1" in
	S5o | S6o) return 0 ;;
	*) return 1 ;;
	esac
}

# collector_start: start (or adopt) the OpenTelemetry Collector used by
# S5o/S6o.  If COLLECTOR_ENDPOINT and COLLECTOR_METRICS_URL are already set
# in the environment, treats the collector as externally managed and just
# uses them (see the COLLECTOR_CPUS note at the top of this file).
# Otherwise starts $OTELCOL itself, under taskset -c $COLLECTOR_CPUS, with a
# generated config: otlp/grpc receiver on a free port, nop exporter, and a
# Prometheus metrics reader on another free port.  Sets COLLECTOR_ENDPOINT
# (grpc URL for OTEL_EXPORTER_OTLP_ENDPOINT) and COLLECTOR_METRICS_URL (the
# metrics scrape URL).
collector_start() {
	if [ -n "${COLLECTOR_ENDPOINT:-}" ] && [ -n "${COLLECTOR_METRICS_URL:-}" ]; then
		COLLECTOR_MANAGED=0
		echo "# using externally managed collector endpoint=$COLLECTOR_ENDPOINT metrics=$COLLECTOR_METRICS_URL" >&2
		return
	fi
	COLLECTOR_MANAGED=1
	local grpc_port metrics_port conf
	grpc_port=$(find_free_port)
	metrics_port=$(find_free_port)
	COLLECTOR_ENDPOINT="http://127.0.0.1:$grpc_port"
	COLLECTOR_METRICS_URL="http://127.0.0.1:$metrics_port/metrics"
	conf="$SCRATCH/collector.yaml"
	cat >"$conf" <<EOF
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 127.0.0.1:$grpc_port
exporters:
  nop:
service:
  telemetry:
    metrics:
      readers:
        - pull:
            exporter:
              prometheus:
                host: 127.0.0.1
                port: $metrics_port
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [nop]
EOF
	on_cpus "$COLLECTOR_CPUS" "$OTELCOL" --config "$conf" >"$SCRATCH/collector.log" 2>&1 &
	COLLECTOR_PID=$!
	local waited=0
	until curl -sf "$COLLECTOR_METRICS_URL" >/dev/null 2>&1; do
		if ! kill -0 "$COLLECTOR_PID" 2>/dev/null; then
			echo "ERROR: $OTELCOL exited before coming up; see $SCRATCH/collector.log" >&2
			cat "$SCRATCH/collector.log" >&2
			exit 1
		fi
		sleep 0.1
		waited=$((waited + 100))
		if [ "$waited" -ge 10000 ]; then
			echo "ERROR: $OTELCOL did not come up within 10s; see $SCRATCH/collector.log" >&2
			exit 1
		fi
	done
	echo "# collector pid=$COLLECTOR_PID endpoint=$COLLECTOR_ENDPOINT metrics=$COLLECTOR_METRICS_URL" >&2
}

# collector_stop: stop a collector collector_start started itself.  A no-op
# for an externally managed collector, and clears COLLECTOR_ENDPOINT /
# COLLECTOR_METRICS_URL either way so the next state re-decides.
collector_stop() {
	if [ "${COLLECTOR_MANAGED:-0}" -eq 1 ] && [ -n "${COLLECTOR_PID:-}" ]; then
		kill "$COLLECTOR_PID" 2>/dev/null || true
		wait "$COLLECTOR_PID" 2>/dev/null || true
	fi
	COLLECTOR_PID=""
	COLLECTOR_ENDPOINT=""
	COLLECTOR_METRICS_URL=""
}

# collector_span_counts: read the collector's cumulative accepted/refused
# span counters.  Prints "accepted,refused" (both 0 if the collector has no
# counters yet).  Metric names carry a _total suffix on current otelcol
# (0.146); matched with or without it for older collectors.
collector_span_counts() {
	[ -n "${COLLECTOR_METRICS_URL:-}" ] || { echo "0,0"; return; }
	curl -sf "$COLLECTOR_METRICS_URL" 2>/dev/null | awk '
		$1 ~ /^otelcol_receiver_accepted_spans(_total)?\{/ { a += $2 }
		$1 ~ /^otelcol_receiver_refused_spans(_total)?\{/  { r += $2 }
		END { printf "%d,%d\n", a, r }'
}

# state_start <state>: bring up a cluster for <state> --- configure, start
# the collector when the state needs one, start the postmaster, and create
# the state's extensions.  Pairs with state_stop.
state_start() {
	local state=$1
	if is_exporter_state "$state"; then
		collector_start
		# The postmaster inherits these from pg_ctl's environment; it reads
		# them once per backend, on that backend's first span (lazy tokio
		# runtime + OTLP exporter init in $EXPORTER_LIB).
		export OTEL_TRACES_EXPORTER=otlp
		export OTEL_EXPORTER_OTLP_ENDPOINT="$COLLECTOR_ENDPOINT"
		export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
		BENCH_STATE_EXPORTING=1
	else
		unset OTEL_TRACES_EXPORTER OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_PROTOCOL
		# NOT COLLECTOR_METRICS_URL's own emptiness: a caller running its own
		# externally managed collector (see collector_start) sets
		# COLLECTOR_ENDPOINT/COLLECTOR_METRICS_URL once, for the whole
		# harness run, so they stay non-empty across every state.
		# pgbench_cell keys exporter accounting off this flag instead.
		BENCH_STATE_EXPORTING=0
	fi
	configure_state "$state"
	start_pg
	setup_state_extensions "$state"
}

# state_stop: stop the postmaster and, if state_start started one, the
# collector.
state_stop() {
	stop_pg
	collector_stop
	BENCH_STATE_EXPORTING=0
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

# thread_acct_start <pid>: begin background polling (every ~100ms) of the
# on-CPU time of <pid>'s child backend threads, split by thread name
# (/proc/<backend>/task/*/comm vs. .../schedstat field 1, ns).  Keeps the
# first and last sample seen per thread id, so a thread that exits mid-cell
# still contributes its last known value.  That misses up to one interval
# per thread, including the exporter's flush at backend exit.  Pairs with
# thread_acct_stop.
#
# The poller runs on CLIENT_CPUS, away from the server, and reads /proc
# with shell builtins: forking per thread per interval would load the CPUs
# being measured.
thread_acct_start() {
	local pmpid=$1
	THREAD_ACCT_FILE="$SCRATCH/thread_acct.$$"
	rm -f "$THREAD_ACCT_FILE" "$THREAD_ACCT_FILE.stop"
	(
		[ -n "$CLIENT_CPUS" ] && taskset -cp "$CLIENT_CPUS" "$BASHPID" >/dev/null
		declare -A first last comm
		while [ ! -f "$THREAD_ACCT_FILE.stop" ]; do
			for bpid in $(pgrep -P "$pmpid" 2>/dev/null); do
				for t in /proc/"$bpid"/task/*; do
					tid=${t##*/}
					read -r val _ <"$t/schedstat" 2>/dev/null || continue
					[ -n "$val" ] || continue
					read -r nm <"$t/comm" 2>/dev/null || nm="?"
					[ -n "${first[$tid]:-}" ] || first[$tid]=$val
					last[$tid]=$val
					comm[$tid]=$nm
				done
			done
			sleep 0.1
		done
		for tid in "${!last[@]}"; do
			echo "${comm[$tid]} ${first[$tid]} ${last[$tid]}"
		done >"$THREAD_ACCT_FILE"
	) &
	THREAD_ACCT_PID=$!
}

# thread_acct_stop: stop the poller and set THREAD_ACCT_EXP_NS /
# THREAD_ACCT_OTHER_NS --- the summed on-CPU delta (last - first sample) of
# threads named "pg-otel-demo" (the exporter's tokio worker) vs. every other
# backend thread, in ns, over the accounting window.
#
# Must be called as a plain statement, never as `$(thread_acct_stop)` /
# `<(thread_acct_stop)`: it calls `wait` on a pid backgrounded by
# thread_acct_start, and running that `wait` inside the extra subshell a
# command/process substitution forks can hang indefinitely when another
# background job (e.g. perf_start's perf) is also outstanding in the same
# shell --- the subshell's job table loses track of which process it's
# actually allowed to reap.  Checked: reproducible with perf_start running
# concurrently; without it, the hang doesn't appear.
thread_acct_stop() {
	THREAD_ACCT_EXP_NS=0
	THREAD_ACCT_OTHER_NS=0
	if [ -n "${THREAD_ACCT_PID:-}" ]; then
		touch "$THREAD_ACCT_FILE.stop"
		wait "$THREAD_ACCT_PID" 2>/dev/null || true
		if [ -f "$THREAD_ACCT_FILE" ]; then
			local out
			out=$(awk '
				{ delta = $3 - $2; if ($1 == "pg-otel-demo") e += delta; else o += delta }
				END { printf "%d %d\n", e+0, o+0 }
			' "$THREAD_ACCT_FILE")
			THREAD_ACCT_EXP_NS=${out%% *}
			THREAD_ACCT_OTHER_NS=${out##* }
		fi
		rm -f "$THREAD_ACCT_FILE" "$THREAD_ACCT_FILE.stop"
	fi
	THREAD_ACCT_PID=""
}

pgbench_run() {
	local script=$1 clients=$2 seconds=$3
	local jobs=$clients
	[ "$jobs" -gt 4 ] && jobs=4
	on_cpus "$CLIENT_CPUS" "$BINDIR/pgbench" -h "$SOCKDIR" -p "$PGPORT" -U postgres \
		-c "$clients" -j "$jobs" -M prepared -T "$seconds" -f "$script" postgres 2>&1
}

PGBENCH_CSV_HEADER="tps,lat_ms,cycles_per_tx,instr_per_tx,exporter_thread_ns_per_tx,other_thread_ns_per_tx,spans_accepted_per_tx,spans_refused_per_tx,spans_expected_per_tx,spans_dropped_per_tx"

# pgbench_cell <script file> <clients> <duration> [perf buffer] [expected
# spans per tx]: one measured pgbench run with perf attached to the
# postmaster, so every backend is counted, including any the workload
# spawns.  The window is duration + buffer (default 3 s), to let backends
# exit and fold in their counts.
#
# Also splits backend on-CPU time into the exporter's tokio worker threads
# (pg-otel-demo) and everything else (thread_acct_start/stop), in every
# state, so the exporter states can be compared with S6.  In an exporter
# state (S5o/S6o), also reads the collector's accepted/refused span counters
# before and after the cell (collector_span_counts), after a short wait past
# backend exit for the exporter's at-exit flush to land; given the spans per
# transaction of the workload when sampled, reports the expected count
# (scaled by the state's sampling ratio) and the shortfall.  The collector
# columns are empty for other states.
#
# Prints: tps,lat_ms,cycles_per_tx,instr_per_tx,exporter_thread_ns_per_tx,
# other_thread_ns_per_tx,spans_accepted_per_tx,spans_refused_per_tx,
# spans_expected_per_tx,spans_dropped_per_tx
pgbench_cell() {
	local script=$1 clients=$2 duration=$3 buffer=${4:-3} expected_spans=${5:-}
	local pmpid out tps lat_ms ntx cpt="" ipt=""
	local exporting=0 exp_ns=0 other_ns=0
	local acc_before=0 ref_before=0 acc_after=0 ref_after=0
	local ent="" ont="" sacc="" sref="" sexp="" sdrop=""

	[ "${BENCH_STATE_EXPORTING:-0}" -eq 1 ] && exporting=1

	pmpid=$(head -1 "$PGDATA/postmaster.pid")

	if [ "$exporting" -eq 1 ]; then
		IFS=, read -r acc_before ref_before <<<"$(collector_span_counts)"
	fi
	thread_acct_start "$pmpid"

	perf_start "$pmpid" "$((duration + buffer))"
	out=$(pgbench_run "$script" "$clients" "$duration")
	[ -n "$PERF_PID" ] && wait_for_backends_idle
	perf_finish

	thread_acct_stop
	exp_ns=$THREAD_ACCT_EXP_NS
	other_ns=$THREAD_ACCT_OTHER_NS
	if [ "$exporting" -eq 1 ]; then
		# The exporter flushes its batch at backend exit; give it a moment
		# to land at the collector before reading counters again.
		sleep 2
		IFS=, read -r acc_after ref_after <<<"$(collector_span_counts)"
	fi

	tps=$(echo "$out" | grep -oP '(?<=^tps = )[0-9.]+' | head -1)
	lat_ms=$(echo "$out" | grep -oP '(?<=^latency average = )[0-9.]+' | head -1)
	ntx=$(echo "$out" | grep -oP '(?<=number of transactions actually processed: )[0-9]+' | head -1)
	if [ -n "${ntx:-}" ] && [ "$ntx" -gt 0 ]; then
		[ -n "$PERF_CYCLES" ] && cpt=$(echo "scale=4; $PERF_CYCLES/$ntx" | bc)
		[ -n "$PERF_INSTR" ] && ipt=$(echo "scale=4; $PERF_INSTR/$ntx" | bc)
		ent=$(echo "scale=4; $exp_ns/$ntx" | bc)
		ont=$(echo "scale=4; $other_ns/$ntx" | bc)
		if [ "$exporting" -eq 1 ]; then
			sacc=$(echo "scale=6; ($acc_after - $acc_before)/$ntx" | bc)
			sref=$(echo "scale=6; ($ref_after - $ref_before)/$ntx" | bc)
			if [ -n "$expected_spans" ]; then
				sexp=$(echo "scale=6; $expected_spans * ${STATE_SAMPLE_RATIO:-1}" | bc)
				sdrop=$(echo "scale=6; $sexp - $sacc" | bc)
			fi
		fi
	fi
	if [ -z "${tps:-}" ] || [ -z "${lat_ms:-}" ]; then
		echo "WARNING: could not parse pgbench output for $script c=$clients:" >&2
		echo "$out" >&2
	fi
	echo "$tps,$lat_ms,$cpt,$ipt,$ent,$ont,$sacc,$sref,$sexp,$sdrop"
}
