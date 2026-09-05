# Heap corruption: `var` list appended both inline and inside a helper

Roc `release-fast-84812227`, macOS arm64. Found while tuning package-sharp's
reverse sweep (commit 7cf2d73 of this repo plus the uncommitted `Dfa.roc` of
that session; `repro.roc` carries the loop variants verbatim).

## Symptom

A `while` loop over a `var acc : List(U64)` that appends to `acc` inline in
one branch and, in another branch, reassigns it from a helper that appends
(`acc = Dfa.set_null_fast(e, s, acc, hay, pos)`) corrupts the heap. Plain
runs die later in `malloc` (`EXC_BAD_ACCESS` in `tiny_malloc_from_free_list`,
or a Rust panic inside the host's allocator: "thread panicked while
processing panic"). Whether it crashes depends on code layout: adding unused
functions to the app made the same loop pass, and `roc build` vs
`roc build --opt=speed` differ.

Guard Malloc makes it deterministic:

    roc build repro.roc
    lldb -b -o "env DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib" -o run -o "bt 10" ./repro -- <256 KB text file>

The faulting instruction is a `str x22, [x8, x27, lsl #3]` in generated code:
a U64 store at index `x27` of a list buffer, one past the end of a Guard
Malloc page, i.e. an append writing past the buffer's capacity. It looks like
the caller keeps a stale (pointer, capacity) for `acc` after the helper's
in-place append reallocated it.

## What passes and what fails (`repro.roc`, run in order under Guard Malloc)

- `cp_b2`: all appends inline — passes.
- `cp_b3`: inline appends, helper call only on a path that never runs — passes.
- `cp_b4`/`cp_b5`: as b3 plus a never-taken branch with more helpers — pass.
- `cp_b`: the helper actually runs in one branch (state 4 is nullable),
  inline appends in the other — **crashes**.
- `cp_c`: `cp_b` with the tables hoisted into locals — crashes.

`no-repro-minimal.roc` is a standalone attempt (helper appends, inline
appends, alternating) that does NOT reproduce; the trigger needs something in
the real helper (it takes a large record parameter and branches into a second
appending helper). Reduction still owed.

## Workaround used

Every append to a loop's `var` list is written inline in the loop function;
helpers return fresh lists (`Dfa.pend_positions`) that the loop appends
element by element. This was also the faster shape.
