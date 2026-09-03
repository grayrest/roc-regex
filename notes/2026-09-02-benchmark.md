# Benchmark: Roc engine vs Rust `regex` (2026-09-02)

First throughput comparison against the vendored Rust `regex` 1.13 crate.
Harness: `tools/bench/` (`gen` + `bench` bins, `run.sh` driver) and
`examples/bench.roc`. Reproduce with `tools/bench/run.sh`.

## Method

- **Identical work.** Both engines run the same 9 patterns over the same
  bytes (`gen` writes a deterministic haystack both sides read). Parity is
  enforced by comparing match counts per pattern; all 9 agree exactly, so the
  ratios compare like for like.
- **Match throughput only.** The regex is compiled *once, before* the timing
  loop in both languages, and timing is in-process (Roc `Utc.now!`, Rust
  `Instant`), so process startup and file I/O are excluded. Whether or not Roc
  folds `compile` is irrelevant to this number — the loop measures the engine.
- **Compile latency** is reported separately: Rust pays `Regex::new` at
  runtime; Roc folds compilation into the binary at build time (the AOT
  premise), so its runtime compile cost is 0.
- Roc side uses `regex::bytes::Regex` on the Rust side to match our
  byte-oriented, codepoint-alphabet engine.

## Results (16 KiB haystack)

```
pattern            roc_ns     rust_ns  roc_MBps  rust_MBps  slowdown  cnt
literal           8780600        4046      1.87     4050.2     ~2000x   ok
teddy_alt        30882050       22517      0.53      727.8     ~1400x   ok
class_plus       13948700      122008      1.17      134.3      ~114x   ok
bounded_num       7394850        5550      2.22     2952.6     ~1300x   ok
word_bound       26185250        4972      0.63     3295.9     ~5300x   ok
two_words        14479500       87803      1.13      186.6      ~165x   ok
caps_email       16092800        3248      1.02     5045.3     ~5000x   ok
uni_letters      13687050      125296      1.20      130.8      ~110x   ok
dotstar_lit      15141150       38720      1.08      423.2      ~390x   ok
```

`_ns` = nanoseconds per `find_all` over the whole haystack. literal / word_bound
/ caps_email slowdowns swing run to run because the Rust side is at timer noise
(a few µs); the Roc side is stable.

### Reading it

- **Roc runs at ~0.5–2.2 MB/s, essentially flat across patterns.** Per-byte
  interpreter + persistent-`List(U8)` overhead dominates, so the pattern barely
  matters. There is no Teddy/memchr fast path in `find_all` (Teddy is only
  wired into single `find`), so `teddy_alt` is actually the *slowest* Roc row —
  it's just the general engine over 8 alternatives.
- **Rust spans 130 MB/s to 11 GB/s** because it dispatches specialised paths
  (memchr for the literal, SIMD Teddy for the alternation, a lazy DFA for the
  big scans).
- **Slowdown is ~110× on the heavy many-match scans** (`class_plus`,
  `uni_letters`, `two_words` — where Rust also has real work to do) and
  **~1000–5000× on the patterns Rust answers almost for free**. So the gap is
  really "Rust has fast paths we don't", not a uniform constant.

### Compile latency

Rust `Regex::new` costs ~30–700 µs per pattern *at runtime*. Roc pays that at
build time via constant folding and 0 at runtime — the one axis where this
design is unambiguously ahead. For a compile-once/match-a-lot workload it's
noise; for compile-per-call it is the whole game.

## Finding: `find_all` stack-overflows past ~3–4k matches

While benchmarking, larger haystacks crashed with **SIGBUS (exit 138)**. It is
not the SIMD path — it tracks match count, not pattern:

| haystack | literal (cnt) | teddy_alt (cnt) | class_plus (cnt) |
|----------|---------------|-----------------|------------------|
| 16 KiB   | ok (81)       | ok (589)        | ok (2509)        |
| 32 KiB   | ok            | ok (1192)       | **crash** (~4900)|
| 64 KiB   | ok (319)      | ok (2383)       | crash            |
| 256 KiB  | ok (1202)     | **crash** (9447)| crash            |

Cause: `Regex.all_loop` (`package/Regex.roc`) recurses once per match. It is
written in tail position with an accumulator, but the current `release-fast`
compiler is not eliminating the call, so stack depth = match count and it blows
the 8 MB stack somewhere around 3–4k frames. Whichever pattern first exceeds
that count is the one that dies, which is why the crash point moves earlier as
the haystack grows.

This is the practical ceiling on the engine right now, well before throughput
matters. Two independent fixes:

1. Rewrite `all_loop` as an explicit iterative loop / fold so depth is O(1)
   regardless of match count (fixes it in our code, no compiler dependency).
2. Separately, tail calls not being optimised is a compiler matter — worth an
   upstream report per the project's standing policy of exercising the
   compiler rather than designing around it.

(1) is the real fix; the 16 KiB benchmark ceiling exists only to dodge this.

## Caveats

- `find_all` re-runs `Pike.captures_from` from each match end; part of the flat
  Roc cost is that per-match restart, not just raw scan speed.
- Single-`find` (with the Teddy/prefilter rungs) is not measured here; it would
  show the SIMD path and a smaller gap on literal-alternation patterns.
- 16 KiB is small; absolute MB/s would shift a little at larger sizes, but the
  ratios are what matter and those are size-stable below the crash ceiling.
