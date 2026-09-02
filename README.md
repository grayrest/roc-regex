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
