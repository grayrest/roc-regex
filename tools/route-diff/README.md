# Router differential against matchit

`package-http/Rtrie` is a from-scratch port of matchit 0.8's radix trie, so
every answer it gives — which route won, and what each parameter bound to — is
checked against the original.

```bash
cargo build --release --manifest-path tools/route-diff/rust/Cargo.toml
python3 tools/route-diff/gen.py > /tmp/route-diff.roc
roc build --output=/tmp/route-diff /tmp/route-diff.roc && /tmp/route-diff a b
```

The table exercises every shape matchit distinguishes: shared prefixes that
force radix splits (`/he`, `/health`, `/healthz`), static and parameter
siblings at one node, a parameter with a static prefix and suffix in one
segment (`/images/img{id}.png`), nested parameters, and a catch-all beside
statics. Paths are a hand-written list of edge cases plus 200 assembled at
random from the table's own segments.

The `a b` arguments exist so the runner cannot be constant-folded whole.
