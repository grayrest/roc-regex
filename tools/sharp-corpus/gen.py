#!/usr/bin/env python3
"""Emit a Roc runner for RE#'s TOML corpus (S2.1).

Reads data/tests/*.toml from the RE# checkout, converts its UTF-16 match
offsets to byte offsets, and prints a Roc app that runs every case through
package-sharp and reports divergences per kind.
"""
import sys, glob, tomllib, os

RESHARP = os.environ.get("RESHARP", os.path.expanduser("~/Repositories/resharp-dotnet"))
PKG = os.environ.get("SHARP_PKG", os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "package-sharp", "main.roc")))
PLATFORM = "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst"

def roc_str(s):
    out = []
    for ch in s:
        if ch == "\\": out.append("\\\\")
        elif ch == '"': out.append('\\"')
        elif ch == "\n": out.append("\\n")
        elif ch == "\t": out.append("\\t")
        elif ch == "\r": out.append("\\r")
        elif ch == "$": out.append("\\$")
        elif ord(ch) < 32: out.append("\\u(%x)" % ord(ch))
        else: out.append(ch)
    return "".join(out)

def u16_to_bytes(s):
    """map UTF-16 index -> byte offset (plus the end)"""
    m = {}
    u = b = 0
    for ch in s:
        m[u] = b
        u += 2 if ord(ch) > 0xFFFF else 1
        b += len(ch.encode("utf-8"))
    m[u] = b
    return m

# Cases where RE#'s recorded output contradicts its own leftmost-longest
# specification; the reference (and this engine) follow the specification.
# Keyed by (file, pattern, input-prefix); value = the spec-correct spans.
# See notes/2026-09-05-package-sharp-design-log.md, "RE# divergences".
KNOWN_RESHARP_DIVERGENCES = {
    ("tests02_lookaround.toml", "(ab){1,3}(?=.*c)", "__ababab_c"): "2-8",
    ("tests08_semantics.toml", r"(?<=6|8\(.*).*&(?<=6|8\(|4|8|0\().*&~(.*\)\:.*)&\w.*&.*\w&.*(?=.*\)\:)&.*(?=\)\:|\)\:)", "\nJan 12 06:26:19"): "48-137,156-179,359-396,451-565,568-604",
}

cases = []
for path in sorted(glob.glob(os.path.join(RESHARP, "data", "tests", "*.toml"))):
    name = os.path.basename(path)
    with open(path, "rb") as f:
        doc = tomllib.load(f)
    for t in doc.get("test", []):
        pat, inp = t["pattern"], t["input"]
        m = u16_to_bytes(inp)
        if "matches" in t:
            want = ",".join(f"{m[s]}-{m[e]}" for s, e in t["matches"])
            for (kf, kp, ki), spec in KNOWN_RESHARP_DIVERGENCES.items():
                if kf == name and kp == pat and inp.startswith(ki):
                    want = spec
            cases.append(("matches", name, pat, inp, want))
        elif "end_positions" in t:
            want = ",".join(str(m[e]) for e in t["end_positions"])
            cases.append(("ends", name, pat, inp, want))
        elif "nullable_positions" in t:
            want = ",".join(str(m[p]) for p in t["nullable_positions"])
            cases.append(("starts", name, pat, inp, want))
        elif name.startswith("tests07"):
            cases.append(("unsupported", name, pat, inp, ""))

print("app [main!] {")
print(f'\tpf: platform "{PLATFORM}",')
print(f'\tre: "{PKG}",')
print("}")
print("import pf.Stdout")
print("import re.Sharp\n")
print("Case : { kind : Str, file : Str, pat : Str, hay : Str, want : Str }\n")
print("cases : List(Case)")
print("cases = [")
for kind, name, pat, inp, want in cases:
    print(f'\t{{ kind: "{kind}", file: "{name}", pat: "{roc_str(pat)}", hay: "{roc_str(inp)}", want: "{roc_str(want)}" }},')
print("]\n")
print(r'''spans_str : Sharp.T, Str -> Str
spans_str = |re, hay|
	Sharp.find_all(re, Str.to_utf8(hay))
	|> List.map(|s| "${s.start.to_str()}-${s.end.to_str()}")
	|> Str.join_with(",")

ends_ok : Sharp.T, Str, Str -> Bool
ends_ok = |re, hay, want| {
	ends = Sharp.find_all(re, Str.to_utf8(hay)) |> List.map(|s| s.end.to_str())
	List.all(Str.split_on(want, ","), |w| List.contains(ends, w))
}

# `filler` is derived from argv so the compiler cannot fold the whole run
run : Case, Str -> { ok : Bool, got : Str, skipped : Bool }
run = |c0, filler| {
	c = { ..c0, hay: Str.concat(c0.hay, filler), pat: Str.concat(c0.pat, filler) }
	match Sharp.compile(c.pat) {
		Err(e) =>
			if c.kind == "unsupported" { { ok: True, got: "", skipped: False } } else { { ok: False, got: "COMPILE_ERR: ${Sharp.err_str(e)}", skipped: False } }
		Ok(re) =>
			if c.kind == "matches" {
				got = spans_str(re, c.hay)
				{ ok: got == c.want, got, skipped: False }
			} else if c.kind == "ends" {
				{ ok: ends_ok(re, c.hay, c.want), got: spans_str(re, c.hay), skipped: False }
			} else if c.kind == "unsupported" {
				{ ok: False, got: "compiled: ${Sharp.show(re)}", skipped: False }
			} else {
				{ ok: True, got: "", skipped: True }
			}
	}
}

main! = |args| {
	filler = if List.len(args) > 99 { "x" } else { "" }
	results = List.map(cases, |c| { c, r: run(c, filler) })
	fails = List.keep_if(results, |x| !x.r.ok)
	skipped = List.count_if(results, |x| x.r.skipped)
	lines = List.map(fails, |x| "FAIL ${x.c.file} [${x.c.kind}] /${x.c.pat}/ on \"${x.c.hay}\"\n     want=[${x.c.want}]\n     got =[${x.r.got}]")
	total = List.len(results)
	Stdout.line!(Str.join_with(lines, "\n"))?
	Stdout.line!("\n${(total - List.len(fails)).to_str()}/${total.to_str()} pass (${skipped.to_str()} skipped: nullable_positions need M2)")
}
''')
