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

## Results (256 KiB haystack)

```
pattern            roc_ns     rust_ns  roc_MBps  rust_MBps  slowdown  cnt
literal         105205400       28372      2.49     9239.6     ~3700x   ok
teddy_alt       478038100      410671      0.55      638.3     ~1200x   ok
class_plus      164809300     2011179      1.59      130.3       ~82x   ok
bounded_num     104517500      106920      2.51     2451.8      ~980x   ok
word_bound      419027950      199895      0.63     1311.4     ~2100x   ok
two_words       202952400     1874982      1.29      139.8      ~110x   ok
caps_email      241123150       72118      1.09     3635.0     ~3300x   ok
uni_letters     167274850     2245861      1.57      116.7       ~74x   ok
dotstar_lit     221695200      647088      1.18      405.1      ~340x   ok
```

`_ns` = nanoseconds per `find_all` over the whole haystack. literal /
word_bound / caps_email slowdowns swing a bit run to run (the Rust side is only
tens of µs); the Roc side is stable.

### Reading it

- **Roc runs at ~0.5–2.5 MB/s, essentially flat across patterns.** Per-byte
  interpreter + persistent-`List(U8)` overhead dominates, so the pattern barely
  matters. There is no Teddy/memchr fast path in `find_all` (Teddy is only
  wired into single `find`), so `teddy_alt` is actually the *slowest* Roc row —
  it's just the general engine over 8 alternatives.
- **Rust spans 117 MB/s to 9 GB/s** because it dispatches specialised paths
  (memchr for the literal, SIMD Teddy for the alternation, a lazy DFA for the
  big scans).
- **Slowdown is ~75–110× on the heavy many-match scans** (`class_plus`,
  `uni_letters`, `two_words` — where Rust also has real work to do) and
  **~1000–3700× on the patterns Rust answers almost for free**. So the gap is
  really "Rust has fast paths we don't", not a uniform constant.

### Compile latency

Rust `Regex::new` costs ~30–700 µs per pattern *at runtime*. Roc pays that at
build time via constant folding and 0 at runtime — the one axis where this
design is unambiguously ahead. For a compile-once/match-a-lot workload it's
noise; for compile-per-call it is the whole game.

## `find_all` stack overflow — found and fixed

The first version of this benchmark crashed with **SIGBUS (exit 138)** on
haystacks larger than ~16 KiB. Root cause: `Regex.all_caps`'s match loop was a
tail-recursive helper (`all_loop`) that iterated once per match. It is written
in tail position, and the `--opt=dev` backend loops it correctly, but the
`--opt=speed` (LLVM) backend does *not* eliminate the tail call once the loop
body is large (it inlines the whole PikeVM matcher). Stack then grew one ~2 KB
frame per match and overflowed after a few thousand — so the crash tracked
match count *for complex patterns only* (a literal at 300k matches was fine; a
class or alternation died at a few thousand).

Fixed by rewriting `all_caps` as an explicit `while` loop with `var` state, so
stack use is O(1) regardless of match count and it no longer depends on
tail-call optimisation. Verified: 256 KiB and 1 MiB haystacks (40k–160k
matches) run clean; differential 860/860 vs Rust; smoke 21/21. The compiler
tail-call miss is written up for upstream in
`upstream/2026-09-02-llvm-tco-match-loop/`.

## Caveats

- `find_all` re-runs `Pike.captures_from` from each match end; part of the flat
  Roc cost is that per-match restart, not just raw scan speed.
- Single-`find` (with the Teddy/prefilter rungs) is not measured here; it would
  show the SIMD path and a smaller gap on literal-alternation patterns.
- Absolute MB/s shifts a little with haystack size; the ratios are what matter
  and those are size-stable.
