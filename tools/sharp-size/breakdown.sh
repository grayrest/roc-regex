#!/usr/bin/env bash
# What does one folded pattern cost in the binary?
#
# Two numbers per pattern, because they answer different questions:
#
#   * MEASURED: the binary's size and its constant-data sections, each also as
#     a delta against a baseline binary holding the smallest possible pattern.
#     The delta is the marginal cost of choosing this pattern over a trivial
#     one; the absolute size includes the platform and the engine code that any
#     first pattern pays for.
#   * LOGICAL: the bytes the engine's own folded structures occupy, summed from
#     their element counts and widths. This is what the artifact is made of,
#     and it says WHERE the cost is (transition tables, Unicode class trie, or
#     the node arena), which the section totals cannot.
#
# The app must actually SCAN a runtime haystack. Asking only for `List.len` of
# the folded lists lets the compiler answer from the constant and drop the data,
# and every binary then comes out byte-identical.
#
#   tools/sharp-size/breakdown.sh <haystack> [size|speed]
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
PKG="${ROOT}/package-sharp/main.roc"
PLATFORM='https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst'
HAY="${1:?haystack file}"
OPT="${2:-size}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# `a+` is the baseline: the smallest pattern that still takes the DFA scan
# path, with an ASCII-only trie. A pure literal is NOT a valid baseline. The
# literal override means it never touches the transition tables, so the whole
# scanning engine is eliminated and it lands SMALLER than this baseline.
PATTERNS=$(cat <<'PATS'
baseline	a+
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
import re.Sharp
import re.Arena

rx : Sharp.T
rx = Sharp.unwrap(Sharp.compile("$1"))

main! = |args| {
	# scan a runtime haystack so the folded tables are live and actually stored
	hay = match List.last(args) { Ok(p) => Path.read_bytes!(Path.from_os_str(p))? Err(_) => [] }
	cs = List.fold(Sharp.find_all(rx, hay), 0, |acc, sp| acc + sp.start + sp.end)
	e = rx.e
	t = rx.trie
	a = rx.a
	u32 = |n| n * 4
	u64 = |n| n * 8
	# the transition tables and the per-state columns
	tables = u32(List.len(e.table)) + u32(List.len(e.end_table)) + 2 * List.len(e.atable)
	states = u32(List.len(e.st_node)) + List.len(e.st_flags) + List.len(e.st_nk) + u32(List.len(e.st_pend)) + 2 * List.len(e.st_minpend) + u32(List.len(e.node_state))
	skips = List.len(e.skip_ok) + List.len(e.skip_lo)
	# the codepoint-class trie, dominated by Unicode class data
	trie = List.len(t.ascii) + 2 * List.len(t.l1) + List.len(t.leaves) + u64(List.len(t.set_tsets)) + u32(List.len(t.cuts)) + List.len(t.mt_of_atom)
	# the interned node graph, including its hash index and refsets
	nodes = u32(List.len(a.cells)) + u32(List.len(a.offs)) + List.len(a.flags) + u64(List.len(a.sub)) + u32(List.len(a.minl)) + u32(List.len(a.maxl)) + u32(List.len(a.pend))
	index = u32(List.len(a.islots)) + u32(List.len(a.ient_key)) + u32(List.len(a.ient_len)) + u32(List.len(a.ient_id)) + u32(List.len(a.ikeys))
	refs = u32(List.len(a.rs_data)) + u32(List.len(a.rs_off)) + u32(List.len(a.rs_len))
	Stdout.line!("tables=\${tables.to_str()} states=\${states.to_str()} skips=\${skips.to_str()} trie=\${trie.to_str()} nodes=\${nodes.to_str()} index=\${index.to_str()} refs=\${refs.to_str()} n_states=\${Sharp.n_states(rx).to_str()} n_nodes=\${Sharp.n_nodes(rx).to_str()} nmt=\${e.nmt.to_str()} complete=\${if Sharp.is_complete(rx) { "1" } else { "0" }} cs=\${cs.to_str()}")
}
APP
}

# __text, __TEXT,__const and __DATA_CONST,__const from the Mach-O section table
sections() {
	size -m "$1" | awk '
		/^Segment __TEXT:/       { seg = "T" }
		/^Segment __DATA_CONST:/ { seg = "D" }
		/^Segment __DATA:/       { seg = "X" }
		/Section __text:/        { txt = $3 }
		/Section __const:/       { if (seg == "D") dc = $3; else if (seg == "T") tc = $3 }
		END { printf "%d %d %d\n", txt + 0, tc + 0, dc + 0 }'
}

declare -a IDS PAT BIN TXT TC DC RUN
i=0
while IFS=$'\t' read -r id pat; do
	[ -z "$id" ] && continue
	app="${TMP}/${id}.roc"
	out="${TMP}/${id}.bin"
	esc="${pat//\\/\\\\}"   # `\b` is not a Roc escape; double every backslash
	emit_app "$esc" > "$app"
	# roc exits non-zero on warnings too, so judge by whether a binary appeared
	roc build --opt="$OPT" --output="$out" "$app" >/dev/null 2>&1 || true
	if [ ! -x "$out" ]; then
		printf '%-13s BUILD FAILED\n' "$id" >&2
		continue
	fi
	read -r t c d <<<"$(sections "$out")"
	IDS[$i]="$id"; PAT[$i]="$pat"
	BIN[$i]=$(stat -f%z "$out"); TXT[$i]=$t; TC[$i]=$c; DC[$i]=$d
	RUN[$i]="$("$out" "$HAY")"
	i=$((i + 1))
done <<<"$PATTERNS"

base_bin=${BIN[0]}; base_dc=${DC[0]}; base_tc=${TC[0]}; base_txt=${TXT[0]}

field() { echo "$1" | tr ' ' '\n' | awk -F= -v k="$2" '$1==k{print $2}'; }

printf '%-13s %9s %9s %9s %9s   %8s %8s %8s %7s %5s\n' \
	pattern binary d_binary d_const d_code tables trie nodes states cmpl
for ((j = 0; j < i; j++)); do
	r="${RUN[$j]}"
	printf '%-13s %9s %+9d %+9d %+9d   %8s %8s %8s %7s %5s\n' \
		"${IDS[$j]}" "${BIN[$j]}" "$((BIN[$j] - base_bin))" \
		"$((TC[$j] + DC[$j] - base_tc - base_dc))" "$((TXT[$j] - base_txt))" \
		"$(field "$r" tables)" "$(field "$r" trie)" "$(field "$r" nodes)" \
		"$(field "$r" n_states)" "$(field "$r" complete)"
done

cat <<'NOTE'

binary is the whole file. d_binary, d_const and d_code are against the `a+`
baseline, read from the Mach-O section table, where const is __TEXT,__const plus
__DATA_CONST,__const and code is __TEXT,__text. tables, trie and nodes are the
engine's own folded structures in bytes, summed from element counts and widths;
cmpl=1 means the fold explored every reachable state.
NOTE
