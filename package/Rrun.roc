## The reverse mirror of `Dfa.Len` (2026-09-07): the sweep for a pattern that
## is ONE minterm class repeated `lo..hi` times needs no automaton at all.
##
## `_*·cls{lo,hi}` is nullable at `p` exactly when `lo` symbols of `cls` start
## at `p`, so for every maximal run of class bytes `[a, b)` the match starts are
## `a .. b - lo` and nothing else. `Dfa.starts_fast_opts` hands those straight
## to the forward end pass.
##
## Why it is worth a module: the sweep it replaces re-enters `Bset.rfind` once
## per run, and a re-entry costs ~16 ns against the kernel's 1.3 ns a window --
## not because it is a call (hoisting the vectors saves 0.6 ns, inlining the
## body 1.6) but because the next window's address is a `clz` of the last hit's
## mask, so the machine cannot run ahead. Here the window loop's address never
## depends on what the window held, and the run bookkeeping rides along beside
## it. Measurements in `notes/2026-09-05-package-sharp-design-log.md`.
##
## Only sound when the class holds no non-ASCII codepoint: `Bset`'s tables
## cannot represent a byte >= 0x80 as a member, and the kernel here does not
## OR the high bit in, so a multibyte symbol reads as a run boundary. It is one
## for an ASCII-only class, and `Accel` will not build this otherwise.
import Bset

Rrun := [].{
    ## `tab` is the class's `Bset` table (16 bytes, set 0); `lo` its minimum
    ## repetition.
    Spec : { tab : List(U8), lo : U64 }

    ## `0` means no run is open: a run's exclusive end is at least 1.
    no_run : U64
    no_run = 0

    lanes : U64
    lanes = 16

    ## Match starts in DESCENDING position order, as the sweep produces them.
    collect : List(U8), List(U8), U64 -> List(U64)
    collect = |hay, tab, lo| {
        n = List.len(hay)
        lov = Bset.load(tab, 0)
        hiv = Bset.hi_vec
        zero = U8x16.splat(0)
        var acc = []
        var run_end = Rrun.no_run
        var pos = n
        while pos >= Rrun.lanes {
            w = pos - Rrun.lanes
            m = Bset.mask_ascii(lov, hiv, U8x16.load(hay, w) ?? zero)
            # an open run that this window's top byte does not continue ends at
            # the window boundary
            if run_end != Rrun.no_run and m.bitwise_and(0x8000) == 0 {
                a = w + Rrun.lanes
                if run_end - a >= lo {
                    var q = run_end - lo + 1
                    while q > a {
                        q = q - 1
                        acc = List.append(acc, q)
                    }
                } else {}
                run_end = Rrun.no_run
            } else {}
            var mm = m
            while mm != 0 {
                hi_i = 15 - (mm.count_leading_zero_bits()).to_u64()
                # the run's low lane: the highest CLEAR bit below `hi_i`, plus one
                inv = mm.bitwise_not().bitwise_and(1.U16.shl_wrap(hi_i.to_u8_wrap()) - 1)
                lo_i = if inv == 0 { 0 } else { 15 - (inv.count_leading_zero_bits()).to_u64() + 1 }
                if run_end == Rrun.no_run {
                    run_end = w + hi_i + 1
                } else {}
                if lo_i > 0 {
                    a = w + lo_i
                    if run_end - a >= lo {
                        var q = run_end - lo + 1
                        while q > a {
                            q = q - 1
                            acc = List.append(acc, q)
                        }
                    } else {}
                    run_end = Rrun.no_run
                } else {}
                mm = mm.bitwise_and(1.U16.shl_wrap(lo_i.to_u8_wrap()) - 1)
            }
            pos = w
        }
        # the last partial window, and the run that reaches offset 0
        while pos > 0 or run_end != Rrun.no_run {
            member = pos > 0 and Bset.member_ascii(tab, 0, List.get(hay, pos - 1) ?? 0)
            if member {
                if run_end == Rrun.no_run { run_end = pos } else {}
                pos = pos - 1
            } else {
                if run_end != Rrun.no_run {
                    a = pos
                    if run_end - a >= lo {
                        var q = run_end - lo + 1
                        while q > a {
                            q = q - 1
                            acc = List.append(acc, q)
                        }
                    } else {}
                    run_end = Rrun.no_run
                } else {
                    pos = pos - 1
                }
            }
        }
        acc
    }
}
