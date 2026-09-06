#!/usr/bin/env python3
"""Differential for `package-http/Rtrie` against matchit 0.8.

`Rtrie` is a from-scratch port of matchit's radix trie, so every answer it
gives -- which route won and what the parameters bound to -- is checked
against the original. Emits a Roc runner carrying matchit's answers.

    cargo build --release --manifest-path tools/route-diff/rust/Cargo.toml
    python3 tools/route-diff/gen.py > /tmp/route-diff.roc
    roc build --output=/tmp/route-diff /tmp/route-diff.roc && /tmp/route-diff a b
"""
import os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.abspath(os.path.join(HERE, "..", "..", "package-http", "main.roc"))
PLATFORM = "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst"
BIN = os.path.join(HERE, "rust", "target", "release", "route-diff")

# A table that exercises every shape matchit distinguishes: shared prefixes
# that force radix splits, static/param siblings at the same node, a parameter
# with a static prefix and suffix in one segment, nested parameters, and a
# catch-all beside statics.
ROUTES = [
    "/",
    "/health",
    "/healthz",
    "/he",
    "/users",
    "/users/{id}",
    "/users/{id}/posts",
    "/users/{id}/posts/{slug}",
    "/users/{id}/posts/{slug}/edit",
    "/user_profiles/{id}",
    "/images/img{id}.png",
    "/images/{name}",
    "/files/{*rest}",
    "/a/b/c",
    "/a/{x}/c",
    "/a/b/{y}",
    "/{top}",
    "/x{y}z",
]

PATHS = [
    "/", "/health", "/healthz", "/he", "/hea", "/health/", "/healthzz",
    "/users", "/users/", "/users/42", "/users/42/", "/users/42/posts",
    "/users/42/posts/hi", "/users/42/posts/hi/edit", "/users/42/posts/hi/x",
    "/users/health", "/users/42/x", "/user_profiles/7", "/user_profiles/",
    "/userz", "/use", "/user", "/user_profiles/a/b",
    "/images/img9.png", "/images/img.png", "/images/imga.b.png",
    "/images/img9.jpg", "/images/x", "/images/", "/images/img9.png/x",
    "/files/a", "/files/a/b/c.css", "/files/", "/files",
    "/a/b/c", "/a/q/c", "/a/b/z", "/a/b", "/a/b/c/d", "/a/q/z",
    "/top", "/xz", "/xyz", "/xqqz", "/x", "/xy",
    "//", "/%2F", "/users/a%2Fb",
]


# plus randomly assembled paths over the table's own alphabet, so the corpus
# reaches shapes the hand-written list did not think of
import random
_rng = random.Random(20260906)
_SEGS = ["", "a", "b", "c", "he", "health", "healthz", "users", "42", "posts",
         "hi", "edit", "user_profiles", "images", "img9.png", "img.png", "x",
         "files", "top", "xz", "q", "z", "img", "png", "%2F"]
for _ in range(200):
    k = _rng.randint(0, 4)
    p = "/" + "/".join(_rng.choice(_SEGS) for _ in range(k))
    if p not in PATHS:
        PATHS.append(p)


def roc_str(s):
    out = []
    for ch in s:
        if ch == "\\": out.append("\\\\")
        elif ch == '"': out.append('\\"')
        elif ch == "$": out.append("\\$")
        else: out.append(ch)
    return "".join(out)


with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
    f.write("\n".join(ROUTES) + "\n")
    rp = f.name
with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
    f.write("\n".join(PATHS) + "\n")
    pp = f.name
out = subprocess.run([BIN, rp, pp], capture_output=True, text=True, check=True).stdout
os.unlink(rp); os.unlink(pp)
if out.startswith("INSERT_ERR"):
    sys.exit("matchit rejected a route: " + out)

want = {}
for line in out.splitlines():
    path, idx, params = line.split("\t")
    want[path] = idx if idx == "-" else (idx + " " + params if params else idx)

print("app [main!] {")
print(f'\tpf: platform "{PLATFORM}",')
print(f'\thttp: "{PKG}",')
print("}")
print("import pf.Stdout")
print("import http.Router\n")
print("routes : List({ method : Str, path : Str })")
print("routes = [")
for r in ROUTES:
    print(f'\t{{ method: "GET", path: "{roc_str(r)}" }},')
print("]\n")
print("cases : List((Str, Str))")
print("cases = [")
for p in PATHS:
    print(f'\t("{roc_str(p)}", "{roc_str(want[p])}"),')
print("]\n")
print(r'''router : Router.T
router = match Router.build(routes) { Ok(r) => r, Err(_) => crash "route table is invalid" }

# matchit's own rendering: the route's index, then its parameters sorted by
# name, so the two sides are compared on the same string
got : Str -> Str
got = |path|
	match Router.at(router, "GET", Str.to_utf8(path)) {
		Err(_) => "-"
		Ok(m) => {
			ps = List.sort_with(List.map(m.params, |p| Str.join_with([p.name, Str.from_utf8_lossy(p.value)], "=")), |x, y| cmp(Str.to_utf8(x), Str.to_utf8(y)))
			idx = (List.find_first_index(routes, |r| r.path == m.path) ?? 0).to_str()
			if List.is_empty(ps) { idx } else { Str.join_with([idx, Str.join_with(ps, ",")], " ") }
		}
	}

cmp : List(U8), List(U8) -> [Before, Same, After]
cmp = |x, y| cmp_at(x, y, 0)

cmp_at : List(U8), List(U8), U64 -> [Before, Same, After]
cmp_at = |x, y, i|
	if i >= List.len(x) or i >= List.len(y) {
		if List.len(x) < List.len(y) { Before } else if List.len(x) > List.len(y) { After } else { Same }
	} else {
		a = List.get(x, i) ?? 0
		b = List.get(y, i) ?? 0
		if a < b { Before } else if a > b { After } else { cmp_at(x, y, i + 1) }
	}

main! = |args| {
	filler = if List.len(args) > 99 { "z" } else { "" }
	bad = List.keep_if(cases, |(p, w)| got(Str.concat(p, filler)) != w)
	lines = List.map(bad, |(p, w)| "DIFFER \"${p}\"  matchit=[${w}]  rtrie=[${got(p)}]")
	Stdout.line!(Str.join_with(lines, "\n"))?
	Stdout.line!("\n${(List.len(cases) - List.len(bad)).to_str()}/${List.len(cases).to_str()} agree with matchit")
}
''')
