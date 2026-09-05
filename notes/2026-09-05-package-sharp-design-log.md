# package-sharp — design log

**Date:** 2026-09-05
**Branch:** `claude/resharp-regex-design-review-60cff0`
**Scope:** a second Roc regex engine porting RE# (`~/Repositories/resharp-dotnet`) —
Brzozowski derivatives, leftmost-longest, `&`/`~`/`_`, normal-form lookarounds —
as a companion package beside `Regex`. Plan: `plans/2026-09-05-package-sharp.md`.

## Goal

Ship RE#'s semantics and syntax in pure Roc with the project's fold thesis
intact: a literal pattern compiles at build time to a flat table; a runtime
pattern compiles at runtime; one function, one code path. Measured against
RE#'s own corpus, a brute-force reference, and RE# itself.

## Constraints

- Purity: no mutable matcher object, so RE#'s lazy DFA becomes "folded prefix +
  runtime extension of a linearly threaded record".
- D12: everything folded is flat `List(U32)`/`List(U64)`; construction is
  append-only on large lists; `List.set` only on small ones (interning index,
  transition rows).
- D3/D8: codepoint alphabet with an `Invalid` symbol class; RE# is UTF-16 with
  .NET Unicode tables, so Unicode disagreements with the oracle are expected and
  excluded from the differential.
- No `dotnet` on the machine today; the RE# TOML corpus (331 cases) is the only
  oracle available until M3 installs the SDK.

## Q1 — What is package-sharp relative to `Regex`?

Options: companion engine; replacement candidate; perf experiment only.
Leftmost-longest set semantics, no captures, no lazy quantifiers, multiline
anchors and empty-match-after-match reporting are all user-visible differences
from the Rust-compatible engine; the 1512-case Rust differential cannot judge
it. **Choice: companion engine (S1).**

## Q2 — Oracle

Options: TOML corpus + brute-force reference + dotnet diff; corpus + reference;
corpus + dotnet. The reference is the only oracle that speaks our alphabet
(`_`/`~` over `Invalid`); real RE# is the only check that our reading of
`llmatch`'s details matches the authors'. **Choice: all three (S2).**

The reference is a structural interpreter over the rewritten node DAG
(`ends(node, s)` = the set of match ends from `s`, with `\A`/`\z`/lookarounds
resolved against the whole haystack), not a derivative re-run — an independent
mechanism catches derivative bugs; a derivative-based reference would share
them. Same intent as the plan's S2.2 (no automaton, exercises the rewrite
layer); noted here because the plan text said "nullability of derivatives".

## Q3 — Eager vs lazy

Options: eager only with unbounded lookahead a compile error (recommended);
eager plus a lazy runtime fallback; lazy only. The user chose completeness:
RE#'s `a(?=.*b)` "infinite automaton" story is part of what is ported.
**Choice: eager plus lazy (S3).**

## Q4 — Fallback shape

Options: one engine (folded prefix + runtime extension, RE#'s own
`DfaThreshold` structure); two engines; lazy only for unbounded lookahead.
**Choice: one engine (S3).** Replaces D10's "downgrade to PikeVM" with
"continue lazily".

## Q5 — Alphabet: `_` and `~` over `Invalid`

Options: `_` includes `Invalid` (true complement); `_` excludes it. **Choice:
includes (S6).** De Morgan holds; `.`/`[^a]` still exclude `Invalid` per D8.

## Q6 — Anchors

Options: RE#'s always-multiline `^`/`$`; Rust's text anchors. **Choice: RE#'s
(S7).** Matches the oracle and 73 anchor corpus cases; costs nothing in the
engine.

## Q7 — Parser

Options: new parser copying `Comp`'s lexer/class/escape code; mode flag on
`Comp`. **Choice: new parser (S8).** The AST differs in kind (And/Not/Any, no
Save/lazy).

## Q8 — Layout

Options: copy Trie/Uni/Teddy/Lit/Err now, consolidate later; extract
`package-core` first; cross-package imports. **Choice: copy now (S8).**

## Q9 — Rewrite tiers in v1

Options: tiers 1+3 now, tier 2 measured in (recommended); all three; tier 1
only. **User's choice: all three (S10).** Each tier-2 rule still gets a
state-count number so its effect on our alphabet is known.

## Q10 — API surface

Options: `is_match, find_all, count, find, replace_all, split, first_end,
longest_end`; RE#'s exact surface; early-exit `find`. **Choice: the first
(S11).** `find` is a documented full sweep.

## Q11 — Arena representation

Options: flat `List(U32)` cells + hand-rolled open-addressing index; Roc
`Dict`. **Choice: flat (S9).** `Dict` fold and in-place behaviour are
unmeasured.

## Q12 — Runtime state cap

Options: evict to the folded prefix and continue; `Try` error arm; crash.
**Choice: evict (S4).**

## Q13 — Accelerators

Options: derivative-driven, staged by measurement; everything in v1; reuse
`Comp`'s AST extraction. **Choice: derivative-driven, staged (S13).** Requires
a right-to-left SIMD kernel that does not exist yet.

## Q14 — Spike gates

Options: gate on unknowns 1, 2, 4 (recommended); gate on all five; none.
**User's choice: none (S14).** Unknowns are measured as the work lands and
recorded in `notes/` with the fail consequence the plan lists.

## Q15 — Cache lifetime

Options: per-call plus a threaded `find_all_grow`; per-call only; threaded
only. **Choice: per-call plus threaded (S5).**

## Q16 — Build order

Options: reference-first; automaton-first; lazy-first. **Choice: reference-first
(S15).** M1 passes the corpus through the reference alone.

## What's deferred

| item | reason | where |
|---|---|---|
| shared `package-core` | after both engines are stable | S8 |
| pruning tier-2 rewrites | all ship; dropping is a later measurement | S10 |
| forward leftmost-longest `find` | not an RE# algorithm | S11 |
| captures | RE# has none; `Regex` exists | plan "Deferred" |
| lookarounds inside `~`, unions of lookarounds, unrewritable mid-pattern lookarounds | RE#'s own unsupported set | plan "Deferred" |
| more than 64 minterms | RE# uses a BitVector solver past 64; v1 returns a compile error naming the count | this log (M1 finding) |

## Conventions established

- Minterms are true equivalence classes: the copied `Trie`'s cut-point atoms
  are grouped by their membership signature over the pattern's sets, and the
  trie's leaves are remapped atom → minterm. A tset is a `U64` bitset over
  minterms (RE#'s `UInt64Solver`).
- Node ids 0–6 are fixed as in RE# (`BOT, EPS, TOP, TOP_STAR, TOP_PLUS,
  END_ANCHOR, BEGIN_ANCHOR`) so ported rewrite rules read the same.
- Node cells: `[kind, a, b, children…]` in one `List(U32)`; node id = cell
  offset. Per-node info in parallel flat lists indexed by node id.
- The engine state (arena + index + tables) is one record threaded linearly:
  moved into each constructor/derivative call and returned, never held by a
  `var` during the call.
- Intra-module calls are module-qualified (`Node.mk_or`) as in `package/`;
  recursive nominal types are destructured only with `match`.
- Every RE# rewrite rule ported keeps RE#'s comment tag (`sub 01` … `sub 07`,
  `merge loops 2/3`) so the two codebases can be diffed rule by rule.

## M1 findings (2026-09-05)

Gate: `tools/sharp-corpus/gen.py` → 331/331 (285 executed through the
reference alone, 46 `nullable_positions` cases skipped until M2's reverse
sweep exists, `tests07_unsupported` all rejected); `tools/sharp-corpus/nodes.roc`
→ 57/57 of RE#'s `_02_NodeTests` / `_03_SubsumptionTests` /
`_04_DerivativeTests` transcribed against our printer.

### RE# divergences (corpus expectations overridden in `gen.py`)

Two corpus cases record RE# output that contradicts RE#'s own leftmost-longest
specification. The reference and this engine follow the specification; the
generator carries the spec-correct spans in `KNOWN_RESHARP_DIVERGENCES`.

1. `(ab){1,3}(?=.*c)` on `__ababab_c`: RE# `[2,6],[6,8]`; spec `[2,8]`
   (`ababab` at 2 is followed by `_c`). Cause found in `mergeOrLookaheads`: a
   fresh lookahead (`rel` 0, EMPTY pending set — "one candidate end, right
   here") merged with pending ones contributes nothing to the unioned set, so
   the just-ended candidate is lost. `Build.merge_or_lookaheads` reads an empty
   pending set as `{(0,0)}`, which is what it denotes. Report upstream.
2. The `tests08` "lookback 2" log-line pattern
   `(?<=6|8\(.*).*&(?<=6|8\(|4|8|0\().*&~(.*\)\:.*)&\w.*&.*\w&.*(?=.*\)\:)&.*(?=\)\:|\)\:)`:
   RE# `577-604` for the last match; spec `568-604`. Byte 568 (`8`) is preceded
   by `6`, both lookbehinds hold, 568–604 contains no `):` and is followed by
   `):`; 568 is leftmost. The "lookback 1" variant without the first lookbehind
   term gives 568 in RE# too. Cause not isolated (no `dotnet` here); first item
   for the M3 differential.

### Deliberate deviations from RE#'s code

- `mkAnd` over three or more singletons: RE# unions their sets
  (`solver.Or`); an intersection of singletons is their intersection.
- `mkConcat2`'s `LookBehind · Concat(LookBehind, rest)` rule: RE# takes the
  rest from `SplitTail`, which drops every element but the last; ours keeps
  the concat's tail. RE# never reaches this branch because
  `mkConcatChecked` merges adjacent lookbehinds first.
- `[\s\S]` is not `_`: it excludes the `Invalid` symbol (S6/D8), so
  `[\s\S]*` prints as `[\s\S]*`, not `_*`. RE#'s "identity true star" test is
  therefore expected to differ.
- `\B` is unsupported, as in RE# (a union of lookarounds).

### Normalizations that .NET's parser did for RE#

`Ast.simplify` splices nested `|`/`&`/concatenation into the parent and turns
an alternation of positive classes into one class, so `a|b|c` has two
minterms and `(.*|(.*11.*|1.*))` collapses to `.*` under star-subsumption.
Without it the corpus still passed; the node-layer tests exposed the gap.

### Unknown 4 (fold cost), first data point

`smoke.roc` (17 constant cases) folded the compile AND the reference search
at build time in ~9 s, ~140 MB. The corpus runner threads an argv-derived
filler into every haystack so its 331 cases evaluate at runtime (build 22 s,
run 5.6 s under `--opt=dev`). A per-pattern fold-cost measurement waits for
M2's tables, which are what the artifact will actually carry.

## M2 findings (2026-09-05)

Gate: corpus 331/331 with every case run on the derivative automaton AND the
reference (agreement required), including the 46 `nullable_positions` cases
against the reverse sweep. 57→59 patterns exceed the fold budget (unbounded
lookaheads) and finish lazily at scan time.

### RE# divergence 2, root cause

The reverse sweep records match starts in RE#'s order: `574, 568, 587, 577,
564, …` for the log-line pattern. A lookbehind alternative that resolves at
once (`6`) records its position immediately; the `8\(.*` alternative resolves
for every pending start when `8(` is finally read, appending larger positions
AFTER smaller ones. RE#'s `llmatch_ends` walks the list from the end assuming
it is sorted right-to-left, meets 577 before 568, and 568 is then skipped as
"inside the previous match". `Dfa.find_all` sorts the starts first. Both
divergences are now understood; both are RE# bugs to report upstream.

### Unknowns, measured (`tools/sharp-size/probe.sh`, 256 KB haystack, `--opt=size`)

| pattern | states | fold complete | build s | RSS GB | binary | `find_all` ns |
|---|---|---|---|---|---|---|
| `Holmes` | 29 | yes | 15.6 | 1.9 | 1.32 MB | 23 M |
| `Sherlock\|Holmes\|…` | 69 | yes | 15.5 | 1.9 | 1.35 MB | 27 M |
| `[A-Za-z]+` | 5 | yes | 15.5 | 1.9 | 1.29 MB | 59 M |
| `\bthe\b` | 19 | yes | 15.7 | 1.9 | 1.78 MB | 24 M |
| `\w+\s+\w+` | 10 | yes | 15.7 | 1.8 | 1.78 MB | 49 M |
| `_*cat_*&_*dog_*` | 80 | yes | 15.4 | 1.8 | 1.35 MB | 66 M |
| `~(_*\d\d_*)` | 7 | yes | 15.6 | 1.8 | 1.45 MB | 70 M |
| `a(?=.*b)`, uncapped | 13108 | no | 25.8 | 6.1 | 5.08 MB | 30 M |
| `a(?=.*b)`, cap 1024 | 1024 | no | 15.5 | 1.8 | 1.68 MB | 29 M |

- **Unknown 4 (fold cost):** a no-fold baseline build (runtime pattern) is
  20.5 s / 1.9 GB, so the ~15.5 s / 1.85 GB is the compiler compiling
  `package-sharp`, not the fold; a complete pattern's fold costs nothing
  measurable and strips the compiler from the binary. The exception is an
  input-dependent state space: 13k states cost +10 s / +4.3 GB / +3.7 MB.
  `Sharp.fold_state_cap = 1024` bounds that (S12 amended: the D13 formula, capped).
  The compiler's 1.9 GB on this package is out of proportion to the old
  package's ~140 MB and is itself an item to look at.
- **Unknown 2 (extending a folded table at runtime):** works — the capped
  `a(?=.*b)` completes its states during the scan at the same speed as the
  uncapped one (29 vs 30 ms). Whether the first `List.set` copies the folded
  table once per call is not yet isolated.
- **Unknown 1 (linear threading):** the engine record threads through every
  scan and the corpus is exact; the cost is visible in the run times below.
- **Runtime:** 23–70 ms per 256 KB `find_all` is ~10–20× the existing
  engine's DFA. Expected at M2: the scan runs over a precomputed class list
  with a generic `step` on a threaded record, no fused ASCII table, no
  accelerators. M4's job.

### Owed upstream

- `roc build` exits non-zero on warnings; `tools/sharp-size/probe.sh` judges
  success by the produced binary.
- Two crashes in debug-only helpers with a large lookaround pattern, repros in
  `upstream/2026-09-05-sharp-debug-crashes/`: `Sharp.show_rev` faults in
  `free` (heap corruption, dev backend), `Sharp.derive_chain_rev` overflows
  the stack. The same pattern's `find_all` path is fine. Not reduced yet.
