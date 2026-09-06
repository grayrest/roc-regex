app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	r: "./main.roc",
}
import pf.Stdout
import r.A
import r.B
main! = |args| {
	h = Str.to_utf8(Str.concat("ABC", if List.len(args) > 99 { "z" } else { "" }))
	Stdout.line!(Str.join_with([A.run(h).to_str(), B.run(h).to_str()], " "))
}
