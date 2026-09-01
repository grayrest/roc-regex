app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
}

import pf.Stdout

spin : U64, U64 -> U64
spin = |acc, n|
	if n == 0 {
		acc
	} else {
		spin(acc + (n % 7), n - 1)
	}

main! = |_args| {
	x = spin(0, 1_000_000_000)
	Stdout.line!(x.to_str())
}
