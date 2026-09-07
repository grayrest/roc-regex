#!/usr/bin/env bash
# Throughput comparison: this Roc engine vs the vendored Rust `regex` crate,
# on an identical haystack, matching identical patterns (parity is checked by
# comparing match counts — a "DIFF" in the last column invalidates that row).
#
#   tools/bench/run.sh [haystack_bytes]
#
# Timing is in-process (per-pattern), so process startup and file I/O are
# excluded and only match throughput is measured. The regex is compiled once,
# before the loop, in both languages.
set -euo pipefail
cd "$(dirname "$0")/../.."

BYTES="${1:-262144}"
HAY="testdata/bench_haystack.txt"
ROC_ITERS=20      # baked into examples/bench.roc; here only for the log line
# Each binary is run REPS times and the per-pattern MINIMUM is kept: noise only ever
# inflates a run. probe.sh does the same with min-of-20 inside one process.
RUST_ITERS=500

echo "building rust bench..."
( cd tools/bench && cargo build --release --quiet --bins )

echo "generating ${BYTES}-byte haystack..."
./tools/bench/target/release/gen "$HAY" "$BYTES" >/dev/null
HAYLEN=$(wc -c < "$HAY")

echo "building roc bench (Dfa)..."
roc build examples/bench.roc --no-cache >/dev/null 2>&1
echo "building roc bench (Regex)..."
roc build examples/bench_sharp.roc --no-cache >/dev/null 2>&1

TMP="$(mktemp -d)"
REPS=5   # a freshly built binary reads ~80% slow on its first run, so warm up and take the min

# min of column 3 per id, preserving the match count
roc_min() { awk -F, '$1!="id" { if (!($1 in m)) { ord[++n]=$1 } ; if (!($1 in m) || $3+0 < m[$1]) m[$1]=$3+0; c[$1]=$4 } END { for (i=1;i<=n;i++) { k=ord[i]; print k",0," m[k] "," c[k] } }'; }
# min of columns 3 (meta) and 4 (pikevm) per id, preserving compile time and count
rust_min() { awk -F, '$1!="id" { if (!($1 in a)) { ord[++n]=$1 } ; if (!($1 in a) || $3+0 < a[$1]) a[$1]=$3+0; if (!($1 in b) || $4+0 < b[$1]) b[$1]=$4+0; p[$1]=$2; c[$1]=$5 } END { for (i=1;i<=n;i++) { k=ord[i]; print k "," p[k] "," a[k] "," b[k] "," c[k] } }'; }

echo "running roc Dfa (${REPS} x ${ROC_ITERS} iters)..."
./bench "$HAY" >/dev/null
for _ in $(seq 1 $REPS); do ./bench "$HAY"; done | roc_min > "$TMP/roc.csv"
echo "running roc Regex (${REPS} x ${ROC_ITERS} iters)..."
./bench_sharp "$HAY" >/dev/null
for _ in $(seq 1 $REPS); do ./bench_sharp "$HAY"; done | roc_min > "$TMP/sharp.csv"
echo "running rust (${REPS} x ${RUST_ITERS} iters)..."
./tools/bench/target/release/bench "$HAY" "$RUST_ITERS" >/dev/null
for _ in $(seq 1 $REPS); do ./tools/bench/target/release/bench "$HAY" "$RUST_ITERS"; done | rust_min > "$TMP/rust.csv"

echo
echo "haystack: ${HAYLEN} bytes   |   ns = nanoseconds per find_all over the whole haystack"
echo "roc = Roc package-dfa (Dfa: the frozen Rust-regex port); sharp = Roc package (Regex: RE# derivatives, leftmost-longest);"
echo "rustMeta = Rust meta engine (lazy DFA + prefilters); rustPV = Rust PikeVM."
echo "cnt checks match-count parity of roc and sharp against Rust (a DIFF invalidates the row)."
awk -F, '
BEGIN{ printf "%-13s %11s %11s %11s %11s %8s %8s %5s\n","pattern","roc_ns","sharp_ns","rustMeta_ns","rustPV_ns","roc/M","sharp/M","cnt" }
FILENAME==ARGV[1] { if($1!="id"){roc[$1]=$3; rcnt[$1]=$4} next }
FILENAME==ARGV[2] { if($1!="id"){ id=$1; sub(/^sharp_/,"",id); sharp[id]=$3; scnt[id]=$4 } next }
# rust.csv: id,compile,meta_ns,pikevm_ns,count,checksum
{ id=$1; rn=roc[id]+0; sn=sharp[id]+0; meta=$3+0; pv=$4+0;
  par=(rcnt[id]==$5 && scnt[id]==$5)?"ok":"DIFF";
  printf "%-13s %11d %11d %11d %11d %7.2fx %7.2fx %5s\n", id, rn, sn, meta, pv, rn/meta, sn/meta, par }
' "$TMP/roc.csv" "$TMP/sharp.csv" "$TMP/rust.csv"

echo
echo "compile latency (Rust Regex::new, ns/pattern; Roc = 0, folded at build time):"
awk -F, '$1!="id"{ printf "  %-13s %8d ns\n",$1,$2 }' "$TMP/rust.csv"
rm -rf "$TMP"
