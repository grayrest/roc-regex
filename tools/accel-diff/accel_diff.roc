app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	re: "../../package/main.roc",
}
import pf.Stdout
import pf.Path
import pf.OsStr
import re.Regex

# Accelerator soundness: `Regex.find_all` against `Regex.find_all_plain` — the
# same automaton with `Accel.none`, so no literal override, no prefix or
# potential-start scan, no length lookup and no skips. Every accelerator is a
# claim that the stretch it jumps holds no match, and this decides all of them
# at once by asking the unaccelerated automaton.
#
# Written for the third byte in `Rlit.rfind_pair2`'s scan window (design log,
# 2026-09-07), which needs a haystack long enough for the SIMD path and runs of
# non-ASCII next to the anchors. Complements `tools/skip-diff`, which turns the
# per-state skips off and leaves the accelerators on: this one is the other
# axis, and neither subsumes the other.

# Patterns chosen for which accelerator they select, which the
# `Accel.run_of` / `Accel.pick_anchor` rules decide from the pattern's sets:
# a pure literal takes the override; a literal run behind `\b` takes a prefix
# scan with a rare-byte pair, and a third byte when its anchor is common; a
# leading `.*` takes a potential start; a non-ASCII run exercises the anchor
# hit that lands mid-symbol.
pats : List(Str)
pats = [
	# prefix scan, common anchor: these are the ones that get a third byte
	"\\bthe\\b", "\\bthe", "the\\b", "\\bthem\\b", "\\bthere\\b", "\\bthat\\b",
	"\\bwas\\b", "\\bhis\\b", "\\bher\\b", "\\bhad\\b", "\\bwhich\\b",
	"the", "them", "there", "[a-z]the[a-z]", "x?the", "the[ ,.]", "[ ]the[ ]",
	"\\sthe\\s", "the\\wx", "\\bthe\\b|\\band\\b",
	# rare anchor: pair but no third byte, and the literal override
	"Holmes", "Moriarty", "\\bHolmes\\b", "(\\w+)@(\\w+)",
	# potential start rather than an exact prefix
	".*Holmes",
	# runs whose anchor is non-ASCII, so a hit lands inside a symbol
	"παρά", "\\bκαι\\b", "λόγος",
	# no accelerator at all, as a control
	"\\w+\\s+\\w+",
	# ONE class repeated, which replaces the sweep outright (`Rrun`): the
	# bounds, a class that is not a range, and classes whose runs are dense
	# enough to cross window boundaries
	"[0-9]{2,4}", "[0-9]", "[0-9]+", "[0-9]{3,}", "[0-9]{5}", "[0-9]{17}",
	"[A-Za-z]+", "[A-Za-z]{2,3}", "[aeiou]+", "[^ ]+", "[^0-9]+", "\\S{4}",
	"[0-9a-f]{2,}", "[ ]+", "[.,;:]+",
	# rejected by the gate, and must still be right: `lo` of zero is nullable
	# everywhere, and a class with non-ASCII members cannot use the kernel
	"[0-9]*", "[A-Za-z]*", "\\p{L}+", "\\w+", "\\d+", "[α-ω]+",
]

# Spans compare by count and by a positional checksum, so a reordering or a
# shifted bound fails as loudly as a missing match.
span_mul : U64
span_mul = 31

checksum : List(Regex.Span) -> U64
checksum = |ss| List.fold(ss, 0, |acc, s| acc + s.start * span_mul + s.end)

# Every nth byte of a mutation is overwritten. Coprime with 16 so the damaged
# bytes fall at every alignment of the SIMD windows the scans read.
mutate_stride : U64
mutate_stride = 997

mutate : List(U8), U8 -> List(U8)
mutate = |hay, v| List.map_with_index(hay, |b, i| if i % mutate_stride == 0 { v } else { b })

to_ascii : List(U8) -> List(U8)
to_ascii = |hay| List.map(hay, |b| if b >= 0x80 { 'x' } else { b })

# Short haystacks with a match in the FIRST and LAST 16-byte window. A partner
# load that would cross either edge is skipped and the window keeps every lane,
# because the partner is a filter and never a requirement; those two windows
# are the only place that fallback is reachable, and the 256 KB haystacks below
# never happen to put a match in them. Turning the fallback into a requirement
# goes unnoticed without these.
edges : List(Str)
edges = [
	"the quick brown fox the",
	"them and the others were there",
	"Holmes went out with Holmes",
	"παρά the λόγος and the παρά",
	"the",
	"the the the the the",
	"a the b the c the d the e",
	"was his her had was his her",
	# runs against both edges, runs that cross a 16-byte window boundary, and
	# runs shorter and longer than a bound
	"1234567890123456789012345",
	"99 the 1234 x 12345678901234567890 y 7",
	"1",
	"12",
	"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
	"       1234567890123456       ",
	"παρά12345λόγος67890παρά",
	"9999999999999999",
]

run_edges : List(Str), U64, List(Str) -> List(Str)
run_edges = |ps, i, bad|
	if i >= List.len(edges) {
		bad
	} else {
		run_edges(ps, i + 1, run(ps, Str.to_utf8(List.get(edges, i) ?? ""), "edge${i.to_str()}", 0, bad))
	}

run : List(Str), List(U8), Str, U64, List(Str) -> List(Str)
run = |ps, hay, tag, i, bad|
	if i >= List.len(ps) {
		bad
	} else {
		p = List.get(ps, i) ?? ""
		match Regex.compile(p) {
			Err(_) => run(ps, hay, tag, i + 1, List.append(bad, "${tag} /${p}/ did not compile"))
			Ok(rx) => {
				a = Regex.find_all(rx, hay)
				b = Regex.find_all_plain(rx, hay)
				bad2 =
					if List.len(a) == List.len(b) and checksum(a) == checksum(b) {
						bad
					} else {
						List.append(bad, "${tag} /${p}/ accel=${List.len(a).to_str()}/${checksum(a).to_str()} plain=${List.len(b).to_str()}/${checksum(b).to_str()}")
					}
				run(ps, hay, tag, i + 1, bad2)
			}
		}
	}

# The haystack path is the last argument, so the same code works whether or not
# the platform prepends the program name.
last_arg : List(OsStr.OsStr) -> Try(OsStr.OsStr, [Empty])
last_arg = |args| {
	n = List.len(args)
	if n == 0 {
		Err(Empty)
	} else {
		match List.get(args, n - 1) {
			Ok(a) => Ok(a)
			Err(_) => Err(Empty)
		}
	}
}

main! = |args| {
	hay =
		match last_arg(args) {
			Ok(a) => Path.read_bytes!(Path.from_os_str(a))?
			Err(_) => []
		}
	mixed = run(pats, hay, "mixed", 0, [])
	cont = run(pats, mutate(hay, 0x80), "continuation", 0, mixed)
	inval = run(pats, mutate(hay, 0xFF), "invalid", 0, cont)
	ascii = run(pats, to_ascii(hay), "ascii", 0, inval)
	bad = run_edges(pats, 0, ascii)
	total = (4 + List.len(edges)) * List.len(pats)
	if List.is_empty(bad) {
		Stdout.line!("${total.to_str()}/${total.to_str()} accel == plain")
	} else {
		Stdout.line!(Str.join_with(bad, "\n"))?
		Stdout.line!("${(total - List.len(bad)).to_str()}/${total.to_str()} accel == plain")
	}
}
