app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	r: "./main.roc",
}
import pf.Stdout
import r.A
main! = |args| Stdout.line!(A.run(Str.to_utf8(Str.concat("ABC", if List.len(args) > 99 { "z" } else { "" }))).to_str())
