# Benchmark: Roc engine vs Rust `regex` (2026-09-02)

First throughput comparison against the vendored Rust `regex` 1.13 crate.
Harness: `tools/bench/` (`gen` + `bench` bins, `run.sh` driver) and
`examples/bench.roc`. Reproduce with `tools/bench/run.sh`.

---

## 2026-09-04: adaptive literal prefilter for `find_all`

`find_all` on a pattern with a required literal **prefix** (e.g. `Holmes`,
`Holmes\d+`) now SIMD-scans for the prefix (Teddy over `[re.prefix]`) and
verifies each candidate with `Pike.wmatch_at` (~2.5 µs/call — cheap), instead of
stepping the DFA over every codepoint. It's **adaptive**: `Teddy.candidates_capped`
bails to the DFA once candidates exceed `len / 512`, the point where
per-candidate verification overtakes a straight DFA scan — so a *dense* literal
can't regress.

`literal` (`Holmes`) at 256 KiB:

| haystack | DFA | adaptive prefilter |
|---|---|---|
| sparse (32 matches) | ~1.47M ns | **~66K ns (~22×)** |
| dense (Sherlock, 1202) | ~1.01M ns | ~1.03M ns (bails → DFA) |

Big win where the literal is rare (the real case — a word in a document), no
regression where it's dense. This is the fix for the `literal`-vs-meta gap
identified earlier: it was never `wmatch_at` (2.5 µs) nor the DFA per-byte cost —
single literals carry `prefix`, not `tlits`, so no prefilter engaged at all.
1512/1512 differential (verified with the gate forced always-on too).

---

## 2026-09-04: `\b` / `\B` moved into the DFA

Word boundaries are now baked into the determinizer (over the codepoint
alphabet: a left-context word bit in the state + per-position `accept_on` /
`accept_eoi`, since a boundary adjacent to `Match` resolves against the
following symbol). `\b`/`\B` patterns leave the PikeVM for the DFA; `^`/`$` still
force the PikeVM. `word_bound` (`\bthe\b`) at 256 KiB:

```
              old_roc_ns   new_roc_ns  speedup   vsPV  vsMeta
word_bound      32806800       989200     33x    0.2x     5x
```

From ~6× vs Rust's PikeVM to **faster than it** (0.2×) and within 5× of Rust's
meta engine. Differential extended with non-ASCII haystacks (`café`, `αβγ`,
`Москва`, `日本語`, …) to cover Unicode word-ness on the DFA: 1161/1161 agree.

---

## 2026-09-04: `find_all` now runs on the DFA (supersedes the PikeVM numbers below)

`Regex.find_all` used to call the PikeVM (`Pike.wfind_from`) unconditionally,
even though `Regex.find` / `is_match` already ran the DFA. It now branches on
`re.engine`: look-free, in-budget patterns (`Three(d)`) iterate via the forward
+ reverse DFA (`Rev.find_from`), leaving only look patterns (`\b`, …) and
`TooBig`/capture paths on the PikeVM. New code is small — `Rev.run_fwd_from`,
`run_rev_from` (reverse floored at the search start for non-overlap), and
`Rev.find_from`. `1431/1431` differential, `21/21` smoke.

Speedup over the old PikeVM `find_all`, at 256 KiB (`vsPV`/`vsMeta` = ratio to
Rust's `regex-automata` PikeVM / meta engine):

```
pattern         old_roc_ns   new_roc_ns  speedup   vsPV  vsMeta   cnt
literal           36298200      1889600     19x    0.5x     32x   ok
teddy_alt         77417050      2294900     34x    0.4x      6x   ok
class_plus        80519400      6653700     12x    0.8x      3x   ok
bounded_num       36244450      1045950     35x    0.3x     10x   ok
word_bound        32806800     32525850      1x    5.9x    156x   ok   (still Pike: \b)
two_words         85171900      5030400     17x    0.6x      3x   ok
caps_email        71822850      1014000     71x    0.1x     14x   ok
uni_letters       82022300      6723350     12x    0.8x      3x   ok
dotstar_lit       82923650      1293650     65x    0.2x      2x   ok
```

`vsPV < 1` means the Roc DFA is **faster than Rust's PikeVM** on every DFA-able
pattern; the regex-class patterns are within 2–3× of Rust's fully-optimized
meta engine, the remaining double-digit gaps (`literal` 32×, `caps_email` 14×)
being literal-prefilter territory (Teddy/memchr), not a DFA gap.

**Linear scaling confirmed** (the O(n²) worry did not materialize): 128 K→256 K
time ratios were 1.79–2.05× across patterns. The leftmost-first determinizer
truncates the lazy dot-star closure at the first `Match`, so the forward state
goes dead just past each match instead of scanning to EOF — no explicit end
bound needed. Scope + reasoning: `notes/2026-09-04-dfa-find-all-scope.md`.

### Folded vs runtime, and artifact size (`tools/size/probe.sh`)

Building the size probe surfaced that **`Regex.compile` only folds for
module-level defs**, not `let`-bindings inside an effectful body. Both
`examples/bench.roc` and the naive probe use a `let` in the timing loop, so
**the throughput numbers above are the runtime-compiled path** — the binary
links the whole parser/NFA/determinizer and runs it at startup (measured
outside the timing window, so the ns/op figures are unaffected; the scan code
is identical either way).

The folded (AOT) path needs a top-level `rx = Regex.unwrap(Regex.compile("…"))`.
`tools/size/probe.sh` builds one such binary per pattern (`--opt=size`) with a
runtime-file haystack so the folded regex is retained. Findings:

- Folding **strips the compiler**: a folded binary is ~460–674 KB vs ~1.1 MB
  for the runtime-compiled path.
- **DFA tables are cheap.** `[A-Za-z]+` (DFA) adds ~**224 bytes** over an
  ASCII `\bthe\b` (Pike) baseline. For a Unicode class pattern the DFA table is
  ~**33 KB** (`\w+` DFA vs `\b\w+\b` Pike, isolating the table from the class
  data).
- **The dominant cost is the per-pattern Unicode class data**, needed by *both*
  engines: `\w` adds ~**180 KB** (`\b\w+\b`, Pike, no DFA). This is the D3
  shared-vs-per-pattern-trie question the README flags, and it dwarfs the DFA.

So switching `find_all` to the DFA is a large throughput win at a small
(ASCII) to modest (Unicode, ~33 KB) artifact cost; the real artifact lever is
the class trie, not the engine.

---

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
word_bound       32806800      205765      7.99     1274.1      159x   ok
two_words        85171900     1534538      3.08      170.8       56x   ok
caps_email       71822850       71120      3.65     3686.0     1010x   ok
uni_letters      82022300     2050669      3.20      127.8       40x   ok
dotstar_lit      82923650      646867      3.16      405.3      128x   ok
```

literal / bounded_num / caps_email slowdowns swing a bit run to run (the Rust
side is only tens of µs); the Roc side is stable.

### Reading it

- **Roc runs at ~3–8 MB/s** — the many-match scans that give Rust real work
  (`class_plus`, `uni_letters`, `two_words`) sit at ~3 MB/s; the low-match
  patterns (`literal`, `bounded_num`, `word_bound`) reach ~7–8 MB/s.
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
literal       36480750    3479387  10.5x       28343   1287x
teddy_alt     79522750    5332380  14.9x      420315    189x
class_plus    81638900    8036353  10.2x     2221722     37x
bounded_num   36508150    3526138  10.4x      109075    335x
word_bound    32806800    5525314   5.9x      205765    159x
two_words     87166650    8615994  10.1x     1539016     57x
caps_email    72459500    8318266   8.7x       72009   1006x
uni_letters   83399100    8159685  10.2x     2051270     41x
dotstar_lit   84987100    6870349  12.4x      644798    132x
```

So the honest implementation gap is **~6–15× vs the same algorithm**, clustered
around ~10×, not the 37–1287× the meta-engine column suggests. Rust's own PikeVM
is 3.6–4× slower than its DFA on the scan-heavy patterns and 50–120× slower on
the ones memchr/DFA answer trivially — that difference is *algorithm*, and it's
not Roc's to close with a PikeVM. `word_bound` used to be a ~65× outlier; the
`is_word_cp` ASCII fast path (below) brought it to ~6×, now the *best* of the
set. The ~10× elsewhere is the immutable-`List` + refcount overhead the profile
shows (73% memory-bound on the scan patterns). Match counts agree across all
three (Roc, Rust meta, Rust PikeVM).

### Engine optimizations (2026-09-03)

The numbers above are ~2–2.5× better than the first measurement across the board
(≈6.5× on `teddy_alt`, 1164→180×; ≈13× on `word_bound`), from six commits — five
attacking `find_all` allocation traffic (profiling had shown ~78% of its time in
malloc/refcount/memcpy, not matching) plus one on the word-boundary look-around:

| commit | change | effect |
|---|---|---|
| `4dd4e01` | generation-stamped `visited` set (was a linear `List` scanned with `List.contains` + grown with `List.append` every position) | O(1) dedup, no per-step alloc |
| `be93982` | index-based reused closure stack (was `List.concat`/`drop_last` per ε-step) | one reused buffer |
| `3f32b64` | start-only whole-match engine for find/find_all/is_match — a thread carries just `start : U64`, no per-thread slot list | drops all slot allocation on the span path |
| `a367671` | delete the now-dead slots `find`/`match_at`/`arun` | — |
| `3fa8c0c` | double-buffer the whole-match thread queues (`WCl` carries a count `n`; two `ths` buffers ping-pong across positions instead of `{ths:[]}` + append every position) | no per-position thread-list alloc |
| `0702d24` | ASCII fast path in `is_word_cp` (was `List.any` over the full Unicode `\w` range table, twice per position, for a `\b` look-around) | word_bound 10.8× faster |

Cumulative speedup (64 KiB, back-to-back): word_bound 12.8×, teddy_alt 6.1×,
caps_email 3.4×, bounded_num 2.9×, dotstar_lit 2.7×, literal 2.6×, two_words
2.4×, class_plus 2.0×, uni_letters 2.1×. Each was verified under `--opt=speed`
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
