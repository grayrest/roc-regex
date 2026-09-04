# Scope: `^` / `$` (text anchors) in the DFA

> **Status: implemented 2026-09-04 (approach B, outermost anchors).** One
> mid-implementation correction: the scope had the difficulty backwards. `^` was
> easy (anchored forward `uprog`, no dot-star — a match can only start at 0).
> `$` via "strip + accept-only-at-EOI" was **wrong** — the leftmost-first
> forward DFA of the anchor-free core dies at the *first* match, so it never
> reaches a later match that ends at `len` (`abc$` on "abcabcabc"). The correct,
> still-strip-and-constrain fix: an outermost `$` skips the forward end-scan
> entirely — `end = len` by definition — and runs the reverse from `len`
> (`run_rev_check`, which reports existence) to find the leftmost start; `^…$`
> composes (reverse-from-len + `start == 0`). Buried `^`/`$` stay on the PikeVM
> (`Rev.has_anchor` bails on any `^`/`$` left in `uprog` after outermost
> stripping). 1512/1512 differential (anchor + non-ASCII + boundary haystacks).


Follow-on to `\b`/`\B`-in-the-DFA. `^`/`$` are the remaining look assertions that
force the PikeVM (`Rev.has_anchor` bails on them). This scope covers moving them
onto the DFA fast path.

## Semantics (the simplifying fact)

`^` = `look_start` = `pos == 0`; `$` = `look_end` = `pos == len`. These are
**text anchors** (`\A`/`\z`), not multiline — the parser has no `(?m)`, so `^`/`$`
never fire at interior newlines (confirmed: `Pike.look_ok`). So they constrain
the **span endpoints** (start must be 0, end must be len), not interior
transitions. Unlike `\b`, word-ness never enters into it.

## Value (be honest: lower than `\b`)

`\b` earns its keep because `\bword\b` scans a large document — an O(n·states)
PikeVM hot loop. `^`/`$` anchor the match to the text ends, so an `^p`/`p$`
pattern matches at most once. It still *scans* O(n) (an unanchored search for a
match that must end at `len`, say), so the DFA does help throughput — but these
patterns are far less common in throughput-critical code, and the PikeVM handles
them correctly today. **Medium-to-low value; a reasonable defer.**

## Two mechanisms

### A. Uniform — extend `close_resolve` with `at_start` / `at_end` flags

Generalize the `\b` machinery: `close_resolve` already resolves pending `Look`s
per position from `(left_word, right_word)`; add `at_start` / `at_end` so it also
resolves `look_start` / `look_end`.

- **`$` is easy and needs no new state:** it resolves purely at accept time.
  `accept_on[state,cls]` (a following symbol exists) resolves `$` = fail;
  `accept_eoi[state]` resolves `$` = pass. This drops straight into the existing
  `accept_on`/`accept_eoi` split — just thread `at_end` (false for per-class,
  true for eoi) into `close_resolve`.
- **`^` needs the start state distinguished:** `^` passes only at pos 0, i.e.
  only in the closure computed *from the start state*. That requires an
  `at_start` bit in the state identity (so the dot-star-restart copy of the
  initial pcs, at pos > 0, is a distinct state that resolves `^` = fail). Plus
  `find_from(at)` must start from the `at_start = false` version when `at > 0`.
- **The hard part is the reverse pass.** In the reversed NFA, `^`/`$` assert the
  *original* pos 0 / len, which map to the reverse scan's `lo`/`end` boundaries
  and the haystack length — not to any symbol property. Threading "original
  pos 0" and "original pos len" correctly through `rev_wb` (which reads backward
  and is already the subtlest code in the engine) is where the risk and effort
  concentrate. This is strictly harder than `\b`, whose symmetry made the reverse
  free.

Handles every case including anchors buried in alternations/groups
(`(^a|b)$`), but pays the reverse-orientation cost.

### B. Strip-and-constrain — for *outermost* anchors (recommended)

Because text anchors only constrain span endpoints, an **outermost** anchor can
be handled at the scan/build level without touching the determinizer internals:

- **`p$`** → determinize `p` as today (unanchored forward), but the forward scan
  records a match end **only at `pos == len`** (an "accept at EOI only" flag).
  The reverse is unchanged (it finds the start of a match already known to end at
  `len`). Reuses the plain/`\b` DFA verbatim; ~trivial.
- **`^p`** → the match must start at 0, i.e. an **anchored** forward scan (no
  dot-star restart). Either determinize an anchor-free core without the lazy
  dot-star prefix, or suppress the restart. The reverse floors at 0. Moderate.
- **`^p$`** → both.

"Outermost" = the AST is `Cat([Look(^) , …])` and/or `Cat([… , Look($)])` at top
level, not inside `Alt`/`Star`/`Group`. That is the overwhelmingly common shape
(`^…`, `…$`, `^…$`). **Buried anchors stay on the PikeVM** (`a(^)b`, `(^a|b)` —
rare, often degenerate). No reverse surgery; reuses the existing DFA.

## Recommendation

**B, for outermost anchors**, keeping buried anchors on the PikeVM — most of the
value at a fraction of A's risk, and it doesn't perturb the just-landed `\b`
reverse code. Do A only if buried anchors turn out to matter (they rarely do).
Given the modest value, deferring entirely is also defensible.

## Scope boundaries

- Text anchors only (no `(?m)` exists to support).
- Outermost `^`/`$` (approach B); buried anchors → PikeVM.
- Captures/replace/split unchanged (PikeVM).
- `TooBig` fallback unchanged.

## Correctness plan

- `tools/diff` already has `^abc`, `abc$`, `^$` and now non-ASCII haystacks; add
  a few outermost-anchor cases over multi-line-ish and boundary haystacks
  (empty, single char, match-at-0, match-at-len, no-match). It's the gate.
- Highest-risk cases: empty pattern `^$`, `$` with a trailing empty match, `^` on
  an empty haystack, and (for B) confirming the "accept at EOI only" flag
  composes correctly with `\b` in the same pattern (`\bword$`).

## Risks

1. **`^p` anchored-forward plumbing** (approach B): needs an anchor-free,
   dot-star-free forward prog or a restart-suppression flag; make sure it still
   composes with `\b` handling.
2. **Approach A's reverse orientation** (if chosen): the error-prone piece;
   differential-gated but subtle.
3. Composition with `\b`: a pattern with both (`^\bword\b$`) must resolve all
   assertions consistently; approach B layers cleanly (anchors at the edges, `\b`
   inside), approach A needs the combined flag set.

## Plan (approach B)

1. Detect outermost `^` / `$` in the AST (a top-level `Cat` head/tail `Look`);
   record two flags on `Compiled` (`anchored_start`, `accept_eoi_only`).
2. `$`: forward scan records accept only at `pos == len` when `accept_eoi_only`.
3. `^`: determinize an anchor-free forward core without the dot-star prefix (or a
   restart-suppression flag); reverse floors at 0.
4. `Rev.has_anchor` stops bailing on *outermost* anchors; still bails on buried
   ones.
5. Gate: `roc check`, smoke, differential (with added anchor cases).
6. Bench: add an `anchored` row (`\w+$` or `^\w+`) to see the PikeVM→DFA move.

## Effort

Approach B: small–medium (`$` trivial, `^` moderate, no reverse surgery).
Approach A: medium–large (reverse-orientation surgery on the subtlest code).
