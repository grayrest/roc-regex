#!/usr/bin/env bash
# The Roc port against the engine it ports: package-sharp vs the original RE#
# (F#/.NET) on identical patterns and an identical haystack.
#
#   DOTNET_ROOT=~/.dotnet PATH=~/.dotnet:$PATH RESHARP=~/Repositories/resharp-dotnet \
#       tools/sharp-bench/run.sh [haystack]
#
# Both sides construct the regex once outside the timing loop, run the same
# number of iterations, and keep the per-pattern MINIMUM. RE# additionally warms
# up first: it JITs and fills a lazy DFA on the early passes, and timing that
# would measure .NET's startup rather than the algorithm.
#
# Match COUNTS are compared for parity. Offsets are not: RE# reports UTF-16
# indices and package-sharp reports byte offsets, and this haystack is not pure
# ASCII, so the two disagree by construction on positions after a multibyte
# codepoint.
set -euo pipefail
cd "$(dirname "$0")/../.."
HAY="${1:-testdata/bench_haystack.txt}"
ITERS=20
REPS=5
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

: "${RESHARP:?set RESHARP to the resharp-dotnet checkout}"

echo "building RE# bench..."
dotnet build -c Release tools/sharp-bench/ResharpBench/ResharpBench.csproj >/dev/null
echo "building roc Sharp bench..."
roc build --no-cache examples/bench_sharp.roc >/dev/null 2>&1 || true

BENCH=tools/sharp-bench/ResharpBench/bin/Release/net10.0/ResharpBench.dll

min_of() { awk -F, '$1!="id" { gsub(/^sharp_/,"",$1); if (!($1 in m) || $3+0 < m[$1]) m[$1]=$3+0; if (!($1 in p) || $2+0 < p[$1]) p[$1]=$2+0; c[$1]=$4 } END { for (k in m) print k "," p[k] "," m[k] "," c[k] }'; }

echo "running RE# (${REPS} x ${ITERS} iters, warmed)..."
for _ in $(seq 1 $REPS); do dotnet "$BENCH" "$HAY" "$ITERS"; done | min_of | sort > "$TMP/resharp.csv"
echo "running roc Sharp (${REPS} x ${ITERS} iters)..."
./bench_sharp "$HAY" >/dev/null
for _ in $(seq 1 $REPS); do ./bench_sharp "$HAY"; done | min_of | sort > "$TMP/sharp.csv"

echo
echo "haystack: $(wc -c < "$HAY" | tr -d ' ') bytes   |   ns per full scan of the haystack"
join -t, "$TMP/sharp.csv" "$TMP/resharp.csv" | awk -F, '
BEGIN { printf "%-15s %12s %12s %10s %5s\n", "pattern", "sharp_ns", "resharp_ns", "sharp/RE#", "cnt" }
{ printf "%-15s %12d %12d %9.2fx %5s\n", $1, $3, $6, $3/$6, ($4==$7 ? "ok" : "DIFF") }'

echo
echo "construction, ns per pattern (RE# compiles at runtime; Roc folds at build time, so 0):"
awk -F, '{ printf "  %-15s %12d\n", $1, $2 }' "$TMP/resharp.csv" | sort
