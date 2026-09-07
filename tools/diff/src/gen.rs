// Emit a Roc test corpus: for each (pattern, haystack) in the M1 subset, the
// leftmost-first find_iter spans as computed by the Rust regex crate (the oracle).
use regex::Regex;

fn main() {
    // patterns within the M1 subset (no \p, no (?i), no backrefs)
    let pats = [
        "a", "abc", "a+", "a*", "a?", "a?b", "ab?c", "a{2}", "a{2,4}", "a{2,}",
        "[a-z]+", "[^0-9]+", "[abc]+", "[a-fA-F0-9]+", "\\d+", "\\w+", "\\s+",
        "\\d{2,4}", "foo|bar|baz", "(ab|cd)+", "a.c", "a.*c", "a.*?c",
        "\\bcat\\b", "\\Bcat", "^abc", "abc$", "^$", "\\w+@\\w+",
        "^\\w+", "\\w+$", "^\\w+$", "a$", "^a", "cat$", "^cat",
        "\\bcat$", "^cat\\b", "foo$|bar", "^a|b", "[0-9]+$", "^.*$",
        "(\\w+)-(\\w+)", "colou?r", "[0-9]{1,3}(\\.[0-9]{1,3}){3}",
        "a|", "|a", "(a*)*", "(a|b)*abb", ".*", "x*", "\\d*",
        "[-+]?\\d+", "\\w{3}", "(foo)(bar)?", "a[bc]?d",
    ];
    let hays = [
        "", "a", "aaa", "abc", "z", "  Hello99  ", "foo bar baz",
        "cat cats scatter", "192.168.1.100", "key=val other=x",
        "2026-09-02", "a-b-c", "color colour", "the@host now",
        "aabbabb", "xxxxx", "12345", "  \t ", "abcabcabc", "+42 -7",
        // non-ASCII: exercises Unicode word-boundary classification on the DFA
        // (word-ness of multi-byte codepoints) and multibyte span offsets
        "café résumé", "αβγ foo", "naïve cat", "foo·bar", "1α cat β2",
        "Москва cat", "日本語 cat text",
    ];
    println!("app [main!] {{");
    println!("\tpf: platform \"https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst\",");
    println!("\tre: \"/Users/grayrest/dev/roc/regex/package-dfa/main.roc\",");
    println!("}}");
    println!("import pf.Stdout");
    println!("import re.Dfa\n");
    println!("cases : List({{ pat : Str, hay : Str, want : Str }})");
    println!("cases = [");
    for p in pats {
        let re = match Regex::new(p) { Ok(r) => r, Err(_) => continue };
        for h in hays {
            // all non-overlapping match spans, byte offsets
            let spans: Vec<String> = re.find_iter(h).map(|m| format!("{}-{}", m.start(), m.end())).collect();
            let want = spans.join(",");
            let pe = roc_str(p);
            let he = roc_str(h);
            println!("\t{{ pat: \"{}\", hay: \"{}\", want: \"{}\" }},", pe, he, want);
        }
    }
    // Specific (pattern, haystack) pairs from the 2026-09-05 code review. The
    // cross product above never pairs a pattern with the haystack that breaks
    // it, so each fix gets its own case here. A pattern the Rust crate REJECTS
    // is expected to be rejected by this engine too ("COMPILE_ERR").
    let pairs: &[(&str, &str)] = &[
        // reverse DFA must use all-matches semantics (leftmost start)
        ("a*?b", "aab"),
        ("\\w+?@\\w+", "ab@cd"),
        ("(|a)b", "ab"),
        ("(?:|a)b", "ab"),
        ("(?:b|ab)c", "abc"),
        ("(?:a|ba)c", "bac"),
        ("x(a|)y", "xay"),
        // inline-start: every boundary must accept the same byte set
        ("[ax][ab]?[axc]+[de]", "aabcd"),
        ("[ax][ab]?[axc]+[de]", "xxabcd aabcd"),
        // ... while the shapes the optimization exists for still work
        ("[A-Za-z]+", "  Hello99  "),
        ("\\w+\\s+\\w+", "foo bar baz"),
        ("\\d{2,4}", "192.168.1.100"),
        // reverse-inner literal prefilter: LEFT must be able to stop at the
        // first occurrence of the literal (hard separator, or a single class)
        ("(?:xab)*ab", "xabab"),
        ("(?:[ab][ab]@c)?[bB]@", "ab@cb@"),
        ("\\w+@\\w+", "the@host now"),
        (".*cat", "cat cats scatter"),
        (".*b", "abcb"),
        ("[a-z]*b", "aabxb"),
        ("(?:ab)*ab", "ababab"),
        // required-prefix extraction must stop at a partially-literal group
        ("(ab?)c", "abc"),
        ("x(ab?)c", "xabc"),
        ("(ab?)c|xyz", "abc"),
        ("(a|ab)c", "abc"),
        ("(ab)?c", "c"),
        // buried anchors -> PikeVM engine; the first-byte SET now prefilters
        // find_all too, not just find
        ("(^a|c|x)d", "ad"),
        ("(^a|c|x)d", "zcd xd ad"),
        ("(^a|c|x)d", "zzz"),
        ("(^a|c|x)d", ""),
        ("(a$|c|x)d", "cd xd"),
        // repetition bounds are validated, not wrapped
        ("a{2,1}", "aa"),
        ("a{99999999999}", "aa"),
        // unsupported escapes are rejected instead of silently mis-parsed
        ("[\\b]", "b"),
        ("\\0", "a"),
        ("\\1", "1"),
    ];
    for (p, h) in pairs {
        let want = match Regex::new(p) {
            Ok(re) => re.find_iter(h).map(|m| format!("{}-{}", m.start(), m.end())).collect::<Vec<_>>().join(","),
            Err(_) => "COMPILE_ERR".to_string(),
        };
        println!("\t{{ pat: \"{}\", hay: \"{}\", want: \"{}\" }},", roc_str(p), roc_str(h), want);
    }
    println!("]\n");
    println!("{}", RUNNER);
}

fn roc_str(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"").replace('\t', "\\t").replace('\n', "\\n")
}

const RUNNER: &str = r#"spans_str : Dfa.T, Str -> Str
spans_str = |re, hay|
	Dfa.find_all(re, Str.to_utf8(hay))
	|> List.map(|s| "${s.start.to_str()}-${s.end.to_str()}")
	|> Str.join_with(",")

# `find` and `is_match` share `find_all`'s plan, so they are checked against the
# same oracle: the first match must be find_all's first span, and is_match must
# agree with whether there is one.
first_str : Dfa.T, Str -> Str
first_str = |re, hay|
	match Dfa.find(re, Str.to_utf8(hay)) {
		Ok(s) => "${s.start.to_str()}-${s.end.to_str()}"
		Err(_) => ""
	}

main! = |_a| {
	results = List.map(cases, |c| {
		got = match Dfa.compile(c.pat) {
			Ok(re) => {
				all = spans_str(re, c.hay)
				want_first = List.first(Str.split_on(c.want, ",")) ?? ""
				first = first_str(re, c.hay)
				im = Dfa.is_match(re, Str.to_utf8(c.hay))
				if first != want_first {
					"find=${first} want=${want_first}"
				} else if im != (c.want != "") {
					"is_match=${if im { "T" } else { "F" }}"
				} else {
					all
				}
			}
			Err(_) => "COMPILE_ERR"
		}
		{ c, ok: got == c.want, got }
	})
	fails = List.keep_if(results, |r| !r.ok)
	lines = List.map(fails, |r| "MISMATCH /${r.c.pat}/ on \"${r.c.hay}\"  rust=[${r.c.want}] roc=[${r.got}]")
	total = List.len(results)
	passed = total - List.len(fails)
	Stdout.line!(Str.join_with(lines, "\n"))?
	Stdout.line!("\n${passed.to_str()}/${total.to_str()} agree with Rust")
}
"#;
