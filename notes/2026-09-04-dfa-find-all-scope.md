# Scope: a DFA inner loop for `find_all` (the last PikeVM hot path)

> **Status: implemented 2026-09-04.** Spike confirmed linear scaling (the bounded
> end-scan proved unnecessary — the determinizer's Match-truncation makes the
> forward state die past each match). Shipped `Rev.run_fwd_from` / `run_rev_from`
> (reverse floored at the search start) / `find_from` and the `find_all` engine
> branch. 12–71× on DFA-able patterns, 1431/1431 differential. Numbers in
> `notes/2026-09-02-benchmark.md`.

Scoping the "DFA-engine direction" for closing the ~10× PikeVM gap. The headline:
**most of the engine already exists.** This is not a greenfield DFA build; it is
wiring one already-built, already-validated DFA into `find_all`, plus **one** new
piece of logic (a bounded forward end-scan).

## What already exists (and is validated)

- `Rev.determinize` / `explore` / `step` / `close_pri` — a **leftmost-first
  determinizer** producing a dense-table DFA (`Rev.D = { table, hit, nc }`).
- `Rev.run_fwd` / `fwd` — an **O(n) forward-DFA inner loop**: per byte it does
  `List.get(hit)` + `Comp.decode` + `Trie.class_of` + `List.get(table)` ≈ **4
  accesses/byte**, vs the PikeVM's ~150–200.
- `Rev.run_rev` / `rev` — the reverse DFA for the leftmost start.
- `Rev.build` — builds fwd+rev DFAs; **folds at compile time** for constant
  patterns. `Regex.compile` already calls it and stores the outcome as
  `engine = Three({fwd, rev}) | Pike` (`Pike` = fell back on `HasLook`/`TooBig`).
- `Rev.find` (three-pass) powers **`Regex.find`**; `Rev.is_match` powers
  **`Regex.is_match`**. Both already run on the DFA. `1431/1431` differential.

So the engine decision is **already made at compile time**, and two of three public
entry points already use the DFA. No new determinization work is required.

## The single gap

`Regex.find_all` (package/Regex.roc:226) ignores `re.engine` and calls
`Pike.wfind_from` unconditionally in its `while` loop. **Every `find_all` runs the
PikeVM even when a DFA is sitting in `re.engine`.** The benchmark measures
`find_all` — this is the entire reason it shows PikeVM numbers.

Fixing this makes `find_all` DFA-driven for the **8 of 9** benchmark patterns that
are DFA-able (all except `word_bound`, which has `\b`).

## Expected win

Forward search is the dominant cost, and it drops from ~150–200 to ~4
accesses/byte. Shared per-byte cost (`Trie.class_of`, `Comp.decode`) does not
change, so the realized speedup is bounded by how much of the PikeVM time was
thread-set churn vs class lookup — profiling said ~78% churn. Estimate: **5–20×
on DFA-able `find_all`**, moving those rows from ~10× vs Rust-PikeVM into the same
class as Rust's meta engine on the forward scan. To be measured, not promised.

## The one hard part: a bounded forward end-scan (the O(n²) risk)

`run_fwd` as written scans until the DFA **dies or hits EOF**, because the forward
NFA carries a **lazy dot-star prefix** (`uprog`, Comp.roc:122–128) that keeps a
live state alive to the end of input. For a single `find` that is fine — one scan.
For `find_all` **iteration**, naively reusing `run_fwd` per match would rescan to
EOF every call → **O(n · #matches) = O(n²)**.

The fix is the one piece of real design: **stop the forward scan at the leftmost
match's end** rather than at EOF. The leftmost end is the last hit position while
the state still contains *real* (non-dot-star-prefix) threads; once the state
collapses back to "only the lazy dot-star is live" (equivalently, re-enters the
dot-star start configuration) after a hit, the current match is closed and the
scan stops there. `find_all` then resumes the next scan from that end.

Concretely this needs a **per-DFA-state "live real thread" bit** (or: recognize the
start-equivalent state), computed once in `determinize` and consumed by a new
`run_fwd_upto`. This is the same mechanism Rust's lazy DFA uses to terminate a
leftmost search. It is bounded and local to `Rev`.

With that bit, `find_from(at)` is O(gap-to-next-match + match-length), and
`find_all` is O(n) overall.

## Everything else is wiring

1. `Rev.run_fwd_from(d, classes, hay, at)` — `run_fwd` with a start param (trivial).
2. `Rev.find_from(d, classes, hay, at)` — three-pass parameterized by `at`: forward
   end-scan from `at` (bounded, per above), reverse start-scan bounded **below at
   `at`** so the returned start ≥ `at` (no overlap with the prior match).
3. `Regex.find_all` — branch on `re.engine`: `Three(d)` → loop calling
   `Rev.find_from`; `Pike` → the existing `Pike.wfind_from` loop. **Keep the exact
   empty-match/advancement logic** (`last_end` dedup, `next_bound`, `s == e`
   handling) unchanged; only the per-step "find next span" call swaps.

## Scope boundaries (stay on the PikeVM — unchanged)

- **Look-around patterns** (`\b`, mid-pattern `^`/`$`, lookahead): `engine = Pike`
  via `HasLook`. `word_bound` stays PikeVM. Documented gap; out of scope.
- **`captures` / `replace` / `split`**: need per-capture offsets the DFA does not
  track; they stay on the slots PikeVM (`Pike.captures`). `find_all` returns only
  spans, so the DFA suffices there.
- **`TooBig`** patterns (DFA state explosion past `max_states`): `engine = Pike`.
  No change; the fallback already exists.
- **Teddy prefilter**: orthogonal. A later step could use Teddy to skip between
  matches inside the DFA `find_all`, but this scope does not touch it.

## Correctness plan

- The `tools/diff` harness already exercises `find_all` (44 patterns × 20
  haystacks) including empty matches, anchors, alternation, and the pathological
  `(a*)*` / `(a|b)*abb` / `a|` / `.*`. It is the gate.
- **Highest-risk cases to watch:** empty matches from the DFA (`find_from` must
  return `{at, at}` when the pattern matches empty at `at`), zero-width iteration
  advancement, and the reverse-start lower bound (start ≥ `at`).
- Keep the PikeVM `find_all` path in place; the DFA path is taken only for
  `Three(d)`. Differential compares both against Rust regardless of which engine a
  pattern selects.

## Risks

1. **O(n²) if the end-scan isn't bounded** — the central task above. *De-risk
   first* (see step 1).
2. **Leftmost-end subtlety** — the "state has live real threads" bit must exactly
   reproduce leftmost-first end semantics. Mitigation: differential suite; if a
   divergence appears it will be a concrete failing (pattern, haystack) pair.
3. **Refcount traps** — the DFA loop threads `pos`/`state`/`best` (scalars) and
   reads shared read-only tables (`d.table`, `d.hit`), so no `List.set` on a
   threaded buffer — the guard that dominated the PikeVM does **not** appear here.
   Low risk, but re-check `find_from`'s span accumulation doesn't bundle Lists.

## Plan

1. **Spike (de-risk the O(n²)):** hack `find_all` to call `Rev.find` (whole-haystack
   DFA) from `at` in a loop on one big-match-count pattern; time it. If it's
   quadratic, that confirms the bounded end-scan is required before anything else.
   ~30 min, throwaway.
2. Add the per-state "live real thread" bit in `determinize`; add `run_fwd_upto`.
3. Add `Rev.run_fwd_from` + `Rev.find_from` (start-parameterized three-pass).
4. Rewire `Regex.find_all` to branch on `re.engine`.
5. Gate: `roc check`, smoke 21/21, differential 1431/1431.
6. Benchmark; record the before/after in `notes/2026-09-02-benchmark.md`.
7. If a win: update README engine table; note `find_all` now DFA-driven for
   non-look patterns.

## Effort

Small–medium. The determinizer, DFA runner, engine selection, and empty-match
iteration logic are all done. New code is ~1 flag in `determinize` + ~3 small
`Rev` functions + a `find_all` branch — call it ~80–120 lines, dominated by
getting the bounded end-scan and its leftmost semantics exactly right. The spike
(step 1) decides whether the estimate holds before committing.
