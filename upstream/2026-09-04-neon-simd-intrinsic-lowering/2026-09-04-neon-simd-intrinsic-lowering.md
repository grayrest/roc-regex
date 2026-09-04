# `U8x16.to_bitmask` / `concat_shift_bytes` lower to scalar sequences on AArch64 NEON

**Compiler:** `Roc compiler version release-fast-43746ac5`
**Host:** arm64 macOS (Darwin 25.3.0)
**Status:** **FIXED** by the local `roc-simdfix` build — validated below.

## One line

In a 128-bit-NEON SIMD scan built with `--opt=speed`, a per-window
`…bitwise_not().to_bitmask()` (movemask) plus `concat_shift_bytes` (byte align)
lower to a long **scalar** teardown — the 16-byte vector is pulled into GPRs
lane-by-lane (`umov.b`/`fmov`/`mov.d`/`extr`) and recombined with scalar `orr` —
instead of the NEON idioms (`shrn`/`addv` movemask; `ext.16b` align). It roughly
doubles the scan's per-window cost. `roc-simdfix` removes the scalar path and the
scan gets ~2.5× faster (details below).

## Scope note (what does and does not exercise this)

This is a regex engine. Its 128-bit **Teddy** literal prefilter
(`package/Teddy.roc`, `scan`/`candidates`) is the SIMD scan in question, and it
is reached only through `Regex.find` (single search on a pattern with a required
literal prefix). **`Regex.find_all` does not use Teddy** — it runs the lazy-DFA
engine — so `examples/bench.roc` (which calls `find_all`) contains no Teddy code
at all, and the old/new compilers produce a byte-identical `bench` binary. That
is consistent with this bug, not a counterexample: the fix only changes objects
that actually emit `to_bitmask`/`concat_shift_bytes`. The numbers below come from
a direct scan microbenchmark, not from `find_all`.

## Measurement (`--opt=speed`, in-process, 256 KiB haystack, literal `Holmes`, m=3)

The full Teddy inner loop (two `tbl.16b` lookups + `concat_shift_bytes` +
`bitwise_not().to_bitmask()`), scanned allocation-free:

| | ns / 256 KiB | throughput |
|---|---|---|
| stock `roc` (`release-fast-43746ac5`) | ~63,400 | ~4.1 GB/s |
| **`roc-simdfix`** | **~25,400** | **~10.3 GB/s** |
| `aho-corasick` 128-bit Teddy (Rust ref) | ~29,900 | ~8.8 GB/s |

The fix is ~2.5× and takes the Roc scan past the Rust reference. Reference bin:
`tools/bench/src/teddy.rs` (aho-corasick packed, forced 128-bit).

## Evidence (`--opt=speed`, not `--debug`)

Caveat that cost the first draft of this report: a **`--debug`** build shows an
even worse ~46-instruction scalar `to_bitmask`, but that is debug codegen. Under
`--opt=speed`, a *simple* `eq_lanes(0).to_bitmask()` already optimizes to `shrn`
— so a minimal repro can hide the bug. The **full** Teddy chain does not: the
stock `--opt=speed` scan loop is 79 instructions, **34 of them scalar extract /
recombine** (`umov.b`, `extr`, `mov.d`, `fmov`, `orr`). `to_bitmask.disasm` in
this directory is that loop. The shape:

```
mov.d x8, v3[1] / fmov x9, d3 / extr x8, x8, x9, #0x38   ; concat_shift_bytes,
mov.d x10, v2[1] / fmov x11, d2 / extr x10, x10, x11, #0x38 ;  done in GPRs
umov.b w8,  v4[0]                                         ; to_bitmask: pull
umov.b w10, v4[1]                                         ;  each lane to a GPR
umov.b w11, v4[6] / umov.b w12, v4[7] / …                 ;  …then scalar orr
```

`roc-simdfix` compiles the same source to a loop with **0 `umov.b`, 0 `extr`** —
`tbl.16b`/`and.16b` plus a `shrn`-based movemask, no GPR round-trip.

## What should happen (and what the fix does)

1. **`to_bitmask` → shift-narrow movemask.** For a per-lane 0x00/0xFF mask:
   `shrn.8b v,v.8h,#4; fmov x,d` gives a 64-bit value at 4 bits/lane; test with
   `cbz`/`tst`. (x86 lowers this to a single `pmovmskb`.) The stock backend does
   this for a bare `to_bitmask`, but the `bitwise_not().to_bitmask()` /
   full-Teddy combination falls back to the per-lane scalar path.
2. **`concat_shift_bytes` → `ext.16b vd,vn,vm,#k`** — one instruction, not the
   `mov.d`/`fmov`/`extr` GPR pair.

`roc-simdfix` emits both, closing the gap.

## Reproduction

`repro.roc` here carries a previous window, `concat_shift_bytes`-aligns it, and
`bitwise_not().to_bitmask()`s — enough that the stock/`roc-simdfix` binaries
differ at `--opt=speed`:

```
roc          build --opt=speed repro.roc && objdump -d ... | grep -c umov.b   # >0
roc-simdfix  build --opt=speed repro.roc && objdump -d ... | grep -c umov.b   # 0
```

The scalar path is most pronounced in the real m=3 Teddy (two `concat_shift`s +
interleaved `and.16b` + final movemask): `package/Teddy.roc`'s `scan` — 79-instr
loop, 34 scalar-extract, at stock `--opt=speed`. `to_bitmask.disasm` is that
loop. Timing that scan in-process over a 256 KiB haystack gave the ~63k→~25k
ns/iter above. (A *bare* `to_bitmask`, and small combinations, already lower to
`shrn` at `--opt=speed` — so a minimal repro understates it; the multi-fingerprint
register pressure is what tips the backend into the scalar teardown.)
