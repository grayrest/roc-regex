## SIMD byte-set search (S13, the kernel behind RE#'s `MintermSearchValues`
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

    ## How often a byte occurs in English-ish text, per mille (rough: letters by
    ## frequency, space 170, newline and common punctuation 10-15, digits and
    ## capitals about 1 each, everything else 0.5 — stored ×2 so the rare
    ## bytes are 1). RE# weights lowercase and whitespace 20, the rest 10; that
    ## made `e` as good an anchor as `h` and a set of six letters "rarer" than
    ## the capitals. A set's weight is the sum: 2000 / weight is the expected
    ## gap in bytes between members.
    freq2 : U8 -> U64
    freq2 = |b|
        if b == ' ' { 340 }
        else if b == 'e' { 200 } else if b == 't' { 140 } else if b == 'a' { 130 } else if b == 'o' { 120 }
        else if b == 'i' { 110 } else if b == 'n' { 110 } else if b == 's' { 100 } else if b == 'h' { 96 }
        else if b == 'r' { 94 } else if b == 'd' { 66 } else if b == 'l' { 64 } else if b == 'u' { 44 }
        else if b == 'c' { 42 } else if b == 'm' { 40 } else if b == 'w' { 36 } else if b == 'f' { 34 }
        else if b == 'g' { 32 } else if b == 'y' { 30 } else if b == 'p' { 28 } else if b == 'b' { 24 }
        else if b == 'v' { 16 } else if b == 'k' { 12 }
        else if b == '\n' { 30 } else if b == ',' or b == '.' { 24 } else if b == '\'' or b == '"' { 8 } else if b == '-' { 6 }
        else if b >= 'a' and b <= 'z' { 2 }
        else if b >= 'A' and b <= 'Z' { 3 }
        else if b >= '0' and b <= '9' { 2 }
        else { 1 }

    ## the expected frequency of a set's ASCII members (per mille ×2)
    weight : List(U8) -> U64
    weight = |bytes| List.fold(bytes, 0, |acc, b| acc + Bset.freq2(b))

    ## Not worth skipping to: members expected closer than ~12 bytes apart, where
    ## a 16-byte window and the skip's bookkeeping cost about what the table
    ## steps did (RE#'s `isTooCommon` leans on .NET's `SearchValues` kinds; this
    ## is ours). `[a-z]`, `\w`, `\s` (space alone is 340) are too common;
    ## `[A-Z]` (78), `\d` (20), `h` (96), `[.,;:]` are not; `e` (200) is.
    too_common : List(U8) -> Bool
    too_common = |bytes| Bset.weight(bytes) > 160
}
