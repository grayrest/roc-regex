## The Roc side of the HTTP parse benchmark, against `tools/http-bench/rust`
## (httparse + matchit).
##
## The task, identical on both sides: for each request, frame it, select the
## route and bind its parameters, and read three named headers. The checksum
## sums every piece's length plus the matched route's index, so a divergence in
## any piece changes it and the comparison is invalid.
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	http: "../package-http/main.roc",
}
import pf.Stdout
import pf.Path
import pf.OsStr
import pf.Utc
import http.Http
import http.Route
import http.Router

# KEEP IN SYNC with tools/http-bench/rust/src/main.rs: the same routes in the
# same order, since the checksum carries the matched route's index. matchit has
# one method-agnostic router, so each route is registered under every method
# the fixture uses.
route_paths : List(Str)
route_paths = [
	"/",
	"/health",
	"/users",
	"/users/{id}",
	"/users/{id}/posts",
	"/users/{id}/posts/{slug}",
	"/user_profiles/{id}",
	"/images/img{id}.png",
	"/static/{*rest}",
]

methods : List(Str)
methods = ["GET", "POST", "DELETE"]

router : Router.T
router = Router.build(List.join(List.map(methods, |m| List.map(route_paths, |p| { method: m, path: p })))) ?? crash "route table is invalid"

# Headers are parsed by `frame` now, so a lookup is a case-insensitive byte
# compare against the index rather than its own search.
# as byte constants, folded into the artifact, the way a server would hold the
# header names it reads on every request
lookups : List(List(U8))
lookups = [Str.to_utf8("content-length"), Str.to_utf8("host"), Str.to_utf8("x-request-id")]

# Split the fixture at each `\r\n\r\n`, so neither side is handed a
# pre-parsed structure.
split_reqs : List(U8) -> List({ start : U64, end : U64 })
split_reqs = |buf| split_loop(buf, 0, 0, [])

split_loop : List(U8), U64, U64, List({ start : U64, end : U64 }) -> List({ start : U64, end : U64 })
split_loop = |buf, i, start, acc|
	if i + 3 >= List.len(buf) {
		acc
	} else if (List.get(buf, i) ?? 0) == '\r' and (List.get(buf, i + 1) ?? 0) == '\n' and (List.get(buf, i + 2) ?? 0) == '\r' and (List.get(buf, i + 3) ?? 0) == '\n' {
		split_loop(buf, i + 4, i + 4, List.append(acc, { start, end: i + 4 }))
	} else {
		split_loop(buf, i + 1, start, acc)
	}

route_index : Str -> U64
route_index = |p| match List.find_first_index(route_paths, |x| x == p) { Ok(i) => i, Err(_) => 0 }

# Stage timing, since H10 keeps no engine-to-engine row: a gap has to be
# diagnosed from inside. 0 = split only, 1 = + frame, 2 = + route, 3 = + the
# three header lookups (the full task, and the only stage whose checksum is
# comparable with the Rust side).
one : U64, List(U8), { start : U64, end : U64 } -> U64
one = |stage, buf, r| {
	raw = List.sublist(buf, { start: r.start, len: r.end - r.start })
	if stage == 0 {
		List.len(raw)
	} else
	match Http.frame(raw) {
		Err(_) => 0
		Ok(req) => {
			method = Http.slice(raw, req.method)
			target = Http.slice(raw, req.target)
			# httparse reports the minor version number, not the text
			minor = if (List.get(raw, req.version.end - 1) ?? 0) == '0' { 0 } else { 1 }
			base = List.len(method) + List.len(target) + minor
			routed =
				if stage < 2 { 0 } else
				match Router.at(router, Str.from_utf8_lossy(method), target) {
					Err(_) => 0
					Ok(m) => List.fold(m.params, route_index(m.path), |acc, p| acc + List.len(p.value))
				}
			hdrs =
				if stage < 3 { 0 } else
				List.fold(lookups, 0, |acc, nm|
					match Http.header_bytes(raw, req, nm) {
						Ok(p) => acc + (p.end - p.start)
						Err(_) => acc
					})
			base + routed + hdrs
		}
	}
}

run : U64, List(U8), List({ start : U64, end : U64 }) -> U64
run = |stage, buf, reqs| List.fold(reqs, 0, |acc, r| acc + one(stage, buf, r))

time_loop : U64, List(U8), List({ start : U64, end : U64 }), U64, U64 -> U64
time_loop = |stage, buf, reqs, n, acc|
	if n == 0 { acc } else { time_loop(stage, buf, reqs, n - 1, run(stage, buf, reqs)) }

stage_name : U64 -> Str
stage_name = |s| match s { 0 => "split", 1 => "frame", 2 => "route", _ => "headers" }

run_stage! : U64, List(U8), List({ start : U64, end : U64 }) => Try({}, _)
run_stage! = |stage, buf, reqs| {
	t0 = Utc.now!()
	cs = time_loop(stage, buf, reqs, iters, 0)
	t1 = Utc.now!()
	per = (if t1 > t0 { t1 - t0 } else { 0 }) / iters.to_u128()
	Stdout.line!("roc_${stage_name(stage)},${per.to_str()},${List.len(reqs).to_str()},${cs.to_str()}")
}

iters : U64
iters = 20

last_arg : List(OsStr.OsStr) -> Try(OsStr.OsStr, [Empty])
last_arg = |args|
	if List.len(args) == 0 { Err(Empty) } else { match List.get(args, List.len(args) - 1) { Ok(a) => Ok(a), Err(_) => Err(Empty) } }

main! = |args| {
	buf =
		match last_arg(args) {
			Ok(a) => Path.read_bytes!(Path.from_os_str(a))?
			Err(_) => []
		}
	reqs = split_reqs(buf)
	run_stage!(0, buf, reqs)?
	run_stage!(1, buf, reqs)?
	run_stage!(2, buf, reqs)?
	run_stage!(3, buf, reqs)
}
