## The regex-node arena (S9): RE#'s `RegexBuilder` storage as flat lists.
##
## A node is a run of cells `[kind, ...fields]` in `cells`; its id is the index
## into `offs` (node id → cell offset). Per-node info lives in parallel lists:
## `flags` (RE#'s `NodeFlags`), `sub` (`SubsumedByMinterm`), `minl`/`maxl`
## (min/max match length, `none` = unknown), `pend` (pending-nullable refset).
##
## `index` is one open-addressing hash table serving both roles RE#'s
## `_nodeCache` plays: structural interning (a node's own cells → its id) and the
## rewrite memo (an unnormalized key → the id it rewrites to). Keys are copied
## into `ikeys`; every list is `U32`/`U64`/`U8` so the whole record folds (D12).
##
## Node ids 0–6 are fixed as in RE# so the ported rules read the same.
Arena := [].{
    A : {
        cells : List(U32),
        offs : List(U32),
        flags : List(U8),
        sub : List(U64),
        minl : List(U32),
        maxl : List(U32),
        pend : List(U32),
        # interning index
        islots : List(U32),
        ient_key : List(U32),
        ient_len : List(U32),
        ient_id : List(U32),
        ikeys : List(U32),
        # refsets (pending-nullable positions), packed `s << 16 | e`
        rs_data : List(U32),
        rs_off : List(U32),
        rs_len : List(U32),
        # alphabet
        nmt : U32,
        wordc : U64,
        nonwordc : U64,
        # RE#'s well-known anchor nodes, filled by `Build.init_anchors`
        anc : Arena.Anchors,
        or_count : U32,
        # RE# raises `UnsupportedPatternException`; constructors here record the
        # first message and keep going, and `compile` turns it into an `Err`.
        err : [NoErr, Unsup(Str)],
    }

    Anchors : { caret : U32, dollar : U32, nwl : U32, wl : U32, nwr : U32, wr : U32, a_anchor : U32, end_z : U32 }

    R : { a : Arena.A, id : U32 }

    # --- fixed ids and encodings -------------------------------------------------

    bot : U32
    bot = 0
    eps : U32
    eps = 1
    top : U32
    top = 2
    top_star : U32
    top_star = 3
    top_plus : U32
    top_plus = 4
    end_anchor : U32
    end_anchor = 5
    begin_anchor : U32
    begin_anchor = 6

    inf : U32
    inf = 0xFFFF_FFFF

    none : U32
    none = 0xFFFF_FFFF

    k_concat : U32
    k_concat = 0
    k_singleton : U32
    k_singleton = 1
    k_loop : U32
    k_loop = 2
    k_or : U32
    k_or = 3
    k_and : U32
    k_and = 4
    k_not : U32
    k_not = 5
    k_lookahead : U32
    k_lookahead = 6
    k_lookbehind : U32
    k_lookbehind = 7
    k_begin : U32
    k_begin = 8
    k_end : U32
    k_end = 9

    f_can_null : U8
    f_can_null = 1
    f_always_null : U8
    f_always_null = 2
    f_look : U8
    f_look = 4
    f_anchor : U8
    f_anchor = 8
    f_suffix_la : U8
    f_suffix_la = 16
    f_prefix_lb : U8
    f_prefix_lb = 32

    rs_empty : U32
    rs_empty = 0
    rs_zero : U32
    rs_zero = 1

    # --- construction ----------------------------------------------------------

    Info : { flags : U8, sub : U64, minl : U32, maxl : U32, pend : U32 }

    ## An arena over `nmt` minterms with the seven fixed nodes registered.
    init : U32 -> Arena.A
    init = |nmt| {
        full = if nmt >= 64 { 0xFFFF_FFFF_FFFF_FFFF } else { 1.U64.shl_wrap(nmt.to_u8_wrap()) - 1 }
        a0 = {
            cells: [], offs: [], flags: [], sub: [], minl: [], maxl: [], pend: [],
            islots: List.repeat(0.U32, 64), ient_key: [], ient_len: [], ient_id: [], ikeys: [],
            rs_data: [], rs_off: [], rs_len: [],
            nmt, wordc: 0, nonwordc: 0,
            anc: { caret: Arena.none, dollar: Arena.none, nwl: Arena.none, wl: Arena.none, nwr: Arena.none, wr: Arena.none, a_anchor: Arena.none, end_z: Arena.none },
            or_count: 0, err: NoErr,
        }
        nullable = Arena.f_can_null.bitwise_or(Arena.f_always_null)
        anchor_flags = Arena.f_anchor.bitwise_or(Arena.f_can_null)
        r0 = Arena.register(a0, Arena.key_singleton(0), { flags: 0, sub: 0, minl: 1, maxl: 1, pend: 0 })
        r1 = Arena.register(r0.a, Arena.key_loop(Arena.bot, 0, Arena.inf), { flags: nullable, sub: full, minl: 0, maxl: 0, pend: 0 })
        r2 = Arena.register(r1.a, Arena.key_singleton(full), { flags: 0, sub: full, minl: 1, maxl: 1, pend: 0 })
        r3 = Arena.register(r2.a, Arena.key_loop(Arena.top, 0, Arena.inf), { flags: nullable, sub: full, minl: 0, maxl: Arena.none, pend: 0 })
        r4 = Arena.register(r3.a, Arena.key_loop(Arena.top, 1, Arena.inf), { flags: 0, sub: full, minl: 1, maxl: Arena.none, pend: 0 })
        r5 = Arena.register(r4.a, [Arena.k_end], { flags: anchor_flags, sub: full, minl: 0, maxl: 0, pend: 0 })
        r6 = Arena.register(r5.a, [Arena.k_begin], { flags: anchor_flags, sub: full, minl: 0, maxl: 0, pend: 0 })
        # refset 0 = empty, 1 = {(0,0)}
        a7 = { ..r6.a, rs_off: [0, 0], rs_len: [0, 1], rs_data: [0] }
        a7
    }

    full : Arena.A -> U64
    full = |a| if a.nmt >= 64 { 0xFFFF_FFFF_FFFF_FFFF } else { 1.U64.shl_wrap(a.nmt.to_u8_wrap()) - 1 }

    ## Append a node with `key` as its cells and index it. The caller has
    ## already checked `lookup(key)`.
    register : Arena.A, List(U32), Arena.Info -> Arena.R
    register = |a, key, info| {
        id = (List.len(a.offs)).to_u32_wrap()
        off = (List.len(a.cells)).to_u32_wrap()
        a1 = { ..a,
            cells: List.concat(a.cells, key),
            offs: List.append(a.offs, off),
            flags: List.append(a.flags, info.flags),
            sub: List.append(a.sub, info.sub),
            minl: List.append(a.minl, info.minl),
            maxl: List.append(a.maxl, info.maxl),
            pend: List.append(a.pend, info.pend),
        }
        { a: Arena.memo(a1, key, id), id }
    }

    ## Record the first unsupported-pattern message.
    fail : Arena.A, Str -> Arena.A
    fail = |a, msg|
        match a.err {
            NoErr => { ..a, err: Unsup(msg) }
            Unsup(_) => a
        }

    # --- keys ------------------------------------------------------------------

    key_singleton : U64 -> List(U32)
    key_singleton = |t| [Arena.k_singleton, t.bitwise_and(0xFFFF_FFFF).to_u32_wrap(), t.shr_zf_wrap(32).to_u32_wrap()]

    key_concat : U32, U32 -> List(U32)
    key_concat = |h, t| [Arena.k_concat, h, t]

    key_loop : U32, U32, U32 -> List(U32)
    key_loop = |body, lo, hi| [Arena.k_loop, body, lo, hi]

    key_or : List(U32) -> List(U32)
    key_or = |ids| List.concat([Arena.k_or, (List.len(ids)).to_u32_wrap()], ids)

    key_and : List(U32) -> List(U32)
    key_and = |ids| List.concat([Arena.k_and, (List.len(ids)).to_u32_wrap()], ids)

    key_not : U32 -> List(U32)
    key_not = |x| [Arena.k_not, x]

    key_look : Bool, U32, U32, U32 -> List(U32)
    key_look = |back, body, rel, pend| [if back { Arena.k_lookbehind } else { Arena.k_lookahead }, body, rel, pend]

    # --- accessors -------------------------------------------------------------

    off : Arena.A, U32 -> U64
    off = |a, id| (List.get(a.offs, id.to_u64()) ?? 0).to_u64()

    kind : Arena.A, U32 -> U32
    kind = |a, id| List.get(a.cells, Arena.off(a, id)) ?? 0

    ## field `i` of node `id` (0-based, after the kind cell)
    fld : Arena.A, U32, U64 -> U32
    fld = |a, id, i| List.get(a.cells, Arena.off(a, id) + 1 + i) ?? 0

    ## the children of an Or/And node
    children : Arena.A, U32 -> List(U32)
    children = |a, id| {
        o = Arena.off(a, id)
        n = (List.get(a.cells, o + 1) ?? 0).to_u64()
        List.sublist(a.cells, { start: o + 2, len: n })
    }

    ## the cells of node `id` (its interning key)
    cells_of : Arena.A, U32 -> List(U32)
    cells_of = |a, id| {
        o = Arena.off(a, id)
        k = List.get(a.cells, o) ?? 0
        n =
            if k == Arena.k_singleton { 3 } else if k == Arena.k_concat { 3 } else if k == Arena.k_loop { 4 }
            else if k == Arena.k_or or k == Arena.k_and { 2 + (List.get(a.cells, o + 1) ?? 0).to_u64() }
            else if k == Arena.k_not { 2 } else if k == Arena.k_lookahead or k == Arena.k_lookbehind { 4 } else { 1 }
        List.sublist(a.cells, { start: o, len: n })
    }

    tset : Arena.A, U32 -> U64
    tset = |a, id| (Arena.fld(a, id, 0)).to_u64().bitwise_or((Arena.fld(a, id, 1)).to_u64().shl_wrap(32))

    is_singleton : Arena.A, U32 -> Bool
    is_singleton = |a, id| Arena.kind(a, id) == Arena.k_singleton
    is_concat : Arena.A, U32 -> Bool
    is_concat = |a, id| Arena.kind(a, id) == Arena.k_concat
    is_loop : Arena.A, U32 -> Bool
    is_loop = |a, id| Arena.kind(a, id) == Arena.k_loop
    is_or : Arena.A, U32 -> Bool
    is_or = |a, id| Arena.kind(a, id) == Arena.k_or
    is_and : Arena.A, U32 -> Bool
    is_and = |a, id| Arena.kind(a, id) == Arena.k_and
    is_not : Arena.A, U32 -> Bool
    is_not = |a, id| Arena.kind(a, id) == Arena.k_not
    is_lookahead : Arena.A, U32 -> Bool
    is_lookahead = |a, id| Arena.kind(a, id) == Arena.k_lookahead
    is_lookbehind : Arena.A, U32 -> Bool
    is_lookbehind = |a, id| Arena.kind(a, id) == Arena.k_lookbehind
    is_anchor : Arena.A, U32 -> Bool
    is_anchor = |a, id| Arena.kind(a, id) == Arena.k_begin or Arena.kind(a, id) == Arena.k_end

    ## Concat head/tail, Loop body, Not inner, Look body
    head : Arena.A, U32 -> U32
    head = |a, id| Arena.fld(a, id, 0)
    tail : Arena.A, U32 -> U32
    tail = |a, id| Arena.fld(a, id, 1)
    loop_lo : Arena.A, U32 -> U32
    loop_lo = |a, id| Arena.fld(a, id, 1)
    loop_hi : Arena.A, U32 -> U32
    loop_hi = |a, id| Arena.fld(a, id, 2)
    look_rel : Arena.A, U32 -> U32
    look_rel = |a, id| Arena.fld(a, id, 1)
    look_pend : Arena.A, U32 -> U32
    look_pend = |a, id| Arena.fld(a, id, 2)

    flags : Arena.A, U32 -> U8
    flags = |a, id| List.get(a.flags, id.to_u64()) ?? 0

    has_flag : Arena.A, U32, U8 -> Bool
    has_flag = |a, id, f| (Arena.flags(a, id)).bitwise_and(f) != 0

    is_always_null : Arena.A, U32 -> Bool
    is_always_null = |a, id| Arena.has_flag(a, id, Arena.f_always_null)
    can_be_null : Arena.A, U32 -> Bool
    can_be_null = |a, id| Arena.has_flag(a, id, Arena.f_can_null)
    contains_look : Arena.A, U32 -> Bool
    contains_look = |a, id| Arena.has_flag(a, id, Arena.f_look)
    depends_anchor : Arena.A, U32 -> Bool
    depends_anchor = |a, id| Arena.has_flag(a, id, Arena.f_anchor)
    has_suffix_la : Arena.A, U32 -> Bool
    has_suffix_la = |a, id| Arena.has_flag(a, id, Arena.f_suffix_la)
    has_prefix_lb : Arena.A, U32 -> Bool
    has_prefix_lb = |a, id| Arena.has_flag(a, id, Arena.f_prefix_lb)

    sub : Arena.A, U32 -> U64
    sub = |a, id| List.get(a.sub, id.to_u64()) ?? 0

    minl : Arena.A, U32 -> U32
    minl = |a, id| List.get(a.minl, id.to_u64()) ?? Arena.none
    maxl : Arena.A, U32 -> U32
    maxl = |a, id| List.get(a.maxl, id.to_u64()) ?? Arena.none

    ## RE#'s `GetFixedLength`
    fixed_len : Arena.A, U32 -> Try(U32, [NotFixed])
    fixed_len = |a, id| {
        mn = Arena.minl(a, id)
        mx = Arena.maxl(a, id)
        if mn != Arena.none and mn == mx { Ok(mn) } else { Err(NotFixed) }
    }

    pend : Arena.A, U32 -> U32
    pend = |a, id| List.get(a.pend, id.to_u64()) ?? 0

    n_nodes : Arena.A -> U64
    n_nodes = |a| List.len(a.offs)

    # --- interning index -------------------------------------------------------

    # FNV-1a over the key's words
    hash : List(U32) -> U64
    hash = |key|
        List.fold(key, 0xCBF2_9CE4_8422_2325, |h, w| h.bitwise_xor(w.to_u64()).times_wrap(0x0000_0100_0000_01B3))

    ## the id a key maps to, if any
    lookup : Arena.A, List(U32) -> Try(U32, [NotFound])
    lookup = |a, key| {
        cap = List.len(a.islots)
        Arena.probe(a, key, (Arena.hash(key)).bitwise_and((cap - 1).to_u64()), cap, 0)
    }

    probe : Arena.A, List(U32), U64, U64, U64 -> Try(U32, [NotFound])
    probe = |a, key, slot, cap, tries|
        if tries >= cap {
            Err(NotFound)
        } else {
            e = List.get(a.islots, slot) ?? 0
            if e == 0 {
                Err(NotFound)
            } else {
                ei = (e - 1).to_u64()
                koff = (List.get(a.ient_key, ei) ?? 0).to_u64()
                klen = (List.get(a.ient_len, ei) ?? 0).to_u64()
                if klen == List.len(key) and List.sublist(a.ikeys, { start: koff, len: klen }) == key {
                    Ok(List.get(a.ient_id, ei) ?? 0)
                } else {
                    Arena.probe(a, key, (slot + 1).bitwise_and((cap - 1).to_u64()), cap, tries + 1)
                }
            }
        }

    ## map `key` to `id` (RE#'s `_nodeCache.Add` / `TryAdd`): no-op if present
    memo : Arena.A, List(U32), U32 -> Arena.A
    memo = |a, key, id|
        match Arena.lookup(a, key) {
            Ok(_) => a
            Err(_) => {
                a1 = if (List.len(a.ient_id) + 1) * 2 > List.len(a.islots) { Arena.grow(a) } else { a }
                ei = (List.len(a1.ient_id)).to_u32_wrap()
                a2 = { ..a1,
                    ient_key: List.append(a1.ient_key, (List.len(a1.ikeys)).to_u32_wrap()),
                    ient_len: List.append(a1.ient_len, (List.len(key)).to_u32_wrap()),
                    ient_id: List.append(a1.ient_id, id),
                    ikeys: List.concat(a1.ikeys, key),
                }
                Arena.place(a2, key, ei)
            }
        }

    # put entry `ei` into the first free slot on its probe sequence
    place : Arena.A, List(U32), U32 -> Arena.A
    place = |a, key, ei| {
        cap = List.len(a.islots)
        slot = Arena.free_slot(a, (Arena.hash(key)).bitwise_and((cap - 1).to_u64()), cap)
        { ..a, islots: List.set(a.islots, slot, ei + 1) ?? a.islots }
    }

    free_slot : Arena.A, U64, U64 -> U64
    free_slot = |a, slot, cap|
        if (List.get(a.islots, slot) ?? 0) == 0 { slot } else { Arena.free_slot(a, (slot + 1).bitwise_and((cap - 1).to_u64()), cap) }

    # double the slot table and re-place every entry
    grow : Arena.A -> Arena.A
    grow = |a| {
        cap2 = List.len(a.islots) * 2
        a1 = { ..a, islots: List.repeat(0.U32, cap2) }
        n = List.len(a1.ient_id)
        List.fold(Arena.upto(n), a1, |acc, ei| {
            koff = (List.get(acc.ient_key, ei) ?? 0).to_u64()
            klen = (List.get(acc.ient_len, ei) ?? 0).to_u64()
            key = List.sublist(acc.ikeys, { start: koff, len: klen })
            Arena.place(acc, key, ei.to_u32_wrap())
        })
    }

    # --- refsets ---------------------------------------------------------------
    #
    # RE#'s `RefSet`: a sorted list of (start, end) relative-position ranges,
    # `uint16` each. Packed here as `s << 16 | e`. Id 0 is empty, id 1 is {(0,0)}.

    rs_get : Arena.A, U32 -> List(U32)
    rs_get = |a, id| {
        o = (List.get(a.rs_off, id.to_u64()) ?? 0).to_u64()
        n = (List.get(a.rs_len, id.to_u64()) ?? 0).to_u64()
        List.sublist(a.rs_data, { start: o, len: n })
    }

    rs_is_empty : Arena.A, U32 -> Bool
    rs_is_empty = |a, id| (List.get(a.rs_len, id.to_u64()) ?? 0) == 0

    ## intern a packed, sorted, merged pair list
    rs_intern : Arena.A, List(U32) -> Arena.R
    rs_intern = |a, pairs|
        if List.is_empty(pairs) {
            { a, id: Arena.rs_empty }
        } else {
            n = List.len(a.rs_off)
            match List.find_first_index(Arena.upto(n), |i| Arena.rs_get(a, i.to_u32_wrap()) == pairs) {
                Ok(i) => { a, id: i.to_u32_wrap() }
                Err(_) => {
                    a1 = { ..a,
                        rs_off: List.append(a.rs_off, (List.len(a.rs_data)).to_u32_wrap()),
                        rs_len: List.append(a.rs_len, (List.len(pairs)).to_u32_wrap()),
                        rs_data: List.concat(a.rs_data, pairs),
                    }
                    { a: a1, id: n.to_u32_wrap() }
                }
            }
        }

    pack : U32, U32 -> U32
    pack = |s, e| s.shl_wrap(16).bitwise_or(e.bitwise_and(0xFFFF))
    ps : U32 -> U32
    ps = |p| p.shr_zf_wrap(16)
    pe : U32 -> U32
    pe = |p| p.bitwise_and(0xFFFF)

    # sort by start then merge adjacent/overlapping ranges (RE#'s refSetRelUnionMany core)
    rs_normalize : List(U32) -> List(U32)
    rs_normalize = |pairs| {
        sorted = List.sort_with(pairs, |x, y| U32.order_relative_to(x, y))
        List.fold(sorted, [], |acc, p|
            match List.last(acc) {
                Ok(q) if Arena.pe(q) + 1 >= Arena.ps(p) => {
                    e = if Arena.pe(p) > Arena.pe(q) { Arena.pe(p) } else { Arena.pe(q) }
                    List.append(List.drop_last(acc, 1), Arena.pack(Arena.ps(q), e))
                }
                _ => List.append(acc, p)
            })
    }

    ## union of two refsets
    rs_union : Arena.A, U32, U32 -> Arena.R
    rs_union = |a, x, y|
        if x == y or Arena.rs_is_empty(a, y) {
            { a, id: x }
        } else if Arena.rs_is_empty(a, x) {
            { a, id: y }
        } else {
            Arena.rs_intern(a, Arena.rs_normalize(List.concat(Arena.rs_get(a, x), Arena.rs_get(a, y))))
        }

    rs_union_many : Arena.A, List(U32) -> Arena.R
    rs_union_many = |a, ids|
        List.fold(ids, { a, id: Arena.rs_empty }, |acc, id| Arena.rs_union(acc.a, acc.id, id))

    ## every range shifted by `by` (RE#'s `refSetAddAll`)
    rs_add_all : Arena.A, U32, U32 -> Arena.R
    rs_add_all = |a, by, id|
        if by == 0 or Arena.rs_is_empty(a, id) {
            { a, id }
        } else {
            Arena.rs_intern(a, List.map(Arena.rs_get(a, id), |p| Arena.pack(Arena.ps(p) + by, Arena.pe(p) + by)))
        }

    ## union of refsets each shifted by (its rel - min_rel) (RE#'s `refSetRelUnionManyMin`)
    rs_rel_union_min : Arena.A, U32, List((U32, U32)) -> Arena.R
    rs_rel_union_min = |a, min_rel, sets| {
        pairs = List.fold(sets, [], |acc, (rel, id)| {
            by = rel - min_rel
            List.concat(acc, List.map(Arena.rs_get(a, id), |p| Arena.pack(Arena.ps(p) + by, Arena.pe(p) + by)))
        })
        Arena.rs_intern(a, Arena.rs_normalize(pairs))
    }

    # --- small helpers -----------------------------------------------------------

    upto : U64 -> List(U64)
    upto = |n| Arena.upto_loop(n, 0, [])

    upto_loop : U64, U64, List(U64) -> List(U64)
    upto_loop = |n, i, acc| if i >= n { acc } else { Arena.upto_loop(n, i + 1, List.append(acc, i)) }

    sort_ids : List(U32) -> List(U32)
    sort_ids = |ids| List.sort_with(ids, |x, y| U32.order_relative_to(x, y))

    ## sorted, deduplicated
    sort_dedup : List(U32) -> List(U32)
    sort_dedup = |ids|
        List.fold(Arena.sort_ids(ids), [], |acc, x| if List.last(acc) == Ok(x) { acc } else { List.append(acc, x) })

    ## remove the first occurrence of `x`
    remove_one : List(U32), U32 -> List(U32)
    remove_one = |xs, x|
        match List.find_first_index(xs, |y| y == x) {
            Ok(i) => List.drop_at(xs, i)
            Err(_) => xs
        }

    max32 : U32, U32 -> U32
    max32 = |x, y| if x > y { x } else { y }
    min32 : U32, U32 -> U32
    min32 = |x, y| if x < y { x } else { y }
}
