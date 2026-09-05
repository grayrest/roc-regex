#!/usr/bin/env bash
# Fold-cost and artifact probe for package-sharp (plan S14 unknowns 2–4).
#
# For each pattern: build a minimal app whose `rx = Sharp.compile("<lit>")` is
# a TOP-LEVEL constant (so it folds), under /usr/bin/time -l (wall, max RSS);
# record the binary size; then run it on a haystack file and print the fold's
# state count, whether exploration completed, the match count, and the mean
# `find_all` time over a few iterations (an incomplete fold extends its table at
# runtime, so that number also exercises unknown 2).
#
#   tools/sharp-size/probe.sh <haystack> [size|speed]
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
PKG="${ROOT}/package-sharp/main.roc"
PLATFORM='https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst'
HAY="${1:?haystack file}"
OPT="${2:-size}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PATTERNS=$(cat <<'PATS'
literal	Holmes
teddy_alt	Sherlock|Holmes|Watson|Adler|Irene|Norton|Baker|John
class_plus	[A-Za-z]+
bounded_num	[0-9]{2,4}
word_bound	\bthe\b
two_words	\w+\s+\w+
caps_email	(\w+)@(\w+)
uni_letters	\p{L}+
dotstar_lit	.*Holmes
inter	_*cat_*&_*dog_*
compl	~(_*\d\d_*)
unbounded_la	a(?=.*b)
PATS
)

emit_app() {
	cat <<APP
app [main!] {
	pf: platform "${PLATFORM}",
	re: "${PKG}",
}
import pf.Stdout
import pf.Path
import pf.OsStr
import pf.Utc
import re.Sharp

rx : Sharp.T
rx = Sharp.unwrap(Sharp.compile("$1"))

iters : U64
iters = 5

checksum : List(Sharp.Span) -> U64
checksum = |spans| List.fold(spans, 0, |acc, sp| acc + sp.start + sp.end)

time_loop : List(U8), U64, U64 -> U64
time_loop = |hay, n, acc|
	if n == 0 { acc } else { time_loop(hay, n - 1, acc + checksum(Sharp.find_all(rx, hay))) }

last_arg : List(OsStr.OsStr) -> Try(OsStr.OsStr, [Empty])
last_arg = |args| {
	n = List.len(args)
	if n == 0 { Err(Empty) } else {
		match List.get(args, n - 1) { Ok(a) => Ok(a) Err(_) => Err(Empty) }
	}
}

main! = |args| {
	hay = match last_arg(args) { Ok(a) => Path.read_bytes!(Path.from_os_str(a))? Err(_) => [] }
	t0 = Utc.now!()
	cs = time_loop(hay, iters, 0)
	t1 = Utc.now!()
	per = (if t1 > t0 { t1 - t0 } else { 0 }) / iters.to_u128()
	n = List.len(Sharp.find_all(rx, hay))
	Stdout.line!("states=\${Sharp.n_states(rx).to_str()} complete=\${if Sharp.is_complete(rx) { "yes" } else { "no" }} nodes=\${Sharp.n_nodes(rx).to_str()} matches=\${n.to_str()} ns_per_find_all=\${per.to_str()} cs=\${cs.to_str()}")
}
APP
}

printf '%-13s %8s %9s %10s  %s\n' "pattern" "build_s" "rss_MB" "bytes" "run"
while IFS=$'\t' read -r id pat; do
	esc="${pat//\\/\\\\}"
	app="${TMP}/${id}.roc"
	emit_app "$esc" > "$app"
	out="${TMP}/${id}.bin"
	# roc exits non-zero on warnings too (e.g. "unconditional condition" when a
	# folded value makes a branch constant), so judge by the produced binary
	/usr/bin/time -l -o "${TMP}/${id}.time" roc build --opt="$OPT" --output="$out" "$app" >/dev/null 2>"${TMP}/${id}.err" || true
	if [ ! -x "$out" ]; then
		printf '%-13s %8s\n' "$id" "BUILD-FAIL"
		sed 's/^/    /' "${TMP}/${id}.err" | grep -v "^ *$" | head -4
		continue
	fi
	wall=$(awk '/real/ {print $1}' "${TMP}/${id}.time")
	rss=$(awk '/maximum resident/ {printf "%.0f", $1/1048576}' "${TMP}/${id}.time")
	sz=$(wc -c < "$out" | tr -d ' ')
	run=$("$out" "$HAY" 2>&1 | tail -1 || true)
	printf '%-13s %8s %9s %10s  %s\n' "$id" "$wall" "$rss" "$sz" "$run"
done <<< "$PATTERNS"
