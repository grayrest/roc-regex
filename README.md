# roc-regex

A port of Rust's `regex` crate to Roc, over a **codepoint alphabet**, using the
compiler's compile-time evaluation of pure functions in place of an
ahead-of-time compilation mode. `Regex.compile("…")` on a literal pattern is
evaluated during the build and the artifact is stored in the executable; the
same call on a runtime pattern runs at runtime. One function, one code path, no
macro and no build step.

The engine is implemented end to end (M1–M4) and agrees with the Rust `regex`
crate across the differential corpus; see **Status** below.

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

The number the current plan most depends on — **the artifact size of a realistic
pattern including its per-pattern class trie** — is now measured by
`tools/size/probe.sh`: a folded binary is ~460–674 KB (the parser/determinizer
is stripped when `compile` folds), the DFA tables cost ~224 B for an ASCII class
up to ~33 KB for a Unicode class, and the dominant term is the per-pattern
Unicode class data (~180 KB for `\w`, needed by both the DFA and the PikeVM) —
the D3 shared-vs-per-pattern-trie question, not the engine. This sets stop
rule 1's threshold and D10's default budget.

## Two engines, and which one is the default

| directory | module | what |
|---|---|---|
| [`package/`](package/README.md) | `Sharp` | **the default engine.** A port of RE#'s design — Brzozowski derivatives, leftmost-longest, `&`/`~`/`_`, lookarounds. No captures. |
| `package-dfa/` | `Regex` | the original Rust-`regex` port — leftmost-first, captures, PikeVM. Frozen: it is the Rust-semantics oracle and a Roc codegen benchmark. |
| `package-http/` | `Http`, `Router` | HTTP framing and matchit-syntax routing on `Sharp`. |

New work lands in `package/`. `Regex` keeps the sections below because the
plans and measurement notes that produced it are the record of how the
codepoint alphabet and the fold-based build were established, and both engines
still share `Uni`, `Trie`, `Teddy` and `Lit`.

`Sharp`'s plan is [`plans/2026-09-05-package-sharp.md`](plans/2026-09-05-package-sharp.md);
its decisions and measurements are in
[`notes/2026-09-05-package-sharp-design-log.md`](notes/2026-09-05-package-sharp-design-log.md).
`tools/bench/run.sh` prints both engines next to Rust.

## Status: M1 complete

The M1 vertical slice runs end to end — parser (literals, `.`, classes, `\w \d
\s`, `\b`, anchors, `* + ? {n,m}` with lazy variants, `|`, groups), Thompson NFA
over codepoint classes (S3), the S1 partition and S2 class trie, a PikeVM (S5),
and the D7 build-time error path. `examples/smoke.roc` passes 21/21; a bad
literal pattern fails the build with a rendered caret message. Gate numbers are
in [`notes/2026-09-02-m1-gate.md`](notes/2026-09-02-m1-gate.md).

All five milestones (M1–M4) are implemented and committed. The engine agrees
with the Rust `regex` crate on **1546/1546** differential cases across three
paths (`find_all`, `is_match`, three-pass `find`), including Unicode classes,
`\p{}`, `(?i)`, empty-match iteration, and pathological patterns.

| module | milestone | what |
|---|---|---|
| `Comp` | M1/M1.5/M2/M4 | parser, AST, NFA compiler, captures, `\p{}`/`(?i)`, prefix extraction |
| `Trie` | M1 | S1 partition + S2 class trie |
| `Pike` | M1/M1.5/M4 | PikeVM with slots; anchored `match_at` |
| `Rev` | M3 | leftmost determinizer, reverse DFA, three-pass `find` (D5) |
| `Uni` | M2 | generated Unicode Tier A tables (packed) |
| `Lit` | M4 | literal memcmp for candidate verifies |
| `Teddy` | M4 | SIMD (`U8x16`) Teddy prefilter |
| `Regex` / `Err` | all | public surface; D7 error + renderer |

`find` is the D5 three-pass span finder (forward DFA end + reverse DFA start,
both leftmost-first, folded into the artifact); captures/`replace`/`split` layer
on the PikeVM. The full 1546-case differential harness (`tools/diff`) completes
at **1546/1546 agreeing with the Rust crate** across `find_all`, `is_match` and
the three-pass `find` — after it exposed and forced the fix of an epsilon-cycle
non-termination bug (`(a*)+`) in the three-pass closure.

`\b` / `\B` (including Unicode word boundaries) now run **in the DFA** — the
codepoint alphabet makes word-ness a single-symbol property, so the boundary is
baked into the transition function (a left-context bit + per-position accept)
rather than falling back to the PikeVM
(`notes/2026-09-04-word-boundary-dfa-scope.md`). Outermost `^` / `$` text
anchors also run on the DFA (`^` → an anchored forward scan, `$` → reverse from
`len`); anchors buried inside alternations/groups still use the PikeVM
(`notes/2026-09-04-anchors-dfa-scope.md`).

Honest gaps: full `\p{}` breadth, `(?i:...)` scoped flags, buried `^`/`$` in the
DFA, captures direct from the reverse pass, and the shared-vs-per-pattern trie
decision (D3 fork). Each is in the milestone notes under `notes/`.

## Benchmark

`tools/bench/run.sh` times this engine against the vendored Rust `regex` crate
on an identical haystack (match counts are compared to enforce identical work).
Match throughput only — the regex is compiled once, before the timing loop, on
both sides. The comparison includes an **engine-matched** column (Rust's
`regex-automata` PikeVM — the same O(n·states) algorithm), separate from Rust's
meta engine (a lazy DFA + memchr/SIMD).

As of 2026-09-04, **`find_all` runs on the DFA** for look-free, in-budget
patterns (it already did for `find`/`is_match`); only look patterns (`\b`, …),
over-budget (`TooBig`), and the capture paths stay on the PikeVM. This made
`find_all` **12–71× faster** on DFA-able patterns — the Roc DFA is now *faster
than Rust's PikeVM* (0.1–0.8×) and within **2–3×** of Rust's meta engine on
regex-class patterns; the remaining double-digit gaps (`literal`, `caps_email`)
are literal-prefilter territory (Teddy/memchr), not the DFA. Scaling is linear
(no O(n²) across match count). Look patterns still run the PikeVM, ~6× vs Rust's
PikeVM after the 2026-09-03 allocation work (generation-set dedup, reused
closure stack, start-only whole-match engine, double-buffered thread queues,
ASCII word-boundary fast path). Compile cost is the axis Roc wins outright: 0 at
runtime (folded at build) vs ~30–700 µs/pattern for `Regex::new`.

`tools/size/probe.sh` measures the folded-artifact size. Folding requires a
top-level `Regex.compile` (not a `let` in an effectful body — so the bench above
is the *runtime-compiled* scan; throughput is identical either way). A folded
binary is ~460–674 KB (the compiler is stripped, vs ~1.1 MB runtime-compiled).
The DFA tables are cheap (~224 bytes for an ASCII class, ~33 KB for a Unicode
class); the dominant artifact cost is the per-pattern Unicode class data (~180 KB
for `\w`), needed by both engines — the D3 trie question, not the DFA.

Full numbers and method are in `notes/2026-09-02-benchmark.md`;
`notes/2026-09-04-dfa-find-all-scope.md` has the DFA `find_all` design.
Benchmarking also flushed out a `find_all` stack overflow on large inputs — a
tail call Roc's optimizer wouldn't loopify — now fixed with an explicit `while`
loop.
