#!/usr/bin/env bash
# HTTP parse throughput: package-http vs Rust httparse + matchit (H10 of
# plans/2026-09-06-http-parse.md).
#
# Both sides do the same work per request -- frame it, select the route and
# bind its parameters, read three named headers -- and both print a checksum
# summing every piece's length plus the matched route's index. A checksum
# mismatch means they did not do the same work and the row is meaningless.
#
#   tools/http-bench/run.sh [n_requests]
#
# The Roc side is built WITHOUT --no-cache: an app importing both Http and
# Route panics the compiler on the clean path
# (upstream/2026-09-06-two-modules-folded-constant).
set -euo pipefail
cd "$(dirname "$0")/../.."

N="${1:-1000}"
FIX="testdata/http_requests.txt"
RUST_ITERS=200
REPS=5   # a freshly built binary reads ~80% slow on its first run

echo "generating ${N} requests..."
python3 tools/http-bench/gen.py "$FIX" "$N"

echo "building rust (httparse + matchit)..."
( cd tools/http-bench/rust && cargo build --release --quiet )

echo "building roc (package-http)..."
# `roc build` exits nonzero when it reports a warning, so `set -e` cannot judge
# it; the binary existing and being newer than the source is the check
BIN="./http_bench_tmp"
rm -f "$BIN"
roc build --output="$BIN" examples/http_bench.roc >/dev/null 2>&1 || true
[ -x "$BIN" ] || { echo "roc build failed:"; roc build --output="$BIN" examples/http_bench.roc; exit 1; }

# min of the ns column per id
mins() { awk -F, '{ if (!($1 in m)) ord[++n]=$1; if (!($1 in m) || $2+0 < m[$1]) m[$1]=$2+0; c[$1]=$3; k[$1]=$4 } END { for (i=1;i<=n;i++) { id=ord[i]; print id "," m[id] "," c[id] "," k[id] } }'; }

echo "running..."
"$BIN" "$FIX" >/dev/null
for _ in $(seq 1 $REPS); do "$BIN" "$FIX"; done | mins > /tmp/hb_roc.csv
./tools/http-bench/rust/target/release/http-bench "$FIX" "$RUST_ITERS" >/dev/null
for _ in $(seq 1 $REPS); do ./tools/http-bench/rust/target/release/http-bench "$FIX" "$RUST_ITERS"; done | mins > /tmp/hb_rust.csv

REQS=$(awk -F, '$1=="rust"{print $3}' /tmp/hb_rust.csv)
echo
echo "${REQS} requests   |   ns per request, cumulative"
echo "roc_frame includes every header: framing parses them all in one pass (H2, reversed)"
awk -F, -v reqs="$REQS" '
FILENAME==ARGV[1] { roc[$1]=$2; rk[$1]=$4; next }
{ rust_ns=$2; rust_k=$4 }
END {
  printf "%-24s %12s %12s\n", "stage", "ns/req", "checksum"
  split("roc_split roc_frame roc_route roc_headers", s, " ")
  for (i=1;i<=4;i++) printf "%-24s %12.1f %12s\n", s[i], roc[s[i]]/reqs, rk[s[i]]
  printf "%-24s %12.1f %12s\n", "rust (httparse+matchit)", rust_ns/reqs, rust_k
  print ""
  if (rk["roc_headers"] == rust_k) printf "checksums agree; roc/rust = %.1fx\n", roc["roc_headers"]/rust_ns
  else print "CHECKSUM MISMATCH -- the two sides did not do the same work"
}' /tmp/hb_roc.csv /tmp/hb_rust.csv
rm -f "$BIN"
