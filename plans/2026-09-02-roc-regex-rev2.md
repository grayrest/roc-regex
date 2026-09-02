# roc-regex rev-2 — Rust's regex crate over a codepoint alphabet, with the AOT step replaced by constant folding

**Status: NOT REVIEWED as a document. Fifteen decisions. No implementation.**

Rev-2 folds [rev-1](2026-09-01-roc-regex.md) and its fourteen in-place
amendments into clean decisions. Rev-1 is the record: written from one design
interview, reviewed 8× across two adversarial rounds (round 1: 7 fatal, 32
major, 18 minor; round 2: FATAL on coherence, FLAWED on the codepoint design,
OVERSTATED on the measurements), and superseded because the amendments made it
unreadable, not because they made it wrong.

> **What changed between revisions, in one paragraph.** Rev-1's central
> decision — a byte-oriented automaton — was **reversed**. It was wrong in
> exactly the way it argued it was right: it claimed compile-time folding
> answers the state-explosion objection to UTF-8 automata. Folding does not
> answer it, it relocates it. 99.1–99.7% of the states of a `\w`-family byte DFA
> are UTF-8 byte-sequence bookkeeping. Everything else in rev-2 follows from that
> one correction or from a review finding.

Evidence, in the order it was taken:
[fold probes](../notes/2026-09-01-fold-probe-log.md) ·
[adversarial review r1](../notes/2026-09-01-adversarial-review.md) ·
[construction rules](../notes/2026-09-02-fold-construction.md) ·
[codepoint alphabet](../notes/2026-09-01-codepoint-alphabet.md) ·
[D6/D11 re-measure](../notes/2026-09-02-d6-d11-remeasure.md)

> **Round-2 corrections applied to the numbers below.** The byte-alphabet fold
> rig used a fixed 256 stride, inflating byte-side artifacts ~2.6×, time ~1.66×
> and RSS ~1.43×; the figures here are the audited ones. The codepoint size
> figures now include the per-pattern class trie, which rev-1 omitted entirely.
> Two rev-1 throughput numbers were measured on loops that never left their
> start state and are struck. Where a claim is an estimate, it says so.

## Why

Rust's `regex` compiles patterns at runtime. Getting a pattern compiled ahead of
time needs a proc macro, a build script, or a serialization mode —
`regex-automata` ships `dfa::dense::DFA::to_bytes_little_endian` precisely
because there is no other way to get a table into a binary.

Roc evaluates pure expressions with compile-time-known arguments during the
build and stores the result in the executable. Measured: a `List(U64)` costing
10⁹ operations builds in 4.9 s and runs in 0.006 s; an invalid input reaching a
`crash` during that evaluation **fails the build with the crash message**. So a
regex library written as ordinary pure Roc gets ahead-of-time compilation and
compile-time pattern validation with no macro, no build step and no second mode.
The same `compile` serves a literal pattern and one read from `argv`; only the
literal one folds.

Rejected, and rev-1 never named them:

- **Bindings to the Rust crate.** Loses compile-time validation and the pure-Roc
  story, and adds a platform dependency. Folding is the whole argument against
  it, and the argument should be made rather than assumed.
- **Porting `regex-lite` instead** (9,717 lines, already pure/scalar/PikeVM-only
  with no unsafe). This was the right question to ask when the DFA looked
  unaffordable over bytes. Over codepoints the DFA is affordable by three orders
  of magnitude, so the full-crate target stands. **If D2 is ever abandoned,
  reopen this before anything else** — without the DFA this project is
  `regex-lite` with a longer parser.

## The shape

    pattern → AST → HIR → Thompson NFA over codepoint classes → { PikeVM, dense DFA }

Four things differ from the original, all forced:

1. **A codepoint alphabet, not bytes.** See D3. This is the deepest divergence
   and everything else follows it.
2. **No lazy DFA.** `regex-automata`'s hybrid engine mutates a state cache during
   the search; a pure function cannot. Replaced by eager determinization under
   budgets — affordable because the folded case pays at build time, which is why
   laziness existed at all.
3. **No SIMD.** `src/builtins/simd.zig` is internal to the compiler's builtins;
   there is no user-facing vector type. Every prefilter is a scalar loop.
4. **No unchecked indexing.** `list_get_unsafe` exists as a low-level but is not
   reachable from Roc. The inner loop is `List.get` returning a `Try`. **This
   port will not approach Rust's throughput and should not be sold as if it
   might.**

## What is measured

| claim | measurement |
|---|---|
| compile-time evaluation is real, unbudgeted | 2×10⁹ iterations: build 9.91 s, run 0.172 s |
| heap values fold and reach runtime | 100-elem `List(U64)`, 10⁹ ops: build 4.93 s, run 0.006 s |
| folded lists are packed at element width | `U32` 1M elems → 4.00 B/elem of binary |
| folding stops at the first runtime argument | `f("lit", runtime)`: build 0.29 s, **run 0.62 s** |
| a fold crash is a build error | `✗ compile time crash`, quoting the message |
| **byte→codepoint state collapse** | `\w{10,20}`: 38,505 → **79** states; 19,714,560 → **1,264** bytes (one rig, both directions) |
| **Unicode `\b` over codepoints** | 4,810,141 differential checks vs the crate, **0 disagreements** |
| **pattern IDs at N=1** | identical states, bytes, time, state-key bytes |
| **fold cost, 276-char Unicode pattern** | byte 1.66 s / 745 MB → codepoint 0.31 s / 140 MB |
| construction: concat vs append | 4,608 chars: 6,232 MB → **248 MB**, byte-identical binary |

**Not measured, and it gates D10:** the artifact size of a realistic pattern
*including* the per-pattern class trie, and therefore what `max_artifact_bytes`
should default to. See M1's gate.

## What "done" means

v1 is `compile`, `compile_with`, `is_match`, `find`, `find_iter`, `captures`,
`replace`, `replace_all`, `replacen`, `replace_with`, `replace_all_with`,
`split`, over `List(U8)` haystacks with byte offsets, Tier A Unicode, and:

1. the **reachable corpus subset** — recounted over codepoints before M1 and
   named as one number (rev-1 carried three irreconcilable counts, and 92
   `\b{start}`/`\b{end}` cases became reachable when D3 reversed) — passing on
   **both** paths;
2. a differential campaign of a stated size against the Rust crate with **zero**
   divergences, with invalid-UTF-8 haystacks **excluded by construction** (D8
   explains why there is no oracle there);
3. SR4's pre-registered throughput floor, met;
4. SR1's artifact budget and SR2's RSS budget, met for a named ten-pattern
   program, with the numbers published;
5. `Regex.compile("(a")` failing the build with a message that names **which**
   pattern — the project's most distinctive feature, asserted in M1's gate.

**Abandonment criterion**, attached to M1 and denominated on **artifact size**
(re-denominated 2026-09-02): if the **p90 artifact across M1's gate set exceeds
1 MB per pattern**, the folded-DFA story does not hold and this is `regex-lite`
in Roc — a runtime engine with compile-time validation — and should be pursued
as one.

It was previously denominated on SR2's 500 MB of compiler RSS, which **cannot
fire**: every codepoint fold on record sits 2–5 MB above a 137 MB baseline, two
orders of magnitude inside the line. A criterion that passes by construction is
not a criterion, and unverified item 1 hung on it.

## Stop rules

Each names a threshold, a measurement and the moment it is evaluated.

1. **Artifact size.** Measured as forward table + reverse table + class trie, at
   M1's gate and at every corpus run. **Threshold to be set from M1's gate
   measurement, on the p90 of the corpus pattern set, not the median** — a
   blowup mode must be read on the tail. Rev-1 retired its size stop rule on a
   sentence its own text falsified; there must be one, and it must be
   denominated on the whole artifact.
2. **Peak compiler RSS.** `/usr/bin/time -l`, cold, `--no-cache`, against the
   stated 137 MB baseline. A realistic pattern folds within **500 MB above
   baseline**, or stop.
3. **Compilation and searching never share a call expression.** Mechanical, in
   CI from M1: no public function takes a pattern and any non-literal-typed
   second argument. Note the exemption — D9's runtime-path suite deliberately
   constructs the forbidden shape — and note that the naive form of this test
   misses `compile_with(lit, runtime_budget)`, which is why the rule is stated
   over argument *types*.
4. **Throughput floor**, pre-registered before M1: a named haystack, three
   pattern classes, MB/s, the PikeVM baseline, and the multiple the DFA path
   must clear. Without it, D2, D5, D10 and M4 are unfalsifiable and can never be
   cut on evidence. Pre-registered from the Roc reference points — a codepoint
   DFA loop at ~468 MiB/s on 8 MB, a byte-set prefilter at ~1,141 MiB/s — with
   the DFA multiple stated as **a claim M3 must clear, not a number M1
   discovers**. M1's gate does not set it (see M1). Fill in the haystack, the
   three pattern classes and the multiple before M1 starts; the caveat on those
   reference points is unverified item 7.
5. **The folded path stays covered.** `expect` does not fold (D9), so folded
   coverage is a generated *program*. If it is dropped for build-time reasons,
   stop.
6. **The folded path's envelope is documented and enforced.** The compiler's
   parser stack aborts between **4,500 and 4,600 characters**, alphabet-
   independent, at ~376 MB, with no file, no line, and the last-named definition
   being one that succeeded. D13's pattern-length budget is set below it and
   applies to **both** paths — nothing lets a function know it is being folded, so
   a folded-only limit is not implementable.

## Build order

**M0 is done.** Its result was the alphabet reversal. Recorded for the next
time: it was hours of work that rewrote the project's central decision, and it
was run for the wrong reason (nothing downstream depended on it).

- **M1 — vertical slice. DONE 2026-09-02** ([gate](../notes/2026-09-02-m1-gate.md); commits `5ff5640`, `aa91b7f`). Subset parser, error type and renderer (D7), Thompson
  NFA over codepoint classes with pattern IDs threaded, class trie, PikeVM,
  `find` and `is_match`, one path, ~15 hand-written cases. Construction rules
  (D12) and budgets (D13) from the first line — they are not retrofittable.
  **Gate — passed.** 21/21 smoke cases (incl. a non-ASCII range through the
  trie); 3 named patterns fold in 1.65 s at ~43 MB above baseline RSS and
  68 KB artifact (~23 KB/pattern), inside SR2 and the 256 KB budget; the bad
  literal fails the build with the rendered caret. Owed: the per-object artifact
  split before SR1's threshold is set. *Original spec:* *Pattern set:* the ~15 hand-written M1 cases
  plus three named production-shaped patterns at 250–300 characters — an Apache
  combined-log matcher, an email-shaped pattern, and a `key=value` extractor —
  named in the repo so the measurement is reproducible by someone else. Three
  Unicode-bearing patterns keep the gate off the ASCII floor, where the trie is
  4,992 B against 38,272 B for `\w{10,20}`, a 7.7× spread.
  *Measurements, per pattern:* fold wall time; peak compiler RSS via
  `/usr/bin/time -l`, cold, `--no-cache`; and artifact bytes **broken out by
  object** (trie / NFA / total) — the split, not the total, is what M2's trie
  fork needs.
  *Passing:* every pattern folds inside SR2's 500 MB; the artifact p90 across the
  set is under the provisional 256 KB; and a deliberately bad literal fails the
  build with a message naming which pattern.
  *What it sets:* SR1's threshold, from the p90, marked provisional until the
  corpus exists at M1.5. **It does not set SR4's floor** — a PikeVM-only
  milestone has no DFA to measure a multiple against.
- **M1.5 — DONE 2026-09-02** (`bda281e`). The rest of the v1 surface. `captures`, `find_iter`, `replace*`,
  `split`, empty-match handling (D14), the two-path corpus generator (D9) and the
  differential harness.
- **M2 — Unicode Tier A. DONE 2026-09-02** (`aa0369b`; [note](../notes/2026-09-02-m2-unicode.md), partial \p{} coverage). Table generator → packed literals + folding decoders;
  HIR class expansion, class set operations, simple case folding. `range_trie.rs`
  and `utf8.rs` (~1,643 lines, the hardest code in the original) are **not
  needed** — D3 deletes UTF-8 automata.
- **M3 — determinizer and dense DFA. DONE 2026-09-02** (`14fa8f0`; [note](../notes/2026-09-02-m3-dfa.md), forward DFA for is_match; reverse pass deferred). Forward and reverse tables over M2's class
  pass, D5's three passes and its 8 start configurations, D11's forward-only
  pattern IDs, D13 budgets 4 and 5, D10's downgrade and its `engine` field's
  `Dfa` arm, D8's determinizer flag combinations. The differential fuzzing
  campaign runs here.

  **Read as M3, not as general:** D5 in its entirety (start-state configuration
  is a DFA concept; a PikeVM evaluates `Look` assertions per position and needs
  none of it), D11's body, D13 budgets 4–5, and D10's downgrade. M1 needs only
  `Match{pid}` in the NFA and an `engine` field that is always `PikeVm`.
- **M4 — prefilter seam. DONE 2026-09-02** (`4aa1892`; [note](../notes/2026-09-02-m4-prefilter.md)). `find_candidate` with the two scalar rungs D6 keeps.

## Decisions

### D1 — Runtime patterns are supported; one API, one code path

Rejected: compile-time-only, which makes "grep a user-supplied pattern"
inexpressible; and separate entry points for folded and runtime patterns, which
is the mode this project exists to avoid.

**Known false at the failure boundary, and stated rather than hidden.** The
folded path's envelope is *smaller* than the runtime path's: non-tail recursion
aborts the compiler between 4,500 and 4,600 pattern characters where the runtime
path handles far more, and the abort has no source location. D13's limits are
therefore set for both paths at the folded path's ceiling — the runtime path
loses capacity to protect the folded one. This is a real cost of "one code path"
and the alternative (a folded-only limit) is not implementable.

### D2 — PikeVM spine, eager dense DFA, under budgets

The lazy DFA is impossible under purity. Eager determinization replaces it and
is affordable **over a codepoint alphabet** — over bytes it was not, and rev-1's
claim that folding made it affordable was false.

Rev-1 also claimed eager determinization is "strictly better for a folded
pattern — no cache, no laziness, no per-search state". That was false over
bytes: Unicode `\b` forces a quit set whose search-time `Err(Quit)` on the first
non-ASCII byte would have required a PikeVM co-resident in every artifact. Over
codepoints there is no quit set and the claim holds.

The budget is a caller argument, since nothing lets a function ask whether it is
being folded: `Regex.compile(pattern)` takes conservative defaults,
`Regex.compile_with(pattern, config)` for the folded case. **Every argument to
`compile_with` must be a compile-time constant** — a budget read from config
silently converts the AOT engine into a runtime one, measured, with no
diagnostic.

### D3 — Codepoint-oriented automaton; `List(U8)` haystacks; byte offsets

Transitions are over **codepoint equivalence classes**, measured at 2–9 per
pattern. Rev-1's byte orientation is reversed: 99.1–99.7% of a `\w`-family byte
DFA's states are UTF-8 bookkeeping (`\w{10,20}`: **38,505 → 79** states,
forward+reverse, from the verified prototype), and no
table encoding rescues it — sparse gets 3.8× at 2.8–6.4× search cost, row
deduplication saves a median 2% and is sometimes negative, stride padding is a
median 11.7%.

`utf8.rs` and `range_trie.rs` are deleted. `util/utf8.rs`'s `decode`/
`decode_last` are still needed and are now on the hot path.

**The class lookup is part of the decision.** A two-level trie with a 128-entry
direct ASCII fast path measured 1.96 ns/codepoint against a byte loop's 1.95
ns/byte; a binary search over the packed range list costs 14.2 ns/codepoint.
**Both figures come from loops whose tables were never exercised** (13 of 19,959
rows touched); the honest reading is that the trie is not the bottleneck and the
comparison understates the byte side, whose real cost with an exercised table is
10.6 ns/symbol. The packed range list is the right storage format and the wrong
lookup path.

*Rev-1 published this pair as "19,959 → 59", assembled from two different rigs
— a `regex-automata` `dense::DFA` sweep and the prototype — whose byte-state
counts for this pattern differ by 1.93× under different builder configs, and
whose codepoint figure came from hard-coded constants in a third. The pair above
is self-consistent from one rig. The two rigs are still unreconciled; it does
not move the conclusion, and it should not be quoted as if it did.*

**The class trie is per-pattern and is the largest object in the artifact:**
38,272 B for `\w{10,20}` against a 544 B transition table, 4,992 B floor for
`[a-z]+`. Rev-1's size figures were transition-table bytes only and omitted it
entirely; the honest byte→codepoint win is roughly **48×, not 324×** — a
measured byte median of 2,158,336 B against an estimated codepoint table plus a
measured 38,272 B trie. That figure is part estimate and stays one until M1's
gate measures a real artifact.

**Undecodable bytes get an explicit `Invalid` symbol class**, chosen over
dropping byte mode and over carrying two alphabets, so matching arbitrary
`List(U8)` is defined rather than undefined. Its rules are D8. **What is given
up:** patterns that address individual bytes —
`(?-u:.)`, `(?-u:[^a])`, `regex::bytes` semantics — about 40 corpus cases.
ASCII-only `(?-u)` patterns keep their meaning, verified.

**The alphabet is not monotonically better.** It has no 256-symbol ceiling: a
large non-ASCII *literal set* produces one singleton class per distinct
codepoint, and 1,000 CJK literals are 48,070,656 bytes over codepoints against
4,620,800 over bytes. Out of v1 scope, but SR1 must be able to see it.

**Resolved 2026-09-02: per-pattern at M1, shared expected to win, decided at
M2.** The alternative is a shared codepoint→atom trie (~103,680 B, folded once)
plus a per-pattern atom→class array (1,644 B) plus an exception list for cuts the
shared partition misses — `\p{Lu}+` needs 1,180, `(?i)Sherlock` needs **31**
(rev-2 previously quoted 3, its non-ASCII sub-count). The crossover is early:
per-pattern is ~45 KB against shared's ~106 KB at one pattern, and ~450 KB
against ~120 KB at ten. Most real programs hold several patterns, so shared is
the expected end state.

M1 builds per-pattern anyway, because it cannot build the alternative: the
exceptions are Unicode-driven and need M2's Tier A tables and HIR case folding,
and the exception *lookup* is unpriced — it cannot naively be a binary search,
which this decision already rejects at 14.2 ns/codepoint. The trie sits behind
`Regex`'s documented-unstable fields (D7), so switching is an internal change.

The cost: SR1's threshold is set at M1 against a per-pattern artifact and moves
if M2 switches. Its first number is provisional twice over.

### D4 — Unicode Tier A, tables as packed literals

`general_category`, `case_folding_simple`, `perl_word`, **`perl_space`** (`\s`
is `White_Space` and is *not* derivable from `general_category`), and
**`property_values` + `property_names`** for `\p{Letter}`-style canonicalization.
Not `property_bool`, scripts, age or the break properties. Later tiers ship as
separately-importable modules.

Tables ship as one packed string literal plus a pure decoder: the decoder's
input is a literal, so the definition folds unconditionally.

Case folding is correct as planned and needs **no orbit table** — verified,
`regex-syntax` resolves `(?i)` at HIR level into explicit ranges carrying the
full orbit, so the codepoint alphabet sees a plain range set.

`.` matches a codepoint; `(?-u)` restricts it to ASCII. Empty matches do not
split a codepoint (D14). An invalid-UTF-8 haystack is not an error.

### D5 — Three-pass search

Forward DFA finds the match end; reverse anchored DFA finds the start; an
anchored PikeVM over that span fills capture slots.

**Start-state configuration is not optional.** There is no single start state:
**8 configurations** over codepoints — the crate's six, with `WordByte` split
into ASCII-word and non-ASCII-word (7), plus `Invalid` (8) — times
anchored/unanchored, deduping in practice to about six distinct states.
Forward selects from the codepoint ending at `start`; **reverse selects from the
codepoint beginning at `end`**. Verified load-bearing: merging the word split
away produces 9,060 fuzz disagreements and thousands of forward/reverse
invariant violations.

**The EOI symbol is mandatory.** `$`, `\z` and `\b`-at-end are unimplementable
without it.

**The span handed to the capture pass is an index pair, never a slice.** Rust
narrows `Input::span` while keeping the whole haystack so look-around still
resolves against context; a `List.sublist` implementation flips every boundary
assertion at a match edge.

`starts_for_each_pattern` is **not** needed on the reverse DFA; the
`Anchored::Pattern` call sites that want it are the capture pass, which here is
a PikeVM where per-pattern starts are free NFA start states.

### D6 — aho-corasick's automaton is dropped; the prefilter seam keeps two scalar rungs

Rev-1's argument — "a folded DFA over `foo|bar|baz` already *is* that automaton,
denser" — is false, measured: at 5,000 dictionary literals AC's contiguous NFA
is 139,588 bytes against a dense DFA's 1,663,232 (11.9×), and D3's reversal
changes this by 0.06%.

Dropped anyway, for reasons rev-1 did not contain:

1. **In Roc it is slower than the engine it would accelerate.** A dense scalar
   AC measures **0.6–0.7× the codepoint DFA in all seven realistic literal
   sets** (re-run at low load; two rev-1 rows were load artifacts). AC is the
   last rung of `regex-automata`'s ladder because the five above it are SIMD;
   Roc inherits only the bottom.
2. **Its sparse form is inside the band D10 rejects.** 5.1× smaller per state
   for **6.4× slower** with a dense root row — at the top edge of D10's
   3.8×-for-2.8–6.4×, not outside it. Rust's better rate comes from
   dense-encoded top trie levels, bit-packed rows and unchecked indexing.
3. **Its three unique semantics are out of v1** — overlapping and all-matches
   need `MatchKind::Standard`, incompatible with leftmost-first; streaming needs
   a reader in the inner loop. All three are search-loop modes over an automaton
   D5 and D11 already build.

*Struck from rev-1: "AC's dense automaton buys 4% for 2,168× the table." That
loop never left state 0. Honestly walked it is 3.1× slower — which strengthens
the conclusion and destroys the sentence.*

**M4 keeps two rungs:** a lead-byte-set scan (2.4–6.1× for ≤3 literals with rare
lead bytes, break-even ~10, worse than naive by 30, and a **net loss at 0.68×
when the lead byte is ubiquitous**), and Rabin-Karp (1.0–1.6×, the only scanner
that degrades gracefully). **Rung selection must be decided from pattern-side
properties**, because the loss case is defined by the haystack and SR3 forbids
the compiled `Regex` from ever seeing one.

**Reopen only if** `RegexSet` or dictionary matching enters scope, or SR4's floor
names a many-literal alternation as required. Note the consequence for the
deferred Teddy work: Teddy holds an `aho_corasick::dfa::DFA` internally, so
"Teddy later" means re-adding the automaton.

### D7 — `compile` returns `Try`; the caller decides what an error means

    compile : Str -> Try(Regex, Error)

A literal pattern with a caller-side `unwrap` reaches the `crash` during folding
and **fails the build with the rendered message**; the same call with a runtime
pattern returns an ordinary `Err`. One function, one code path.

**`Error` is one record, not a pattern-carrying variant per kind:**

```roc
Position : { offset : U64, line : U32, col : U32 }   # offset BYTES, col CODEPOINTS
Error : { pattern : Str, at : [Whole, At(Span)], aux : [NoAux, Aux(Span)], kind : ErrorKind }
```

`Position` carries `offset` in **bytes** (for slicing) and `col` in **display
columns** (for the caret), because the compile-time formatter reflows on display
width. `at` is optional because D13's budget errors have no
offset. ~47 kinds, tracking `regex-syntax` names so the differential harness
maps 1:1, plus two this design creates: `UnicodePropertyNotInTier` (so a Tier B
property is distinguishable from a typo) and `ByteSyntaxUnsupported` (so D3's
~40 deferred cases are visible in the diff). Budget kinds carry **limit and
observed** — the caller's only remedy is to raise the budget and they cannot
size the raise without both.

**`kind` is public and matchable; `render` is the only supported way to produce
a message.** An opaque `Error` would make D13's budgets unusable, and is not
implementable today anyway (Owed upstream 2).

**Every field of `Error` and of `Regex` is documented as unstable** (decided
2026-09-02). Roc has no field privacy and the nominal type that would give it
segfaults the compiler, so the layout is public whether or not that is intended.
Documenting instability is the only lever available; it costs nothing now and
keeps M3 free to add the forward and reverse tables without a breaking change.
The cost is that it is a convention with no enforcement — a caller who reads the
fields breaks later and nothing warns them.

**Renderer contract.** The compile-time crash formatter reflows at **80 display
columns** (4-space indent + 76 of content), East-Asian-width aware, combining
marks counted as zero, wrapping at word boundaries and never splitting a
codepoint. With D7's `  | ` gutter and both `...` elisions that leaves a
**66-display-column** excerpt budget. The renderer emits a **window**, not the
pattern: the span's line if it fits, else a window measured in display columns,
snapped to codepoint boundaries, with ASCII `...` elision and a caret column
recomputed in display columns over the escaped text.

> **Corrected 2026-09-02.** Rev-2 originally said the formatter "hard-wraps at 80
> bytes, breaks mid-token, and splits UTF-8", giving a 72-**byte** budget. All
> three premises are false — measured, it never split a codepoint and it breaks
> at spaces — and 72 bytes rendered through a real compile-time crash produces
> the mangled, caret-detached output the rule exists to prevent. The unit error
> also mattered on its own: a codepoint column puts the caret **12 columns left
> of target** on CJK. Escape tabs and controls before
windowing. `render` is total and bounded. Ship `Regex.unwrap` and
`Regex.unwrap_labeled` — with three top-level regexes all reporting at
`file:1:1`, a caller-supplied label is worth more than the caret.

**No partial operations on the compile path — a code rule, not a caveat.** Roc
cannot catch a crash, so an internal `List.get` fallback or an arithmetic
overflow becomes an unattributable compile-time crash on a random line of the
user's `main!`. Every compile-path access is defaulted; every state-id, offset
and counter arithmetic is checked and converted into a budget error.

Two facts to design around: a compile-time crash **still emits a binary and
exits 1**, and one bad pattern is reported **twice** — so the message must be
self-sufficient both times.

### D8 — `Invalid` symbol semantics

D3 adopts the class; this is what it means. **There is no oracle**: Rust's `\b`
runs a reverse byte DFA that sees word-ness *through* a stray continuation byte,
which no codepoint model reproduces. So this is a **written spec tested against
itself**, and D9 excludes invalid-UTF-8 haystacks from the crate comparison.

1. **Extent:** one `Invalid` symbol is one non-continuation byte plus every
   continuation byte following it. Not `error_len`/maximal-subpart, which is
   measurably wrong — it puts a boundary at offset 1 of `b"\x80\x80"` where
   `util/utf8.rs:118` says there is none.
2. **No class edge accepts `Invalid`.** Ordinary `.` and `[^a]` do not match it.
3. **The unanchored prefix loop ranges over *all* symbols including `Invalid`.**
   Rust compiles it from `AnyByte`, not `(?s:.)`. Getting this wrong loses every
   match after the first bad byte — measured at 52× more divergences, and
   `\b\w+\b` on `b"\xFFabc\xFF"` returning nothing instead of `[(1,4)]`.
4. **`\b`, `\b{start}`, `\b{end}` treat `Invalid` as non-word.**
5. **`\B`, `\b{start-half}`, `\b{end-half}` are unsatisfied adjacent to it** —
   and suppression must key on **the consumed symbol as well as the look-behind
   value**. D3's original cost note ("a third look-behind value") is the wrong
   half: it alone makes the forward and reverse DFAs disagree 787 times. The
   determinizer flag has **four** valid combinations, not three.
6. **An empty match is reported at the start of every `Invalid` run.** Where
   that run begins with a continuation byte, this is a position
   `regex-automata`'s `util/utf8.rs:118-131` rejects as a boundary — and it
   occurs at offset 0 **and immediately after any valid codepoint**, not only at
   offset 0.
7. **Outside rules 1–6, behaviour on invalid input is undefined and untested.**
   Measured over a v1-scoped fuzz (12,000 patterns, 96,000 checks): rules 1–6
   account for most divergence from `regex::bytes`, and **2,254 checks (2.3%)
   are explained by no rule**, including non-empty span differences. Do not read
   this spec as total.

> **Corrected 2026-09-02.** Rule 6 previously read "a haystack beginning with a
> continuation byte reports an empty match at offset 0 where Rust does not."
> Both halves were wrong: `regex::bytes` *does* report it (the codepoint model
> instead misses one at offset 1), and the phenomenon is not confined to offset
> 0. Rule 7 is new, and is the honest statement of how far this spec reaches.

### D9 — Two-path corpus, differential harness early

**`expect` does not fold.** `roc build` ignores expects entirely; `roc test`
executes them at runtime, ~6× slower than native, and a bad literal pattern
inside an `expect` builds clean and fails only under `roc test`. So the two
paths are (a) `roc test` for the runtime engine and (b) a **generated program**
with top-level `re_k = Regex.compile(…)` bindings asserting at runtime, with
build time and artifact size confirming the fold happened. Rev-1's "generate the
suite twice into `expect`s" produced one path twice.

**Count the reachable subset before M1 and name one number.** Rev-1 carried
three (160, 166, 382) and all are stale: 92 `\b{start}`/`\b{end}` cases became
reachable when D3 reversed, D5 now specifies the start-state machinery the
`bounds` and `anchored` exclusions rested on, and D3 adds ~40 byte-granular
exclusions. Also note what the `\b` verification did and did not do: it mined
the toml files for pattern/haystack pairs and never read their declared match
kinds, bounds or expected spans, so "744 of 858 cases" is not corpus conformance.

The differential harness is built at M1.5, so the engine's interfaces are shaped
to make intermediate results extractable while that is cheap. **Invalid-UTF-8
haystacks are excluded from the crate comparison by construction** (D8).

### D10 — Dense table, budget denominated on the whole artifact

Dense over sparse: sparse needs a scan or binary search per symbol, bad in Rust
and worse without unchecked indexing. `U32` state ids; at measured state counts
of 16–79, width is no longer a size question.

**The budget is `max_artifact_bytes`, measured as forward table + reverse table
+ class trie + NFA program.** Rev-1 denominated it on the transition tables
alone, omitting the largest object in the design; rev-2 then added the trie and
omitted the NFA, which D5 makes resident in every three-pass search and D10 makes
the downgrade target.

**Provisional default: 256 KB** (decided 2026-09-02). Measured single-pattern
artifacts are ~45 KB, dominated by the class trie, so this is ~5× headroom for an
ordinary pattern while still firing on pathological ones — which it must, since
this decision requires a corpus case that actually triggers the downgrade. M1's
gate revises it; it is provisional precisely to break the circularity of a
default that only its own gate could supply.

**Exceeding it is a silent downgrade to the PikeVM with identical semantics —
and D13's budgets are the ones that `Err`.** The split is: D10's budget is a
*performance* limit (downgrade); D13's are *safety* limits (error). They must
carry distinct thresholds so they cannot fire on the same pattern.

**The downgrade needs observability**: `engine : [Dfa({ artifact_bytes : U64 }),
PikeVm]` on the compiled `Regex`, asserted by the corpus. In the folded case
both are compile-time constants. And the corpus must contain **one
single-pattern case that actually triggers the downgrade**, or the path ships
untested — every measured single-pattern artifact is far under any sane default.

### D11 — Pattern IDs from the start, forward DFA only, single-pattern API in v1

**The marginal cost for v1's single-pattern API is exactly zero** — identical
state count, table bytes, determinization time and state-key bytes, structurally
guaranteed because `PatternID::ZERO` is not encoded when it is the only id. So
"cheap now, expensive to retrofit" survives unconditionally.

**Thread pattern IDs through the forward DFA only.** All merging-prevention
lives in the reverse `MatchKind::All` DFA — 2.74× on a tokenizer set, 4.35× on a
Unicode set — and the reverse DFA never needs to know *which* pattern matched.
Building it without them validated at zero disagreements over 107,766 checks.
Forward-only costs 1.02–1.08×.

Rev-1's 14.1 MB figure was one direction over bytes and 99% UTF-8 bookkeeping:
twenty patterns are **118.2 KB** over codepoints for both directions, and
determinization falls from 119 s to 19 ms.

### D12 — Compile-time construction rules

Compiler-behaviour facts, not style. Compile-time evaluation frees nothing
during a root's evaluation, and every rule follows from that.

1. **Never `List.concat` a growing accumulator.** Quadratic: 4,608 characters
   costs 6,232 MB by concat and **248 MB** by append, byte-identical output.
2. **Never `List.set` a compile-time accumulator.** It copies the whole list and
   retains 3.8 MB *per call*. Emit forward-only with precomputed subtree sizes.
3. **Every folded artifact is a flat list of packable scalars.** `List(U32)`
   stores at 4.00 B/elem; a 5-variant tag union costs 12.0 B/elem and 982 MB of
   compiler RSS at 200k elements; `List(List(U64))` costs 116 B/elem and does not
   finish. No `List(Inst)`, no `List(record)`, no nested lists, no `List(Str)`
   crossing into the ConstStore. This rule was found in review round 1 and was in
   no rev-1 decision.
4. **The class trie is built with adjacent-only dedup** — compare each leaf block
   against its predecessor, pure forward-only append. Verified compatible with
   rule 2 and within 40% of full hash dedup.

With flat construction, N regex constants cost N × artifact storage and nothing
else (two patterns: 1.06×, not 1.91×), so there is no reason to serialize folds.

### D13 — Five budgets, checked during construction

D10's artifact cap is checked on the *result*; every explosion happens upstream
of it. `((a{100}){100}){100}` — twenty characters — is 1,020,205 NFA states and
61 s of determinization; Rust rejects it in 5 ms.

1. **Pattern length and AST node count**, while parsing. SR6 delegates the
   folded path's envelope to D13, and neither a nest limit nor an NFA size limit
   can see it coming: the parser stack aborts on a **flat** 4,600-character
   pattern whose nest depth is 1 and whose NFA is small. Without this budget SR6
   has no mechanism.
2. **AST nest limit**, while parsing.
3. **NFA size limit**, checked *during* expansion — expansion is where the
   multiplier lives.
4. **Determinizer state count**, checked *during* determinization. A finished-
   artifact cap cannot see 2,740,293 states coming; multi-pattern shapes that
   share an unbounded-class suffix grow ×5–7 per added pattern.
5. **Determinizer transient allocation**, bounding the build rather than the
   result.

**Defaults, decided 2026-09-02.** Pattern length **1,000** characters — real
production patterns top out around 250–300, the measured parser-stack ceiling is
4,500–4,600 on one rig, and frame shape moves that by 4× (49,859 frames small vs
12,292 fat), so the real ceiling of the real parser is unknown and 1,000 is the
number that does not bet on a measurement taken from a different program. Raise
it once CI bisects the actual abort point of `compile` (SR6). Nest limit **250**
and NFA size limit **10 MB**, both Rust's, the latter costing ~100 MB of fold at
D12's ~10 bytes of compiler RSS per artifact byte — inside SR2. Budget 5 is
deferred to M3: pure Roc cannot observe its own allocation, so it needs a proxy.

**Budget 4 is derived, not chosen:** `max_artifact_bytes / (stride × 4)`, tracked
incrementally during determinization, and **taking D10's downgrade terminates
determinization**. That control-flow ordering — not two hopefully-disjoint
constants — is what stops D10 and D13 from both firing on one pattern.

All five return `Err` through D7's `Try`, so a literal bomb fails the build with
a message and a runtime bomb returns an error. All five apply to both paths at
the folded path's ceiling (D1, SR6). D1 admits attacker-supplied patterns, so
without these the library is a remote DoS in any program that greps user input —
and because literals fold, a build-time one as well.

### D14 — Empty-match semantics

The iterator advance rule: keep `last_match_end`; if a match is empty and its end
equals `last_match_end`, discard it and re-search from **the next symbol
boundary** — one symbol step. An empty match at end of haystack is reported.

> **Corrected 2026-09-02.** Rev-2 originally said "`start + 1` byte — one byte,
> not one codepoint" and warned that a codepoint step "passes the corpus and is
> wrong". That is backwards. From a symbol start, `+1 byte` is either the next
> symbol or a position *inside* one; `util/empty.rs:106-125` gives only two
> reasons the per-codepoint step is unsafe — `(?-u:\B)` and a configurable line
> terminator — and D3 defers the first while D9 puts the second out of v1. The
> verified prototype steps one symbol (`inv/src/search.rs:150`), and it is the
> implementation that passed the corpus. The byte reading was also the only
> construction in this design capable of producing a mid-codepoint offset, i.e.
> the only thing that could fire D15's `crash`. Suppression
is **positional, not global** — `b|` on `"abc"` gives `[0,0],[1,2],[3,3]`.

Two rules rev-1 omitted: a **half match** has no start, so its discard condition
is offset equality with **no emptiness test** — and D5's forward pass produces
half matches. And under an **anchored** search a codepoint-splitting empty match
yields no match at all, with no re-search; D5's reverse pass and every
`bounds`-carrying search are anchored.

**`util/empty.rs` is a byte-alphabet artifact and is retired by D3** — the module
says so itself, and a codepoint automaton's positions are symbol boundaries by
construction. What remains is rounding a caller-supplied byte offset to a symbol
boundary. **Conditional:** if the ~40 deferred byte-addressing cases or a
configurable line terminator return, the re-search loop returns with them.

The advance rule must be an **internal loop inside `Iter.custom`'s step**, since
that API cannot emit `Skip`. So `find_iter`'s step is not a single search.

**D15's `replace` totality depends on this decision being right.** `""` split on
`"☃"` must give `["","☃",""]`; it is the one-line test that catches a breakage.

### D15 — `replace`, `split`, and the iteration primitive

`find_iter : Regex, List(U8) -> Iter(Span)` via `Iter.custom`. `Iter` costs ~20
ns/match against ~5 ns for a hand-written loop — invisible at realistic density,
and `take_first` early exit runs at baseline. `is_match` is a separate function
**for an engine reason**, not the `Iter` reason rev-1 gave: it skips D5's reverse
pass and the capture engine entirely.

The replacement mini-language is Rust's exactly, including the longest-parse rule
that makes `$1a` the group *named* `1a`, `${...}`, `$$`, empty expansion for
unknown references, and literal treatment of an unclosed `${`. **Interpolation
cannot fail**, which is what keeps `replace` out of `Try`.

Five functions, no `Replacer` abstraction (Roc has no ad-hoc polymorphism):
`replace`, `replace_all`, `replacen`, `replace_with`, `replace_all_with`, plus
`Regex.Bytes.*` twins. Keep Rust's no-`$` fast path as an internal optimisation —
under D5 it saves a whole PikeVM pass per match. `replacen(re, hay, 0, rep)`
means **zero replacements**; Rust's `replacen(_, 0, _)` meaning "unlimited" while
`splitn(_, 0)` means "nothing" is a contradiction not worth replicating.

The `Str` layer returns `Str`, not `Try(Str, _)`: every span lands on a codepoint
boundary, so splicing valid UTF-8 at those boundaries yields valid UTF-8, and the
internal `Str.from_utf8` failure is a `crash` that cannot fire if D14 is right.
The byte layer returns `List(U8)` and makes no UTF-8 claim.

`split` is Rust's, including every empty field — leading, trailing, and one more
field than matches. Lift the six worked cases verbatim as corpus.

**Open fork:** `replace_all` taking a plain `Str` matches Rust and the harness
but re-parses per call and **forces the group-name table into the folded
artifact**, since the library cannot know which names a runtime replacement will
reference. A pre-compiled `Replacement` folds the parse and drops the name table
— this project's own thesis applied to `replace`. Needs a name-table size
measurement at M1.

## M1 specification

Written 2026-09-02 after a sufficiency review found M1 unbuildable as specified.
These are consequences of the decisions above plus the Rust source, not new
decisions. Where behaviour is taken from `regex-automata`, the file and line are
given so the port has a target rather than a description.

### S1 — Codepoint equivalence classes

Determined by D3, unwritten until now, and previously scheduled in M3 although
M1's NFA and trie both consume it.

Collect every range endpoint appearing anywhere in the pattern's HIR: for each
class range `[lo, hi]`, emit cut points `lo` and `hi + 1`; for each literal `c`,
emit `c` and `c + 1`. Add `0` and `0x110000`. Sort, dedup. Consecutive cut points
delimit the partition's atoms, and each atom is one equivalence class — every
codepoint inside it is indistinguishable to this pattern. Assign class ids in
atom order; `Invalid` (D8) takes the next id after the last atom, and EOI (D5)
the one after that.

The partition is **per-pattern**, which is what makes the class trie per-pattern
(D3). Rust's byte analogue is `util/alphabet.rs`'s `ByteClassSet`, driven from
`nfa/thompson/compiler.rs`; the algorithm is the same over a 0x110000-wide
alphabet instead of 256.

Measured class counts for real patterns are 2–9. Nothing bounds this in general:
a large non-ASCII literal set produces one atom per distinct codepoint (D3's
caveat), which is why D13's budgets are checked during construction rather than
after.

### S2 — Class trie layout

Three flat arrays, per D12 rule 3 (no nested lists, no records in the artifact):

| array | length | element | meaning |
|---|---|---|---|
| `ascii` | 128 | `U8` | class id, direct-indexed by codepoint. The fast path. |
| `l1` | 4,352 | `U8` | leaf-block index for `cp >> 8` over the whole 0x110000 space |
| `leaves` | `n × 256` | `U8` | class id by `cp & 0xFF` |

Total = `128 + 4,352 + n × 256` bytes. This reconciles exactly with the measured
figures: `\w{10,20}` at 38,272 B is n = 132, `[a-z]+` at 4,992 B is n = 2, and
D12 rule 4's adjacent-only dedup gives n = 185 → **51,840 B**, which is the
number to build against — the 38,272 figure uses full hash dedup, which rule 4
forbids.

**Constraint the layout implies and nobody has stated:** `l1` entries are one
byte, so a pattern is limited to **256 distinct leaf blocks**. `\w` already uses
185 under rule 4. A pattern exceeding it must widen `l1` to `U16` (+4,352 bytes)
— detect and switch rather than truncate.

Lookup: `if cp < 128 then ascii[cp] else leaves[l1[cp >> 8] * 256 + (cp & 0xFF)]`.
Three `List.get`s worst case, one on the ASCII path. This is the structure
measured at 1.96 ns/codepoint; a binary search over a packed range list instead
costs 14.2 (D3).

### S3 — NFA program encoding

D12 rule 3 forbids `List(Inst)`, so the program is a flat `List(U32)`, one word
per instruction:

    bits 31..28  opcode
    bits 27..0   operand

| opcode | operand | meaning |
|---|---|---|
| `0` Class | class id | consume one symbol if it is in this class |
| `1` Split | index into `splits` | two-way branch; preference order is arm 0 first |
| `2` Jmp | target pc | unconditional |
| `3` Match | pattern id | accept (D11 — `Match{pid}` is all M1 needs of D11) |
| `4` Look | `Look` variant id | zero-width assertion, evaluated against position |
| `5` Save | slot index | capture slot (M1.5; reserve the opcode) |

`Split` needs two targets and a word holds one operand, so split targets live in
a parallel `List(U32)` of pairs indexed by the operand. Emission is
**forward-only with precomputed subtree sizes** (D12 rule 2): compute each HIR
node's instruction count in a first pass, then emit in a second with all targets
known. Never `List.set` — back-patching retains 3.8 MB per call at compile time.

### S4 — `x*` compiles as `(x+)?` when `x` can match empty

The one measured correctness bug from the prototype: naive `x*` produced 394
fuzz disagreements before it was fixed. It lived only in a note's prose.

`nfa/thompson/compiler.rs:1275-1279`, verbatim: *"when implementing
leftmost-first (Perl-like) match semantics, `x*` results in an incorrect
preference order when computing the transitive closure of states if and only if
`x` can match the empty string. So instead, we compile `x*` as `(x+)?`, which
preserves the correct preference order."* (rust-lang/regex#779.)

So: if `x`'s minimum length is > 0, emit the simple self-looping union. Otherwise
emit `x`, then a union looping back to `x`'s start (the `+`), then an outer union
choosing between `x`'s start and empty (the `?`). Greedy uses `add_union`,
non-greedy `add_union_reverse` — the arms are the same, the preference order
flips.

This is not an optimisation. Getting it wrong passes most tests and produces
wrong capture positions and wrong leftmost-first alternation.

### S5 — The PikeVM without mutation

Rust's thread list is a `SparseSet` — a dense list plus a sparse index, both
mutated in place (`nfa/thompson/pikevm.rs:1996`, `ActiveStates`). Roc has no
mutation, and D12's rules govern compile-time construction, not the search loop;
the search loop's constraint is simply that it runs at runtime and must not
allocate per symbol more than it has to.

The pure form: carry the current thread list as a **sorted `List(U32)` of pcs**,
built once per input position by a fold over the previous list. Sorted order is
what replaces the sparse index — membership is a scan of a list whose length is
bounded by the NFA size and typically tiny, and preference order is positional,
so keeping it sorted by pc is wrong; **keep it in insertion order and dedup
against the list being built**. For M1's sizes a linear membership check is
correct and fast enough; if it shows up in SR4's numbers, replace the dedup
check with a generation-stamped `List(U32)` of size `n_states` rebuilt per
position.

Epsilon closure is an explicit worklist — a `List(U32)` stack folded until empty
— not recursion, because the compile path forbids deep non-tail recursion (D13
budget 1) and the search path would otherwise be unbounded in pattern nesting.

`Look` assertions are evaluated at the position, against the previous and next
symbol classes. M1 needs no start-state configuration; that is D5, and D5 is M3.

### S6 — Specimen error message

"A bad literal pattern fails the build naming which pattern" is M1's gate
criterion and the project's headline feature, so here is the target output.
Source: `Regex.unwrap(Regex.compile("(\\d{4}-\\d{2}"))` at a package boundary,
where the compile-time crash reports at `app.roc:1:1` with no source snippet
(D7), so the message is the entire diagnostic:

```
regex: unclosed group
  | (\d{4}-\d{2}
  | ^
  = expected ')' before end of pattern
```

With `unwrap_labeled("date", …)`, the first line becomes
`regex[date]: unclosed group` — which is why D7 ships it: with three top-level
regexes all reporting at `file:1:1`, the label identifies the pattern where the
file position cannot.

Rules, from D7: every rendered line ≤ **66 display columns**; the excerpt is a
window, not the pattern, snapped to codepoint boundaries with ASCII `...`
elision when cut; the caret column is computed in **display columns over the
escaped text**; tabs and controls are escaped before windowing. A long pattern
renders as:

```
regex: unclosed group
  | ...aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa(bbbbbbbbbbbbbbbbbbbbbbb...
  |                                    ^
  = expected ')' before end of pattern
```

## Deferred, with the reason

- **Teddy / `packed/`** — needs user-facing vector types, and re-adding AC's
  automaton (D6).
- **`RegexSet` public API** — needs D13's state-count budget and D11's
  forward-only rule; not "only the surface waits".
- **Unicode Tier B/C** — ~25k lines of table source for rarely-written
  properties. `UnicodePropertyNotInTier` (D7) makes the boundary legible.
- **`(?-u)` byte-granular patterns and `regex::bytes` semantics** — inexpressible
  over codepoints (D3); ~40 corpus cases, flagged by `ByteSyntaxUnsupported`.
- **One-pass DFA, bounded backtracker** — earn their place in Rust largely
  through constants unavailable without SIMD and unchecked indexing.
- **Sparse tables** — measured 3.8× smaller for 2.8–6.4× slower.
- **Overlapping / all-matches / streaming search** — search-loop modes over the
  automaton D5 and D11 build; not new machinery.
- **Lookaround, backreferences** — excluded, as in Rust, by the linear-time
  guarantee.
- **Opaque `Regex` and `Error` types** — wanted; currently crash the compiler.

## Asserted and not verified

1. **That the fold survives at library scale.** Measured only on rigs, never on
   a real engine. M1 is the test, and the abandonment criterion hangs on it.
2. **The `Invalid` class as specified in D8.** Rules 1–6 are a written spec with
   no oracle. Rule 3 and rule 5 were found by measurement; the rest are reasoned.
3. **`CustomLineTerminator` as a start configuration.** It is one of the crate's
   six and D5 carries it, but the verified prototype dropped it — so it is
   reasoned only, and D9 lists the 11 line-terminator cases as unreachable in v1.
4. **The shared-versus-per-pattern class trie fork** (D3), and therefore
   SR1's threshold and D10's default.
5. **The group-name table's size** (D15's fork).
6. **A 5-in-85,010 count divergence (0.006%)** between the codepoint prototype
   and AC leftmost-first at 1,000 literals, reproducible at 16 MiB and absent at
   4 MiB. **Not isolated.** An unexplained correctness divergence in the
   prototype that validates the alphabet.
7. **The locality benefit of a small table.** Every throughput rig so far touched
   ~20 rows and never exercised its footprint, in both directions.

## Owed upstream

1. **Feature request, the most valuable of these:** specialize a call on its
   constant arguments when other arguments are runtime. This is the missing
   partial-evaluation step behind D2's `compile_with` cliff, and every library
   that wants to exploit compile-time evaluation will hit the same wall.
2. **Bug — WRITTEN UP 2026-09-02**, ready to file:
   [`upstream/2026-09-02-nominal-methods-segfault.md`](../upstream/2026-09-02-nominal-methods-segfault.md).
   SIGSEGV in `postcheck/monotype/lower.zig:16175 instNodeContent` for **any**
   data-carrying nominal type with a methods block destructured by a lambda
   argument pattern. Reproduces in a single file (no package needed), for payloads
   `U64`, `Str`, a record and a tag union, and independently of folding. A `match`
   unwrap avoids the segfault but yields a spurious type mismatch on the
   constructor plus a compile-time crash attributed to the app header's platform
   URL. Checked against the tracker: nothing matching is filed.

   This is the bug behind D7's and D10's transparent records — see the note there.
3. **Feature request (rewritten 2026-09-02):** the compile-time crash formatter
   reflows the message on display width. It is well-behaved — word-wrapping,
   width-aware, never splitting a codepoint — but a library that renders its own
   caret diagram has to reverse-engineer the wrap to stay inside it. The ask is
   an opt-out: emit a crash message verbatim. *The earlier version of this item
   reported a byte-wrapping UTF-8-splitting bug that does not exist.*
4. **Feature request:** `Iter` has no `any`, `find_first` or `take_while`, which
   costs an API decision in D15 and is a far smaller ask than (1).
