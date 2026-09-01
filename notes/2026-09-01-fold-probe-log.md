# Compile-time evaluation — what the probes measured

Rigs in [`probes/fold/`](probes/fold/). Compiler `release-fast-b9fea521`, source
at `~/Repositories/roc`, macOS arm64, basic-cli 0.21.0. Times are wall clock from
`/usr/bin/time -p` unless the row says otherwise. `--no-cache` where a cold fold
is being measured; the cache result itself is row 6.

Every number below was taken in one session on 2026-09-01. Nothing here is a
prediction.

## 1. Compile-time evaluation happens, and it is unbudgeted

`probes/fold/fold.roc` — a tail-recursive `spin` over N iterations bound to a
top-level `U64`.

| N | build | run |
|---|---|---|
| 200 000 000 | 1.15 s | 0.176 s |
| 2 000 000 000 | 9.91 s | 0.172 s |

Ten times the work, ten times the *build*, flat runtime. There is no wall-clock
budget: the compiler runs the loop to completion. `roc check` narrates it —

    | Evaluating `table = build([], 100)` at compile time in fold6:24:1 (4s)

## 2. Heap values fold, land in the binary, and survive to runtime

`probes/fold/fold6.roc` — `List(U64)` of 100 elements, each costing
`spin(0, 10_000_000)`, indexed at runtime by a value derived from `args`.

Build 4.93 s. First run 0.244 s, second run 0.006 s, correct value. The list is
not recomputed at runtime, and it is not recomputed per run.

## 3. Folding is not restricted to top-level definitions

`probes/fold/inbody.roc` — `x = spin(0, 1_000_000_000)` bound inside `main!`.
Build 5.52 s, run 0.168 s.

## 4. The shapes a regex artifact needs all fold

`probes/fold/shapes.roc` — three definitions, each gated behind
`spin(0, 300_000_000)`:

- `List([Byte(U8), Split(U64, U64), Jmp(U64), Match])` — tag union with payloads
- `List(List(U64))` — nested
- `{ name : Str, ids : List(U64) }` — record carrying a `Str`

All three fold. 4.72 s user against 1.74 s wall: **independent definitions fold
in parallel.**

## 5. A crash inside a folded expression is a build error

`probes/fold/crashy.roc` reaches `crash "empty pattern"` during folding. The
build fails with `✗ compile time crash`, quoting the crash message and pointing
at both the definition that crashed and the call site.

`probes/fold/errs_bad.roc` is the same mechanism through ordinary error
handling: `compile : Str -> Try(_, Error)` returning `Err`, and a caller-side
`unwrap` that crashes on the `Err` branch. An invalid literal pattern fails the
build with the rendered message —

    regex: 2 unclosed group(s)

— while `probes/fold/errs.roc`, the valid pattern, builds and runs. This is the
whole compile-time-validation story and it needs no new language feature.

## 6. Folds are cached across builds

`probes/bisect` variant A: cold `--no-cache` 1.24 s, warm 0.22 s. The cost is
paid per changed module, not per build.

## 7. Fold eligibility is per-call-expression, all-or-nothing on arguments

This is the load-bearing result and it was found by correcting an earlier bad
probe. The first version put the expensive call's argument as a literal
independent of the pattern, so what folded was a constant subexpression, not a
specialization. With the work made dependent on the argument:

| rig | shape | build | run | folds |
|---|---|---|---|---|
| `v1.roc` | `re = R.compile("a+b")` at top level | 2.64 s | 0.18 s | yes |
| `v2.roc` | same, bound inside `main!` | 2.68 s | 0.16 s | yes |
| `v4.roc` | via `get = \|pat\| R.compile(pat)` | 2.83 s | 0.18 s | yes |
| `v5.roc` | via two helper levels | 2.65 s | 0.21 s | yes |
| `v3.roc` | `R.matches("a+b", hay)` — literal **and** runtime arg | 0.29 s | 0.62 s | **no** |

Constant arguments propagate through arbitrarily deep helper chains. One runtime
argument anywhere in a call's argument list disables folding for everything
inside that call, including the parts that depend only on the constants. There
is no partial specialization.

## 8. Folded lists are embedded packed at the element width

`probes/fold/tbl.roc`, 1 000 000 elements, runtime index, baseline binary
390 704 bytes subtracted:

| element | growth | bytes/elem |
|---|---|---|
| `U8` | 1 001 376 | 1.00 |
| `U16` | 2 002 768 | 2.00 |
| `U32` | 4 005 520 | 4.00 |
| `U64` | 8 011 024 | 8.01 |

An earlier reading of "no size change" was a broken shell substitution building a
stale binary, not a compiler behaviour.

## 9. There is no unchecked indexing available to user code

`list_get_unsafe` and `str_get_utf8_byte_unsafe` exist in
`src/canonicalize/BuiltinLowLevel.zig` but are not reachable from Roc:
`List.get_unsafe does not exist`. The inner loop is `List.get -> Try(U8,
[OutOfBounds])`, bounds-checked, per byte.

## 10. Compiler bug found — data-carrying nominal types

`probes/fold/varB.roc` with `probes/fold/engB/`. A nominal type whose payload is
a record containing a `List`, with a methods block:

```roc
Eng := { prog : List(U64) }.{ ... }
```

SIGSEGV in `postcheck/monotype/lower.zig:16175 instNodeContent`, reached through
`compile_time_finalization.zig`. Reproduces in-app and across a package
boundary, **and whether or not the value is folded** — a variant taking its input
from `args` crashes at the same site, so this is monotype lowering, not
compile-time evaluation.

`probes/fold/varE.roc` — the roc-markdown idiom, namespace module `E := [].{ Eng
: { prog : List(U64) } ... }` with a transparent alias — builds, folds and runs
correctly.

Owed upstream as a bug report. It does not steer the design: Roc is pre-0.1 and
"this crashes the compiler today" carries no signal about whether a design is
right. The plan uses the type it wants and the bug gets filed.
