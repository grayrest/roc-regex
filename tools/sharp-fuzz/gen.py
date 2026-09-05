#!/usr/bin/env python3
"""Fuzz campaign for package-sharp (plan: "a fuzz campaign of stated size
against the brute-force reference with zero divergences").

Generates random RE#-syntax patterns over a small alphabet and fixed
haystacks (with a two-byte codepoint and an invalid byte), and prints a Roc
runner that compiles each pattern AT RUNTIME (argv-derived filler defeats
folding) and compares `find_all` (fast path or threaded, whichever the fold
allows), `find_all_threaded`, an eviction-forcing variant, and the
structural reference `find_all_ref`. Patterns RE# rejects (non-normal-form
lookarounds, `\\B`) are counted, not failed.

    python3 tools/sharp-fuzz/gen.py [n_patterns] [seed] [plain] > /tmp/sharp-fuzz.roc
    roc build /tmp/sharp-fuzz.roc && /tmp/sharp-fuzz
"""
import os, random, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.abspath(os.path.join(HERE, "..", "..", "package-sharp", "main.roc"))
PLATFORM = "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst"

N = int(sys.argv[1]) if len(sys.argv) > 1 else 1500
SEED = int(sys.argv[2]) if len(sys.argv) > 2 else 20260905
# "plain": no anchors, word borders or lookarounds (the constructs where the
# brute-force reference and RE#'s derivative semantics are known to differ)
PLAIN = len(sys.argv) > 3 and sys.argv[3] == "plain"
# "resharp": every construct, ASCII haystacks, compared with real RE# through
# tools/sharp-diff's harness (needs DOTNET_ROOT/PATH/RESHARP as for sharp-diff)
RESHARP = len(sys.argv) > 3 and sys.argv[3] == "resharp"
rng = random.Random(SEED)

ATOMS = ["a", "b", "c", "[ab]", "[^a]", "[^ab]", ".", "_", r"\w", r"\d", r"\s", r"\W", "é", ",", " ", r"\n"]
if RESHARP:
    ATOMS = [a for a in ATOMS if a != "é"]
QUANTS = ["*", "+", "?", "{2}", "{1,2}", "{0,2}", "{2,}"]


def atom(d):
    r = rng.random()
    if d <= 0 or r < 0.55 or (PLAIN and r < 0.66):
        return rng.choice(ATOMS)
    if PLAIN and r >= 0.82:
        return "(" + alt(d - 1) + ")"
    if r < 0.62:
        return "^" if rng.random() < 0.5 else "$"
    if r < 0.66:
        return r"\b"
    if r < 0.74:
        return "(" + alt(d - 1) + ")"
    if r < 0.82:
        return "~(" + alt(d - 1) + ")"
    look = rng.choice(["(?=", "(?!", "(?<=", "(?<!"])
    return look + alt(d - 1) + ")"


def piece(d):
    a = atom(d)
    if a in ("^", "$", r"\b") or a.startswith("(?"):
        return a
    return a + rng.choice(QUANTS) if rng.random() < 0.45 else a


def cat(d):
    return "".join(piece(d) for _ in range(rng.randint(1, 4)))


def conj(d):
    parts = [cat(d) for _ in range(1 if rng.random() < 0.85 else 2)]
    return "&".join(parts)


def alt(d):
    parts = [conj(d) for _ in range(1 if rng.random() < 0.7 else rng.randint(2, 3))]
    return "|".join(parts)


def gen_pattern():
    return alt(rng.randint(1, 3))


HAYS = [
    b"", b"a", b"ab", b"abc", b"aab ba", b"ca,b\nab", b"ab\xc3\xa9b a", b"bb\xffab", b"a b  c,\n\nab", b"babaacab", b"\xc3\xa9\xc3\xa9,a", b"cab ab\xff\n",
]
if RESHARP:
    HAYS = [b"", b"a", b"ab", b"abc", b"aab ba", b"ca,b\nab", b"abxb a", b"bbxab", b"a b  c,\n\nab", b"babaacab", b"c1,a", b"cab ab\n"]


def roc_str(s):
    out = []
    for ch in s:
        if ch == "\\": out.append("\\\\")
        elif ch == '"': out.append('\\"')
        elif ch == "$": out.append("\\$")
        else: out.append(ch)
    return "".join(out)


pats = []
seen = set()
while len(pats) < N:
    p = gen_pattern()
    if p in seen or len(p) > 60:
        continue
    seen.add(p)
    pats.append(p)

if RESHARP:
    import json, subprocess, tempfile
    harness = os.path.join(HERE, "..", "sharp-diff", "ResharpDiff", "bin", "Release", "net10.0", "ResharpDiff.dll")
    cases = [{"pat": p, "hay": h.decode()} for p in pats for h in HAYS]
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(cases, f)
        path = f.name
    out = json.loads(subprocess.run(["dotnet", harness, path], capture_output=True, text=True, check=True).stdout)
    os.unlink(path)
    want = {}
    for r in out:
        want[(r["pat"], r["hay"])] = ",".join(f"{s}-{e}" for s, e in r["matches"]) if r["ok"] else None

print("app [main!] {")
print(f'\tpf: platform "{PLATFORM}",')
print(f'\tre: "{PKG}",')
print("}")
print("import pf.Stdout")
print("import re.Sharp\n")
print("# %d patterns, seed %d, %d haystacks" % (N, SEED, len(HAYS)))
print("pats : List(Str)")
print("pats = [")
for p in pats:
    print(f'\t"{roc_str(p)}",')
print("]\n")
print("hays : List(List(U8))")
print("hays = [")
for h in HAYS:
    print("\t[" + ", ".join(str(b) for b in h) + "],")
print("]\n")
if RESHARP:
    # RE#'s answer per pattern: one entry per haystack, "-" where RE# rejects the pattern
    print("wants : List(List(Str))")
    print("wants = [")
    for p in pats:
        row = []
        for h in HAYS:
            w = want[(p, h.decode())]
            row.append('"-"' if w is None else '"' + w + '"')
        print("\t[" + ", ".join(row) + "],")
    print("]\n")
if not RESHARP:
    print("wants : List(List(Str))")
    print("wants = []\n")
print(r'''spans : List(Sharp.Span) -> Str
spans = |sp| sp |> List.map(|s| "${s.start.to_str()}-${s.end.to_str()}") |> Str.join_with(",")

Outcome : { rejected : U64, incomplete : U64, cases : U64, fails : List(Str) }

check : Sharp.T, Str, List(U8), Outcome -> Outcome
check = |re, pat, hay, o| {
	fast = spans(Sharp.find_all(re, hay))
	ref = spans(Sharp.find_all_ref(re, hay))
	thr = spans(Sharp.find_all_threaded(re, hay))
	ev = spans(Sharp.find_all(Sharp.with_runtime_cap(re, 6), hay))
	o2 = { ..o, cases: o.cases + 1 }
	if fast == ref and thr == ref and ev == ref {
		o2
	} else {
		{ ..o2, fails: List.append(o2.fails, "/${pat}/ on ${hay |> List.map(|b| b.to_str()) |> Str.join_with(" ")}: fast=[${fast}] threaded=[${thr}] evict=[${ev}] ref=[${ref}]") }
	}
}

run : Str, Outcome -> Outcome
run = |pat, o|
	match Sharp.compile(pat) {
		Err(_) => { ..o, rejected: o.rejected + 1 }
		Ok(re) => {
			o1 = if Sharp.is_complete(re) { o } else { { ..o, incomplete: o.incomplete + 1 } }
			List.fold(hays, o1, |acc, hay| check(re, pat, hay, acc))
		}
	}

# tier B: `find_all` against RE#'s own answer (ASCII); a pattern RE# rejects
# and we accept is not a failure (our fragment is wider), the reverse is
run_resharp : Str, List(Str), Outcome -> Outcome
run_resharp = |pat, ws, o|
	match Sharp.compile(pat) {
		Err(_) => { ..o, rejected: o.rejected + 1 }
		Ok(re) => {
			o1 = if Sharp.is_complete(re) { o } else { { ..o, incomplete: o.incomplete + 1 } }
			List.fold_with_index(hays, o1, |acc, hay, i| {
				w = List.get(ws, i) ?? "-"
				if w == "-" {
					acc
				} else {
					got = spans(Sharp.find_all(re, hay))
					acc2 = { ..acc, cases: acc.cases + 1 }
					if got == w { acc2 } else { { ..acc2, fails: List.append(acc2.fails, "/${pat}/ on \"${Str.from_utf8_lossy(hay)}\": sharp=[${got}] resharp=[${w}]") } }
				}
			})
		}
	}

main! = |args| {
	filler = if List.len(args) > 99 { "x" } else { "" }
	o = List.fold_with_index(pats, { rejected: 0, incomplete: 0, cases: 0, fails: [] }, |acc, p, i| if List.is_empty(wants) { run(Str.concat(p, filler), acc) } else { run_resharp(Str.concat(p, filler), List.get(wants, i) ?? [], acc) })
	Stdout.line!(Str.join_with(List.take_first(o.fails, 40), "\n"))?
	Stdout.line!("patterns=${List.len(pats).to_str()} rejected=${o.rejected.to_str()} incomplete=${o.incomplete.to_str()} cases=${o.cases.to_str()} divergences=${List.len(o.fails).to_str()}")
}
''')
