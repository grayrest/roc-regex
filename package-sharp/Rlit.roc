## Right-to-left literal search (S13): the reverse sweep skips from its start
## state to the last occurrence of a required prefix, the way RE# uses
## `LastIndexOf`. `rfind_byte` walks 16-byte windows backwards with one
## `eq_lanes`/`to_bitmask` per window and takes the highest set lane;
## `rfind_lit` looks for the literal's last byte and verifies the rest.
import Bset
import Lit
import Trie
import TSet
import Utf8

Rlit := [].{
    ## A required prefix as minterm sets in REVERSE-reading order (the reverse
    ## sweep consumes `sets[0]` first, i.e. the rightmost symbol), with the index
    ## of the set searched for (`anchor`: the rarest; `anchor_byte` when it is a
    ## single ASCII codepoint, else `anchor_tab`, its `Bset` table) and the state
    ## the sweep lands in after consuming all of them. `land` is False for RE#'s
    ## potential-start sets: the occurrence only says a match may start here, so
    ## the sweep resumes at its end in the initial state and re-reads it.
    Prefix : { sets : List(U64), anchor : U64, single : Bool, anchor_byte : U8, anchor_tab : List(U8), state : U32, land : Bool }

    Occ : { start : U64, end : U64 }

    ## The last occurrence of the prefix ending at or before `end`: the anchor
    ## set is searched (`rfind_byte`, or `Bset.rfind` for a set), then the other
    ## sets verified symbol by symbol to its left and right (RE#'s
    ## `trySkipToWeightedSetCharRev`). One function with `while` loops: a call
    ## per candidate that passed the trie and prefix records cost more than the
    ## search on dense anchors (digits: 1.25 ms against 0.25 for plain skipping).
    ## Only a non-ASCII symbol calls out (`Rlit.class_at`, with the trie).
    rfind_sets : List(U8), Trie.T, Rlit.Prefix, U64 -> Try(Rlit.Occ, [NotFound])
    rfind_sets = |hay, t, pf, end0| {
        sets = pf.sets
        ascii = t.ascii
        anchor_set = List.get(sets, pf.anchor) ?? 0
        single = pf.single
        ab = pf.anchor_byte
        tab = pf.anchor_tab
        m = List.len(sets)
        # forward index of the anchor symbol; symbols after it need >= 1 byte each
        ja = m - 1 - pf.anchor
        after = m - 1 - ja
        n = List.len(hay)
        var end = end0
        var result = Err(NotFound)
        var searching = end >= m
        while searching {
            hit = if single { Rlit.rfind_byte(hay, ab, end - after) } else { Bset.rfind(hay, tab, 0, end - after) }
            match hit {
                Err(_) => {
                    searching = False
                }
                Ok(p0) => {
                    # a set hit on a non-ASCII byte names some byte of the symbol: find
                    # its start and check the symbol really is in the anchor set
                    b0 = List.get(hay, p0) ?? 0
                    p = if b0 < 0x80 { p0 } else { Utf8.sym_start(hay, p0) }
                    anchor_ok = b0 < 0x80 or TSet.contains(anchor_set, Rlit.class_at(t, hay, p))
                    # symbols at forward indices ja+1 .. m-1, starting after the anchor
                    var pos = if b0 < 0x80 { p + 1 } else { p + (Utf8.decode(hay, p)).len }
                    var j = ja + 1
                    var ok = anchor_ok
                    while ok and j < m {
                        if pos >= n {
                            ok = False
                        } else {
                            b = List.get(hay, pos) ?? 0
                            cls = if b < 0x80 { List.get(ascii, b.to_u64()) ?? 0 } else { Rlit.class_at(t, hay, pos) }
                            if TSet.contains(List.get(sets, m - 1 - j) ?? 0, cls) {
                                pos = if b < 0x80 { pos + 1 } else { pos + (Utf8.decode(hay, pos)).len }
                                j = j + 1
                            } else {
                                ok = False
                            }
                        }
                    }
                    occ_end = pos
                    # symbols at forward indices ja-1 .. 0, ending at the anchor
                    var start = p
                    var k = ja
                    # the occurrence must end at or before the SWEEP position; `end` only
                    # bounds the anchor search (a two-byte symbol after the anchor can
                    # reach past `p + after` and was wrongly rejected: `..?[ab]\w` on
                    # "abéb a" lost its match)
                    var ok2 = ok and occ_end <= end0
                    while ok2 and k > 0 {
                        if start == 0 {
                            ok2 = False
                        } else {
                            bl = List.get(hay, start - 1) ?? 0
                            if bl < 0x80 {
                                if TSet.contains(List.get(sets, m - k) ?? 0, List.get(ascii, bl.to_u64()) ?? 0) {
                                    start = start - 1
                                    k = k - 1
                                } else {
                                    ok2 = False
                                }
                            } else {
                                d = Utf8.decode_rev(hay, start)
                                cls = if d.ok { Trie.class_of(t, d.cp) } else { t.invalid }
                                if TSet.contains(List.get(sets, m - k) ?? 0, cls) {
                                    start = d.cs
                                    k = k - 1
                                } else {
                                    ok2 = False
                                }
                            }
                        }
                    }
                    if ok2 {
                        result = Ok({ start, end: occ_end })
                        searching = False
                    } else {
                        end = p + after
                        searching = end >= m
                    }
                }
            }
        }
        result
    }

    # the class of the (non-ASCII) symbol starting at `pos`
    class_at : Trie.T, List(U8), U64 -> U32
    class_at = |t, hay, pos| {
        d = Utf8.decode(hay, pos)
        if d.ok { Trie.class_of(t, d.cp) } else { t.invalid }
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
