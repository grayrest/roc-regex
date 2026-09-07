app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	re: "../../package/main.roc",
}
import pf.Stdout
import pf.Path
import pf.OsStr
import re.Regex

# Skip soundness: `Regex.find_all` against `Regex.find_all_noskip` — the same
# automaton with every per-state skip turned off — over a long haystack and
# three mutations of it. Any disagreement is a skip that jumped over a match.
#
# Written for `skip_ok[s] == 2` (2026-09-07), the flag that lets a state whose
# leaving set is pure ASCII pass over multibyte symbols instead of decoding
# them. That path is only reachable on a haystack that HAS non-ASCII, and only
# in states the fuzz's short haystacks rarely build, so it needs its own
# differential; the mutations put lone continuation bytes and invalid bytes
# next to the digits so the D8 `Invalid` symbol is in the skipped stretch too.

# Patterns whose skip sets span the cases the flag distinguishes: pure-ASCII
# sets that qualify (`[0-9]`, `[A-Z]`, punctuation), sets that do not because
# they hold non-ASCII (`\w`, `é`), and nullable states that must not qualify.
pats : List(Str)
pats = [
	"[0-9]{2,4}", "[0-9]+", "[0-9]", "[0-9]{3}", "\\d\\d",
	"[A-Z][a-z]+", "[A-Z]{2}", "[.,;:]", "[.,;:][ ]",
	"h[a-z]{2}", "\\bthe\\b", "(\\w+)@(\\w+)", "[0-9]{2,4}[a-z]",
	"[^0-9]{200,}", "[0-9]|é", "é[0-9]", "[0-9]é", "\\d+[^\\d]",
	# leaving sets that hold a codepoint the haystack ACTUALLY contains: the
	# generated text is Greek, so these are what make the non-ASCII condition
	# fail loudly when it is dropped. `\d` is Unicode-aware, so it is one too.
	"[0-9λ]", "[0-9α]{2,4}", "[.,;:ω]", "[A-Zγ]{2}", "μ[a-z]", "[0-9ε]+",
	# NULLABLE skip states with pure-ASCII leaving sets: these are what the
	# second condition holds back. Every position is a match, so an interior
	# symbol boundary lost inside a skipped multibyte run shows up as a
	# missing empty match.
	"[0-9]*", "[0-9]{0,3}", "[.,;:]*", "[A-Z]*",
]

# Spans compare by count and by a positional checksum, so a reordering or a
# shifted bound fails as loudly as a missing match.
span_mul : U64
span_mul = 31

checksum : List(Regex.Span) -> U64
checksum = |ss| List.fold(ss, 0, |acc, s| acc + s.start * span_mul + s.end)

# Every nth byte of a mutation is overwritten. Coprime with 16 so the damaged
# bytes fall at every alignment of the SIMD windows the skip scans with.
mutate_stride : U64
mutate_stride = 997

mutate : List(U8), U8 -> List(U8)
mutate = |hay, v| List.map_with_index(hay, |b, i| if i % mutate_stride == 0 { v } else { b })

to_ascii : List(U8) -> List(U8)
to_ascii = |hay| List.map(hay, |b| if b >= 0x80 { 'x' } else { b })

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
				b = Regex.find_all_noskip(rx, hay)
				bad2 =
					if List.len(a) == List.len(b) and checksum(a) == checksum(b) {
						bad
					} else {
						List.append(bad, "${tag} /${p}/ skip=${List.len(a).to_str()}/${checksum(a).to_str()} noskip=${List.len(b).to_str()}/${checksum(b).to_str()}")
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
	bad = run(pats, to_ascii(hay), "ascii", 0, inval)
	total = 4 * List.len(pats)
	if List.is_empty(bad) {
		Stdout.line!("${total.to_str()}/${total.to_str()} skip == noskip")
	} else {
		Stdout.line!(Str.join_with(bad, "\n"))?
		Stdout.line!("${(total - List.len(bad)).to_str()}/${total.to_str()} skip == noskip")
	}
}
