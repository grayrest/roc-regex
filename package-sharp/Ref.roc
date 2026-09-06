## The brute-force reference (S2.2): a structural interpreter over the rewritten
## node DAG, no automaton. `ends(node, s)` is the set of symbol positions `e`
## such that the symbols `s..e` are in the node's language, with `\A`, `\z` and
## lookarounds resolved against the whole haystack. Leftmost-longest matching
## is then defined directly: the smallest `s` with a non-empty `ends`, its
## largest `e`, then continue from `e` (or `s + 1` after an empty match).
##
## Positions are symbol indices (codepoints, or one `Invalid` symbol per
## malformed run); spans are reported as byte offsets. Sets of positions are
## `List(U8)` flags of length `n + 1`. Results are memoized per (node, start).
import Arena
import Trie
import TSet
import Utf8

Ref := [].{
    ## the haystack as symbol classes and symbol start offsets (`pos[n]` = len)
    # `cls` is a minterm id, which `Trie.build` keeps under 64, and `pos` a byte
    # offset, so the prepared haystack costs 5 bytes a symbol rather than 12.
    Hay : { cls : List(U8), pos : List(U32), n : U64 }

    prepare : Trie.T, List(U8) -> Ref.Hay
    prepare = |t, hay| Ref.prep_loop(t, hay, 0, { cls: [], pos: [], n: 0 })

    prep_loop : Trie.T, List(U8), U64, Ref.Hay -> Ref.Hay
    prep_loop = |t, hay, i, acc|
        if i >= List.len(hay) {
            { ..acc, pos: List.append(acc.pos, i.to_u32_wrap()) }
        } else {
            d = Utf8.decode(hay, i)
            c = if d.ok { Trie.class_of(t, d.cp) } else { t.invalid }
            Ref.prep_loop(t, hay, i + d.len, { cls: List.append(acc.cls, c.to_u8_wrap()), pos: List.append(acc.pos, i.to_u32_wrap()), n: acc.n + 1 })
        }

    ## memo of `ends` results keyed by (node, start)
    Memo : Dict((U32, U64), List(U8))

    St : { m : Ref.Memo, set : List(U8) }

    empty_set : U64 -> List(U8)
    empty_set = |n| List.repeat(0.U8, n + 1)

    single : U64, U64 -> List(U8)
    single = |n, p| List.set(Ref.empty_set(n), p, 1) ?? Ref.empty_set(n)

    union : List(U8), List(U8) -> List(U8)
    union = |x, y| List.map2(x, y, |p, q| if p == 1 or q == 1 { 1 } else { 0 })

    inter : List(U8), List(U8) -> List(U8)
    inter = |x, y| List.map2(x, y, |p, q| if p == 1 and q == 1 { 1 } else { 0 })

    members : List(U8) -> List(U64)
    members = |s| List.fold_with_index(s, [], |acc, f, i| if f == 1 { List.append(acc, i) } else { acc })

    is_empty : List(U8) -> Bool
    is_empty = |s| !List.any(s, |f| f == 1)

    ## the match ends from symbol position `s`
    ends : Arena.A, Ref.Hay, Ref.Memo, U32, U64 -> Ref.St
    ends = |a, h, m, id, s|
        match Dict.get(m, (id, s)) {
            Ok(set) => { m, set }
            Err(_) => {
                r = Ref.compute(a, h, m, id, s)
                { m: Dict.insert(r.m, (id, s), r.set), set: r.set }
            }
        }

    compute : Arena.A, Ref.Hay, Ref.Memo, U32, U64 -> Ref.St
    compute = |a, h, m, id, s| {
        n = h.n
        k = Arena.kind(a, id)
        if k == Arena.k_singleton {
            if s < n and TSet.contains(Arena.tset(a, id), (List.get(h.cls, s) ?? 0).to_u32()) {
                { m, set: Ref.single(n, s + 1) }
            } else {
                { m, set: Ref.empty_set(n) }
            }
        } else if k == Arena.k_concat {
            hd = Ref.ends(a, h, m, Arena.head(a, id), s)
            List.fold(Ref.members(hd.set), { m: hd.m, set: Ref.empty_set(n) }, |acc, mid| {
                t = Ref.ends(a, h, acc.m, Arena.tail(a, id), mid)
                { m: t.m, set: Ref.union(acc.set, t.set) }
            })
        } else if k == Arena.k_or {
            List.fold(Arena.children(a, id), { m, set: Ref.empty_set(n) }, |acc, c| {
                r = Ref.ends(a, h, acc.m, c, s)
                { m: r.m, set: Ref.union(acc.set, r.set) }
            })
        } else if k == Arena.k_and {
            List.fold(Arena.children(a, id), { m, set: List.repeat(1.U8, n + 1) }, |acc, c| {
                r = Ref.ends(a, h, acc.m, c, s)
                { m: r.m, set: Ref.inter(acc.set, r.set) }
            })
        } else if k == Arena.k_not {
            r = Ref.ends(a, h, m, Arena.head(a, id), s)
            { m: r.m, set: List.map_with_index(r.set, |f, i| if i >= s and f == 0 { 1 } else { 0 }) }
        } else if k == Arena.k_loop {
            Ref.loop_ends(a, h, m, Arena.head(a, id), Arena.loop_lo(a, id), Arena.loop_hi(a, id), s)
        } else if k == Arena.k_lookahead {
            r = Ref.ends(a, h, m, Arena.head(a, id), s)
            { m: r.m, set: if Ref.is_empty(r.set) { Ref.empty_set(n) } else { Ref.single(n, s) } }
        } else if k == Arena.k_lookbehind {
            # some suffix ending at `s` is in the body's language
            body = Arena.head(a, id)
            r = List.fold_until(Arena.upto(s + 1), { m, found: False }, |acc, q| {
                e = Ref.ends(a, h, acc.m, body, q)
                if (List.get(e.set, s) ?? 0) == 1 { Break({ m: e.m, found: True }) } else { Continue({ m: e.m, found: False }) }
            })
            { m: r.m, set: if r.found { Ref.single(n, s) } else { Ref.empty_set(n) } }
        } else if k == Arena.k_begin {
            { m, set: if s == 0 { Ref.single(n, s) } else { Ref.empty_set(n) } }
        } else {
            { m, set: if s == n { Ref.single(n, s) } else { Ref.empty_set(n) } }
        }
    }

    # body{lo,hi}: iterate the body's ends from the current frontier until it stops
    # growing (a nullable body stabilizes; a non-nullable one moves right)
    loop_ends : Arena.A, Ref.Hay, Ref.Memo, U32, U32, U32, U64 -> Ref.St
    loop_ends = |a, h, m, body, lo, hi, s| {
        n = h.n
        start = Ref.single(n, s)
        res0 = if lo == 0 { start } else { Ref.empty_set(n) }
        Ref.loop_iter(a, h, m, body, lo, hi, 1, start, res0)
    }

    loop_iter : Arena.A, Ref.Hay, Ref.Memo, U32, U32, U32, U32, List(U8), List(U8) -> Ref.St
    loop_iter = |a, h, m, body, lo, hi, i, cur, res|
        if Ref.is_empty(cur) or (hi != Arena.inf and i > hi) or i > (h.n + 2).to_u32_wrap() {
            { m, set: res }
        } else {
            nxt = List.fold(Ref.members(cur), { m, set: Ref.empty_set(h.n) }, |acc, mid| {
                r = Ref.ends(a, h, acc.m, body, mid)
                { m: r.m, set: Ref.union(acc.set, r.set) }
            })
            res2 = if i >= lo { Ref.union(res, nxt.set) } else { res }
            if nxt.set == cur and i >= lo {
                { m: nxt.m, set: res2 }
            } else {
                Ref.loop_iter(a, h, nxt.m, body, lo, hi, i + 1, nxt.set, res2)
            }
        }

    ## RE#'s leftmost-longest non-overlapping matches, as byte spans
    find_all : Arena.A, Trie.T, U32, List(U8) -> List({ start : U64, end : U64 })
    find_all = |a, t, root, hay| {
        h = Ref.prepare(t, hay)
        Ref.scan(a, h, Dict.empty(), root, 0, [])
    }

    scan : Arena.A, Ref.Hay, Ref.Memo, U32, U64, List({ start : U64, end : U64 }) -> List({ start : U64, end : U64 })
    scan = |a, h, m, root, s, acc|
        if s > h.n {
            acc
        } else {
            r = Ref.ends(a, h, m, root, s)
            case_end = List.fold_with_index(r.set, Err(NoMatch), |best, f, i| if f == 1 { Ok(i) } else { best })
            match case_end {
                Err(_) => Ref.scan(a, h, r.m, root, s + 1, acc)
                Ok(e) => {
                    span = { start: (List.get(h.pos, s) ?? 0).to_u64(), end: (List.get(h.pos, e) ?? 0).to_u64() }
                    next = if e > s { e } else { s + 1 }
                    Ref.scan(a, h, r.m, root, next, List.append(acc, span))
                }
            }
        }

    ## the ends of matches anchored at position 0 (RE#'s FirstEnd/LongestEnd)
    ends_at_start : Arena.A, Trie.T, U32, List(U8) -> List(U64)
    ends_at_start = |a, t, root, hay| {
        h = Ref.prepare(t, hay)
        r = Ref.ends(a, h, Dict.empty(), root, 0)
        List.map(Ref.members(r.set), |e| (List.get(h.pos, e) ?? 0).to_u64())
    }
}
