app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
}
import pf.Stdout

helper : List(U64), U64 -> List(U64)
helper = |l, i| List.append(l, i)

# R1: inline appends only
r1 : U64 -> U64
r1 = |n| {
	var acc = []
	var i = 0
	while i < n {
		acc = List.append(acc, i)
		i = i + 1
	}
	List.len(acc)
}

# R2: alternate an inline append with an append inside a helper
r2 : U64 -> U64
r2 = |n| {
	var acc = []
	var i = 0
	while i < n {
		if i % 7 == 0 {
			acc = helper(acc, i)
		} else {
			acc = List.append(acc, i)
		}
		i = i + 1
	}
	List.len(acc)
}

# R3: helper only
r3 : U64 -> U64
r3 = |n| {
	var acc = []
	var i = 0
	while i < n {
		acc = helper(acc, i)
		i = i + 1
	}
	List.len(acc)
}

# R5: R2 with concat instead of the inline append
r5 : U64 -> U64
r5 = |n| {
	var acc = []
	var i = 0
	while i < n {
		if i % 7 == 0 {
			acc = helper(acc, i)
		} else {
			acc = List.concat(acc, [i])
		}
		i = i + 1
	}
	List.len(acc)
}

main! = |args| {
	n = 100_000 + List.len(args)
	Stdout.line!("R1 inline only:   ${r1(n).to_str()}")?
	Stdout.line!("R3 helper only:   ${r3(n).to_str()}")?
	Stdout.line!("R5 concat+helper: ${r5(n).to_str()}")?
	Stdout.line!("R2 mixed:         ${r2(n).to_str()}")
}
