#!/usr/bin/env python3
"""Differential against real RE# (plan S2.3).

Defines an ASCII-only corpus in RE# syntax, asks the ResharpDiff harness for
RE#'s answers, converts UTF-16 offsets to byte offsets, and prints a Roc runner
that compares `package`'s `find_all` with them, and its `first_end` /
`longest_end` with RE#'s `FirstEnd` / `LongestEnd`. Unicode is excluded on
purpose: .NET's tables and ours legitimately differ.

    DOTNET_ROOT=~/.dotnet PATH=~/.dotnet:$PATH RESHARP=~/Repositories/resharp-dotnet \
        python3 tools/sharp-diff/gen.py > /tmp/sharp-diff.roc
"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.abspath(os.path.join(HERE, "..", "..", "package", "main.roc"))
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
    # (?i): leading, scoped, classes, and the multi-partner folds (Kelvin sign,
    # long s, final sigma). A bare mid-pattern (?i) and every flag but `i` are
    # parse errors on our side; RE#'s .NET parser takes them, so those rows land
    # in "we reject" and are listed in KNOWN_FLAG_REJECTS below instead.
    "(?i)abc", "(?i)cat", "(?i)[a-z]+", "(?i)k", "(?i)K", "(?i)\\w+", "(?i)a|B",
    "(?i:abc)", "a(?i:bc)", "(?i:[a-f])+", "(?i)(?<=a)b", "(?i)a(?=b)", "(?i)~(_*a_*)",
    "(?i)\\bcat\\b", "(?i)^abc\$", "(?i)color", "(?i)\u017f", "(?i)s", "(?i)\u212a",
]

HAYS = [
    "ABC", "AbC", "CAT cats", "K", "k", "\u212a", "\u017f", "S", "Color COLOUR",
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


# Confirmed RE# bugs (design log, "Fuzz campaign"): for these the runner checks
# our answer against the textbook one, not RE#'s. "REJECT" means we refuse the
# pattern because no rewrite in RE#'s normal form gives the right matches.
KNOWN_RESHARP_BUGS = [
    ("b?^", "b", "REJECT"),                # RE#: 0-1 — `^` cannot hold after a consumed char; nullable before a line anchor
    ("a*^", "xa", "REJECT"),               # RE#: 0-2 — nullable expression before a line anchor
    ("~(b)^", "a", "REJECT"),              # RE#: 0-1
    ("b{0,2}^", "bbc", "REJECT"),          # RE#: 0-3
    ("b_{1,2}", "aab ba", "2-5"),          # RE#: 2-4,4-6 — not leftmost-longest
    ("[^a]&.\\s|\\W*", "abxb a", "0-0,1-1,2-2,3-3,4-5,5-5,6-6"),  # RE#: drops the \s
    ("(?=a&b|c)", "abc", "2-2"),           # RE#: 0-0,2-2
    ("(?<!a.)", "abc", "0-0,1-1,3-3"),     # RE#: 1-1,2-2,3-3
    ("(?<!a.,)", "ab,c", "0-0,1-1,2-2,4-4"),  # RE#: includes 3-3
    ("(\\n?)+(?<! )b+", "a\nbb", "REJECT"),  # RE#: 0-4 — `(\n?)+` cannot match "a"; nullable before a lookbehind
    ("a?\\b\\s", "a b  c,\n\nab", "REJECT"),  # RE#: 0-9
    ("\\s*\\bts\\b", "x ts", "REJECT"),      # RE#: 0-4 (swallows the prefix)
    ("(?<=[ab]\\b)", "aab ba", "REJECT"),     # RE#: 4-4,6-6 — one symbol off
    ("(?=(?<=\\n))", "ca,b\nab", "REJECT"),  # RE#: 4-4 — one symbol off
    ("b?(?!c&d)", "b", "0-1,1-1"),         # RE#: 0-0,1-1
    ("[^a]^ ?|.", "aab ba", "0-1,1-2,2-3,3-4,4-5,5-6"),  # RE#: 2-4
    (".[^a]{1,2}[ab]*(?!\\w.{2}cb?)", "abxb a", "0-4"),  # RE#: 2-5
]

# `(?i)` rows where RE# (through .NET) differs from Unicode simple case folding,
# which is what regex-syntax's table encodes and what Rust's `regex`, our
# `Regex` and Python's `re` all implement. Two families, both verified against
# Python's `re.IGNORECASE` independently of our own output:
#   - .NET's IgnoreCase does not equate U+017F LATIN SMALL LETTER LONG S with
#     `s`/`S`, so `(?i)s` does not match "\u017f" for RE# and does for us.
#   - .NET leaks a SCOPED `(?i:...)` to the whole pattern: `a(?i:bc)` matched
#     "ABC" for RE#, where the `a` is outside the group.
# The value is the textbook answer, which the runner checks OUR result against.
KNOWN_CI_DIVERGENCES = {
    ("(?i)[a-z]+", "\u017f"): "0-2",
    ("a(?i:bc)", "ABC"): "",
    ("a(?i:bc)", "AbC"): "",
    ("(?i)\u017f", "CAT cats"): "7-8",
    ("(?i)\u017f", "S"): "0-1",
    ("(?i)\u017f", "cat cats scatter"): "7-8,9-10",
    ("(?i)\u017f", "the@host now"): "6-7",
    ("(?i)\u017f", "raining cats and dogs"): "11-12,20-21",
    ("(?i)s", "\u017f"): "0-2",
}

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
print("import re.Regex\n")
print("Case : { pat : Str, hay : Str, ok : Bool, want : Str, known : Bool, fe : Str, le : Str }\n")
print("cases : List(Case)")
print("cases = [")
for r in results:
    m = u16_to_bytes(r["hay"])
    want = ",".join(f"{m[s]}-{m[e]}" for s, e in r["matches"]) if r["ok"] else r["err"].split(":")[0]
    fe = str(m[r["firstEnd"]]) if r["ok"] and r["firstEnd"] >= 0 else "-"
    le = str(m[r["longestEnd"]]) if r["ok"] and r["longestEnd"] >= 0 else "-"
    ci = KNOWN_CI_DIVERGENCES.get((r["pat"], r["hay"]))
    if ci is not None:
        print(f'\t{{ pat: "{roc_str(r["pat"])}", hay: "{roc_str(r["hay"])}", ok: True, want: "{roc_str(ci)}", known: True, fe: "?", le: "?" }},')
        continue
    print(f'\t{{ pat: "{roc_str(r["pat"])}", hay: "{roc_str(r["hay"])}", ok: {"True" if r["ok"] else "False"}, want: "{roc_str(want)}", known: False, fe: "{fe}", le: "{le}" }},')
for pat, hay, want in KNOWN_RESHARP_BUGS:
    print(f'\t{{ pat: "{roc_str(pat)}", hay: "{roc_str(hay)}", ok: {"False" if want == "REJECT" else "True"}, want: "{roc_str(want)}", known: True, fe: "?", le: "?" }},')
print("]\n")
print(r'''spans_str : Regex.Pattern, Str -> Str
spans_str = |re, hay|
	Regex.find_all(re, Str.to_utf8(hay))
	|> List.map(|s| "${s.start.to_str()}-${s.end.to_str()}")
	|> Str.join_with(",")

# outcomes: Agree, Differ, RejectBoth (RE# and we both reject), WeAccept (RE#
# rejects, we compile — the wider fragment, not a bug), WeReject (RE# compiles,
# we reject — a bug on our side)
run : Case, Str -> { kind : Str, got : Str }
run = |c0, filler| {
	c = { ..c0, hay: Str.concat(c0.hay, filler), pat: Str.concat(c0.pat, filler) }
	if c.known {
		# a confirmed RE# bug: `want` is the textbook answer ("REJECT" = we refuse)
		match Regex.compile(c.pat) {
			Err(e) => { kind: if c.want == "REJECT" { "KnownBug" } else { "Differ" }, got: Regex.err_str(e) }
			Ok(re) => {
				got = spans_str(re, c.hay)
				{ kind: if c.want != "REJECT" and got == c.want { "KnownBug" } else { "Differ" }, got }
			}
		}
	} else
	match Regex.compile(c.pat) {
		Err(e) => { kind: if c.ok { "WeReject" } else { "RejectBoth" }, got: Regex.err_str(e) }
		Ok(re) =>
			if !c.ok {
				{ kind: "WeAccept", got: spans_str(re, c.hay) }
			} else {
				got = spans_str(re, c.hay)
				{ kind: if got == c.want { "Agree" } else { "Differ" }, got }
			}
	}
}

# RE#'s FirstEnd/LongestEnd start from DFA_R_NOPR, the state with the lookbehind
# prefix STRIPPED, so they answer as if the caller had already verified it:
# `(?<=b)a` anchored at 0 of "a" is 1 for RE# and no match for us. We resolve the
# prefix against offset 0 instead (`Deriv.at_input_start`), which is what the
# structural reference says and what a caller stepping pieces of its own buffer
# needs. Where the two differ, the reference is the arbiter (design log,
# "Dropping RE# parity"), so a difference is reported as PrefixDiff, not a
# failure, and only when the reference sides with us.
end_str : Try(U64, [NoMatch]) -> Str
end_str = |r| match r { Ok(n) => n.to_str(), Err(_) => "-" }

ref_end : Regex.Pattern, List(U8), Bool -> Str
ref_end = |re, hay, first| {
	es = Regex.ends_at_start_ref(re, hay)
	match (if first { List.first(es) } else { List.last(es) }) { Ok(n) => n.to_str(), Err(_) => "-" }
}

# "Agree" | "PrefixDiff" | "Differ"
check_ends : Regex.Pattern, Case, Str -> Str
check_ends = |re, c, hay|
	if c.known or !c.ok {
		"Agree"
	} else {
		h = Str.to_utf8(hay)
		fe = end_str(Regex.first_end(re, h))
		le = end_str(Regex.longest_end(re, h))
		if fe == c.fe and le == c.le {
			"Agree"
		} else if fe == ref_end(re, h, True) and le == ref_end(re, h, False) {
			"PrefixDiff"
		} else {
			"Differ"
		}
	}

main! = |args| {
	filler = if List.len(args) > 99 { "x" } else { "" }
	results = List.map(cases, |c| { c, r: run(c, filler) })
	ends = List.map(cases, |c0| {
		c = { ..c0, hay: Str.concat(c0.hay, filler), pat: Str.concat(c0.pat, filler) }
		match Regex.compile(c.pat) {
			Err(_) => { c, kind: "Agree" }
			Ok(re) => { c, kind: check_ends(re, c, c.hay) }
		}
	})
	end_bad = List.keep_if(ends, |x| x.kind == "Differ")
	Stdout.line!(Str.join_with(List.map(end_bad, |x| "EndDiffer /${x.c.pat}/ on \"${x.c.hay}\"  resharp=[${x.c.fe}/${x.c.le}]"), "\n"))?
	end_pref = List.count_if(ends, |x| x.kind == "PrefixDiff")
	count = |k| List.count_if(results, |x| x.r.kind == k)
	bad = List.keep_if(results, |x| x.r.kind == "Differ" or x.r.kind == "WeReject")
	lines = List.map(bad, |x| "${x.r.kind} /${x.c.pat}/ on \"${x.c.hay}\"  resharp=[${x.c.want}] sharp=[${x.r.got}]")
	Stdout.line!(Str.join_with(lines, "\n"))?
	accepts = List.keep_if(results, |x| x.r.kind == "WeAccept") |> List.map(|x| x.c.pat) |> List.fold([], |acc, p| if List.contains(acc, p) { acc } else { List.append(acc, p) })
	Stdout.line!("we accept, RE# rejects: ${Str.join_with(accepts, "  ")}")?
	Stdout.line!("\nagree=${count("Agree").to_str()} differ=${count("Differ").to_str()} reject_both=${count("RejectBoth").to_str()} we_accept=${count("WeAccept").to_str()} we_reject=${count("WeReject").to_str()} known_resharp_bugs=${count("KnownBug").to_str()} of ${List.len(results).to_str()}")?
	Stdout.line!("ends: differ=${List.len(end_bad).to_str()} prefix_diff=${end_pref.to_str()} of ${List.len(ends).to_str()}")
}
''')
