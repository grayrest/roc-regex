# Segfault: nominal type with a methods block, unwrapped by a lambda pattern

**Title for the tracker:** `Segfault in monotype lowering: any data-carrying nominal type with a methods block, unwrapped via a lambda argument pattern`

**Version:** `Roc compiler version release-fast-b9fea521` (`b9fea5215e fix(monotype): skip the spec-lookup cache for an unresolved node`), macOS arm64.

---

## Summary

Declaring a nominal type with a payload and a methods block, then destructuring
it in a **lambda argument pattern** (`|W(n)| …`), segfaults the compiler in
`postcheck/monotype/lower.zig`. It reproduces in a single file and across a
package boundary, for every payload shape tried, and is independent of
compile-time evaluation — a variant whose value comes from `argv` crashes at the
same site.

## Minimal reproduction

One file, no package needed:

```roc
app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst" }

import pf.Stdout

W := U64.{
	make : U64 -> W
	make = |n| W(n)

	unwrap : W -> U64
	unwrap = |W(n)| n
}

main! = |_args| Stdout.line!(W.unwrap(W.make(7)).to_str())
```

```
$ roc build --no-cache a1.roc

Segmentation fault (SIGSEGV) in the Roc compiler.
Fault address: 0x309397492

Stack trace:
src/postcheck/monotype/lower.zig:16175:24: in instNodeContent (roc)
        return switch (checkedPayload(self.view, checked_ty)) {
                       ^
src/postcheck/monotype/lower.zig:17910:34: in lowerLambdaArgsAndBodyAtCell (roc)
                try self.instNode(self.view.bodies.pattern(pattern_id).ty),
                                 ^
src/postcheck/monotype/lower.zig:16548:75: in lowerTemplateBodyAtNode (roc)
src/postcheck/monotype/lower.zig:4012:61: in lowerReservedTemplateBodyIntoDraft (roc)
src/postcheck/monotype/lower.zig:3848:68: in completeTemplateReservation (roc)
src/postcheck/monotype/lower.zig:3932:45: in executePendingSpecJob (roc)
src/postcheck/monotype/lower.zig:441:37: in run (roc)
src/lir/checked_pipeline.zig:523:48: in lowerCheckedModulesToLir (roc)
src/eval/compile_time_finalization.zig:2257:56: in lowerFinalizationModulesToLir (roc)
```

`lowerLambdaArgsAndBodyAtCell` is lowering the lambda's argument *pattern* type,
so the trigger looks like the destructuring pattern rather than the nominal type
itself.

## Scope

| variant | result |
|---|---|
| single file, `\|W(n)\|` lambda pattern | **SIGSEGV** |
| across a package boundary, `\|W(n)\|` | **SIGSEGV** |
| payload `U64` | **SIGSEGV** |
| payload `Str` | **SIGSEGV** |
| payload `{ a : U64 }` | **SIGSEGV** |
| payload `[A(U64), B]` | **SIGSEGV** |
| value derived from `argv` (nothing folded) | **SIGSEGV**, same site |
| namespace module + transparent alias (`N := [].{ Wrapped : U64 … }`) | builds and runs |

## A second, probably related bug

Replacing the lambda pattern with a `match` avoids the segfault but produces two
bogus diagnostics instead:

```roc
	unwrap : W -> U64
	unwrap = |w| match w { W(n) => n }
```

```
── ✗ compile time crash ─ app.roc:2:27
pf: platform "https://github.com/.../4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
                         ^^^^
    runtime error

── ✗ type mismatch ─ W.roc:3:13
make = |n| W(n)
```

The type mismatch is on the nominal type's own constructor applied to a value of
its declared payload type, and the compile-time crash is attributed to the
platform URL in the app header — a line unrelated to any of it.

## Impact

This makes data-carrying nominal types unusable, which removes the only
mechanism for an opaque type. A library that wants its handle type to be opaque
has to ship a transparent record instead and rely on documentation, since Roc
has no field privacy.

## Files

Repro files are in the reporting project at `notes/probes/fold/` (`varB.roc`
plus `engB/`, the original larger case) and reproduced minimally above.
