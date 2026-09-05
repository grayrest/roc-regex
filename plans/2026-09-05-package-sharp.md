# package-sharp — an RE#-style derivative engine as a companion to `Regex`

**Status: design interview complete 2026-09-05; NOT REVIEWED as a document.
Fifteen decisions. No implementation.**

Source under review: `~/Repositories/resharp-dotnet` (RE#, F#, POPL 2025 paper,
blog post `resharp_writeup.html` in that repo's root). Files read for this
record: `Types.fs`, `Algorithm.fs`, `RegexBuilder.fs` (all 3,221 lines of
rewrites), `Regex.fs` (the `llmatch` loop), `Optimizations.fs`, `Cache.fs`,
`Minterms.fs`, `Info.fs`, `Accelerators.fs`, `Patterns.fs`, `Common.fs`
(`ResharpOptions`), `docs/syntax.md`, `data/tests/*.toml` (331 cases), the
test project's `_05`/`_06` semantics harnesses. On the Roc side: `Rev.roc`,
`Regex.roc`, `Trie.roc`, `Teddy.roc`, `Lit.roc`, plan rev-2, every note under
`notes/`, and the perf-decision memory.

## Why a second engine rather than a change to the first

RE# is not a faster way to do what `Regex` does. It is a different
specification of what a regex means:

| | `Regex` (rev-2, shipped) | RE# |
|---|---|---|
| match semantics | leftmost-first (Perl/Rust priority) | leftmost-longest, `\|` is set union |
| captures | yes (PikeVM slots) | none; `(...)` is a group |
| lazy quantifiers | yes | none |
| boolean ops | `\|` | `\|`, `&`, `~(...)`, `_` |
| lookarounds | `\b`/`\B` in the DFA; `^`/`$` outermost | `(?<=R1)R2(?=R3)` normal form, negatives, and intersections of such |
| `^`/`$` | text anchors, `(?m)` opts in | always line anchors (`$` is `(?=\n\|\z)`) |
| empty match after a match | suppressed at the previous end (D14) | reported: `.*(?=aaa)` on `baaa` gives `[0,1],[1,1]` |
| construction | Thompson NFA → eager leftmost-first determinization, folded | Brzozowski derivatives → lazy DFA, mutated during the scan |
| oracle | Rust `regex` crate, 1512/1512 | RE# itself (no `dotnet` on this machine) |

Every row but "construction" is user-visible. So package-sharp is a **companion
API with RE#'s semantics and syntax**, shipped beside `Regex`, and nothing in
`package/` changes (S1). The one row that *is* about construction is where
RE#'s design collides with this project's thesis, and S3–S5 are about that.

## The shape

    pattern → AST (And/Not/Any, no Save, no lazy)
            → hash-consed regex nodes in a flat arena, rewritten on construction
            → derivative-based DFA: states = node ids, table = state×class
            → folded at build time up to a budget; extended lazily at runtime
            → llmatch: reverse sweep marks every match start, forward pass per
              start finds the longest end, non-overlap by skipping

Reused from `package/`, by copy (S8): `Trie` (the S1 partition *is* RE#'s
minterm set; the ≤64-atom bitset *is* its `UInt64Solver`), `Uni`, `Teddy`,
`Lit`, `Err`, and the hot-loop idioms of `Rev.roc` (dense `U32` table, fused
ASCII byte→state table, `U64` accept bitset, ASCII fast path, recursion with
scalar accumulators).

New in kind: the node arena and rewrite engine, the derivative function with
location-dependent nullability, the pending-nullable (lookahead `rel`)
machinery, the reverse sweep, a right-to-left SIMD scan kernel, and a runtime
path that mutates a folded table.

## Decisions

### S1 — Companion engine; `Regex` is untouched

A second public module (working name `Sharp`) with RE#'s semantics. Rejected:
*replacement candidate* — would force leftmost-longest and no captures on every
user, or require bolting priority semantics onto derivatives, which RE# does
not do and which is research; *perf experiment only* — too little to learn
about the design's real costs (lookarounds, boolean ops) from a subset.

### S2 — Three oracles: RE#'s TOML corpus, a brute-force reference, and real RE#

1. **RE#'s 331-case TOML corpus** (`data/tests/tests01…08`) ported verbatim as
   the floor. `tests07_unsupported` becomes the rejection corpus.
2. **A brute-force set-semantics reference in Roc**: for a pattern and
   haystack, enumerate substrings and decide membership by direct derivative +
   nullability over the *node layer* (no automaton), then apply the
   leftmost-longest non-overlap rule. It is the fuzz oracle, it speaks our
   alphabet (S6), and it is the only oracle that can define `_`/`~` over the
   `Invalid` class. It exercises the rewrite layer directly, which is why it
   is built before the DFA (S15).
3. **Real RE# via the .NET SDK**, installed for this purpose: a `tools/sharp-diff`
   generator in the shape of `tools/diff` emitting expectations from
   `ValueMatches`. UTF-16 offsets convert to byte offsets on valid UTF-8.
   Unicode cases are **excluded**: .NET's `\w`/`\d`/`\s`/case tables differ
   from our Rust-derived `Uni` tables and neither side is wrong.

Rejected: corpus + reference without RE# — a misreading of `llmatch`'s
details (empty-match reporting, `rel` encoding, anchor nullability at
`Begin`/`End`) would be baked into engine and reference alike.

### S3 — One engine: folded prefix, runtime extension

Exactly RE#'s own structure (`DfaThreshold = 100` states precompiled, then
lazy). The fold explores derivative states up to the budget (S12) and ships
the transition table **plus the node arena and interning index**. At runtime
a miss (`table[state, cls] == 0`) computes the derivative, interns the node,
appends a state row, and threads the updated record linearly through the scan.
If the fold **completed** — no unexplored frontier, no unbounded lookahead —
the arena is dropped and the artifact is a pure table, as `Rev.D` is today.

This replaces rev-2's D10 "over budget → downgrade to the PikeVM" with "over
budget → continue lazily", which keeps RE# semantics for every pattern.

Rejected: *eager only, unbounded lookahead is a compile error* (my
recommendation; the user chose completeness — RE#'s `a(?=.*b)` story is part
of what is being ported); *two engines* (eager table OR lazy interpreter) —
two scan loops and no precomputed states for the over-budget case; *lazy only*
— abandons the zero-runtime-compile axis the project exists to show.

**Why lookarounds force this.** A `LookAhead` node carries `rel` (characters
since the match ended) and a `pendingNulls` set of relative offsets; each
derivative step mints a new node with `rel+1` until the body resolves. For a
body with finite max length (`\b`, `$`, `(?=\W)`, `(?=aaa)`) the state space is
finite and eager exploration terminates. For `(?=.*b)` it does not; RE# calls
this an "infinite automaton" and bounds it by the input's longest line.

### S4 — Runtime state cap: evict and continue

RE#'s `MaxDfaCapacity` (100k) throws. Here, when the runtime portion reaches
the cap: keep the current state's node DAG, re-intern it into the arena reset
to the folded prefix, drop everything else minted at runtime, continue. This
is Rust's hybrid-DFA discipline. Bounded memory, no error arm on `find_all`,
never a wrong answer; the failure mode is slowness. **The corpus must contain
a case that forces eviction**, or the path ships untested (same rule as D10's
downgrade case).

Rejected: `find_all` returning `Try(_, [StateLimit])` — an error arm `Regex`
lacks, pushed onto every caller; `crash` — unacceptable under D1's
runtime-pattern admission.

### S5 — Cache lifetime: per-call, plus a threaded variant

`find_all : T, List(U8) -> List(Span)` cannot return minted states, so each
call restarts from the folded prefix. For a complete fold this costs nothing.
For an incomplete one, a caller looping over haystacks can use
`find_all_grow : T, List(U8) -> (T, List(Span))` (name provisional) and thread
the extended regex. Same engine, one extra function.

Rejected: per-call only — incomplete-fold patterns pay derivation on every
call; threaded only — every call site pays a tuple for the common case where
nothing was minted.

### S6 — `_` is the universal set including `Invalid`; `~` is the true complement

D3/D8's `Invalid` symbol class stays. `.`, `[^a]` and every ordinary class
still exclude it (D8 rule 2). `_` includes it, so `_*` means *any string* and
`~(_*x_*)` matches text containing undecodable bytes; De Morgan holds exactly.
The brute-force reference defines this; RE# (UTF-16, no invalid symbol) is
silent, so the dotnet diff runs on valid UTF-8 only.

Rejected: `_` excludes `Invalid` — then a string with a bad byte is in neither
`R` nor `~R`, and `~` is not a complement over the input alphabet.

### S7 — Anchors are RE#'s: `^`/`$` are line anchors, always

RE# parses with `RegexOptions.Multiline` unconditionally; `$` is literally
`(?=\n|\z)` internally and `^` is `(?<=\A|\n)`. `\A`/`\z` are the text anchors.
Matches the oracle and `tests04_anchors` (73 cases). Anchors are ordinary
nodes with location-dependent nullability (`LocationKind` Begin/Center/End)
and a separate end-transition table, so this costs nothing in the engine. The
divergence from `Regex` is documented at the top of the module.

### S8 — New parser; engine-agnostic modules copied, consolidated later

**Parser.** RE#'s grammar: `|` lowest, then `&`, then concatenation; `~(...)`;
`_`; `(...)` non-capturing; `(?=`/`(?!`/`(?<=`/`(?<!`; no `*?`/`+?`/`??`; no
`\1`; lookaround position validated after construction
(`mkConcatChecked`-style, S10 tier 3). The AST has `And`/`Not`/`Any` and no
`Save`/lazy flag. Copy `Comp`'s lexer, class parser, escapes and `\p{}`
lookup (~600 lines); write `parse_alt → parse_and → parse_cat → parse_repeat
→ parse_atom` fresh. Rejected: a mode flag on `Comp` — every consumer of
`Comp` gains unreachable arms and the packages couple at module level.

**Layout.** `./package-sharp/` is its own Roc package with its own `main.roc`.
`Trie`, `Uni`, `Teddy`, `Lit`, `Err` are copied (~900 lines duplicated) so it
builds and measures independently and its `Trie` may diverge (e.g. the
word-uniform split `\b` forces). A shared `package-core` is a refactor once
both engines are stable. Rejected: extract core first — changes the shipped
engine before package-sharp exists; cross-package relative imports —
unverified in Roc's packaging and not publishable.

### S9 — Flat arena, hand-rolled interning, `Rev.D`-shaped table

Everything that folds or mutates at runtime is `List(U32)`/`List(U64)` (D12
rule 3): nodes are `[kind, a, b, child…]` cells in one list with node id = cell
offset (`Or`/`And` variable arity; `Loop` = body, lo, hi; `Singleton` = tset
id; `LookAhead`/`LookBehind` = body, rel, pending-set id); parallel flat lists
for node info (flags byte, `SubsumedByMinterm` bitset, min/max length, pending
nullables as an offset into a flat `(s,e)` pair list); a flat open-addressing
hash table keyed on the cell slice for interning; DFA states as a dense
`state → node id` list with the `state*nc + cls` table, `0 = unexplored`,
plus the fused ASCII table and `U64` accept bitset from `Rev.D`. The whole
engine state is one record threaded linearly (the discipline the 2026-09-03
allocation work established: moved into each call, never held by a `var`
during it).

Rejected: Roc `Dict` for interning/transitions — whether it folds, at what
byte cost, and whether `Dict.insert` stays in place across function
boundaries at `--opt=speed` are unmeasured; it could not be an artifact shape
if it doesn't fold.

### S10 — All three rewrite tiers ship in v1

`RegexBuilder.fs` splits into: **tier 1**, the ACI normalization and
identities that make the derivative space finite (flatten/sort/dedup `Or`
and `And`, `⊥`/`ε`/`⊤*` rules, `~⊥→⊤*`, `~ε→⊤+`, right-assoc concat, loop
merging `a{m}a{n}`, sub 01/02, `ε|R→R?`, singleton merging `a|b→[ab]`, loop
range union); **tier 2**, subsumption behind RE#'s `MinimizePattern`
(`PredStar` containment, sub 013, sub 07, `mergeOrGroupedHeads/Tails/Loops/
NonZeroLoops`, `mergeOrIntersections`, `mergeOrLookaheads`, `mkLoop`'s
`(.*a){5}→(.*a){5,}`, the `⊤*·And(StartsWithTrueStar…)` rule); **tier 3**,
lookaround normalization (`mkLookaround` body normal form, adjacent
lookarounds merged into `&`, anchors folded into lookaround bodies,
`mkConcatChecked`'s mid-pattern rewrites and `UnsupportedPattern`
rejections, `mkNot` rejecting lookarounds and anchors inside `~`).

The user chose all three in v1 over my recommendation (tiers 1+3, tier 2
measured in rule by rule). Consequence: `_03_SubsumptionTests` and
`_13_OptimizationTests` are ported alongside as the rewrite corpus, and each
tier-2 rule still gets a state-count number on the bench patterns so its
effect on our alphabet is known, even though it ships regardless.

### S11 — API surface

`compile`, `unwrap`, `unwrap_labeled` (as `Regex`), `is_match`, `find_all`,
`count`, `find`, `replace_all`, `split`, `first_end`, `longest_end`,
`find_all_grow` (S5); byte API with `_str` conveniences mirroring
`Regex.roc`. `find` is **documented as a full sweep**: the reverse pass must
reach the haystack start to know the leftmost start, so it costs `find_all`
minus the list — RE#'s blog says the same of its own `Match`. `replace_all`
supports `$0` and `$$` only (no groups). `split` derives from `find_all`.
`first_end`/`longest_end` are RE#'s anchored-at-`\A` end finders. No
`captures`.

Rejected: an early-exit `find` — needs a forward leftmost-longest search,
which RE# does not have and which is not a port.

### S12 — Budgets

Fold-time state budget: D13 budget 4 as `Regex` computes it today
(`max_artifact_bytes / (nc × 4)`, 256 KB provisional), tracked during
exploration; reaching it ends exploration and ships the arena (S3) rather
than downgrading. D13 budgets 1–3 (pattern length 1,000, nest 250, node-count
limit) apply unchanged at parse/construction. Runtime cap: 100k states as RE#,
eviction on reach (S4). RE#'s `StartsetInferenceLimit` (2,000 `Or` nodes)
and `FindPotentialStartSizeLimit` (200) carry over as the accelerator budgets.

### S13 — Accelerators are derivative-driven, staged by measurement

RE# computes every accelerator from the node graph after rewrites, so it sees
through `&` and `~`, which AST extraction cannot. Port in RE#'s order of
payoff: **v1** the reverse-direction scan kernel (byte / range / literal,
right-to-left — RE# uses `LastIndexOf`; `Teddy`/`byte_scan` only run
left-to-right today) and the initial accelerator (`calcPrefixSets` →
`StringPrefix` / `SearchValuesPrefix` / `SingleSearchValuesPrefix`,
`calcPotentialMatchStart` → `SearchValuesPotentialStart`) wired to it. **Next**,
each against the bench suite: per-state `CanSkip` startsets (RE#'s
`isTooCommon` heuristics are tuned to .NET `SearchValues` and need re-tuning
against our kernels), `LengthLookup` (`FixedLength`, `RemainingSets`,
`SetLookup`, `FixedLengthPrefixMatchEnd`) for the forward end pass, and
`MatchOverride` for pure literals (memcmp path, already exists in `Regex`).

Rejected: everything in v1 — no signal on which matter on our alphabet;
reusing `Comp.prefix_of` — blind to `&`/`~`, a second extraction to keep in
sync.

### S14 — No spike gates; unknowns are measured as the work lands

The user chose to build and find out over gating on probes. The unknowns, and
what a bad answer costs, so nobody is surprised:

| # | unknown | if it fails |
|---|---|---|
| 1 | a record-of-`List`s engine state threaded linearly keeps `List.set` in place across function boundaries at `--opt=speed` (the open question from `notes/2026-09-02-pikemut.md`) | the lazy path copies the table per miss; S3 degrades to "complete folds only" and S4/S5 are moot until a Roc-level answer exists |
| 2 | a *folded* constant is refcount-immortal, so the first runtime `List.set` copies the whole arena once per `find_all` call | acceptable if the copy is lazy-on-first-miss (complete folds never miss); otherwise the incomplete-fold path pays O(artifact) per call and `find_all_grow` becomes the recommended entry point for it |
| 3 | the derivative engine is DCE'd from a binary whose folded regex is complete | artifact grows by the engine's code size for every user; measured by `tools/size/probe.sh` |
| 4 | fold cost (compiler RSS, build time) of eager exploration with the flat arena on the bench patterns and the 331-case corpus, inside D12's ~10 B RSS per artifact byte | S12's budget tightens, or interning/arena construction is reworked to append-only per D12 rules 1–2 |
| 5 | a right-to-left SIMD kernel (last set bit of `to_bitmask`, backward window stepping) | scalar reverse scan fallback; the initial accelerator still works, slower |

Each is reported with a number in `notes/` when first observed, in the style
of the existing notes.

### S15 — Build order: reference first

- **M1 — node layer + reference.** Parser (S8); flat arena and interning (S9);
  rewrite tiers 1–3 (S10); `derivative`/`isNullable` with `LocationKind`; node
  info inference (`Flags`, `SubsumedByMinterm`, min/max length, pending
  nullables); reverse-pattern construction (`RegexNode.rev`); the brute-force
  reference (S2.2). Gate: all 331 TOML cases pass **through the reference
  alone**; `tests07_unsupported` rejects; `_02_NodeTests`/`_03_Subsumption`/
  `_04_Derivative` ported as node-layer tests.
- **M2 — eager automaton + llmatch.** State exploration under S12, folding at
  compile time; `HandleInputEnd`/`HandleInputStart` anchor and pending-null
  handling; the reverse sweep collecting starts (`collect_noskip`); the forward
  end pass (`end_lazy`) with `NullKind`; non-overlap; `find_all`/`count`/
  `is_match`/`find`/`replace_all`/`split`/`first_end`/`longest_end`. Gate:
  corpus via the DFA; fuzz vs reference at a stated size with zero
  divergences; the bench suite grows `sharp_*` rows (on the nine current
  patterns leftmost-first and leftmost-longest agree, so the harness's
  match-count parity check still holds); artifact sizes via `tools/size`.
- **M3 — lazy extension.** Runtime miss handling, interning at runtime,
  eviction (S4) with a corpus case that forces it, `find_all_grow` (S5);
  unknowns 1–3 measured. Install the .NET SDK; `tools/sharp-diff` (S2.3) on
  ASCII patterns.
- **M4 — accelerators** (S13) in payoff order, each with a bench row before
  and after.

## Assumptions, stated so they can be wrong

- **Unicode tables are `Uni`'s** (Rust-derived), not .NET's; `(?i)` reuses
  the existing case-fold expansion. This is the reason the dotnet diff is
  ASCII-only.
- **`\b`/`\B` are RE#'s lookaround anchors** (`(?<=\w)(?!\w)|(?<!\w)(?=\w)`
  via `_nonWordLeft`/`_nonWordRight`), which requires the partition to be
  word-uniform when a boundary is present — the same `ranges_w` fold `Comp`
  does today. RE# credits its `\b` speed to this encoding.
- **The reverse sweep records every match start**, including starts of
  overlapping matches later skipped (`\w+` on prose: one entry per interior
  position). O(n) list, as RE#'s `ValueList<int> acc`. Accepted.
- **For an unbounded-lookahead pattern the fold still explores up to budget**;
  states reached on short contexts are the common ones and are worth
  precomputing.
- **`compile` vs `compile_with(config)`** follows D2: every `compile_with`
  argument must be a compile-time constant or the fold silently becomes a
  runtime compile.
- **`Str.from_utf8` on `replace_all_str`/`split_str` cannot fail** for the
  same reason as D15: spans land on symbol boundaries. `Invalid` runs are
  symbols, so a split at an `Invalid` boundary in a `List(U8)` haystack is
  fine; the `_str` layer only ever receives valid UTF-8.
- **Module name `Sharp`**, package `roc-regex-sharp`. Unimportant, easy to
  change, stated so it is not re-decided.

## What "done" means for v1

`compile`, `unwrap`, `is_match`, `find_all`, `count`, `find`, `replace_all`,
`split`, `first_end`, `longest_end`, `find_all_grow` over `List(U8)` with byte
offsets and `_str` twins; RE#'s syntax including `&`, `~`, `_`, negative and
positive lookarounds in normal form, `\b`; 331/331 on the ported corpus via
the DFA; a fuzz campaign of stated size against the brute-force reference
with zero divergences; the dotnet diff at zero divergences on its ASCII
subset; an eviction-forcing case in the corpus; `sharp_*` rows in
`tools/bench` with the same parity check; artifact sizes for a complete fold
and for an incomplete one published; unknowns 1–5 each with a recorded
number.

## Deferred, with the reason

- **Shared `package-core`** — after both engines are stable (S8).
- **Tier-2 rewrite pruning** — all rules ship (S10); dropping any is a later
  measurement, not a v1 question.
- **A forward leftmost-longest `find`** — not an RE# algorithm (S11).
- **Captures** — RE# has none; `(?<=ab)cd(?=ef)` is its answer for one group,
  and `Regex` exists for the rest.
- **Lookarounds inside `~`, unions of lookarounds, mid-pattern lookarounds
  outside the `mkConcatChecked` rewrites** — RE#'s own unsupported set,
  rejected with RE#'s messages. The Rust RE# port reportedly supports a wider
  fragment; not in scope.
