app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	re: "../package-dfa/main.roc",
}
import pf.Stdout
import re.Regex

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
	{ pat: "[α-ω]+", hay: "abγδεxy", want: "2-8" },
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

# `find` walks a GROWING PREFIX of the haystack (Regex.find_chunked), so a
# needle past the first few rounds exercises a path the short cases above never
# reach. Each check asserts the three entry points agree: `find` must return
# `find_all`'s first span, and `is_match` must agree that there is one.
long_pats : List(Str)
long_pats = ["zqxjv", "[0-9]{2,4}", "\\w+@\\w+", "ZQ|QZ", "q[a-z]+v", "nomatchhere", "\\bzq\\b"]

long_hay : List(U8)
long_hay = {
	pad = List.repeat('.', 100000)
	List.join([pad, Str.to_utf8(" zqxjv42@wq ZQ zq "), pad])
}

run_long : Str -> { ok : Bool, got : Str }
run_long = |src| {
	re = Regex.unwrap(Regex.compile(src))
	span_str = |r| match r { Ok(sp) => "${sp.start.to_str()}-${sp.end.to_str()}", Err(_) => "none" }
	want = span_str(List.first(Regex.find_all(re, long_hay)))
	got = span_str(Regex.find(re, long_hay))
	im = Regex.is_match(re, long_hay)
	{ ok: got == want and im == (want != "none"), got: "${got} (find_all ${want})" }
}

main! = |_a| {
	results = List.concat(List.map(cases, run_one), List.map(long_pats, run_long))
	cases_all = List.concat(cases, List.map(long_pats, |p| { pat: p, hay: "<200 KB>", want: "= find_all's first span" }))
	passed = List.len(List.keep_if(results, |r| r.ok))
	total = List.len(results)
	lines = List.map2(cases_all, results, |c, r| {
		mark = if r.ok { "ok  " } else { "FAIL" }
		"${mark} /${c.pat}/ want ${c.want} got ${r.got}"
	})
	Stdout.line!(Str.join_with(lines, "\n"))?
	Stdout.line!("\n${passed.to_str()}/${total.to_str()} passed")
}
