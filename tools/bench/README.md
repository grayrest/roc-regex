# bench

Throughput comparison of the Roc engine against the vendored Rust `regex` 1.13
crate. See `notes/2026-09-02-benchmark.md` for results and method.

```
tools/bench/run.sh [haystack_bytes]     # default 262144
```

- `src/gen.rs` — writes a deterministic haystack both engines read.
- `src/bench.rs` — Rust side: times `Regex::new` (compile) separately from a
  `find_iter` loop (match), prints `id,compile_ns,match_ns_per_iter,count,checksum`.
- `examples/bench.roc` — Roc side, same patterns and output shape.

The pattern list is duplicated between `src/bench.rs` and `examples/bench.roc`
(the regexes must be string literals in the Roc source so `compile` folds at
build time). **Keep the two lists in sync** — same ids, same regexes.
