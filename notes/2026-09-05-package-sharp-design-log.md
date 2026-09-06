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
