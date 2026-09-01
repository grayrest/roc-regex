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

build : List(U64), U64 -> List(U64)
build = |acc, n|
	if n == 0 {
		acc
	} else {
		build(List.append(acc, spin(n, 10_000_000)), n - 1)
	}

table : List(U64)
table = build([], 100)

main! = |args| {
	i = List.len(args)
	match List.get(table, i) {
		Ok(v) => Stdout.line!(v.to_str())
		Err(_) => Stdout.line!("oob")
	}
}
