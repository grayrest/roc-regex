app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
}
import pf.Stdout

R := [].{
	Error : [UnclosedGroup(U64), TrailingBackslash]

	## returns Err for a pattern with an unbalanced paren
	compile : Str -> Try(List(U8), R.Error)
	compile = |s| {
		b = Str.to_utf8(s)
		opens = List.len(List.keep_if(b, |c| c == 40))
		closes = List.len(List.keep_if(b, |c| c == 41))
		if opens != closes {
			Err(UnclosedGroup(opens - closes))
		} else {
			Ok(b)
		}
	}

	## caller-side unwrap that crashes
	unwrap : Try(List(U8), R.Error) -> List(U8)
	unwrap = |r|
		match r {
			Ok(v) => v
			Err(UnclosedGroup(n)) => crash "regex: ${n.to_str()} unclosed group(s)"
			Err(TrailingBackslash) => crash "regex: trailing backslash"
		}
}

good : List(U8)
good = R.unwrap(R.compile("a(bc)d"))

main! = |_args| Stdout.line!(List.len(good).to_str())
