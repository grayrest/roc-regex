# `List.set`/`List.get` on a linearly-threaded buffer emits the uniqueness/clone guard and doesn't inline

**Compiler:** `Roc compiler version release-fast-b9fea521`
**Host:** arm64 macOS (Darwin 25.3.0), `--opt=speed`

## One line

A `List.set` on a buffer that is threaded strictly linearly — passed to a
function and its result rebound, so there is exactly one live reference — still
compiles to: a seamless-slice discriminant decode, a **runtime refcount==1
uniqueness check guarding a full clone path** (`roc_alloc` + `memcpy` + old
`decref`), and, when the call isn't inlined, a **12-register prologue** around a
single store instruction. The clone path is provably dead and the guard is
provably true, but both are emitted. In a hot loop this is the difference
between ~30 instructions and ~3 per element update.

## Why it matters (the workload)

This is a byte-oriented regex engine (a PikeVM). Its inner loop is a
thread-set simulation that, per input byte, does ~150–200 `List.get`/`List.set`
on a handful of reused, linearly-threaded scratch buffers (a visited-generation
array, a DFS stack, the thread queues). No allocation happens in the steady
state — the buffers are reused — so profiling a scan shows the time going almost
entirely into these accesses and their guards, not into matching.

Against Rust's `regex-automata` **PikeVM** (same O(n·states) algorithm, a
sparse-set with unchecked indexing), this Roc engine is ~10× slower, and a
disassembly says the ~10× is almost exactly the per-access instruction ratio:
Rust does bounds-check + store (~2–3 instructions), Roc does the guard sequence
below (~30). It is not the algorithm, not GC, not allocation.

## The minimal case: `spush`

`spush` pushes onto a reused buffer, growing only at the frontier:

```roc
spush : List(U32), U64, U32 -> List(U32)
spush = |stack, i, v|
    if i < List.len(stack) { List.set(stack, i, v) ?? stack } else { List.append(stack, v) }
```

Its caller threads `stack` linearly — the buffer's only use each step is the
`spush` call, whose result is rebound — so `stack` has exactly one owner at the
`List.set`. `repro.roc` in this directory drives 20M such pushes over a reused
2000-element buffer and runs in ~0.04 s; the point is the emitted code, not the
time. Build it `--opt=speed --debug` and disassemble `spush` (or `main`, into
which it may inline in a program this small).

## The disassembly

Full annotated listing in `spush.disasm` (captured from the regex build, where
`spush` stays a separate proc). The shape:

```
+0 .. +24   sub sp,#0x80 + save 12 callee-saved registers   ← prologue for the
                                                               COLD clone path
+40 .. +68  and #1 / lsr / csel / orr / cbz                 ← seamless-slice
                                                               discriminant decode
+72 .. +92  ldr [x-0x8]; cmp #1; b.ne clone                 ← UNIQUENESS CHECK:
                                                               refcount==1? else clone
+104        str w24, [x20, x25, lsl #2]                     ← the store (1 instr)
+164 ..     roc_alloc / memcpy / roc_dealloc                ← CLONE path (dead here)
```

One instruction (`+104`) does the work. The store is guarded by a slice-bit
decode and a refcount load+compare+branch, and the function reserves a 128-byte
frame and saves 12 registers it only needs if it takes the clone path — which,
for a uniquely-owned buffer, it never does.

## What should happen

Each piece is removable without touching the source or the algorithm:

1. **Elide the uniqueness check and the clone path when the buffer is provably
   uniquely owned.** Here it is: `stack` is a function parameter used once (the
   `List.set`) and returned; the caller rebinds the result and never reuses the
   old binding. This is exactly what reuse / borrow analysis is for, and it
   isn't firing across the `spush` call boundary (nor when the same
   `List.set ... ?? x` is written inline — see note below).
2. **Split the cold clone path out** so the fast path doesn't carry a
   12-register prologue for a call it never makes.
3. **Inline `spush`.** It's a one-line helper called ~15×/position; the backend
   keeps it as a `bl` with the full frame above. (Manually inlining it removed
   the *frame* and bought ~3% on other patterns — but nothing on the
   push-heaviest pattern, which confirmed the dominant cost is the per-access
   guard in item 1, not the call.)
4. **Specialize away the seamless-slice discriminant** for lists known not to be
   slices (these buffers never are).

With (1) alone, a `List.set` on a proven-unique buffer becomes ~store + a bounds
check, i.e. Rust's ~2–3 instructions, and the ~10× hot-loop gap largely closes.

### Note on the `?? default` idiom

Every access in this engine is `List.set(x, i, v) ?? x` / `List.get(x, i) ?? d`
because `List.set`/`get` return a `Try`. In isolation this idiom does mutate in
place (it is not the source of cloning), but it also carries the guard above and
a branch on the `Try`. If the index is provably in range, the whole `Try` +
fallback should fold away.

## Reproduction

```
roc build --no-cache --opt=speed --debug repro.roc && ./repro   # prints r=7, ~0.04s
# then disassemble `spush` (or `main`) and compare +104 (the store) to the
# guard/prologue around it.
```

`spush.disasm` is the captured listing from the regex hot path; `repro.roc` is
a standalone, package-free driver of the same `spush`.
