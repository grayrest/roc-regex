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
RUST_ITERS=500

echo "building rust bench..."
( cd tools/bench && cargo build --release --quiet --bins )

echo "generating ${BYTES}-byte haystack..."
./tools/bench/target/release/gen "$HAY" "$BYTES" >/dev/null
HAYLEN=$(wc -c < "$HAY")

echo "building roc bench (Regex)..."
roc build examples/bench.roc --no-cache >/dev/null 2>&1
echo "building roc bench (Sharp)..."
roc build examples/bench_sharp.roc --no-cache >/dev/null 2>&1

TMP="$(mktemp -d)"
echo "running roc Regex (${ROC_ITERS} iters)..."
./bench "$HAY" > "$TMP/roc.csv"
echo "running roc Sharp (${ROC_ITERS} iters)..."
./bench_sharp "$HAY" > "$TMP/sharp.csv"
echo "running rust (${RUST_ITERS} iters)..."
./tools/bench/target/release/bench "$HAY" "$RUST_ITERS" > "$TMP/rust.csv"

echo
echo "haystack: ${HAYLEN} bytes   |   ns = nanoseconds per find_all over the whole haystack"
echo "roc = Roc Regex (DFA + PikeVM); sharp = Roc package-sharp (RE# derivatives, leftmost-longest);"
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
