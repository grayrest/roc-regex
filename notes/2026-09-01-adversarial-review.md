# Adversarial review of the 2026-09-01 plan — 4 rounds, all FLAWED

Four independent reviews, run the same day the plan was written, each on a
separate attack surface and each able to run its own probes rather than take the
plan's word: **premise**, **engine architecture**, **plan quality**,
**API/semantics**. Verdicts: FLAWED, FLAWED, FLAWED, FLAWED. Totals **7 fatal,
32 major, 18 minor**. Nothing here has been dispositioned.

Reviewer probe rigs live outside the repo, in the session scratchpad. The
numbers below are theirs, not the plan author's.

## The three findings that decide the project

### 1. Folding is bounded by compiler memory, and the plan measured time

A real pipeline — recursive-descent parser → nominal `Ast` → Thompson `List(Inst)`
→ `List(U32)` transition table — folded at increasing pattern size:

| pattern chars | table entries | binary | build | **peak RSS** |
|---|---|---|---|---|
| 18 | 3 840 | 407 264 | 0.27 s | 138 MB |
| 1 152 | 229 632 | 1 310 144 | 0.35 s | 528 MB |
| 4 608 | 917 760 | 4 068 048 | 1.10 s | **6 492 MB** |
| 9 216 | — | — | abort | — |

Build time is **sublinear** in artifact size (4× artifact, 3.1× time), so stop
rule 2's "build time grows faster than the artifact" can never fire, and 1.10 s
sits comfortably under its 2 s threshold — while RSS grows 12.3× and the next
step is unbuildable on a 16 GB machine.

The cause: **compile-time evaluation never frees.** A rig allocating and dropping
a 512-byte list per iteration retains 479 bytes per iteration. `List.concat` in a
build loop is quadratic in compiler memory where `List.append` is flat (400
chunks: 205 MB vs 138 MB). The identical pipeline on the **runtime** path builds
the same 917 760-entry table in **0.01 s and 7.24 MB** — a ~900× memory
amplification, folded versus run — and reaches sizes the folded path cannot.

Consequence for **D2**: `max_table_bytes` bounds the *artifact*. Determinization
allocates a state set per explored subset and reclaims none of it, so a pattern
whose final table is comfortably under budget can still cost gigabytes to build.
The claim that eager determinization is affordable "because the folded case pays
for it at build time" is an argument about time; the cost is memory, it is
superlinear, and D2 has no knob that bounds it.

Parallel folding makes it worse, not better: concurrent roots each hold an arena
that never frees, so peak RSS is the **sum** of live folds (two 128-unit patterns:
3 308 MB = 2 × 1 734 MB). The probe log recorded fold parallelism as a win.

### 2. M0's real number — eager determinization does not survive Unicode

Taken with `regex-automata` 0.4.18, forward + reverse `dense::DFA` in the meta
engine's own configuration:

| pattern | total bytes | build |
|---|---|---|
| `\w{10,20}` | **10 229 144** | 629 ms |
| `(?i)[\p{L}\p{N}_]{4,12}` | 6 151 736 | 345 ms |
| `\w{5}` | 2 947 224 | 150 ms |
| `[\w.+-]+@[\w-]+\.[\w.]+` | 2 099 992 | 209 ms |
| `\w+\s+\w+` | 1 264 920 | 84 ms |

Median of 26 Unicode-class patterns: 651 544 B — **under** stop rule 1's 1 MB
line, while **12 of 26 exceed it**. Over 61 mixed patterns: 13 over 1 MB, 29 over
40 KiB, which is the regex crate's own default full-DFA budget. Read on the
distribution rather than the median — which is how a blowup mode must be read —
**stop rule 1 fires.**

And **Unicode `\b` has no DFA at all**. `dfa/dense.rs:5108` refuses to build one;
the meta engine's workaround puts every non-ASCII byte in a quit set, producing a
haystack-dependent *search-time* failure:

    "\b\w+\b"  "hello world" -> Ok(HalfMatch { offset: 5 })
               "héllo wörld" -> Err(Quit { byte: 195, offset: 1 })

Rust catches this on every search (`meta/strategy.rs:713`) and re-runs the
PikeVM. **D10's downgrade is a build-time budget check** and has no path for a
DFA that builds clean, matches clean on ASCII, and errors on the first `é`. Every
DFA-backed `Regex` must therefore carry a complete PikeVM and its NFA
permanently, roughly doubling the artifact and falsifying D2's "strictly better
for a folded pattern — no cache, no laziness, no per-search state".

### 3. `expect` does not fold, so the folded path is tested by nothing

`roc build` ignores `expect` entirely (248 ms whether the module holds 2 or 8);
`roc test` executes them at runtime, serially, ~1.45 s each and ~6× slower than
native. A bad literal pattern inside an `expect` builds clean in 170 ms and fails
only under `roc test`.

**D9 has this exactly backwards.** The 858-case corpus as designed exercises the
ordinary runtime engine; the folded path — the reason the project exists — is
covered by zero tests, and stop rule 5 guards the wrong one. Folded verification
has to be a *program*: top-level `re_k = Regex.compile(…)` bindings asserting at
runtime, with build time and binary size confirming the fold happened.

## Findings by decision

### D1 — one API, one code path

**False at the failure boundary, twice.** The interpreter's 1024-call-depth cap
does not apply (`compile_time_finalization.zig:901` returns false on macOS arm64;
roots run as dev-backend machine code), but the compiler's native stack does:
30 000 deep for a thin frame, **5 000** for a fat one, and for a real parser
**8 000 pattern chars flat or 2 000 nesting levels**. The same inputs run fine on
the runtime path (24 000 chars, 4 000 deep). The failure is:

    The Roc compiler overflowed its stack memory and had to exit.

exit 134, no file, no line, no definition name — and when a slow fold precedes
it, the last thing named is the definition that *succeeded*.

Also missing: **no `nest_limit`, no NFA `size_limit`**. `((a{100}){100}){100}` —
twenty characters — is 1 020 205 NFA states and 61 s of determinization before
failing at a 4 GiB cap; the real crate rejects it in 5 ms
(`regex-1.13.1/src/builders.rs:53`, `regex-syntax/src/ast/parse.rs:141`). Because
D7 folds literals, that is a build-time DoS, and D1 makes it a remote one.

### D2 — eager determinization under a byte budget

Contradicted by findings 1 and 2. The budget bounds the wrong quantity, and the
population it was meant to rescue is the population it fails on.

### D4 — Unicode Tier A

`\s` is **not** in Tier A and is not derivable from `general_category`
(`White_Space` includes `Cc` characters); it needs `perl_space.rs`, 23 lines.
`\p{Letter}` / `\p{gc=Lu}` need name canonicalization —
`property_values.rs` (956) + `property_names.rs` (281) — without which only
`\pL`-style single letters work. `utf8.rs` (592 lines, `Utf8Sequences`) is a hard
prerequisite of D3 and appears in no milestone. `\d` is fine. **Case folding is
correct as planned** — the generated table already carries full equivalence
classes, no orbit table needed.

### D5 — three-pass search

Omits **start-state configuration** entirely: six configurations
(`util/start.rs:344`), forward chosen from `haystack[start-1]`, **reverse chosen
from `haystack[end]`**, multiplied by anchored/per-pattern. Without it `^`, `$`,
`\b`, `(?m)` and CRLF are wrong for any search not beginning at offset 0 — which
is every step of `find_iter` and all 44 corpus cases carrying `bounds`. Also
omits the **EOI symbol** (`util/alphabet.rs:311`), without which `$`, `\z` and
`\b`-at-end are unimplementable.

"An anchored PikeVM over **that span alone**" is a correctness bug if taken
literally: Rust narrows `Input::span` while keeping the whole haystack so
look-around still sees context (`util/search.rs:150`, the `\bat\b` / `"batter"`
example). A `List.sublist` implementation flips every boundary assertion.

### D6 — aho-corasick's automaton is subsumed

**Measurably backwards.** Over dictionary words:

| literals | AC NFA | regex dense DFA | ratio |
|---|---|---|---|
| 1 000 | 30 992 | 352 968 | 11.4× |
| 5 000 | 145 664 | 1 689 412 | **11.6×** |

The failure-link indirection the decision dismisses is what makes AC sparse.
Three further errors: leftmost-first answers one of AC's three match semantics
and is "fundamentally incompatible with overlapping searches"
(`dfa/automaton.rs:1540`); AC is the **fallback prefilter** M4 needs
(`util/prefilter/mod.rs:606`); and Teddy holds an `aho_corasick::dfa::DFA`
internally (`util/prefilter/teddy.rs:28`), so dropping the automaton breaks the
SIMD half D6 claims to keep.

### D7 — `compile` returns `Try`; caller decides

The mechanism survives, and **multi-line caret rendering does display readably**
in a build error. Two failures around it: across a package boundary, compile-time
crash attribution **collapses to `file:1:1`** — three top-level regexes, two bad,
both errors pointing at the `app` header, distinguishable only by message content
— so every `Error` variant must carry the full pattern text and offset, which
`UnclosedGroup(U64)` does not. And internal panics (arithmetic overflow, a
`List.get` fallback) surface as compile-time crashes on unrelated lines of the
user's `main!`; Roc cannot catch a crash, so the library cannot convert these
into `Error`.

### D8 — `Iter(Span)`

**Cost concern closed:** ~20 ns/match for the iterator against ~5 ns for a
hand-written loop, invisible at realistic density; `take_first` early exit runs
at baseline. Unverified item 5 is resolved and stop rule 4 is vindicated. But the
stated *reason* for a separate `is_match` is wrong — `Iter.next` is lazy and
early exit works fine; the real reason is engine-level (skip the reverse pass and
the PikeVM). Two shape constraints: `Iter.custom`'s `advance` cannot emit `Skip`,
and it has no error channel.

`replace`/`replace_all`/`split` are named as v1 with nothing specified — the
replacement mini-language (`$ref` with longest-possible-parse, so `$1a` is the
group *named* `1a`; `${ref}`; `$$`) is 536 lines in regex-lite; `Str.from_utf8`
returns a `Try`, so the `Str`-level return type is undesigned; and `split`'s
leading/trailing empty-field semantics are unstated.

**Empty matches** get one sentence covering roughly a quarter of the problem. The
iterator advance rule, the end-of-haystack match, positional (not global)
suppression, and `util/empty.rs` (265 lines, sitting *below every engine* in both
directions) are all missing. Supporting `(?-u)` and invalid-UTF-8 haystacks
inherits precisely the composition problem that module exists to solve.

### D9 — two-path corpus

Contradicted by finding 3. Separately, the "858 cases" target is unreachable:
two reviewers independently counted **160** and **166** cases needing search
modes v1 has no function for, and a third counted **382 (44%)** touching a
feature the plan never names — CRLF mode (108), `\b{start}`/`\b{end}` (92),
overlapping (77), `match-kind = "all"` (74), multi-pattern (59, explicitly
deferred by D11), `bounds` (44), anchored (39), line-terminator (11), earliest
(9), match-limit (5), POSIX classes (5), `(?x)` (1).

### D10 — dense, `U32`, byte budget

The dense/`U32` half **survives and is the right call** — folded `List(U32)`
stores at exactly 4.00 bytes/element. Three corrections: byte classes compress
~2.3×, not 6–50×, for Unicode patterns (`\w+` → 113 classes, one pattern → 140);
the size formula understates by up to 2× because stride rounds to the next power
of two, so alphabet 140 pays for 256 columns; and the silent downgrade has **no
observability** — no field, no diagnostic, no query — in the one case (folded)
where the answer is a compile-time constant.

### D11 — pattern IDs from the start

Pattern IDs are **part of the DFA state key** (`util/determinize/state.rs:20`) and
therefore prevent state merging. Twenty trivial `key\s*=\s*(\w+)` patterns
measured at **14.1 MB**. Cheap in the NFA and PikeVM as the plan argues; dominant
in the DFA the plan makes the headline. "Small constant cost" is not what the
numbers say.

### D12 — vertical slice

Not a decision — no rejected alternative, unlike every other entry. Eleven
decisions, not twelve. And M1 as scoped is not a slice: it is `regex-lite`
(measured **9 717 lines**, a finished shipping engine) minus Unicode, plus
pattern IDs, plus a two-path corpus generator, plus a cross-language differential
harness.

## Artifact-shape rule the plan never states

Only lists of **packable scalars** are cheap to store. Storage cost, not
evaluation cost — the same 200 000-element `List(Inst)` consumed to a `U64`
instead of stored costs 0.25 s / 142 MB against 1.27 s / 982 MB stored.
`const_store_writer.zig`'s `storeList` reaches `storePackedList` only when
`planIsScalar`; everything else gets a reserved `ConstNodeId` per element.

| artifact | bytes/element | note |
|---|---|---|
| `List(U32)` | 4.00 | |
| `List(U64)` | 8.00 | |
| `List(Inst)` 5-variant tag union | 12.0 | 982 MB RSS at 200 k |
| `List(Str)` | 23 | |
| `List(List(U64))` | 116 | DNF at 200 k |
| recursive nominal tree | 93.5 | 24 B of real data; depth 16 DNF |

**Every folded artifact must be a flat list of packable scalars.** No
`List(Inst)`, no `List(record)`, no `List(List(_))`, no `List(Str)` crossing into
the ConstStore. This belongs in D4, D10 and D11 and is in none of them.

## Confirmed, and worth keeping

- Packing at element width (probe log §8) — independently reproduced.
- All-or-nothing folding on arguments (§7) — reproduced, but the rule is
  **narrower** than the plan states: record fields, closures, higher-order
  arguments, `List.map`, and `Str.concat` of literals all fold. Folding is lost
  only when the pattern is threaded through a **parameter** of a call that also
  receives a runtime argument. The unguarded case is D2's own knob —
  `compile_with(lit, { max_table_bytes: runtime_budget })` silently stops folding.
- Folds are cached (§6), and **dedup and dead-stripping are both real**: identical
  artifacts store once even when the two call sites are syntactically different;
  an unreachable folded table costs zero binary and full build. Unverified items
  3 and 4 are resolved, both favourably.
- DFA minimization is correctly omitted — ≤4% saved for 12–120× the build time.
- `Str.to_utf8` costs ~0.35 ms/MB. The "convenience layer copies" claim is honest.

## Also owed upstream

Beyond the two the plan already lists: `const_store_writer.zig:1128`'s
`writerInvariant` is a bare `unreachable` in release builds across 36 call sites,
so any unstorable value shape is silent UB rather than a diagnostic. No reviewer
could reach one — `Dict`, `Box`, records carrying closures, `List(Str)` and a
top-level `Iter` all store correctly — but it is a latent hazard. And the missing
`Iter` combinators (`any`, `find_first`, `take_while`) cost an API decision in D8
and are a far smaller ask than partial specialization.
