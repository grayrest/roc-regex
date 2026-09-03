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

Current engine, after the 2026-09-03 allocation work (see below). ns per
`find_all` over the whole haystack; Roc is the min of three runs (the box was
lightly loaded, which only inflates a run, never deflates it).

```
pattern            roc_ns     rust_ns  roc_MBps  rust_MBps  slowdown  cnt
literal          40259100       42974      6.51     6100.1      937x   ok
teddy_alt       100045650      430740      2.62      608.6      232x   ok
class_plus       87104950     2102483      3.01      124.7       41x   ok
bounded_num      39855000      109841      6.58     2386.6      363x   ok
word_bound      353435950      192911      0.74     1358.9     1832x   ok
two_words        95086950     1534538      2.76      170.8       62x   ok
caps_email       82937250       71120      3.16     3686.0     1166x   ok
uni_letters      89184250     2050669      2.94      127.8       43x   ok
dotstar_lit      97443200      646867      2.69      405.3      151x   ok
```

literal / bounded_num / caps_email slowdowns swing a bit run to run (the Rust
side is only tens of µs); the Roc side is stable.

### Reading it

- **Roc runs at ~0.7–6.6 MB/s** — the many-match scans that give Rust real work
  (`class_plus`, `uni_letters`, `two_words`) sit at ~3 MB/s; the outlier is
  `word_bound` (0.7 MB/s), whose per-position word-boundary look-around the
  allocation work barely touched.
- **Rust spans 125 MB/s to 6 GB/s** because it dispatches specialised paths
  (memchr for the literal, SIMD Teddy for the alternation, a lazy DFA for the
  big scans).
- **Slowdown is ~41–62× on the heavy many-match scans** and ~150–1800× on the
  patterns Rust answers almost for free. So the gap is really "Rust has fast
  paths we don't", not a uniform constant.

### Engine optimizations (2026-09-03)

The numbers above are ~2× better than the first measurement across the board
(≈5× on `teddy_alt`), from four commits that attacked the `find_all` allocation
traffic — profiling had shown ~78% of its time in malloc/refcount/memcpy, not
matching:

| commit | change | effect |
|---|---|---|
| `4dd4e01` | generation-stamped `visited` set (was a linear `List` scanned with `List.contains` + grown with `List.append` every position) | O(1) dedup, no per-step alloc |
| `be93982` | index-based reused closure stack (was `List.concat`/`drop_last` per ε-step) | one reused buffer |
| `3f32b64` | start-only whole-match engine for find/find_all/is_match — a thread carries just `start : U64`, no per-thread slot list | drops all slot allocation on the span path |
| `a367671` | delete the now-dead slots `find`/`match_at`/`arun` | — |

Cumulative speedup (64 KiB, back-to-back): teddy_alt 4.6×, caps_email 2.7×,
literal 2.6×, bounded_num 2.5×, dotstar_lit 2.1×, two_words 1.9×, class_plus
1.8×, uni_letters 1.7×, word_bound 1.1×. Each was verified under `--opt=speed`
for both correctness (differential 860/860) and non-regression (a slower result
would mean a buffer had refcount > 1 and was being cloned).

It is **still ~80% allocation-bound.** The remaining allocators — the per-match
`visited`/`stack` setup and the per-position thread list — can only be reused by
carrying buffers *across* the per-match call boundary, which is where a loop
`var` held during the call forces refcount > 1 and Roc clones the whole buffer
(a ~2× regression, measured and reverted). Removing that needs either inlining
the scan into one large function (which trips the optimizer blowup noted in
`notes/2026-09-02-pikemut.md`) or a move idiom Roc doesn't expose here — the same
"it's the Roc compiler, not LLVM" theme as the tail-call issue.

### Compile latency

Rust `Regex::new` costs ~30–700 µs per pattern *at runtime*. Roc pays that at
build time via constant folding and 0 at runtime — the one axis where this
design is unambiguously ahead. For a compile-once/match-a-lot workload it's
noise; for compile-per-call it is the whole game.

## `find_all` stack overflow — found and fixed

The first version of this benchmark crashed with **SIGBUS (exit 138)** on
haystacks larger than ~16 KiB. Root cause: `Regex.all_caps`'s match loop was a
tail-recursive helper (`all_loop`) that iterated once per match. It is written
in tail position, and the `--opt=dev` backend loops it correctly, but at
`--opt=speed` it is not looped: Roc's tail-call pass runs *after* inlining, and
inlining the matcher merges the loop's branch tails, so the pass's shared-tail
guard rejects both self-calls. The stack then grew one ~2 KB frame per match and
overflowed after a few thousand — so the crash tracked match count *for complex
patterns only* (a literal at 300k matches was fine; a class or alternation died
at a few thousand). This is a Roc-compiler pass, not LLVM; full root cause in
`upstream/2026-09-02-llvm-tco-match-loop/`.

Fixed by rewriting `all_caps` as an explicit `while` loop with `var` state, so
stack use is O(1) regardless of match count and it no longer depends on
tail-call optimisation. Verified: 256 KiB and 1 MiB haystacks (40k–160k
matches) run clean; differential 860/860 vs Rust; smoke 21/21. The compiler
tail-call miss is written up for upstream in
`upstream/2026-09-02-llvm-tco-match-loop/`.

## Caveats

- `find_all` re-runs the whole-match scan (`Pike.wfind_from`) from each match
  end, re-allocating its `visited`/`stack` buffers per match; part of the Roc
  cost is that per-match restart, not just raw scan speed.
- Single-`find` (with the Teddy/prefilter rungs) is not measured here; it would
  show the SIMD path and a smaller gap on literal-alternation patterns.
- Absolute MB/s shifts a little with haystack size; the ratios are what matter
  and those are size-stable.
