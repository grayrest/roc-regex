app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst" }
import pf.Stdout
import pf.Path
import pf.OsStr
# mimic the Teddy inner op: carry prev window, byte-align, then movemask
scan : List(U8), U64, U64, U8x16, U64 -> U64
scan = |hay, w, len, prev, n|
	if w + 16 > len { n }
	else {
		chunk = U8x16.load(hay, w) ?? U8x16.splat(0)
		aligned = prev.concat_shift_bytes(chunk, 15)
		bm = aligned.eq_lanes(U8x16.splat(0)).bitwise_not().to_bitmask()
		scan(hay, w + 16, len, chunk, n + (if bm == 0 { 0 } else { 1 }))
	}
last_arg = |args| { n = List.len(args)
	if n == 0 { Err(Empty) } else { match List.get(args, n - 1) { Ok(a) => Ok(a) Err(_) => Err(Empty) } } }
main! = |args| {
	hay = match last_arg(args) { Ok(a) => Path.read_bytes!(Path.from_os_str(a))? Err(_) => [] }
	Stdout.line!((scan(hay, 0, List.len(hay), U8x16.splat(0xFF), 0)).to_str())
}
