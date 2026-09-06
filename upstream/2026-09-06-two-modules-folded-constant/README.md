# Two modules each holding a folded constant: compiler panic

`roc build` panics when an app imports **two different modules that each hold a
top-level value produced by compile-time evaluation**. Either module alone is
fine; the two together are not. The reproducer here panics with and without
`--no-cache`; a larger real case (`examples/http.roc` in this repo) panics
only under `--no-cache` and builds on the cached path, so the cache appears to
hide it rather than to cause it.

    Roc compiler version release-fast-5f9a6e18

## Reproduce

```
roc build --output=out_a  app_a.roc    # ok
roc build --output=out_b  app_b.roc    # ok
roc build --output=out_ab app_ab.roc   # panics, every time, cached or not
```

`app_ab` is `app_a` and `app_b` side by side, importing both modules and
calling both. The panic message varies between runs and between variants of
the same shape; all three of these have appeared:

```
thread N panic: boxy ABI wrapper called before roc_boxy runtime initialization
thread N panic: compile-time RocOps deallocated unknown pointer
Segmentation fault (SIGSEGV) in the Roc compiler.  Fault address: 0xfffffffffffffff8
```

They look like the compile-time evaluator's allocator: a pointer freed through
the wrong allocator, or the boxy runtime being used before it is initialized.

## What each module does

`A.roc` and `B.roc` are identical apart from the module name and one character
of the pattern. Each has ONE top-level value whose initializer the compiler
evaluates at build time — here `Sharp.compile`, which builds a regex automaton
and returns a record of flat `List(U32)`s:

```roc
import sharp.Sharp
A := [].{
    m : Sharp.T
    m = Sharp.unwrap(Sharp.compile("[A-Z]+"))
    run : List(U8) -> U64
    run = |h| match Sharp.longest_end(A.m, h) { Ok(e) => e, Err(_) => 0 }
}
```

The app derives its haystack from `args` so the call itself cannot fold and
the constant has to survive into the binary.

## Not the trigger

Each of these was checked separately and builds:

- **Several folded constants in ONE module.** Ten of them in one module, all
  used, builds and runs.
- **The number of them.** Two is enough, across two modules.
- **The pattern.** Every pair tried fails, including two plain literals.
- **This package.** A module whose folded value is an ordinary recursive
  function over lists and tag unions -- no dependency on the regex package at
  all -- shows the same thing in the real case that led here.

## Why it matters here

`package-http/Http.roc` and `package-http/Route.roc` each hold their matchers
as top-level folded values, which is the point of the design: a matcher is
built at compile time and stored in the artifact. An app that frames a request
AND routes it imports both, so the whole package cannot be built cleanly.
`examples/http.roc` builds and passes 49/49 on the cached path and panics
under `--no-cache`, which is what `tools/sharp-size/breakdown.sh` uses, so the
artifact-size measurement for that example cannot be taken.
