#!/usr/bin/env python3
"""Fixture for the HTTP parse benchmark (H10 of plans/2026-09-06-http-parse.md).

Writes N realistic HTTP/1.1 requests, one after another, to the file named by
argv[1]. Both sides read the same file and split it on the `\r\n\r\n` that ends
each request's header block, so neither side gets a pre-parsed structure.

    python3 tools/http-bench/gen.py testdata/http_requests.txt [n]
"""
import random, sys

path = sys.argv[1]
n = int(sys.argv[2]) if len(sys.argv) > 2 else 1000
rng = random.Random(20260906)

# paths that exercise the route table in examples/http_bench.roc: statics,
# one-parameter routes, two-parameter routes, a suffix route and a catch-all
PATHS = [
    ("GET", "/"), ("GET", "/health"), ("GET", "/users"), ("POST", "/users"),
    ("GET", "/users/{}"), ("DELETE", "/users/{}"), ("GET", "/users/{}/posts"),
    ("GET", "/users/{}/posts/{}"), ("GET", "/user_profiles/{}"),
    ("GET", "/images/img{}.png"), ("GET", "/static/{}"),
]
SLUGS = ["hello-world", "on-regex", "a", "why-derivatives", "notes-2026"]
FILES = ["css/site.css", "js/app.js", "img/logo.svg", "fonts/x.woff2"]
HEADERS = [
    ("Host", "example.com"), ("User-Agent", "curl/8.4.0"), ("Accept", "*/*"),
    ("Accept-Encoding", "gzip, deflate"), ("Connection", "keep-alive"),
    ("Cache-Control", "no-cache"), ("X-Request-Id", "0123456789abcdef"),
    ("Referer", "https://example.com/"), ("Cookie", "sid=abc123; theme=dark"),
    ("Accept-Language", "en-US,en;q=0.9"), ("X-Forwarded-For", "203.0.113.7"),
    ("Origin", "https://example.com"), ("DNT", "1"), ("Pragma", "no-cache"),
]

out = []
for _ in range(n):
    method, tmpl = rng.choice(PATHS)
    if tmpl == "/static/{}":
        p = tmpl.format(rng.choice(FILES))
    elif tmpl.count("{}") == 2:
        p = tmpl.format(rng.randint(1, 99999), rng.choice(SLUGS))
    elif "{}" in tmpl:
        p = tmpl.format(rng.randint(1, 99999))
    else:
        p = tmpl
    hs = rng.sample(HEADERS, rng.randint(8, 14))
    # Content-Length is one of the three headers both sides look up, so it is
    # always present; the other two vary in position
    hs.append(("Content-Length", str(rng.randint(0, 4096))))
    rng.shuffle(hs)
    lines = "".join(f"{k}: {v}\r\n" for k, v in hs)
    out.append(f"{method} {p} HTTP/1.1\r\n{lines}\r\n")

open(path, "w", newline="").write("".join(out))
print(f"{n} requests, {sum(len(r) for r in out)} bytes -> {path}", file=sys.stderr)
