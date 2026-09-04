#!/usr/bin/env bash
# Artifact-size probe: how many bytes does baking a folded regex — and in
# particular its DFA tables — add to the executable?
#
# For each pattern we build a minimal app that folds `Regex.compile("<lit>")`
# at build time (the AOT premise: the literal is a compile-time constant, so the
# whole compiled artifact — NFA prog, class trie, and, for a look-free in-budget
# pattern, the forward+reverse DFA tables — is materialized into the binary).
# The haystack is a runtime file arg, so the folded regex is actually used and
# cannot be dead-stripped.
#
# The `\bthe\b` row is the baseline: `\b` forces engine = Pike, so it bakes NO
# DFA tables while linking the exact same code. Every other row minus that
# baseline is the DFA-table (+ any larger class trie) cost for that pattern.
#
#   tools/size/probe.sh            # default --opt=size
#   tools/size/probe.sh speed      # --opt=speed
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
PKG="${ROOT}/package/main.roc"
PLATFORM='https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst'
OPT="${1:-size}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# id<TAB>pattern-literal (kept in sync with examples/bench.roc; \b row = Pike baseline)
PATTERNS=$(cat <<'EOF'
pike_base	\bthe\b
literal	Holmes
teddy_alt	Sherlock|Holmes|Watson|Adler|Irene|Norton|Baker|John
class_plus	[A-Za-z]+
bounded_num	[0-9]{2,4}
two_words	\w+\s+\w+
caps_email	(\w+)@(\w+)
uni_letters	\p{L}+
dotstar_lit	.*Holmes
EOF
)

emit_app() { # $1 = pattern literal (already Roc-escaped)
	# `rx` is a TOP-LEVEL constant: Roc folds `Regex.compile` at build time only
	# for module-level defs, not for lets inside an effectful body. Folding it
	# here bakes the artifact (and DFA tables) into the binary AND lets the
	# compiler dead-strip the parser/determinizer, so the binary is both smaller
	# and representative of the AOT path. The haystack stays a runtime file arg.
	cat <<EOF
app [main!] {
	pf: platform "${PLATFORM}",
	re: "${PKG}",
}
import pf.Stdout
import pf.Path
import pf.OsStr
import re.Regex

rx : Regex.T
rx = Regex.unwrap(Regex.compile("$1"))

last_arg : List(OsStr.OsStr) -> Try(OsStr.OsStr, [Empty])
last_arg = |args| {
	n = List.len(args)
	if n == 0 { Err(Empty) } else {
		match List.get(args, n - 1) { Ok(a) => Ok(a) Err(_) => Err(Empty) }
	}
}

main! = |args| {
	hay = match last_arg(args) { Ok(a) => Path.read_bytes!(Path.from_os_str(a))? Err(_) => [] }
	n = List.len(Regex.find_all(rx, hay))
	Stdout.line!(n.to_str())
}
EOF
}

printf '%-13s %12s\n' "pattern" "bytes(${OPT})"
base=0
while IFS=$'\t' read -r id pat; do
	# escape backslashes for the Roc string literal
	esc="${pat//\\/\\\\}"
	app="${TMP}/${id}.roc"
	emit_app "$esc" > "$app"
	out="${TMP}/${id}.bin"
	if ! roc build --opt="$OPT" --output="$out" "$app" >/dev/null 2>"${TMP}/${id}.err"; then
		printf '%-13s %12s\n' "$id" "BUILD-FAIL"
		sed 's/^/    /' "${TMP}/${id}.err" | head -6
		continue
	fi
	sz=$(wc -c < "$out")
	if [ "$id" = "pike_base" ]; then
		base=$sz
		printf '%-13s %12s   (Pike baseline, no DFA)\n' "$id" "$sz"
	else
		printf '%-13s %12s   Δ=%+d over baseline\n' "$id" "$sz" "$((sz - base))"
	fi
done <<< "$PATTERNS"
