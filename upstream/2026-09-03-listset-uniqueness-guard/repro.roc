app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
}
import pf.Stdout

# One-line helper over a buffer, as used in a hot PikeVM closure: set in place
# when the index is live, grow only at the frontier. `stack` is passed by the
# caller and returned — provably a single owner — so the runtime uniqueness
# check and clone path inside List.set are dead. Both are still emitted; see
# the disassembly of this function in the report.
spush : List(U32), U64, U32 -> List(U32)
spush = |stack, i, v|
	if i < List.len(stack) { List.set(stack, i, v) ?? stack } else { List.append(stack, v) }

main! = |args| {
	# runtime count so the loop is not constant-folded at build time
	total = 20_000_000 + List.len(args).to_u64()
	var buf = List.repeat(0, 2000)
	var i = 0
	var k = 0
	while k < total {
		buf = spush(buf, i, 7)
		i = if i >= 1999 { 0 } else { i + 1 }
		k = k + 1
	}
	Stdout.line!("r=${(List.get(buf, 0) ?? 0).to_str()}")
}
