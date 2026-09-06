## The `package-http` consumer test (H9.3): a stepwise HTTP/1.1 request parser
## and matchit-syntax router built only from the public API.
##
## Also the subject `tools/sharp-size/breakdown.sh` measures for H6, so the
## route table is declared at the top level where it folds into the artifact.
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	http: "../package-http/main.roc",
}
import pf.Stdout
import http.Http
import http.Route
import http.Router

routes : List({ method : Str, path : Str })
routes = [
	{ method: "GET", path: "/" },
	{ method: "GET", path: "/health" },
	{ method: "GET", path: "/users" },
	{ method: "POST", path: "/users" },
	{ method: "GET", path: "/users/{id}" },
	{ method: "DELETE", path: "/users/{id}" },
	{ method: "GET", path: "/users/{id}/posts" },
	{ method: "GET", path: "/users/{id}/posts/{slug}" },
	{ method: "GET", path: "/user_profiles/{id}" },
	{ method: "GET", path: "/images/img{id}.png" },
	{ method: "GET", path: "/static/{*rest}" },
]

router : Router.T
router =
	match Router.build(routes) {
		Ok(r) => r
		Err(_) => crash "route table is invalid"
	}

# --- expectations -------------------------------------------------------------

Case : { name : Str, got : Str, want : Str }

req : Str -> Str
req = |text| {
	buf = Str.to_utf8(text)
	match Http.frame(buf) {
		Err(Incomplete) => "incomplete"
		Err(BadRequestLine) => "bad-request-line"
		Err(ObsFold) => "obs-fold"
		Err(BadHeader) => "bad-header"
		Ok(r) =>
			Str.join_with(
				[
					Http.slice_str(buf, r.method),
					Http.slice_str(buf, r.target),
					Http.slice_str(buf, r.version),
					r.body.to_str(),
				],
				"|",
			)
	}
}

hdr : Str, Str -> Str
hdr = |text, name| {
	buf = Str.to_utf8(text)
	match Http.frame(buf) {
		Err(_) => "incomplete"
		Ok(r) =>
			match Http.header(buf, r, name) {
				Err(_) => "-"
				Ok(p) => Http.slice_str(buf, p)
			}
	}
}

route : Str, Str -> Str
route = |method, path|
	match Router.at(router, method, Str.to_utf8(path)) {
		Err(NotFound) => "404"
		Err(MethodNotAllowed(allow)) => Str.join_with(["405", Str.join_with(allow, ",")], " ")
		Ok(m) =>
			Str.join_with(
				List.prepend(
					List.map(m.params, |p| Str.join_with([p.name, Str.from_utf8_lossy(p.value)], "=")),
					m.path,
				),
				" ",
			)
	}

get_req : Str
get_req = "GET /users/42/posts/hello-world?x=1 HTTP/1.1\r\nHost: example.com\r\nContent-Length: 17\r\nX-Empty:\r\nAccept:   text/html   \r\nReferer: https://x/y\r\n\r\nbody"

dup_req : Str
dup_req = "GET / HTTP/1.1\r\nX-Dup: one\r\nX-Dup: two\r\n\r\n"

nfields : Str -> Str
nfields = |text| {
	buf = Str.to_utf8(text)
	match Http.frame(buf) {
		Err(_) => "incomplete"
		Ok(r) => List.len(r.fields).to_str()
	}
}

cases : List(Case)
cases = [
	# --- framing ---
	{ name: "simple GET", got: req("GET / HTTP/1.1\r\nHost: a\r\n\r\n"), want: "GET|/|HTTP/1.1|27" },
	{ name: "POST with body", got: req("POST /users HTTP/1.0\r\nHost: a\r\n\r\nxy"), want: "POST|/users|HTTP/1.0|33" },
	{ name: "no terminator", got: req("GET / HTTP/1.1\r\nHost: a\r\n"), want: "incomplete" },
	{ name: "empty buffer", got: req(""), want: "incomplete" },
	{ name: "headers only, no body", got: req("GET /x HTTP/1.1\r\n\r\n"), want: "GET|/x|HTTP/1.1|19" },
	{ name: "lowercase method rejected", got: req("get / HTTP/1.1\r\n\r\n"), want: "bad-request-line" },
	{ name: "bad version", got: req("GET / HTTP/x.y\r\n\r\n"), want: "bad-request-line" },
	{ name: "missing version", got: req("GET /\r\n\r\n"), want: "bad-request-line" },
	{ name: "obs-fold rejected", got: req("GET / HTTP/1.1\r\n Host: a\r\n\r\n"), want: "obs-fold" },
	{ name: "long method", got: req("PROPPATCH / HTTP/1.1\r\n\r\n"), want: "PROPPATCH|/|HTTP/1.1|24" },
	{ name: "target with query", got: req("GET /a?b=c&d=e HTTP/1.1\r\n\r\n"), want: "GET|/a?b=c&d=e|HTTP/1.1|27" },
	# --- headers on demand ---
	{ name: "header exact case", got: hdr(get_req, "Host"), want: "example.com" },
	{ name: "header lowercase", got: hdr(get_req, "content-length"), want: "17" },
	{ name: "header uppercase", got: hdr(get_req, "CONTENT-LENGTH"), want: "17" },
	{ name: "header mixed case", got: hdr(get_req, "cOnTeNt-LeNgTh"), want: "17" },
	{ name: "header absent", got: hdr(get_req, "Authorization"), want: "-" },
	{ name: "header empty value", got: hdr(get_req, "X-Empty"), want: "" },
	{ name: "header OWS trimmed", got: hdr(get_req, "Accept"), want: "text/html" },
	{ name: "header name is matched literally", got: hdr(get_req, "Host.*"), want: "-" },
	{ name: "all headers are indexed", got: nfields(get_req), want: "5" },
	{ name: "duplicate header takes the first", got: hdr(dup_req, "X-Dup"), want: "one" },
	{ name: "header with no colon", got: req("GET / HTTP/1.1\r\nbroken\r\n\r\n"), want: "bad-header" },
	{ name: "value containing a colon", got: hdr(get_req, "Referer"), want: "https://x/y" },
	# --- routing ---
	{ name: "root", got: route("GET", "/"), want: "/" },
	{ name: "static beats param", got: route("GET", "/users"), want: "/users" },
	{ name: "one param", got: route("GET", "/users/42"), want: "/users/{id} id=42" },
	{ name: "two params", got: route("GET", "/users/42/posts/hi"), want: "/users/{id}/posts/{slug} id=42 slug=hi" },
	{ name: "static after param", got: route("GET", "/users/42/posts"), want: "/users/{id}/posts id=42" },
	{ name: "underscore is literal", got: route("GET", "/user_profiles/7"), want: "/user_profiles/{id} id=7" },
	{ name: "underscore route is not a wildcard", got: route("GET", "/userXprofiles/7"), want: "404" },
	{ name: "prefix and suffix in segment", got: route("GET", "/images/img9.png"), want: "/images/img{id}.png id=9" },
	{ name: "suffix is subtracted, not swallowed", got: route("GET", "/images/imga.b.png"), want: "/images/img{id}.png id=a.b" },
	{ name: "param before suffix is non-empty", got: route("GET", "/images/img.png"), want: "404" },
	{ name: "suffix must match", got: route("GET", "/images/img9.jpg"), want: "404" },
	{ name: "catch-all", got: route("GET", "/static/css/site.css"), want: "/static/{*rest} rest=css/site.css" },
	{ name: "catch-all needs one byte", got: route("GET", "/static/"), want: "404" },
	{ name: "param does not cross a slash", got: route("GET", "/users/4/2"), want: "404" },
	{ name: "param must be non-empty", got: route("GET", "/users/"), want: "404" },
	{ name: "unknown path", got: route("GET", "/nope"), want: "404" },
	{ name: "method not allowed", got: route("PUT", "/users/42"), want: "405 GET,DELETE" },
	{ name: "other method on same path", got: route("DELETE", "/users/42"), want: "/users/{id} id=42" },
	{ name: "post to collection", got: route("POST", "/users"), want: "/users" },
	{ name: "percent-encoding is left alone", got: route("GET", "/users/a%2Fb"), want: "/users/{id} id=a%2Fb" },
]

# --- a request split at every byte boundary -----------------------------------

# `frame` must answer `Incomplete` for every prefix that stops before the
# terminator, and the same framing for every prefix at or past it. This is the
# only thing that exercises the partial-buffer rule, and the differential
# corpus cannot: every haystack there is under 30 bytes.
split_src : Str
split_src = "GET /users/7/posts/x HTTP/1.1\r\nHost: h\r\nAccept: */*\r\nContent-Length: 3\r\n\r\nabc"

upto : U64 -> List(U64)
upto = |n| upto_loop(n, 0, [])

upto_loop : U64, U64, List(U64) -> List(U64)
upto_loop = |n, i, acc| if i >= n { acc } else { upto_loop(n, i + 1, List.append(acc, i)) }

split_check : Str
split_check = {
	full = Str.to_utf8(split_src)
	n = List.len(full)
	term = match Http.frame(full) { Ok(r) => r.body, Err(_) => 0 }
	whole = req(split_src)
	bad = List.keep_if(upto(n + 1), |k| {
		got = req(Str.from_utf8_lossy(List.take_first(full, k)))
		want = if k < term { "incomplete" } else { whole }
		got != want
	})
	if List.is_empty(bad) { "ok" } else { Str.join_with(["bad at ", Str.join_with(List.map(List.take_first(bad, 6), |k| k.to_str()), ",")], "") }
}

# --- route table validation ---------------------------------------------------

route_err : List({ method : Str, path : Str }) -> Str
route_err = |rs|
	match Router.build(rs) {
		Ok(_) => "ok"
		Err(BadRoute(p, InvalidParam)) => Str.join_with(["invalid-param ", p], "")
		Err(BadRoute(p, InvalidParamSegment)) => Str.join_with(["invalid-param-segment ", p], "")
		Err(BadRoute(p, InvalidCatchAll)) => Str.join_with(["invalid-catch-all ", p], "")
		Err(Conflict(a, b)) => Str.join_with(["conflict ", a, " ", b], "")
	}

table_cases : List(Case)
table_cases = [
	{ name: "unclosed brace", got: route_err([{ method: "GET", path: "/a/{id" }]), want: "invalid-param /a/{id" },
	{ name: "empty name", got: route_err([{ method: "GET", path: "/a/{}" }]), want: "invalid-param /a/{}" },
	{ name: "stray close", got: route_err([{ method: "GET", path: "/a}b" }]), want: "invalid-param /a}b" },
	{ name: "two params in a segment", got: route_err([{ method: "GET", path: "/{a}-{b}" }]), want: "invalid-param-segment /{a}-{b}" },
	{ name: "catch-all not last", got: route_err([{ method: "GET", path: "/{*rest}/x" }]), want: "invalid-catch-all /{*rest}/x" },
	{ name: "same shape conflicts", got: route_err([{ method: "GET", path: "/u/{id}" }, { method: "GET", path: "/u/{name}" }]), want: "conflict /u/{id} /u/{name}" },
	{ name: "different methods do not conflict", got: route_err([{ method: "GET", path: "/u/{id}" }, { method: "PUT", path: "/u/{name}" }]), want: "ok" },
	{ name: "escaped braces are literal", got: route_err([{ method: "GET", path: "/{{a}}" }]), want: "ok" },
	{ name: "escaped-brace route matches", got: route(  "GET", "/{a}"), want: "404" },
	# the trie decides precedence structurally, so these check the descent
	# rather than a sort order
	{ name: "static wins over param at a shared prefix", got: route("GET", "/users"), want: "/users" },
	{ name: "param wins when no static matches", got: route("GET", "/userz"), want: "404" },
	{ name: "catch-all loses to a static sibling", got: route("GET", "/static/css/site.css"), want: "/static/{*rest} rest=css/site.css" },
	{ name: "backtrack out of a static into a param", got: route("GET", "/users/health"), want: "/users/{id} id=health" },
	{ name: "backtrack out of a longer static", got: route("GET", "/user_profiles/x"), want: "/user_profiles/{id} id=x" },
	{ name: "shared prefix does not leak", got: route("GET", "/use"), want: "404" },
	{ name: "trailing slash is not the route", got: route("GET", "/health/"), want: "404" },
]

main! = |_| {
	all = List.concat(List.concat(cases, table_cases), [{ name: "split at every byte", got: split_check, want: "ok" }])
	lines = List.map(all, |c| {
		mark = if c.got == c.want { "ok  " } else { "FAIL" }
		Str.join_with([mark, c.name, ": got ", c.got, " want ", c.want], " ")
	})
	fails = List.count_if(all, |c| c.got != c.want)
	Stdout.line!(Str.join_with(lines, "\n"))?
	Stdout.line!(Str.join_with(["\n", (List.len(all) - fails).to_str(), "/", List.len(all).to_str(), " passed"], ""))
}
