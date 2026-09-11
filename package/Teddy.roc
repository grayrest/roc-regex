## Teddy — a SIMD multi-literal prefilter on Roc's 128-bit intrinsics.
##
## Basic ("Slim") 128-bit Teddy: up to 8 literals, one per bucket bit, with an
## M-byte fingerprint (M = min(3, shortest literal)). For each fingerprint
## position it builds two 16-entry nibble→bucket-mask tables; the scan does two
## `table_lookup`s (pshufb) per position, ANDs the shifted results
## (`concat_shift_bytes` = palignr) to require consecutive fingerprint bytes, and
## `to_bitmask` (pmovmskb) extracts candidate lanes. It yields a SUPERSET of the
## positions where some literal could start; the caller verifies each. AVX2 "fat"
## Teddy (256-bit) is out — Roc has only 128-bit vectors.
Teddy := [].{
    ## Built prefilter: the M nibble-table pairs (unused ones are splat 0), the
    ## fingerprint length m, and the literals (for the caller's verification and
    ## a scalar tail scan).
    T : {
        m : U64,
        lo_byte0 : U8x16, hi_byte0 : U8x16,
        lo_byte1 : U8x16, hi_byte1 : U8x16,
        lo_byte2 : U8x16, hi_byte2 : U8x16,
        lits : List(List(U8)),
        # the same literals end to end, with each one's offset and length, so
        # verification reads bytes out of a flat buffer. Walking `lits` instead
        # refcounts a nested list per literal per candidate, which on a dense
        # alternation costs more than the scan it prefilters.
        flat : List(U8),
        offs : List(U32),
        lens : List(U32),
    }

    ## Build from ≤8 non-empty literals, or `Err` (too many, or an empty literal —
    ## either makes Teddy inapplicable and the caller keeps its scalar rung).
    build : List(List(U8)) -> Try(Teddy.T, [Unsuitable])
    build = |lits|
        if List.len(lits) == 0 or List.len(lits) > 8 or List.any(lits, List.is_empty) {
            Err(Unsuitable)
        } else {
            m = List.fold(lits, 3, |acc, l| if List.len(l) < acc { List.len(l) } else { acc })
            tabs_byte0 = Teddy.tables(lits, 0)
            tabs_byte1 = if m >= 2 { Teddy.tables(lits, 1) } else { { lo: U8x16.splat(0), hi: U8x16.splat(0) } }
            tabs_byte2 = if m >= 3 { Teddy.tables(lits, 2) } else { { lo: U8x16.splat(0), hi: U8x16.splat(0) } }
            f = List.fold(lits, { flat: [], offs: [], lens: [] }, |acc, l|
                { flat: List.concat(acc.flat, l), offs: List.append(acc.offs, (List.len(acc.flat)).to_u32_wrap()), lens: List.append(acc.lens, (List.len(l)).to_u32_wrap()) })
            Ok({ m, lo_byte0: tabs_byte0.lo, hi_byte0: tabs_byte0.hi, lo_byte1: tabs_byte1.lo, hi_byte1: tabs_byte1.hi, lo_byte2: tabs_byte2.lo, hi_byte2: tabs_byte2.hi, lits, flat: f.flat, offs: f.offs, lens: f.lens })
        }

    # nibble→bucket-mask tables for fingerprint position `p`: bit (1<<i) is set in
    # lo[byte&0xF] and hi[byte>>4] for literal i's p-th byte.
    tables : List(List(U8)), U64 -> { lo : U8x16, hi : U8x16 }
    tables = |lits, p| {
        pair = List.map_with_index(lits, |l, i| { b: List.get(l, p) ?? 0, bit: 1.U8.shl_wrap(i.to_u8_wrap()) })
        lo = List.fold(pair, List.repeat(0.U8, 16), |acc, e| Teddy.setbit(acc, (e.b.bitwise_and(0x0F)).to_u64(), e.bit))
        hi = List.fold(pair, List.repeat(0.U8, 16), |acc, e| Teddy.setbit(acc, (e.b.shr_zf_wrap(4)).to_u64(), e.bit))
        { lo: U8x16.from_list(lo) ?? U8x16.splat(0), hi: U8x16.from_list(hi) ?? U8x16.splat(0) }
    }

    setbit : List(U8), U64, U8 -> List(U8)
    setbit = |t, idx, bit| List.set(t, idx, (List.get(t, idx) ?? 0).bitwise_or(bit)) ?? t

    ## Spans of a pure-literal alternation, as the fused scan emits them: a main
    ## pass plus an overlapping tail window, each candidate verified inline
    ## against `t.lits` (the whole literal, first match in order =
    ## leftmost-first). No candidate list and no dedup pass — the `last_end` skip
    ## absorbs the overlap AND keeps matches non-overlapping. `cap` bails to
    ## `TooMany` once too many candidates are seen.
    Span : { start : U64, end : U64 }

    ## Fused scan and verify for a pure-literal alternation, as ONE monomorphic
    ## function: every table, every literal buffer and every accumulator is a
    ## local, and the window, bit and candidate loops are `while`s with inline
    ## appends. Split into per-window, per-bit and per-candidate functions it
    ## would pass the 6-vector `Teddy.T` and the accumulator record at every
    ## step, and a verify closure would defeat the tight-loop codegen.
    match_lits : Teddy.T, List(U8), U64 -> Try(List(Teddy.Span), [TooMany])
    match_lits = |t, hay, cap| {
        len = List.len(hay)
        m = t.m
        lo_byte0 = t.lo_byte0
        hi_byte0 = t.hi_byte0
        lo_byte1 = t.lo_byte1
        hi_byte1 = t.hi_byte1
        lo_byte2 = t.lo_byte2
        hi_byte2 = t.hi_byte2
        flat = t.flat
        offs = t.offs
        lens = t.lens
        nlit = List.len(lens)
        back = m - 1
        lomask = U8x16.splat(0x0F)
        zero = U8x16.splat(0)

        var $spans = []
        var $last_end = 0
        var $seen = 0
        var $bail = False

        if len < 16 {
            # scalar tail: try every position
            var $at = 0
            while $bail == False and $at < len {
                var $fp_lit_i = 0
                var $hit = False
                while $hit == False and $fp_lit_i < nlit {
                    off = (List.get(offs, $fp_lit_i) ?? 0).to_u64()
                    var $fp_i = 0
                    var $fp_ok = True
                    while $fp_ok and $fp_i < m {
                        if (List.get(hay, $at + $fp_i) ?? 1) == (List.get(flat, off + $fp_i) ?? 2) { $fp_i = $fp_i + 1 } else { $fp_ok = False }
                    }
                    if $fp_ok { $hit = True } else { $fp_lit_i = $fp_lit_i + 1 }
                }
                if $hit {
                    $seen = $seen + 1
                    if $seen > cap {
                        $bail = True
                    } else if $at >= $last_end {
                        var $lit_i = 0
                        var $found = 0
                        while $lit_i < nlit and $found == 0 {
                            off = (List.get(offs, $lit_i) ?? 0).to_u64()
                            lit_len = (List.get(lens, $lit_i) ?? 0).to_u64()
                            var $i = 0
                            var $ok = True
                            while $ok and $i < lit_len {
                                if (List.get(hay, $at + $i) ?? 1) == (List.get(flat, off + $i) ?? 2) { $i = $i + 1 } else { $ok = False }
                            }
                            if $ok { $found = $at + lit_len } else { $lit_i = $lit_i + 1 }
                        }
                        if $found != 0 {
                            $spans = List.append($spans, { start: $at, end: $found })
                            $last_end = $found
                        }
                    }
                }
                $at = $at + 1
            }
        } else {
            # 16-byte windows from `back`, then one more at `len - 16` so the
            # final bytes are covered; `last_end` absorbs the overlap
            var $w = back
            var $prev_byte0 = U8x16.splat(0xFF)
            var $prev_byte1 = U8x16.splat(0xFF)
            var $tail_done = False
            var $done = False
            while $done == False {
                if $bail {
                    $done = True
                } else if $w + 16 > len {
                    if $tail_done {
                        $done = True
                    } else {
                        $w = len - 16
                        $prev_byte0 = U8x16.splat(0xFF)
                        $prev_byte1 = U8x16.splat(0xFF)
                        $tail_done = True
                    }
                } else {
                    chunk = U8x16.load(hay, $w) ?? zero
                    chunk_lo = chunk.bitwise_and(lomask)
                    chunk_hi = chunk.shr_zf_wrap(4).bitwise_and(lomask)
                    res_byte0 = lo_byte0.table_lookup(chunk_lo).bitwise_and(hi_byte0.table_lookup(chunk_hi))
                    res_byte1 = if m >= 2 { lo_byte1.table_lookup(chunk_lo).bitwise_and(hi_byte1.table_lookup(chunk_hi)) } else { zero }
                    cand =
                        if m == 1 {
                            res_byte0
                        } else if m == 2 {
                            $prev_byte0.concat_shift_bytes(res_byte0, 15).bitwise_and(res_byte1)
                        } else {
                            res_byte2 = lo_byte2.table_lookup(chunk_lo).bitwise_and(hi_byte2.table_lookup(chunk_hi))
                            $prev_byte0.concat_shift_bytes(res_byte0, 14).bitwise_and($prev_byte1.concat_shift_bytes(res_byte1, 15)).bitwise_and(res_byte2)
                        }
                    cand_mask = cand.eq_lanes(zero).bitwise_not().to_bitmask()
                    $prev_byte0 = res_byte0
                    $prev_byte1 = res_byte1
                    if cand_mask != 0 {
                        var $j = 0
                        while $bail == False and $j < 16 {
                            if cand_mask.bitwise_and(1.U16.shl_wrap($j.to_u8_wrap())) != 0 and $w + $j >= back {
                                at = $w + $j - back
                                $seen = $seen + 1
                                if $seen > cap {
                                    $bail = True
                                } else if at >= $last_end {
                                    var $lit_i = 0
                                    var $found = 0
                                    while $lit_i < nlit and $found == 0 {
                                        off = (List.get(offs, $lit_i) ?? 0).to_u64()
                                        lit_len = (List.get(lens, $lit_i) ?? 0).to_u64()
                                        var $i = 0
                                        var $ok = True
                                        while $ok and $i < lit_len {
                                            if (List.get(hay, at + $i) ?? 1) == (List.get(flat, off + $i) ?? 2) { $i = $i + 1 } else { $ok = False }
                                        }
                                        if $ok { $found = at + lit_len } else { $lit_i = $lit_i + 1 }
                                    }
                                    if $found != 0 {
                                        $spans = List.append($spans, { start: at, end: $found })
                                        $last_end = $found
                                    }
                                }
                            }
                            $j = $j + 1
                        }
                    }
                    $w = $w + 16
                }
            }
        }
        if $bail { Err(TooMany) } else { Ok($spans) }
    }
}
