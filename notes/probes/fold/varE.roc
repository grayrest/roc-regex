app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
}
import pf.Stdout

E := [].{
	Eng : { prog : List(U64) }

	spin : U64, U64 -> U64
	spin = |acc, n|
		if n == 0 { acc } else { E.spin(acc + (n % 7), n - 1) }

	compile : Str -> E.Eng
	compile = |s| {
		base = E.spin(0, 200_000_000)
		{ prog: [base, Str.count_utf8_bytes(s)] }
	}

	sum : E.Eng -> U64
	sum = |e| List.fold(e.prog, 0, |a, b| a + b)
}

re : E.Eng
re = E.compile("abc")

main! = |_args| Stdout.line!(E.sum(re).to_str())
