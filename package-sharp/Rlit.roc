## Right-to-left literal search (S13): the reverse sweep skips from its start
## state to the last occurrence of a required prefix, the way RE# uses
## `LastIndexOf`. `rfind_byte` walks 16-byte windows backwards with one
## `eq_lanes`/`to_bitmask` per window and takes the highest set lane;
## `rfind_lit` looks for the literal's last byte and verifies the rest.
import Lit
import Trie
import TSet
import Utf8

Rlit := [].{
    ## A required prefix as minterm sets in REVERSE-reading order (the reverse
    ## sweep consumes `sets[0]` first, i.e. the rightmost symbol), with the index
    ## of the set searched for (`anchor`, a single ASCII codepoint `anchor_byte`)
    ## and the state the sweep lands in after consuming all of them.
    Prefix : { sets : List(U64), anchor : U64, anchor_byte : U8, state : U32 }

    ## The start of the last occurrence of the prefix ending at or before `end`:
    ## `rfind_byte` for the anchor, then the other sets verified symbol by symbol
    ## to its left and right (RE#'s `trySkipToWeightedSetCharRev`).
    rfind_sets : List(U8), Trie.T, Rlit.Prefix, U64 -> Try(U64, [NotFound])
    rfind_sets = |hay, t, pf, end| {
        m = List.len(pf.sets)
        # forward index of the anchor symbol; symbols after it need >= 1 byte each
        ja = m - 1 - pf.anchor
        after = m - 1 - ja
        if end < m {
            Err(NotFound)
        } else {
            match Rlit.rfind_byte(hay, pf.anchor_byte, end - after) {
                Err(_) => Err(NotFound)
                Ok(p) =>
                    match Rlit.verify_sets(hay, t, pf.sets, m, ja, p, end) {
                        Ok(start) => Ok(start)
                        Err(_) => Rlit.rfind_sets(hay, t, pf, p + after)
                    }
            }
        }
    }

    # sets[m-1-j] must accept the symbol at forward index j of the occurrence.
    # Plain recursion: this runs once per anchor-byte candidate.
    verify_sets : List(U8), Trie.T, List(U64), U64, U64, U64, U64 -> Try(U64, [NoMatch])
    verify_sets = |hay, t, sets, m, ja, p, end|
        match Rlit.verify_right(hay, t, sets, m, ja + 1, p + 1) {
            Err(e) => Err(e)
            Ok(occ_end) => if occ_end > end { Err(NoMatch) } else { Rlit.verify_left(hay, t, sets, m, ja, p) }
        }

    # symbols at forward indices j, j+1, ... m-1 starting at byte `pos`; the end
    verify_right : List(U8), Trie.T, List(U64), U64, U64, U64 -> Try(U64, [NoMatch])
    verify_right = |hay, t, sets, m, j, pos|
        if j >= m {
            Ok(pos)
        } else if pos >= List.len(hay) {
            Err(NoMatch)
        } else {
            d = Utf8.decode(hay, pos)
            cls = if d.ok { Trie.class_of(t, d.cp) } else { t.invalid }
            if TSet.contains(List.get(sets, m - 1 - j) ?? 0, cls) { Rlit.verify_right(hay, t, sets, m, j + 1, pos + d.len) } else { Err(NoMatch) }
        }

    # symbols at forward indices j-1, ..., 0 ending at byte `pos`; the start
    verify_left : List(U8), Trie.T, List(U64), U64, U64, U64 -> Try(U64, [NoMatch])
    verify_left = |hay, t, sets, m, j, pos|
        if j == 0 {
            Ok(pos)
        } else if pos == 0 {
            Err(NoMatch)
        } else {
            d = Utf8.decode_rev(hay, pos)
            cls = if d.ok { Trie.class_of(t, d.cp) } else { t.invalid }
            if TSet.contains(List.get(sets, m - j) ?? 0, cls) { Rlit.verify_left(hay, t, sets, m, j - 1, d.cs) } else { Err(NoMatch) }
        }

    ## the position of the last `b` strictly before `end`
    rfind_byte : List(U8), U8, U64 -> Try(U64, [NotFound])
    rfind_byte = |hay, b, end|
        if end >= 16 {
            w = end - 16
            bv = U8x16.splat(b)
            m = (U8x16.load(hay, w) ?? bv).eq_lanes(bv).to_bitmask()
            if m == 0 {
                Rlit.rfind_byte(hay, b, w)
            } else {
                Ok(w + 15 - (m.count_leading_zero_bits()).to_u64())
            }
        } else {
            Rlit.rfind_tail(hay, b, end)
        }

    rfind_tail : List(U8), U8, U64 -> Try(U64, [NotFound])
    rfind_tail = |hay, b, end|
        if end == 0 {
            Err(NotFound)
        } else if (List.get(hay, end - 1) ?? 0) == b {
            Ok(end - 1)
        } else {
            Rlit.rfind_tail(hay, b, end - 1)
        }

    ## the start of the last occurrence of `lit` that ends at or before `end`
    rfind_lit : List(U8), List(U8), U64 -> Try(U64, [NotFound])
    rfind_lit = |hay, lit, end| Rlit.rfind_lit_at(hay, lit, Rlit.rarest_index(lit), end)

    ## as `rfind_lit`, searching for the literal's byte at index `k` (its rarest)
    ## and verifying the rest around each hit
    rfind_lit_at : List(U8), List(U8), U64, U64 -> Try(U64, [NotFound])
    rfind_lit_at = |hay, lit, k, end| {
        n = List.len(lit)
        if n == 0 or end < n {
            Err(NotFound)
        } else {
            b = List.get(lit, k) ?? 0
            # the byte at index k of an occurrence ending at or before `end` lies before end - (n - 1 - k)
            match Rlit.rfind_byte(hay, b, end - (n - 1 - k)) {
                Err(_) => Err(NotFound)
                Ok(p) =>
                    if p >= k and Lit.matches(hay, p - k, lit, n) {
                        Ok(p - k)
                    } else {
                        Rlit.rfind_lit_at(hay, lit, k, p + (n - 1 - k))
                    }
            }
        }
    }

    ## the index of the literal's rarest byte in English-ish text (memmem's trick:
    ## search for the byte least likely to produce false candidates)
    rarest_index : List(U8) -> U64
    rarest_index = |lit| {
        best = List.fold_with_index(lit, { i: 0, rank: 255 }, |acc, b, i| {
            r = Rlit.rank(b)
            if r < acc.rank { { i, rank: r } } else { acc }
        })
        best.i
    }

    # frequency rank of a byte: lower is rarer. Letters by English frequency,
    # space and common punctuation common, digits and capitals in between, and
    # everything else (rare punctuation, non-ASCII bytes) rarest.
    rank : U8 -> U8
    rank = |b| {
        common = Str.to_utf8("etaoinshrdlcumwfgypbvkjxqz")
        if b == ' ' { 26 }
        else if b == 'e' { 27 } else if b == 't' { 25 } else if b == 'a' { 24 } else if b == 'o' { 23 }
        else if b == 'i' { 22 } else if b == 'n' { 21 } else if b == 's' { 20 } else if b == 'h' { 19 }
        else if b == 'r' { 18 } else if b == 'd' { 17 } else if b == 'l' { 16 } else if b == 'c' { 15 }
        else if b == 'u' { 14 } else if b == 'm' { 13 } else if b == 'w' { 12 } else if b == 'f' { 11 }
        else if b == 'g' { 10 } else if b == 'y' { 9 } else if b == 'p' { 8 } else if b == 'b' { 7 }
        else if b == ',' or b == '.' or b == '\n' { 14 }
        else if b >= '0' and b <= '9' { 6 }
        else if b >= 'A' and b <= 'Z' { 5 }
        else if List.contains(common, b) { 4 }
        else { 1 }
    }
}
