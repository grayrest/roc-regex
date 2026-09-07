## Teddy — a SIMD multi-literal prefilter (D6, M4), on Roc's 128-bit intrinsics.
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
        lo0 : U8x16, hi0 : U8x16,
        lo1 : U8x16, hi1 : U8x16,
        lo2 : U8x16, hi2 : U8x16,
        lits : List(List(U8)),
        # the same literals end to end, with each one's offset and length, so
        # verification reads bytes out of a flat buffer. Walking `lits` instead
        # refcounts a nested list per literal per candidate, which measured
        # ~161 ns a candidate and made Teddy lose to the plain scan on a dense
        # alternation.
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
            t0 = Teddy.tables(lits, 0)
            t1 = if m >= 2 { Teddy.tables(lits, 1) } else { { lo: U8x16.splat(0), hi: U8x16.splat(0) } }
            t2 = if m >= 3 { Teddy.tables(lits, 2) } else { { lo: U8x16.splat(0), hi: U8x16.splat(0) } }
            f = List.fold(lits, { flat: [], offs: [], lens: [] }, |acc, l|
                { flat: List.concat(acc.flat, l), offs: List.append(acc.offs, (List.len(acc.flat)).to_u32_wrap()), lens: List.append(acc.lens, (List.len(l)).to_u32_wrap()) })
            Ok({ m, lo0: t0.lo, hi0: t0.hi, lo1: t1.lo, hi1: t1.hi, lo2: t2.lo, hi2: t2.hi, lits, flat: f.flat, offs: f.offs, lens: f.lens })
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

    ## Ascending candidate start offsets (a superset of true literal starts).
    candidates : Teddy.T, List(U8) -> List(U64)
    candidates = |t, hay| {
        len = List.len(hay)
        if len < 16 {
            Teddy.scalar_tail(t, hay, 0, len, [])
        } else {
            main = Teddy.scan(t, hay, len, t.m - 1, U8x16.splat(0xFF), U8x16.splat(0xFF), [])
            # overlap window covering the tail, plus any positions the last full
            # window's fingerprint could not reach
            Teddy.scan(t, hay, len, len - 16, U8x16.splat(0xFF), U8x16.splat(0xFF), main)
            |> Teddy.dedup_sorted
        }
    }

    ## As `candidates`, but bail with `Err(TooMany)` once more than `cap`
    ## candidates have been found — the adaptive-prefilter selectivity gate. Dense
    ## literals abort the scan early (cheaply) so the caller can fall back to the
    ## DFA instead of verifying a candidate at nearly every position.
    candidates_capped : Teddy.T, List(U8), U64 -> Try(List(U64), [TooMany])
    candidates_capped = |t, hay, cap| {
        len = List.len(hay)
        if len < 16 {
            cands = Teddy.scalar_tail(t, hay, 0, len, [])
            if List.len(cands) > cap { Err(TooMany) } else { Ok(cands) }
        } else {
            match Teddy.scan_capped(t, hay, len, t.m - 1, U8x16.splat(0xFF), U8x16.splat(0xFF), [], cap) {
                Err(TooMany) => Err(TooMany)
                Ok(main) => {
                    tail = Teddy.scan(t, hay, len, len - 16, U8x16.splat(0xFF), U8x16.splat(0xFF), main)
                    Ok(Teddy.dedup_sorted(tail))
                }
            }
        }
    }

    ## memchr-style single-byte candidate scan (offsets of byte `b`), capped like
    ## `candidates_capped`. Leaner than a Teddy fingerprint — one `eq_lanes` per
    ## 16-byte window, no nibble tables, no overlap so no dedup — and enough for
    ## the literal-prefix prefilter, whose anchored-DFA verify filters the rest.
    byte_candidates_capped : U8, List(U8), U64 -> Try(List(U64), [TooMany])
    byte_candidates_capped = |b, hay, cap|
        Teddy.byte_scan(b, hay, List.len(hay), 0, [], cap)

    # Unrolled 4×: the common (no-match) 64-byte block is skipped with a single
    # OR-reduced `to_bitmask`, so the hot path is one movemask per 64 bytes rather
    # than per 16. Only when a lane hits do we extract each window's offsets.
    byte_scan : U8, List(U8), U64, U64, List(U64), U64 -> Try(List(U64), [TooMany])
    byte_scan = |b, hay, len, w, acc, cap|
        if List.len(acc) > cap {
            Err(TooMany)
        } else if w + 64 <= len {
            bv = U8x16.splat(b)
            m0 = (U8x16.load(hay, w) ?? bv).eq_lanes(bv)
            m1 = (U8x16.load(hay, w + 16) ?? bv).eq_lanes(bv)
            m2 = (U8x16.load(hay, w + 32) ?? bv).eq_lanes(bv)
            m3 = (U8x16.load(hay, w + 48) ?? bv).eq_lanes(bv)
            any = m0.bitwise_or(m1).bitwise_or(m2).bitwise_or(m3).to_bitmask()
            if any == 0 {
                Teddy.byte_scan(b, hay, len, w + 64, acc, cap)
            } else {
                a0 = Teddy.bits_of(m0, w, acc)
                a1 = Teddy.bits_of(m1, w + 16, a0)
                a2 = Teddy.bits_of(m2, w + 32, a1)
                a3 = Teddy.bits_of(m3, w + 48, a2)
                Teddy.byte_scan(b, hay, len, w + 64, a3, cap)
            }
        } else if w + 16 <= len {
            a = Teddy.bits_of((U8x16.load(hay, w) ?? U8x16.splat(b)).eq_lanes(U8x16.splat(b)), w, acc)
            Teddy.byte_scan(b, hay, len, w + 16, a, cap)
        } else {
            Ok(Teddy.byte_tail(b, hay, w, len, acc))
        }

    # append offsets of set lanes in a per-lane 0x00/0xFF mask at window `w`
    bits_of : U8x16, U64, List(U64) -> List(U64)
    bits_of = |m, w, acc| {
        bm = m.to_bitmask()
        if bm == 0 { acc } else { Teddy.bits(bm, w, 0, 0, acc) }
    }

    # scalar scan of the final < 16 bytes
    byte_tail : U8, List(U8), U64, U64, List(U64) -> List(U64)
    byte_tail = |b, hay, at, len, acc|
        if at >= len {
            acc
        } else {
            Teddy.byte_tail(b, hay, at + 1, len, if (List.get(hay, at) ?? 0) == b { List.append(acc, at) } else { acc })
        }

    ## memchr-style scan for the offsets of every byte in the inclusive range
    ## [lo,hi] — the class-prefilter analogue of `byte_candidates_capped`. Same
    ## 4x-unrolled window loop, but the per-lane test is a range compare
    ## (`gte_lanes` & `lte_lanes`) instead of an equality, so a wide first-byte
    ## class (e.g. `[0-9]`) is scanned at SIMD throughput.
    range_candidates_capped : U8, U8, List(U8), U64 -> Try(List(U64), [TooMany])
    range_candidates_capped = |lo, hi, hay, cap|
        Teddy.range_scan(lo, hi, hay, List.len(hay), 0, [], cap)

    range_scan : U8, U8, List(U8), U64, U64, List(U64), U64 -> Try(List(U64), [TooMany])
    range_scan = |lo, hi, hay, len, w, acc, cap|
        if List.len(acc) > cap {
            Err(TooMany)
        } else if w + 64 <= len {
            lov = U8x16.splat(lo)
            hiv = U8x16.splat(hi)
            in_range = |c| c.gte_lanes(lov).bitwise_and(c.lte_lanes(hiv))
            m0 = in_range(U8x16.load(hay, w) ?? lov)
            m1 = in_range(U8x16.load(hay, w + 16) ?? lov)
            m2 = in_range(U8x16.load(hay, w + 32) ?? lov)
            m3 = in_range(U8x16.load(hay, w + 48) ?? lov)
            any = m0.bitwise_or(m1).bitwise_or(m2).bitwise_or(m3).to_bitmask()
            if any == 0 {
                Teddy.range_scan(lo, hi, hay, len, w + 64, acc, cap)
            } else {
                a0 = Teddy.bits_of(m0, w, acc)
                a1 = Teddy.bits_of(m1, w + 16, a0)
                a2 = Teddy.bits_of(m2, w + 32, a1)
                a3 = Teddy.bits_of(m3, w + 48, a2)
                Teddy.range_scan(lo, hi, hay, len, w + 64, a3, cap)
            }
        } else if w + 16 <= len {
            c = U8x16.load(hay, w) ?? U8x16.splat(lo)
            m = c.gte_lanes(U8x16.splat(lo)).bitwise_and(c.lte_lanes(U8x16.splat(hi)))
            Teddy.range_scan(lo, hi, hay, len, w + 16, Teddy.bits_of(m, w, acc), cap)
        } else {
            Ok(Teddy.range_tail(lo, hi, hay, w, len, acc))
        }

    # scalar scan of the final < 16 bytes
    range_tail : U8, U8, List(U8), U64, U64, List(U64) -> List(U64)
    range_tail = |lo, hi, hay, at, len, acc|
        if at >= len {
            acc
        } else {
            b = List.get(hay, at) ?? 0
            Teddy.range_tail(lo, hi, hay, at + 1, len, if b >= lo and b <= hi { List.append(acc, at) } else { acc })
        }

    scan_capped : Teddy.T, List(U8), U64, U64, U8x16, U8x16, List(U64), U64 -> Try(List(U64), [TooMany])
    scan_capped = |t, hay, len, w, prev0, prev1, acc, cap|
        if List.len(acc) > cap {
            Err(TooMany)
        } else if w + 16 > len {
            Ok(acc)
        } else {
            chunk = U8x16.load(hay, w) ?? U8x16.splat(0)
            lomask = U8x16.splat(0x0F)
            hlo = chunk.bitwise_and(lomask)
            hhi = chunk.shr_zf_wrap(4).bitwise_and(lomask)
            res0 = t.lo0.table_lookup(hlo).bitwise_and(t.hi0.table_lookup(hhi))
            res1 = if t.m >= 2 { t.lo1.table_lookup(hlo).bitwise_and(t.hi1.table_lookup(hhi)) } else { U8x16.splat(0) }
            cand =
                if t.m == 1 {
                    res0
                } else if t.m == 2 {
                    prev0.concat_shift_bytes(res0, 15).bitwise_and(res1)
                } else {
                    res2 = t.lo2.table_lookup(hlo).bitwise_and(t.hi2.table_lookup(hhi))
                    a0 = prev0.concat_shift_bytes(res0, 14)
                    a1 = prev1.concat_shift_bytes(res1, 15)
                    a0.bitwise_and(a1).bitwise_and(res2)
                }
            bm = cand.eq_lanes(U8x16.splat(0)).bitwise_not().to_bitmask()
            acc2 = if bm == 0 { acc } else { Teddy.bits(bm, w, t.m - 1, 0, acc) }
            Teddy.scan_capped(t, hay, len, w + 16, res0, res1, acc2, cap)
        }

    ## Fused scan + literal verify for a pure-literal alternation: mirrors
    ## `candidates_capped`'s main+overlap-tail scan, but verifies each candidate
    ## inline against `t.lits` (the whole literal, first match in order =
    ## leftmost-first) and emits its span. No candidate list, no `dedup_sorted`
    ## (the `last_end` skip absorbs the overlap AND keeps matches non-overlapping),
    ## and monomorphic (no verify closure — that defeats the tight-loop codegen).
    ## `cap` bails to `TooMany` once too many candidates are seen.
    Span : { start : U64, end : U64 }
    MState : { last_end : U64, spans : List(Teddy.Span), seen : U64 }

    ## Fused scan and verify for a pure-literal alternation, as ONE function:
    ## every table, every literal buffer and every accumulator is a local, and
    ## the window, bit and candidate loops are `while`s with inline appends.
    ##
    ## It was written as `scan_m` -> `bits_m` -> `step_m`, which passed the
    ## 6-vector `Teddy.T` and the accumulator record per window, per set bit and
    ## per candidate. That cost about 150 ns a candidate and made a dense
    ## alternation lose to the ordinary two-pass scan.
    match_lits : Teddy.T, List(U8), U64 -> Try(List(Teddy.Span), [TooMany])
    match_lits = |t, hay, cap| {
        len = List.len(hay)
        m = t.m
        lo0 = t.lo0
        hi0 = t.hi0
        lo1 = t.lo1
        hi1 = t.hi1
        lo2 = t.lo2
        hi2 = t.hi2
        flat = t.flat
        offs = t.offs
        lens = t.lens
        nlit = List.len(lens)
        back = m - 1
        lomask = U8x16.splat(0x0F)
        zero = U8x16.splat(0)

        var spans = []
        var last_end = 0
        var seen = 0
        var bail = False

        if len < 16 {
            # scalar tail: try every position
            var at = 0
            while bail == False and at < len {
                var li0 = 0
                var hit = False
                while hit == False and li0 < nlit {
                    off = (List.get(offs, li0) ?? 0).to_u64()
                    var i0 = 0
                    var ok0 = True
                    while ok0 and i0 < m {
                        if (List.get(hay, at + i0) ?? 1) == (List.get(flat, off + i0) ?? 2) { i0 = i0 + 1 } else { ok0 = False }
                    }
                    if ok0 { hit = True } else { li0 = li0 + 1 }
                }
                if hit {
                    seen = seen + 1
                    if seen > cap {
                        bail = True
                    } else if at >= last_end {
                        var li = 0
                        var found = 0
                        while li < nlit and found == 0 {
                            off = (List.get(offs, li) ?? 0).to_u64()
                            ln = (List.get(lens, li) ?? 0).to_u64()
                            var i = 0
                            var ok = True
                            while ok and i < ln {
                                if (List.get(hay, at + i) ?? 1) == (List.get(flat, off + i) ?? 2) { i = i + 1 } else { ok = False }
                            }
                            if ok { found = at + ln } else { li = li + 1 }
                        }
                        if found != 0 {
                            spans = List.append(spans, { start: at, end: found })
                            last_end = found
                        }
                    }
                }
                at = at + 1
            }
        } else {
            # 16-byte windows from `back`, then one more at `len - 16` so the
            # final bytes are covered; `last_end` absorbs the overlap
            var w = back
            var prev0 = U8x16.splat(0xFF)
            var prev1 = U8x16.splat(0xFF)
            var tail_done = False
            var done = False
            while done == False {
                if bail {
                    done = True
                } else if w + 16 > len {
                    if tail_done {
                        done = True
                    } else {
                        w = len - 16
                        prev0 = U8x16.splat(0xFF)
                        prev1 = U8x16.splat(0xFF)
                        tail_done = True
                    }
                } else {
                    chunk = U8x16.load(hay, w) ?? zero
                    hlo = chunk.bitwise_and(lomask)
                    hhi = chunk.shr_zf_wrap(4).bitwise_and(lomask)
                    res0 = lo0.table_lookup(hlo).bitwise_and(hi0.table_lookup(hhi))
                    res1 = if m >= 2 { lo1.table_lookup(hlo).bitwise_and(hi1.table_lookup(hhi)) } else { zero }
                    cand =
                        if m == 1 {
                            res0
                        } else if m == 2 {
                            prev0.concat_shift_bytes(res0, 15).bitwise_and(res1)
                        } else {
                            res2 = lo2.table_lookup(hlo).bitwise_and(hi2.table_lookup(hhi))
                            prev0.concat_shift_bytes(res0, 14).bitwise_and(prev1.concat_shift_bytes(res1, 15)).bitwise_and(res2)
                        }
                    bm = cand.eq_lanes(zero).bitwise_not().to_bitmask()
                    prev0 = res0
                    prev1 = res1
                    if bm != 0 {
                        var j = 0
                        while bail == False and j < 16 {
                            if bm.bitwise_and(1.U16.shl_wrap(j.to_u8_wrap())) != 0 and w + j >= back {
                                at = w + j - back
                                seen = seen + 1
                                if seen > cap {
                                    bail = True
                                } else if at >= last_end {
                                    var li = 0
                                    var found = 0
                                    while li < nlit and found == 0 {
                                        off = (List.get(offs, li) ?? 0).to_u64()
                                        ln = (List.get(lens, li) ?? 0).to_u64()
                                        var i = 0
                                        var ok = True
                                        while ok and i < ln {
                                            if (List.get(hay, at + i) ?? 1) == (List.get(flat, off + i) ?? 2) { i = i + 1 } else { ok = False }
                                        }
                                        if ok { found = at + ln } else { li = li + 1 }
                                    }
                                    if found != 0 {
                                        spans = List.append(spans, { start: at, end: found })
                                        last_end = found
                                    }
                                }
                            }
                            j = j + 1
                        }
                    }
                    w = w + 16
                }
            }
        }
        if bail { Err(TooMany) } else { Ok(spans) }
    }

    # scan 16-byte windows from `w`, carrying prev fingerprint results
    scan : Teddy.T, List(U8), U64, U64, U8x16, U8x16, List(U64) -> List(U64)
    scan = |t, hay, len, w, prev0, prev1, acc|
        if w + 16 > len {
            acc
        } else {
            chunk = U8x16.load(hay, w) ?? U8x16.splat(0)
            lomask = U8x16.splat(0x0F)
            hlo = chunk.bitwise_and(lomask)
            hhi = chunk.shr_zf_wrap(4).bitwise_and(lomask)
            res0 = t.lo0.table_lookup(hlo).bitwise_and(t.hi0.table_lookup(hhi))
            # compute res1 once and reuse it for both `cand` and the next window's
            # carry (`prev1`); recomputing it in the recursive call doubled the
            # per-window pshufb work.
            res1 = if t.m >= 2 { t.lo1.table_lookup(hlo).bitwise_and(t.hi1.table_lookup(hhi)) } else { U8x16.splat(0) }
            cand =
                if t.m == 1 {
                    res0
                } else if t.m == 2 {
                    # res0 shifted left 1 (lane0 <- prev0[15]) AND res1
                    prev0.concat_shift_bytes(res0, 15).bitwise_and(res1)
                } else {
                    res2 = t.lo2.table_lookup(hlo).bitwise_and(t.hi2.table_lookup(hhi))
                    a0 = prev0.concat_shift_bytes(res0, 14)
                    a1 = prev1.concat_shift_bytes(res1, 15)
                    a0.bitwise_and(a1).bitwise_and(res2)
                }
            bm = cand.eq_lanes(U8x16.splat(0)).bitwise_not().to_bitmask()
            # the whole point of the SIMD scan: when no lane is a candidate (the
            # common case on real haystacks) skip the 16-way scalar bit-extraction
            # entirely, so an empty window costs one vector step, not 16 iterations.
            acc2 = if bm == 0 { acc } else { Teddy.bits(bm, w, t.m - 1, 0, acc) }
            Teddy.scan(t, hay, len, w + 16, res0, res1, acc2)
        }

    # for each set bit `j` in `bm`, append candidate start (w + j - back), clamped
    bits : U16, U64, U64, U64, List(U64) -> List(U64)
    bits = |bm, w, back, j, acc|
        if j >= 16 {
            acc
        } else {
            set = bm.bitwise_and(1.U16.shl_wrap(j.to_u8_wrap())) != 0
            acc2 =
                if set and w + j >= back {
                    List.append(acc, w + j - back)
                } else {
                    acc
                }
            Teddy.bits(bm, w, back, j + 1, acc2)
        }

    # scalar first-M-bytes scan for haystacks shorter than a vector
    scalar_tail : Teddy.T, List(U8), U64, U64, List(U64) -> List(U64)
    scalar_tail = |t, hay, at, len, acc|
        if at >= len {
            acc
        } else {
            hit = List.any(t.lits, |l| Teddy.starts(hay, at, l, t.m))
            Teddy.scalar_tail(t, hay, at + 1, len, if hit { List.append(acc, at) } else { acc })
        }

    starts : List(U8), U64, List(U8), U64 -> Bool
    starts = |hay, at, lit, m| Teddy.eqm(hay, at, lit, 0, m)
    eqm : List(U8), U64, List(U8), U64, U64 -> Bool
    eqm = |hay, at, lit, i, m|
        if i >= m {
            True
        } else if (List.get(hay, at + i) ?? 1) == (List.get(lit, i) ?? 2) {
            Teddy.eqm(hay, at, lit, i + 1, m)
        } else {
            False
        }

    dedup_sorted : List(U64) -> List(U64)
    dedup_sorted = |xs| {
        sorted = List.sort_with(xs, |a, b| U64.order_relative_to(a, b))
        List.fold(sorted, [], |acc, x| if (List.last(acc) ?? 0) == x and !List.is_empty(acc) { acc } else { List.append(acc, x) })
    }
}
