app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	re: "../../package-sharp/main.roc",
}
import pf.Stdout
import re.Sharp

# RE#'s node-layer tests (_02_NodeTests, _03_SubsumptionTests,
# _04_DerivativeTests), transcribed. `want` lists the printed forms RE# accepts;
# a case passes when our printer produces any of them. Kinds:
#   conv      the converted (rewritten) pattern
#   der       derivative of the raw pattern by the input's first codepoint
#   derts     derivative of `_*·pattern` by the input's first codepoint
#   derrev    End-location derivative of the reverse pattern by the input's last codepoint
#   derat     derivative of the raw pattern by the codepoint at `pos`
#   noprefix  the pattern with its lookbehind prefix stripped
#   revfixed  fixed length of the reverse pattern ("none" when not fixed)
#   minterms  the minterm classes, `;`-joined (the Invalid class prints as `\i`)
#   ident     "der1 == root" / "der1_rev == rev" identity checks ("true"/"false")

Case : { kind : Str, pat : Str, input : Str, pos : U64, want : List(Str) }

c : Str, Str, Str, List(Str) -> Case
c = |kind, pat, input, want| { kind, pat, input, pos: 0, want }

cases : List(Case)
cases = [
	# --- _02_NodeTests -------------------------------------------------------
	c("conv", "(_*B_*&_*A_*)", "", ["(_*A_*&_*B_*)", "(_*B_*&_*A_*)"]),
	c("conv", "(_*A_*&_*B_*)&_*B_*", "", ["(_*B_*&_*A_*)", "(_*A_*&_*B_*)"]),
	c("conv", "([a-zA-Z]+)Huck|([a-zA-Z]+)Saw", "", ["[A-Za-z]+(Huck|Saw)", "[A-Za-z]+(Saw|Huck)"]),
	c("conv", "t(s?|s)day", "", ["ts?day"]),
	c("conv", "1111", "", ["1{4}", "(11){2}"]),
	c("conv", "[\\s\\S]*", "", ["_*", "[\\s\\S]*"]),
	c("conv", ".(?=A.*)", "", [".(?=A)", ".(?=A.*)"]),
	c("conv", "(?<Time>^\\d)", "", ["^\\d", "^φ", "(?<=(\\n|\\A))φ"]),
	c("conv", "Twain", "", ["Twain"]),
	c("noprefix", "(?<=author).*&.*and.*", "", ["(.*and.*&.*)", ".*and.*", "(.*&.*and.*)"]),
	c("noprefix", "\\b11", "", ["11"]),
	c("noprefix", "(?<=aaa).*", "", [".*"]),
	c("minterms", "(a|b|c)", "", ["[^a-c];[a-c];\\i"]),
	c("minterms", "[a-q][^u-z]{13}x", "", ["[^a-qu-z];[a-q];[u-wyz];x;\\i"]),
	c("revfixed", "Twain", "", ["5"]),
	c("revfixed", "[a-q][^u-z]{13}x", "", ["15"]),
	c("revfixed", "\\b1\\b", "", ["1"]),
	c("ident", "((_*t|)neW_*&_*erohsa_*&_*lirpA_*&_*yadsruhT_*)", "test", ["true"]),
	c("ident", "((nglish_*|_*English_*)&~(_*\\n\\n_*)\\n&_*King_*&_*Paris_*)", "English", ["true"]),
	c("identrev", "_*Huck_*", "g", ["true"]),
	# --- _03_SubsumptionTests --------------------------------------------------
	c("der", "((?<=.*).*&~(.*A.*))", "A", ["⊥"]),
	c("der", "(.* and .*|and .*)&.*", "aaa", ["(.* and .*|nd .*)", "(nd .*|.* and .*)", "(.* a)?nd .*", "((ε|.* a)nd .*&.*)", "(.*&(.* a|ε)nd .*)", "(.*&(ε|.* a)nd .*)", "((.* a|ε)nd .*&.*)"]),
	c("der", "(.*&.*s)", "aaa", [".*s"]),
	c("der", "(a*|.*)", "aaa", [".*"]),
	c("conv", "Huck[a-zA-Z]+|Saw[a-zA-Z]+", "", ["(Huck|Saw)[A-Za-z]+", "(Saw|Huck)[A-Za-z]+"]),
	c("der", ".*t.*hat.*", "ttt", [".*(t.*)?hat.*", ".*(hat.*|t.*hat.*)", ".*(t.*hat.*|hat.*)", ".*hat.*"]),
	c("derts", "^a*b", "a", ["(_*^)?a*b", "(a*b|_*^a*b)", "(_*^a*b|a*b)", "(a*b|_*(?<=(\\n|\\A))a*b)", "(a*b|_*(?<=(\\A|\\n))a*b)"]),
	c("conv", "(.*|(.*11.*|1.*))", "", [".*"]),
	c("conv", ".*(?=.*def)&.*def", "", [".*def(?=.*def_*)", ".*def(?=.*def)"]),
	c("conv", "(?<=abc).*&.*def", "", ["(?<=abc).*def"]),
	c("conv", "a|s", "", ["[as]"]),
	c("conv", "at|st", "", ["[as]t"]),
	c("conv", "(.*ereht)?.*", "", [".*"]),
	c("der", ".*t.*hat", "ttt", [".*hat"]),
	c("conv", "(.*1)?(.*1){2,}", "", ["(.*1){2,}"]),
	c("conv", "(.*1)?.*1", "", [".*1"]),
	c("conv", ".*1.*1", "", ["(.*1){2,}"]),
	c("conv", ".*1.*1$", "", ["(.*1){2,}$"]),
	c("conv", ".*1.*1.*1$", "", ["(.*1){3,}$"]),
	c("conv", "(.*1)?.*a", "", [".*a"]),
	c("conv", "((.*1)?|b).*a", "", [".*a"]),
	c("conv", "(.*|)", "", [".*"]),
	# --- _04_DerivativeTests ---------------------------------------------------
	c("der", "ab", "ab", ["b"]),
	c("derts", "ab", "ab", ["(b|_*ab)", "(_*ab|b)", "(ε|_*a)b", "(_*a|ε)b", "(_*a)?b"]),
	c("der", "_", "324", ["⊥*", "ε"]),
	{ kind: "derat", pat: "(?<=-.*).*", input: "-aaaa-", pos: 5, want: ["(.*|(?<=.*).*)", "((?<=.*).*|.*)", "(?<=.*).*", ".*"] },
	c("der", "^\\d$", "1", ["$"]),
	c("der", "\\b11", "11", ["1"]),
	{ kind: "derat", pat: "(?<=\\s)22", input: "1 2", pos: 1, want: ["22"] },
	{ kind: "derat", pat: "(?<=\\d)a", input: "1a", pos: 0, want: ["a"] },
	c("der", "^\\d+$", "123", ["\\d*$", "φ*$"]),
	c("der", "~(.*11.*)", "1", ["~((.*1)?1.*)", "~((1|.*11).*)", "~((.*11|1).*)"]),
	{ kind: "derat", pat: "^((0?[13578]a)|(0?[13456789]a))$", input: "4a", pos: 0, want: ["a$"] },
	c("der", "((?<=B.*).*&~(.*A.*))", "BA", ["(?<=.*)(.*&~(.*A.*))", "(?<=.*)(~(.*A.*)&.*)", "(~(.*A.*)&.*)", ".*(.*&~(.*A.*))", ".*(~(.*A.*)&.*)"]),
	c("derrev", "..g", "gggg", [".{2,2}", "..", ".{2}"]),
	c("derts", "(.*a.*&.*c.*&.*b.*)", "ccab", ["((.*a.*&.*b.*)|_*(.*a.*&.*c.*&.*b.*))", "((.*a.*&.*b.*)|_*(.*c.*&.*a.*&.*b.*))", "((.*b.*&.*a.*)|_*(.*b.*&.*c.*&.*a.*))", "((.*b.*&.*a.*)|_*(.*c.*&.*b.*&.*a.*))", "(_*(.*a.*&.*b.*&.*c.*)|(.*a.*&.*b.*))", "(_*(.*a.*&.*c.*&.*b.*)|(.*a.*&.*b.*))", "(_*(.*b.*&.*c.*&.*a.*)|(.*b.*&.*a.*))", "(_*(.*c.*&.*a.*&.*b.*)|(.*a.*&.*b.*))", "(_*(.*c.*&.*b.*&.*a.*)|(.*b.*&.*a.*))", "((.*b.*&.*a.*)|_*(.*b.*&.*a.*&.*c.*))", "(_*(.*b.*&.*a.*&.*c.*)|(.*b.*&.*a.*))", "((.*a.*&.*b.*)|_*(.*a.*&.*b.*&.*c.*))"]),
	c("der", "(?<!a)b", "bb", ["(~(_*a)b)?", "b?"]),
]

# `φ` in RE#'s expectations stands for any large (Unicode) class; accept a
# candidate when it equals the expectation, or when the expectation contains φ
# and the candidate matches with any bracket class in the φ position.
matches_want : Str, Str -> Bool
matches_want = |got, want|
	if got == want {
		True
	} else if Str.contains(want, "φ") {
		# crude: compare with every `[...]` class in `got` replaced by φ
		Str.replace_each(got, "[", "\u(1)") |> Str.replace_each("]", "\u(2)") |> squash_classes == want
	} else {
		False
	}

# replace each \u(1)...\u(2) run (a bracket class) by φ
squash_classes : Str -> Str
squash_classes = |s| {
	bytes = Str.to_utf8(s)
	out = List.fold(bytes, { acc: [], depth: 0 }, |st, b|
		if b == 1 { { acc: List.concat(st.acc, Str.to_utf8("φ")), depth: st.depth + 1 } }
		else if b == 2 { { acc: st.acc, depth: st.depth - 1 } }
		else if st.depth > 0 { st }
		else { { acc: List.append(st.acc, b), depth: 0 } })
	Str.from_utf8_lossy(out.acc)
}

run : Case, Str -> { ok : Bool, got : Str }
run = |c0, filler| {
	pat = Str.concat(c0.pat, filler)
	match Sharp.compile(pat) {
		Err(e) => { ok: False, got: "COMPILE_ERR ${Sharp.err_str(e)}" }
		Ok(re) => {
			got =
				if c0.kind == "conv" { Sharp.show(re) }
				else if c0.kind == "der" { Sharp.der1(re, c0.input) }
				else if c0.kind == "derts" { Sharp.der1_ts(re, c0.input) }
				else if c0.kind == "derrev" { Sharp.der1_rev(re, c0.input) }
				else if c0.kind == "derat" { Sharp.der1_at(re, c0.input, c0.pos) }
				else if c0.kind == "noprefix" { Sharp.show_noprefix(re) }
				else if c0.kind == "revfixed" { match Sharp.rev_fixed_len(re) { Ok(n) => n.to_str(), Err(_) => "none" } }
				else if c0.kind == "minterms" { Str.join_with(Sharp.minterms(re), ";") }
				else if c0.kind == "ident" { if Sharp.der1(re, c0.input) == Sharp.show(re) { "true" } else { "false: ${Sharp.der1(re, c0.input)}" } }
				else if c0.kind == "identrev" { if Sharp.der1_rev(re, c0.input) == Sharp.show_rev(re) { "true" } else { "false: ${Sharp.der1_rev(re, c0.input)} vs ${Sharp.show_rev(re)}" } }
				else { "?" }
			{ ok: List.any(c0.want, |w| matches_want(got, w)), got }
		}
	}
}

main! = |args| {
	filler = if List.len(args) > 99 { "x" } else { "" }
	results = List.map(cases, |c1| { c: c1, r: run(c1, filler) })
	fails = List.keep_if(results, |x| !x.r.ok)
	lines = List.map(fails, |x| "FAIL [${x.c.kind}] /${x.c.pat}/ ${x.c.input}\n     want=${Str.join_with(x.c.want, " | ")}\n     got =${x.r.got}")
	Stdout.line!(Str.join_with(lines, "\n"))?
	Stdout.line!("\n${(List.len(results) - List.len(fails)).to_str()}/${List.len(results).to_str()} node-layer cases pass")
}
