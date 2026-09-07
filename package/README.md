# package — RE#'s design in Roc

The default regex engine of this repository. The Rust-`regex` port it grew up
beside lives in `package-dfa/` (`Regex`) and is kept as an oracle.

`Sharp` is a port of [RE#](https://github.com/ieviev/resharp)
(`~/Repositories/resharp-dotnet`): Brzozowski derivatives over a symbolic
alphabet, a lazily-built DFA whose states are regex nodes, **leftmost-longest**
matching found by a reverse sweep for match starts and a forward pass for
each end, and the operators a derivative engine gets for free: intersection
`&`, complement `~(…)`, the universal set `_`, and lookarounds in RE#'s normal
form. The design decisions are in `plans/2026-09-05-package-sharp.md`; every
measurement and every departure from RE# is in
`notes/2026-09-05-package-sharp-design-log.md`.

Like `Regex`, `Sharp.compile("…")` on a literal pattern is evaluated during
the build (the derivative automaton is explored eagerly and stored in the
binary); on a runtime pattern the same call runs at runtime.

## Use

```roc
import re.Sharp

rx : Sharp.T
rx = Sharp.unwrap(Sharp.compile("_*cat_*&_*dog_*"))   # a haystack containing both words

Sharp.find_all(rx, bytes)          # List({ start, end }) byte offsets, non-overlapping, leftmost-longest
Sharp.find_all_str(rx, "…")        # the same on a Str
Sharp.is_match / count / find / first_end / longest_end / replace_all / split
```

Every `_str` twin takes and returns `Str`. Haystacks are `List(U8)`; malformed
UTF-8 is one `Invalid` symbol per run (D8), matched only by `_` and `~`.

## Semantics (RE#'s, not Rust's)

- **Leftmost-longest**, not leftmost-first: `a|ab` on "ab" matches "ab".
- `^` and `$` are line anchors always (RE# is always multiline); `\A`, `\z`
  are the input anchors.
- `.` and `[^…]` exclude `\n` and the `Invalid` symbol; `_` is everything
  including both; `~(R)` is the true complement.
- `&` binds tighter than `|`, looser than concatenation: `a|b&c` is
  `a|(b&c)`.
- Lookarounds must be in RE#'s normal form (a lookahead at the end of a
  branch, a lookbehind at the start, `\b` allowed anywhere); `\B` and lazy
  quantifiers are rejected as in RE# (`a*?` is accepted and treated as `a*`).
- Unicode classes are `Uni`'s tables (Rust-derived), shared with `Regex`.

RE# has a handful of bugs the engine reproduces for parity; they are listed
with minimal cases in the design log under "Fuzz campaign".

## Modules

| module | what |
|---|---|
| `Sharp` | the API, `compile` (parse → minterms → arena → rewrites → automaton → accelerators), introspection helpers |
| `Ast`, `Conv`, `Err` | RE#'s grammar; AST → nodes, including the `\b` and negative-lookaround rewrites |
| `Trie`, `Uni`, `TSet`, `Utf8` | codepoint classes as minterms (`U64` bitsets), Unicode tables, UTF-8 with the `Invalid` symbol |
| `Arena`, `Build`, `Deriv` | the interned node graph, RE#'s `RegexBuilder` rewrites (all three tiers), derivatives and nullability by location |
| `Dfa` | states, transition tables, the reverse sweep and forward end pass (fast byte loops for complete folds, a threaded scan with eviction for incomplete ones) |
| `Accel`, `Rlit`, `Bset`, `Teddy`, `Lit` | RE#'s accelerators: prefix and potential-start skips, per-state skip sets, length lookups, literal override; the SIMD kernels behind them |
| `Ref`, `Show` | the brute-force reference interpreter and the RE# notation printer (oracles and debugging) |

## Checking it

```bash
python3 tools/sharp-corpus/gen.py > /tmp/c.roc && roc build /tmp/c.roc && /tmp/c a b     # RE#'s 331-case corpus, four engines cross-checked
roc tools/sharp-corpus/nodes.roc                                                        # node-layer tests
python3 tools/sharp-fuzz/gen.py 1500 20260905 plain > /tmp/f.roc && roc build /tmp/f.roc && /tmp/f a b   # fuzz vs the reference
DOTNET_ROOT=~/.dotnet PATH=~/.dotnet:$PATH RESHARP=~/Repositories/resharp-dotnet python3 tools/sharp-diff/gen.py > /tmp/d.roc   # vs real RE#
tools/sharp-size/probe.sh <haystack> [size|speed]     # fold cost, artifact size, ns per find_all
tools/sharp-size/breakdown.sh <haystack> [size|speed] # what one pattern costs in the binary, and where
tools/bench/run.sh                                     # sharp_* rows next to Regex and Rust
DOTNET_ROOT=~/.dotnet PATH=~/.dotnet:$PATH RESHARP=~/Repositories/resharp-dotnet tools/sharp-bench/run.sh   # vs the original RE#
```

The `a b` arguments exist so the runners cannot be constant-folded whole.

## Status and limits

- Complete folds (every reachable state explored at build time, cap 1024
  states) get the fast byte-loop scans and all accelerators; a pattern over
  the cap (unbounded lookaheads like `a(?=.*b)`) runs the threaded scan,
  extending its table at runtime and evicting back to the fold past a cap.
- No captures (RE# has none in its core either), no `\B`. `(?i)` is
  supported: a leading `(?i)` or a scoped `(?i:...)`, expanded to case-fold
  classes at parse time. A bare mid-pattern `(?i)` and every other inline flag
  are parse errors.
- Performance on 256 KB of prose is within 1–2.5x of Rust's meta engine on
  the bench patterns and ahead of `Regex` on classes and boolean patterns;
  the literal alternation is the outlier (no literal-set accelerator in
  RE#'s design). Numbers: design log, M4 stages.
