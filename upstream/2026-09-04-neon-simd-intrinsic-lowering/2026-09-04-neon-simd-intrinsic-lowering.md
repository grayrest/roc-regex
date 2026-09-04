# `U8x16.to_bitmask` (and `concat_shift_bytes`) lower to long scalar sequences on AArch64 NEON

**Compiler:** `Roc compiler version release-fast-43746ac5`
**Host:** arm64 macOS (Darwin 25.3.0), `--opt=speed`

## One line

`U8x16.to_bitmask()` compiles to a **46-instruction** per-lane scalar extraction
(`umov.b`/`mov.b`/`fmov`/`orr`) instead of the standard ~4-instruction AArch64
NEON movemask reduction (`shrn.8b v, v.8h, #4; fmov x, d; …`). In a SIMD scan
loop this single intrinsic dominates the per-window cost and makes an otherwise
identical algorithm run ~2–3× slower than the C/Rust equivalent. A second,
smaller instance: `concat_shift_bytes` (a byte-wise vector shift/align) lowers to
a 28-instruction scalar GPR path instead of a single `ext.16b`.

## Why it matters (the workload)

This is a regex engine whose literal prefilter is a 128-bit **Teddy** — the same
algorithm as `aho-corasick`'s packed Teddy: per 16-byte window it does two
`tbl.16b` (pshufb) table lookups, some `and.16b`, a byte-align (`ext.16b`), and
one **movemask** (`to_bitmask`) to extract candidate lanes. No data structures
are built in the scan; it is pure SIMD over bytes. Both this engine and
`aho-corasick` go through LLVM and emit 128-bit NEON on arm64, so equivalent
source should produce equivalent code.

It doesn't. Scanning an identical 256 KiB haystack for the literal `Holmes`
(`m = 3` fingerprint), allocation-free on both sides:

| | ns / 256 KiB | throughput |
|---|---|---|
| `aho-corasick` 128-bit Teddy (Rust) | 30,400 | 8.6 GB/s |
| this engine's `Teddy.scan` (Roc) | 65,850 | 4.0 GB/s |

**~2.17× slower.** Isolating `to_bitmask` with a single-byte fingerprint
(`m = 1`, no `concat_shift_bytes`) widens the gap to **~3.4×** (Roc 58,056 ns vs
Rust 17,061 ns) — i.e. the movemask is the dominant term: with less surrounding
work it accounts for *more* of the loop, not less.

## The disassembly

Captured from the regex build; `to_bitmask.disasm` and `concat_shift_bytes.disasm`
in this directory are the full blobs, `repro.roc` is a standalone package-free
driver that reproduces the movemask blob in `_roc_main`.

### `to_bitmask` — 46 instructions for one movemask

The whole block for `cand.eq_lanes(0).bitwise_not().to_bitmask()` is a per-lane
teardown of the 16-byte vector into GPRs and a scalar OR-reduction:

```
cmeq.16b v6, v5, #0
cmtst.16b v5, v5, v5
umov.b   w8,  v5[0]      ; and w8, w8, #0x80
umov.b   w10, v5[1]      ; and w10, w10, #0x2
mov      b2,  v5[2]  /  mov.b v2[4], v5[3]
umov.b   w11, v5[6]      ; …
… (16 lanes extracted one at a time) …
zip2.8b  v5, v5, v0
fmov     x16, d5
orr      w16, w16, w17
orr      w16, w16, w16, lsr #16
… (a dozen scalar orr to fold the lanes) …
tst      w8, #0xff
cset     w26, ne
```

### `concat_shift_bytes` — 28 instructions for one `ext.16b`

`prevN.concat_shift_bytes(resN, k)` (take the top `16-k` bytes of `prev`
concatenated with the low `k` of `res`, i.e. a byte align) is done by moving both
halves of each vector to GPRs and recombining with `extr`/`orr`:

```
mov.d x8, v4[1] / fmov x9, d4 / extr x8, x8, x9, #0x38 / …
extr  x8, x8, x9, #0x30 / mov.d x10, v3[1] / fmov x11, d3 / extr x10, x10, x11, #0x38 / …
```

AArch64 has `ext.16b vd, vn, vm, #k` for exactly this — one instruction.

## What should happen

Both are standard NEON idioms that LLVM emits for the equivalent C intrinsics /
`std::simd`; the Roc lowering is emitting IR that the backend can't recognize as
a movemask / vector-align and falls back to scalar.

1. **`to_bitmask` → the shift-narrow reduction.** For a per-lane 0x00/0xFF mask:
   `shrn.8b v0, v0.8h, #4` packs the 16 lanes into a 64-bit register at 4 bits
   each; `fmov x, d0` then a `cbz`/`tst` (or per-set-bit iteration via `rbit`
   + `clz`). ~3–4 instructions. (The equivalent x86 lowering is a single
   `pmovmskb`.) Alternatively `and` with a per-lane bit-position vector then
   `addv`/`addp`.
2. **`concat_shift_bytes` → `ext.16b vd, vn, vm, #k`.** One instruction.
3. If these are lowered via hand-written IR sequences, emitting the target
   intrinsic (`@llvm.aarch64.neon.*`) or the shufflevector/`lshr`+`trunc` pattern
   LLVM canonicalizes to `shrn` would fix it without a source change.

With (1) alone the Teddy scan's per-window instruction count roughly halves and
the ~2–3× gap to `aho-corasick` should largely close.

## Reproduction

```
roc build --no-cache --opt=speed --debug repro.roc
# disassemble _roc_main; the per-window loop body is: ldr q, cmeq.16b, then the
# ~46-instruction umov.b/mov.b/fmov/orr movemask (no shrn/addv) shown above.
./repro <any-file>   # prints the count of 16-byte windows containing a 0 byte
```

`to_bitmask.disasm` / `concat_shift_bytes.disasm` are the captured blobs from the
regex Teddy scan (`package/Teddy.roc`, `count`/`scan`).
