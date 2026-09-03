# roc-regex

A port of Rust's `regex` crate to Roc, over a **codepoint alphabet**, using the
compiler's compile-time evaluation of pure functions in place of an
ahead-of-time compilation mode. `Regex.compile("…")` on a literal pattern is
evaluated during the build and the artifact is stored in the executable; the
same call on a runtime pattern runs at runtime. One function, one code path, no
macro and no build step.

Nothing is implemented.

| document | status |
|---|---|
| [`plans/2026-09-02-roc-regex-rev2.md`](plans/2026-09-02-roc-regex-rev2.md) | **CURRENT — NOT REVIEWED as a document.** 14 decisions, 11 measured, 3 not |
| [`plans/2026-09-01-roc-regex.md`](plans/2026-09-01-roc-regex.md) | **SUPERSEDED.** Reviewed 8×, amended 14× in place; kept as the record |

Measurement notes, in the order taken:

| note | what it establishes |
|---|---|
| [fold probes](notes/2026-09-01-fold-probe-log.md) | compile-time evaluation is real, unbudgeted, cached, and stops at the first runtime argument |
| [adversarial review r1](notes/2026-09-01-adversarial-review.md) | 7 fatal, 32 major, 18 minor against rev-1 |
| [construction rules](notes/2026-09-02-fold-construction.md) | `concat` is quadratic, `List.set` never frees, memory is ~10 B of RSS per artifact byte |
| [codepoint alphabet](notes/2026-09-01-codepoint-alphabet.md) | the reversal: 99.1–99.7% of a byte DFA's states are UTF-8 bookkeeping; Unicode `\b` verified over codepoints |
| [D6/D11 re-measure](notes/2026-09-02-d6-d11-remeasure.md) | aho-corasick re-argued; pattern IDs cost exactly zero at N=1 |

Numbers in these documents are measured or absent, and where a measurement was
later found to be overstated the correction is recorded next to it rather than
substituted for it. Two rev-1 throughput figures were struck outright after an
audit found their loops never left their start state.

The single number the current plan most depends on is still absent: **the
artifact size of a realistic pattern including its per-pattern class trie**,
which sets both stop rule 1's threshold and D10's default budget. M1's gate
takes it.

## Status: M1 complete

The M1 vertical slice runs end to end — parser (literals, `.`, classes, `\w \d
\s`, `\b`, anchors, `* + ? {n,m}` with lazy variants, `|`, groups), Thompson NFA
over codepoint classes (S3), the S1 partition and S2 class trie, a PikeVM (S5),
and the D7 build-time error path. `examples/smoke.roc` passes 21/21; a bad
literal pattern fails the build with a rendered caret message. Gate numbers are
in [`notes/2026-09-02-m1-gate.md`](notes/2026-09-02-m1-gate.md).

All five milestones (M1–M4) are implemented and committed. The engine agrees
with the Rust `regex` crate on **1431/1431** differential cases across three
paths (`find_all`, `is_match`, three-pass `find`), including Unicode classes,
`\p{}`, `(?i)`, empty-match iteration, and pathological patterns.

| module | milestone | what |
|---|---|---|
| `Comp` | M1/M1.5/M2/M4 | parser, AST, NFA compiler, captures, `\p{}`/`(?i)`, prefix extraction |
| `Trie` | M1 | S1 partition + S2 class trie |
| `Pike` | M1/M1.5/M4 | PikeVM with slots; anchored `match_at` |
| `Rev` | M3 | leftmost determinizer, reverse DFA, three-pass `find` (D5) |
| `Uni` | M2 | generated Unicode Tier A tables (packed) |
| `Lit` | M4 | scalar prefilter rungs |
| `Teddy` | M4 | SIMD (`U8x16`) Teddy prefilter |
| `Regex` / `Err` | all | public surface; D7 error + renderer |

`find` is the D5 three-pass span finder (forward DFA end + reverse DFA start,
both leftmost-first, folded into the artifact); captures/`replace`/`split` layer
on the PikeVM. The full 1431-case differential harness (`tools/diff`) completes
at **1431/1431 agreeing with the Rust crate** across `find_all`, `is_match` and
the three-pass `find` — after it exposed and forced the fix of an epsilon-cycle
non-termination bug (`(a*)+`) in the three-pass closure.

Honest gaps: full `\p{}` breadth, `(?i:...)` scoped flags, Unicode `\b` in the
DFA (look patterns use the PikeVM), captures direct from the reverse pass, and
the shared-vs-per-pattern trie decision (D3 fork). Each is in the milestone
notes under `notes/`.

## Benchmark

`tools/bench/run.sh` times this engine against the vendored Rust `regex` crate
on an identical haystack (match counts are compared to enforce identical work).
Match throughput only — the regex is compiled once, before the timing loop, on
both sides. Roughly: Roc runs at **~0.75–7.2 MB/s** (the many-match scans that
give Rust real work sit at ~3 MB/s), Rust at 125 MB/s–6 GB/s, so the slowdown is
**~38–56× on heavy many-match scans up to ~thousands× on patterns Rust answers
via memchr/DFA for free**. Compile cost is the one axis Roc wins: 0 at runtime
(folded at build) vs ~30–700 µs/pattern for `Regex::new`. Full numbers, method,
and the 2026-09-03 allocation work that cut the gap ~2–2.5× (generation-set
dedup, reused closure stack, start-only whole-match engine, double-buffered
thread queues) are in `notes/2026-09-02-benchmark.md`. Benchmarking also flushed out a `find_all`
stack overflow on large inputs — a tail call Roc's optimizer wouldn't loopify —
now fixed with an explicit `while` loop and written up for upstream in
`upstream/2026-09-02-llvm-tco-match-loop/`.
