app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
}
import pf.Stdout

R := [].{
	spin : U64, U64 -> U64
	spin = |acc, n|
		if n == 0 { acc } else { R.spin(acc + (n % 7), n - 1) }

	compile : Str -> U64
	compile = |s| {
		h = List.fold(Str.to_utf8(s), 7, |a, c| a * 31 + c.to_u64())
		R.spin(0, 500_000_000 + (h % 1000))
	}

	matches : Str, List(U8) -> U64
	matches = |pat, hay| R.compile(pat) + List.len(hay)
}

main! = |args| {
	hay = Str.to_utf8(if List.len(args) > 99 { "zz" } else { "hello" })
	x = R.compile("a+b")
	Stdout.line!((x + List.len(hay)).to_str())
}
