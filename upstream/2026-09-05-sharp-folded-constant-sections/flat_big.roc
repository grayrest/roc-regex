app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
}
import pf.Stdout
import pf.Path
import pf.OsStr

mk : U64, List(U32) -> List(U32)
mk = |n, acc| if n == 0 { acc } else { mk(n - 1, List.append(acc, n.to_u32_wrap())) }

tbl : List(U32)
tbl = mk(50000, [])

main! = |args| {
	i = List.len(args)
	Stdout.line!("v=${(List.get(tbl, i) ?? 0).to_str()} n=${List.len(tbl).to_str()}")
}
