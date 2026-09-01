Eng := { prog : List(U64) }.{
	spin : U64, U64 -> U64
	spin = |acc, n|
		if n == 0 { acc } else { Eng.spin(acc + (n % 7), n - 1) }

	compile : Str -> Eng
	compile = |s| {
		base = Eng.spin(0, 200_000_000)
		Eng({ prog: [base, Str.count_utf8_bytes(s)] })
	}

	sum : Eng -> U64
	sum = |Eng(e)| List.fold(e.prog, 0, |a, b| a + b)
}
