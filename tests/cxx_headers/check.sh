#!/bin/sh
# Check that every otel_api header compiles as C++ (extensions such as
# pg_stat_ch are C++ and include these headers).
#   PG_CONFIG=/path/to/pg_config tests/cxx_headers/check.sh
# Also run via `make check-cxx-headers` at the top level.
set -u
here=$(cd "$(dirname "$0")" && pwd)
api=$here/../../otel_api
PG_CONFIG=${PG_CONFIG:-pg_config}
CXX=${CXX:-g++}
inc=$($PG_CONFIG --includedir-server) || exit 2
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT
rc=0
for h in "$api"/*.h; do
	n=$(basename "$h")
	printf '#include "postgres.h"\n#include "%s"\n' "$n" > "$tmp/t.cc"
	if $CXX -std=c++17 -fsyntax-only -I"$api" -I"$inc" "$tmp/t.cc" 2> "$tmp/err"; then
		echo "ok   $n"
	else
		echo "FAIL $n"; head -5 "$tmp/err"; rc=1
	fi
done
exit $rc
