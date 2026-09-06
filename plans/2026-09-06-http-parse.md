# HTTP framing and routing on `Sharp`

**Status: design interview complete 2026-09-06; NOT REVIEWED as a document.
Eleven decisions. No implementation.** Record of the interview and the reasons:
`notes/2026-09-06-http-parse-grill.md`.

Consumer: `~/dev/roc/tower-platform` — routes are `{ method, path, handler }`
with `path` in matchit 0.8 syntax; params arrive as `List({ name, value })`;
`Req.get_header` is case-insensitive; the host currently routes with matchit
and frames with hyper. This plan puts framing and routing in Roc on top of the
derivative engine in the sharp worktree (`claude/resharp-regex-design-review-60cff0`).

## The shape

    request bytes ──► Http.frame : List(U8) -> Try(Request, [Incomplete, Bad(…)])
                        request line: three longest_end steps over slices
                        header block: find "\r\n\r\n"; recorded as a span
                      Http.header : Request, Str -> Try(List(U8), [Missing])
                        find  ^(?i)name:[ \t]*  over the block slice, then
                        longest_end [^\r\n]*  for the value — on demand
    path slice    ──► Route.at : Router, Str, List(U8) -> Try(Match, [NotFound, MethodNotAllowed(List(Str))])
                        per-method list of (selection Sharp.T, pieces), in
                        priority order; first selection that matches wins;
                        params by stepping the pieces over the same slice

Every piece is `List.sublist` of the original buffer. Nothing in `Sharp`
learns HTTP; `package-http` uses only its public surface.

## Decisions

### H1 — Both framing and routing; `Sharp` is the engine; `Regex` stays frozen

Overrides S1 for the *target*: new features land in `package-sharp`;
`package/` gets bug fixes only and keeps `tools/diff`, its bench rows and its
README status (its value: the Rust-semantics oracle, and a codegen benchmark
for the Roc developers). Rejected: deleting `package/`; keeping `Regex` as the
HTTP target (captures on the PikeVM, ~6x behind the DFA; repeated groups keep
one iteration).

### H2 — Caller-driven anchored stepping over seamless slices

The parse primitive is "from the start of this slice, how far does this piece
extend?" — RE#'s `LongestEnd`. Pieces are the slices. No captures, no cursor
type in the engine, no resumable match state. Rejected: resuming across socket
reads (re-parse from the block start instead, as `httparse` does); a
prebuilt one-pass parser that records every header up front.

### H3 — `first_end`/`longest_end` on the frozen DFA, slice semantics

Signatures unchanged: `Sharp.T, List(U8) -> Try(U64, [NoMatch])`. The haystack
is the slice: `\A` at 0, `\z` at `len`, lookbehind and `\b` at 0 see
beginning-of-input; the result is slice-relative. Implementation: the forward
end pass `Dfa.end_loop` shape on raw bytes with `atable` (as `ends_fast`),
single start 0, **no `Ref.prepare`** (each call's slice is a suffix of the
buffer; a per-call copy is quadratic over the parse). `first_end` is the same
loop returning at the first nullable state. The initial state is the one whose
node is the *root* (lookbehind prefix included, nullability at
`Deriv.loc_begin`), not `s_noprefix` — verify against `Ref.ends_at_start`,
which stays as the oracle and as the path for incomplete folds. A nullable
pattern returns `Ok(0)`; callers check progress. `end == List.len(slice)`
is the partial-buffer signal; no flag.

Rejected: offset-taking twins with real left context (a second anchor
semantics to document and fuzz, for no HTTP need); a cursor/combinator layer
in the engine.

### H4 — One matcher per route, matchit priority, conflicts at build

Selection tries routes in an order computed at build: sort by the
segment-kind sequence (static = 0, param = 1, catch-all = 2, lexicographic).
Two routes that can match the same path agree on their static segments, so
the first divergence is static-vs-dynamic and the static one sorts first —
matchit's rule. Same-shape routes (identical kind sequence and statics,
e.g. `/users/{id}` vs `/users/{name}`) are a build error, as
`matchit::InsertError::Conflict`. Tables are per method; a path that matches
under another method yields `MethodNotAllowed` with the `Allow` list.

Rejected: registration order (wrong for this syntax); pattern IDs in one
automaton (branch identity lost in `mergeOr*` rewrites; leftmost-longest
ties). **Reopen:** pattern IDs if M4 shows per-call overhead dominating; a
radix trie for selection if sorted per-route passes cannot approach matchit
(2.4 µs for 130 routes).

### H5 — `(?i)` by parse-time fold expansion

Leading bare `(?i)` and scoped `(?i:…)`; mid-pattern bare `(?i)` rejected,
as `Regex` does. Each literal codepoint and class range expands to its simple
case-fold partners via shared `Uni.fold_partners_in`; `Conv` sees classes, the
derivative engine is untouched. `Ast.read_flags` already lexes `ci`; wire it
through `Conv`. RE#'s case-insensitive prefix accelerator becomes reachable;
it is optional here and measured if added. Rejected: normalizing the buffer
(copies; breaks slices); a caller-side class-expansion helper.

### H6 — Artifact policy: measure first

After narrowing, an ASCII pattern is ~30 KB stored (10 KB trie + tables +
nodes, at ~2.2x, owed upstream), Unicode patterns 100+ KB. The route table is
one automaton per route plus two shared piece matchers (H7). M4 runs
`tools/sharp-size/breakdown.sh` on `examples/http.roc` and records the number.
Named lever if it is bad: an ASCII-only trie (all classes ASCII plus one
"rest" class → a 256-entry table, no Unicode leaves), local to
`Trie`/`Dfa.freeze`. Rejected: a shared trie across patterns (D3).

### H7 — Route string → selection pattern + piece list; no constructor API

`Route.parse : Str -> Try(RouteSpec, Err)` implements matchit 0.8:
segments split on `/`; `{name}` at most once per segment with optional static
prefix/suffix; `{*name}` only as the last segment, non-empty; `{{`/`}}`
escapes; a param never matches empty. Output: `pieces : List([Static(List(U8)),
Param(Str), CatchAll(Str)])` and the selection pattern string
`\A` ++ (statics regex-escaped, `{p}` → `[^/]+`, `{*p}` → `_+`) ++ `\z`,
compiled with `Sharp.compile`. Extraction steps the pieces over the path
slice: `Static` is a byte compare, `Param` is `longest_end` of the shared
`[^/]+` matcher, `CatchAll` of the shared `_+`. Params stay percent-encoded,
as matchit returns them. Escaping must cover RE#'s extra metacharacters
`_`, `&`, `~` — verify `Ast`'s lexer accepts `\_`, `\&`, `\~`; add them if
not. Rejected: public constructors over `Ast` (one consumer);
lookaround extraction per parameter (a full sweep per param, normal-form
constraints).

### H8 — Layout: `package-http/`

A third package depending on `package-sharp`: `main.roc`, `Route.roc`
(parse, sort, conflict check, per-method tables, `at`), `Http.roc` (frame,
`header`, request-line pieces `method`/`target`/`version`), each under 300
lines. Pieces are `List(U8)`; `_str` twins only where the platform needs
them. Route tables fold when declared at top level; inside `main` they compile
at boot, and conflicts then error at boot rather than at build — document,
do not work around.

Framing rules: parse only once `\r\n\r\n` is found (else `Incomplete`);
request line `[A-Z]+` SP `[^ ]+` SP `HTTP/[0-9]\.[0-9]` `\r\n`; header line
`^(?i)name:[ \t]*` found over the block slice (`^` is a line anchor, so
"start of a header line" needs nothing else), value `[^\r\n]*` with trailing
SP/HT trimmed; a header line starting with SP/HT (obs-fold) is `Bad`.

### H9 — Tests (approved)

1. **End finders** — differential + fuzz: `tools/sharp-fuzz` gains an `ends`
   mode comparing the DFA `first_end`/`longest_end` with `Ref.ends_at_start`
   (nullable patterns, no-match, match at `\z`), ~1,500 cases per seed;
   `tools/sharp-diff` calls RE# `FirstEnd`/`LongestEnd` on the corpus patterns.
2. **`(?i)`** — differential: an `IgnoreCase` flag in the `.NET` harness; a
   `Regex` cross-check on the leftmost-first-agrees subset; ~60 listed cases
   (ASCII, Kelvin/long-s/sigma multi-partner folds, scoped, rejected
   mid-pattern).
3. **Consumer** — integration, `examples/http.roc`: ~20 requests (well-formed,
   folded headers, missing terminator, oversized method, bad version,
   case-mixed names, empty value, and one fixture split at every byte
   boundary for the `end == len` rule). Also the `breakdown.sh` subject.

No unit tests on internals.

### H10 — Benchmark: `httparse` only

A `tools/bench` row: ~1,000 realistic requests (mixed methods, 8–20 headers,
paths spread over the example route table), ns per request for request line
+ all headers + route selection + three named headers on demand, piece counts
compared with the vendored `httparse` side. No `regex`-stepwise row (owner's
choice); diagnose a gap with stage timing as `probe.sh` does.

### H11 — Order

- **M0** — merge the sharp branch to `main` (only `README.md` conflicts);
  one branch for the rest.
- **M1** — H3, with H9.1 in the same commit.
- **M2** — H5, with H9.2.
- **M3** — `package-http`: `Route`, then `Http`, then `examples/http.roc`
  (H9.3).
- **M4** — H10 row and H6 measurement; both in the design log with their
  reopen conditions.

Each milestone ends with the existing gates green: corpus 331, fuzz, RE#
differential, bench counts.

## Assumptions, stated so they can be wrong

- The HTTP layer belongs in this repository, not in `tower-platform`.
- Every HTTP and route pattern folds completely (no unbounded lookahead), so
  the interpreter path for incomplete folds is never on the request path.
- `List.sublist` is zero-copy for the slice sizes here and does not defeat
  the frozen scan's byte loop.
- RE# supports `IgnoreCase` in its .NET harness (its accelerators mention
  case-insensitive prefixes); if not, `Regex` becomes the only `(?i)` oracle.

## What "done" means

`Sharp.first_end`/`longest_end` on the DFA with the interpreter and RE#
agreeing; `(?i)` parsed and cross-checked; `package-http` framing and routing
`examples/http.roc` 100% on its fixtures; an `httparse` row and a
`breakdown.sh` number recorded in the design log.

## Deferred, with the reason

- **Pattern IDs / a trie for selection** — H4's measured reopen.
- **ASCII-only trie** — H6's measured lever.
- **Resumable matching across reads** — no need over re-parsing (H2).
- **Constructor API over `Ast`** — no second consumer (H7).
- **`package-core`** — S8, after both engines are stable.

## Implementation status (2026-09-06)

M0-M3 landed on `main`. Departures from the plan as written:

- **H8 grew a third module.** `Router.roc` holds the table: the priority sort,
  the conflict check, per-method selection and 405/`Allow`. Putting it in
  `Route.roc` (which the plan named) would have taken that file past the
  300-line rule; `Route` is now one route and `Router` is the table of them.
- **H3's start state is `Deriv.at_input_start` of the root, not the root.** The
  plan said the root with nullability at `loc_begin`. That is wrong for a
  leading lookbehind, because a lookbehind derivative walks its body FORWARD:
  the root matched `(?<=ab)cd` against "abcd" at 0. The prefix has to be
  resolved against offset 0 rather than kept. See the design log.
- **H5 was mostly already implemented.** `(?i)` leading and scoped both worked;
  the README's "No `(?i)`" was stale. What M2 actually fixed was three defects
  behind it, one of them (a one-directional fold table) in `Regex` as well.
- **H7's parameter extraction needed the suffix subtracted.** `[^/]+` is greedy
  and takes the whole segment, so a route with a static suffix in the same
  segment (`/images/img{id}.png`) bound "9.png" instead of "9". `Route.step`
  now removes the following static's in-segment head.
- **M4's H10 row is taken; H6 is blocked.** `tools/http-bench/run.sh` reports
  **27.3x slower than `httparse` + `matchit`** on the same task with agreeing
  checksums, and the stage split puts 60% of it in route selection at ~707 ns
  per anchored match of a 20-byte path -- per-call overhead, not scanning. Both
  of H4's reopens are now justified by measurement; neither is implemented,
  because they are design changes. See the design log.
- **`Route.matches` uses `longest_end`, not `is_match`.** Same automaton, same
  answer, one forward pass instead of a reverse sweep first: routing 7663 ->
  6361 ns/req.
- **`Http.header_matcher` was added.** H8 described `header` taking a name;
  a caller looking the same header up per request wants the matcher compiled
  once, which the benchmark needs and a real server would too.

### Blocked: two modules with folded constants panic the compiler

`Http` and `Route` each hold their matchers as top-level folded values, which
is the design. An app importing BOTH panics the Roc compiler; either alone is
fine. Reduced to a six-file reproducer in
`upstream/2026-09-06-two-modules-folded-constant/` (no regex dependency in the
minimal form -- an ordinary recursive function over lists and tag unions shows
it too).

`examples/http.roc` builds and passes 49/49 on the cached path and panics under
`--no-cache`. Per [[compiler-instability-not-a-design-input]] the layout is
NOT being redesigned around this; it is reported upstream.

Consequence: `tools/sharp-size/breakdown.sh` builds with `--no-cache`, so
**H6's artifact measurement cannot be taken** until the compiler bug is fixed.
H10's `httparse` row was not blocked by it (`tools/http-bench/run.sh` builds
on the cached path).
