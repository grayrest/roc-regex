app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
}
import pf.Stdout

build : List(TY), U64 -> List(TY)
build = |acc, n|
	if n == 0 { acc } else { build(List.append(acc, (n % 251).to_TYL()), n - 1) }

table : List(TY)
table = build([], NNN)

main! = |args| {
	i = List.len(args)
	match List.get(table, i) {
		Ok(v) => Stdout.line!(v.to_str())
		Err(_) => Stdout.line!("oob")
	}
}
