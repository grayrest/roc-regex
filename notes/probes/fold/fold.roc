app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
}

import pf.Stdout

spin : U64, U64 -> U64
spin = |acc, n|
	if n == 0 {
		acc
	} else {
		spin(acc + (n % 7), n - 1)
	}

total : U64
total = spin(0, 2_000_000_000)

main! = |_args|
	Stdout.line!(total.to_str())
