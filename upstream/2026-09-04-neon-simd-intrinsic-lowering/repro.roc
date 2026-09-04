app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
}
import pf.Stdout
import pf.Path
import pf.OsStr

# Isolates U8x16.to_bitmask (the NEON movemask). Count 16-byte windows that
# contain a zero byte. Build --opt=speed --debug and disassemble _roc_main: the
# per-window body is one clean 'ldr q', one 'cmeq.16b' ... then ~46 scalar
# umov.b/mov.b/fmov/orr instructions for the single to_bitmask, where AArch64
# wants ~4 (shrn.8b v,v.8h,#4; fmov x,d; then test).
scan : List(U8), U64, U64, U64 -> U64
scan = |hay, w, len, n|
	if w + 16 > len {
		n
	} else {
		chunk = U8x16.load(hay, w) ?? U8x16.splat(0)
		bm = chunk.eq_lanes(U8x16.splat(0)).to_bitmask()
		scan(hay, w + 16, len, n + (if bm == 0 { 0 } else { 1 }))
	}

last_arg = |args| { n = List.len(args)
	if n == 0 { Err(Empty) } else { match List.get(args, n - 1) { Ok(a) => Ok(a) Err(_) => Err(Empty) } } }

main! = |args| {
	hay = match last_arg(args) { Ok(a) => Path.read_bytes!(Path.from_os_str(a))? Err(_) => [] }
	Stdout.line!((scan(hay, 0, List.len(hay), 0)).to_str())
}
