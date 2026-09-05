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
    ## Most literals one fingerprint can carry: each nibble bucket is a bitmask
    ## with one bit per literal, so 8 is the structural limit. `Comp` reads this
    ## when it decides whether an alternation can use the Teddy path — the two
    ## must agree, or a pattern passes `Comp`'s check and then silently falls off
    ## the SIMD path in `build`.
    max_lits : U64
    max_lits = 8

    ## Built prefilter: the M nibble-table pairs (unused ones are splat 0), the
    ## fingerprint length m, and the literals (for the caller's verification and
    ## a scalar tail scan).
    T : {
        m : U64,
        lo0 : U8x16, hi0 : U8x16,
        lo1 : U8x16, hi1 : U8x16,
        lo2 : U8x16, hi2 : U8x16,
        lits : List(List(U8)),
    }

    ## Build from ≤8 non-empty literals, or `Err` (too many, or an empty literal —
    ## either makes Teddy inapplicable and the caller keeps its scalar rung).
    build : List(List(U8)) -> Try(Teddy.T, [Unsuitable])
    build = |lits|
        if List.len(lits) == 0 or List.len(lits) > Teddy.max_lits or List.any(lits, List.is_empty) {
            Err(Unsuitable)
        } else {
            m = List.fold(lits, 3, |acc, l| if List.len(l) < acc { List.len(l) } else { acc })
            t0 = Teddy.tables(lits, 0)
            t1 = if m >= 2 { Teddy.tables(lits, 1) } else { { lo: U8x16.splat(0), hi: U8x16.splat(0) } }
            t2 = if m >= 3 { Teddy.tables(lits, 2) } else { { lo: U8x16.splat(0), hi: U8x16.splat(0) } }
            Ok({ m, lo0: t0.lo, hi0: t0.hi, lo1: t1.lo, hi1: t1.hi, lo2: t2.lo, hi2: t2.hi, lits })
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

    ## As the three `*_capped` scans, but covering only `hay[0..limit]` — the
    ## growing prefix an early-exit search walks. A SIMD window may overshoot and
    ## report a candidate at or past `limit`; that is harmless, because every
    ## candidate is verified and they still come out in increasing order, so the
    ## caller's "first verified candidate" is still the leftmost one.
    candidates_upto : Teddy.T, List(U8), U64, U64 -> Try(List(U64), [TooMany])
    candidates_upto = |t, hay, limit, cap|
        if limit < 16 {
            cands = Teddy.scalar_tail(t, hay, 0, limit, [])
            if List.len(cands) > cap { Err(TooMany) } else { Ok(cands) }
        } else {
            match Teddy.scan_capped(t, hay, limit, t.m - 1, U8x16.splat(0xFF), U8x16.splat(0xFF), [], cap) {
                Err(TooMany) => Err(TooMany)
                Ok(main) => {
                    tail = Teddy.scan(t, hay, limit, limit - 16, U8x16.splat(0xFF), U8x16.splat(0xFF), main)
                    Ok(Teddy.dedup_sorted(tail))
                }
            }
        }

    byte_candidates_upto : U8, List(U8), U64, U64 -> Try(List(U64), [TooMany])
    byte_candidates_upto = |b, hay, limit, cap| Teddy.byte_scan(b, hay, limit, 0, [], cap)

    range_candidates_upto : U8, U8, List(U8), U64, U64 -> Try(List(U64), [TooMany])
    range_candidates_upto = |lo, hi, hay, limit, cap| Teddy.range_scan(lo, hi, hay, limit, 0, [], cap)

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

    match_lits : Teddy.T, List(U8), U64 -> Try(List(Teddy.Span), [TooMany])
    match_lits = |t, hay, cap| {
        len = List.len(hay)
        st0 = { last_end: 0, spans: [], seen: 0 }
        if len < 16 {
            match Teddy.tail_m(t, hay, 0, len, cap, st0) {
                Ok(st) => Ok(st.spans)
                Err(e) => Err(e)
            }
        } else {
            match Teddy.scan_m(t, hay, len, t.m - 1, U8x16.splat(0xFF), U8x16.splat(0xFF), cap, st0) {
                Err(e) => Err(e)
                Ok(st1) =>
                    match Teddy.scan_m(t, hay, len, len - 16, U8x16.splat(0xFF), U8x16.splat(0xFF), cap, st1) {
                        Err(e) => Err(e)
                        Ok(st2) => Ok(st2.spans)
                    }
            }
        }
    }

    # verify one candidate against the literals (in order), threading MState
    step_m : Teddy.T, List(U8), Teddy.MState, U64, U64, U64 -> Try(Teddy.MState, [TooMany])
    step_m = |t, hay, st, at, cap, len|
        if st.seen + 1 > cap {
            Err(TooMany)
        } else if at < st.last_end {
            Ok({ ..st, seen: st.seen + 1 })
        } else {
            match Teddy.lit_end(t, hay, at, 0, len) {
                Ok(end) => Ok({ last_end: end, spans: List.append(st.spans, { start: at, end }), seen: st.seen + 1 })
                Err(_) => Ok({ ..st, seen: st.seen + 1 })
            }
        }

    # end (`at + len`) of the first literal that fully matches at `at`, else NoMatch
    lit_end : Teddy.T, List(U8), U64, U64, U64 -> Try(U64, [NoMatch])
    lit_end = |t, hay, at, li, len|
        match List.get(t.lits, li) {
            Err(_) => Err(NoMatch)
            Ok(lit) => {
                # the literal must FIT: `eqm` reads a missing haystack byte as
                # 1, so an overhanging literal whose tail is 0x01 would verify
                # and emit a span past the end of the haystack.
                e = at + List.len(lit)
                if e <= len and Teddy.eqm(hay, at, lit, 0, List.len(lit)) {
                    Ok(e)
                } else {
                    Teddy.lit_end(t, hay, at, li + 1, len)
                }
            }
        }

    # windowed fused scan (mirrors `scan`, verifying literals instead of collecting)
    scan_m : Teddy.T, List(U8), U64, U64, U8x16, U8x16, U64, Teddy.MState -> Try(Teddy.MState, [TooMany])
    scan_m = |t, hay, len, w, prev0, prev1, cap, st|
        if w + 16 > len {
            Ok(st)
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
            if bm == 0 {
                Teddy.scan_m(t, hay, len, w + 16, res0, res1, cap, st)
            } else {
                match Teddy.bits_m(t, hay, bm, w, t.m - 1, 0, cap, st, len) {
                    Err(e) => Err(e)
                    Ok(st2) => Teddy.scan_m(t, hay, len, w + 16, res0, res1, cap, st2)
                }
            }
        }

    # verify each set bit's candidate (mirrors `bits`)
    bits_m : Teddy.T, List(U8), U16, U64, U64, U64, U64, Teddy.MState, U64 -> Try(Teddy.MState, [TooMany])
    bits_m = |t, hay, bm, w, back, j, cap, st, len|
        if j >= 16 {
            Ok(st)
        } else {
            set = bm.bitwise_and(1.U16.shl_wrap(j.to_u8_wrap())) != 0
            if set and w + j >= back {
                match Teddy.step_m(t, hay, st, w + j - back, cap, len) {
                    Err(e) => Err(e)
                    Ok(st2) => Teddy.bits_m(t, hay, bm, w, back, j + 1, cap, st2, len)
                }
            } else {
                Teddy.bits_m(t, hay, bm, w, back, j + 1, cap, st, len)
            }
        }

    # scalar fused tail (mirrors `scalar_tail`) for haystacks shorter than a vector
    tail_m : Teddy.T, List(U8), U64, U64, U64, Teddy.MState -> Try(Teddy.MState, [TooMany])
    tail_m = |t, hay, at, len, cap, st|
        if at >= len {
            Ok(st)
        } else if List.any(t.lits, |l| Teddy.starts(hay, at, l, t.m)) {
            match Teddy.step_m(t, hay, st, at, cap, len) {
                Err(e) => Err(e)
                Ok(st2) => Teddy.tail_m(t, hay, at + 1, len, cap, st2)
            }
        } else {
            Teddy.tail_m(t, hay, at + 1, len, cap, st)
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
