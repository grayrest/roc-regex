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
literal          36298200       42974      7.22     6100.1      845x   ok
teddy_alt        77417050      430740      3.39      608.6      180x   ok
class_plus       80519400     2102483      3.26      124.7       38x   ok
bounded_num      36244450      109841      7.23     2386.6      330x   ok
word_bound      351234000      192911      0.75     1358.9     1821x   ok
two_words        85171900     1534538      3.08      170.8       56x   ok
caps_email       71822850       71120      3.65     3686.0     1010x   ok
uni_letters      82022300     2050669      3.20      127.8       40x   ok
dotstar_lit      82923650      646867      3.16      405.3      128x   ok
```

literal / bounded_num / caps_email slowdowns swing a bit run to run (the Rust
side is only tens of µs); the Roc side is stable.

### Reading it

- **Roc runs at ~0.75–7.2 MB/s** — the many-match scans that give Rust real work
  (`class_plus`, `uni_letters`, `two_words`) sit at ~3 MB/s; the outlier is
  `word_bound` (0.75 MB/s), whose per-position word-boundary look-around the
  allocation work barely touched.
- **Rust spans 125 MB/s to 6 GB/s** because it dispatches specialised paths
  (memchr for the literal, SIMD Teddy for the alternation, a lazy DFA for the
  big scans).
- **Slowdown is ~38–56× on the heavy many-match scans** and ~130–1800× on the
  patterns Rust answers almost for free. So the gap is really "Rust has fast
  paths we don't", not a uniform constant.

### Engine-matched: vs Rust's *PikeVM*, not its DFA

The `rust_ns` column above is Rust's **meta engine** — a lazy DFA plus
memchr/SIMD prefilters. Roc's `find_all` runs a **PikeVM** (O(n·states) thread
simulation), a different and slower algorithm than a DFA, so that comparison
conflates "Rust has a DFA" with "Roc's implementation is slower". The
engine-matched number is Roc's PikeVM against `regex-automata`'s PikeVM (same
algorithm), added as a column to `tools/bench` (`rustPV`):

```
pattern         roc_ns  rustPV_ns  vsPV   rustMeta_ns  vsMeta
literal       36610550    3481229  10.5x       69791    525x
teddy_alt     77824550    5276869  14.7x      411945    189x
class_plus    81252350    7935828  10.2x     2193313     37x
bounded_num   36385700    3482498  10.4x      106181    343x
word_bound   353712750    5466075  64.7x      208540   1696x
two_words     85825650    8548217  10.0x     1529254     56x
caps_email    72808450    8239148   8.8x       70468   1033x
uni_letters   82727050    8109591  10.2x     2024092     41x
dotstar_lit   83708650    6829018  12.3x      636093    132x
```

So the honest implementation gap is **~10× vs the same algorithm** (8.8–14.7×),
not the 37–1696× the meta-engine column suggests. Rust's own PikeVM is 3.6–4×
slower than its DFA on the scan-heavy patterns and 50–120× slower on the ones
memchr/DFA answer trivially — that difference is *algorithm*, and it's not Roc's
to close with a PikeVM. The one real outlier is `word_bound` at ~65×: Roc's
word-boundary look-around (`word_before`/`word_after`, each decoding a
codepoint) is a specific hotspot worth its own pass. The ~10× elsewhere is the
immutable-`List` + refcount overhead the profile shows (73% memory-bound). Match
counts agree across all three (Roc, Rust meta, Rust PikeVM).

### Engine optimizations (2026-09-03)

The numbers above are ~2–2.5× better than the first measurement across the board
(≈6.5× on `teddy_alt`, 1164→180×), from five commits that attacked the
`find_all` allocation traffic — profiling had shown ~78% of its time in
malloc/refcount/memcpy, not matching:

| commit | change | effect |
|---|---|---|
| `4dd4e01` | generation-stamped `visited` set (was a linear `List` scanned with `List.contains` + grown with `List.append` every position) | O(1) dedup, no per-step alloc |
| `be93982` | index-based reused closure stack (was `List.concat`/`drop_last` per ε-step) | one reused buffer |
| `3f32b64` | start-only whole-match engine for find/find_all/is_match — a thread carries just `start : U64`, no per-thread slot list | drops all slot allocation on the span path |
| `a367671` | delete the now-dead slots `find`/`match_at`/`arun` | — |
| `3fa8c0c` | double-buffer the whole-match thread queues (`WCl` carries a count `n`; two `ths` buffers ping-pong across positions instead of `{ths:[]}` + append every position) | no per-position thread-list alloc |

Cumulative speedup (64 KiB, back-to-back): teddy_alt 6.1×, caps_email 3.4×,
dotstar_lit 2.7×, bounded_num 2.9×, class_plus 2.0×, two_words 2.4×, literal
2.6×, uni_letters 2.1×, word_bound 1.2×. Each was verified under `--opt=speed`
for both correctness (differential 860/860) and non-regression — a slower result
would mean a buffer had refcount > 1 and was being cloned, and the discipline
throughout was that a reused buffer must be threaded *linearly* (moved into each
call, never held by a `var`/pool slot during the call) so `List.set` mutates in
place.

It is now **~73% allocation-bound** (down from 78%; `malloc` specifically fell
to ~33% while `rc` refcount traffic rose to the top at ~30%). The remaining
allocators are the per-*match* setup (`visited`/`stack` and the two thread
buffers grow from `[]` once per match) plus the accumulator. Pooling those
*across* matches was tried and **did not pay** — the buffers are small (a dozen
`U32`) and the pool wrapper allocates a one-element list per match, a wash — and
the naïve cross-match reuse via a loop `var` held during the call forces
refcount > 1 and clones (a measured ~2× regression, reverted). Cutting the `rc`
30% or the per-match residue further would need fewer threaded values or a move
idiom Roc doesn't expose here — the same "it's the Roc compiler, not LLVM" theme
as the tail-call issue.

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
