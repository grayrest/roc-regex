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
