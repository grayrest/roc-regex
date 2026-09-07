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
- `mkConcat2`'s fall-through registration right-nests a concat head
  (`(ab)c -> a(bc)`) before interning. RE# only normalizes in its LAST
  match arm, so a rewrite path that ends in `createCached` — the
  concat-tail case, reached whenever the tail is itself a concat — interns
  `Concat(Concat(a,b), c)` as a node distinct from `a(bc)`. See M4.

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

- **Unknown 3 (the engine is DCE'd from a complete-fold binary):** yes,
  once the fast path exists (M4 step 0): a complete fold's binary is 410 KB
  (`Holmes`) to 1.25 MB (`\bthe\b`, Unicode `\w` tables) against 1.73 MB for
  the incomplete `a(?=.*b)`, which keeps the threaded scan, the derivative
  code and the arena constructors. Before M4 step 0 every binary carried them
  (1.29–1.78 MB above).
- **Unknown 5 (a right-to-left SIMD kernel):** works — `Rlit.rfind_byte`
  (one `eq_lanes`/`to_bitmask` per 16-byte window, highest lane by
  `count_leading_zero_bits`) finds all 1157 `@` in 256 KB in 22 µs;
  `Bset.rfind` does the same for byte sets with two `table_lookup`s per
  window. Both measured under M4 stages 1 and 2.

### Owed upstream

- `roc build` exits non-zero on warnings; `tools/sharp-size/probe.sh` judges
  success by the produced binary.
- Two crashes in debug-only helpers with a large lookaround pattern, repros in
  `upstream/2026-09-05-sharp-debug-crashes/`: `Sharp.show_rev` faults in
  `free` (heap corruption, dev backend), `Sharp.derive_chain_rev` overflows
  the stack. The same pattern's `find_all` path is fine. Not reduced yet.

## M3 findings (2026-09-05, part 1: eviction and the threaded variant)

- `Dfa.freeze` records the fold's extent (states, arena marks); a scan that
  mints past `runtime_cap` (RE#'s 100k default) evicts: arena, tables, index
  and refsets are truncated back to the fold, and the current state's node is
  rebuilt through the constructors (`Build.copy_node`) so the scan continues.
  A cap below the folded prefix is ignored — the first version evicted on
  every miss forever when the cap was under the fold (10-minute corpus run).
- Corpus runner: every `matches` case is scanned a third time with a 24-state
  cap, forcing eviction on any pattern that mints states at scan time (the 59
  over-budget ones); 331/331 agree. 14 s for the whole run.
- `Sharp.find_all_grow` returns the regex with its cache extended (S5);
  `Sharp.with_runtime_cap` exposes the cap for tests.
- The Homebrew `dotnet-sdk` cask needs `sudo` for its `.pkg`; the SDK is
  installed user-space with Microsoft's `dotnet-install.sh` into `~/.dotnet`.

## M3 findings (part 2: the RE# differential)

`tools/sharp-diff/`: a C# harness (`ResharpDiff`, references RE#'s
`Resharp.fsproj`, net10.0, `FSharp.Core` pinned so it is copied) answers a
JSON case list with RE#'s `Matches`; `gen.py` defines a 102-pattern ×
35-haystack ASCII corpus in RE# syntax, converts UTF-16 offsets to bytes, and
emits a Roc runner. Outcome classes: Agree / Differ / RejectBoth / WeAccept /
WeReject. Result: **agree 3430, differ 0, reject-both 140, we-accept 0,
we-reject 0** of 3570.

Two things the differential caught:

- **Lazy quantifiers.** RE#'s docs list them as unsupported, but its converter
  maps `Lazyloop` to `mkLoop` (only set-lazy loops raise), so `a*?` compiles
  and means `a*`. Under set semantics laziness has no meaning, so this is the
  right behaviour; `Ast.after_quant` now skips the `?` marker. The
  `LazyQuantifierUnsupported` kind stays in `Err` unused for now.
- **Empty input with both anchors.** `^$`, `^.*$`, `\A.*\z` on `""`: RE#
  reports `[0,0]` (its `canBeNullable` flags), we reported nothing because the
  empty-input check tested `Begin` and `End` separately and `\A…\z` needs
  both at once. `Deriv.loc_both` is a location where both anchors hold; the
  empty-input path uses it.

RejectBoth (140 = 4 patterns × 35): `\Bcat`, `a(?=bb)b`, `(?<=a)b|(?<=c)d`,
`~(\ba)` — RE#'s unsupported fragment, rejected on both sides.

## M4 step 0 (2026-09-05): the byte-loop scan for complete folds

A complete fold is a read-only table, so `Dfa.find_all_fast` scans the
haystack directly — ASCII through a fused byte→state table built at `freeze`,
other symbols through `Utf8.decode`/`decode_rev` and the trie — with no
engine record threaded and no per-call class/offset lists. Pending-nullable
offsets are symbol counts, moved with `Utf8.advance`/`retreat`. The threaded
scan stays for incomplete folds and the corpus cross-checks the two
(`find_all_threaded`) on every case: 331/331; RE# differential 3430/3430.

`tools/sharp-size/probe.sh`, 256 KB, `--opt=size`, ns per `find_all`:

| pattern | before | after | existing `Regex` DFA (memory) |
|---|---|---|---|
| `Holmes` | 23.0 M | 3.5 M | prefilter path, ~0.015 M |
| `Sherlock\|Holmes\|…` | 26.5 M | 1.8 M | ~2.3 M |
| `[A-Za-z]+` | 58.8 M | 14.2 M | ~3.0 M |
| `[0-9]{2,4}` | 30.2 M | 4.8 M | ~1.0 M |
| `\bthe\b` | 23.6 M | 1.4 M | ~1.0 M |
| `\w+\s+\w+` | 48.8 M | 12.2 M | ~2.5 M |
| `(\w+)@(\w+)` | 24.6 M | 4.0 M | ~1.0 M |
| `\p{L}+` | 58.9 M | 15.4 M | ~3.1 M |
| `.*Holmes` | 28.0 M | 4.7 M | ~1.3 M |
| `_*cat_*&_*dog_*` | 65.6 M | 18.4 M | — |
| `~(_*\d\d_*)` | 70.0 M | 18.8 M | — |
| `a(?=.*b)` (incomplete, threaded) | 29.7 M | 34.4 M | — |

Builds also fell to ~8.5 s / ~1.0 GB (the fast path lets the compiler drop
the threaded scan and `Ref.prepare` from a complete-fold binary). Remaining
gap to the existing engine on dense patterns: RE#'s design sweeps the WHOLE
haystack in reverse before any forward pass (two passes over every byte),
and there are no accelerators yet — S13's work.

## M4 accelerators (2026-09-05): S13, first stage

Built (RE#'s `Optimizations.fs`, derivative-driven so they see through
`&`/`~` and the rewrites):

- `Accel.prefix_sets`: `getPrefixNode` + `calcPrefixSets` — the minterm sets
  every match must start with, as derivatives of the reverse pattern while
  exactly one non-dead derivative exists.
- `Accel.set_prefix` (RE#'s `InitialAccelerator.StringPrefix` /
  `SearchValuesPrefix`, `applyPrefixSetsChecked`): the reverse sweep, when in
  its initial state, searches backwards for the rarest single-ASCII set of
  the prefix (`Rlit.rank`, memmem's rarest-byte trick), verifies the other
  sets symbol by symbol, and lands in the state `_*·rev(R)` reaches after the
  whole prefix. Landing states are created at compile time so the fold
  stays complete.
- `Rlit.rfind_byte`: the reverse SIMD kernel — 16-byte windows backwards,
  one `eq_lanes`/`to_bitmask` per window, highest lane via
  `count_leading_zero_bits`.
- `LengthLookup.FixedLength`: every match has one symbol length, so the
  forward end pass is `Utf8.advance`.
- `MatchOverride.FixedLengthString`: the raw pattern IS a literal
  (`inferOverrideRegex`'s conditions: no anchors, no lookarounds, forward and
  reverse), so `find_all` is a Teddy-candidate + `Lit.matches` search. The
  check is on the RAW pattern: `^abc` and `(?<!,)x` both strip to a literal
  in `noprefix` and must not be overridden.

### The duplicate initial state

The set-prefix skip first measured at zero gain on `(\w+)@(\w+)` and a loss
on `\bthe\b`, while a standalone `rfind_sets` sweep found all 1157 anchors
in 390 µs. Instrumenting the sweep: `skips=1 steps=261821 back_to_start=0`.
The reverse sweep never returned to its initial state, so the skip fired once
per haystack. Dumping states: the initial node was
`_*·(\w+·(@·\w+))`, but after `(_*\w+|\w*)@\w+` (mergeOrSuffix's shape)
lost its `\w*` branch the derivative interned `(_*·\w+)·(@·\w+)` — the same
language, a distinct node, a distinct state without the initial flag. Cause:
the concat-tail rewrite case ends in a plain registration without the
`(ab)c -> a(bc)` normalization, which RE# (and our port) only apply in the
final fall-through arm. Fix: `Build.concat_register` right-nests a concat
head before interning (a deviation from RE#'s code, listed under M1's
deviations; RE# likely carries the same latent duplicate — owed upstream
with a repro once reduced). With canonical concats the email pattern folds to
10 states instead of 11 and the sweep returns to its initial state after
every non-word symbol.

### Measurements (`tools/sharp-size/probe.sh`, 256 KB, `--opt=size`, ns per `find_all`)

| pattern | M4 step 0 | with accelerators | accelerator |
|---|---|---|---|
| `Holmes` | 3.5 M | 0.032 M | override (Teddy + memcmp) |
| `Sherlock\|Holmes\|…` | 1.8 M | 1.5 M | none yet (alternation: no single prefix) |
| `[A-Za-z]+` | 14.2 M | 8.5 M | none (byte-loop gains from unrelated cleanup) |
| `[0-9]{2,4}` | 4.8 M | 2.6 M | none |
| `\bthe\b` | 1.4 M | 0.56 M | prefix, 4 sets, anchor `h` |
| `\w+\s+\w+` | 12.2 M | 6.6 M | none |
| `(\w+)@(\w+)` | 4.0 M | 0.32 M | prefix, 3 sets, anchor `@` |
| `\p{L}+` | 15.4 M | 8.4 M | none |
| `.*Holmes` | 4.7 M | 1.2 M | prefix, 6 sets, anchor `H` |
| `_*cat_*&_*dog_*` | 18.4 M | 11.6 M | none (prefix inference stops at the `&`) |
| `~(_*\d\d_*)` | 18.8 M | 11.9 M | none |
| `a(?=.*b)` (incomplete) | 34.4 M | 26.8 M | none |

A/B at `--opt=speed` (`find_all` / starts-only, accel vs plain):
word_bound 0.49 / 0.41 ms vs 1.31 / 1.20; caps_email 0.31 / 0.17 vs
1.38 / 1.25; dotstar_lit 1.12 / 0.59 vs 2.12 / 1.60; literal 0.030 vs 1.2;
teddy_alt and two_words unchanged (no accelerator applies).

Not yet done from S13, in the order the table suggests: potential-start sets
for literal alternations (teddy_alt: RE#'s `CanSkip` startset over the union
of first sets, our Teddy as the kernel), `CanSkip` startsets for non-initial
states, the remaining `LengthLookup` variants (SetLookup / RemainingSets /
FixedLengthPrefixMatchEnd), and a forward-direction accelerator for the end
pass (the dense-class patterns spend their time in two full sweeps, which no
skip helps).

## M4 accelerators, stage 2 (2026-09-05): per-state skip sets, and the loop shapes

Built: RE#'s per-state startsets (`_createStartset` / `CanSkipFlag`,
`skip_active_rev`, the forward `CanSkip`). At `freeze`, every state of a
complete fold gets the set of minterms whose transition leaves it (for the
initial state also not to dead); when that set is neither empty nor full and
not too common, the state is skippable and the sweeps jump to the nearest
byte in it. The kernel is `Bset`: nibble-table byte-set membership
(`table_lookup` on lo/hi nibbles, 16 bytes per compare), forwards and
backwards; a non-ASCII byte always counts as a member so a skip stops at any
multibyte symbol and the automaton decodes it. `too_common` is RE#'s
`CommonalityScoreSimple` weight (lowercase and whitespace 20, else 10) over
the ASCII members, > 300 — RE#'s own test leans on .NET's `SearchValues`
kinds, so this is ours: `[a-z]` (520) and `\w` are too common, `[A-Z]`
(260), `\d` (100), `\s` and single letters are not.

Where it pays: `~(_*\d\d_*)` (both sweeps skip to digits), `[0-9]{2,4}`,
`.*Holmes`'s end pass (`.*` skips to `\n`/`H`), `Sherlock|Holmes|…` (the
initial state's set is the eight capitals — RE#'s potential-start set falls
out of the startset here). Where it does not: `_*cat_*&_*dog_*` skips to
`t`/`g`, which are frequent enough that a 16-byte window buys about what 10
table steps cost (RE# would skip here too, with 32-64-byte vectors).
Incomplete folds do not skip yet (RE# computes startsets lazily per state).

### Sorting the starts

An always-nullable pattern has a start at every position; sorting 262k
starts (`List.sort_with` with a closure) cost more than both sweeps. The
reverse sweep emits starts descending except where pending nullables resolve
out of order, so `Dfa.ascending` checks for descending order and reverses
with dedup in one pass, sorting only otherwise. `~(_*\d\d_*)`: 8.7 → 3.4 ms.

### The loop shapes (the biggest win of the milestone)

With the accelerators in, `[A-Za-z]+`'s reverse sweep still took 4.6 ms for
262k bytes — 18 ns a step for a table lookup — while a bare loop in a scratch
app doing the same lookups and appends took 0.9 ms. Bisected with local
copies of the loop (`revloop*.roc`):

1. **Per-call cost of the engine record.** `step_rev_fast(e, …)`,
   `is_null(e, …)`, `set_null_fast(e, …)` per step, and `end_fast(e, …)` per
   start, each pass `Dfa.E` (~27 lists). When the compiler does not inline
   the call, that is a record copy plus refcount traffic, ~100 ns. Binding
   `e.atable`/`e.st_nk`/… to locals before the loop and writing the step
   inline: reverse sweep 4.6 → 0.9 ms, end pass 4.9 → 0.5 ms.
2. **`List.fold` closures.** The end pass as a fold over the starts copied
   its captured environment per start: 8 ms for 262k starts. A `while` over
   an index in the same function: 0.5 ms.
3. **A Roc miscompile.** Mixing an inline `acc = List.append(acc, p)` with
   `acc = set_null_fast(e, s, acc, hay, p)` (which appends inside) in one
   `var` loop corrupted the heap — a store one past a list buffer's capacity,
   layout-dependent (adding unused functions to the app hid it), deterministic
   under Guard Malloc. Repro and notes in
   `upstream/2026-09-05-sharp-var-list-append/`; reduction owed. Every append
   in the loops is now inline; helpers return fresh lists.

The `has_skip`/prefix record hoisting from stage 1 was the same phenomenon
in miniature: a loop with the accelerator value merely in scope ran 36 ms.
Rule adopted: hot loops are one function, tables in locals, `while` not
fold, appends inline. `Sharp.find_all` on the 256 KB haystack is now
validated fast-vs-threaded under Guard Malloc for twelve patterns (`gm.roc`),
plus the corpus and the RE# differential.

### Measurements (`tools/sharp-size/probe.sh`, 256 KB, `--opt=size`, ns per `find_all`)

| pattern | stage 1 | stage 2 | existing `Regex` DFA |
|---|---|---|---|
| `Holmes` | 0.032 M | 0.118 M (0.027 at `--opt=speed`) | ~0.015 M |
| `Sherlock\|Holmes\|…` | 1.5 M | 1.28 M | ~2.3 M |
| `[A-Za-z]+` | 8.5 M | 2.82 M | ~3.0 M |
| `[0-9]{2,4}` | 2.6 M | 0.65 M | ~1.0 M |
| `\bthe\b` | 0.56 M | 0.45 M | ~1.0 M |
| `\w+\s+\w+` | 6.6 M | 2.58 M | ~2.5 M |
| `(\w+)@(\w+)` | 0.32 M | 0.19 M | ~1.0 M |
| `\p{L}+` | 8.4 M | 2.69 M | ~3.1 M |
| `.*Holmes` | 1.2 M | 0.22 M | ~1.3 M |
| `_*cat_*&_*dog_*` | 11.6 M | 2.40 M | — |
| `~(_*\d\d_*)` | 11.9 M | 1.97 M | — |
| `a(?=.*b)` (incomplete, threaded) | 26.8 M | 27.4 M | — |

A/B at `--opt=speed`, full / no per-state skips / no accelerators (ms):
class_plus 2.31 / 2.23 / 2.23; compl 1.40 / 2.13 / 2.13; bounded_num
0.54 / 0.97 / 0.99; dotstar_lit 0.18 / 0.35 / 0.84; teddy_alt 0.94 / 0.82 /
0.82; inter 1.94 / 1.94 / 1.94; word_bound 0.89 / 0.75 / 0.99 (the skip check
costs ~0.15 ms on this one with no skippable state — not yet understood).

Still owed from S13: the threaded (incomplete-fold) path has none of this;
`LengthLookup`'s `FixedLengthPrefixMatchEnd`/`SetLookup`/`RemainingSets`;
RE#'s potential-start sets beyond what the initial startset gives; 32-byte
kernels for the frequent-byte cases; the word_bound skip-check overhead.

## M4 accelerators, stage 3 (2026-09-05): length lookups, bench rows

Ported RE#'s `inferLengthLookup` for the forward end pass (`Accel.infer_len`,
`Dfa.Len`): `getFixedPrefixLength` walks the concat chain of the forward
pattern counting singleton symbols (`x{lo,hi}` contributes `lo` and leaves
`x{0,hi-lo}`; lookarounds and anchors are zero-length and drop out) and
returns what remains. Then, in RE#'s order: `RemainingSets` when the rest is
`[set]{0,m}` over one minterm (`[0-9]{2,4}`: two symbols, then up to two more
digits — no automaton at all); `SetLookup` when the rest has exactly one live
derivative, always nullable and a dead end (`t[^,]*,`: the match ends at the
first `,` after the prefix, found with the `Bset` kernel); otherwise
`PrefixEnd`: start the scan past the fixed prefix in the remainder's state.
The end pass dispatches on a hoisted `kind` byte; the prefix advance is
inlined (a `Utf8.advance` call per start cost more than the state it saved).

Two things learned the hard way:

- **Deviation, kept:** `SetLookup`'s inference ignores minterms that kill the
  remainder. RE# counts them as live derivatives, which on our alphabet rules
  the lookup out for every negated class (the `Invalid` symbol kills `[^,]`).
  Sound because a start recorded by the reverse sweep guarantees a match, so
  no killing symbol can precede the terminator.
- **Caught by the RE# differential:** with that change, RE#'s own second
  check — the continuation's derivatives, EXCLUDING those back to the
  remainder or itself, must be just `bot` — became unsound: `a.*c` gave
  `.*c|()` as the continuation, which steps back to `.*c` on most symbols, and
  the lookup stopped at the first `c` (RE# never reaches this case because
  `.` → `\n` → bot already disqualifies it). 3 of 3570 cases differed. The
  continuation must now be a true dead end: every minterm kills it.

Numbers (A/B, `--opt=speed`, 256 KB, ms): `[0-9]{2,4}` 0.53 → 0.385
(`RemainingSets`); `[A-Za-z]+` 2.23 → 2.17 and `\w+\s+\w+` unchanged
(`PrefixEnd` saves one transition per match, about what the advance costs);
`t[^,]*,` 0.372 with `SetLookup` against 0.80 with the state scan.

### `tools/bench` (generated 256 KB haystack, ns per `find_all`)

`examples/bench_sharp.roc` adds `sharp_*` rows; `run.sh` pairs them with the
`Regex` rows and checks both engines' match counts against Rust (all ten
agree — leftmost-first and leftmost-longest coincide on these patterns).

| pattern | Regex | Sharp | Rust meta | Sharp / meta |
|---|---|---|---|---|
| `Holmes` | 136 K | 120 K | 64 K | 1.9x |
| `Moriarty` | 22 K | 23 K | 9.6 K | 2.4x |
| `Sherlock\|Holmes\|…` | 1359 K | 1970 K | 421 K | 4.7x |
| `[A-Za-z]+` | 3423 K | 2478 K | 2403 K | 1.03x |
| `[0-9]{2,4}` | 156 K | 185 K | 108 K | 1.7x |
| `\bthe\b` | 333 K | 512 K | 204 K | 2.5x |
| `\w+\s+\w+` | 2396 K | 2634 K | 1530 K | 1.7x |
| `(\w+)@(\w+)` | 134 K | 165 K | 68 K | 2.4x |
| `\p{L}+` | 3395 K | 2544 K | 2039 K | 1.25x |
| `.*Holmes` | 532 K | 414 K | 646 K | 0.64x |

(The bench haystack is generated prose with a different letter mix from the
Sherlock text, so its absolute numbers differ from the probe's.) The
alternation is the outlier: RE# has no literal-set accelerator, so the sweep
skips only to the eight capitals; the existing engine runs Teddy over the
literals themselves.

## M4 accelerators, stage 4 (2026-09-05): set anchors, potential starts, frequency weights

- **Prefix anchors are byte sets now** (RE#'s `SearchValuesPrefix`), not only
  single ASCII codepoints: the rarest set is searched with the `Bset` kernel
  and a non-ASCII hit is verified against the set after `Utf8.sym_start`.
  `Rlit.rfind_sets` became one function of `while` loops that returns the
  occurrence's start and end; the recursive version passed the trie and
  prefix records per candidate and, on dense anchors, cost 5x the plain skip.
- **Potential-start sets** (`calcPotentialMatchStart`, `Potential` in
  `Dfa.Init`): the union of first sets over all live derivatives per depth;
  an occurrence only says a match may start there, so the sweep resumes at
  its end in the initial state (stepping once when the occurrence ends at
  the current position, as RE#'s `pos <> resultEnd`). Gated harder than RE#'s
  `useOnlyHead`: only when the anchor is not the first set and at least twice
  as rare as it — the initial state's own skip set already jumps to the first
  set with no verification.
- **Frequency weights replace RE#'s commonality.** RE# weights every
  lowercase letter 20 and everything else 10, which made `e` as good an
  anchor as `h` (`\bthe\b` went from 0.75 to 1.37 ms) and a set of six last
  letters "rarer" than the eight capitals (`Sherlock|Holmes|…` 4.4 ms). `Bset.freq2`
  is a rough English per-mille table; a set's weight is the sum and 2000 /
  weight the expected gap. `too_common` is weight > 160 (gap under ~12
  bytes): `[a-z]`, `\w`, `\s`, `e`, `t` are too common, `[A-Z]`, `\d`, `h`,
  punctuation are not. Consequences measured: the alternation's initial skip
  set (last letters `k s n r e`) is dropped, 0.94 → 0.85 ms; `_*cat_*&_*dog_*`
  no longer skips to `t`/`g`, unchanged.
- A set anchor on the first symbol is refused: it is the initial state's skip
  set plus verification and a landing (`[0-9]{2,4}` 0.385 → 0.457 with it).

A/B (`--opt=speed`, 256 KB, ms, full): word_bound 0.55 (starts 0.26),
caps_email 0.095, dotstar_lit 0.156, literal 0.027, bounded_num 0.368,
class_plus 2.25, two_words 2.0, compl 1.37, inter 2.1, set_lookup 0.37.
Corpus 331/331, RE# differential 3430/0, sixteen patterns fast-vs-threaded
under Guard Malloc.

S13 is complete in RE#'s terms except: skip sets on the threaded
(incomplete-fold) path, which RE# computes lazily per state, and `(?i)`
prefixes (`StringPrefixCaseIgnore`, not supported by the parser yet).

## Fuzz campaign (2026-09-05): `tools/sharp-fuzz`

`gen.py` grows random RE#-syntax patterns (depth ≤ 3: classes, `.`, `_`,
`\w\d\s\W`, `é`, quantifiers incl. `{m,n}`, groups, `|`, `&`, `~`, anchors,
`\b`, all four lookarounds) over fixed haystacks that include a two-byte
codepoint and an invalid byte, and emits a Roc runner that compiles each
pattern at runtime and compares `find_all`, `find_all_threaded`, an
eviction-forcing variant (`with_runtime_cap 6`) and the brute-force
reference. Seed 20260905, 1500 patterns, 12 haystacks.

- **Tier A, plain constructs** (`plain`: no anchors, `\b` or lookarounds):
  18000 cases, 0 rejected, 8 incomplete folds, **0 divergences** among the
  four engines. This is the plan's fuzz campaign against the reference.
- **Tier B, every construct against real RE#** (`resharp`, ASCII, through
  `tools/sharp-diff`'s harness): 1500 patterns, 677 rejected by us (RE#'s
  lookaround normal form), 9816 cases, 101 divergences in 9 pattern families,
  every one reduced to a minimal case on which RE# contradicts itself or
  leftmost-longest (below). 0 unexplained.
- **Every construct against the reference**: 158 divergences in 9 families,
  all anchors, negative lookbehinds at position 0, lookaheads with `&`, or
  `\b` after an optional — the corners where real RE# sides with our DFA and
  the reference is textbook (checked case by case with the harness). The
  reference interprets the shared node graph with textbook lookaround and
  anchor semantics; the derivative engine reproduces RE#'s, bugs included.

### Two real bugs the campaign found (fixed)

1. `SetLookup` inference: dropping killing minterms (stage 3's deviation) is
   only sound when the remainder is not nullable; `[^a]\n{2,}c?` ran to the
   end of input instead of stopping at the first non-`\n`. The fast path
   disagreed with the threaded scan, the reference and RE#.
2. `Rlit.rfind_sets` rejected an occurrence whose two-byte symbol after the
   anchor reached past the retry bound `p + after` (the bound is for the
   anchor search; the occurrence only has to end by the sweep position):
   `..?[ab]\w` on "abéb a" lost its match. Present since the first prefix
   accelerator; invisible on ASCII.

### RE# bugs confirmed with the .NET harness (owed upstream, kept for parity)

| RE# says | expected |
|---|---|
| `b?^` on "b" → 0-1; `a*^` on "xa" → 0-2; `b{0,2}^` on "bbc" → 0-3 (`a^` on "a" → none) | `^` cannot match at end of input after a non-empty loop |
| `b_{1,2}`, `b.{1,2}` on "aab ba" → 2-4, 4-6 (`b_{2}` → 2-5) | leftmost-longest: 2-5 |
| `[^a]&.\s\|\W*` on "abxb a" → 1-2, 2-3 …; `(?=a&b\|c)` on "abc" → 0-0 | `[^a]&.\s` is empty (RE# agrees alone: no matches), so the language is `\W*` |
| `(?<!a.)` on "abc" → 1-1, 2-2, 3-3; `(?<!a.,)` on "ab,c" → 3-3 included | position 0 has nothing behind it; "ab," precedes 3 |
| `(\n?)+(?<! )b+` on "a\nbb" → 0-4 | `(\n?)+` cannot match "a" |
| `(?<![^a][ab][ab]\d{0,2})` on "babaacab" → duplicate 2-2 | one span per position |
| `a?\b\s` on "a b  c,\n\nab" → 0-9 (`\b\s` → 1-2, 3-4) | 1-2, 3-4 |

Our DFA reproduces the first, third, fourth and last families (same node
graph and derivative semantics) and disagrees with RE# on the `{1,2}` and
`(\n?)+` ones, where it gives the expected answer. Whether to depart from
RE# on the reproduced ones is a decision for the owner: the RE# differential
would then need a known-divergence list, as the corpus already has.

## Dropping RE# parity on its confirmed bugs (2026-09-05)

Owner's decision after the fuzz campaign: the engine gives the textbook
answer where RE# is demonstrably wrong, and the RE# differential carries a
known-divergence list. Every fix below was located by tracing the engine's
own reverse sweep state by state (`trace2.roc`: `Dfa.step_end`/`Dfa.step`
with the node dumped structurally, Show being unreliable) and is marked
"Deviation from RE#" in the code. The brute-force reference is now the
arbiter for lookarounds and anchors too: **every construct, 9396 cases, 0
divergences** against it; plain constructs 18000 / 0; corpus 331/331; the
curated RE# differential 3430 agree / 0 differ / 16 known bugs; the RE# fuzz
tier 9480 cases / 0 unexplained / 149 RE# bugs (classified automatically:
RE# disagrees, the reference sides with us).

| # | RE#'s behaviour | root cause | fix |
|---|---|---|---|
| 1 | `a?\b\s` → 0-9, `\s*\bts\b` on "x ts" → 0-4: a mid-pattern lookbehind after a nullable expression swallows the text before the match | `mkConcatChecked` prepends `_*` to a left context of min length 0 before intersecting it with `_*R` | `Build.rewrite_at` rejects a nullable left context before a lookbehind, `\b` or `^`: the correct rewrite needs a lookbehind inside a union, which the forward pass cannot verify (RE#'s own reason for forbidding lookarounds in unions) |
| 2 | `_*\A` → 0-2, `x*(?<=a)b` accepts "xb" | `mkNodeWithoutLookbackPrefix` strips a lookbehind/anchor through an always-nullable head | `Deriv.without_lookback_prefix` strips only at the very start; the end pass checks Begin-nullability at position 0 (`ends_fast`, `ends_from`) |
| 3 | `b?(?!c&d)` on "b" → 0-0 | `HandleInputEndFwd` consults the End location only for anchor states without pending positions | `at_eoi`: End-nullable branches with nothing pending give the position itself; pending pairs of End-nullable branches give `pos - offset`; empty input uses the Begin+End location |
| 4 | `(?<!a.)` on "abc" → 1-1, 2-2, 3-3 (no 0-0, spurious 2-2) | pending positions materialize when a lookahead's body CAN be nullable (anchor-dependent bodies included) and are marked at every step; `HandleInputStart` reads the Center-location NullKind | `Dfa.pend_at`/`fresh_at`: pending pairs count only for branches nullable at the current location; state creation uses Center, input start Begin, input end End |
| 5 | `b^ ?\|.` on "b a" → 0-2 | `mkAnd2` folds `ε & X` to ε whenever X CAN be nullable | folds only for always-nullable X; otherwise the intersection stays and the location decides |
| 6 | `.[^a]{1,2}[ab]*(?!\w.{2}cb?)` on "abxb a" → 2-5, not 0-4 | `Or(LB·rest, rest)` → `(LB\|ε)·rest` → `LB{0,1}` → ε: a lookbehind whose body is nullable now (the reversed lookahead's running check) is treated as an optional assertion and dropped | `mk_or2`/`mk_or`: ε is not folded into a branch that carries a lookaround (its nullability is transient) |
| 7 | `(?<=[ab]\b)` → 4-4, 6-6 (should be 3-3, 6-6); `(?=(?<=\n))` one symbol off | a lookaround or `\b` nested in a lookaround body | rejected (`Conv.nested_look_msg`); no rewrite in RE#'s normal form expresses it |

RE# bugs we never reproduced (already the textbook answer): `b_{1,2}` not
extended to 2-5; `[^a]&.\s\|\W*` losing the `\s`; `(\n?)+(?<! )b+` → 0-4;
duplicate positions from `(?<![^a][ab][ab]\d{0,2})`.

Cost: `\s*\bword\b`-style patterns are now rejected (RE# accepts them and,
for a non-empty prefix, returns a match that swallows it). The corpus's one
such case expects the rejection (`KNOWN_RESHARP_DIVERGENCES` "REJECT").

Known-divergence lists: `tools/sharp-diff/gen.py` `KNOWN_RESHARP_BUGS`
(pattern, haystack, textbook answer or REJECT; outcome `KnownBug` when we
match it); `tools/sharp-corpus/gen.py` `KNOWN_RESHARP_DIVERGENCES` (now also
"REJECT"); the fuzz `resharp` tier classifies each RE# disagreement by asking
the reference and fails only when both disagree with us.

Performance is unchanged within noise (A/B after the changes: class_plus
2.17 ms, two_words 1.89, compl 1.49, bounded_num 0.40, caps_email 0.09).

## Three-way benchmark (2026-09-05): Sharp, Regex, Rust meta

`tools/bench/run.sh`, 256 KB generated haystack, ns per `find_all` over the
whole haystack, all ten rows agreeing on match counts.

| pattern | Regex | Sharp | Rust meta | Regex/meta | Sharp/meta | Sharp vs Regex |
|---|---|---|---|---|---|---|
| `Holmes` | 51650 | 45600 | 27102 | 1.91x | 1.68x | 1.13x faster |
| `Moriarty` | 11400 | 11050 | 10023 | 1.14x | 1.10x | 1.03x faster |
| `Sherlock\|Holmes\|…` | 1009050 | 934550 | 426359 | 2.37x | 2.19x | 1.08x faster |
| `[A-Za-z]+` | 3382900 | 2556000 | 2226193 | 1.52x | 1.15x | 1.32x faster |
| `[0-9]{2,4}` | 157150 | 193350 | 109584 | 1.43x | 1.76x | 1.23x slower |
| `\bthe\b` | 333500 | 357000 | 204681 | 1.63x | 1.74x | 1.07x slower |
| `\w+\s+\w+` | 2383800 | 2676050 | 1547382 | 1.54x | 1.73x | 1.12x slower |
| `(\w+)@(\w+)` | 133250 | 89100 | 69035 | 1.93x | 1.29x | 1.50x faster |
| `\p{L}+` | 3408300 | 2648000 | 2052761 | 1.66x | 1.29x | 1.29x faster |
| `.*Holmes` | 536200 | 372900 | 644486 | 0.83x | 0.58x | 1.44x faster |

Sharp is ahead on seven of ten and behind on three. Rust's PikeVM, the
engine-matched comparison from the original note, is 3.4 ms to 8.7 ms on
these patterns, so both Roc engines are an order of magnitude past it and the
lazy-DFA meta engine is the only meaningful target left.

The split follows the accelerators exactly. Sharp wins where the reverse
sweep can skip or the pattern reduces to a literal search: dense classes
(1.15x and 1.29x of Rust against Regex's 1.52x and 1.66x), the email pattern
with its `@` anchor, and `.*Holmes`, where both Roc engines beat Rust because
a leading `.*` denies its prefilter a start anchor while our reverse sweep
finds the literal directly. Sharp loses on the three patterns where nothing
skips and RE#'s design pays its structural cost of two passes over every
byte: `\w+\s+\w+` has no accelerator at all, and `[0-9]{2,4}` and `\bthe\b`
skip on only one state each. Those three are also the patterns Regex was
tuned on most recently (its inline-start and hard-separator end-scan work),
so the comparison there is against a well-optimized forward scan.

### Harness fix

`run.sh` ran each binary exactly once, immediately after building it. A
freshly built binary reads about 80% slow on its first execution: repeated
runs of the same `bench_sharp` gave 87050, 49800, 49350, 46450 ns for
`Holmes`. Every fast-pattern row in earlier three-way runs was inflated by
that. The harness now discards a warmup run and takes the per-pattern
minimum of five, as `probe.sh` already did inside one process. Numbers above
reproduce across runs to within 2%.

Roc's `--opt=speed` is the build default, so the harness was always
optimizing; an explicit flag changes nothing.

## Per-pattern artifact size (2026-09-05): `tools/sharp-size/breakdown.sh`

`probe.sh` reports whole-binary bytes, which conflates the platform, the engine
code and the pattern's own data. The new tool separates them: it reads the
Mach-O section table for code and constant data, diffs both against a baseline
binary, and prints the engine's own folded structures summed from their element
counts and widths. `--opt=size`, 256 KB haystack.

| pattern | binary | d_binary | d_const | d_code | tables | trie | nodes | states |
|---|---|---|---|---|---|---|---|---|
| `a+` baseline | 741776 | 0 | 0 | 0 | 3216 | 20004 | 772 | 5 |
| `Holmes` | 409200 | -332576 | -84928 | -224088 | 9216 | 20116 | 2782 | 15 |
| `Sherlock\|Holmes\|…` | 889424 | +147648 | +152080 | -3320 | 48720 | 20396 | 8231 | 69 |
| `[A-Za-z]+` | 725264 | -16512 | -8 | -3516 | 3216 | 20020 | 772 | 5 |
| `[0-9]{2,4}` | 741712 | -64 | +3000 | -4452 | 5360 | 20004 | 936 | 9 |
| `\bthe\b` | 1250720 | +508944 | +490208 | +1276 | 7384 | 220340 | 2584 | 12 |
| `\w+\s+\w+` | 1217744 | +475968 | +480384 | -4348 | 5440 | 220268 | 1380 | 9 |
| `(\w+)@(\w+)` | 1217888 | +476112 | +479720 | +2820 | 5440 | 220132 | 1261 | 9 |
| `\p{L}+` | 1184912 | +443136 | +428384 | -3480 | 3216 | 201828 | 772 | 5 |
| `.*Holmes` | 791104 | +49328 | +44944 | +5300 | 12264 | 20140 | 4976 | 20 |
| `_*cat_*&_*dog_*` | 807440 | +65664 | +55216 | -408 | 14400 | 20116 | 3755 | 24 |
| `~(_*\d\d_*)` | 889520 | +147744 | +147952 | +4 | 3216 | 88708 | 1093 | 5 |
| `a(?=.*b)` incomplete | 1714000 | +972224 | +349712 | +611160 | 41000 | 20044 | 43114 | 1024 |

Four things the split shows that the total could not.

**Code is paid once.** `d_code` is within about 5 KB for every complete fold,
so the roughly 225 KB of scanning engine is a fixed cost and everything
per-pattern is data. The exception is the incomplete fold, which keeps the
threaded scan, the derivative machinery and the arena constructors: 611 KB of
extra code on top of its 350 KB of tables.

**A pure literal is cheaper than the baseline.** `Holmes` comes in 332 KB
BELOW a minimal DFA pattern, because the literal override never touches the
transition tables and the whole scanning path is eliminated. Any measurement
that uses a literal as its baseline is therefore wrong, which is how the first
version of this tool produced a table of identical numbers.

**Unicode class data dominates everything else.** Adding `\w` costs about 490
KB where its derived trie accounts for 200 KB of that. The residue is chased
below; the guess recorded here first, that it was `Uni`'s source range tables
being retained, was wrong.

**Transition tables are small.** The largest complete fold here is the
alternation at 48 KB across 69 states. Tables only become a term at all in the
1024-state incomplete fold.

### Measuring this at all requires the data to be live

An app that only asks for `List.len` of the folded lists gets constant-folded
answers and the data is dropped, so every binary comes out byte-identical. The
tool therefore scans a real runtime haystack, as `probe.sh` does. That is also
a clean demonstration that the fold is genuine and dead-code-eliminated.

## Correction: the artifact overhead is not retained `Uni` tables (2026-09-05)

The size breakdown above noted that a Unicode class costs about 2.4x its
derived trie and guessed the excess was `Uni`'s source ranges surviving the
fold. That guess was wrong, and the entry has been corrected.

`Uni` stores its tables as hex strings decoded at parse time. All sixteen of
them total 62328 bytes, and `w_hex` is 9552. That cannot account for 274016
bytes, and the excess scales with the trie rather than being a fixed addend:
`\d+` adds 68728 bytes of table and 76904 of excess, `\w+` adds 200096 and
274016.

What is actually happening, measured on `[A-Za-z]+` against `\w+`, which
differ only in that class:

| section | `[A-Za-z]+` | `\w+` | delta |
|---|---|---|---|
| `__TEXT,__const` | 43504 | 243600 | +200096 |
| `__DATA_CONST,__const` | 62224 | 336240 | +274016 |
| `__TEXT,__text` | 442012 | 443056 | +1044 |

The `__TEXT,__const` delta is exactly the trie's 50024 `U32` elements times
four, to the byte, which also confirms the tool's logical formula. The
`__DATA_CONST,__const` delta then sits on top of that, and the two sections
overlap in content: of 52 blocks of `__TEXT,__const` carrying at least 24
distinct byte values, so that a coincidental match on repetitive class indices
is excluded, 14 appear verbatim in `__DATA_CONST,__const`.

A control isolates this from the engine. A folded bare `List(U32)` of 50000
elements costs exactly 4 bytes per element, all in `__DATA_CONST,__const` and
none in `__TEXT,__const`, and wrapping it in a record or nesting it two deep
changes nothing. So a simple folded list is stored once at its data size in one
section, while the folded regex is stored across both at about 2.2x.

What in the larger structure triggers the second copy is not established. It is
a Roc codegen question rather than an engine one, so it is recorded as a
reproducer in `upstream/2026-09-05-sharp-folded-constant-sections/` with the
four apps and the section tables. The earlier claim that roughly 200 KB per
Unicode pattern is recoverable stands as a rough size for the prize, but only
upstream can collect it.

## Narrowing the class trie (2026-09-05)

`Trie.build` rejects any pattern needing more than 63 minterms, so a class id
never reaches 64, yet `ascii`, `leaves` and `mt_of_atom` all stored ids as
`U32`. Four bytes to hold a value under 64, and `leaves` was 86% of the trie
for `\w`. Three changes:

- class ids are `U8` in `ascii`, `leaves` and `mt_of_atom`, and `l1` is `U16`,
  since a block index cannot exceed 4352;
- leaves `0..n_classes-1` are the constant blocks, one per minterm, and every
  block that is entirely one minterm points at its constant leaf rather than
  getting a copy. For `\w` only 131 of 4352 blocks contain a boundary;
- adjacent identical mixed blocks are still shared, as before.

| pattern | trie before | trie after | binary before | binary after |
|---|---|---|---|---|
| `a+` baseline | 20004 | 9883 | 741776 | 725360 |
| `[A-Za-z]+` | 20020 | 9893 | 725264 | 725264 |
| `[0-9]{2,4}` | 20004 | 9883 | 741712 | 725296 |
| `\bthe\b` | 220340 | 52289 | 1250720 | 823904 |
| `\w+\s+\w+` | 220268 | 51467 | 1217744 | 823760 |
| `(\w+)@(\w+)` | 220132 | 51382 | 1217888 | 823904 |
| `\p{L}+` | 201828 | 47619 | 1184912 | 790928 |
| `~(_*\d\d_*)` | 88708 | 21591 | 889520 | 758192 |

A Unicode pattern's binary drops about a third, 427 KB on `\bthe\b`. Speed is
neutral: on the bench set every row is within 0.94x to 1.08x on ASCII text and
0.96x to 1.03x on 262 KB of mixed Greek, Cyrillic, CJK and Latin-1.

### `class_of` has to stay two reads, no loop and no call

The obvious further step is to drop `leaves` entirely. `cuts` and
`mt_of_atom` are already stored, for printing, and together they ARE the
codepoint map, so a search over them answers any lookup. That was built and
measured: the trie fell to 16801 bytes for `\w`, a 13x reduction, and the
whole bench set ran 1.5x to 1.6x slower on non-ASCII text.

Isolating `class_of` in a loop over 262 KB of mixed-script text, per lookup:

| variant | ns per pass | note |
|---|---|---|
| original, two reads | 1344000 | inlined |
| search over `cuts` | 2705000 | loop in the function |
| search, single-atom case inlined | 3147000 | no better |
| uniform bit, then search | 1860000 | one extra branch |
| the same lookup written in the caller | 1365000 | data layout is fine |

Two separate causes, separated by writing each lookup inline in the caller so
that no call boundary exists, then comparing the same lookup inline against
called. Same haystack, same checksum from all of them:

| variant | ns per pass |
|---|---|
| shipped two-read lookup, inline in caller | 1397000 |
| cut-point binary search, inline in caller | 2750000 |
| shipped lookup, called as `Trie.class_of` | 2093000 |
| old lookup, called as `Trie.class_of` | 1342000 |

- **The search really does more work**: +1353000 between the two inline
  probes, about 13.7 ns per lookup, with no call involved.
- **Inlining is separately lost**: +696000 for the identical lookup once it
  sits behind `Trie.class_of`, about 7.1 ns per lookup. The old lookup called
  through the package matches the inline baseline, so it was being inlined and
  the new one is not.

The version that regressed 1.5x narrowed its search to one block with `l1`,
so its +1363000 splits roughly half into call overhead and half into search
steps. It was not predominantly an inlining artifact, which an earlier draft
of this entry claimed.

The shipped design still pays the 7 ns of call overhead. That does not appear
end to end, where non-ASCII text measures 0.96x to 1.03x, which reads as the
4x smaller tables repaying it in cache pressure the micro-benchmark cannot
see. The inlining boundary itself is the same one recorded under M4 stage 2
for the scan loops.

So the shipped design keeps the original two-read shape exactly and takes its
size from the element widths and the shared constant leaves. The cut-search
version is smaller and remains available if a future workload is known to be
ASCII-only, but it is not worth 1.6x on Unicode text.

### A stale node-layer expectation

The node tests were not re-run after the RE#-parity change, and one case had
been failing since: `^a*b` derived by `a` now prints `(ε|_*^)a*b` rather than
`(_*^)?a*b`, because `ε | X` no longer folds when X carries a lookaround. The
test accepts a list of spellings and this one was added. Nothing else moved,
and 57/57 pass again.

## Narrowing the DFA tables (2026-09-06)

`atable`, the fused ASCII byte-to-state table, is built only when the fold is
complete, and a complete fold is capped at `Sharp.fold_state_cap` = 1024
states, so a state id there fits a `U16`. `st_minpend` holds a symbol offset
that `Arena.ps` already bounds to 16 bits. Both narrowed; every reader widens
back on the way out.

| pattern | tables before | tables after | binary before | binary after |
|---|---|---|---|---|
| `Sherlock\|Holmes\|…` | 48720 | 30800 | 873008 | 840224 |
| `_*cat_*&_*dog_*` | 14400 | 8000 | 774608 | 741824 |
| `.*Holmes` | 12264 | 6888 | 774688 | 774736 |
| `Holmes` | 9216 | 5120 | 409200 | 409200 |
| `\bthe\b` | 7384 | 4056 | 823904 | 823904 |
| `\w+\s+\w+` | 5440 | 2880 | 823760 | 807392 |
| `a+` baseline | 3216 | 1680 | 725360 | 725408 |
| `a(?=.*b)` incomplete | 41000 | 41000 | 1730416 | 1681168 |

The tables halve as expected. The binary follows only where the saving clears
the file's roughly 16 KB granularity, so the alternation and the intersection
drop about 33 KB each while several rows show no change at all. The
incomplete fold keeps its 41000 bytes of tables, because it has no `atable`
at all, but still drops 49 KB from the narrower `st_minpend` and the code that
goes with it. Speed is unchanged: 0.87x to 1.02x across the bench set.

**`table` and `end_table` are deliberately left at `U32`.** They are read by
the extensible path, which mints states at scan time up to `runtime_cap`,
RE#'s 100000 default. Narrowing them means lowering that cap below 65535,
which is a documented budget under S4 and S12 rather than a representation
detail, so it is a decision for the owner and not taken here. The prize is
`a(?=.*b)`'s 41000 bytes halving, and nothing on any complete fold, where
these two tables are already small next to `atable`.

## The anchored end finders on the DFA (2026-09-06)

`first_end` and `longest_end` ran on `Ref.ends_at_start`, the brute-force
interpreter -- correct, and oracles rather than fast paths. H3 of
`plans/2026-09-06-http-parse.md` makes them the parse primitive for a caller
stepping pieces of its own buffer, so they move to the frozen DFA
(`Dfa.ends_at_start_fast`, one pass returning both bounds). The interpreter
stays as the oracle and as the path for an incomplete fold.

**The start state is not `s_noprefix`, and it is not the root either.** The
forward pass of a search runs the prefix-free pattern because the reverse sweep
has already verified the lookbehind prefix at that start. An anchored match has
had no sweep, so `s_noprefix` would accept a prefix that does not hold:
`(?<=ab)cd` anchored at 0 of "cdef" is not a match, and `s_noprefix` is `cd`,
which matches. Starting from the root instead is worse, because a lookbehind
derivative walks its body FORWARD (`Deriv.derivative`, `k_lookbehind`): the root
matched "abcd" at 0 and reported 4.

The prefix has to be RESOLVED against offset 0, which is what
`Deriv.at_input_start` does -- the mirror of `without_lookback_prefix`, sharing
its shape and its one deviation (it does not resolve through a merely nullable
head; a prefix after one is judged at its position by the forward pass, as in a
search). At offset 0 a lookbehind holds exactly when its body matches the empty
string there, `\A` holds always, and `\z` is left to the end-of-input handler.
An unsatisfiable prefix resolves to `bot`, which is already the dead state, so
that pattern costs no state at all; for everything without a leading lookbehind
the resolved node is the interned root and `get_state` returns the existing
state. Only a satisfiable leading lookbehind mints one more.

**Both bounds in one pass.** `first_end` is the smallest end and `longest_end`
the largest, so the loop tracks both and the two entry points share it. Two
places needed a second reading of the pending-nullable set, which
`ends_fast` reads only for the largest end:

- in the loop, a pending state's largest end retreats by the SMALLEST pending
  offset (`st_minpend`); the smallest end needs the largest (`pend_max_off`).
- at end of input, `at_eoi_fast` folds the pending pairs with `max_end` over
  each pair's `ps`; the smallest end needs `pe` (`at_eoi_bounds`).

The second one was found by the fuzz, not by inspection: `~(_,\w[^ab])+$` on
"cab ab\xff\n" ends at 7 (before the newline, where `$` holds) and at 8, and
the single-value handler reported 8 for `first_end`. The first was written
correctly only because the second showed what to look for.

RE#'s `CanSkip` is not used here. Skipping jumps to the LAST position a state
loops on, which is right for the largest end and steps over the smallest.

### RE#'s own FirstEnd/LongestEnd disagree, and the reference is the arbiter

Both call `end_first`/`end_lazy` with `DFA_R_NOPR` (`Regex.fs:1149`, `:1157`) --
the noprefix state. So RE# implements them the way `s_noprefix` would: it
strips the prefix and leaves verifying it to the caller. `(?<=b)a` anchored at
0 of "a" is 1 for RE# and no match for us.

The differential now calls both APIs and classifies this: a disagreement where
the structural reference sides with us is `PrefixDiff`, anything else is a
failure. 3587 cases: `find_all` differ=0, ends differ=0, prefix_diff=211. This
follows "Dropping RE# parity on its confirmed bugs" above -- the reference is
the arbiter -- and the semantics a caller stepping its own buffer needs.

### Gates

Corpus 331/331, node layer 57/57, fuzz plain (1500 patterns, 18000 cases,
`first_end`/`longest_end` against the reference on every one) 0 divergences.

A new full-construct fuzz seed (1500 patterns, seed 42, 9336 cases) reports 16
divergences, **identical before and after this change** and none of them in the
ends: four patterns, all the family the log's "Dropping RE# parity" section
names as rejected -- a nullable expression before a line anchor
(`[^a]\n{0,2}^^`, `\n^^.&[^a]a`, `a\W{0,2}.*(?=^)`, and one `$` alternation).
The rejection rule does not catch them. Pre-existing and out of scope here;
recorded so the next seed does not read as a regression.

## `(?i)`, and a fold table that only worked one way (2026-09-06)

M2 of `plans/2026-09-06-http-parse.md` is `(?i)`, needed because HTTP header
names are case-insensitive and normalizing the buffer would copy it, which the
slice-based parse cannot afford. Most of it was already there: `Ast.parse`
handles a leading `(?i)` (`starts_ci`), `group_head`/`read_flags` handle a
scoped `(?i:...)`, and `fold_ast` expands `Chars` nodes. The README's "No
`(?i)`" was stale. Three real defects behind it:

**The fold table is one-directional.** `Uni.fold_hex`, generated from
regex-syntax 0.8, has 1735 ordered pairs in which 153 codepoints appear only as
a target. `k` and `K` both list the Kelvin sign U+212A; U+212A lists neither. So
`(?i)k` matched U+212A and `(?i)\u{212a}` matched nothing -- in BOTH engines,
since `Regex` reads the same table. Fixed by shipping the symmetric-transitive
closure of the generated pairs: 1890 pairs, 155 added, max orbit 4. Symmetry
alone gets 1888; the last two (U+A64A/U+A64B, linked only through U+1C88) need
transitivity. Every pair in the closure agrees with Unicode simple case folding
in both directions, checked against Python's `casefold` -- and nothing Python
calls equal is missing from it. `Regex` still runs 1546/1546 against the Rust
crate afterwards.

**`fold_ranges` skipped any range wider than 1024 codepoints.** It looked up
partners one codepoint at a time, so a wide class was unaffordable and silently
went unfolded: `(?i)[a-\u{525}]` did not match a Kelvin sign. `Regex` had
already moved to one pass over the orbit table per range
(`Uni.fold_partners_in`); `package-sharp`'s copy of `Uni` had not been updated
with it. Both copies now carry `fold_pairs` and `fold_partners_in`, and the
1024 guard and `fold_range_members` are gone.

**Unimplemented inline flags were skipped, not rejected.** `read_flags` walked
past any letter it did not know, so `(?s:.)` compiled as `(?:.)` and `(?U:a+)`
as `(?:a+)` -- the same silent-wrong-meaning defect the 2026-09-05 review fixed
in `Regex`. They are `FlagUnsupported` parse errors now. A bare mid-pattern
`(?i)` was already an error, and stays one.

### RE# disagrees on `(?i)` twice, and both times .NET is the odd one out

The differential grew 19 `(?i)` patterns and 9 haystacks. Nine rows differ, in
two families, both recorded in `KNOWN_CI_DIVERGENCES` with the textbook answer
derived from Python's `re.IGNORECASE` rather than copied from our output:

- **.NET's IgnoreCase is not simple case folding.** It does not equate U+017F
  LATIN SMALL LETTER LONG S with `s`/`S`, so `(?i)s` on "\u017f" is no match
  for RE# and a match for us, Rust, `Regex` and Python. Same family as the
  Unicode exclusion the harness header already states.
- **.NET leaks a scoped `(?i:...)` to the whole pattern.** `a(?i:bc)` matched
  "ABC" for RE#, where the `a` is outside the group.

### Gates

`Regex` 1546/1546 vs the Rust crate; smoke 28/28; RE# corpus 331/331; node
layer 57/57; fuzz plain 18000 cases 0 divergences; fuzz seed 42 16 divergences
(the pre-existing anchor family, unchanged); RE# differential agree=5139
differ=0 of 5341, ends differ=0 prefix_diff=261.

## HTTP parsing on the engine, and where it goes (2026-09-06)

M3 and M4 of `plans/2026-09-06-http-parse.md`. `package-http` frames HTTP/1.1
requests and routes them with matchit 0.8 syntax, using only `Sharp`'s public
API: `longest_end` per piece over a slice of the caller's buffer, `find` for
the `\r\n\r\n` terminator and for a header line, and one anchored selection
pattern per route.

### The claim the plan set out to test does not hold

`tools/http-bench/run.sh`: 1000 generated requests (8-15 headers each, 328 KB),
against Rust `httparse` + `matchit` doing the identical task -- frame the
request, select the route and bind its parameters, read three named headers.
Both sides print a checksum summing every piece's length plus the matched
route's index; they agree at 51584, so the comparison is of the same work. Min
of five runs, ns per request:

| stage | ns/req | share |
|---|---|---|
| split the fixture into requests | 7.7 | 0% |
| + frame (method, target, version, header-block extent) | 1300 | 12% |
| + select the route and bind parameters | 7661 | 60% |
| + three header lookups (the full task) | 10543 | 27% |
| `httparse` + `matchit`, same task | 386 | |

**27.3x slower than the hand-written parser.** The premise of H1 was that a
tuned matcher beats most hand-written parsers; against the strongest one it
does not, and the plan asked for this number rather than an estimate.

### Where it goes: per-call overhead, not scanning

Routing is 60% of a request. The table holds 27 entries (9 routes x 3
methods); the method comparison short-circuits, so ~9 anchored matches run per
request, at about **707 ns each for a path of ~20 bytes**. The engine scans
prose at roughly 8 ns/byte, so a 20-byte path is ~160 ns of scanning and the
rest is fixed cost per call. This is the `caps_email` shape from the earlier
entry -- per-candidate overhead, not scan length -- and it is exactly H4's
stated reopen condition ("pattern IDs if M4 shows per-call overhead
dominating"). matchit does 130 routes in 2.4 us; we do 9 in 6.4 us.

What did help, and is shipped: `Route.matches` used `Sharp.is_match`, which
runs the reverse sweep first. The selection pattern is anchored `\A..\z`, so a
match exists exactly when `longest_end` is the whole path -- one forward pass,
no sweep, no candidate list. Routing went from 7663 to 6361 ns/req and the
total from 12508 to 10543, checksum unchanged.

The two reopens H4 named are both now justified by measurement rather than
speculation, and neither is implemented: they are design changes for the owner
to call. A radix trie for selection would remove the per-route call entirely;
pattern IDs would make it one automaton pass. The other 40% (framing 12%,
header lookups 27%) is the same per-call cost spread over four `find` /
`longest_end` calls per request, so it moves with any fix to the same thing.

### Blocked: H6's artifact measurement

`tools/sharp-size/breakdown.sh` builds with `--no-cache`, and an app importing
both `Http` and `Route` panics the compiler on that path (either module alone
is fine). Reduced to a six-file reproducer in
`upstream/2026-09-06-two-modules-folded-constant/`; the minimal form needs no
regex package at all. Per [[compiler-instability-not-a-design-input]] the
module layout is not being changed around it. `examples/http.roc` and the
benchmark app both build on the cached path, so only the size number is lost.

## The radix trie for route selection (2026-09-06)

H4's reopen, taken by the owner after M4 measured route selection at 60% of a
request. `package-http/Rtrie` is a port of matchit 0.8's radix trie: static
edges share prefixes and split on insert, a parameter edge consumes to the next
`/`, a catch-all to the end, and at every node a static child is tried before
the parameter child and that before the catch-all, backtracking into the next
kind when a deeper match fails. Nodes are parallel flat lists indexed by node
id, as `Dfa.E` and `Arena.A` are.

One descent answers selection AND binds the parameters, so the second pass that
stepped the pieces with `[^/]+` is gone too, and with it the whole selection
pattern: `Route` is now the route SYNTAX only and does not import `Sharp`. The
regex engine has left routing entirely.

### The measurement

`tools/http-bench/run.sh`, same fixture, same task, checksums still agreeing at
51584:

| stage | anchored DFA per route | radix trie |
|---|---|---|
| split | 7.7 | 7.2 |
| + frame | 1298.5 | 1309.0 |
| + route | 7669.9 | **1914.5** |
| + three header lookups | 10552.0 | **4617.1** |
| `httparse` + `matchit` | 386.9 | 387.8 |
| ratio | 27.3x | **11.9x** |

Route selection went from 6361 to 606 ns per request, **10.5x**, and the whole
parse from 27.3x off `httparse` to 11.9x. What remains is 1302 ns of framing
and 2703 ns for three header lookups (~900 ns each), both still the engine's
per-call cost on short inputs -- the same fixed overhead the routing pass was
paying nine times.

### Checked against the original, not just against itself

`tools/route-diff` builds the same table in real matchit and compares the
matched route and its bound parameters path by path: **174/174 agree**,
first run, including the radix splits (`/he` vs `/health` vs `/healthz`), the
backtrack out of a static into a parameter (`/users/health`), and the
suffix-in-segment case (`/images/img{id}.png` on "imga.b.png" binds "a.b").
`examples/http.roc` is 56/56 with seven cases added for the descent.

Two behaviours changed and are now matchit's rather than ours: conflicts are
detected structurally (a route ending where one already does, or a parameter
edge with a different name) instead of by comparing sorted shape keys, and
`Allow` lists methods in declaration order again, since nothing sorts the table.

### H6, unblocked and answered

Removing `Sharp` from `Route` left `Http` as the only module holding folded
matchers, so the two-module compiler panic no longer fires for
`examples/http.roc` and `--no-cache` builds work. That is a consequence of the
design change, not a workaround: the bug is unaffected and
`upstream/2026-09-06-two-modules-folded-constant/` still reproduces it.

The artifact number H6 wanted, from the constant sections of `--no-cache`
builds with live (argv-derived) data, 1 route against 11:

| app | `__TEXT,__const` + `__DATA_CONST,__const` | per extra route |
|---|---|---|
| routing only | 24536 -> 27776 | **324 B** |
| routing + framing engine | 213832 -> 234640 | **2081 B** |

Against H6's estimate of ~30 KB per pattern, a route is one to two orders of
magnitude cheaper, because there is no per-route automaton left to store. The
estimate still holds for the FRAMING matchers: `Http`'s five folded automata
plus the engine account for the 189 KB gap between the two rows. So the
ASCII-only trie that H6 named as its lever is still the thing to reach for, but
for framing, not for the route table. Why the same table costs 324 B alone and
2081 B beside the engine is unexplained; it is the same folded-constant
double-storage question already recorded above as owed upstream.

## Per-call cost on short inputs, and a literal that was not one (2026-09-06)

The owner asked for the framing and header overhead measured in the trie entry.
Every number below is from a haystack of a few hundred bytes, which is the
regime this engine had never been profiled in: everything it does once per call
is invisible against 256 KB and dominant against 280 bytes.

**What it was not.** Three plausible causes were measured and cleared before the
real one was found, which is the only reason it was found:

- `List.sublist` **is free** (0 ns). H2's "seamless slices" premise holds; the
  parse was not copying its buffer.
- Passing `Sharp.T` across a call boundary is **free** (0 ns for a function that
  takes it and reads one scalar). The record-passing cost the hot-loop notes
  warn about does not apply here.
- The literal scan's prologue (`List.repeat`/`concat`/`take_first` to pad the
  literal to a vector, three allocations per call) is real but small: hoisting
  it into `Accel` changed 770 ns to 770 ns.

**What it was.** `Sharp.find("\r\n\r\n")` cost ~780 ns and was **flat from 4
bytes to 1004** — no scanning component at all. The kernel it should reach,
`Dfa.first_literal`, is 22 ns. The pattern was not taking the literal path:
`accel_str` reported `len=any override=none`.

`Build.loop_register` computed a loop's min/max length only when the body was a
SINGLETON. The rewrites fold a doubled literal into exactly that shape, so
`\r\n\r\n` becomes `(\r\n){2}` and reported no fixed length, which denied it
`Accel`'s literal override and sent an HTTP terminator search through the whole
reverse sweep. The rule is general — a repetition of a fixed-length body is
fixed-length, `lo * body` — and so was the hole: `abab`, `aaaa`, `xyxy`,
`(?:ab){2}` and `(?:abc){3}` were all in it, while `abcd`, `abba` and `abcabc`
were fine. Capped so a large `{n,m}` cannot overflow into the `none` sentinel.

Two smaller changes went with it, both the same rule as
`Regex.verify_candidates`: `Sharp.find` and `is_match` dispatch the literal
override themselves instead of reaching the kernel through `find_first_fast` ->
`find_all_fast_opts`, and `Dfa.first_literal` stops at the first hit instead of
collecting every span and taking the head.

| | before | after |
|---|---|---|
| `Sharp.find` of `\r\n\r\n`, 280 B | 787 ns | **63 ns** |
| `Http.frame`, 280 B request | 1209 ns | **566 ns** |

### The benchmark

| stage | regex selection | radix trie | + these fixes |
|---|---|---|---|
| + frame | 1298.5 | 1309.0 | **735.9** |
| + route | 7669.9 | 1914.5 | 1335.8 |
| + three header lookups | 10552.0 | 4617.1 | **4107.1** |
| ratio to `httparse` | 27.3x | 11.9x | **10.2x** |

### What is left, and the decision it needs

Headers are now **67%** of a parse: 2771 ns for three lookups, ~920 each.
`(?i)^content-length:[ \t]*` is genuinely not a literal, so none of the above
touches it, and its `find` is ~560 ns fixed plus 0.6 ns/byte — setup again,
in the non-literal path's own prologues (`ends_fast` alone destructures the
`Dfa.Len` tag seven times before it looks at a byte).

Four hypotheses for that 560 ns were measured and rejected, so it is genuinely
not yet located: `List.sublist`, passing `Sharp.T`, the literal prologue's
allocations (all above), and the six extra `Dfa.Len` destructures in
`ends_fast`'s prologue — skipping the five that `MatchEnd` does not need moved
620 ns to 607, inside the noise, and was reverted. What remains unexamined is
`starts_fast_opts` and the body of `ends_fast`; a probe calling them directly
from an app crashed (exit 138), which is itself worth reducing before the next
attempt.

The cheaper shape is measured and available: one `find_all` of `\r\n` over the
header block costs ~80 ns plus 0.6 ns/byte — about 250 ns for a 280-byte block
— and yields every line boundary, after which matching a known header name is a
byte compare. Three lookups would go from ~2770 ns to ~300.

That is **H2's lazy-versus-eager decision**, not an optimisation: H2 chose
"pull a header on demand" over "materialize all headers up front" on the
reasoning that materializing was the expensive one, and this measurement says
the opposite by an order of magnitude. It is the owner's call, so it is
recorded here rather than taken.

### Gates

RE# corpus 331/331, node layer 57/57, fuzz plain 18000 cases 0 divergences,
fuzz seed 42 16 divergences (the pre-existing anchor family, unchanged), RE#
differential agree=5139 differ=0 of 5341 with ends differ=0, `examples/http.roc`
56/56, router differential 174/174 against matchit.

## Eager headers (2026-09-06)

The owner took the decision the previous entry recorded: `Http.frame` parses
every header in the same pass, and `header` is a lookup rather than a search.

Framing no longer searches for the terminator separately either. One `find_all`
of `\r\n` over the buffer locates the request line's end, every header line's
end, AND the blank line that ends the block, so the `find` of `\r\n\r\n` is
gone: one SIMD literal pass does what a search plus a search per header did.

| stage (cumulative) | lazy headers | eager |
|---|---|---|
| split | 8.2 | 7.8 |
| + frame | 735.9 | 1459.2 |
| + route | 1335.8 | 2128.3 |
| + three header lookups | 4107.1 | **2236.7** |
| `httparse` + `matchit` | 402.6 | 404.6 |
| ratio | 10.2x | **5.5x** |

Framing absorbs the header parsing and roughly doubles, 736 -> 1459; the three
lookups fall from 2771 to **89** — about 30 ns each against ~920. The stage
split now reads differently, which the harness says on its own header.

Two things inside the lookup were worth more than the search they replaced:

- `List.find_first` over the fields cost a closure per header. An indexed
  `while` took three lookups from 423 ns to 89. This is the fold-closure cost
  the hot-loop notes describe, in a loop of eleven elements.
- `Http.header` takes a `Str`, and `Str.to_utf8` allocates on every call.
  `header_bytes` takes the name already as bytes, which a top-level literal
  folds into the artifact — that is what a server holds for the headers it
  reads on every request.

`colon_at` and `eq_ci_at` became `while` loops rather than per-byte recursion,
worth about 1%: kept for the idiom, not for the number.

### What the whole exercise moved

| | ns/request | vs `httparse` |
|---|---|---|
| M4, as first measured | 10552 | 27.3x |
| radix trie for selection | 4617 | 11.9x |
| the doubled-literal override fix | 4107 | 10.2x |
| eager headers | **2237** | **5.5x** |

Framing is now 65% of a parse and route selection 30%. The ~560 ns of unlocated
fixed cost in the non-literal `find` path no longer sits on the request path at
all — nothing in framing or routing uses a leftmost search any more.

Gates: `examples/http.roc` 60/60 (four cases added for the field index —
duplicate headers, a header with no colon, a value containing a colon, the
field count), router differential 174/174 against matchit. The engine was not
touched, so its gates stand from the previous entry.

## Where the non-literal `find`'s fixed cost was (2026-09-06)

The previous entry left ~560 ns unlocated after rejecting four hypotheses. Two
more of it are now found, and the method that found them was splitting `find`
into its two passes across a family of patterns rather than guessing again:
`Sharp.match_starts_fast` is public, so the reverse sweep can be timed alone
and the forward end pass taken as the difference. Over a 213-byte header block:

| pattern | find | sweep alone | is_match |
|---|---|---|---|
| `Content-Length` (literal) | 36 | 347 | 62 |
| `[Cc]ontent-Length` | 484 | 347 | 445 |
| `(?i)^content-length:[ \t]*` | 715 | 461 | 552 |
| `^content-length:` (no match) | 381 | 326 | 335 |

`find` is the sweep plus a small end pass, and the sweep costs ~330 ns even for
a pattern it records nothing for. Against haystack length the sweep is **~242
ns fixed plus 0.46 ns/byte** — so on a header block it is almost all fixed.

**`Deriv.nullable` is a recursive walk of the node graph, and `sweep_prologue`
called it once per scan.** So did `start_fast`, the sweep's input-start
handler. The comment above `sweep_prologue` said "it runs once per scan, so the
call costs nothing measurable", which was true when it was measured against 256
KB. The answers were already precomputed: `fl_end_null` and `fl_begin_null` are
set at state creation to exactly `can_be_null(node) and nullable(loc, node)`,
and `nullable` is False when the node cannot be null, so the flag test IS the
query. Three substitutions, ~90-100 ns off every non-literal `find`:

| pattern | find before | after |
|---|---|---|
| `[Cc]ontent-Length` | 484 | 397 |
| `(?i)content-length:` | 580 | 491 |
| `(?i)^content-length:[ \t]*` | 715 | 624 |
| `^content-length:` | 381 | 302 |
| `[0-9]+` | 625 | 523 |

**`Teddy.build` ran once per search too**, for any pattern with a literal-set
accelerator. It is 820-856 ns — more than the entire search it was preparing.
`Accel.literal_set` already built the tables to decide whether the set was
usable and then threw them away, keeping only the literals; `Sharp.T` now
carries `Lits(literals, Teddy.T)` and they fold into the artifact. Paired A/B on
a 75-byte haystack, `Sherlock|Holmes|Watson|Adler`:

| | `Sharp.find` |
|---|---|
| tables built per call | 885-1950 ns |
| tables in the artifact | **83-265 ns** |

Both bugs are the same shape as the doubled-literal one in the previous entry,
and the same shape as each other: per-search setup that a 256 KB benchmark
amortises to nothing and a few-hundred-byte search pays in full. This engine
had never been profiled at that size.

**What is still unaccounted for:** the sweep keeps ~145-260 ns of fixed cost
depending on pattern complexity, and the forward end pass ~140-270. Neither is
a single identifiable call any more — `collect_plain`'s prologue is already
documented as tuned, and `ends_fast`'s extra tag destructures were measured at
no-op in the previous entry.

No regression on long haystacks: `tools/bench/run.sh` is within 2-6% on every
row, and the untouched `Regex` column moved by the same amount, so that is the
machine rather than the change.

Gates: RE# corpus 331/331, node layer 57/57, fuzz plain 18000 cases 0
divergences, fuzz seed 42 unchanged at 16, RE# differential agree=5139 differ=0
of 5341 with ends differ=0, `examples/http.roc` 60/60.

## `collect_*`'s prologue, and what the residual actually is (2026-09-06)

The owner suspected `collect_plain`'s prologue was not tuned for a match of
this size. It is not, and the comment above it says so once you read it against
the question: "the tables the loop reads are bound once ... passing the engine
record to a helper PER STEP cost 4-5x". That tuned the loop. Nothing tuned the
entry.

Timing `Sharp.match_starts_fast` on a haystack the accelerator skips
end-to-end, so that scanning contributes almost nothing:

| haystack | `collect_plain` | `collect_prefix` |
|---|---|---|
| 0 B (early return, never enters) | 46 | 44 |
| **1 B** | **127** | **121** |
| 2 B | 124 | 118 |
| 4 B | 126 | 120 |
| 256 B | 148 | 140 |

**~80 ns appears the instant the sweep processes one byte**, and 1 B to 256 B
adds ~20. Both loops pay it equally.

### It is not the table bindings, and not the automaton

Three hypotheses measured and rejected, so the next attempt does not repeat
them:

- **Binding the five list fields costs ~1-6 ns**, measured directly: a record
  of five lists, functions binding 0 / 1 / 3 / 5 of them, and a variant reading
  them in place without binding, all within noise of each other.
- **The record return is free** — the same test with a `{ s, acc }` return
  measured the same.
- **It does not scale with the automaton.** `[ab]` (5 states) shows the same
  ~80 ns step as the header pattern (34 states).

So it is the fixed structure of entering the sweep — `sweep_prologue`, the
`collect_fast` dispatch, `collect_plain`/`collect_prefix`, `start_fast`: four
calls whose bodies each do a small fixed amount of real work (`decode_rev`, a
class lookup, two table reads, flag tests, and list plumbing across three
record returns). Cutting it means fusing them, which puts the `find_all` hot
loop at risk for ~80 ns on short searches.

### Correction to the previous entry

That entry put the sweep at "~242 ns fixed plus 0.46 ns/byte". Both numbers
came from filler haystacks and conflated fixed cost with content-dependent
scanning. Measured apart, for `(?i)^content-length:[ \t]*`:

| | ns |
|---|---|
| sweep, fixed (entry ~46 + setup ~80) | ~130 |
| sweep, scanning a real 213-byte header block | ~210 |
| forward end pass and `find`'s glue | ~270 |
| **`find` total** | **~620** |

So a little over a fifth of a non-literal `find` on a small haystack is setup,
not the 40%+ the earlier estimate implied, and the largest single piece left is
the forward end pass rather than the sweep.

Nothing shipped from this round: no change was measured as a win, and the
project does not ship unmeasured ones.

## The forward end pass: a tag built once per byte (2026-09-06)

The previous entry left the forward end pass as the largest unexplained piece.
Splitting it needed a way to grow the MATCH while holding the haystack and the
automaton still: `(?i)^content-length:[ \t]*` does that, because padding spaces
after the colon lengthens what `[ \t]*` consumes and nothing else. Block held
at 220 bytes:

| pad | find | sweep | end pass |
|---|---|---|---|
| 0 | 374 | 190 | 184 |
| 16 | 457 | 185 | 272 |
| 48 | 567 | 185 | 382 |
| 100 | 751 | 183 | **568** |

The sweep is flat, which is the control. So the end pass is **~126 ns fixed plus
~3.8 ns per matched byte** — and the per-byte half is the interesting one, since
a fused-`atable` DFA step should be nearer 1 ns.

**`best` was a `Try(U64, [NoEnd])` updated inside the loop.** A nullable tail is
nullable at EVERY position, so `best = Ok(pos)` built a tag on every byte. Held
as a `U64` with a sentinel (`Dfa.no_end`, with `from_pos`/`to_pos` at the two
boundaries where the tag is still wanted):

| | fixed | per byte |
|---|---|---|
| `Try` tag in the loop | 197 ns | 3.87 |
| `U64` sentinel | **167** | **3.10** |

`ends_at_start_fast` — the anchored pass behind `first_end`/`longest_end`, and
so behind every `Http.take` — carried TWO of them, a `{ first, last }` record of
tags updated per byte. Same treatment:

| `Sharp.longest_end`, 34 B | before | after |
|---|---|---|
| no match | 134 ns | 109 |
| 3-byte match | 166 | 111 |
| 34-byte match | 616 | **452** |

That is 14.2 -> 10.1 ns per byte for the anchored pass.

### What it moved

`tools/http-bench`: **2237 -> 2074 ns/request, 5.5x -> 5.0x** off `httparse`,
framing 1459 -> 1257.

**Correction.** This entry first claimed the long-haystack bench "improved on
seven of eight rows", from comparing two runs taken hours apart. A PAIRED run
(see "Did the campaign cost long-haystack speed?" below) does not support that:
against Rust's meta engine the campaign is better on six rows, worse on three
and level on one, all inside the same few percent the untouched `Regex` column
drifts by. The long-haystack effect is a wash, not a gain. The isolated
measurement of this change — 3.87 -> 3.10 ns/byte in the end pass — stands; it
is simply too small a share of `find_all` to show through the noise.

### One change reverted

Inside the same loop, `hay[pos]` is read twice — once as `b0` for the skip
check, once as `b` for the transition. Reading it once measured 566 vs 580 ns
at pad=100, inside the noise: the compiler already eliminates it. Reverted
rather than shipped with a plausible-sounding comment.

### Also: `Dfa.ends_fast` and `Dfa.find_first_fast` SIGBUS when called from an app

Both crash (exit 138) called directly from an app, while `Sharp.find` runs the
same code from inside the package without trouble. Hit three times now while
profiling, and it is why this entry's decomposition had to be done indirectly,
by growing the match rather than by timing the pass. Worth a reduction for
upstream; it belongs with the two debug-helper crashes already owed.

### Gates

RE# corpus 331/331, node layer 57/57, fuzz plain 18000 cases 0 divergences,
fuzz seed 42 unchanged at 16, RE# differential agree=5139 differ=0 of 5341 with
ends differ=0, `examples/http.roc` 60/60, `tools/bench` counts all ok.

## Did the campaign cost long-haystack speed? (2026-09-06)

The owner asked whether the whole short-input campaign had been startup and
teardown cost only, and whether it had hurt throughput on long haystacks. Two
checks, because the first two claims in this log about long-haystack effects
were both drawn from UNPAIRED runs and one of them was wrong.

### The automaton is unchanged

`Build.loop_register`'s min/max length is read by more than the accelerator:
`or2_loop_subsume` uses it to decide whether a loop subsumes another branch and
an alternation can collapse, and `min_len_or`/`max_len_and` propagate it through
`Or`/`And`. So in principle giving non-singleton loop bodies a real length can
change which node graph gets built, not merely which accelerator is chosen.

Measured, it does not. Compiling the ten bench patterns plus `abab`,
`(?:ab){2}` and `\r\n\r\n` before and after the campaign, **state counts and
node counts are identical on all thirteen**. The only difference in the whole
comparison is the three doubled literals going from `len=any override=none` to
`len=4 override=abab`. The rewrite layer was not disturbed.

### Throughput is a wash, and the control says so

A paired run — pre-campaign tree at `23abd8b` in a worktree, post-campaign tree,
alternated, twice each — on the 256 KB bench. Raw Sharp ns, best of both rounds:

| pattern | pre | post | |
|---|---|---|---|
| `Holmes` | 28700 | 29950 | +4.4% |
| `Moriarty` | 10600 | 10650 | +0.5% |
| `Sherlock\|Holmes\|…` | 493050 | 494550 | +0.3% |
| `[A-Za-z]+` | 2140850 | 2206650 | +3.1% |
| `[0-9]{2,4}` | 194400 | 196950 | +1.3% |
| `\bthe\b` | 263100 | 263350 | +0.1% |
| `\w+\s+\w+` | 2255500 | 2276350 | +0.9% |
| `(\w+)@(\w+)` | 73800 | 73700 | -0.1% |
| `\p{L}+` | 2243900 | 2273550 | +1.3% |
| `.*Holmes` | 367650 | 358450 | -2.5% |

Slightly slower on eight rows, faster on two, none beyond ~4%. **The control
settles it: `Regex`, whose code is byte-identical in both trees, drifts the
same way in the same run** (+4.9%, +1.5%, +0.8%, +0.7%, +0.4% on five of its
rows, -1.0% and -0.6% on two). A consistent sub-percent-to-few-percent shift
appears in an engine the campaign never touched, so it is build layout and
machine state, not the change.

Ratios against Rust's meta engine are no better as a comparator here: in round
2 the Rust side itself got ~6% faster mid-run, which moved every `sharp/M`
figure up regardless of Sharp.

**Conclusion: long-haystack throughput is unchanged within measurement error,
and every row's match count agreed with Rust in every run.** The earlier
"improved on seven of eight rows" in this log was two unpaired runs read as a
trend; it has been struck.

### Was it all startup cost?

Nearly. Four of the five changes are per-call and vanish into a 256 KB scan:
the literal-dispatch restructure, the precomputed padded literal, the
`Deriv.nullable` walks replaced by flags, and `Teddy.build` moved into the
artifact. Two qualifications:

- **The doubled-literal fix is algorithm selection, not startup.** `\r\n\r\n`
  now runs a SIMD literal scan instead of a reverse sweep plus forward pass.
  That is a large win at any length for the patterns it reaches; the bench has
  no doubled literal in it, which is why the table above does not move.
- **The `Try`-tag fix is per-byte, not per-call.** It measured 3.87 -> 3.10
  ns/byte in the end pass in isolation, but the end pass is a small enough
  share of `find_all` that it does not clear the noise floor above.

## The ~130 ns of sweep setup, decomposed (2026-09-06)

`Dfa` cannot be timed from an app (it SIGBUSes), but `Sharp` can call it, so
temporary probes inside `Sharp` timed the sweep in cumulative stages. 100k
iterations, `[ab]`, 1-byte haystack:

| stage | cumulative | its own |
|---|---|---|
| call boundary only (no-op with the same arguments) | 1 | **1** |
| + `sweep_prologue` | 23 | **22** |
| + `collect_fast` -> `collect_plain` | 75 | **52** |
| + `start_fast` | 101 | **26** |
| `Sharp.match_starts_fast` (returns the list to the app) | 135 | **34** |

So it is not one thing. It is four small things, none individually wrong.

### Six hypotheses measured and rejected

Each of these was plausible enough to try, and each is worth NOT trying again:

1. **The call boundary.** A no-op `Dfa.probe_noop : Dfa.E, Trie.T, List(U8) ->
   U64` that reads one scalar from each argument costs **1 ns**. Passing the
   engine record — eighteen fields, fourteen lists, a nested `Arena.A` — is
   free.
2. **The record return.** `probe_noop_rec` returning `sweep_prologue`'s exact
   `{ s, pos, acc }` also costs **1 ns**.
3. **Binding the tables.** A synthetic record of five lists, with functions
   binding zero, one, three or five of them and a variant reading them in place,
   are all within noise of each other (~1-6 ns).
4. **Eagerly binding the arena in `start_fast`.** `a = e.a` sits above the
   branch that uses it; moving it inside changed 101 ns to 102. The compiler
   already sinks it. Reverted.
5. **`ends_fast`'s six extra `Dfa.Len` destructures** (previous entry): no-op.
6. **Automaton size.** `[ab]` at 5 states pays the same as the header pattern
   at 34.

### The one anomaly left

`collect_fast`'s 52 ns splits as ~22 before it looks at a byte and **~30 for
the FIRST byte**, after which bytes cost ~0.2-0.6 ns each. A thirty-nanosecond
first iteration against a sub-nanosecond steady state is the sharpest thing in
the profile and is not explained by anything above. It is not cold cache — the
same haystack and engine are scanned 100k times in the timing loop, so the
tables are hot after the first of those.

Attributing it further needs a profiler rather than another A/B; guessing has
now failed six times in a row. Cutting the ~130 ns without one would mean
fusing `sweep_prologue`, `collect_*` and `start_fast` into a single function so
their list reads happen once, which puts the `find_all` hot loop at risk for a
cost that no longer sits on the HTTP request path at all.

Nothing shipped from this round.

## Profiled: it is Roc's refcounting (2026-09-06)

Six rounds of A/B guessing had failed, so: `sample` on a binary doing nothing
but `Sharp.match_starts_fast` in a loop. Roc emits opaque `_roc__proc_<hex>`
symbols, but its runtime helpers keep their names, which is enough.

Excluding the root frame:

| haystack | `roc_llvm_rc_decref_*` | Roc code |
|---|---|---|
| 1 byte | **73.8%** | 26.2% |
| 256 bytes | **58.8%** | 41.2% |

**Three quarters of a short sweep is reference counting**, and the share falls
exactly as it should when real scanning grows — a fixed per-call cost. The call
tree shows the struct-level routines (`decref_69/71/73`) recursing into the
list one (`decref_29`): the engine records being walked field by field on entry
and exit. `Dfa.E` is eighteen fields, fourteen of them lists, with a nested
`Arena.A` of its own; `sweep_prologue`, `collect_fast`, `collect_plain` and
`start_fast` each take it.

### This corrects the previous entry

That entry measured a no-op `Dfa.probe_noop : Dfa.E, Trie.T, List(U8) -> U64`
at 1 ns and concluded "passing the engine record is free". Wrong: the probe read
one scalar per argument, so the compiler elided the refcounting. It does not
elide it when the fields are used, which is the whole difference between the
probe and the real function. A no-op is not a null hypothesis for refcounting.

### Two fixes tried, both worse or invalid

- **A `Tabs` record holding just the tables the loops read.** 142-160 ns against
  85-100 for the `Dfa.E` version — WORSE. It has to carry `Arena.A` and
  `st_pend` for the pending-nullable path, which puts a nested record back in,
  and `tabs_of` constructs it per call.
- **Flat arguments — the five lists, no record.** Measured 30 ns against 85, but
  that spike's loop had dropped the `pend_positions` calls, so it was not the
  same loop. The number is not evidence for anything.

Reverted, both. What the profile supports is the diagnosis, not yet a fix: a
real one has to keep the pending path and still hand the loop something Roc
does not walk, and the obvious shapes for that are what just failed.

Worth noting for upstream: `sweep_prologue(e, t, hay)` returns a record that
contains neither `e` nor `t`, so both are pure borrows. Refcounting them is
work the program cannot observe.

## Current standing against Rust's meta engine (2026-09-06, quiet machine)

Two back-to-back runs of `tools/bench/run.sh`, 256 KB haystack, on a machine
with no competing build (every earlier three-way table in this log was taken
while another session held ~98% of a core). The two runs agree within 2% on
every row, which no previous pair in this log does.

| pattern | sharp ns | sharp/meta | run 2 | `Regex`/meta |
|---|---|---|---|---|
| `Holmes` | 29000 | **1.09x** | 1.06x | 1.88x |
| `Moriarty` | 10150 | **1.04x** | 1.03x | 1.17x |
| `Sherlock\|Holmes\|…` | 474750 | **1.13x** | 1.12x | 2.14x |
| `[A-Za-z]+` | 2093250 | **0.96x** | 0.97x | 1.55x |
| `[0-9]{2,4}` | 189350 | **1.75x** | 1.79x | 1.39x |
| `\bthe\b` | 255550 | **1.26x** | 1.25x | 1.64x |
| `\w+\s+\w+` | 2132250 | **1.38x** | 1.40x | 1.53x |
| `(\w+)@(\w+)` | 70250 | **1.03x** | 1.05x | 1.99x |
| `\p{L}+` | 2166100 | **1.06x** | 1.05x | 1.67x |
| `.*Holmes` | 340300 | **0.53x** | 0.56x | 0.84x |

All match counts agree with Rust.

**Two rows beat the meta engine** — `[A-Za-z]+` at 0.96x and `.*Holmes` at
0.53x — and four more are within 5% of it. Sharp is ahead of `Regex` on every
row, including `[0-9]{2,4}`, the one row where it is furthest from Rust (1.75x
against Rust, but `Regex` is 1.39x there, so this is the single pattern where
the older engine still wins).

Against this log's first three-way table (M4 stage 4): `Holmes` 1.68 -> 1.09,
the alternation 2.19 -> 1.13, `\bthe\b` 1.74 -> 1.26, `\w+\s+\w+` 1.73 ->
1.39, `(\w+)@(\w+)` 1.29 -> 1.04, `\p{L}+` 1.29 -> 1.05. **Almost all of that
belongs to the accelerator work between the two tables** — the byte-wide class
trie, the 16-bit `atable`, walking the starts backwards, stopping the sweep for
`is_match`, the literal-set accelerator, the fused single-literal scan, the
inlined fixed-length end pass — not to the short-input campaign above, which a
paired test measured as a wash at this length. Part of the gap is also that the
earlier table was measured under contention.

`[0-9]{2,4}` is the one row that has not moved at all (1.76 -> 1.75) and is now
the outlier by a distance.

## The port against the original (2026-09-06): `tools/sharp-bench`

Everything measured so far compared this engine with Rust and with the other
Roc engine. `tools/sharp-bench` compares it with the thing it is a port of.
The harness builds RE# from the checkout, times the same ten patterns on the
same 256 KB haystack, and checks match counts.

Both sides construct once outside the loop and keep the per-pattern minimum
over 5 runs of 20 iterations. RE# additionally warms up: it JITs and fills a
lazy DFA on the early passes. That warmup matters more than expected. Before
adding it, the first pattern's construction measured 19.9 ms; after, 0.92 ms.
The whole first draft of the construction column was measuring .NET starting
up.

| pattern | sharp ns | RE# ns | sharp/RE# | counts |
|---|---|---|---|---|
| `(\w+)@(\w+)` | 84900 | 648833 | 0.13x | ok |
| `.*Holmes` | 372050 | 993625 | 0.37x | ok |
| `[0-9]{2,4}` | 189800 | 449458 | 0.42x | ok |
| `Moriarty` | 11050 | 25167 | 0.44x | ok |
| `Holmes` | 46650 | 81000 | 0.58x | ok |
| `\bthe\b` | 375300 | 632584 | 0.59x | ok |
| `Sherlock\|Holmes\|…` | 940750 | 1027041 | 0.92x | ok |
| `[A-Za-z]+` | 2590500 | 2385458 | 1.09x | ok |
| `\p{L}+` | 2650700 | 2355583 | 1.13x | ok |
| `\w+\s+\w+` | 2680700 | 2035792 | 1.32x | ok |

Ahead on seven, behind on three, and all ten match counts agree. The counts
agreeing is the more interesting half: on top of the 331-case corpus and the
3587-case differential, the port reproduces the original's answers on every
bench pattern.

The split is the same one that shows against the other Roc engine. Where an
accelerator fires the port wins, most dramatically on the email pattern at
7.6x, where the rare-byte prefix skip does the work. The three losses are the
dense-class patterns where nothing skips and both engines walk every symbol;
there RE# is running a JIT-optimised inner loop over .NET's vectorised
primitives and we are not.

Construction is the architectural difference rather than a tuning one:

| pattern | RE# construction |
|---|---|
| `[A-Za-z]+` | 414833 |
| `Holmes` | 920500 |
| `\w+\s+\w+` | 5628834 |
| `Sherlock\|Holmes\|…` | 8860250 |
| `\bthe\b` | 8878208 |

RE# pays 0.4 ms to 8.9 ms per pattern at runtime, every process start. A
folded Roc pattern pays zero, because the automaton is in the binary. On a
short-lived process that alone outweighs every scan difference above.

Two caveats. Offsets are not compared, only counts: RE# reports UTF-16 indices
and this engine reports byte offsets, and the haystack has 9900 non-ASCII
bytes, so positions after a multibyte codepoint legitimately differ. And the
.NET side gets Release, server GC and a warmup, which is the fairest setup for
it, while the Roc side is ahead-of-time compiled and needs none.

## Why the dense classes were slow, and the fix (2026-09-06)

The three patterns behind RE# were `[A-Za-z]+`, `\p{L}+` and `\w+\s+\w+`, the
ones where no accelerator fires. Timing each stage on inputs prepared outside
the loop, rather than by subtracting whole-scan timings, which was too noisy
to read:

| pattern | starts recorded | matches kept | reverse | order | forward |
|---|---|---|---|---|---|
| `[A-Za-z]+` | 205101 | 40056 | 1098000 | 633000 | 1226000 |
| `\p{L}+` | 210051 | 40898 | 1030000 | 356000 | 931000 |
| `\w+\s+\w+` | 210198 | 21091 | 1029000 | 355000 | 1329000 |

Two causes, only one of them inherent.

**The discard rate is the design.** The reverse sweep records a start wherever
a match could begin, so a dense class records most of the haystack: five to
nine starts for every match that survives the next-valid check. RE# does the
same, so this explains the absolute cost, not the gap.

**The ordering pass was mine.** `find_all` materialized a sorted, deduplicated
copy of that 205000-element list before the forward pass. RE# never does:
`llmatch_ends` walks its accumulator backwards by index, which is ascending
position order already. That copy was 15% to 25% of the scan on exactly these
patterns and near zero elsewhere.

It existed for a reason. RE#'s backwards walk assumes the accumulator is
ordered, and lookaround pending positions can resolve out of order, which is
one of the RE# bugs this port fixes. But that only happens with lookarounds.
`Dfa.is_descending` now decides: ordered input is walked backwards in place,
out-of-order input is still sorted, and duplicate suppression folds into the
loop as a comparison against the previous start, since equal starts are
adjacent in position order.

| pattern | sharp/RE# before | after | sharp/Rust meta before | after |
|---|---|---|---|---|
| `[A-Za-z]+` | 1.09x | 0.85x | 1.07x | 0.93x |
| `\p{L}+` | 1.13x | 0.91x | 1.20x | 1.08x |
| `\w+\s+\w+` | 1.32x | 1.08x | 1.65x | 1.45x |
| `Sherlock\|Holmes\|…` | 0.92x | 0.85x | 2.18x | 2.11x |
| `(\w+)@(\w+)` | 0.13x | 0.11x | 1.21x | 1.05x |

Against the original the port is now ahead on nine of ten patterns, behind
only on `\w+\s+\w+` at 1.08x. Against Rust's meta engine `[A-Za-z]+` lands at
0.93x and `.*Holmes` at 0.55x, so two patterns are now faster than Rust.
Against the other Roc engine the port wins eight of ten. In absolute terms
`[A-Za-z]+` went from 2590500 to 2083950, a 20% cut, with the other two dense
patterns each about 17%.

The lesson generalises past this change: the accumulator is O(haystack) on
dense patterns, so anything that touches it a second time costs a full pass.

## Two more redundant passes (2026-09-06)

Auditing the scan paths for the same shape as the ordering copy found three
more, two of them worth fixing now.

**`find` and `is_match` computed every match.** Both were defined as
`find_all` plus a pick, so on a dense class they ran the forward pass over all
40056 matches to answer about one. The reverse sweep is unavoidable, since the
leftmost start is not known until the sweep reaches the haystack start, but
everything after it was waste. `find_all_fast_opts` now takes `first_only` and
stops the forward loop after the first span; `find` and `is_match` share it
through `Sharp.find_first`.

| pattern | is_match before | after | find before | after | reverse sweep |
|---|---|---|---|---|---|
| `[A-Za-z]+` | 2089000 | 1175000 | 2063000 | 1140000 | ~1074000 |
| `\w+\s+\w+` | 2659000 | 1158000 | 2596000 | 1140000 | ~1040000 |
| `(\w+)@(\w+)` | 88000 | 40000 | 88000 | 40000 | ~39000 |

Both now sit at the reverse-sweep floor, which is the design's lower bound for
a leftmost answer. 1.8x to 2.3x.

**The threaded scan still sorted unconditionally.** The previous entry fixed
the ordering copy in `find_all_fast` and left the identical code in
`Dfa.find_all`, which incomplete folds use. Same fix: check for order, read
backwards when ordered, sort only when lookarounds resolved out of order. Worth
3% on `a(?=.*b)`, 12220000 to 11860000, because the threaded path's cost is
dominated by `Ref.prepare` and the per-symbol stepping rather than the sort.

**`count` is left alone.** It genuinely needs every match, because match
boundaries decide which later starts get skipped, so only the span allocation
is recoverable.

### The gates did not cover what changed

Nothing in the corpus, the differential or the fuzz runner exercised `find` or
`is_match`; they all go through `find_all`. So the fuzz runner now checks
`find` against the first of `find_all`, and `is_match` against whether
`find_all` is empty, on every case: 27396 of them across both tiers, zero
divergences. That check should have existed before the API had two entry
points whose agreement was assumed rather than tested.

### Still open

`Ref.prepare` materializes a class and a byte offset per symbol before the
threaded scan runs, two haystack-sized lists that the fast path does without
and that RE# does not build at all. That is structural rather than a stray
pass, so it is a larger change than these.

## `Ref.prepare` is amortization, not a redundant pass (2026-09-06)

The previous entry listed `Ref.prepare` as the last of the redundant passes:
it builds a class and a byte offset per symbol before the threaded scan, two
haystack-sized lists the frozen scans do without. That reading was wrong, and
the rewrite that followed from it was a regression.

The threaded scan was converted to byte offsets, decoding and classifying each
symbol in place exactly as the frozen scans do, sharing their byte-based
helpers. It passed every gate, so it was correct, and it was much slower:

| pattern | with `prepare` | byte-based | |
|---|---|---|---|
| `a(?=.*b)` find_all | 12192000 | 21247000 | 1.74x slower |
| `\w+\s+\w+` threaded | 41965000 | 54422000 | 1.30x slower |

The reason the frozen path can decode in place is that it has `atable`, the
fused ASCII byte-to-state table, so a complete fold never calls `Trie.class_of`
for ASCII at all. The threaded path has no such table, by definition: it exists
because the fold is incomplete. So it pays a decode and a class lookup per
symbol, and the forward pass re-walks the span of every match, so the same
symbols are classified several times. `prepare` pays that once and every later
pass indexes an array. It is a cache, and the passes that read it are what
justify it.

Reverted. What survived is the smaller version of the idea: the prepared
haystack was storing a minterm id in a `U32` and a byte offset in a `U64`,
where `Trie.build` bounds a minterm id under 64 and a byte offset fits a
`U32`. Narrowing both takes the prepared haystack from 12 bytes a symbol to 5,
so 3.1 MB to 1.3 MB on a 256 KB haystack. Speed is neutral to about 1.5%
better, measured by alternating the two binaries once the machine was quiet,
after a first attempt produced numbers 40% higher across the board on both
sides and had to be discarded.

The general lesson is the opposite of the previous entry's: a pass that
materializes something later passes read repeatedly is not the same shape as
one that materializes something read once. The ordering copy was read once.

## Stopping the reverse sweep for `is_match` (2026-09-06)

`find` needs the leftmost match, so its sweep must reach the haystack start
before the answer is known. `is_match` does not: any match will do, and the
sweep runs right to left, so it can stop at the first start it records.

The obstacle was that this rests on a recorded start always having an end,
which the code does not assume anywhere else. Both scans carry a branch for a
start that yields none. So the fast path does not assume it either: the
stopped sweep produces a candidate, the forward pass verifies it, and a
candidate that yields no end falls back to the full scan. False positives are
impossible because a verified end is a real match, and false negatives are
impossible because failure falls back. The saving survives whether or not the
implication holds.

`Dfa.first_starts` gets its own loops rather than a flag in `collect_plain`,
because a per-step check there would cost `find_all` on every pattern. The
`HandleInputEnd` prologue is now shared by both sweeps as `sweep_prologue`,
which runs once per scan.

`is_match`, ns, min of 10:

| case | before | after |
|---|---|---|
| `[A-Za-z]+` on 256 KB of prose | 1409000 | below timer resolution |
| `\bthe\b` on the same | 402000 | 1000 |
| `[a-c]{3}` where the only match is at offset 0 | 686000 | 527000 |
| `[a-c]{3}` with no match at all | 685000 | 518000 |

The first two are the point: a pattern that matches anywhere near the end of
the haystack now answers in constant time rather than scanning all of it. The
last two are the cases with no early exit available, and neither regressed;
they gained slightly from not ordering starts or building a span list.

`find_all` is untouched, as the bench confirms: `[A-Za-z]+` 2174650 against
Rust's 2229288, still 0.98x.

## A literal-set accelerator for alternations (2026-09-06)

The alternation was the worst row against Rust, 2.07x, because RE#'s design has
no literal-set accelerator: its sweep skips only to the eight capitals where
Rust runs Teddy over the literals themselves. We already had Teddy, so the gap
was ours to close.

`Accel.literal_set` recognises a pattern whose language is a finite set of two
to eight non-empty strings, with no anchor or lookaround, and orders them
LONGEST FIRST, because `Teddy.lit_end` returns the first literal that matches
at a position and leftmost-longest wants the longest. `Sharp` carries the set
and dispatches before the scan.

| case, 256 KB of prose | Teddy | ordinary scan |
|---|---|---|
| 8 common names, 9630 matches | 467000 | 1004000 |
| 3 rare names, 59 matches | 28000 | 549000 |
| 3 absent names | 24000 | 545000 |

On the bench the alternation went from 903250 to 490200, so 1.84x, and from
2.43x of Rust's meta engine to 1.14x. Every other row moved 0.96x to 1.03x,
which is noise.

### Four things that went wrong first

**Detection has to be recursive.** A flat walk over the union's children found
only 5 of the 8 literals, because the builder merges shared affixes:
`Watson|Norton` is stored as a concat whose head is a union, not as two literal
chains. `Accel.literal_lang` computes the language as a set of strings through
concat, union and singleton, with the member count capped so it cannot blow up.

**Putting the branch in the hot function cost 3-25% on EVERY pattern**,
including the one it was meant to help. Adding a `LiteralSet` arm to
`Dfa.find_all_fast_opts` slowed `two_words` by 1.21x and `caps_email` by 1.22x,
patterns that never take the branch. Extracting the general scan into its own
function did not help, so it was not the call: the hot function simply got
bigger. `Sharp` dispatches instead, and `Dfa` never learns about literal sets.
Same inlining boundary as the trie lookup and the scan loops.

**Teddy's verification cost about 150 ns a candidate**, enough to lose to the
ordinary scan on a dense alternation. Two causes, both the familiar shape:
`lit_end` walked `List(List(U8))`, refcounting a nested list per literal per
candidate, and `scan_m` -> `bits_m` -> `step_m` passed the 6-vector `Teddy.T`
and the accumulator record per window, per set bit and per candidate.
Flattening the literals into one buffer with offsets took it from 1.21x to
1.13x; rewriting the fused scan as a single function of `while` loops with the
tables in locals took it to 0.54x.

**A defensive cap made things worse.** With verification still slow, a
candidate cap looked necessary so a dense alternation could fall back. It was
measured at 1.03x on that row, because bailing means paying for a partial Teddy
scan and then the whole ordinary one. Once the loop was rewritten the uncapped
version was 1.84x FASTER on the same row, so the cap came out. Its own
measurement had been read against `find_all_plain`, which disables every
accelerator, not just this one; that comparison flattered Teddy early on and
hid the regression until the like-for-like A/B against the previous commit.

## The short-literal overhead (2026-09-06)

`Holmes` sat at 1.81x of Rust's meta engine and `Moriarty` at 1.17x, the two
widest rows left. The difference between them is the tell: 1219 matches against
59, on the same haystack, so the gap was per match rather than per byte.

Counting first: on this haystack every `H` starts `Holmes` and every `M` starts
`Moriarty`, so there is not one false candidate. Selectivity was not the
problem, which ruled out reaching for Teddy's three-byte fingerprint.

Two fixes, both the shapes this log keeps returning to.

**Fusing the scan.** `find_all_literal` collected every candidate offset into a
`List(U64)` and then folded over it. Scanning and verifying in one loop, with
inline appends, took `Holmes` from 48150 to 42650.

**Vectorizing the verification.** Confirming a 6-byte literal meant five
bounds-checked byte loads. With the literal padded into a lane and a mask of
its length, it is one load, one compare and one masked test, on the common path
where the literal fits 16 bytes and the window is in bounds. That took `Holmes`
to 30050.

| pattern | before | after | vs Rust before | after |
|---|---|---|---|---|
| `Holmes` | 48150 | 30050 | 1.81x | 1.11x |
| `Moriarty` | 11250 | 10650 | 1.17x | 1.08x |

`Moriarty` barely moved, which is the expected result and a useful check: with
59 matches it is almost entirely the byte scan, and that was already near the
floor. Decomposing `Holmes`, the scan accounts for about 11000 of its 30050 and
the remaining 19000 covers 1219 matches, so roughly 15 ns each against Rust's
14 ns, which is parity. (An earlier draft of this paragraph blamed vector
width, claiming Rust reads 32 bytes a window to Roc's 16. That is wrong: Rust's
meta engine uses 128-bit vectors on this machine, so both read 16. Corrected
2026-09-06.)

## `[0-9]{2,4}` and `\bthe\b`, the last two gaps (2026-09-06)

The two widest remaining rows against Rust, at 1.75x and 1.78x. Stage timings,
on the 256 KB haystack:

| pattern | starts | matches | reverse sweep | forward | total |
|---|---|---|---|---|---|
| `\bthe\b` | 1216 | 1216 | 341000 | 139000 | 480000 |
| `[0-9]{2,4}` | 2863 | 1455 | 224000 | ~0 | 185000 |

**`[0-9]{2,4}` is essentially all reverse sweep.** Its `RemainingSets` length
lookup makes the forward pass free, and its skip set already earns 3x: 614000
without, 224000 with. What is left is 0.85 ns a byte against Rust's 0.42.

That is NOT vector width. Rust's meta engine uses 128-bit vectors on this
machine, the same as Roc, so both kernels read 16 bytes a window and the gap is
work per window. Ours is the general `Bset` kernel: two `table_lookup`s, an
and, a compare against zero, a negate, a bitmask and an or for the high bit,
over a bounds-checked load. A contiguous ten-value set like `[0-9]` does not
need any of that — two range compares and an and decide it. I have not
confirmed which kernel Rust actually picks here, so the 2x is consistent with
ops per window but not yet attributed; a `[0-9]`-shaped range kernel in `Bset`
is the obvious thing to try and has not been tried.

**`\bthe\b`: the cost was candidates, not verification.** One fix landed
first: the fixed-length end pass called `Utf8.advance`, a call per symbol
wrapping a call per decode, costing 145 ns a match to advance three ASCII
bytes. Inlined, the row went 373350 to 342450, so 1.78x to 1.68x, with every
other row unchanged.

The rest is the sweep. The accelerator anchors on `h`, which occurs 13473 times
on this haystack where the pattern matches 1216, so 12257 hits are found and
rejected. I first read that as a VERIFICATION cost — three further set checks
per rejection at four memory operations each — and built the fix that reading
implies: the prefix sets here are a word-boundary class followed by the single
codepoints `t`, `h`, `e`, so the contiguous run of single-codepoint sets was
compared as one padded vector against a length mask, the way `find_all_literal`
verifies a literal.

That made the row 10% SLOWER (338700 to 372650), which falsified the reading.
Measuring the halves separately: `Rlit.rfind_byte` for `h` over the haystack,
one call per hit as the sweep does it, is about 210000 ns of the 341000 sweep
on its own. So the scan is 60% of it, and the 12257 rejections share the other
130000 — about 10 ns each, which is one or two checks, not three. Verification
already early-outs on the first set that fails; replacing a 10 ns early-out
with a 16-byte load, compare and mask is strictly more work.

The cost is the candidate RATE, so the run belongs in the search, not the
verification. `Accel.run_of` now returns the rarest OTHER byte of the run as a
signed distance from the anchor, and `Rlit.rfind_pair` ANDs a second window
compare at that distance into the anchor mask (memchr's rare byte pair): an `h`
not preceded by `t` never leaves the scan loop. `\bthe\b` verifies `th`,
`.*Holmes` verifies `H` with `m` three bytes on (the run's rarest pair), and
`(\w+)@(\w+)` has no single-codepoint run so nothing changes.

The pair is a filter and never a requirement: a window too close to an edge for
the second load falls back to the anchor-only mask, and verification below
still checks every set. That is what keeps it sound.

| pattern | before | after | |
|---|---|---|---|
| `\bthe\b` | 338700 | 254350 | 0.75x |
| every other row | | | 0.92x-1.00x |

Which puts `\bthe\b` at about 1.26x of Rust, from 1.68x. The general lesson,
and the second time this session: measure which half of a loop costs, do not
infer it from the operation count. The rejected candidates were cheap because
they early-out; finding them was not.

## The range kernel for `[0-9]{2,4}`, tried and reverted (2026-09-06)

The entry above left a `[0-9]`-shaped range kernel as "the obvious thing to
try". Tried, measured, reverted. Recording it so it is not tried again.

**The kernel itself works and is faster.** `U8x16.lt_lanes` is UNSIGNED (probed:
lanes 120..255 compare correctly against a splat of 100), so a contiguous ASCII
range is `c -w lo` then one `lt_lanes` against `span`, or-ed with the high-bit
mask as everywhere in `Bset` — five ops a window against the table kernel's
two `table_lookup`s, an and, a zero-compare, a negate and two bitmasks. Walking
every digit of the 256 KB haystack, one call a hit as the skip loop does:

| kernel | ns |
|---|---|
| nibble tables | 211000 |
| range | 172000 |

1.23x, same 14454 hits. (Both measurements need min-of-300 in-process; at
min-of-20 the same binary reads anywhere from 211000 to 451000 run to run.)

**It does not convert.** Two wirings, both net losses:

1. Encoding the range in `skip_ok`/`skip_lo` and dispatching the per-byte
   membership test on it: `bounded_num` 0.97x, but `caps_email` 1.04x,
   `class_plus` 1.03-1.05x, `two_words` 1.04x, `word_bound` 1.02x. The extra
   branch is in the per-byte loop, and it costs patterns that have no range at
   all -- including ones with no skip states, where the only change is that
   `skip_ok[s]` is now bound to a local instead of compared in place.
2. Keeping the per-byte path byte-identical and dispatching only inside the
   skip, off a new `skip_rng` field: `bounded_num` 0.94-0.96x, but
   `literal_sparse` 1.25-1.29x, `literal_dense` 1.11-1.12x, `teddy_alt`
   1.03-1.06x. One more field on `Dfa.E` is what does that -- the record is
   threaded through every entry point, and this is the same record-size effect
   the hot-loop notes have hit repeatedly.

**Why 1.23x on the kernel is only 3-6% on the row.** I first wrote that the
scan is 20% of the row and the other 80% is the automaton stepping "the 14454
digits it lands on". Both halves of that are wrong, and counting the haystack
says why:

| | count |
|---|---|
| bytes | 262144 |
| digits | 4554 |
| digit runs | 1691 |
| non-ASCII bytes | 9900 |
| non-ASCII symbols | 4950 |
| `Bset.rfind` hits for `[0-9]` | 14454 |

14454 = 4554 + 9900. The digit skip stops at every digit AND at every non-ASCII
BYTE, because `Bset` or-s the high bit into the member mask -- "a skip must
stop at any multibyte symbol and let the automaton decode it", as the header
there says. So of the roughly 9500 symbol steps the sweep takes, 4950 are
non-ASCII symbols that cannot possibly be digits, and each of those is the
expensive step: `Utf8.decode_rev`, `Trie.class_of`, a full `table` lookup on
the minterm, where a digit step is one `atable` read.

Fresh decomposition of the row, min-of-200 in process:

| | ns |
|---|---|
| reverse sweep | 153000 |
| forward end pass | 17000 |
| `find_all` | 170000 |
| sweep with no skip sets | 546000 |

The sweep is 90% of the row, and over half of the sweep is spent on symbols
that are in the haystack's other alphabet.

So `[0-9]{2,4}`'s 1.72x is not vector width (corrected above), not the `Bset`
kernel, and not the cost of a step in general. It is the number of steps, and
specifically the non-ASCII ones the skip refuses to pass.


## `Sharp` becomes the default engine (2026-09-06, owner)

Directory swap, owner's call: `./package` -> `./package-dfa` (`Regex`, the
Rust-`regex` port) and `./package-sharp` -> `./package` (`Sharp`). The engine
a caller gets by depending on this repository's `package/` is now the
derivative engine.

This is the layout catching up with S1's override in
`plans/2026-09-06-http-parse.md`: new features already landed in `Sharp` only,
`Regex` was already frozen as the Rust-semantics oracle and a Roc codegen
benchmark, and `package-http` already depended on `Sharp` alone. The rename
makes the default match what the work has been.

Mechanical, and checked as such: every moved file is byte-identical to its
predecessor in `HEAD` (`git show HEAD:<old> | cmp`), and only path strings
changed in the consumers -- `examples/{smoke,bench}.roc` and
`tools/{size/probe.sh,diff/src/gen.rs}` to `package-dfa/`,
`examples/bench_sharp.roc`, `package-http/main.roc`, the four `tools/sharp-*`
runners and the `upstream/` reproducers to `package/`. Gates after the move:
`examples/smoke.roc` 21/21, `examples/http.roc` 60/60,
`tools/sharp-corpus/nodes.roc` 57/57, `tools/route-diff` 174/174 against
matchit, and all five examples build with zero errors.

Names NOT changed, deliberately: the modules are still `Regex` and `Sharp`,
and the `tools/sharp-*` directories keep their names. Renaming the module
would rewrite every call site in the corpus, fuzz and differential tools for
no behavioural gain, and `Sharp` is what the design log, the plans and the
RE# comparison all say.

## `[0-9]{2,4}`: the skip learns to pass over non-ASCII (2026-09-07)

The row had been the widest gap against Rust since the first three-way table
and the only one where `Regex` beat `Sharp`. Two entries above diagnosed it as
step COUNT -- 4950 non-ASCII symbols the digit skip refuses to pass -- and
left a range kernel as tried-and-reverted. This entry confirms the diagnosis
by experiment and fixes it, at 1.75x -> 1.20x with no other row moving.

### The diagnosis, settled

Replace every non-ASCII byte of the bench haystack with `x`. Same 262144
bytes, same 4554 digits in the same places, same 1455 matches:

| haystack | sharp | rustMeta | |
|---|---|---|---|
| as generated | 188950 | 108834 | 1.74x |
| non-ASCII -> `x` | 99850 | 109024 | **0.92x** |

Rust does not move (108834 -> 109024). `Sharp` halves and passes it. The whole
gap is the 9900 non-ASCII bytes, about 18 ns per symbol. Nothing about the
per-byte codegen is wrong on this row: given an all-ASCII haystack the loop is
already faster than Rust's.

Attributing that 18 ns, with the sweep's skip loop emulated over the real
haystack and the state pinned (min-of-200 in process):

| the non-ASCII arm does | ns |
|---|---|
| stop, then one cheap byte step | 97000 |
| stop, then `decode_rev` | 171000 |
| + `Trie.class_of` | 166000 |
| + the minterm transition (what it does today) | 151000 |
| walk the whole run back, no decode | 81000 |
| never stop for non-ASCII at all | 41000 |

So 110000 ns of the row is reachable, and a scan that never stops would take
all of it. (The b/c/d ordering is inverted by a few percent -- three loop
shapes, not three costs; the useful reading is 151000 against 81000 and 41000.)

### When passing is sound

`skip_ok[s]` becomes 0 / 1 / 2, where 2 says the skip may pass over non-ASCII
symbols. It needs two things beyond a 1:

- **No minterm holding a non-ASCII codepoint leaves the state.** The trie's
  atoms give this directly: atom `a` covers `[cuts[a], cuts[a+1])`, so it
  reaches past ASCII exactly when `cuts[a+1] > 0x80`. `Dfa.nonascii_classes`
  unions those atoms' minterms with `Invalid`, and a state passes when its
  leaving set misses all of them -- every such symbol then loops.
- **The state is not nullable.** A nullable skip state records every skipped
  POSITION as a match start, which is only right while each position is a
  symbol; passing over a multibyte run would record its interior bytes.

`[0-9]{2,4}`'s sweep has one skipping state (the reverse start, `st_nk` =
`nk_notnull`), and it qualifies.

### Four wirings, and why the cheapest one shipped

Reading the flag is free; ACTING on it is where three of four attempts paid
for the row out of every other row's pocket. A/B alternating both binaries in
one session, min-of-8:

| wiring | `bounded_num` | the heavy-sweep rows |
|---|---|---|
| encoding only (`== 1` -> `!= 0`, no behaviour change) | 0.995x | 0.99-1.01x |
| `Bset.rfind_ascii`, a second SIMD kernel in the arm | 0.565x | class_plus 1.03, two_words 1.03, uni_letters 1.03 |
| one kernel, a stop/pass mask threaded through `rfind` | **0.517x** | 1.035-1.058x |
| the same, mask built inside the skip branch | 0.526x | 1.02-1.05x, moving between rows |
| **walk the run back with a byte loop** | **0.666x** | **0.98-1.01x** |

The first row is the control: renumbering the flag, with the scans behaving
exactly as before, costs nothing. Everything after it is the arm.

The two fastest wirings are the two that touch shared code -- a second SIMD
loop inlined into `collect_plain`, or one loop with an extra parameter -- and
both tax `class_plus`, `two_words` and `uni_letters` 3-5%, patterns that never
take the branch. This is the hot-loop note's register-pressure effect again,
and at these sizes 3% of three ~2.1 ms rows is more time than the whole
80-90 us won on `bounded_num`. Hoisting the mask out of the per-byte test
recovered about half of it and moved the rest onto other rows.

What shipped is the slowest of the three and the only one that is free: inside
the `b < 0x80` branch `collect_plain` ALREADY has, a `while` that walks the
non-ASCII run back a byte at a time. No new kernel, no new parameter, `Bset`
untouched, and the per-byte test above it byte-identical. It leaves the
109000-vs-126000 difference on the table on purpose.

### What it moved

| | before | after |
|---|---|---|
| `bounded_num` vs Rust meta | 1.75x | **1.20x** |
| `bounded_num` vs `Regex` (`package-dfa`) | 1.39x, `Regex` ahead | 1.41x vs 1.20x, `Sharp` ahead |
| every other row | | 0.98-1.01x |

`[0-9]{2,4}` is no longer the widest row -- `two_words` at 1.41x is -- and no
longer the row where `Regex` wins.

Gates: corpus 331/331, fuzz plain 1500 patterns / 18000 cases 0 divergences,
fuzz seed 42 full 16 divergences (the pre-existing `$`-before-nullable family,
unchanged), node layer 57/57, `examples/http.roc` 60/60, router differential
174/174. Plus a differential written for this change and landed as
`tools/skip-diff`: `find_all` against `find_all_noskip` -- same automaton,
skips off -- over four 256 KB haystacks (mixed, lone continuation bytes at
every 997th position, `0xFF` at every 997th position, all-ASCII).

**The first version of it could not fail.** 18 patterns, 72/72, and removing
EITHER soundness condition from `skip_sets` still gave 72/72. Two holes: the
patterns spelled their non-ASCII with `é`, which this haystack does not
contain (it is Greek), and none of them had a nullable skip state, so that
condition never flipped a flag. Fixed by adding leaving sets over codepoints
the haystack really holds (`[0-9λ]`, `μ[a-z]`, `[.,;:ω]`) and a nullable one
(`[0-9]{0,3}`). At 28 patterns / 112 cases the correct build passes and each
condition removed is caught:

| condition removed | result |
|---|---|
| no non-ASCII minterm leaves the state | 103/112 -- `[0-9λ]`, `[.,;:ω]`, `[0-9ε]+` |
| the state is not nullable | 109/112 -- `[0-9]{0,3}`, ~4100 empty matches lost |

The second row is also the evidence that the nullability condition is
necessary rather than defensive: without it a passed-over Greek run swallows
every interior symbol boundary a nullable state should have recorded.

### Not done

`collect_prefix` and the two forward loops have the same shape and did not get
the pass path. No pattern measured here would use it: a prefix accelerator
implies a literal run, and `\bthe\b`'s skip set contains the word class, which
is not ASCII-only. Adding it is three more perturbations of hot loops with no
row to show for them.

## `\w+\s+\w+`, and the ordering check nobody was paying attention to (2026-09-07)

With `[0-9]{2,4}` fixed, `two_words` was the widest row at 1.41x. It has **no
accelerators at all**: `\w` and `\s` are both too common for a skip set, there
is no literal and no prefix, so `init = NoInit`, `any_skip = false`, and both
passes are the bare DFA. The decomposition (min-of-40 in process, 256 KB):

| | ns |
|---|---|
| reverse sweep | 935000 |
| forward end pass | 1055000 |
| `find_all` | 2123000 |

and the sweep splits, by running the same loop shapes over an all-ASCII copy of
the haystack of identical length:

| | ns |
|---|---|
| the ASCII step alone | 491000 |
| + the non-ASCII arm, never taken | +0 |
| + the nullability read and its branch | +259000 |
| the 4950 real non-ASCII symbols | +61000 |
| the 210198 start appends | +155000 |

The sweep records **210198 starts for 21091 matches** -- four fifths of every
position in the haystack.

### Three levers, measured and dropped

- **Fusing the nullability read into `atable`** would take the 259000. Already
  tried and recorded above ("do not re-propose transition-entry tagging");
  not retried.
- **Pre-sizing the start accumulator.** 210198 appends growing from `[]` cost
  229000 ns in isolation; from `List.with_capacity(210198)` they cost
  **390000**, and from a haystack-sized reserve 315000. Reserving is worse in
  Roc, not better. Dropped.
- **Compressing runs of consecutive starts.** Only the leftmost of a
  consecutive run can survive `ends_fast`, which drops every start inside the
  previous match. Compressing 210198 -> 45917 gives the same 21091 matches and
  takes the end pass 1055000 -> 852000; done in the sweep it would also take
  most of the 155000 of appends. About 15% of the row.
  **It is unsound in general**, which is why it is not here: a start whose
  forward scan finds no end does NOT advance `next_valid`, so dropping its
  neighbour loses a match. Making it safe needs a gate saying the sweep is
  exact, which the engine does not compute, and the change lands in
  `collect_plain`, where every perturbation has cost ~4%.

Which leaves the 133000 ns that is neither pass.

### `is_descending` was 4% of the row and 6-12% of four others

`find_all_fast_opts` called `Dfa.is_descending(raw)` on every search: a full
pass over a start list four fifths as long as the haystack, to decide whether
`ends_fast` may walk it backwards in place. **87000 ns on this row**, and the
answer is a property of the automaton, not of the haystack. The sweep walks
right to left and appends `pos`; the only appends that can go backwards are
`nk_prev`, which records `pos` plus one symbol, and a pending state, which
records whatever its lookaround resolved to. So `ef_starts_desc` is set at
fold time when no state is either, and `starts_fast_opts` now GUARANTEES
descending output -- checking, and sorting on the rare failure, inside itself
instead of at the call site.

`any_skip : Bool` became `eflags : U8` to carry the second answer without
widening `Dfa.E`; a field added to that record has cost 1.1-1.3x before.

A/B alternating, min-of-10 to 14, against the previous commit:

| | restructure only | + the flag |
|---|---|---|
| `class_plus` | 0.987x | **0.916x** |
| `uni_letters` | 0.984x | **0.924x** |
| `two_words` | 0.967x | **0.923x** |
| `dotstar_lit` | 0.909x | 0.922x |
| `caps_email` | 0.991x | 0.948x |
| `literal_dense` | 1.013x | **1.075x** |

The first column is the same code with the flag forced off, so it isolates
moving the decision out of the procedure the whole scan inlines into: that part
is free. The flag itself buys another ~5% on the three dense rows and costs
~6% on `literal_dense`, a row that takes the literal override and never runs
this code -- the register-pressure lottery the hot-loop notes describe, once
more. It is 1700 ns against 420000, so it ships; recorded rather than hidden
because the row's ratio moves 1.02x -> 1.09x.

### Standing after both changes

| pattern | vs Rust meta before | after |
|---|---|---|
| `[A-Za-z]+` | 0.95x | **0.86x** |
| `\p{L}+` | 1.05x | **0.96x** |
| `(\w+)@(\w+)` | 1.04x | **0.98x** |
| `.*Holmes` | 0.55x | **0.50x** |
| `\w+\s+\w+` | 1.41x | **1.29x** |
| `[0-9]{2,4}` | 1.75x | 1.20x |
| `Holmes` | 1.02x | 1.09x |

Five of ten rows are now at or below Rust's meta engine. `\w+\s+\w+` is still
the widest at 1.29x, and what is left of it is the structural floor: 491000 of
reverse stepping and ~820000 of forward scanning is two passes over the text,
against Rust's 1545687 for the whole search.

Gates: corpus 331/331, fuzz plain 18000 cases 0 divergences, fuzz seed 42 16
divergences (pre-existing), node layer 57/57, skip differential 112/112, http
60/60, router 174/174.

**One caveat on the evidence.** A probe asserting `ef_starts_desc` implies a
descending sweep passes 376/376 over 47 patterns rich in anchors, `\b` and
lookarounds -- but it passes 376/376 with the gate REMOVED too, so it does not
demonstrate that out-of-order output is reachable on this path at all. Every
unbounded lookahead tried folds INCOMPLETE and goes to the threaded scan, which
still checks order for itself. The real evidence is the corpus and the fuzz,
which compare spans against the reference: a wrong order gives wrong spans.
