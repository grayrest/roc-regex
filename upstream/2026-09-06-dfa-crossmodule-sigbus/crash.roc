app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	sharp: "../../package/main.roc",
}
import pf.Stdout
import pf.Utc
import sharp.Sharp
import sharp.Dfa

hn : Sharp.T
hn = Sharp.unwrap(Sharp.compile("(?i)^content-length:[ \t]*"))

iters : U64
iters = 20000

blk : U64 -> List(U8)
blk = |z| Str.to_utf8(Str.concat("Host: example.com\r\nUser-Agent: curl/8.4.0\r\nAccept: */*\r\nAccept-Encoding: gzip\r\nConnection: keep-alive\r\nCache-Control: no-cache\r\nX-Request-Id: 0123456789abcdef\r\nReferer: https://example.com/\r\nContent-Length: 2456\r\n", if z > 99 { "z" } else { "" }))

l_find : List(U8), U64, U64 -> U64
l_find = |b, n, acc| if n == 0 { acc } else { l_find(b, n - 1, acc + (match Sharp.find(hn, b) { Ok(s) => s.end, Err(_) => 0 })) }

l_ff : List(U8), U64, U64 -> U64
l_ff = |b, n, acc| if n == 0 { acc } else { l_ff(b, n - 1, acc + List.len(Dfa.find_first_fast(hn.e, hn.trie, hn.accel, b))) }

l_sweep : List(U8), U64, U64 -> U64
l_sweep = |b, n, acc| if n == 0 { acc } else { l_sweep(b, n - 1, acc + List.len(Sharp.match_starts_fast(hn, b, True))) }

l_ends : List(U8), List(U64), U64, U64 -> U64
l_ends = |b, sts, n, acc| if n == 0 { acc } else { l_ends(b, sts, n - 1, acc + List.len(Dfa.ends_fast(hn.e, hn.trie, hn.accel.len, b, sts, True, True, True))) }

main! = |args| {
	b = blk(List.len(args))
	d = l_ff(b, iters, 0)
	Stdout.line!("ff ok ${(d / iters).to_str()}")
}
