## Node construction with RE#'s rewrites (S10): `RegexBuilder.fs` ported rule
## for rule. Tier 1 (ACI normalization and identities) makes the derivative
## space finite; tier 2 (subsumption, RE#'s `MinimizePattern`) keeps it small;
## tier 3 (lookaround normal form, `mkConcatChecked`) is what lets lookarounds
## live in DFA states. RE#'s `sub 0N` / `merge loops N` tags are kept in the
## comments. Every constructor threads the arena and returns `{ a, id }`.
##
## RE# throws `UnsupportedPatternException`; here the arena records the message
## (`Arena.fail`) and the constructor returns `bot`, and `compile` reports it.
import Arena
import TSet

Build := [].{
    R : Arena.R

    ret : Arena.A, U32 -> Arena.R
    ret = |a, id| { a, id }

    # --- patterns (Patterns.fs) --------------------------------------------------

    ## `p*` for a singleton `p`: its tset
    pred_star : Arena.A, U32 -> Try(U64, [No])
    pred_star = |a, id|
        if Arena.is_loop(a, id) and Arena.loop_lo(a, id) == 0 and Arena.loop_hi(a, id) == Arena.inf and Arena.is_singleton(a, Arena.head(a, id)) {
            Ok(Arena.tset(a, Arena.head(a, id)))
        } else {
            Err(No)
        }

    is_pred_star : Arena.A, U32 -> Bool
    is_pred_star = |a, id| Build.pred_star(a, id) != Err(No)

    ## `p{lo,hi}` for a singleton `p`
    pred_loop : Arena.A, U32 -> Try({ t : U64, lo : U32, hi : U32 }, [No])
    pred_loop = |a, id|
        if Arena.is_loop(a, id) and Arena.is_singleton(a, Arena.head(a, id)) {
            Ok({ t: Arena.tset(a, Arena.head(a, id)), lo: Arena.loop_lo(a, id), hi: Arena.loop_hi(a, id) })
        } else {
            Err(No)
        }

    ## `p*` or `p*·R`
    pred_star_head : Arena.A, U32 -> Try(U64, [No])
    pred_star_head = |a, id|
        match Build.pred_star(a, id) {
            Ok(p) => Ok(p)
            Err(_) => if Arena.is_concat(a, id) { Build.pred_star(a, Arena.head(a, id)) } else { Err(No) }
        }

    starts_with_true_star : Arena.A, U32 -> Bool
    starts_with_true_star = |a, id|
        if Arena.is_concat(a, id) {
            Arena.head(a, id) == Arena.top_star
        } else {
            id == Arena.top_star
        }

    ends_with_true_star : Arena.A, U32 -> Bool
    ends_with_true_star = |a, id|
        if Arena.is_concat(a, id) {
            t = Arena.tail(a, id)
            if t == Arena.top_star { True } else { Build.ends_with_true_star(a, t) }
        } else {
            id == Arena.top_star
        }

    ## `SplitTail`: the concat chain's heads and its final non-concat element
    split_tail : Arena.A, U32 -> { heads : List(U32), tail : U32 }
    split_tail = |a, id| Build.split_tail_loop(a, id, [])

    split_tail_loop : Arena.A, U32, List(U32) -> { heads : List(U32), tail : U32 }
    split_tail_loop = |a, id, acc|
        if Arena.is_concat(a, id) {
            Build.split_tail_loop(a, Arena.tail(a, id), List.append(acc, Arena.head(a, id)))
        } else {
            { heads: acc, tail: id }
        }

    ## `ConcatSuffix`: the last element of a concat chain
    concat_suffix : Arena.A, U32 -> U32
    concat_suffix = |a, id| if Arena.is_concat(a, id) { Build.concat_suffix(a, Arena.tail(a, id)) } else { id }

    ## `collectConcatNodes`: a concat chain as a list
    collect_concat : Arena.A, U32 -> List(U32)
    collect_concat = |a, id| {
        s = Build.split_tail(a, id)
        List.append(s.heads, s.tail)
    }

    has_prefix_or_suffix : Arena.A, U32 -> Bool
    has_prefix_or_suffix = |a, id| Arena.has_prefix_lb(a, id) or Arena.has_suffix_la(a, id)

    # --- info inference (Info.fs) -----------------------------------------------

    nullf : U8
    nullf = 3

    infer_or : Arena.A, List(U32) -> U8
    infer_or = |a, ids| List.fold(ids, 0, |acc, id| acc.bitwise_or(Arena.flags(a, id)))

    infer_and : Arena.A, List(U32) -> U8
    infer_and = |a, ids|
        List.fold(ids, Build.nullf, |acc, id| {
            f = Arena.flags(a, id)
            orf = acc.bitwise_or(f).bitwise_and(Arena.f_look.bitwise_or(Arena.f_anchor))
            andf = acc.bitwise_and(f).bitwise_and(Build.nullf)
            orf.bitwise_or(andf)
        })

    infer_concat : Arena.A, U32, U32 -> U8
    infer_concat = |a, h, t| {
        h1 = Arena.flags(a, h)
        t1 = Arena.flags(a, t)
        orf = h1.bitwise_or(t1).bitwise_and(Arena.f_look)
        andf = h1.bitwise_and(t1).bitwise_and(Build.nullf)
        dep = if Arena.depends_anchor(a, h) or (Arena.can_be_null(a, h) and Arena.depends_anchor(a, t)) { Arena.f_anchor } else { 0 }
        suf = if Arena.has_suffix_la(a, t) or Arena.is_lookahead(a, t) { Arena.f_suffix_la } else { 0 }
        pref = if Arena.has_prefix_lb(a, h) or Arena.is_lookbehind(a, h) { Arena.f_prefix_lb } else { 0 }
        andf.bitwise_or(orf).bitwise_or(dep).bitwise_or(suf).bitwise_or(pref)
    }

    infer_loop : Arena.A, U32, U32 -> U8
    infer_loop = |a, body, lo|
        (Arena.flags(a, body)).bitwise_or(if lo == 0 { Build.nullf } else { 0 })

    infer_lookaround : Arena.A, U32, Bool -> U8
    infer_lookaround = |a, body, back| {
        f = Arena.flags(a, body)
        nf = f.bitwise_and(Build.nullf)
        anc = f.bitwise_and(Arena.f_anchor)
        side = if back { Arena.f_prefix_lb } else { Arena.f_suffix_la }
        nf.bitwise_or(Arena.f_look).bitwise_or(side).bitwise_or(anc)
    }

    infer_compl : Arena.A, U32 -> U8
    infer_compl = |a, inner| {
        f = Arena.flags(a, inner)
        nf =
            if !Arena.can_be_null(a, inner) { Build.nullf }
            else if Arena.is_always_null(a, inner) { 0 }
            else { Arena.f_can_null }
        nf.bitwise_or(f.bitwise_and(Arena.f_look.bitwise_or(Arena.f_anchor)))
    }

    add_len : U32, U32 -> U32
    add_len = |x, y| if x == Arena.none or y == Arena.none { Arena.none } else { x + y }

    # min over children; none if any child none
    min_len_or : Arena.A, List(U32) -> U32
    min_len_or = |a, ids|
        List.fold(ids, 0xFFFF_FFFE, |acc, id| {
            v = Arena.minl(a, id)
            if acc == Arena.none or v == Arena.none { Arena.none } else { Arena.min32(acc, v) }
        })

    max_len_or : Arena.A, List(U32) -> U32
    max_len_or = |a, ids|
        List.fold(ids, 0, |acc, id| {
            v = Arena.maxl(a, id)
            if acc == Arena.none or v == Arena.none { Arena.none } else { Arena.max32(acc, v) }
        })

    min_len_and : Arena.A, List(U32) -> U32
    min_len_and = |a, ids|
        List.fold(ids, 0, |acc, id| {
            v = Arena.minl(a, id)
            if acc == Arena.none or v == Arena.none { Arena.none } else { Arena.max32(acc, v) }
        })

    max_len_and : Arena.A, List(U32) -> U32
    max_len_and = |a, ids|
        List.fold(ids, 0xFFFF_FFFE, |acc, id| {
            v = Arena.maxl(a, id)
            if acc == Arena.none or v == Arena.none { Arena.none } else { Arena.min32(acc, v) }
        })

    sub_of : Arena.A, List(U32) -> U64
    sub_of = |a, ids| List.fold(ids, 0, |acc, id| acc.bitwise_or(Arena.sub(a, id)))

    pend_of : Arena.A, List(U32) -> Arena.R
    pend_of = |a, ids| Arena.rs_union_many(a, List.map(ids, |id| Arena.pend(a, id)))

    # --- one -----------------------------------------------------------------------

    one : Arena.A, U64 -> Arena.R
    one = |a, t| {
        key = Arena.key_singleton(t)
        match Arena.lookup(a, key) {
            Ok(id) => { a, id }
            Err(_) => Arena.register(a, key, { flags: 0, sub: t, minl: 1, maxl: 1, pend: Arena.rs_empty })
        }
    }

    # --- mkOr2 -----------------------------------------------------------------------

    mk_or2 : Arena.A, U32, U32 -> Arena.R
    mk_or2 = |a, n1, n2|
        if n1 == n2 {
            { a, id: n1 }
        } else if Arena.is_not(a, n1) and Arena.head(a, n1) == n2 {
            { a, id: Arena.top_star }
        } else if Arena.is_not(a, n2) and Arena.head(a, n2) == n1 {
            { a, id: Arena.top_star }
        } else if n1 == Arena.bot {
            { a, id: n2 }
        } else if n2 == Arena.bot {
            { a, id: n1 }
        } else if n1 == Arena.top_star or n2 == Arena.top_star {
            { a, id: Arena.top_star }
        } else {
            key = Arena.key_or(Arena.sort_ids([n1, n2]))
            match Arena.lookup(a, key) {
                Ok(id) => { a, id }
                Err(_) => Build.or2_rules(a, n1, n2, key)
            }
        }

    or2_rules : Arena.A, U32, U32, List(U32) -> Arena.R
    or2_rules = |a, n1, n2, key|
        if Arena.is_singleton(a, n1) and Arena.is_singleton(a, n2) {
            Build.one(a, (Arena.tset(a, n1)).bitwise_or(Arena.tset(a, n2)))
        } else if (n1 == Arena.eps and Arena.contains_look(a, n2)) or (n2 == Arena.eps and Arena.contains_look(a, n1)) {
            # Deviation from RE#: `ε | X` is not folded when X carries a lookaround.
            # A lookaround node's nullability is transient (its body keeps being
            # derived to verify the text ahead), so `X? -> X` / `-> ε` folds that are
            # sound for ordinary regexes drop a running check: `.[^a]{1,2}[ab]*(?!R)`
            # lost its leftmost start once `LB·rest | rest` became `rest`.
            Build.or_register(a, Arena.sort_ids([n1, n2]))
        } else if n1 == Arena.eps {
            Build.mk_loop(a, n2, 0, 1)
        } else if n2 == Arena.eps {
            Build.mk_loop(a, n1, 0, 1)
        } else if Arena.is_loop(a, n1) and Arena.is_loop(a, n2) and Arena.head(a, n1) == Arena.head(a, n2) {
            # a{0,5}|a{4,7} -> a{0,7}
            Build.mk_loop(a, Arena.head(a, n1), Arena.min32(Arena.loop_lo(a, n1), Arena.loop_lo(a, n2)), Arena.max32(Arena.loop_hi(a, n1), Arena.loop_hi(a, n2)))
        } else if Arena.is_loop(a, n1) and Arena.head(a, n1) == n2 {
            # (ab)|(ab){2} -> (ab){1,2}
            Build.or2_loop_body(a, n1, key)
        } else if Arena.is_loop(a, n2) and Arena.head(a, n2) == n1 {
            Build.or2_loop_body(a, n2, key)
        } else if Arena.is_or(a, n1) {
            if List.contains(Arena.children(a, n1), n2) { { a, id: n1 } } else { Build.mk_or(a, Arena.sort_ids(List.append(Arena.children(a, n1), n2))) }
        } else if Arena.is_or(a, n2) {
            if List.contains(Arena.children(a, n2), n1) { { a, id: n2 } } else { Build.mk_or(a, Arena.sort_ids(List.append(Arena.children(a, n2), n1))) }
        } else {
            match (Build.pred_star(a, n1), Build.pred_star(a, n2)) {
                (Ok(p1), Ok(p2)) =>
                    if TSet.subset(p2, p1) { { a, id: n1 } } else if TSet.subset(p1, p2) { { a, id: n2 } } else { Build.or_create_cached(a, key) }
                _ => Build.or2_rules2(a, n1, n2, key)
            }
        }

    or2_loop_body : Arena.A, U32, List(U32) -> Arena.R
    or2_loop_body = |a, lp, key| {
        lo = Arena.loop_lo(a, lp)
        hi = Arena.loop_hi(a, lp)
        if lo == 2 {
            Build.mk_loop(a, Arena.head(a, lp), 1, hi)
        } else if lo == 0 and hi == 1 {
            { a, id: lp }
        } else {
            Build.or_create_cached(a, key)
        }
    }

    or2_rules2 : Arena.A, U32, U32, List(U32) -> Arena.R
    or2_rules2 = |a, n1, n2, key|
        if Arena.is_concat(a, n1) and Arena.is_concat(a, n2) and Arena.head(a, n1) == Arena.head(a, n2) {
            # merge head
            r1 = Build.mk_or2(a, Arena.tail(a, n1), Arena.tail(a, n2))
            r2 = Build.mk_concat2(r1.a, Arena.head(a, n1), r1.id)
            { a: Arena.memo(r2.a, key, r2.id), id: r2.id }
        } else if Arena.is_anchor(a, n1) and (Arena.is_lookahead(a, n2) or Arena.is_lookbehind(a, n2)) {
            Build.or2_anchor_into_look(a, n1, n2)
        } else if Arena.is_anchor(a, n2) and (Arena.is_lookahead(a, n1) or Arena.is_lookbehind(a, n1)) {
            Build.or2_anchor_into_look(a, n2, n1)
        } else if Arena.is_loop(a, n1) and Arena.is_singleton(a, Arena.head(a, n1)) {
            Build.or2_loop_subsume(a, n1, n2, key)
        } else if Arena.is_loop(a, n2) and Arena.is_singleton(a, Arena.head(a, n2)) {
            Build.or2_loop_subsume(a, n2, n1, key)
        } else {
            Build.or_create_cached_subsume(a, n1, n2, key)
        }

    # put anchor inside lookaround body
    or2_anchor_into_look : Arena.A, U32, U32 -> Arena.R
    or2_anchor_into_look = |a, anc, look| {
        r = Build.mk_or2(a, anc, Arena.head(a, look))
        Build.mk_lookaround(r.a, r.id, Arena.is_lookbehind(a, look), Arena.look_rel(a, look), Arena.look_pend(a, look))
    }

    # sub 013: a loop over a singleton subsumes a node contained in its predicate and length range
    or2_loop_subsume : Arena.A, U32, U32, List(U32) -> Arena.R
    or2_loop_subsume = |a, lp, other, key| {
        lpred = Arena.tset(a, Arena.head(a, lp))
        if TSet.subset(Arena.sub(a, other), lpred) {
            omin = Arena.minl(a, other)
            omax = Arena.maxl(a, other)
            if omin != Arena.none and omax != Arena.none and Arena.loop_lo(a, lp) <= omin and Arena.loop_hi(a, lp) >= omax {
                { a: Arena.memo(a, key, lp), id: lp }
            } else {
                Build.or_create_cached_subsume(a, lp, other, key)
            }
        } else {
            Build.or_create_cached_subsume(a, lp, other, key)
        }
    }

    # an Or of `key`'s two members, without subsumption
    or_create_cached : Arena.A, List(U32) -> Arena.R
    or_create_cached = |a, key| {
        ids = List.drop_first(key, 2)
        match Arena.lookup(a, key) {
            Ok(id) => { a, id }
            Err(_) => Build.or_register(a, ids)
        }
    }

    or_register : Arena.A, List(U32) -> Arena.R
    or_register = |a, ids| {
        p = Build.pend_of(a, ids)
        r = Arena.register(p.a, Arena.key_or(ids), { flags: Build.infer_or(a, ids), sub: Build.sub_of(a, ids), minl: Build.min_len_or(a, ids), maxl: Build.max_len_or(a, ids), pend: p.id })
        { a: { ..r.a, or_count: r.a.or_count + 1 }, id: r.id }
    }

    or_create_cached_subsume : Arena.A, U32, U32, List(U32) -> Arena.R
    or_create_cached_subsume = |a, n1, n2, key| {
        s1 = Build.split_tail(a, n1)
        s2 = Build.split_tail(a, n2)
        if s1.tail == s2.tail {
            h1 = Build.mk_concat_list(a, s1.heads)
            h2 = Build.mk_concat_list(h1.a, s2.heads)
            nh = Build.mk_or2(h2.a, h1.id, h2.id)
            Build.mk_concat2(nh.a, nh.id, s1.tail)
        } else {
            Build.or_create_cached(a, key)
        }
    }

    # --- mkOr (n-ary) ----------------------------------------------------------------

    ## sort then `mk_or` (RE#'s `mkOrSeq`)
    mk_or_seq : Arena.A, List(U32) -> Arena.R
    mk_or_seq = |a, ids| Build.mk_or(a, Arena.sort_dedup(ids))

    ## `mk_or` over an already-sorted list
    mk_or : Arena.A, List(U32) -> Arena.R
    mk_or = |a, nodes| {
        key = Arena.key_or(nodes)
        match Arena.lookup(a, key) {
            Ok(id) => { a, id }
            Err(_) => {
                sc = Build.or_scan(a, nodes, { derivs: [], stars: [], true_star: False, eps: False, zeroloops: 0 })
                if sc.true_star {
                    { a: Arena.memo(a, key, Arena.top_star), id: Arena.top_star }
                } else {
                    # star loops subsume derivatives contained in their predicate
                    d1 = List.fold(sc.stars, sc.derivs, |ds, star|
                        match Build.pred_star(a, star) {
                            Ok(p) => List.drop_if(ds, |d| d != star and TSet.subset(Arena.sub(a, d), p))
                            Err(_) => ds
                        })
                    # add epsilon only if no nullables yet (a lookaround's nullability is
                    # transient and does not absorb ε — see `mk_or2`)
                    d2 = if sc.eps and !List.any(d1, |d| Arena.is_always_null(a, d) and !Arena.contains_look(a, d)) { List.append(d1, Arena.eps) } else { d1 }
                    # merge singletons
                    m = Build.merge_singletons(a, d2)
                    d4 = if sc.zeroloops > 0 { Build.merge_or_grouped_loops(m.a, m.derivs) } else { m.derivs }
                    r5 = Build.merge_or_lookaheads(m.a, d4)
                    r6 =
                        if r5.a.or_count < 2000 {
                            i1 = Build.merge_or_intersections(r5.a, r5.derivs)
                            h1 = Build.merge_or_grouped_heads(r5.a, i1)
                            t1 = Build.merge_or_grouped_tails(h1.a, h1.derivs)
                            Build.merge_or_non_zero_loops(t1.a, t1.derivs)
                        } else {
                            r5
                        }
                    fin = Build.or_finish(r6.a, r6.derivs)
                    { a: Arena.memo(fin.a, key, fin.id), id: fin.id }
                }
            }
        }
    }

    OrScan : { derivs : List(U32), stars : List(U32), true_star : Bool, eps : Bool, zeroloops : U64 }

    or_scan : Arena.A, List(U32), Build.OrScan -> Build.OrScan
    or_scan = |a, nodes, st|
        List.fold(nodes, st, |acc, d|
            if acc.true_star {
                acc
            } else if d == Arena.bot {
                acc
            } else if d == Arena.top_star {
                { ..acc, true_star: True }
            } else if d == Arena.eps {
                { ..acc, eps: True }
            } else if Arena.is_or(a, d) {
                Build.or_scan(a, Arena.children(a, d), acc)
            } else if Arena.is_concat(a, d) {
                h = Arena.head(a, d)
                if Arena.is_loop(a, h) and Arena.loop_lo(a, h) == 0 and Arena.loop_hi(a, h) != Arena.inf {
                    { ..acc, zeroloops: acc.zeroloops + 1, derivs: List.append(acc.derivs, d) }
                } else {
                    { ..acc, derivs: List.append(acc.derivs, d) }
                }
            } else if Arena.is_loop(a, d) and Arena.loop_lo(a, d) == 0 and Arena.loop_hi(a, d) != Arena.inf {
                { ..acc, zeroloops: acc.zeroloops + 1, derivs: List.append(acc.derivs, d) }
            } else if Arena.is_loop(a, d) and Arena.loop_lo(a, d) == 0 and Arena.loop_hi(a, d) == Arena.inf and Arena.is_singleton(a, Arena.head(a, d)) {
                { ..acc, stars: List.append(acc.stars, d), derivs: List.append(acc.derivs, d) }
            } else {
                { ..acc, derivs: List.append(acc.derivs, d) }
            })

    Derivs : { a : Arena.A, derivs : List(U32) }

    merge_singletons : Arena.A, List(U32) -> Build.Derivs
    merge_singletons = |a, ds| {
        singles = List.keep_if(ds, |d| Arena.is_singleton(a, d))
        if List.is_empty(singles) {
            { a, derivs: ds }
        } else {
            rest = List.drop_if(ds, |d| Arena.is_singleton(a, d))
            ss = List.fold(singles, 0, |acc, d| acc.bitwise_or(Arena.tset(a, d)))
            r = Build.one(a, ss)
            { a: r.a, derivs: List.append(rest, r.id) }
        }
    }

    or_finish : Arena.A, List(U32) -> Arena.R
    or_finish = |a, derivs|
        if List.is_empty(derivs) {
            { a, id: Arena.bot }
        } else if List.len(derivs) == 1 {
            { a, id: List.get(derivs, 0) ?? Arena.bot }
        } else {
            ids = Arena.sort_dedup(derivs)
            if List.len(ids) == 1 {
                { a, id: List.get(ids, 0) ?? Arena.bot }
            } else {
                match Arena.lookup(a, Arena.key_or(ids)) {
                    Ok(id) => { a, id }
                    Err(_) => Build.or_register(a, ids)
                }
            }
        }

    # C{0,9}D | C{0,8}D = C{0,9}D — remove loop duplicates
    merge_or_grouped_loops : Arena.A, List(U32) -> List(U32)
    merge_or_grouped_loops = |a, ds| {
        entries = List.fold(ds, [], |acc, d|
            match Build.loop_group_key(a, d) {
                Ok(k) => List.append(acc, { d, body: k.body, tail: k.tail, lo: k.lo, hi: k.hi })
                Err(_) => acc
            })
        # per (body, tail): the widest range
        List.drop_if(ds, |d|
            match List.find_first(entries, |e| e.d == d) {
                Err(_) => False
                Ok(e) => {
                    same = List.keep_if(entries, |x| x.body == e.body and x.tail == e.tail)
                    maxv = List.fold(same, 0, |m, x| Arena.max32(m, x.hi))
                    minv = List.fold(same, Arena.inf, |m, x| Arena.min32(m, x.lo))
                    e.hi < maxv or (e.hi == 1 and e.lo == 1 and 1 > minv)
                }
            })
    }

    # a zero-lower-bounded loop (or a singleton, read as {1,1}) with its tail
    loop_group_key : Arena.A, U32 -> Try({ body : U32, tail : U32, lo : U32, hi : U32 }, [No])
    loop_group_key = |a, d|
        if Arena.is_concat(a, d) {
            h = Arena.head(a, d)
            if Arena.is_loop(a, h) and Arena.loop_lo(a, h) == 0 and Arena.loop_hi(a, h) < Arena.inf {
                Ok({ body: Arena.head(a, h), tail: Arena.tail(a, d), lo: 0, hi: Arena.loop_hi(a, h) })
            } else if Arena.is_singleton(a, h) {
                Ok({ body: h, tail: Arena.tail(a, d), lo: 1, hi: 1 })
            } else {
                Err(No)
            }
        } else if Arena.is_loop(a, d) and Arena.loop_lo(a, d) == 0 and Arena.loop_hi(a, d) < Arena.inf {
            Ok({ body: Arena.head(a, d), tail: Arena.eps, lo: 0, hi: Arena.loop_hi(a, d) })
        } else if Arena.is_singleton(a, d) {
            Ok({ body: d, tail: Arena.eps, lo: 1, hi: 1 })
        } else {
            Err(No)
        }

    # lookaheads with the same body merge their pending-nullable sets
    merge_or_lookaheads : Arena.A, List(U32) -> Build.Derivs
    merge_or_lookaheads = |a, ds| {
        las = List.keep_if(ds, |d| Arena.is_lookahead(a, d))
        if List.len(las) < 2 {
            { a, derivs: ds }
        } else {
            min_rel = List.fold(las, Arena.inf, |m, d| Arena.min32(m, Arena.look_rel(a, d)))
            others = List.drop_if(ds, |d| Arena.is_lookahead(a, d))
            bodies = Arena.sort_dedup(List.map(las, |d| Arena.head(a, d)))
            List.fold(bodies, { a, derivs: others }, |acc, body| {
                grp = List.keep_if(las, |d| Arena.head(a, d) == body)
                if List.len(grp) == 1 {
                    { a: acc.a, derivs: List.append(acc.derivs, List.get(grp, 0) ?? Arena.bot) }
                } else {
                    # an empty pending set means "one candidate end, `rel` back":
                    # RE# unions the sets as-is and loses that candidate (log,
                    # "RE# divergences"); read it as {(0,0)}.
                    nulls = Arena.rs_rel_union_min(acc.a, min_rel, List.map(grp, |d| (Arena.look_rel(a, d), if Arena.look_pend(a, d) == Arena.rs_empty { Arena.rs_zero } else { Arena.look_pend(a, d) })))
                    m = Build.mk_lookaround(nulls.a, body, False, min_rel, nulls.id)
                    { a: m.a, derivs: List.append(acc.derivs, m.id) }
                }
            })
        }
    }

    # And-derivatives whose conjunct set contains another's are dropped
    merge_or_intersections : Arena.A, List(U32) -> List(U32)
    merge_or_intersections = |a, ds| {
        ands = List.keep_if(ds, |d| Arena.is_and(a, d))
        List.drop_if(ds, |d|
            Arena.is_and(a, d) and List.any(ands, |prev| prev != d and List.all(Arena.children(a, prev), |x| List.contains(Arena.children(a, d), x))))
    }

    # a·X | a·Y -> a·(X|Y)
    merge_or_grouped_heads : Arena.A, List(U32) -> Build.Derivs
    merge_or_grouped_heads = |a, ds| {
        keyed = List.fold(ds, [], |acc, d|
            if Arena.is_concat(a, d) { List.append(acc, { d, h: Arena.head(a, d), t: Arena.tail(a, d) }) }
            else if Arena.is_singleton(a, d) { List.append(acc, { d, h: d, t: Arena.eps }) }
            else { acc })
        others = List.drop_if(ds, |d| Arena.is_concat(a, d) or Arena.is_singleton(a, d))
        heads = Arena.sort_dedup(List.map(keyed, |e| e.h))
        List.fold(heads, { a, derivs: others }, |acc, h| {
            grp = List.keep_if(keyed, |e| e.h == h)
            if List.len(grp) == 1 {
                { a: acc.a, derivs: List.append(acc.derivs, (List.get(grp, 0) ?? { d: Arena.bot, h: 0, t: 0 }).d) }
            } else {
                o = Build.mk_or(acc.a, Arena.sort_dedup(List.map(grp, |e| e.t)))
                c = Build.mk_concat2(o.a, h, o.id)
                { a: c.a, derivs: List.append(acc.derivs, c.id) }
            }
        })
    }

    # X·t | Y·t -> (X|Y)·t
    merge_or_grouped_tails : Arena.A, List(U32) -> Build.Derivs
    merge_or_grouped_tails = |a, ds| {
        keyed = List.map(ds, |d| {
            s = Build.split_tail(a, d)
            { d, heads: s.heads, t: s.tail }
        })
        tails = Arena.sort_dedup(List.map(keyed, |e| e.t))
        List.fold(tails, { a, derivs: [] }, |acc, t| {
            grp = List.keep_if(keyed, |e| e.t == t)
            if List.len(grp) == 1 {
                { a: acc.a, derivs: List.append(acc.derivs, (List.get(grp, 0) ?? { d: Arena.bot, heads: [], t: 0 }).d) }
            } else {
                hs = List.fold(grp, { a: acc.a, ids: [] }, |st, e| {
                    r = Build.mk_concat_list(st.a, e.heads)
                    { a: r.a, ids: List.append(st.ids, r.id) }
                })
                o = Build.mk_or(hs.a, Arena.sort_dedup(hs.ids))
                c = Build.mk_concat2(o.a, o.id, t)
                { a: c.a, derivs: List.append(acc.derivs, c.id) }
            }
        })
    }

    # a{1,3}·t | a{2,5}·t -> a{1,5}·t: union the loop ranges per (body, tail)
    merge_or_non_zero_loops : Arena.A, List(U32) -> Build.Derivs
    merge_or_non_zero_loops = |a, ds| {
        keyed = List.fold(ds, [], |acc, d|
            match Build.nz_key(a, d) {
                Ok(k) => List.append(acc, k)
                Err(_) => acc
            })
        others = List.drop_if(ds, |d| Build.nz_key(a, d) != Err(No))
        pairs = List.fold(keyed, [], |acc, k| if List.contains(acc, (k.body, k.tail)) { acc } else { List.append(acc, (k.body, k.tail)) })
        List.fold(pairs, { a, derivs: others }, |acc, (body, tail)| {
            ranges = List.keep_if(keyed, |k| k.body == body and k.tail == tail) |> List.map(|k| (k.lo, k.hi))
            merged = Build.union_ranges(ranges)
            List.fold(merged, acc, |st, (lo, hi)| {
                l = Build.mk_loop(st.a, body, lo, hi)
                c = Build.mk_concat2(l.a, l.id, tail)
                { a: c.a, derivs: List.append(st.derivs, c.id) }
            })
        })
    }

    nz_key : Arena.A, U32 -> Try({ body : U32, tail : U32, lo : U32, hi : U32 }, [No])
    nz_key = |a, d|
        if Arena.is_concat(a, d) {
            h = Arena.head(a, d)
            if Arena.is_loop(a, h) {
                Ok({ body: Arena.head(a, h), tail: Arena.tail(a, d), lo: Arena.loop_lo(a, h), hi: Arena.loop_hi(a, h) })
            } else {
                Ok({ body: h, tail: Arena.tail(a, d), lo: 1, hi: 1 })
            }
        } else if Arena.is_loop(a, d) and Arena.loop_hi(a, d) < 0xFFFF {
            Ok({ body: Arena.head(a, d), tail: Arena.eps, lo: Arena.loop_lo(a, d), hi: Arena.loop_hi(a, d) })
        } else if Arena.is_singleton(a, d) {
            Ok({ body: d, tail: Arena.eps, lo: 1, hi: 1 })
        } else {
            Err(No)
        }

    # RangeSet.unionMany: sort by start, merge overlapping or adjacent ranges
    union_ranges : List((U32, U32)) -> List((U32, U32))
    union_ranges = |rs| {
        sorted = List.sort_with(rs, |(s1, _), (s2, _)| U32.order_relative_to(s1, s2))
        List.fold(sorted, [], |acc, (s, e)|
            match List.last(acc) {
                Ok((cs, ce)) if ce == Arena.inf or ce + 1 >= s => List.append(List.drop_last(acc, 1), (cs, Arena.max32(ce, e)))
                _ => List.append(acc, (s, e))
            })
    }

    # --- mkAnd2 / mkAnd ----------------------------------------------------------------

    mk_and2 : Arena.A, U32, U32 -> Arena.R
    mk_and2 = |a, n1, n2|
        if n1 == n2 {
            { a, id: n1 }
        } else if Arena.is_not(a, n1) and Arena.head(a, n1) == n2 {
            { a, id: Arena.bot }
        } else if Arena.is_not(a, n2) and Arena.head(a, n2) == n1 {
            { a, id: Arena.bot }
        } else if n1 == Arena.bot or n2 == Arena.bot {
            { a, id: Arena.bot }
        } else if n1 == Arena.top_star {
            { a, id: n2 }
        } else if n2 == Arena.top_star {
            { a, id: n1 }
        } else if n1 == Arena.eps or n2 == Arena.eps {
            # Deviation from RE#, which folds `ε & X` to ε whenever X CAN be nullable:
            # an anchor-dependent X (`_*(\A|\n)`, i.e. `^` rewritten) is nullable
            # only at some positions, and the fold made `b^ ?|.` match "b " on "b a".
            # Only an always-nullable X folds; otherwise the intersection stays and
            # the location decides.
            x = if n1 == Arena.eps { n2 } else { n1 }
            if Arena.is_always_null(a, x) {
                { a, id: Arena.eps }
            } else if !Arena.can_be_null(a, x) {
                { a, id: Arena.bot }
            } else {
                key = Arena.key_and(Arena.sort_ids([n1, n2]))
                match Arena.lookup(a, key) {
                    Ok(id) => { a, id }
                    Err(_) => Build.and_create_cached(a, List.drop_first(key, 2))
                }
            }
        } else {
            key = Arena.key_and(Arena.sort_ids([n1, n2]))
            match Arena.lookup(a, key) {
                Ok(id) => { a, id }
                Err(_) => Build.and2_rules(a, n1, n2, key)
            }
        }

    and2_rules : Arena.A, U32, U32, List(U32) -> Arena.R
    and2_rules = |a, n1, n2, key|
        if Arena.is_singleton(a, n1) and Arena.is_singleton(a, n2) {
            Build.one(a, (Arena.tset(a, n1)).bitwise_and(Arena.tset(a, n2)))
        } else if Arena.is_and(a, n1) {
            if List.contains(Arena.children(a, n1), n2) { { a, id: n1 } } else { Build.mk_and(a, Arena.sort_ids(List.append(Arena.children(a, n1), n2))) }
        } else if Arena.is_and(a, n2) {
            if List.contains(Arena.children(a, n2), n1) { { a, id: n2 } } else { Build.mk_and(a, Arena.sort_ids(List.append(Arena.children(a, n2), n1))) }
        } else {
            match (Build.pred_loop(a, n1), Build.pred_loop(a, n2)) {
                (Ok(l1), Ok(l2)) => {
                    p1large = TSet.subset(l2.t, l1.t)
                    p2large = TSet.subset(l1.t, l2.t)
                    p1rl = l1.lo <= l2.lo and l1.hi >= l2.hi
                    p2rl = l2.lo <= l1.lo and l2.hi >= l1.hi
                    if (p1large or p2large) and (p1rl or p2rl) {
                        smpred = if p1large { l2.t } else { l1.t }
                        sm = if p1rl { l2 } else { l1 }
                        o = Build.one(a, smpred)
                        r = Build.mk_loop(o.a, o.id, sm.lo, sm.hi)
                        { a: Arena.memo(r.a, key, r.id), id: r.id }
                    } else {
                        Build.and_create_cached(a, List.drop_first(key, 2))
                    }
                }
                _ =>
                    match (Build.pred_star(a, n1), Build.pred_star(a, n2)) {
                        (Ok(p), _) => if TSet.subset(Arena.sub(a, n2), p) { { a, id: n2 } } else { Build.and_create_cached(a, List.drop_first(key, 2)) }
                        (_, Ok(p)) => if TSet.subset(Arena.sub(a, n1), p) { { a, id: n1 } } else { Build.and_create_cached(a, List.drop_first(key, 2)) }
                        _ => Build.and_create_cached(a, List.drop_first(key, 2))
                    }
            }
        }

    and_create_cached : Arena.A, List(U32) -> Arena.R
    and_create_cached = |a, ids0| {
        ids = Arena.sort_dedup(ids0)
        if List.is_empty(ids) {
            { a, id: Arena.top_star }
        } else if List.len(ids) == 1 {
            { a, id: List.get(ids, 0) ?? Arena.bot }
        } else {
            match Arena.lookup(a, Arena.key_and(ids)) {
                Ok(id) => { a, id }
                Err(_) =>
                    if List.any(ids, |id| Build.has_prefix_or_suffix(a, id)) {
                        r = Build.merge_and_prefix_suffix(a, ids)
                        { a: Arena.memo(r.a, Arena.key_and(ids), r.id), id: r.id }
                    } else {
                        p = Build.pend_of(a, ids)
                        Arena.register(p.a, Arena.key_and(ids), { flags: Build.infer_and(a, ids), sub: Build.sub_of(a, ids), minl: Build.min_len_and(a, ids), maxl: Build.max_len_and(a, ids), pend: p.id })
                    }
            }
        }
    }

    mk_and_seq : Arena.A, List(U32) -> Arena.R
    mk_and_seq = |a, ids| Build.mk_and(a, Arena.sort_dedup(ids))

    mk_and : Arena.A, List(U32) -> Arena.R
    mk_and = |a, nodes| {
        key = Arena.key_and(nodes)
        match Arena.lookup(a, key) {
            Ok(id) => { a, id }
            Err(_) =>
                if List.len(nodes) == 2 {
                    Build.mk_and2(a, List.get(nodes, 0) ?? Arena.bot, List.get(nodes, 1) ?? Arena.bot)
                } else {
                    sc = Build.and_scan(a, nodes, { derivs: [], stars: [], compls: [], is_false: False, eps: False })
                    if sc.is_false {
                        { a: Arena.memo(a, key, Arena.bot), id: Arena.bot }
                    } else {
                        # add all complements together
                        c1 =
                            if List.is_empty(sc.compls) {
                                { a, derivs: sc.derivs }
                            } else {
                                o = Build.mk_or_seq(a, sc.compls)
                                n = Build.mk_not(o.a, o.id)
                                { a: n.a, derivs: Arena.sort_dedup(List.append(sc.derivs, n.id)) }
                            }
                        # a star loop is dropped when some other conjunct is contained in it
                        d2 = List.fold(sc.stars, c1.derivs, |ds, star|
                            match Build.pred_star(a, star) {
                                Ok(p) => if List.any(ds, |d| d != star and TSet.subset(Arena.sub(a, d), p)) { ds } else { Arena.sort_dedup(List.append(ds, star)) }
                                Err(_) => ds
                            })
                        if sc.eps and List.any(d2, |d| !Arena.can_be_null(c1.a, d)) {
                            { a: Arena.memo(c1.a, key, Arena.bot), id: Arena.bot }
                        } else {
                            d3 = if sc.eps { Arena.sort_dedup(List.append(d2, Arena.eps)) } else { d2 }
                            if !List.is_empty(d3) and List.all(d3, |d| Arena.is_singleton(c1.a, d)) {
                                # RE# unions these; an intersection of singletons is their intersection (log)
                                r = Build.one(c1.a, List.fold(d3, Arena.full(c1.a), |acc, d| acc.bitwise_and(Arena.tset(c1.a, d))))
                                { a: Arena.memo(r.a, key, r.id), id: r.id }
                            } else {
                                g1 = Build.and_group_heads(c1.a, d3)
                                g2 = Build.and_group_tails(g1.a, g1.derivs)
                                r = Build.and_create_cached(g2.a, g2.derivs)
                                { a: Arena.memo(r.a, key, r.id), id: r.id }
                            }
                        }
                    }
                }
        }
    }

    AndScan : { derivs : List(U32), stars : List(U32), compls : List(U32), is_false : Bool, eps : Bool }

    and_scan : Arena.A, List(U32), Build.AndScan -> Build.AndScan
    and_scan = |a, nodes, st|
        List.fold(nodes, st, |acc, d|
            if acc.is_false or d == Arena.top_star {
                acc
            } else if d == Arena.bot {
                { ..acc, is_false: True }
            } else if d == Arena.eps {
                { ..acc, eps: True }
            } else if Arena.is_and(a, d) {
                Build.and_scan(a, Arena.children(a, d), acc)
            } else if Arena.is_not(a, d) {
                { ..acc, compls: List.append(acc.compls, Arena.head(a, d)) }
            } else if Arena.is_loop(a, d) and Arena.loop_lo(a, d) == 0 and Arena.loop_hi(a, d) == Arena.inf and Arena.is_singleton(a, Arena.head(a, d)) {
                { ..acc, stars: List.append(acc.stars, d) }
            } else if List.contains(acc.derivs, d) {
                acc
            } else {
                { ..acc, derivs: List.append(acc.derivs, d) }
            })

    # concats whose heads have the same fixed length: (h1·t1)&(h2·t2) -> (h1&h2)·(t1&t2)
    and_group_heads : Arena.A, List(U32) -> Build.Derivs
    and_group_heads = |a, ds| {
        grp_of = |d|
            if Arena.is_concat(a, d) and Arena.tail(a, d) != Arena.eps {
                match Arena.fixed_len(a, Arena.head(a, d)) {
                    Ok(0) => Err(No)
                    Ok(n) => Ok(n)
                    Err(_) => Err(No)
                }
            } else {
                Err(No)
            }
        lens = List.fold(ds, [], |acc, d| match grp_of(d) { Ok(n) => if List.contains(acc, n) { acc } else { List.append(acc, n) }, Err(_) => acc })
        ungrouped = List.keep_if(ds, |d| grp_of(d) == Err(No))
        List.fold(lens, { a, derivs: ungrouped }, |acc, n| {
            grp = List.keep_if(ds, |d| grp_of(d) == Ok(n))
            if List.len(grp) == 1 {
                { a: acc.a, derivs: List.append(acc.derivs, List.get(grp, 0) ?? Arena.bot) }
            } else {
                h = Build.mk_and_seq(acc.a, List.map(grp, |d| Arena.head(a, d)))
                t = Build.mk_and_seq(h.a, List.map(grp, |d| Arena.tail(a, d)))
                c = Build.mk_concat2(t.a, h.id, t.id)
                { a: c.a, derivs: List.append(acc.derivs, c.id) }
            }
        })
    }

    # concat chains whose final element has the same fixed length: (H1·t1)&(H2·t2) -> (H1&H2)·(t1&t2)
    and_group_tails : Arena.A, List(U32) -> Build.Derivs
    and_group_tails = |a, ds| {
        keyed = List.map(ds, |d| {
            s = Build.split_tail(a, d)
            g =
                if List.is_empty(s.heads) { Err(No) }
                else {
                    match Arena.fixed_len(a, s.tail) {
                        Ok(0) => Err(No)
                        Ok(n) => Ok(n)
                        Err(_) => Err(No)
                    }
                }
            { d, heads: s.heads, t: s.tail, g }
        })
        lens = List.fold(keyed, [], |acc, e| match e.g { Ok(n) => if List.contains(acc, n) { acc } else { List.append(acc, n) }, Err(_) => acc })
        ungrouped = List.keep_if(keyed, |e| e.g == Err(No)) |> List.map(|e| e.d)
        List.fold(lens, { a, derivs: ungrouped }, |acc, n| {
            grp = List.keep_if(keyed, |e| e.g == Ok(n))
            if List.len(grp) == 1 {
                { a: acc.a, derivs: List.append(acc.derivs, (List.get(grp, 0) ?? { d: Arena.bot, heads: [], t: 0, g: Err(No) }).d) }
            } else {
                hs = List.fold(grp, { a: acc.a, ids: [] }, |st, e| {
                    r = Build.mk_concat_list(st.a, e.heads)
                    { a: r.a, ids: List.append(st.ids, r.id) }
                })
                h = Build.mk_and_seq(hs.a, hs.ids)
                t = Build.mk_and_seq(h.a, List.map(grp, |e| e.t))
                c = Build.mk_concat2(t.a, h.id, t.id)
                { a: c.a, derivs: List.append(acc.derivs, c.id) }
            }
        })
    }

    ## `(?<=P1)A(?=S1) & (?<=P2)B(?=S2)` -> `(?<=P1)(?<=P2) (A&B) (?=S1)(?=S2)`
    merge_and_prefix_suffix : Arena.A, List(U32) -> Arena.R
    merge_and_prefix_suffix = |a, nodes| {
        parts = List.fold(nodes, { a, prefixes: [], suffixes: [], remaining: [] }, |acc, v| {
            s = Build.strip_prefix_suffix(acc.a, v)
            rem = if s.node == Arena.top_star { acc.remaining } else { List.append(acc.remaining, s.node) }
            { a: s.a, prefixes: List.concat(acc.prefixes, s.prefixes), suffixes: List.concat(acc.suffixes, s.suffixes), remaining: rem }
        })
        if List.is_empty(parts.prefixes) and List.is_empty(parts.suffixes) {
            { a: Arena.fail(parts.a, "this pattern is unsupported because of nested lookarounds"), id: Arena.bot }
        } else {
            pre = Build.mk_concat_list(parts.a, parts.prefixes)
            suf = Build.mk_concat_list(pre.a, parts.suffixes)
            node = Build.mk_and_seq(suf.a, parts.remaining)
            inner = Build.mk_concat2(node.a, node.id, suf.id)
            Build.mk_concat2(inner.a, pre.id, inner.id)
        }
    }

    Strip : { a : Arena.A, prefixes : List(U32), node : U32, suffixes : List(U32) }

    ## `stripSuffixes`: (remaining pattern, suffix lookaheads)
    strip_suffixes : Arena.A, U32 -> { a : Arena.A, node : U32, suffixes : List(U32) }
    strip_suffixes = |a, node|
        if !Build.has_prefix_or_suffix(a, node) {
            { a, node, suffixes: [] }
        } else if Arena.is_concat(a, node) {
            ch = Arena.head(a, node)
            ct = Arena.tail(a, node)
            if Arena.is_lookbehind(a, ch) {
                { a, node, suffixes: [] }
            } else if Arena.is_lookahead(a, ct) {
                { a, node: ch, suffixes: [ct] }
            } else if Arena.is_concat(a, ct) and Arena.is_lookahead(a, Arena.head(a, ct)) {
                inner = Build.strip_suffixes(a, Arena.tail(a, ct))
                { a: inner.a, node: ch, suffixes: List.prepend(inner.suffixes, Arena.head(a, ct)) }
            } else {
                inner = Build.strip_suffixes(a, ct)
                c = Build.mk_concat2(inner.a, ch, inner.node)
                { a: c.a, node: c.id, suffixes: inner.suffixes }
            }
        } else if Arena.is_lookahead(a, node) {
            { a, node: Arena.eps, suffixes: [node] }
        } else if Arena.is_lookbehind(a, node) {
            { a, node, suffixes: [] }
        } else if Arena.is_or(a, node) {
            if Arena.fixed_len(a, node) == Ok(0) {
                { a, node: Arena.eps, suffixes: [node] }
            } else {
                { a: Arena.fail(a, "cannot infer width for lookaround Or node"), node, suffixes: [] }
            }
        } else {
            { a, node, suffixes: [] }
        }

    ## `stripPrefixSuffix`: (prefix lookbehinds, remaining pattern, suffix lookaheads)
    strip_prefix_suffix : Arena.A, U32 -> Build.Strip
    strip_prefix_suffix = |a, node|
        if !Build.has_prefix_or_suffix(a, node) {
            { a, prefixes: [], node, suffixes: [] }
        } else if Arena.is_concat(a, node) {
            h = Arena.head(a, node)
            t = Arena.tail(a, node)
            if Arena.is_lookbehind(a, h) {
                inner = Build.strip_prefix_suffix(a, t)
                { ..inner, prefixes: List.prepend(inner.prefixes, h) }
            } else if Arena.is_lookahead(a, t) {
                { a, prefixes: [], node: h, suffixes: [t] }
            } else if Arena.is_concat(a, t) and Arena.is_lookahead(a, Arena.head(a, t)) {
                inner = Build.strip_suffixes(a, Arena.tail(a, t))
                { a: inner.a, prefixes: [], node: h, suffixes: List.prepend(inner.suffixes, Arena.head(a, t)) }
            } else {
                hp = Build.head_prefix(a, h)
                inner = Build.strip_suffixes(hp.a, t)
                c = Build.mk_concat2(inner.a, hp.node, inner.node)
                { a: c.a, prefixes: hp.prefixes, node: c.id, suffixes: inner.suffixes }
            }
        } else if Arena.is_lookahead(a, node) {
            { a, prefixes: [], node: Arena.eps, suffixes: [node] }
        } else if Arena.is_lookbehind(a, node) {
            { a, prefixes: [node], node: Arena.eps, suffixes: [] }
        } else if Arena.is_or(a, node) {
            if node == a.anc.dollar {
                { a, prefixes: [], node: Arena.eps, suffixes: [node] }
            } else if node == a.anc.caret {
                { a: Arena.fail(a, "unsupported lookaround/anchor in pattern"), prefixes: [], node, suffixes: [] }
            } else {
                { a, prefixes: [], node, suffixes: [] }
            }
        } else {
            { a, prefixes: [], node, suffixes: [] }
        }

    # a head carrying a lookbehind prefix: peel it if the head is zero- or one-wide
    head_prefix : Arena.A, U32 -> { a : Arena.A, prefixes : List(U32), node : U32 }
    head_prefix = |a, h|
        if Arena.has_prefix_lb(a, h) {
            match Arena.fixed_len(a, h) {
                Ok(0) => { a, prefixes: [h], node: Arena.eps }
                Ok(1) => { a, prefixes: [h], node: Arena.top }
                _ => { a: Arena.fail(a, "cannot infer width for lookaround prefix"), prefixes: [], node: h }
            }
        } else {
            { a, prefixes: [], node: h }
        }

    # --- mkNot ---------------------------------------------------------------------

    mk_not : Arena.A, U32 -> Arena.R
    mk_not = |a, inner| {
        key = Arena.key_not(inner)
        match Arena.lookup(a, key) {
            Ok(id) => { a, id }
            Err(_) => {
                r =
                    if inner == Arena.bot {
                        { a, id: Arena.top_star }
                    } else if inner == Arena.top_star {
                        { a, id: Arena.bot }
                    } else if inner == Arena.eps {
                        { a, id: Arena.top_plus }
                    } else if Arena.contains_look(a, inner) {
                        { a: Arena.fail(a, "lookarounds inside complement are unsupported"), id: Arena.bot }
                    } else if Arena.depends_anchor(a, inner) {
                        { a: Arena.fail(a, "anchors inside complement are unsupported"), id: Arena.bot }
                    } else {
                        Arena.register(a, key, { flags: Build.infer_compl(a, inner), sub: Arena.full(a), minl: Arena.none, maxl: Arena.none, pend: Arena.pend(a, inner) })
                    }
                { a: Arena.memo(r.a, key, r.id), id: r.id }
            }
        }
    }

    # --- mkConcat2 -----------------------------------------------------------------------

    ## right-assoc concatenation of a list (RE#'s `mkConcatResizeArray`)
    mk_concat_list : Arena.A, List(U32) -> Arena.R
    mk_concat_list = |a, ids|
        List.fold_rev(ids, { a, id: Arena.eps }, |v, acc| Build.mk_concat2(acc.a, v, acc.id))

    incr_loop : U32, U32 -> U32
    incr_loop = |x, y| if x == Arena.inf or y == Arena.inf { Arena.inf } else { x + y }

    mk_concat2 : Arena.A, U32, U32 -> Arena.R
    mk_concat2 = |a, h, t|
        if h == Arena.eps {
            { a, id: t }
        } else if t == Arena.eps {
            { a, id: h }
        } else if h == Arena.bot or t == Arena.bot {
            { a, id: Arena.bot }
        } else {
            key = Arena.key_concat(h, t)
            match Arena.lookup(a, key) {
                Ok(id) => { a, id }
                Err(_) => {
                    r = Build.concat_rules(a, h, t)
                    { a: Arena.memo(r.a, key, r.id), id: r.id }
                }
            }
        }

    # Register head·tail once every rewrite has declined. A concat head is
    # right-nested first (`(ab)c -> a(bc)`): RE# only normalizes in its last
    # fall-through, so a rewrite path that ends in `createCached` (e.g. the
    # concat-tail case) registers a structurally distinct copy of a node the
    # derivative also reaches in normal form — `_*\w+@\w+` came back as
    # `(_*\w+)(@\w+)` after `(_*\w+|\w*)@\w+` lost its `\w*` branch, so the
    # reverse sweep never returned to its initial state and the prefix skip
    # fired once per haystack. Canonical concats make those the same state.
    concat_register : Arena.A, U32, U32 -> Arena.R
    concat_register = |a, h, t|
        if Arena.is_concat(a, h) {
            inner = Build.mk_concat2(a, Arena.tail(a, h), t)
            Build.mk_concat2(inner.a, Arena.head(a, h), inner.id)
        } else {
            Build.concat_register_raw(a, h, t)
        }

    concat_register_raw : Arena.A, U32, U32 -> Arena.R
    concat_register_raw = |a, h, t| {
        key = Arena.key_concat(h, t)
        match Arena.lookup(a, key) {
            Ok(id) => { a, id }
            Err(_) => {
                p = Arena.rs_union(a, Arena.pend(a, h), Arena.pend(a, t))
                Arena.register(p.a, key, { flags: Build.infer_concat(a, h, t), sub: (Arena.sub(a, h)).bitwise_or(Arena.sub(a, t)), minl: Build.add_len(Arena.minl(a, h), Arena.minl(a, t)), maxl: Build.add_len(Arena.maxl(a, h), Arena.maxl(a, t)), pend: p.id })
            }
        }
    }

    concat_rules : Arena.A, U32, U32 -> Arena.R
    concat_rules = |a, h, t|
        if h == Arena.top_star and Arena.is_and(a, t) and List.all(Arena.children(a, t), |x| Build.starts_with_true_star(a, x)) {
            { a, id: t }
        } else if t == Arena.top_star and Arena.is_and(a, h) and List.all(Arena.children(a, h), |x| Build.ends_with_true_star(a, x)) {
            { a, id: h }
        } else if Arena.is_loop(a, h) and Arena.is_loop(a, t) and Arena.head(a, h) == Arena.head(a, t) {
            # sub 01: (.*1)?(.*1){2,} -> (.*1){2,}
            Build.mk_loop(a, Arena.head(a, h), Build.incr_loop(Arena.loop_lo(a, h), Arena.loop_lo(a, t)), Build.incr_loop(Arena.loop_hi(a, h), Arena.loop_hi(a, t)))
        } else if Arena.is_loop(a, h) and Arena.head(a, h) == t {
            # sub 02: (.*1)?.*1 -> .*1
            Build.mk_loop(a, t, Build.incr_loop(Arena.loop_lo(a, h), 1), Build.incr_loop(Arena.loop_hi(a, h), 1))
        } else if Arena.is_concat(a, t) {
            ch = Arena.head(a, t)
            t2 = Arena.tail(a, t)
            if Arena.is_loop(a, ch) and Arena.head(a, ch) == h {
                # merge loops 2
                l = Build.mk_loop(a, h, Build.incr_loop(Arena.loop_lo(a, ch), 1), Build.incr_loop(Arena.loop_hi(a, ch), 1))
                Build.mk_concat2(l.a, l.id, t2)
            } else if Arena.is_loop(a, h) and Arena.is_loop(a, ch) and Arena.head(a, h) == Arena.head(a, ch) {
                # merge loops 3
                l = Build.mk_loop(a, Arena.head(a, h), Build.incr_loop(Arena.loop_lo(a, h), Arena.loop_lo(a, ch)), Build.incr_loop(Arena.loop_hi(a, h), Arena.loop_hi(a, ch)))
                Build.mk_concat2(l.a, l.id, t2)
            } else {
                Build.concat_tail_case(a, h, t, ch, t2)
            }
        } else {
            match (Build.pred_star(a, h), Build.pred_star(a, t)) {
                (Ok(p1), Ok(p2)) =>
                    if TSet.subset(p2, p1) { { a, id: h } } else if TSet.subset(p1, p2) { { a, id: t } } else { Build.concat_register(a, h, t) }
                _ => Build.concat_rules2(a, h, t)
            }
        }

    concat_rules2 : Arena.A, U32, U32 -> Arena.R
    concat_rules2 = |a, h, t|
        if Arena.is_lookbehind(a, h) and Arena.is_concat(a, t) and Arena.is_lookbehind(a, Arena.head(a, t)) {
            # (?<=a.*)(?<=\W)aa -> (?<=_*a.*&_*\W)aa
            lb = Build.combine_lookbehinds(a, Arena.head(a, h), Arena.head(a, Arena.head(a, t)))
            Build.mk_concat2(lb.a, lb.id, Arena.tail(a, t))
        } else if Arena.is_lookbehind(a, h) and Arena.is_lookbehind(a, t) {
            Build.combine_lookbehinds(a, Arena.head(a, h), Arena.head(a, t))
        } else if Arena.is_lookbehind(a, h) and Build.is_pred_star(a, Arena.head(a, h)) and (Arena.head(a, h) == t or (Arena.is_concat(a, t) and Arena.head(a, t) == Arena.head(a, h))) {
            # (?<=.*).* -> .*   (?<=.*).*ab -> .*ab
            { a, id: t }
        } else if Arena.is_lookahead(a, h) and Arena.is_lookahead(a, t) {
            # (?=a.*)(?=\W) -> (?=a.*_*&\W_*)
            c1 = Build.mk_concat2(a, Arena.head(a, h), Arena.top_star)
            c2 = Build.mk_concat2(c1.a, Arena.head(a, t), Arena.top_star)
            an = Build.mk_and_seq(c2.a, [c1.id, c2.id])
            Build.mk_lookaround(an.a, an.id, False, Arena.look_rel(a, h), Arena.look_pend(a, h))
        } else if Arena.is_lookahead(a, h) and Arena.head(a, h) == Arena.eps and !Arena.is_always_null(a, t) {
            Build.concat_register(a, h, t)
        } else if Build.sub07(a, h, t) {
            # sub 07: ((.*1)?|b).*a -> .*a
            { a, id: t }
        } else if Arena.is_or(a, h) {
            Build.concat_or_head(a, h, t)
        } else if Arena.is_concat(a, h) {
            # normalize concat
            if Arena.is_loop(a, t) and Arena.head(a, t) == h {
                # (ab)(ab){10} -> (ab){11}
                Build.mk_loop(a, h, Build.incr_loop(Arena.loop_lo(a, t), 1), Build.incr_loop(Arena.loop_hi(a, t), 1))
            } else {
                inner = Build.mk_concat2(a, Arena.tail(a, h), t)
                Build.mk_concat2(inner.a, Arena.head(a, h), inner.id)
            }
        } else {
            Build.concat_register(a, h, t)
        }

    combine_lookbehinds : Arena.A, U32, U32 -> Arena.R
    combine_lookbehinds = |a, b1, b2| {
        c1 = Build.mk_concat2(a, Arena.top_star, b1)
        c2 = Build.mk_concat2(c1.a, Arena.top_star, b2)
        an = Build.mk_and_seq(c2.a, [c1.id, c2.id])
        Build.mk_lookaround(an.a, an.id, True, 0, Arena.rs_empty)
    }

    sub07 : Arena.A, U32, U32 -> Bool
    sub07 = |a, h, t|
        match Build.pred_star_head(a, t) {
            Ok(p) => Arena.is_always_null(a, h) and TSet.subset(Arena.sub(a, h), p)
            Err(_) => False
        }

    # ((.*1)?|b).*a -> .*a : nullable branches contained in the tail's star become eps
    concat_or_head : Arena.A, U32, U32 -> Arena.R
    concat_or_head = |a, h, t|
        match Build.pred_star_head(a, t) {
            Err(_) => Build.concat_register(a, h, t)
            Ok(p) => {
                xs = Arena.children(a, h)
                subsumed = List.any(xs, |n| n != Arena.eps and Arena.is_always_null(a, n) and TSet.subset(Arena.sub(a, n), p))
                if subsumed {
                    ys = List.map(xs, |n| if n != Arena.eps and Arena.is_always_null(a, n) and TSet.subset(Arena.sub(a, n), p) { Arena.eps } else { n })
                    o = Build.mk_or(a, Arena.sort_dedup(ys))
                    Build.mk_concat2(o.a, o.id, t)
                } else {
                    Build.concat_register(a, h, t)
                }
            }
        }

    # `mkConcat2_concatTailCase`: head · Concat(concat_head, tail2)
    concat_tail_case : Arena.A, U32, U32, U32, U32 -> Arena.R
    concat_tail_case = |a, h, t, ch, t2|
        match (Build.pred_star(a, h), Build.pred_star(a, t)) {
            (Ok(p1), Ok(p2)) =>
                if TSet.subset(p2, p1) { { a, id: h } } else if TSet.subset(p1, p2) { { a, id: t } } else { Build.concat_register(a, h, t) }
            (Ok(p1), _) =>
                match Build.pred_star(a, ch) {
                    Ok(p2) =>
                        if TSet.subset(p2, p1) { Build.mk_concat2(a, h, t2) }
                        else if TSet.subset(p1, p2) { Build.mk_concat2(a, ch, t2) }
                        else { Build.concat_register(a, h, t) }
                    Err(_) =>
                        if Arena.is_loop(a, ch) and Arena.loop_lo(a, ch) == 0 and Arena.loop_hi(a, ch) == 1 {
                            # .*(t.*)?hat.* -> .*hat
                            tsuffix = Build.concat_suffix(a, Arena.head(a, ch))
                            if TSet.subset(Arena.sub(a, ch), p1) and h == tsuffix { Build.mk_concat2(a, h, t2) } else { Build.concat_register(a, h, t) }
                        } else {
                            Build.sub03_06(a, h, t, ch, t2)
                        }
                }
            _ =>
                if Arena.is_loop(a, h) and Arena.loop_lo(a, h) == 0 and Arena.loop_hi(a, h) == 1 {
                    # (.*ab)?.* -> .*
                    body = Arena.head(a, h)
                    r =
                        if Arena.is_concat(a, body) {
                            match (Build.pred_star(a, Arena.head(a, body)), Build.pred_star(a, t)) {
                                (Ok(pc), Ok(p2)) =>
                                    if TSet.subset(Arena.sub(a, h), p2) {
                                        if TSet.subset(pc, p2) { Ok(t) } else if body == t { Ok(t) } else { Err(No) }
                                    } else {
                                        Err(No)
                                    }
                                _ => Err(No)
                            }
                        } else {
                            Err(No)
                        }
                    match r {
                        Ok(id) => { a, id }
                        Err(_) => Build.sub03_06(a, h, t, ch, t2)
                    }
                } else if Arena.is_loop(a, h) and Arena.loop_lo(a, h) == 0 {
                    # .{0,20}_* -> _*
                    match Build.pred_star(a, t) {
                        Ok(p2) => if TSet.subset(Arena.sub(a, h), p2) { { a, id: t } } else { Build.concat_register(a, h, t) }
                        Err(_) => Build.sub03_06(a, h, t, ch, t2)
                    }
                } else {
                    Build.sub03_06(a, h, t, ch, t2)
                }
        }

    # `mkConcat2_sub03_06`
    sub03_06 : Arena.A, U32, U32, U32, U32 -> Arena.R
    sub03_06 = |a, n1, t, n2, tail_node| {
        inner = Build.mk_concat2(a, n1, n2)
        a1 = inner.a
        if Build.is_pred_star(a1, inner.id) {
            # sub 06: (.*1)?.*a -> .*a
            Build.mk_concat2(a1, inner.id, tail_node)
        } else if Arena.is_concat(a1, tail_node) {
            c0 = Arena.head(a1, tail_node)
            c1 = Arena.tail(a1, tail_node)
            if n1 == c0 and n2 == c1 {
                # sub 03: .*1.*1$ -> (.*1){2,}
                Build.mk_loop(a1, tail_node, 2, 2)
            } else if Arena.is_concat(a1, c1) and n1 == c0 and n2 == Arena.head(a1, c1) {
                # sub 04 + sub 05
                l = Build.mk_loop(a1, inner.id, 2, 2)
                Build.mk_concat2(l.a, l.id, Arena.tail(a1, c1))
            } else if Arena.is_loop(a1, c0) and Arena.head(a1, c0) == inner.id {
                l = Build.mk_loop(a1, inner.id, Build.incr_loop(Arena.loop_lo(a1, c0), 1), Build.incr_loop(Arena.loop_hi(a1, c0), 1))
                Build.mk_concat2(l.a, l.id, c1)
            } else {
                Build.concat_register(a1, n1, t)
            }
        } else {
            Build.concat_register(a1, n1, t)
        }
    }

    # --- mkLoop ----------------------------------------------------------------------

    mk_loop : Arena.A, U32, U32, U32 -> Arena.R
    mk_loop = |a, body, lo, hi| {
        key = Arena.key_loop(body, lo, hi)
        match Arena.lookup(a, key) {
            Ok(id) => { a, id }
            Err(_) => {
                r = Build.loop_rules(a, body, lo, hi)
                { a: Arena.memo(r.a, key, r.id), id: r.id }
            }
        }
    }

    # `n * m` stays a length rather than wrapping or colliding with the `none`
    # sentinel
    len_fits : U32, U32 -> Bool
    len_fits = |n, m| m == 0 or n <= (Arena.none - 1) // m

    loop_register : Arena.A, U32, U32, U32 -> Arena.R
    loop_register = |a, body, lo, hi| {
        key = Arena.key_loop(body, lo, hi)
        match Arena.lookup(a, key) {
            Ok(id) => { a, id }
            Err(_) => {
                # A repetition of a FIXED-LENGTH body has a fixed length too:
                # `(\r\n){2}` is four symbols. Only a singleton body used to
                # count, so a doubled literal — which the rewrites fold into
                # exactly this shape — reported no length at all, and with it
                # lost `Accel`'s literal override: `\r\n\r\n`, `abab`, `xyxy`
                # and `(?:ab){2}` all ran the full reverse sweep where a 22 ns
                # SIMD scan would do. Capped so a large `{n,m}` cannot overflow.
                bmin = Arena.minl(a, body)
                bmax = Arena.maxl(a, body)
                minl = if bmin != Arena.none and Build.len_fits(lo, bmin) { lo * bmin } else { Arena.none }
                maxl = if bmax != Arena.none and hi != Arena.inf and Build.len_fits(hi, bmax) { hi * bmax } else { Arena.none }
                Arena.register(a, key, { flags: Build.infer_loop(a, body, lo), sub: Arena.sub(a, body), minl, maxl, pend: Arena.pend(a, body) })
            }
        }
    }

    loop_rules : Arena.A, U32, U32, U32 -> Arena.R
    loop_rules = |a, body, lo, hi|
        if lo == 0 and hi == 0 {
            { a, id: Arena.eps }
        } else if lo == 1 and hi == 1 {
            { a, id: body }
        } else if Arena.is_loop(a, body) and lo == 0 and Arena.loop_lo(a, body) == 0 and Arena.loop_hi(a, body) == Arena.inf {
            { a, id: body }
        } else if Arena.is_loop(a, body) and lo == 0 and hi == 1 and Arena.loop_lo(a, body) == 0 and Arena.loop_hi(a, body) == 1 {
            Build.mk_loop(a, Arena.head(a, body), lo, hi)
        } else if Arena.is_lookbehind(a, body) {
            { a, id: if lo == 0 { Arena.eps } else { body } }
        } else if Arena.is_concat(a, body) {
            ch = Arena.head(a, body)
            ct = Arena.tail(a, body)
            match Build.pred_star(a, ch) {
                Ok(pstar) => Build.loop_star_rule(a, body, lo, hi, TSet.subset(Arena.sub(a, ct), pstar))
                Err(_) =>
                    match Build.pred_star(a, ct) {
                        Ok(pstar) => Build.loop_star_rule(a, body, lo, hi, TSet.subset(Arena.sub(a, ch), pstar))
                        Err(_) => Build.loop_register(a, body, lo, hi)
                    }
            }
        } else {
            Build.loop_register(a, body, lo, hi)
        }

    # (.*a){5} -> (.*a){5,}   (a.*){5} -> (a.*){5,}
    loop_star_rule : Arena.A, U32, U32, U32, Bool -> Arena.R
    loop_star_rule = |a, body, lo, hi, subsumed|
        if lo > 0 and hi != Arena.inf {
            if subsumed { Build.mk_loop(a, body, lo, Arena.inf) } else { Build.loop_register(a, body, lo, hi) }
        } else if lo == 1 and hi == Arena.inf {
            if subsumed { { a, id: body } } else { Build.loop_register(a, body, lo, hi) }
        } else {
            Build.loop_register(a, body, lo, hi)
        }

    # --- mkLookaround --------------------------------------------------------------------

    mk_lookaround : Arena.A, U32, Bool, U32, U32 -> Arena.R
    mk_lookaround = |a, body, back, rel, pend| {
        key = Arena.key_look(back, body, rel, pend)
        match Arena.lookup(a, key) {
            Ok(id) => { a, id }
            Err(_) =>
                if back and body == Arena.eps {
                    { a, id: body }
                } else if back and body == Arena.top_star {
                    Build.look_create(a, Arena.top_star, back, rel, pend)
                } else if !back and Arena.is_always_null(a, body) {
                    # IMPORTANT: finish pending lookahead
                    Build.look_create(a, Arena.eps, back, rel, pend)
                } else if body == Arena.bot {
                    { a, id: Arena.bot }
                } else {
                    Build.look_create(a, body, back, rel, pend)
                }
        }
    }

    look_create : Arena.A, U32, Bool, U32, U32 -> Arena.R
    look_create = |a, body0, back, rel, pend| {
        nb = if back { { a, id: body0 } } else { Build.lookahead_normal_form(a, body0) }
        a1 = nb.a
        body = nb.id
        key = Arena.key_look(back, body, rel, pend)
        match Arena.lookup(a1, key) {
            Ok(id) => { a: a1, id }
            Err(_) => {
                flags = Build.infer_lookaround(a1, body, back)
                nulls =
                    if flags.bitwise_and(Arena.f_can_null) == 0 or pend == Arena.rs_empty {
                        { a: a1, id: Arena.rs_empty }
                    } else {
                        Arena.rs_add_all(a1, rel, pend)
                    }
                Arena.register(nulls.a, key, { flags, sub: Arena.full(a1), minl: 0, maxl: 0, pend: nulls.id })
            }
        }
    }

    # rewrite a lookahead body to normal form: it ends with `_*` unless anchored
    lookahead_normal_form : Arena.A, U32 -> Arena.R
    lookahead_normal_form = |a, body|
        if body == Arena.eps or body == Arena.top_star or Build.ends_with_true_star(a, body) {
            { a, id: body }
        } else if Arena.is_concat(a, body) and Arena.head(a, body) == Arena.top_star and Arena.is_anchor(a, Arena.tail(a, body)) and Arena.depends_anchor(a, body) {
            # not always correct but does not make a difference (RE#)
            { a, id: Arena.eps }
        } else if Arena.is_concat(a, body) and Arena.depends_anchor(a, body) {
            s = Build.split_tail(a, body)
            if Arena.depends_anchor(a, s.tail) { { a, id: body } } else { Build.mk_concat2(a, body, Arena.top_star) }
        } else {
            Build.mk_concat2(a, body, Arena.top_star)
        }

    # --- mkConcatChecked ---------------------------------------------------------------

    ## Concatenate with the lookaround-position checks and rewrites (tier 3).
    mk_concat_checked : Arena.A, List(U32) -> Arena.R
    mk_concat_checked = |a, nodes0| {
        nodes = List.fold(nodes0, [], |acc, n| List.concat(acc, Build.collect_concat(a, n)))
        len = List.len(nodes)
        if len == 0 {
            { a, id: Arena.eps }
        } else if len == 1 {
            n0 = List.get(nodes, 0) ?? Arena.eps
            if Arena.is_or(a, n0) and Arena.contains_look(a, n0) {
                { a: Arena.fail(a, "Lookarounds inside union not supported\nMove lookarounds/anchors outside union ^1$|^2$ -> ^(1|2)$"), id: Arena.bot }
            } else {
                { a, id: n0 }
            }
        } else {
            n_last = List.get(nodes, len - 1) ?? Arena.eps
            n_prev = List.get(nodes, len - 2) ?? Arena.eps
            n0 = List.get(nodes, 0) ?? Arena.eps
            n1 = List.get(nodes, 1) ?? Arena.eps
            if Arena.is_lookahead(a, n_prev) and Arena.is_lookahead(a, n_last) {
                # merge suffixes
                c1 = Build.mk_concat2(a, Arena.head(a, n_prev), Arena.top_star)
                c2 = Build.mk_concat2(c1.a, Arena.head(a, n_last), Arena.top_star)
                an = Build.mk_and_seq(c2.a, [c1.id, c2.id])
                merged = Build.mk_lookaround(an.a, an.id, False, 0, Arena.rs_empty)
                Build.mk_concat_checked(merged.a, List.append(List.take_first(nodes, len - 2), merged.id))
            } else if Arena.is_lookbehind(a, n0) and Arena.is_lookbehind(a, n1) {
                # merge prefixes
                c1 = Build.mk_concat2(a, Arena.top_star, Arena.head(a, n0))
                c2 = Build.mk_concat2(c1.a, Arena.top_star, Arena.head(a, n1))
                an = Build.mk_and_seq(c2.a, [c1.id, c2.id])
                merged = Build.mk_lookaround(an.a, an.id, True, 0, Arena.rs_empty)
                Build.mk_concat_checked(merged.a, List.prepend(List.drop_first(nodes, 2), merged.id))
            } else {
                match Build.first_rewrite_index(a, nodes, 0) {
                    Err(_) => Build.mk_concat_list(a, nodes)
                    Ok(i) => Build.rewrite_at(a, nodes, i)
                }
            }
        }
    }

    unsupported_look : Str
    unsupported_look = "this pattern contains unsupported anchors/lookarounds: lookarounds are only supported at the start or end of the pattern, e.g. (?<=R1)R2(?=R3). See docs/syntax.md#lookarounds"

    # the first position whose node needs a mid-pattern lookaround rewrite
    first_rewrite_index : Arena.A, List(U32), U64 -> Try(U64, [NoRewrite])
    first_rewrite_index = |a, nodes, i|
        match List.get(nodes, i) {
            Err(_) => Err(NoRewrite)
            Ok(curr) =>
                if Arena.is_lookbehind(a, curr) {
                    if i == 0 { Build.first_rewrite_index(a, nodes, i + 1) } else { Ok(i) }
                } else if Arena.is_lookahead(a, curr) {
                    if i + 1 == List.len(nodes) { Build.first_rewrite_index(a, nodes, i + 1) } else { Ok(i) }
                } else if Arena.contains_look(a, curr) {
                    Ok(i)
                } else {
                    Build.first_rewrite_index(a, nodes, i + 1)
                }
        }

    rewrite_at : Arena.A, List(U32), U64 -> Arena.R
    rewrite_at = |a, nodes, i| {
        curr = List.get(nodes, i) ?? Arena.eps
        left = List.take_first(nodes, i)
        right = List.drop_first(nodes, i + 1)
        if Arena.is_lookbehind(a, curr) {
            body = Arena.head(a, curr)
            # (nullability, not the min-length cache: a complement's length is unknown)
            left_nullable = List.all(left, |n| Arena.can_be_null(a, n))
            if Arena.maxl(a, body) == 1 and left_nullable {
                # Deviation from RE#, which prepends `_*` to the left context here
                # (`(_*X & _*R)Y`): when X can be empty the lookbehind may look at
                # text before the match, and the `_*` then makes the match swallow
                # that text — `a?\b\s` matched 0-9 on "a b  c,\n\nab". The correct
                # rewrite needs a lookbehind inside a union, which RE#'s normal form
                # excludes, so the pattern is rejected instead of matched wrongly.
                { a: Arena.fail(a, "a lookbehind (or \\b, ^) after an expression that can be empty is unsupported; anchor it or make the expression non-empty"), id: Arena.bot }
            } else if Arena.maxl(a, body) == 1 {
                ls = Build.mk_concat_list(a, left)
                look = Build.mk_concat2(ls.a, Arena.top_star, body)
                rem = Build.mk_concat_checked(look.a, right)
                an = Build.mk_and_seq(rem.a, [ls.id, look.id])
                Build.mk_concat2(an.a, an.id, rem.id)
            } else {
                { a: Arena.fail(a, Build.unsupported_look), id: Arena.bot }
            }
        } else if Arena.is_lookahead(a, curr) {
            body = Arena.head(a, curr)
            rem = Build.mk_concat_checked(a, right)
            s = Build.split_tail(rem.a, body)
            lm =
                if s.tail == Arena.top_star {
                    r = Build.mk_concat_list(rem.a, s.heads)
                    { a: r.a, len: Arena.maxl(r.a, r.id) }
                } else {
                    { a: rem.a, len: Arena.maxl(rem.a, body) }
                }
            if lm.len == Arena.none {
                { a: Arena.fail(lm.a, "unconstrained lookarounds are only supported as prefixes/suffixes"), id: Arena.bot }
            } else {
                match Build.rewrite_common_lookahead(lm.a, curr, rem.id) {
                    Ok(rw) => Build.mk_concat_checked(rw.a, List.append(left, rw.id))
                    Err(a2) => { a: Arena.fail(a2, Build.unsupported_look), id: Arena.bot }
                }
            }
        } else if Build.has_prefix_or_suffix(a, curr) {
            if Arena.is_or(a, curr) {
                # attempt combining every or branch
                arms = List.fold(Arena.children(a, curr), { a, ids: [] }, |acc, arm| {
                    r = Build.mk_concat_checked(acc.a, List.prepend(right, arm))
                    { a: r.a, ids: List.append(acc.ids, r.id) }
                })
                o = Build.mk_or_seq(arms.a, arms.ids)
                Build.mk_concat_list(o.a, List.append(left, o.id))
            } else if Arena.is_concat(a, curr) {
                # attempt adding more context to the lookaround
                Build.mk_concat_list(a, List.concat(List.concat(left, [Arena.head(a, curr), Arena.tail(a, curr)]), right))
            } else {
                { a: Arena.fail(a, Build.unsupported_look), id: Arena.bot }
            }
        } else {
            { a: Arena.fail(a, Build.unsupported_look), id: Arena.bot }
        }
    }

    ## `attemptRewriteCommonLookahead`: a lookahead followed by `remaining` as an intersection
    rewrite_common_lookahead : Arena.A, U32, U32 -> Try(Arena.R, Arena.A)
    rewrite_common_lookahead = |a, look, remaining| {
        body0 = Arena.head(a, look)
        s = Build.split_tail(a, body0)
        lb = if s.tail == Arena.top_star { Build.mk_concat_list(a, s.heads) } else { { a, id: body0 } }
        a1 = lb.a
        body = lb.id
        is_nwr = look == a1.anc.nwr
        and_with = |ax, x| {
            c = Build.mk_concat2(ax, x, Arena.top_star)
            Build.mk_and_seq(c.a, [c.id, remaining])
        }
        if is_nwr and Build.is_pred_star(a1, remaining) {
            # a\b.* -> a(?=(\W.*|\z))
            nw = Build.one(a1, a1.nonwordc)
            c = Build.mk_concat2(nw.a, nw.id, remaining)
            Ok(Build.mk_or2(c.a, c.id, Arena.end_anchor))
        } else if is_nwr and Arena.is_loop(a1, remaining) and Arena.loop_lo(a1, remaining) == 1 and Arena.loop_hi(a1, remaining) == Arena.inf and Arena.is_singleton(a1, Arena.head(a1, remaining)) {
            # \b.+
            Ok(and_with(a1, body))
        } else if is_nwr and Arena.is_concat(a1, remaining) {
            # \b\s+abc
            nw = Build.one(a1, a1.nonwordc)
            Ok(and_with(nw.a, nw.id))
        } else if is_nwr and Arena.is_loop(a1, remaining) and Arena.loop_lo(a1, remaining) == 0 and Arena.is_concat(a1, Arena.head(a1, remaining)) and Arena.is_singleton(a1, Arena.head(a1, Arena.head(a1, remaining))) {
            # \b(/[abc]*)
            nw = Build.one(a1, a1.nonwordc)
            case2 = and_with(nw.a, nw.id)
            Ok(Build.mk_or2(case2.a, look, case2.id))
        } else if Arena.is_singleton(a1, body) and (Arena.is_concat(a1, remaining) or Arena.is_singleton(a1, remaining)) {
            Ok(and_with(a1, body))
        } else if Arena.is_singleton(a1, body) and Arena.is_loop(a1, remaining) and Arena.loop_lo(a1, remaining) > 0 {
            Ok(and_with(a1, body))
        } else if Build.is_pred_star(a1, remaining) or Arena.is_and(a1, remaining) {
            Ok(and_with(a1, body))
        } else {
            Err(a1)
        }
    }

    # --- relocation after eviction (S4) ---------------------------------------------

    ## Re-create node `id` of arena `src` inside `a` (which is `src` truncated to
    ## `marks`): ids below the mark are shared; anything newer is rebuilt through
    ## the constructors, refsets included.
    copy_node : Arena.A, Arena.A, Arena.Marks, U32 -> Arena.R
    copy_node = |src, a, m, id|
        if id.to_u64() < m.nodes {
            { a, id }
        } else {
            k = Arena.kind(src, id)
            if k == Arena.k_singleton {
                Build.one(a, Arena.tset(src, id))
            } else if k == Arena.k_concat {
                h = Build.copy_node(src, a, m, Arena.head(src, id))
                t = Build.copy_node(src, h.a, m, Arena.tail(src, id))
                Build.mk_concat2(t.a, h.id, t.id)
            } else if k == Arena.k_loop {
                b = Build.copy_node(src, a, m, Arena.head(src, id))
                Build.mk_loop(b.a, b.id, Arena.loop_lo(src, id), Arena.loop_hi(src, id))
            } else if k == Arena.k_or or k == Arena.k_and {
                cs = List.fold(Arena.children(src, id), { a, ids: [] }, |acc, c| {
                    r = Build.copy_node(src, acc.a, m, c)
                    { a: r.a, ids: List.append(acc.ids, r.id) }
                })
                if k == Arena.k_or { Build.mk_or_seq(cs.a, cs.ids) } else { Build.mk_and_seq(cs.a, cs.ids) }
            } else if k == Arena.k_not {
                b = Build.copy_node(src, a, m, Arena.head(src, id))
                Build.mk_not(b.a, b.id)
            } else if k == Arena.k_lookahead or k == Arena.k_lookbehind {
                b = Build.copy_node(src, a, m, Arena.head(src, id))
                pend = Arena.look_pend(src, id)
                rs = if pend.to_u64() < m.rs { { a: b.a, id: pend } } else { Arena.rs_intern(b.a, Arena.rs_get(src, pend)) }
                Build.mk_lookaround(rs.a, b.id, k == Arena.k_lookbehind, Arena.look_rel(src, id), rs.id)
            } else {
                { a, id }
            }
        }

    # --- anchors and negative lookarounds (RegexBuilder anchors, RegexNodeConverter) --

    ## Create RE#'s well-known anchor nodes. `wordc`/`nonwordc` are the `\w`/`\W`
    ## tsets (0 when the pattern has no `\b`), `nl` the `\n` tset (0 when no `^`/`$`).
    init_anchors : Arena.A, U64, U64, U64 -> Arena.A
    init_anchors = |a0, wordc, nonwordc, nl| {
        a = { ..a0, wordc, nonwordc }
        mk_side = |ax, anchor, t, back| {
            o = Build.one(ax, t)
            b = Build.mk_or2(o.a, anchor, o.id)
            Build.mk_lookaround(b.a, b.id, back, 0, Arena.rs_empty)
        }
        r1 = mk_side(a, Arena.begin_anchor, nonwordc, True)
        r2 = mk_side(r1.a, Arena.begin_anchor, wordc, True)
        r3 = mk_side(r2.a, Arena.end_anchor, nonwordc, False)
        r4 = mk_side(r3.a, Arena.end_anchor, wordc, False)
        # ^ ≡ (?<=\A|\n)   $ ≡ (?=\z|\n)
        r5 = mk_side(r4.a, Arena.begin_anchor, nl, True)
        r6 = mk_side(r5.a, Arena.end_anchor, nl, False)
        { ..r6.a, anc: { caret: r5.id, dollar: r6.id, nwl: r1.id, wl: r2.id, nwr: r3.id, wr: r4.id, a_anchor: Arena.none, end_z: Arena.none } }
    }

    ## `(?!R)` / `(?<!R)` as positive lookarounds over complements
    rewrite_negative_lookaround : Arena.A, Bool, U32 -> Arena.R
    rewrite_negative_lookaround = |a, back, node|
        if Arena.is_singleton(a, node) {
            flipped = Build.one(a, TSet.compl(Arena.tset(a, node), a.nmt))
            if back {
                # (?<!\w) = (?<=\A|\W)
                o = Build.mk_or2(flipped.a, Arena.begin_anchor, flipped.id)
                Build.mk_lookaround(o.a, o.id, True, 0, Arena.rs_empty)
            } else {
                # (?!\w) = (?=\z|\W)
                o = Build.mk_or2(flipped.a, flipped.id, Arena.end_anchor)
                Build.mk_lookaround(o.a, o.id, False, 0, Arena.rs_empty)
            }
        } else if back {
            # (?<=\A·~(_*R)) ≡ (?<!R)
            c = Build.mk_concat2(a, Arena.top_star, node)
            n = Build.mk_not(c.a, c.id)
            c2 = Build.mk_concat2(n.a, Arena.begin_anchor, n.id)
            Build.mk_lookaround(c2.a, c2.id, True, 0, Arena.rs_empty)
        } else {
            # (?=~(R·_*)·\z) ≡ (?!R)
            c = Build.mk_concat2(a, node, Arena.top_star)
            n = Build.mk_not(c.a, c.id)
            c2 = Build.mk_concat2(n.a, n.id, Arena.end_anchor)
            Build.mk_lookaround(c2.a, c2.id, False, 0, Arena.rs_empty)
        }
}
