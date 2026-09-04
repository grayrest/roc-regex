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
    println!("\tre: \"/Users/grayrest/dev/roc/regex/package/main.roc\",");
    println!("}}");
    println!("import pf.Stdout");
    println!("import re.Regex\n");
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
    println!("]\n");
    println!("{}", RUNNER);
}

fn roc_str(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"").replace('\t', "\\t").replace('\n', "\\n")
}

const RUNNER: &str = r#"spans_str : Regex.T, Str -> Str
spans_str = |re, hay|
	Regex.find_all(re, Str.to_utf8(hay))
	|> List.map(|s| "${s.start.to_str()}-${s.end.to_str()}")
	|> Str.join_with(",")

main! = |_a| {
	results = List.map(cases, |c| {
		got = match Regex.compile(c.pat) {
			Ok(re) => spans_str(re, c.hay)
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
