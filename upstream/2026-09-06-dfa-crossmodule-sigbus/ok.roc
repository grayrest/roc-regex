app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	sharp: "../../package-sharp/main.roc",
}
import pf.Stdout
import sharp.Sharp

hn : Sharp.T
hn = Sharp.unwrap(Sharp.compile("(?i)^content-length:[ \t]*"))

blk : U64 -> List(U8)
blk = |z| Str.to_utf8(Str.concat("Host: example.com\r\nContent-Length: 2456\r\n", if z > 99 { "z" } else { "" }))

# the SAME search, reached through Sharp instead of Dfa: runs fine
main! = |args| {
	b = blk(List.len(args))
	Stdout.line!(match Sharp.find(hn, b) { Ok(s) => s.end.to_str(), Err(_) => "-" })
}
