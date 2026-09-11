## SIMD byte-set search (the kernel behind RE#'s `MintermSearchValues`
## skips): for a set of ASCII bytes, `find`/`rfind` locate the nearest member
## with one pair of nibble `table_lookup`s per 16-byte window. A non-ASCII
## byte always counts as a member: a skip must stop at any multibyte symbol
## and let the automaton decode it, so the high bit of a lane is OR-ed into
## the member mask.
##
## Sets are stored packed, 16 bytes each, in one `List(U8)`: set `k` is the
## `lo` nibble table at `k * 16`; `lo[b & 15] & hi[b >> 4] != 0` iff ASCII `b`
## is a member. The high nibble of an ASCII byte is 0..7, one bit each, so
## `hi` is the same constant for every set.
Bset := [].{
    hi_table : List(U8)
    hi_table = [1, 2, 4, 8, 16, 32, 64, 128, 0, 0, 0, 0, 0, 0, 0, 0]

    ## the 16-byte `lo` table of a set of ASCII bytes (non-ASCII ignored)
    table : List(U8) -> List(U8)
    table = |bytes|
        List.fold(bytes, List.repeat(0, 16), |acc, b|
            if b >= 0x80 {
                acc
            } else {
                i = b.bitwise_and(15).to_u64()
                bit = 1.shl_wrap(b.shr_zf_wrap(4))
                List.set(acc, i, (List.get(acc, i) ?? 0).bitwise_or(bit)) ?? acc
            })

    ## is `b` in set `k` of the packed tables?
    member : List(U8), U64, U8 -> Bool
    member = |tables, k, b|
        b >= 0x80
        or (List.get(tables, k * 16 + b.bitwise_and(15).to_u64()) ?? 0).bitwise_and(List.get(Bset.hi_table, b.shr_zf_wrap(4).to_u64()) ?? 0) != 0

    ## the lanes of `chunk` that are members (ASCII via the tables, non-ASCII
    ## via the high bit)
    mask : U8x16, U8x16, U8x16 -> U16
    mask = |lo, hi, chunk| {
        nib = U8x16.splat(0x0F)
        r = lo.table_lookup(chunk.bitwise_and(nib)).bitwise_and(hi.table_lookup(chunk.shr_zf_wrap(4).bitwise_and(nib)))
        r.eq_lanes(U8x16.splat(0)).bitwise_not().to_bitmask().bitwise_or(chunk.to_bitmask())
    }

    load : List(U8), U64 -> U8x16
    load = |tables, k| U8x16.load(tables, k * 16) ?? U8x16.splat(0)

    hi_vec : U8x16
    hi_vec = U8x16.from_list(Bset.hi_table) ?? U8x16.splat(0)

    ## the position of the last member of set `k` strictly before `end`
    rfind : List(U8), List(U8), U64, U64 -> Try(U64, [NotFound])
    rfind = |hay, tables, k, end| Bset.rfind_loop(hay, tables, k, Bset.load(tables, k), Bset.hi_vec, end)

    rfind_loop : List(U8), List(U8), U64, U8x16, U8x16, U64 -> Try(U64, [NotFound])
    rfind_loop = |hay, tables, k, lo, hi, end|
        if end >= 16 {
            w = end - 16
            m = Bset.mask(lo, hi, U8x16.load(hay, w) ?? U8x16.splat(0))
            if m == 0 {
                Bset.rfind_loop(hay, tables, k, lo, hi, w)
            } else {
                Ok(w + 15 - m.count_leading_zero_bits().to_u64())
            }
        } else {
            Bset.rfind_tail(hay, tables, k, end)
        }

    rfind_tail : List(U8), List(U8), U64, U64 -> Try(U64, [NotFound])
    rfind_tail = |hay, tables, k, end|
        if end == 0 {
            Err(NotFound)
        } else if Bset.member(tables, k, List.get(hay, end - 1) ?? 0) {
            Ok(end - 1)
        } else {
            Bset.rfind_tail(hay, tables, k, end - 1)
        }

    ## the position of the first member of set `k` at or after `pos`
    find : List(U8), List(U8), U64, U64 -> Try(U64, [NotFound])
    find = |hay, tables, k, pos| Bset.find_loop(hay, tables, k, Bset.load(tables, k), Bset.hi_vec, List.len(hay), pos)

    find_loop : List(U8), List(U8), U64, U8x16, U8x16, U64, U64 -> Try(U64, [NotFound])
    find_loop = |hay, tables, k, lo, hi, n, w|
        if w + 16 <= n {
            m = Bset.mask(lo, hi, U8x16.load(hay, w) ?? U8x16.splat(0))
            if m == 0 {
                Bset.find_loop(hay, tables, k, lo, hi, n, w + 16)
            } else {
                Ok(w + m.count_trailing_zero_bits().to_u64())
            }
        } else {
            Bset.find_tail(hay, tables, k, n, w)
        }

    find_tail : List(U8), List(U8), U64, U64, U64 -> Try(U64, [NotFound])
    find_tail = |hay, tables, k, n, pos|
        if pos >= n {
            Err(NotFound)
        } else if Bset.member(tables, k, List.get(hay, pos) ?? 0) {
            Ok(pos)
        } else {
            Bset.find_tail(hay, tables, k, n, pos + 1)
        }

    ## `member`/`mask` WITHOUT the "a non-ASCII byte is always a member" rule.
    ## The nibble tables already say "no" for a byte >= 0x80 (its high nibble is
    ## 8..15 and `hi_table` is 0 there), so these are the ordinary kernel minus
    ## the high bit, not an extra test. Sound only for a set with no non-ASCII
    ## member, where a multibyte symbol genuinely is not in it (`Rrun`).
    member_ascii : List(U8), U64, U8 -> Bool
    member_ascii = |tables, k, b|
        (List.get(tables, k * 16 + b.bitwise_and(15).to_u64()) ?? 0).bitwise_and(List.get(Bset.hi_table, b.shr_zf_wrap(4).to_u64()) ?? 0) != 0

    mask_ascii : U8x16, U8x16, U8x16 -> U16
    mask_ascii = |lo, hi, chunk| {
        nib = U8x16.splat(0x0F)
        r = lo.table_lookup(chunk.bitwise_and(nib)).bitwise_and(hi.table_lookup(chunk.shr_zf_wrap(4).bitwise_and(nib)))
        r.eq_lanes(U8x16.splat(0)).bitwise_not().to_bitmask()
    }

    ## How often a byte occurs in English-ish text, per mille (rough: letters by
    ## frequency, space 170, newline and common punctuation 10-15, digits and
    ## capitals about 1 each, everything else 0.5 — stored ×2 so the rare
    ## bytes are 1). RE# weights lowercase and whitespace 20 and the rest 10,
    ## which makes `e` as good an anchor as `h` and a set of six letters
    ## "rarer" than the capitals. A set's weight is the sum: 2000 / weight is
    ## the expected gap in bytes between members.
    ##
    ## One entry per byte value, 16 to a row; the trailing comment names the
    ## row's first byte.
    byte_weight_table : List(U64)
    byte_weight_table = [
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 30, 1, 1, 1, 1, 1,  # 0x00
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  # 0x10
        340, 1, 8, 1, 1, 1, 1, 8, 1, 1, 1, 1, 24, 6, 24, 1,  # 0x20
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1,  # 0x30
        1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,  # 0x40
        3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 1, 1, 1, 1,  # 0x50
        1, 130, 24, 42, 66, 200, 34, 32, 96, 110, 2, 12, 64, 40, 110, 120,  # 0x60
        28, 2, 94, 100, 140, 44, 16, 36, 2, 30, 2, 1, 1, 1, 1, 1,  # 0x70
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  # 0x80
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  # 0x90
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  # 0xA0
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  # 0xB0
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  # 0xC0
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  # 0xD0
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  # 0xE0
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  # 0xF0
    ]

    byte_weight : U8 -> U64
    byte_weight = |b| List.get(Bset.byte_weight_table, b.to_u64()) ?? 1

    ## the expected frequency of a set's ASCII members (per mille ×2)
    weight : List(U8) -> U64
    weight = |bytes| List.fold(bytes, 0, |acc, b| acc + Bset.byte_weight(b))

    ## Not worth skipping to: members expected closer than ~12 bytes apart, where
    ## a 16-byte window and the skip's bookkeeping cost about what the table
    ## steps do (RE#'s `isTooCommon` leans on .NET's `SearchValues` kinds; this
    ## is ours). `[a-z]`, `\w`, `\s` (space alone is 340) are too common;
    ## `[A-Z]` (78), `\d` (20), `h` (96), `[.,;:]` are not; `e` (200) is.
    too_common : List(U8) -> Bool
    too_common = |bytes| Bset.weight(bytes) > 160
}
