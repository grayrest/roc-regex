# Scope: `\b` / `\B` in the determinizer (look-in-the-DFA)

Bringing word-boundary patterns onto the DFA fast path instead of the PikeVM
fallback. Motivated by the observation that our **codepoint alphabet** makes
Unicode `\b` *bakeable* into the DFA — the situation Rust enjoys only for ASCII
`\b` over its byte alphabet (Rust quits-and-falls-back on non-ASCII bytes for
Unicode `\b`; we would not have to).

## Current state

- `\b`→`Look(look_wordb=2)`, `\B`→`Look(look_nwordb=3)` compile to `op_look`
  (`Comp.roc:432`, `:907`). `^`/`$` are `look_start`/`look_end` (out of scope
  here, see below).
- `Rev.build` bails on **any** look: `if Rev.has_look(c.prog, 0) { Err(HasLook) }`
  → `engine = Pike`. So `\bthe\b` is the one benchmark pattern still on the
  PikeVM, and every look pattern misses the 12–71× DFA `find_all` win.
- `Rev.close_go` (the priority ε-closure) handles `split`/`jmp`/`save`/`match`
  and stops at `char`. It has **no `Look` case** — because build bails first.
- The reference semantics to match are `Pike.look_ok` / `word_before` /
  `word_after`: `\b` holds iff `is_word_cp(left_cp) != is_word_cp(right_cp)`,
  with off-the-ends treated as non-word.

## Why the codepoint alphabet makes this tractable

`\b` at a position depends on the word-ness of the codepoint on each side. Over
codepoints, word-ness is a property of a **single input symbol** — so the DFA
can carry "was the entering codepoint a word codepoint?" as one bit of state and
resolve `\b` inside the transition function, exactly as Rust bakes ASCII `\b`
into its byte DFA. No quit bytes, no fallback, correct on all input.

## The mechanism (three coordinated changes)

### 1. Make the class partition word-uniform

`word(class)` must be well-defined, i.e. every S1 class must be entirely word or
entirely non-word codepoints. A `\b`-only pattern (`\bthe\b`) today partitions to
`{t}{h}{e}{else}`, and `{else}` mixes word (other letters) and non-word (space,
punctuation). **Fix:** when the pattern contains a word-boundary look, fold
`Comp.ranges_w` (the Unicode `\w` set, already used by `is_word_cp`) into the
class sets before `Trie.build`, so the partition splits on the word frontier.
Injection point: `Comp.compile`, conditional on a `wordb`/`nwordb` op being
present.

### 2. DFA state gains a left-context bit

A determinized state becomes `(ε-closure set, left_word)` where `left_word` is
whether the codepoint that entered the state was a word codepoint (for the start
state and the reverse pass, "off the end" = non-word). This is what lets the
transition evaluate `\b` without seeing further input. State identity includes
the bit, so states split by left-context — up to ~2× states in the worst case
(bounded by `max_states`; `TooBig` fallback unchanged).

### 2b. Accept is per-position, not per-state (correction, 2026-09-04)

Discovered during implementation: a `\b` *immediately before* `Match` (the
trailing `\b` in `\bthe\b`) resolves against the **following** codepoint, or
against end-of-input at the haystack boundary. So "does a match end here?" is not
a pure state property — it depends on the next symbol. The `hit : List(U8)`
(one flag per state) is replaced by:

- `accept_on[state·nc + cls]` — resolving the state's pending `Look`s at the
  position *before* `cls` (left = state's `left_word`, right = `class_is_word(cls)`)
  reaches `Match`;
- `accept_eoi[state]` — same, with right = end-of-input (non-word).

The scan loops (`Rev.fwd` / `Rev.rev`) change to consult `accept_on[state,cls]`
at each position and `accept_eoi[state]` at the boundary, instead of `hit[state]`.
`Rev.D` becomes `{ table, accept_on, accept_eoi, nc }`.

### 3. The closure resolves pending `Look`s per transition

`close_go` stops at `char` **and** `Look` (a `Look` pc joins the frontier set
unresolved). `step(set, left_word, cls)` then, for `cls`:
1. position context = `(left_word, is_word_cp(cls))` — both now known;
2. resolve each pending `Look` in `set`: if its assertion holds at this position,
   continue its ε-closure (which may reach `char`/`match`/more `Look`); else drop
   that branch — **priority order preserved** (the truncation-at-first-`Match`
   discipline `close_go` already enforces);
3. advance the surviving `char` pcs on `cls`;
4. plain-close the result (stopping again at `char`/`Look`);
5. the new state's `left_word = is_word_cp(cls)`.

`\b` is zero-width, so it only ever gates ε-edges — it fits the closure model
with no symbol consumed.

## Scope boundaries

- **This scope: `\b` and `\B` only.** Both are symmetric in word-ness, so the
  reverse DFA (`c.rprog`) needs no kind-flip — the same left-context-bit
  mechanism works mirrored (its "left" is the original string's right). That
  symmetry is why `\b` is the clean first target.
- **`^` / `$` are a separate follow-on.** They are position/line assertions, not
  symbol-word assertions: `look_start` = pos 0, `look_end` = pos len. They need a
  different context (a start flag / EOI transition), and the *unanchored* forward
  DFA (lazy dot-star prefix) makes `^` subtle — it must fire only at pos 0, not at
  every dot-star restart. They also need kind-flipping in the reverse pass
  (`look_start` ↔ `look_end`). Do them after `\b` lands, as their own scope.
- **Captures / `replace` / `split` stay on the PikeVM** (they need per-group
  offsets the DFA doesn't track); only span-finding (`find`/`find_all`/`is_match`)
  moves to the DFA. Unchanged.
- **`TooBig` still falls back to Pike** — the state-count bound is the safety net
  for a `\b` pattern whose word-split partition blows up.

## Costs

- **Artifact size.** Folding `ranges_w` into the partition gives a `\b` pattern
  the Unicode-word class trie — the same ~180 KB the size probe measured for
  `\w`, plus a wider DFA table (`states × nc`). A `\b` pattern's folded artifact
  grows accordingly; the payoff is DFA-speed matching. (An ASCII-only `(?-u:\b)`
  would only need the ASCII word split — much smaller — if we later special-case
  it.)
- **State count** up to ~2× from the left-context bit.

## Correctness plan

- `tools/diff` (1431 cases) already includes `\b`, `\B`, Unicode `\b`, and
  `(a*)+`-style pathologies. It is the gate: a divergence surfaces as a concrete
  (pattern, haystack) pair.
- The determinizer's leftmost-first + look-resolution must reproduce
  `Pike.look_ok` exactly. Highest-risk cases: `\b` at the very start/end of the
  haystack (off-the-end = non-word), zero-width `\b` matches, and `\B` inside a
  run of word chars.
- Keep the `HasLook → Pike` fallback in place for `^`/`$` (and anything else)
  until their own scope lands; only route `wordb`/`nwordb`-only patterns to the
  DFA at first.

## Risks

1. **Leftmost-first through look-gated ε-edges.** Resolving a `Look` mid-closure
   must not reorder priority. Mitigation: resolution slots into the existing
   priority-ordered `close_go`; differential suite verifies.
2. **Reverse-DFA orientation.** `\b` is symmetric so this should be free, but the
   reverse pass's "off the end = non-word" boundary needs checking against the
   forward pass. Differential covers it (three-pass `find`).
3. **State explosion** on adversarial word-split patterns → `TooBig` → Pike. No
   correctness impact, just no speedup for those.
4. **Partition growth** couples `\b` to the ~180 KB Unicode word data even when
   the rest of the pattern is ASCII — acceptable, but the ASCII-`\b` special case
   is the mitigation if artifact size bites.

## Plan

1. **Partition:** fold `ranges_w` into the class sets when a `wordb`/`nwordb` op
   is present (`Comp.compile`); confirm every class is word-uniform.
2. **State + build:** extend the determinized state to `(set, left_word)`;
   `Rev.build` no longer bails on `wordb`/`nwordb` (still bails on
   `start`/`end`).
3. **Closure:** `close_go` stops at `Look`; `step` resolves pending `Look`s given
   `(left_word, is_word_cp(cls))`, then advances; set `left_word` on the result.
4. **Gate:** `roc check`, smoke 21/21, differential 1431/1431.
5. **Bench:** `word_bound` should jump from PikeVM (~6× vs Rust PikeVM) to the DFA
   class (compare to the other DFA patterns); record it.
6. Update README honest-gaps (Unicode `\b` in the DFA — partially closed) and the
   engine notes.

## Effort

Medium. Bigger than the DFA `find_all` wiring (that was pure reuse); this is real
determinizer surgery — a new state component threaded through `determinize` /
`explore` / `step` / `close_go`, plus the partition change. Bounded and
well-gated by the differential suite. `^`/`$` deliberately deferred to keep it
contained.
