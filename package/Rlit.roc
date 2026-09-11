## Right-to-left literal search: the reverse sweep skips from its start
## state to the last occurrence of a required prefix, the way RE# uses
## `LastIndexOf`. `rfind_byte` walks 16-byte windows backwards with one
## `eq_lanes`/`to_bitmask` per window and takes the highest set lane, and
## `rfind_sets` verifies the remaining sets around each hit.
import Bset
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
    ## `pair`: the anchor sits in a run of single-codepoint sets, so a second
    ## byte of that run is folded into the search (`pair_byte` at `pair_dist`
    ## before the anchor when `pair_back`, after it otherwise). It only filters
    ## candidates; verification below still checks every set.
    Prefix : { sets : List(U64), anchor : U64, single : Bool, anchor_byte : U8, anchor_tab : List(U8), state : U32, land : Bool, pair : Bool, pair_byte : U8, pair_back : Bool, pair_dist : U64, triple : Bool, triple_byte : U8, triple_back : Bool, triple_dist : U64 }

    Occ : { start : U64, end : U64 }

    ## The last occurrence of the prefix ending at or before `end`: the anchor
    ## set is searched (`rfind_byte`, or `Bset.rfind` for a set), then the other
    ## sets verified symbol by symbol to its left and right (RE#'s
    ## `trySkipToWeightedSetCharRev`). One function with `while` loops, because a
    ## call per candidate — passing the trie and the prefix record through it —
    ## costs more than the search itself on a dense anchor such as the digits.
    ## Only a non-ASCII symbol calls out (`Rlit.class_at`, with the trie).
    rfind_sets : List(U8), Trie.T, Rlit.Prefix, U64 -> Try(Rlit.Occ, [NotFound])
    rfind_sets = |hay, t, prefix, end_bound| {
        sets = prefix.sets
        ascii = t.ascii
        anchor_set = List.get(sets, prefix.anchor) ?? 0
        single = prefix.single
        anchor_byte = prefix.anchor_byte
        tab = prefix.anchor_tab
        m = List.len(sets)
        # forward index of the anchor symbol; symbols after it need >= 1 byte each
        anchor_fwd = m - 1 - prefix.anchor
        after = m - 1 - anchor_fwd
        n = List.len(hay)
        pair = prefix.pair
        partner_byte = prefix.pair_byte
        partner_back = prefix.pair_back
        partner_dist = prefix.pair_dist
        triple = prefix.triple
        triple_byte = prefix.triple_byte
        triple_back = prefix.triple_back
        triple_dist = prefix.triple_dist
        var $end = end_bound
        var $result = Err(NotFound)
        var $searching = $end >= m
        while $searching {
            hit =
                if pair {
                    # nested inside the `pair` arm rather than beside it: a
                    # third top-level test would cost a branch on every window,
                    # and a triple takes the `pair` branch either way
                    if triple {
                        Rlit.rfind_triple(hay, anchor_byte, partner_byte, partner_back, partner_dist, triple_byte, triple_back, triple_dist, n, $end - after)
                    } else {
                        Rlit.rfind_pair(hay, anchor_byte, partner_byte, partner_back, partner_dist, n, $end - after)
                    }
                } else if single {
                    Rlit.rfind_byte(hay, anchor_byte, $end - after)
                } else {
                    Bset.rfind(hay, tab, 0, $end - after)
                }
            match hit {
                Err(_) => {
                    $searching = False
                }
                Ok(raw_hit) => {
                    # a set hit on a non-ASCII byte names some byte of the symbol: find
                    # its start and check the symbol really is in the anchor set
                    hit_byte = List.get(hay, raw_hit) ?? 0
                    p = if hit_byte < 0x80 { raw_hit } else { Utf8.sym_start(hay, raw_hit) }
                    anchor_ok = hit_byte < 0x80 or TSet.contains(anchor_set, Rlit.class_at(t, hay, p))
                    # symbols at forward indices anchor_fwd+1 .. m-1, starting after the anchor
                    var $pos = if hit_byte < 0x80 { p + 1 } else { p + (Utf8.decode(hay, p)).len }
                    var $j = anchor_fwd + 1
                    var $ok = anchor_ok
                    while $ok and $j < m {
                        if $pos >= n {
                            $ok = False
                        } else {
                            b = List.get(hay, $pos) ?? 0
                            cls = if b < 0x80 { (List.get(ascii, b.to_u64()) ?? 0).to_u32() } else { Rlit.class_at(t, hay, $pos) }
                            if TSet.contains(List.get(sets, m - 1 - $j) ?? 0, cls) {
                                $pos = if b < 0x80 { $pos + 1 } else { $pos + (Utf8.decode(hay, $pos)).len }
                                $j = $j + 1
                            } else {
                                $ok = False
                            }
                        }
                    }
                    occ_end = $pos
                    # symbols at forward indices anchor_fwd-1 .. 0, ending at the anchor
                    var $start = p
                    var $k = anchor_fwd
                    # the occurrence must end at or before the SWEEP position; `end` only
                    # bounds the anchor search, and a two-byte symbol after the anchor
                    # can reach past `p + after` (`..?[ab]\w` on "abéb a")
                    var $back_ok = $ok and occ_end <= end_bound
                    while $back_ok and $k > 0 {
                        if $start == 0 {
                            $back_ok = False
                        } else {
                            left_byte = List.get(hay, $start - 1) ?? 0
                            if left_byte < 0x80 {
                                if TSet.contains(List.get(sets, m - $k) ?? 0, (List.get(ascii, left_byte.to_u64()) ?? 0).to_u32()) {
                                    $start = $start - 1
                                    $k = $k - 1
                                } else {
                                    $back_ok = False
                                }
                            } else {
                                d = Utf8.decode_rev(hay, $start)
                                cls = if d.ok { Trie.class_of(t, d.cp) } else { t.invalid }
                                if TSet.contains(List.get(sets, m - $k) ?? 0, cls) {
                                    $start = d.cs
                                    $k = $k - 1
                                } else {
                                    $back_ok = False
                                }
                            }
                        }
                    }
                    if $back_ok {
                        $result = Ok({ start: $start, end: occ_end })
                        $searching = False
                    } else {
                        $end = p + after
                        $searching = $end >= m
                    }
                }
            }
        }
        $result
    }

    # the class of the (non-ASCII) symbol starting at `pos`
    class_at : Trie.T, List(U8), U64 -> U32
    class_at = |t, hay, pos| {
        d = Utf8.decode(hay, pos)
        if d.ok { Trie.class_of(t, d.cp) } else { t.invalid }
    }

    ## The position of the last `b` strictly before `end` that also has `partner_byte` at
    ## `dist` bytes before it (`back`) or after it. Two window compares ANDed:
    ## a window whose `b` lanes all fail the pair keeps scanning instead of
    ## returning a candidate the caller would only reject. Windows too close to
    ## an edge for the second load fall back to the `b`-only mask, which is
    ## sound because the pair is a filter, never a requirement.
    rfind_pair : List(U8), U8, U8, Bool, U64, U64, U64 -> Try(U64, [NotFound])
    rfind_pair = |hay, b, partner_byte, back, dist, n, end|
        if end >= 16 {
            w = end - 16
            anchor_vec = U8x16.splat(b)
            anchor_mask = (U8x16.load(hay, w) ?? anchor_vec).eq_lanes(anchor_vec).to_bitmask()
            m =
                if anchor_mask == 0 {
                    0
                } else if back {
                    if w >= dist {
                        partner_vec = U8x16.splat(partner_byte)
                        anchor_mask.bitwise_and((U8x16.load(hay, w - dist) ?? partner_vec).eq_lanes(partner_vec).to_bitmask())
                    } else {
                        anchor_mask
                    }
                } else if w + dist + 16 <= n {
                    partner_vec = U8x16.splat(partner_byte)
                    anchor_mask.bitwise_and((U8x16.load(hay, w + dist) ?? partner_vec).eq_lanes(partner_vec).to_bitmask())
                } else {
                    anchor_mask
                }
            if m == 0 {
                Rlit.rfind_pair(hay, b, partner_byte, back, dist, n, w)
            } else {
                Ok(w + 15 - (m.count_leading_zero_bits()).to_u64())
            }
        } else {
            Rlit.rfind_tail(hay, b, end)
        }

    ## `rfind_pair` with a THIRD byte of the run ANDed in as well. Every hit
    ## that leaves the window is a scan restart, which costs many times a
    ## window: for `\bthe\b` over the bench haystack `h` alone leaves 13473
    ## hits, `th` 6043 and `the` 2394, against 1216 matches. Filtering inside
    ## the window is what converts; verifying harder outside it does not.
    rfind_triple : List(U8), U8, U8, Bool, U64, U8, Bool, U64, U64, U64 -> Try(U64, [NotFound])
    rfind_triple = |hay, b, partner_byte, back, dist, triple_byte, triple_back, triple_dist, n, end|
        if end >= 16 {
            w = end - 16
            anchor_vec = U8x16.splat(b)
            anchor_mask = (U8x16.load(hay, w) ?? anchor_vec).eq_lanes(anchor_vec).to_bitmask()
            pair_mask = if anchor_mask == 0 { 0 } else { anchor_mask.bitwise_and(Rlit.partner_mask(hay, w, partner_byte, back, dist, n)) }
            m = if pair_mask == 0 { 0 } else { pair_mask.bitwise_and(Rlit.partner_mask(hay, w, triple_byte, triple_back, triple_dist, n)) }
            if m == 0 {
                Rlit.rfind_triple(hay, b, partner_byte, back, dist, triple_byte, triple_back, triple_dist, n, w)
            } else {
                Ok(w + 15 - (m.count_leading_zero_bits()).to_u64())
            }
        } else {
            Rlit.rfind_tail(hay, b, end)
        }

    ## the lanes of the window at `w` whose partner byte matches at `dist`. A
    ## window too close to an edge for the second load keeps every lane: the
    ## partner is a filter, never a requirement, which is what keeps it sound.
    partner_mask : List(U8), U64, U8, Bool, U64, U64 -> U16
    partner_mask = |hay, w, partner_byte, back, dist, n| {
        partner_vec = U8x16.splat(partner_byte)
        if back {
            if w >= dist { (U8x16.load(hay, w - dist) ?? partner_vec).eq_lanes(partner_vec).to_bitmask() } else { 0xFFFF }
        } else if w + dist + 16 <= n {
            (U8x16.load(hay, w + dist) ?? partner_vec).eq_lanes(partner_vec).to_bitmask()
        } else {
            0xFFFF
        }
    }

    ## the position of the last `b` strictly before `end`
    rfind_byte : List(U8), U8, U64 -> Try(U64, [NotFound])
    rfind_byte = |hay, b, end|
        if end >= 16 {
            w = end - 16
            anchor_vec = U8x16.splat(b)
            m = (U8x16.load(hay, w) ?? anchor_vec).eq_lanes(anchor_vec).to_bitmask()
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

    # frequency rank of a byte: lower is rarer. Letters by English frequency,
    # space and common punctuation common, digits and capitals in between, and
    # everything else (rare punctuation, non-ASCII bytes) rarest.
    #
    # One entry per byte value, 16 to a row; the trailing comment names the
    # row's first byte.
    rank_table : List(U8)
    rank_table = [
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 14, 1, 1, 1, 1, 1,  # 0x00
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  # 0x10
        26, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 14, 1, 14, 1,  # 0x20
        6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 1, 1, 1, 1, 1, 1,  # 0x30
        1, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,  # 0x40
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 1, 1, 1, 1, 1,  # 0x50
        1, 24, 7, 15, 17, 27, 11, 10, 19, 22, 4, 4, 16, 13, 21, 23,  # 0x60
        8, 4, 18, 20, 25, 14, 4, 12, 4, 9, 4, 1, 1, 1, 1, 1,  # 0x70
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  # 0x80
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  # 0x90
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  # 0xA0
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  # 0xB0
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  # 0xC0
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  # 0xD0
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  # 0xE0
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  # 0xF0
    ]

    rank : U8 -> U8
    rank = |b| List.get(Rlit.rank_table, b.to_u64()) ?? 1
}
