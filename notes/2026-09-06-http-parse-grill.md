# HTTP parsing and routing on `Sharp` — grill record

**Date:** 2026-09-06
**Scope:** use the regex engine to frame HTTP requests and select routes for a
web app server (the consumer is `~/dev/roc/tower-platform`). The owner drives
each parse step; pieces are seamless slices of the request buffer.
Plan: `plans/2026-09-06-http-parse.md` (H1–H11).

Read for this record: `package/Regex.roc` (the public surface and the
compile-time plan), the sharp worktree's `Sharp.roc`, `Dfa.roc` (the forward
end pass), `Ref.roc` (`ends_at_start`), `Ast.roc`, `plans/2026-09-05-package-sharp.md`
(S1, S11, deferred list, implementation status), the sharp design log
(three-way benchmark, artifact breakdown, trie/table narrowing, `Ref.prepare`),
`tower-platform`'s README, `Req.roc`, `crates/host/src/router.rs`, and
matchit 0.8.6's README and `InsertError`.

## Q1 — What is matched, and for what?

Options: request framing only; routing only; both. The owner wants both, and
expects a full parse in one forward pass because the matchers are tuned
harder than a hand-written parser would be. **Choice: both; the API surface
is expected to grow (H1).**

## Q2 — Which engine

Asked as "how do header pieces come out of one pass" under `Regex` (captures
run on the PikeVM, ~6x behind the DFA; a repeated group keeps its last
iteration). The owner's answer changed the premise: **the derivative engine in
the sharp worktree replaces `Regex` as the target** — leftmost-longest,
always-multiline `^`, lookarounds, `_`/`&`/`~`, no captures. That overrides
plan S1 ("companion engine; `Regex` untouched") for the *target*, not for the
package (Q8). **Choice: `Sharp` is the engine (H1).**

## Q3 — "Build up a matcher across a number of calls"

Options: (i) compose the pattern from parts; (ii) resume matching across
socket reads (a derivative state is a regex); (iii) parse by a sequence of
anchored calls, each "from the start of this slice, how far does this piece
extend?". (ii) buys nothing over re-parsing an 8 KB header block from its
start on the next read — what `httparse` and every HTTP/1.1 parser does — and
would push mutable DFA state through the API. (iii) is RE#'s `LongestEnd`
primitive and makes seamless slices the offset API. **Choice: (iii), the
caller drives each step (H2).** (i) resurfaced in Q11 and was rejected there.

## Q4 — Route identification

Options: one `Sharp.T` per route tried in order; one automaton with pattern
IDs (branch identity does not survive the `Or` merge rewrites; leftmost-longest
across routes ties); routing as segment-wise parsing. An anchored DFA pass dies
at the first byte that cannot continue, so a non-matching route costs a few
bytes, not the path. **Choice: one matcher per route (H4).** Precedence was
recorded as caller order here and **corrected in Q11** to matchit's priority.
Reopen pattern IDs only on a measured per-call-overhead finding (the
`caps_email` shape: fixed cost per candidate, not scan length).

## Q5 — Case-insensitive header names

`Sharp` has no `(?i)`; header names are case-insensitive; the buffer cannot be
normalized without copying. Options: `(?i)` by parse-time fold expansion
(`Regex` does this with shared `Uni.fold_partners_in`); a caller-side helper
that expands a literal to case classes through `compile_ast`; scoped flags
only. **Choice: leading bare `(?i)` and scoped `(?i:…)`, mid-pattern bare
`(?i)` rejected as `Regex` does (H5).** Parser-only; the engine sees classes.
Also unlocks RE#'s case-insensitive prefix accelerator, skipped by the port.

## Q6 — The anchored primitive

Found: `first_end`/`longest_end` exist with the right signature but run on
`Ref.ends_at_start`, the brute-force interpreter — oracles, not fast paths.
The frozen DFA's forward end pass (`Dfa.ends_from`/`ends_fast`) is the loop
`find_all` runs after the reverse sweep, unexposed. Options: keep RE#'s
signatures with slice semantics (`\A` at slice start, `\z` at slice end,
lookbehind/`\b` at 0 see beginning of input); offset-taking twins with real
left context (Rust `Input::span`); a cursor layer. HTTP pieces are
delimiter-bounded, so the caller has consumed the delimiter and
beginning-of-input is the correct left context. **Choice: RE#'s signatures on
the DFA, slice semantics; `first_end` is the same loop with an early exit; a
nullable pattern returns `Ok(0)` and the caller checks progress (H3).** The
finder must not `Ref.prepare` the slice: each call's slice is a suffix of the
buffer, so a per-call copy is quadratic over the parse.

Partial buffers need no flag: `end == List.len(slice)` means "might extend".

## Q7 — Artifact size with dozens of folded patterns

After the trie/table narrowing an ASCII pattern is ~10 KB trie + 2–5 KB
tables + 1–3 KB nodes, stored at ~2.2x (owed upstream): ~30 KB each, 100+ KB
with `\w`/`\p{}`. Sixty automata is 1.5–2 MB. Options: build and measure with
`breakdown.sh`; pre-emptive ASCII-only trie specialization; a shared trie (the
old D3 fork). **Choice: measure first, ASCII-only trie is the named lever,
no shared trie (H6)** — consistent with S14 (no spike gates). Q11 later capped
the count at one automaton per route plus two shared piece matchers.

## Q8 — Fate of `package/` (`Regex`)

Options: keep frozen; delete with `tools/diff` and its bench rows; keep until
parity then delete. **Choice: keep, frozen** — the owner's reason: it has
value as a codegen benchmark for the Roc developers if nothing else; mine: it
is the only Rust-semantics differential and `(?i)` is about to be
cross-checked against it (H1).

## Q9 — Tests

Nothing tests `first_end`/`longest_end` today and the RE# `.NET` differential
passes no `RegexOptions`. Proposed and **approved as listed (H9)**: fuzz
`ends` mode against the interpreter plus RE# `FirstEnd`/`LongestEnd` on the
corpus; `(?i)` against RE# `IgnoreCase` and `Regex`; one integration file
`examples/http.roc` with ~20 fixtures including a split-at-every-byte run; no
unit tests on internals.

## Q10 — Benchmark comparator

Options: Rust `httparse`; Rust `regex` doing the same stepwise parse; both;
none. The owner chose **`httparse` only (H10)** — the claim is about
hand-written parsers. There is therefore no engine-to-engine row for this
work; a gap has to be diagnosed with `probe.sh`-style stage timing instead.

## Q11 — Route strings

Asked as "how do parameters come out without captures" with a constructor
API over `Ast` recommended. The owner: routes are strings in
`tower-platform`'s syntax — **matchit 0.8**: `/users/{id}`,
`/images/img{id}.png` (one param per segment), `/{*rest}` (last segment,
non-empty), `{{`/`}}` escapes; params as `List({ name, value })`; per-method
tables with 405 + `Allow`; static beats param beats catch-all at the first
differing segment; same-shape routes conflict at build. That fixes the
syntax, so a constructor API would have one consumer. **Choice: translate the
route to a regex string for selection and a piece list for extraction; two
shared piece matchers (`[^/]+`, `_+`); routes sorted at build time by
segment-kind sequence to reproduce matchit's priority; conflicts are build
errors (H4, H7).** A radix trie for selection is the reopen if sorted
per-route passes cannot approach matchit's 2.4 µs / 130 routes.

## Q12 — Layout and order

**Choice: `package-http/` (`Route.roc`, `Http.roc`) consuming only `Sharp`'s
public API; M0 merge sharp → M1 DFA end finders + oracles → M2 `(?i)` →
M3 `package-http` + `examples/http.roc` → M4 `httparse` row + `breakdown.sh`
(H8, H11).** Assumed without objection: the HTTP layer lives in this
repository; incomplete folds keep the `Ref` path for the anchored finders.
