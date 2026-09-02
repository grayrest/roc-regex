# M4 — literal extraction and the prefilter seam

The prefilter rung D6 keeps, wired behind one narrow seam.

## What is built

- **Required-literal prefix extraction** (`Comp.prefix_of`): the bytes every
  match must begin with. It collects exact single-codepoint literals from the
  head of a `Cat` (descending into a leading `Group`) and stops at the first
  class, alternation, quantifier or group boundary. Verified: `abcdef`→6,
  `foo.*bar`→3, `colou?r`→"colo" (stops at the optional `u?`), `cat`→3;
  `foo|bar`, `[a-z]+x`, `\w+`→none. Stored on `Regex.T` as `prefix : List(U8)`.
- **The seam** (`package/Lit.roc`): `find_candidate : List(U8), U64, List(U8) ->
  Try(U64, [NoCandidate])` — the next offset at/after `at` where the prefix
  occurs, by a scalar first-byte scan then a compare (the "byte-set scan then
  verify" rung). Empty prefix ⇒ every position is a candidate. No SIMD (none is
  user-facing in Roc); this is the one file to swap when a SIMD builtin lands.
- **Prefiltered `find`** (`Regex.find_pf`): when a prefix exists, scan for the
  next candidate and run the PikeVM **anchored** at it (`Pike.match_at`); on a
  miss, advance and rescan. Because every match must start with the prefix,
  iterating candidates in order and taking the first anchored match preserves
  leftmost-first. When no prefix was extracted, the engine's own unanchored
  search runs unchanged.

## Verification

The differential harness now checks **three** paths against the Rust crate —
`find_all` (PikeVM), `is_match` (DFA), and the prefiltered `find` (leftmost):
**1431/1431 agree.** The prefilter changes `find`'s search path for every
literal-prefix pattern in the corpus (`abc`, `colou?r`, `cat`, …) and leftmost
semantics are preserved. smoke 21/21.

## Also built (2026-09-02): the first-byte-set rung + skip heuristic

`Comp.first_bytes` extracts a **sound superset** of the bytes a match can begin
with, as ASCII singletons — for an alternation or class start (`(cat|dog)\b` ->
{c,d}, `[abc]x\b` -> {a,b,c}). It returns "wide" (skip) when the lead is a
`.`/`\w`/negated/nullable construct or exceeds 4 distinct bytes — the
pattern-side skip decision D6 requires (the compiled `Regex` never sees the
haystack, SR3, so the choice is made from the pattern). `Lit.find_in_set` is the
rung; `Regex.find_fb` runs the engine anchored at each candidate.

Where it fires: look-bearing patterns with a literal or small-lead-set start
(`foo\b` via the prefix rung, `(cat|dog)\b` via the byte-set rung) — the ones
that route to the PikeVM. Look-free patterns take the three-pass DFA. Verified,
and the full 1431-case differential still agrees with Rust (45 s).

## Deferred per D6

Rabin-Karp for multi-literal sets; inner required literals (not just prefixes,
`hir/literal.rs` territory);
wiring the prefilter into the three-pass DFA path (it currently accelerates only
the PikeVM path). The seam is the point: these slot in at `find_candidate` /
`find_in_set` without touching the engines.
