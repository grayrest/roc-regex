#!/usr/bin/env bash
# Skip soundness: `find_all` against `find_all_noskip` on a long haystack and
# three mutations of it. See README.md.
#
#   tools/skip-diff/run.sh [haystack_bytes]
set -euo pipefail
cd "$(dirname "$0")/../.."

BYTES="${1:-262144}"
HAY="testdata/bench_haystack.txt"
OUT="$(mktemp -d)/skip_diff"

if [ ! -s "$HAY" ] || [ "$(wc -c < "$HAY")" -ne "$BYTES" ]; then
  echo "generating ${BYTES}-byte haystack..."
  ( cd tools/bench && cargo build --release --quiet --bin gen )
  ./tools/bench/target/release/gen "$HAY" "$BYTES" >/dev/null
fi

echo "building..."
roc build --output="$OUT" tools/skip-diff/skip_diff.roc >/dev/null 2>&1

# `a b` so the runner cannot be constant-folded whole; the haystack path is last
RESULT="$("$OUT" a b "$HAY")"
echo "$RESULT"
echo "$RESULT" | tail -1 | grep -Eq '^([0-9]+)/\1 skip == noskip$'
