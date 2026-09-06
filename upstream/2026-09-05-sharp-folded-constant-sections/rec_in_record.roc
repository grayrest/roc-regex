app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
}
import pf.Stdout

mk : U64, List(U32) -> List(U32)
mk = |n, acc| if n == 0 { acc } else { mk(n - 1, List.append(acc, n.to_u32_wrap())) }

T : { xs : List(U32), n : U64 }
tbl : T
tbl = { xs: mk(50000, []), n: 50000 }

main! = |args| {
	i = List.len(args)
	Stdout.line!("v=${(List.get(tbl.xs, i) ?? 0).to_str()}")
}
