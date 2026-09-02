app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	re: "../package/main.roc",
}
import pf.Stdout
import re.Regex

# each case: pattern, haystack, expected find result as "start-end" or "none"
Case : { pat : Str, hay : Str, want : Str }

cases : List(Case)
cases = [
	{ pat: "a", hay: "a", want: "0-1" },
	{ pat: "a", hay: "z", want: "none" },
	{ pat: "abc", hay: "xxabcyy", want: "2-5" },
	{ pat: "a+", hay: "baaac", want: "1-4" },
	{ pat: "a*", hay: "bbb", want: "0-0" },
	{ pat: "a?b", hay: "xb", want: "1-2" },
	{ pat: "(foo|bar|baz)", hay: "a bar b", want: "2-5" },
	{ pat: "[a-z]+", hay: "  Hello99", want: "3-7" },
	{ pat: "[^0-9]+", hay: "abc123", want: "0-3" },
	{ pat: "\\d{2,4}", hay: "x12345", want: "1-5" },
	{ pat: "\\w+", hay: "  foo_bar!", want: "2-9" },
	{ pat: "\\bcat\\b", hay: "a cat!", want: "2-5" },
	{ pat: "\\bcat\\b", hay: "cats", want: "none" },
	{ pat: "^abc$", hay: "abc", want: "0-3" },
	{ pat: "^abc$", hay: "abcd", want: "none" },
	{ pat: "a.c", hay: "a\nc axc", want: "4-7" },
	{ pat: "colou?r", hay: "color", want: "0-5" },
	{ pat: "(ab)+", hay: "xababab", want: "1-7" },
	{ pat: "a{3}", hay: "aaaa", want: "0-3" },
	{ pat: "a.*?b", hay: "axbxb", want: "0-3" },
]

run_one : Case -> { ok : Bool, got : Str }
run_one = |c| {
	re = Regex.unwrap(Regex.compile(c.pat))
	got =
		match Regex.find_str(re, c.hay) {
			Ok(s) => "${s.start.to_str()}-${s.end.to_str()}"
			Err(_) => "none"
		}
	{ ok: got == c.want, got }
}

main! = |_a| {
	results = List.map(cases, run_one)
	passed = List.len(List.keep_if(results, |r| r.ok))
	total = List.len(results)
	lines = List.map2(cases, results, |c, r| {
		mark = if r.ok { "ok  " } else { "FAIL" }
		"${mark} /${c.pat}/ on \"${c.hay}\"  want ${c.want} got ${r.got}"
	})
	Stdout.line!(Str.join_with(lines, "\n"))?
	Stdout.line!("\n${passed.to_str()}/${total.to_str()} passed")
}
