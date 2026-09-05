#!/usr/bin/env python3
"""Differential against real RE# (plan S2.3).

Defines an ASCII-only corpus in RE# syntax, asks the ResharpDiff harness for
RE#'s answers, converts UTF-16 offsets to byte offsets, and prints a Roc runner
that compares package-sharp's `find_all` with them. Unicode is excluded on
purpose: .NET's tables and ours legitimately differ.

    DOTNET_ROOT=~/.dotnet PATH=~/.dotnet:$PATH RESHARP=~/Repositories/resharp-dotnet \
        python3 tools/sharp-diff/gen.py > /tmp/sharp-diff.roc
"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.abspath(os.path.join(HERE, "..", "..", "package-sharp", "main.roc"))
PLATFORM = "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst"
HARNESS = os.path.join(HERE, "ResharpDiff", "bin", "Release", "net10.0", "ResharpDiff.dll")

PATS = [
    # literals, classes, quantifiers
    "a", "abc", "a+", "a*", "a?", "a?b", "ab?c", "a{2}", "a{2,4}", "a{2,}", "a{0,2}b",
    "[a-z]+", "[^0-9]+", "[abc]+", "[a-fA-F0-9]+", "[0-9]+", "\\d{2,4}", "\\w+", "\\s+", "\\S+",
    "foo|bar|baz", "(ab|cd)+", "a.c", "a.*c", "(a|ab)+", "(ab|a)+", "a|", "|a", "(a*)*", "(a|b)*abb",
    ".*", "x*", "\\d*", "[-+]?\\d+", "\\w{3}", "(foo)(bar)?", "a[bc]?d", "colou?r", ".", "_", "_*",
    # boolean ops
    "_*a_*", "_*cat_*&_*dog_*", "~(_*a_*)", "~(_*11_*)", ".*a.*&.*b.*", "c...&...s", "~(a)", "~(_*)",
    "a_*&~(_*b_*)", "(_*a_*)&~(_*b_*)", "~(.*\\n\\n.*)", "[a-z]+&~(_*e_*)", ".*&.*", "a&b", "~(_*xyz_*)",
    "_{2,5}", "_*&_*", "(a|b)&(b|c)", "~(~(a))",
    # lookarounds
    "a(?=b)", "a(?!b)", "(?<=b)a", "(?<!b)a", "\\w+(?=_*z)", "(?<=z_*)\\w+", ".(?=[A-Z])", "(?=a)", "(?<=a)",
    "a(?=.*c)", "bb(?=aa)", "(?<=aaa).*", ".*(?=aaa)", "(ab)+(?=_)", "(?<=\\W)hello(?=\\W)", "1(?=.*3)(?=.*2)",
    "(?<=a.*).(?=.*c)", "a+\\b(?=.*x)",
    # anchors and word boundaries
    "^abc", "abc$", "^$", "^a", "a$", "^.*$", "\\Aa", "a\\z", "\\A.*\\z", "^\\d+$", "^(a|b)$",
    "\\bcat\\b", "\\bcat", "cat\\b", "\\b1\\b", "\\b-", "1\\b-", "a\\b", "\\b\\w+\\b",
    # unsupported in RE# (expected rejections)
    "\\Bcat", "a(?=bb)b", "a*?", "(?<=a)b|(?<=c)d", "~(\\ba)",
]

HAYS = [
    "", "a", "aaa", "abc", "z", "  Hello99  ", "foo bar baz", "cat cats scatter", "192.168.1.100",
    "key=val other=x", "2026-09-02", "a-b-c", "color colour", "the@host now", "aabbabb", "xxxxx",
    "12345", "  \t ", "abcabcabc", "+42 -7", "cat and dog", "dog and cat", "Aa11aBaAA", "__ababab_c",
    "line one\nline two\n\nline four", "raining cats and dogs", "1 23", "a x c", " hello ", "b\nab\na",
    "zabc abc", "1-2", "a ", "ab", "__abab__ab__",
]


def roc_str(s):
    out = []
    for ch in s:
        if ch == "\\": out.append("\\\\")
        elif ch == '"': out.append('\\"')
        elif ch == "\n": out.append("\\n")
        elif ch == "\t": out.append("\\t")
        elif ch == "$": out.append("\\$")
        elif ord(ch) < 32: out.append("\\u(%x)" % ord(ch))
        else: out.append(ch)
    return "".join(out)


def u16_to_bytes(s):
    m, u, b = {}, 0, 0
    for ch in s:
        m[u] = b
        u += 2 if ord(ch) > 0xFFFF else 1
        b += len(ch.encode("utf-8"))
    m[u] = b
    return m


cases = [{"pat": p, "hay": h} for p in PATS for h in HAYS]
with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
    json.dump(cases, f)
    path = f.name
out = subprocess.run(["dotnet", HARNESS, path], capture_output=True, text=True, check=True).stdout
results = json.loads(out)
os.unlink(path)

print("app [main!] {")
print(f'\tpf: platform "{PLATFORM}",')
print(f'\tre: "{PKG}",')
print("}")
print("import pf.Stdout")
print("import re.Sharp\n")
print("Case : { pat : Str, hay : Str, ok : Bool, want : Str }\n")
print("cases : List(Case)")
print("cases = [")
for r in results:
    m = u16_to_bytes(r["hay"])
    want = ",".join(f"{m[s]}-{m[e]}" for s, e in r["matches"]) if r["ok"] else r["err"].split(":")[0]
    print(f'\t{{ pat: "{roc_str(r["pat"])}", hay: "{roc_str(r["hay"])}", ok: {"True" if r["ok"] else "False"}, want: "{roc_str(want)}" }},')
print("]\n")
print(r'''spans_str : Sharp.T, Str -> Str
spans_str = |re, hay|
	Sharp.find_all(re, Str.to_utf8(hay))
	|> List.map(|s| "${s.start.to_str()}-${s.end.to_str()}")
	|> Str.join_with(",")

# outcomes: Agree, Differ, RejectBoth (RE# and we both reject), WeAccept (RE#
# rejects, we compile — the wider fragment, not a bug), WeReject (RE# compiles,
# we reject — a bug on our side)
run : Case, Str -> { kind : Str, got : Str }
run = |c0, filler| {
	c = { ..c0, hay: Str.concat(c0.hay, filler), pat: Str.concat(c0.pat, filler) }
	match Sharp.compile(c.pat) {
		Err(e) => { kind: if c.ok { "WeReject" } else { "RejectBoth" }, got: Sharp.err_str(e) }
		Ok(re) =>
			if !c.ok {
				{ kind: "WeAccept", got: spans_str(re, c.hay) }
			} else {
				got = spans_str(re, c.hay)
				{ kind: if got == c.want { "Agree" } else { "Differ" }, got }
			}
	}
}

main! = |args| {
	filler = if List.len(args) > 99 { "x" } else { "" }
	results = List.map(cases, |c| { c, r: run(c, filler) })
	count = |k| List.count_if(results, |x| x.r.kind == k)
	bad = List.keep_if(results, |x| x.r.kind == "Differ" or x.r.kind == "WeReject")
	lines = List.map(bad, |x| "${x.r.kind} /${x.c.pat}/ on \"${x.c.hay}\"  resharp=[${x.c.want}] sharp=[${x.r.got}]")
	Stdout.line!(Str.join_with(lines, "\n"))?
	accepts = List.keep_if(results, |x| x.r.kind == "WeAccept") |> List.map(|x| x.c.pat) |> List.fold([], |acc, p| if List.contains(acc, p) { acc } else { List.append(acc, p) })
	Stdout.line!("we accept, RE# rejects: ${Str.join_with(accepts, "  ")}")?
	Stdout.line!("\nagree=${count("Agree").to_str()} differ=${count("Differ").to_str()} reject_both=${count("RejectBoth").to_str()} we_accept=${count("WeAccept").to_str()} we_reject=${count("WeReject").to_str()} of ${List.len(results).to_str()}")
}
''')
