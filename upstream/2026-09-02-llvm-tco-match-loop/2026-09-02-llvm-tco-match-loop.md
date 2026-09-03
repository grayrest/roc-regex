# LLVM (`--opt=speed`) backend does not tail-call-optimise a self-recursive loop when the body is "large"

**Compiler:** `Roc compiler version release-fast-b9fea521`
**Host:** arm64 macOS (Darwin 25.3.0)
**Backends:** fails on `--opt=speed` (LLVM); works on `--opt=dev` (native dev backend).

## One-line

A tail-recursive function that iterates once per regex match overflows the
stack (SIGBUS) under `--opt=speed`, but only when the recursive call's body is
big enough (it inlines a non-trivial matcher). Simple bodies with the *same*
recursion shape and the *same* iteration count are turned into a loop and run
in O(1) stack. The `dev` backend loops in every case.

This is very likely a size/complexity threshold in whichever pass turns a
tail-recursive call into a loop (LLVM `tailcallopt` / our lowering of it), not
a correctness bug in user code: the recursion is in tail position and the dev
backend handles it.

## Symptom

`Regex.find_all` (this repo) crashed with `EXC_BAD_ACCESS` / exit 138 on larger
haystacks. It is not input size per se and not the SIMD path — it tracks the
**number of matches** for a given pattern, and only for "complex enough"
patterns:

| pattern (over its haystack)        | matches | `--opt=speed` |
|------------------------------------|--------:|---------------|
| `a` over 300k `'a'`                | 300000  | ok            |
| `[a-z]` over 300k `'a'`            | 300000  | ok            |
| `[A-Za-z]+` over 100k `"a "` pairs | 100000  | **SIGBUS**    |
| `[A-Za-z]+` over 256 KiB prose     |  40161  | **SIGBUS**    |
| `Holmes` over 256 KiB prose        |   1202  | ok            |
| 8-way literal alternation, 256 KiB |   9447  | **SIGBUS**    |
| same alternation, 64 KiB           |   2383  | ok            |

So for a *simple* matcher the loop is optimised regardless of iteration count
(300k fine); for a *complex* one it is not, and then depth = match count blows
the 8 MB stack after a few thousand frames.

## Minimal repro

`repro.roc` in this directory is self-contained (generates its own haystack, no
data file). It reproduces against the **pre-fix** recursive `all_caps` (see
"The code" below). With that recursive form:

```
roc build --no-cache --opt=speed repro.roc && ./repro   # -> SIGBUS (exit 138)
roc build --no-cache --opt=dev   repro.roc && ./repro   # -> "matches: 100000"
```

## The code

The loop that overflows (pre-fix `package/Regex.roc`):

```roc
all_caps = |re, hay| Regex.all_loop(re, hay, 0, Regex.sentinel, [])

all_loop : Regex.T, List(U8), U64, U64, List(List(U64)) -> List(List(U64))
all_loop = |re, hay, at, last_end, acc|
    if at > List.len(hay) {
        acc
    } else {
        match Pike.captures_from(Regex.base(re), hay, at) {   # <- heavy, inlined
            Err(_) => acc
            Ok(slots) => {
                s = List.get(slots, 0) ?? 0
                e = List.get(slots, 1) ?? 0
                if s == e and e == last_end {
                    Regex.all_loop(re, hay, Regex.next_bound(hay, e), last_end, acc)   # tail
                } else {
                    nat = if s == e { Regex.next_bound(hay, e) } else { e }
                    Regex.all_loop(re, hay, nat, e, List.append(acc, slots))           # tail
                }
            }
        }
    }
```

Both recursive calls are in tail position. `Pike.captures_from` is a large
function (it sets up and calls the recursive PikeVM `run` → `exec` → `close`).

## Backtraces (`--opt=speed --debug`, arm64)

The crash is the entry stack-probe of a newly pushed frame, so `lldb`'s
unwinder mostly fails, but the frames it does show are the self-recursion:

Pre-fix `all_loop`:
```
frame #0: roc__proc_536b at Regex:184           # all_loop body
frame #1: roc__proc_536b at Regex:196:25         # all_loop's own tail call
```
`sp - x9 = 0x2000` at the probe; each recursive frame is ~0x8f0 (2288) bytes,
so ~3.6k frames exhaust an 8 MB stack — matching the observed threshold.

An intermediate attempt (recurse on a *captured* closure instead of threading
the big `Regex.T` record) raised the threshold but did not remove it; the
matcher chain is inlined straight into the loop body:
```
frame #0: roc__proc_4e4c at Pike:122             # close
frame #1: ...             at Pike:118  [inlined]  # add -> close
frame #2: ...             at Pike:70   [inlined]  # run -> add
frame #3: ...             at Pike:35   [inlined]  # captures_from -> run
frame #4: roc__proc_4e41  at Regex:194            # the loop closure `go`
frame #6: roc__proc_4e41  at Regex:203            # `go` recursing (not looped)
frame #7: roc__proc_4e41  at Regex:203
```

## What does NOT reproduce (negative results — narrows the trigger)

All of these are tail-recursive with the *same* shape and TCO fine under
`--opt=speed` at 200k–5M iterations, so none of the following alone is the
trigger:

1. Plain counter `count(n-1, acc+1)` — 50M.
2. Recursion nested inside `match` + `if` (arms return the recursive call) — 20M.
3. `List(List(U64))` accumulator with `List.append(acc, x)` in the tail arg,
   plus a `Try`-returning callee matched in the body — 200k.
4. Recursing while threading a large by-value record (9 `List` fields) — 5M.
5. Body inlines a helper that builds a small heap list — 300k.
6. Body inlines a helper that contains its own inner (bounded) recursion — 100k.

The real `captures_from` differs by being substantially larger than any of
these mocks (threads `Comp.Compiled`, builds `Cl` closure records holding two
`List`s, recurses through `close`). The distinguishing factor appears to be the
**size of the inlined loop body**, consistent with a code-size gate on
tailcallopt.

## Workaround / fix applied in this repo

Rewrote `all_caps` as an explicit `while` loop with `var` state, so it does not
depend on tail-call optimisation at all (O(1) stack for any match count). This
is arguably the more idiomatic form for an unbounded loop anyway. Verified:
256 KiB and 1 MiB haystacks with 40k–160k matches run clean; differential
harness 860/860 vs Rust; smoke 21/21.

## Questions for the compiler investigation

1. Does `--opt=speed` intend to guarantee TCO for tail-position self-calls, or
   is it best-effort? (`--opt=dev` clearly does it here.)
2. If best-effort, is the gate LLVM's own `tailcallopt` bailing on frame size /
   byval memory args, or does our lowering stop emitting the loop above some
   body size? Inspecting the emitted LLVM IR for the failing `roc__proc_*`
   (does it `musttail`/`tail`-mark the self-call, or emit a real `call`?) would
   settle it.
3. If it is a genuine size threshold, is a diagnostic warranted when a
   tail-recursive function that *could* loop is left as recursion (so users
   aren't silently exposed to stack growth under one backend but not the other)?
