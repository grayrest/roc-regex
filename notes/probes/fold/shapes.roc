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

Inst : [Byte(U8), Split(U64, U64), Jmp(U64), Match]

prog : List(Inst)
prog = {
	base = spin(0, 300_000_000)
	[Byte((base % 256).to_u8_wrap()), Split(1, 2), Jmp(0), Match]
}

rows : List(List(U64))
rows = {
	b = spin(0, 300_000_000)
	List.map([0, 1, 2], |i| List.map([0, 1, 2, 3], |j| b + i * 4 + j))
}

named : { name : Str, ids : List(U64) }
named = {
	b = spin(0, 300_000_000)
	{ name: "abc", ids: [b, b + 1] }
}

main! = |_args| {
	n0 = List.len(prog)
	n1 = List.len(rows)
	n2 = Str.count_utf8_bytes(named.name)
	Stdout.line!("${n0.to_str()} ${n1.to_str()} ${n2.to_str()}")
}
