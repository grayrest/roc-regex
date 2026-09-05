app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	re: "../package-sharp/main.roc",
}
import pf.Stdout
import pf.Path
import pf.OsStr
import pf.Utc
import re.Sharp

# KEEP PATTERNS IN SYNC with tools/bench/src/bench.rs and examples/bench.roc: same regexes,
# ids prefixed `sharp_` (tools/bench/run.sh strips the prefix to pair rows). RE#'s semantics are
# leftmost-longest; on these patterns leftmost-first agrees, so the count parity check holds.
# Each `src` is a string literal so `Sharp.compile` is constant-folded into the
# binary at build time (the AOT premise). The regex is bound once, before the
# timing loop, so per-iteration numbers measure match throughput only.
Pat : { id : Str, src : Str }

patterns : List(Pat)
patterns = [
	{ id: "sharp_literal_dense", src: "Holmes" },
	{ id: "sharp_literal_sparse", src: "Moriarty" },
	{ id: "sharp_teddy_alt", src: "Sherlock|Holmes|Watson|Adler|Irene|Norton|Baker|John" },
	{ id: "sharp_class_plus", src: "[A-Za-z]+" },
	{ id: "sharp_bounded_num", src: "[0-9]{2,4}" },
	{ id: "sharp_word_bound", src: "\\bthe\\b" },
	{ id: "sharp_two_words", src: "\\w+\\s+\\w+" },
	{ id: "sharp_caps_email", src: "(\\w+)@(\\w+)" },
	{ id: "sharp_uni_letters", src: "\\p{L}+" },
	{ id: "sharp_dotstar_lit", src: ".*Holmes" },
]

# How many times each pattern is matched against the haystack. The loop always
# executes this many times: `find_all` takes the runtime haystack, so the calls
# cannot be constant-folded away. Bumped by hand when tuning; the reported
# figure is ns *per iteration*, so the value only trades precision for time.
iters : U64
iters = 20

# Sum span endpoints so the match loop has an observable result and cannot be
# eliminated. Totals stay well under U64 max for a single-haystack run.
checksum : List(Sharp.Span) -> U64
checksum = |spans|
	List.fold(spans, 0, |acc, sp| acc + sp.start + sp.end)

time_loop : Sharp.T, List(U8), U64, U64 -> U64
time_loop = |rx, hay, n, acc|
	if n == 0 {
		acc
	} else {
		c = checksum(Sharp.find_all(rx, hay))
		time_loop(rx, hay, n - 1, acc + c)
	}

run_all! : List(Pat), List(U8), U64 => Try({}, _)
run_all! = |pats, hay, i|
	if i >= List.len(pats) {
		Ok({})
	} else {
		p = List.get(pats, i) ?? { id: "?", src: "" }
		rx = Sharp.unwrap(Sharp.compile(p.src))
		t0 = Utc.now!()
		cs = time_loop(rx, hay, iters, 0)
		t1 = Utc.now!()
		delta = if t1 > t0 { t1 - t0 } else { 0 }
		per = delta / iters.to_u128()
		count = List.len(Sharp.find_all(rx, hay))
		# id,compile_ns(0=folded),match_ns_per_iter,match_count,checksum
		Stdout.line!("${p.id},0,${per.to_str()},${count.to_str()},${cs.to_str()}")?
		run_all!(pats, hay, i + 1)
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
	Stdout.line!("id,compile_ns,match_ns_per_iter,match_count,checksum")?
	run_all!(patterns, hay, 0)
}
