## Node construction with RE#'s rewrites: `RegexBuilder.fs` ported rule for
## rule. ACI normalization and identities make the derivative space finite;
## subsumption (RE#'s `MinimizePattern`) keeps it small; the lookaround normal
## form (`mkConcatChecked`) is what lets lookarounds live in DFA states. RE#'s
## `sub 0N` / `merge loops N` tags are kept in the comments. Every constructor
## threads the arena and returns `{ a, id }`.
##
## RE# throws `UnsupportedPatternException`; here the arena records the message
## (`Arena.fail`) and the constructor returns `bot`, and `compile` reports it.
import Arena
import TSet

Build := [].{
    R : Arena.R

    # --- the intern-or-build idiom ----------------------------------------------

    ## Look `key` up in the intern index and build the node only on a miss.
    ##
    ## Every constructor below opens this way: RE#'s `_nodeCache` is consulted
    ## first, and the rewrite rules run only when the key is new. `build` takes
    ## the arena back because a miss usually allocates (children, refsets).
    interned : Arena.A, List(U32), (Arena.A -> Arena.R) -> Arena.R
    interned = |a, key, build|
        match Arena.lookup(a, key) {
            Ok(id) => { a, id }
            Err(_) => build(a)
        }

    ## Map `key` to the node the rewrites returned (RE#'s `_nodeCache.Add`), so
    ## the unnormalized key reaches the normalized node next time.
    ##
    ## Deliberately separate from `interned`: only the sites RE# memoises call
    ## it. Which keys end up mapped is what the derivative space — and so the
    ## DFA — is built out of, so never add one to a site that has none, and
    ## never drop one.
    memoed : List(U32), Arena.R -> Arena.R
    memoed = |key, r| { a: Arena.memo(r.a, key, r.id), id: r.id }

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
            or_flags = acc.bitwise_or(f).bitwise_and(Arena.f_look.bitwise_or(Arena.f_anchor))
            and_flags = acc.bitwise_and(f).bitwise_and(Build.nullf)
            or_flags.bitwise_or(and_flags)
        })

    infer_concat : Arena.A, U32, U32 -> U8
    infer_concat = |a, h, t| {
        head_flags = Arena.flags(a, h)
        tail_flags = Arena.flags(a, t)
        or_flags = head_flags.bitwise_or(tail_flags).bitwise_and(Arena.f_look)
        and_flags = head_flags.bitwise_and(tail_flags).bitwise_and(Build.nullf)
        dep = if Arena.depends_anchor(a, h) or (Arena.can_be_null(a, h) and Arena.depends_anchor(a, t)) { Arena.f_anchor } else { 0 }
        suf = if Arena.has_suffix_la(a, t) or Arena.is_lookahead(a, t) { Arena.f_suffix_la } else { 0 }
        pref = if Arena.has_prefix_lb(a, h) or Arena.is_lookbehind(a, h) { Arena.f_prefix_lb } else { 0 }
        and_flags.bitwise_or(or_flags).bitwise_or(dep).bitwise_or(suf).bitwise_or(pref)
    }

    infer_loop : Arena.A, U32, U32 -> U8
    infer_loop = |a, body, lo|
        (Arena.flags(a, body)).bitwise_or(if lo == 0 { Build.nullf } else { 0 })

    infer_lookaround : Arena.A, U32, Bool -> U8
    infer_lookaround = |a, body, back| {
        f = Arena.flags(a, body)
        null_flag = f.bitwise_and(Build.nullf)
        anchor_flag = f.bitwise_and(Arena.f_anchor)
        side = if back { Arena.f_prefix_lb } else { Arena.f_suffix_la }
        null_flag.bitwise_or(Arena.f_look).bitwise_or(side).bitwise_or(anchor_flag)
    }

    infer_compl : Arena.A, U32 -> U8
    infer_compl = |a, inner| {
        f = Arena.flags(a, inner)
        null_flag =
            if !Arena.can_be_null(a, inner) { Build.nullf }
            else if Arena.is_always_null(a, inner) { 0 }
            else { Arena.f_can_null }
        null_flag.bitwise_or(f.bitwise_and(Arena.f_look.bitwise_or(Arena.f_anchor)))
    }

    add_len : U32, U32 -> U32
    add_len = |x, y| if x == Arena.none or y == Arena.none { Arena.none } else { x + y }

    # min over children; none if any child none
    min_len_or : Arena.A, List(U32) -> U32
    min_len_or = |a, ids|
        List.fold(ids, 0xFFFF_FFFE, |acc, id| {
            v = Arena.minl(a, id)
            if acc == Arena.none or v == Arena.none { Arena.none } else { Arena.min_u32(acc, v) }
        })

    max_len_or : Arena.A, List(U32) -> U32
    max_len_or = |a, ids|
        List.fold(ids, 0, |acc, id| {
            v = Arena.maxl(a, id)
            if acc == Arena.none or v == Arena.none { Arena.none } else { Arena.max_u32(acc, v) }
        })

    min_len_and : Arena.A, List(U32) -> U32
    min_len_and = |a, ids|
        List.fold(ids, 0, |acc, id| {
            v = Arena.minl(a, id)
            if acc == Arena.none or v == Arena.none { Arena.none } else { Arena.max_u32(acc, v) }
        })

    max_len_and : Arena.A, List(U32) -> U32
    max_len_and = |a, ids|
        List.fold(ids, 0xFFFF_FFFE, |acc, id| {
            v = Arena.maxl(a, id)
            if acc == Arena.none or v == Arena.none { Arena.none } else { Arena.min_u32(acc, v) }
        })

    sub_of : Arena.A, List(U32) -> U64
    sub_of = |a, ids| List.fold(ids, 0, |acc, id| acc.bitwise_or(Arena.sub(a, id)))

    pend_of : Arena.A, List(U32) -> Arena.R
    pend_of = |a, ids| Arena.rs_union_many(a, List.map(ids, |id| Arena.pend(a, id)))

    # --- one -----------------------------------------------------------------------

    one : Arena.A, U64 -> Arena.R
    one = |a, t| {
        key = Arena.key_singleton(t)
        Build.interned(a, key, |a1|
            Arena.register(a1, key, { flags: 0, sub: t, minl: 1, maxl: 1, pend: Arena.rs_empty }))
    }

    # --- mkOr2 -----------------------------------------------------------------------

    mk_or2 : Arena.A, U32, U32 -> Arena.R
    mk_or2 = |a, left, right|
        if left == right {
            { a, id: left }
        } else if Arena.is_not(a, left) and Arena.head(a, left) == right {
            { a, id: Arena.top_star }
        } else if Arena.is_not(a, right) and Arena.head(a, right) == left {
            { a, id: Arena.top_star }
        } else if left == Arena.bot {
            { a, id: right }
        } else if right == Arena.bot {
            { a, id: left }
        } else if left == Arena.top_star or right == Arena.top_star {
            { a, id: Arena.top_star }
        } else {
            key = Arena.key_or(Arena.sort_ids([left, right]))
            Build.interned(a, key, |a1| Build.or2_rules(a1, left, right, key))
        }

    or2_rules : Arena.A, U32, U32, List(U32) -> Arena.R
    or2_rules = |a, left, right, key|
        if Arena.is_singleton(a, left) and Arena.is_singleton(a, right) {
            Build.one(a, (Arena.tset(a, left)).bitwise_or(Arena.tset(a, right)))
        } else if (left == Arena.eps and Arena.contains_look(a, right)) or (right == Arena.eps and Arena.contains_look(a, left)) {
            # Deviation from RE#: `ε | X` is not folded when X carries a lookaround.
            # A lookaround node's nullability is transient (its body keeps being
            # derived to verify the text ahead), so `X? -> X` / `-> ε` folds that are
            # sound for ordinary regexes drop a running check: folding
            # `LB·rest | rest` to `rest` loses the leftmost start of
            # `.[^a]{1,2}[ab]*(?!R)`.
            Build.or_register(a, Arena.sort_ids([left, right]))
        } else if left == Arena.eps {
            Build.mk_loop(a, right, 0, 1)
        } else if right == Arena.eps {
            Build.mk_loop(a, left, 0, 1)
        } else if Arena.is_loop(a, left) and Arena.is_loop(a, right) and Arena.head(a, left) == Arena.head(a, right) {
            # a{0,5}|a{4,7} -> a{0,7}
            lo = Arena.min_u32(Arena.loop_lo(a, left), Arena.loop_lo(a, right))
            hi = Arena.max_u32(Arena.loop_hi(a, left), Arena.loop_hi(a, right))
            Build.mk_loop(a, Arena.head(a, left), lo, hi)
        } else if Arena.is_loop(a, left) and Arena.head(a, left) == right {
            # (ab)|(ab){2} -> (ab){1,2}
            Build.or2_loop_body(a, left, key)
        } else if Arena.is_loop(a, right) and Arena.head(a, right) == left {
            Build.or2_loop_body(a, right, key)
        } else if Arena.is_or(a, left) {
            if List.contains(Arena.children(a, left), right) { { a, id: left } } else { Build.mk_or(a, Arena.sort_ids(List.append(Arena.children(a, left), right))) }
        } else if Arena.is_or(a, right) {
            if List.contains(Arena.children(a, right), left) { { a, id: right } } else { Build.mk_or(a, Arena.sort_ids(List.append(Arena.children(a, right), left))) }
        } else {
            match (Build.pred_star(a, left), Build.pred_star(a, right)) {
                (Ok(left_pred), Ok(right_pred)) =>
                    if TSet.subset(right_pred, left_pred) { { a, id: left } } else if TSet.subset(left_pred, right_pred) { { a, id: right } } else { Build.or_create_cached(a, key) }
                _ => Build.or2_rules_fallback(a, left, right, key)
            }
        }

    or2_loop_body : Arena.A, U32, List(U32) -> Arena.R
    or2_loop_body = |a, loop_id, key| {
        lo = Arena.loop_lo(a, loop_id)
        hi = Arena.loop_hi(a, loop_id)
        if lo == 2 {
            Build.mk_loop(a, Arena.head(a, loop_id), 1, hi)
        } else if lo == 0 and hi == 1 {
            { a, id: loop_id }
        } else {
            Build.or_create_cached(a, key)
        }
    }

    or2_rules_fallback : Arena.A, U32, U32, List(U32) -> Arena.R
    or2_rules_fallback = |a, left, right, key|
        if Arena.is_concat(a, left) and Arena.is_concat(a, right) and Arena.head(a, left) == Arena.head(a, right) {
            # merge head
            merged_tail = Build.mk_or2(a, Arena.tail(a, left), Arena.tail(a, right))
            merged_concat = Build.mk_concat2(merged_tail.a, Arena.head(a, left), merged_tail.id)
            Build.memoed(key, merged_concat)
        } else if Arena.is_anchor(a, left) and (Arena.is_lookahead(a, right) or Arena.is_lookbehind(a, right)) {
            Build.or2_anchor_into_look(a, left, right)
        } else if Arena.is_anchor(a, right) and (Arena.is_lookahead(a, left) or Arena.is_lookbehind(a, left)) {
            Build.or2_anchor_into_look(a, right, left)
        } else if Arena.is_loop(a, left) and Arena.is_singleton(a, Arena.head(a, left)) {
            Build.or2_loop_subsume(a, left, right, key)
        } else if Arena.is_loop(a, right) and Arena.is_singleton(a, Arena.head(a, right)) {
            Build.or2_loop_subsume(a, right, left, key)
        } else {
            Build.or_create_cached_subsume(a, left, right, key)
        }

    # put anchor inside lookaround body
    or2_anchor_into_look : Arena.A, U32, U32 -> Arena.R
    or2_anchor_into_look = |a, anchor, look| {
        r = Build.mk_or2(a, anchor, Arena.head(a, look))
        Build.mk_lookaround(r.a, r.id, Arena.is_lookbehind(a, look), Arena.look_rel(a, look), Arena.look_pend(a, look))
    }

    # sub 013: a loop over a singleton subsumes a node contained in its predicate and length range
    or2_loop_subsume : Arena.A, U32, U32, List(U32) -> Arena.R
    or2_loop_subsume = |a, loop_id, other, key| {
        lpred = Arena.tset(a, Arena.head(a, loop_id))
        if TSet.subset(Arena.sub(a, other), lpred) {
            omin = Arena.minl(a, other)
            omax = Arena.maxl(a, other)
            if omin != Arena.none and omax != Arena.none and Arena.loop_lo(a, loop_id) <= omin and Arena.loop_hi(a, loop_id) >= omax {
                Build.memoed(key, { a, id: loop_id })
            } else {
                Build.or_create_cached_subsume(a, loop_id, other, key)
            }
        } else {
            Build.or_create_cached_subsume(a, loop_id, other, key)
        }
    }

    # an Or of `key`'s two members, without subsumption
    or_create_cached : Arena.A, List(U32) -> Arena.R
    or_create_cached = |a, key| {
        ids = List.drop_first(key, 2)
        Build.interned(a, key, |a1| Build.or_register(a1, ids))
    }

    or_register : Arena.A, List(U32) -> Arena.R
    or_register = |a, ids| {
        p = Build.pend_of(a, ids)
        info = {
            flags: Build.infer_or(a, ids),
            sub: Build.sub_of(a, ids),
            minl: Build.min_len_or(a, ids),
            maxl: Build.max_len_or(a, ids),
            pend: p.id,
        }
        r = Arena.register(p.a, Arena.key_or(ids), info)
        { a: { ..r.a, or_count: r.a.or_count + 1 }, id: r.id }
    }

    or_create_cached_subsume : Arena.A, U32, U32, List(U32) -> Arena.R
    or_create_cached_subsume = |a, left, right, key| {
        left_split = Build.split_tail(a, left)
        right_split = Build.split_tail(a, right)
        if left_split.tail == right_split.tail {
            left_prefix = Build.mk_concat_list(a, left_split.heads)
            right_prefix = Build.mk_concat_list(left_prefix.a, right_split.heads)
            merged_head = Build.mk_or2(right_prefix.a, left_prefix.id, right_prefix.id)
            Build.mk_concat2(merged_head.a, merged_head.id, left_split.tail)
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
        Build.interned(a, key, |a1| {
            scan = Build.or_scan(a1, nodes, { derivs: [], stars: [], true_star: False, eps: False, zeroloops: 0 })
            if scan.true_star {
                Build.memoed(key, { a: a1, id: Arena.top_star })
            } else {
                # star loops subsume derivatives contained in their predicate
                after_star_subsume = List.fold(scan.stars, scan.derivs, |derivs, star|
                    match Build.pred_star(a1, star) {
                        Ok(p) => List.drop_if(derivs, |d| d != star and TSet.subset(Arena.sub(a1, d), p))
                        Err(_) => derivs
                    })
                # add epsilon only if no nullables yet (a lookaround's nullability is
                # transient and does not absorb ε — see `mk_or2`)
                with_eps = if scan.eps and !List.any(after_star_subsume, |d| Arena.is_always_null(a1, d) and !Arena.contains_look(a1, d)) { List.append(after_star_subsume, Arena.eps) } else { after_star_subsume }
                # merge singletons
                m = Build.merge_singletons(a1, with_eps)
                after_loop_dedup = if scan.zeroloops > 0 { Build.merge_or_grouped_loops(m.a, m.derivs) } else { m.derivs }
                after_lookahead_merge = Build.merge_or_lookaheads(m.a, after_loop_dedup)
                after_loop_range_merge =
                    if after_lookahead_merge.a.or_count < 2000 {
                        after_intersect_merge = Build.merge_or_intersections(after_lookahead_merge.a, after_lookahead_merge.derivs)
                        after_head_merge = Build.merge_or_grouped_heads(after_lookahead_merge.a, after_intersect_merge)
                        after_tail_merge = Build.merge_or_grouped_tails(after_head_merge.a, after_head_merge.derivs)
                        Build.merge_or_non_zero_loops(after_tail_merge.a, after_tail_merge.derivs)
                    } else {
                        after_lookahead_merge
                    }
                fin = Build.or_finish(after_loop_range_merge.a, after_loop_range_merge.derivs)
                Build.memoed(key, fin)
            }
        })
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
    merge_singletons = |a, derivs| {
        singles = List.keep_if(derivs, |d| Arena.is_singleton(a, d))
        if List.is_empty(singles) {
            { a, derivs }
        } else {
            rest = List.drop_if(derivs, |d| Arena.is_singleton(a, d))
            merged_tset = List.fold(singles, 0, |acc, d| acc.bitwise_or(Arena.tset(a, d)))
            r = Build.one(a, merged_tset)
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
                Build.interned(a, Arena.key_or(ids), |a1| Build.or_register(a1, ids))
            }
        }

    # C{0,9}D | C{0,8}D = C{0,9}D — remove loop duplicates
    merge_or_grouped_loops : Arena.A, List(U32) -> List(U32)
    merge_or_grouped_loops = |a, derivs| {
        entries = List.fold(derivs, [], |acc, d|
            match Build.loop_group_key(a, d) {
                Ok(k) => List.append(acc, { d, body: k.body, tail: k.tail, lo: k.lo, hi: k.hi })
                Err(_) => acc
            })
        # per (body, tail): the widest range
        List.drop_if(derivs, |d|
            match List.find_first(entries, |e| e.d == d) {
                Err(_) => False
                Ok(e) => {
                    same = List.keep_if(entries, |x| x.body == e.body and x.tail == e.tail)
                    maxv = List.fold(same, 0, |m, x| Arena.max_u32(m, x.hi))
                    minv = List.fold(same, Arena.inf, |m, x| Arena.min_u32(m, x.lo))
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
    merge_or_lookaheads = |a, derivs| {
        lookaheads = List.keep_if(derivs, |d| Arena.is_lookahead(a, d))
        if List.len(lookaheads) < 2 {
            { a, derivs }
        } else {
            min_rel = List.fold(lookaheads, Arena.inf, |m, d| Arena.min_u32(m, Arena.look_rel(a, d)))
            others = List.drop_if(derivs, |d| Arena.is_lookahead(a, d))
            bodies = Arena.sort_dedup(List.map(lookaheads, |d| Arena.head(a, d)))
            List.fold(bodies, { a, derivs: others }, |acc, body| {
                group = List.keep_if(lookaheads, |d| Arena.head(a, d) == body)
                if List.len(group) == 1 {
                    { a: acc.a, derivs: List.append(acc.derivs, List.get(group, 0) ?? Arena.bot) }
                } else {
                    # an empty pending set means "one candidate end, `rel` back":
                    # RE# unions the sets as-is and loses that candidate; read it
                    # as {(0,0)}.
                    pends = List.map(group, |d|
                        (Arena.look_rel(a, d), if Arena.look_pend(a, d) == Arena.rs_empty { Arena.rs_zero } else { Arena.look_pend(a, d) }))
                    nulls = Arena.rs_rel_union_min(acc.a, min_rel, pends)
                    m = Build.mk_lookaround(nulls.a, body, False, min_rel, nulls.id)
                    { a: m.a, derivs: List.append(acc.derivs, m.id) }
                }
            })
        }
    }

    # And-derivatives whose conjunct set contains another's are dropped
    merge_or_intersections : Arena.A, List(U32) -> List(U32)
    merge_or_intersections = |a, derivs| {
        ands = List.keep_if(derivs, |d| Arena.is_and(a, d))
        List.drop_if(derivs, |d|
            Arena.is_and(a, d) and List.any(ands, |prev| prev != d and List.all(Arena.children(a, prev), |x| List.contains(Arena.children(a, d), x))))
    }

    # a·X | a·Y -> a·(X|Y)
    merge_or_grouped_heads : Arena.A, List(U32) -> Build.Derivs
    merge_or_grouped_heads = |a, derivs| {
        keyed = List.fold(derivs, [], |acc, d|
            if Arena.is_concat(a, d) { List.append(acc, { d, h: Arena.head(a, d), t: Arena.tail(a, d) }) }
            else if Arena.is_singleton(a, d) { List.append(acc, { d, h: d, t: Arena.eps }) }
            else { acc })
        others = List.drop_if(derivs, |d| Arena.is_concat(a, d) or Arena.is_singleton(a, d))
        heads = Arena.sort_dedup(List.map(keyed, |e| e.h))
        List.fold(heads, { a, derivs: others }, |acc, h| {
            group = List.keep_if(keyed, |e| e.h == h)
            if List.len(group) == 1 {
                { a: acc.a, derivs: List.append(acc.derivs, (List.get(group, 0) ?? { d: Arena.bot, h: 0, t: 0 }).d) }
            } else {
                o = Build.mk_or(acc.a, Arena.sort_dedup(List.map(group, |e| e.t)))
                c = Build.mk_concat2(o.a, h, o.id)
                { a: c.a, derivs: List.append(acc.derivs, c.id) }
            }
        })
    }

    # X·t | Y·t -> (X|Y)·t
    merge_or_grouped_tails : Arena.A, List(U32) -> Build.Derivs
    merge_or_grouped_tails = |a, derivs| {
        keyed = List.map(derivs, |d| {
            s = Build.split_tail(a, d)
            { d, heads: s.heads, t: s.tail }
        })
        tails = Arena.sort_dedup(List.map(keyed, |e| e.t))
        List.fold(tails, { a, derivs: [] }, |acc, t| {
            group = List.keep_if(keyed, |e| e.t == t)
            if List.len(group) == 1 {
                { a: acc.a, derivs: List.append(acc.derivs, (List.get(group, 0) ?? { d: Arena.bot, heads: [], t: 0 }).d) }
            } else {
                heads_acc = List.fold(group, { a: acc.a, ids: [] }, |st, e| {
                    r = Build.mk_concat_list(st.a, e.heads)
                    { a: r.a, ids: List.append(st.ids, r.id) }
                })
                o = Build.mk_or(heads_acc.a, Arena.sort_dedup(heads_acc.ids))
                c = Build.mk_concat2(o.a, o.id, t)
                { a: c.a, derivs: List.append(acc.derivs, c.id) }
            }
        })
    }

    # a{1,3}·t | a{2,5}·t -> a{1,5}·t: union the loop ranges per (body, tail)
    merge_or_non_zero_loops : Arena.A, List(U32) -> Build.Derivs
    merge_or_non_zero_loops = |a, derivs| {
        keyed = List.fold(derivs, [], |acc, d|
            match Build.nz_key(a, d) {
                Ok(k) => List.append(acc, k)
                Err(_) => acc
            })
        others = List.drop_if(derivs, |d| Build.nz_key(a, d) != Err(No))
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
        sorted = List.sort_with(rs, |(left_start, _), (right_start, _)| U32.order_relative_to(left_start, right_start))
        List.fold(sorted, [], |acc, (s, e)|
            match List.last(acc) {
                Ok((cur_start, cur_end)) if cur_end == Arena.inf or cur_end + 1 >= s => List.append(List.drop_last(acc, 1), (cur_start, Arena.max_u32(cur_end, e)))
                _ => List.append(acc, (s, e))
            })
    }

    # --- mkAnd2 / mkAnd ----------------------------------------------------------------

    mk_and2 : Arena.A, U32, U32 -> Arena.R
    mk_and2 = |a, left, right|
        if left == right {
            { a, id: left }
        } else if Arena.is_not(a, left) and Arena.head(a, left) == right {
            { a, id: Arena.bot }
        } else if Arena.is_not(a, right) and Arena.head(a, right) == left {
            { a, id: Arena.bot }
        } else if left == Arena.bot or right == Arena.bot {
            { a, id: Arena.bot }
        } else if left == Arena.top_star {
            { a, id: right }
        } else if right == Arena.top_star {
            { a, id: left }
        } else if left == Arena.eps or right == Arena.eps {
            # Deviation from RE#, which folds `ε & X` to ε whenever X CAN be nullable:
            # an anchor-dependent X (`_*(\A|\n)`, i.e. `^` rewritten) is nullable
            # only at some positions, and the fold makes `b^ ?|.` match "b " on "b a".
            # Only an always-nullable X folds; otherwise the intersection stays and
            # the location decides.
            x = if left == Arena.eps { right } else { left }
            if Arena.is_always_null(a, x) {
                { a, id: Arena.eps }
            } else if !Arena.can_be_null(a, x) {
                { a, id: Arena.bot }
            } else {
                key = Arena.key_and(Arena.sort_ids([left, right]))
                Build.interned(a, key, |a1| Build.and_create_cached(a1, List.drop_first(key, 2)))
            }
        } else {
            key = Arena.key_and(Arena.sort_ids([left, right]))
            Build.interned(a, key, |a1| Build.and2_rules(a1, left, right, key))
        }

    and2_rules : Arena.A, U32, U32, List(U32) -> Arena.R
    and2_rules = |a, left, right, key|
        if Arena.is_singleton(a, left) and Arena.is_singleton(a, right) {
            Build.one(a, (Arena.tset(a, left)).bitwise_and(Arena.tset(a, right)))
        } else if Arena.is_and(a, left) {
            if List.contains(Arena.children(a, left), right) { { a, id: left } } else { Build.mk_and(a, Arena.sort_ids(List.append(Arena.children(a, left), right))) }
        } else if Arena.is_and(a, right) {
            if List.contains(Arena.children(a, right), left) { { a, id: right } } else { Build.mk_and(a, Arena.sort_ids(List.append(Arena.children(a, right), left))) }
        } else {
            match (Build.pred_loop(a, left), Build.pred_loop(a, right)) {
                (Ok(left_loop), Ok(right_loop)) => {
                    left_pred_larger = TSet.subset(right_loop.t, left_loop.t)
                    right_pred_larger = TSet.subset(left_loop.t, right_loop.t)
                    left_range_larger = left_loop.lo <= right_loop.lo and left_loop.hi >= right_loop.hi
                    right_range_larger = right_loop.lo <= left_loop.lo and right_loop.hi >= left_loop.hi
                    if (left_pred_larger or right_pred_larger) and (left_range_larger or right_range_larger) {
                        smaller_pred = if left_pred_larger { right_loop.t } else { left_loop.t }
                        smaller_loop = if left_range_larger { right_loop } else { left_loop }
                        o = Build.one(a, smaller_pred)
                        r = Build.mk_loop(o.a, o.id, smaller_loop.lo, smaller_loop.hi)
                        Build.memoed(key, r)
                    } else {
                        Build.and_create_cached(a, List.drop_first(key, 2))
                    }
                }
                _ =>
                    match (Build.pred_star(a, left), Build.pred_star(a, right)) {
                        (Ok(p), _) => if TSet.subset(Arena.sub(a, right), p) { { a, id: right } } else { Build.and_create_cached(a, List.drop_first(key, 2)) }
                        (_, Ok(p)) => if TSet.subset(Arena.sub(a, left), p) { { a, id: left } } else { Build.and_create_cached(a, List.drop_first(key, 2)) }
                        _ => Build.and_create_cached(a, List.drop_first(key, 2))
                    }
            }
        }

    and_create_cached : Arena.A, List(U32) -> Arena.R
    and_create_cached = |a, raw_ids| {
        ids = Arena.sort_dedup(raw_ids)
        if List.is_empty(ids) {
            { a, id: Arena.top_star }
        } else if List.len(ids) == 1 {
            { a, id: List.get(ids, 0) ?? Arena.bot }
        } else {
            key = Arena.key_and(ids)
            Build.interned(a, key, |a1|
                if List.any(ids, |id| Build.has_prefix_or_suffix(a1, id)) {
                    Build.memoed(key, Build.merge_and_prefix_suffix(a1, ids))
                } else {
                    p = Build.pend_of(a1, ids)
                    info = {
                        flags: Build.infer_and(a1, ids),
                        sub: Build.sub_of(a1, ids),
                        minl: Build.min_len_and(a1, ids),
                        maxl: Build.max_len_and(a1, ids),
                        pend: p.id,
                    }
                    Arena.register(p.a, key, info)
                })
        }
    }

    mk_and_seq : Arena.A, List(U32) -> Arena.R
    mk_and_seq = |a, ids| Build.mk_and(a, Arena.sort_dedup(ids))

    mk_and : Arena.A, List(U32) -> Arena.R
    mk_and = |a, nodes| {
        key = Arena.key_and(nodes)
        Build.interned(a, key, |a1|
            if List.len(nodes) == 2 {
                Build.mk_and2(a1, List.get(nodes, 0) ?? Arena.bot, List.get(nodes, 1) ?? Arena.bot)
            } else {
                scan = Build.and_scan(a1, nodes, { derivs: [], stars: [], compls: [], is_false: False, eps: False })
                if scan.is_false {
                    Build.memoed(key, { a: a1, id: Arena.bot })
                } else {
                    # add all complements together
                    after_compl_merge =
                        if List.is_empty(scan.compls) {
                            { a: a1, derivs: scan.derivs }
                        } else {
                            o = Build.mk_or_seq(a1, scan.compls)
                            n = Build.mk_not(o.a, o.id)
                            { a: n.a, derivs: Arena.sort_dedup(List.append(scan.derivs, n.id)) }
                        }
                    # a star loop is dropped when some other conjunct is contained in it
                    after_star_subsume = List.fold(scan.stars, after_compl_merge.derivs, |derivs, star|
                        match Build.pred_star(a1, star) {
                            Ok(p) => if List.any(derivs, |d| d != star and TSet.subset(Arena.sub(a1, d), p)) { derivs } else { Arena.sort_dedup(List.append(derivs, star)) }
                            Err(_) => derivs
                        })
                    if scan.eps and List.any(after_star_subsume, |d| !Arena.can_be_null(after_compl_merge.a, d)) {
                        Build.memoed(key, { a: after_compl_merge.a, id: Arena.bot })
                    } else {
                        with_eps = if scan.eps { Arena.sort_dedup(List.append(after_star_subsume, Arena.eps)) } else { after_star_subsume }
                        if !List.is_empty(with_eps) and List.all(with_eps, |d| Arena.is_singleton(after_compl_merge.a, d)) {
                            # RE# unions these; an intersection of singletons is their intersection
                            r = Build.one(after_compl_merge.a, List.fold(with_eps, Arena.full(after_compl_merge.a), |acc, d| acc.bitwise_and(Arena.tset(after_compl_merge.a, d))))
                            Build.memoed(key, r)
                        } else {
                            after_head_group = Build.and_group_heads(after_compl_merge.a, with_eps)
                            after_tail_group = Build.and_group_tails(after_head_group.a, after_head_group.derivs)
                            Build.memoed(key, Build.and_create_cached(after_tail_group.a, after_tail_group.derivs))
                        }
                    }
                }
            })
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
    and_group_heads = |a, derivs| {
        group_of = |d|
            if Arena.is_concat(a, d) and Arena.tail(a, d) != Arena.eps {
                match Arena.fixed_len(a, Arena.head(a, d)) {
                    Ok(0) => Err(No)
                    Ok(n) => Ok(n)
                    Err(_) => Err(No)
                }
            } else {
                Err(No)
            }
        lens = List.fold(derivs, [], |acc, d| match group_of(d) { Ok(n) => if List.contains(acc, n) { acc } else { List.append(acc, n) }, Err(_) => acc })
        ungrouped = List.keep_if(derivs, |d| group_of(d) == Err(No))
        List.fold(lens, { a, derivs: ungrouped }, |acc, n| {
            group = List.keep_if(derivs, |d| group_of(d) == Ok(n))
            if List.len(group) == 1 {
                { a: acc.a, derivs: List.append(acc.derivs, List.get(group, 0) ?? Arena.bot) }
            } else {
                h = Build.mk_and_seq(acc.a, List.map(group, |d| Arena.head(a, d)))
                t = Build.mk_and_seq(h.a, List.map(group, |d| Arena.tail(a, d)))
                c = Build.mk_concat2(t.a, h.id, t.id)
                { a: c.a, derivs: List.append(acc.derivs, c.id) }
            }
        })
    }

    # concat chains whose final element has the same fixed length: (H1·t1)&(H2·t2) -> (H1&H2)·(t1&t2)
    and_group_tails : Arena.A, List(U32) -> Build.Derivs
    and_group_tails = |a, derivs| {
        keyed = List.map(derivs, |d| {
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
            group = List.keep_if(keyed, |e| e.g == Ok(n))
            if List.len(group) == 1 {
                { a: acc.a, derivs: List.append(acc.derivs, (List.get(group, 0) ?? { d: Arena.bot, heads: [], t: 0, g: Err(No) }).d) }
            } else {
                heads_acc = List.fold(group, { a: acc.a, ids: [] }, |st, e| {
                    r = Build.mk_concat_list(st.a, e.heads)
                    { a: r.a, ids: List.append(st.ids, r.id) }
                })
                h = Build.mk_and_seq(heads_acc.a, heads_acc.ids)
                t = Build.mk_and_seq(h.a, List.map(group, |e| e.t))
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
            concat_tail = Arena.tail(a, node)
            if Arena.is_lookbehind(a, ch) {
                { a, node, suffixes: [] }
            } else if Arena.is_lookahead(a, concat_tail) {
                { a, node: ch, suffixes: [concat_tail] }
            } else if Arena.is_concat(a, concat_tail) and Arena.is_lookahead(a, Arena.head(a, concat_tail)) {
                inner = Build.strip_suffixes(a, Arena.tail(a, concat_tail))
                { a: inner.a, node: ch, suffixes: List.prepend(inner.suffixes, Arena.head(a, concat_tail)) }
            } else {
                inner = Build.strip_suffixes(a, concat_tail)
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
                head_prefix_result = Build.head_prefix(a, h)
                inner = Build.strip_suffixes(head_prefix_result.a, t)
                c = Build.mk_concat2(inner.a, head_prefix_result.node, inner.node)
                { a: c.a, prefixes: head_prefix_result.prefixes, node: c.id, suffixes: inner.suffixes }
            }
        } else if Arena.is_lookahead(a, node) {
            { a, prefixes: [], node: Arena.eps, suffixes: [node] }
        } else if Arena.is_lookbehind(a, node) {
            { a, prefixes: [node], node: Arena.eps, suffixes: [] }
        } else if Arena.is_or(a, node) {
            if node == a.anchors.dollar {
                { a, prefixes: [], node: Arena.eps, suffixes: [node] }
            } else if node == a.anchors.caret {
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
        Build.interned(a, key, |a1| {
            r =
                if inner == Arena.bot {
                    { a: a1, id: Arena.top_star }
                } else if inner == Arena.top_star {
                    { a: a1, id: Arena.bot }
                } else if inner == Arena.eps {
                    { a: a1, id: Arena.top_plus }
                } else if Arena.contains_look(a1, inner) {
                    { a: Arena.fail(a1, "lookarounds inside complement are unsupported"), id: Arena.bot }
                } else if Arena.depends_anchor(a1, inner) {
                    { a: Arena.fail(a1, "anchors inside complement are unsupported"), id: Arena.bot }
                } else {
                    info = { flags: Build.infer_compl(a1, inner), sub: Arena.full(a1), minl: Arena.none, maxl: Arena.none, pend: Arena.pend(a1, inner) }
                    Arena.register(a1, key, info)
                }
            Build.memoed(key, r)
        })
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
            Build.interned(a, key, |a1| Build.memoed(key, Build.concat_rules(a1, h, t)))
        }

    # Register head·tail once every rewrite has declined. A concat head is
    # right-nested first (`(ab)c -> a(bc)`): RE# only normalizes in its last
    # fall-through, so a rewrite path that ends in `createCached` (e.g. the
    # concat-tail case) would otherwise register a structurally distinct copy
    # of a node the derivative also reaches in normal form, and the two would
    # never compare equal as DFA states. Canonical concats make them one state.
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
        Build.interned(a, key, |a1| {
            p = Arena.rs_union(a1, Arena.pend(a1, h), Arena.pend(a1, t))
            info = {
                flags: Build.infer_concat(a1, h, t),
                sub: (Arena.sub(a1, h)).bitwise_or(Arena.sub(a1, t)),
                minl: Build.add_len(Arena.minl(a1, h), Arena.minl(a1, t)),
                maxl: Build.add_len(Arena.maxl(a1, h), Arena.maxl(a1, t)),
                pend: p.id,
            }
            Arena.register(p.a, key, info)
        })
    }

    concat_rules : Arena.A, U32, U32 -> Arena.R
    concat_rules = |a, h, t|
        if h == Arena.top_star and Arena.is_and(a, t) and List.all(Arena.children(a, t), |x| Build.starts_with_true_star(a, x)) {
            { a, id: t }
        } else if t == Arena.top_star and Arena.is_and(a, h) and List.all(Arena.children(a, h), |x| Build.ends_with_true_star(a, x)) {
            { a, id: h }
        } else if Arena.is_loop(a, h) and Arena.is_loop(a, t) and Arena.head(a, h) == Arena.head(a, t) {
            # sub 01: (.*1)?(.*1){2,} -> (.*1){2,}
            lo = Build.incr_loop(Arena.loop_lo(a, h), Arena.loop_lo(a, t))
            hi = Build.incr_loop(Arena.loop_hi(a, h), Arena.loop_hi(a, t))
            Build.mk_loop(a, Arena.head(a, h), lo, hi)
        } else if Arena.is_loop(a, h) and Arena.head(a, h) == t {
            # sub 02: (.*1)?.*1 -> .*1
            Build.mk_loop(a, t, Build.incr_loop(Arena.loop_lo(a, h), 1), Build.incr_loop(Arena.loop_hi(a, h), 1))
        } else if Arena.is_concat(a, t) {
            ch = Arena.head(a, t)
            concat_tail = Arena.tail(a, t)
            if Arena.is_loop(a, ch) and Arena.head(a, ch) == h {
                # merge loops 2
                l = Build.mk_loop(a, h, Build.incr_loop(Arena.loop_lo(a, ch), 1), Build.incr_loop(Arena.loop_hi(a, ch), 1))
                Build.mk_concat2(l.a, l.id, concat_tail)
            } else if Arena.is_loop(a, h) and Arena.is_loop(a, ch) and Arena.head(a, h) == Arena.head(a, ch) {
                # merge loops 3
                lo = Build.incr_loop(Arena.loop_lo(a, h), Arena.loop_lo(a, ch))
                hi = Build.incr_loop(Arena.loop_hi(a, h), Arena.loop_hi(a, ch))
                l = Build.mk_loop(a, Arena.head(a, h), lo, hi)
                Build.mk_concat2(l.a, l.id, concat_tail)
            } else {
                Build.concat_tail_case(a, h, t, ch, concat_tail)
            }
        } else {
            match (Build.pred_star(a, h), Build.pred_star(a, t)) {
                (Ok(head_pred), Ok(tail_pred)) =>
                    if TSet.subset(tail_pred, head_pred) { { a, id: h } } else if TSet.subset(head_pred, tail_pred) { { a, id: t } } else { Build.concat_register(a, h, t) }
                _ => Build.concat_rules_fallback(a, h, t)
            }
        }

    concat_rules_fallback : Arena.A, U32, U32 -> Arena.R
    concat_rules_fallback = |a, h, t|
        if Arena.is_lookbehind(a, h) and Arena.is_concat(a, t) and Arena.is_lookbehind(a, Arena.head(a, t)) {
            # (?<=a.*)(?<=\W)aa -> (?<=_*a.*&_*\W)aa
            combined_lb = Build.combine_lookbehinds(a, Arena.head(a, h), Arena.head(a, Arena.head(a, t)))
            Build.mk_concat2(combined_lb.a, combined_lb.id, Arena.tail(a, t))
        } else if Arena.is_lookbehind(a, h) and Arena.is_lookbehind(a, t) {
            Build.combine_lookbehinds(a, Arena.head(a, h), Arena.head(a, t))
        } else if Arena.is_lookbehind(a, h)
            and Build.is_pred_star(a, Arena.head(a, h))
            and (Arena.head(a, h) == t or (Arena.is_concat(a, t) and Arena.head(a, t) == Arena.head(a, h))) {
            # (?<=.*).* -> .*   (?<=.*).*ab -> .*ab
            { a, id: t }
        } else if Arena.is_lookahead(a, h) and Arena.is_lookahead(a, t) {
            # (?=a.*)(?=\W) -> (?=a.*_*&\W_*)
            first_ext = Build.mk_concat2(a, Arena.head(a, h), Arena.top_star)
            second_ext = Build.mk_concat2(first_ext.a, Arena.head(a, t), Arena.top_star)
            combined_and = Build.mk_and_seq(second_ext.a, [first_ext.id, second_ext.id])
            Build.mk_lookaround(combined_and.a, combined_and.id, False, Arena.look_rel(a, h), Arena.look_pend(a, h))
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
    combine_lookbehinds = |a, first_body, second_body| {
        first_ext = Build.mk_concat2(a, Arena.top_star, first_body)
        second_ext = Build.mk_concat2(first_ext.a, Arena.top_star, second_body)
        combined_and = Build.mk_and_seq(second_ext.a, [first_ext.id, second_ext.id])
        Build.mk_lookaround(combined_and.a, combined_and.id, True, 0, Arena.rs_empty)
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
    concat_tail_case = |a, h, t, ch, concat_tail|
        match (Build.pred_star(a, h), Build.pred_star(a, t)) {
            (Ok(head_pred), Ok(tail_pred)) =>
                if TSet.subset(tail_pred, head_pred) { { a, id: h } } else if TSet.subset(head_pred, tail_pred) { { a, id: t } } else { Build.concat_register(a, h, t) }
            (Ok(head_pred), _) =>
                match Build.pred_star(a, ch) {
                    Ok(ch_pred) =>
                        if TSet.subset(ch_pred, head_pred) { Build.mk_concat2(a, h, concat_tail) }
                        else if TSet.subset(head_pred, ch_pred) { Build.mk_concat2(a, ch, concat_tail) }
                        else { Build.concat_register(a, h, t) }
                    Err(_) =>
                        if Arena.is_loop(a, ch) and Arena.loop_lo(a, ch) == 0 and Arena.loop_hi(a, ch) == 1 {
                            # .*(t.*)?hat.* -> .*hat
                            tsuffix = Build.concat_suffix(a, Arena.head(a, ch))
                            if TSet.subset(Arena.sub(a, ch), head_pred) and h == tsuffix { Build.mk_concat2(a, h, concat_tail) } else { Build.concat_register(a, h, t) }
                        } else {
                            Build.sub03_06(a, h, t, ch, concat_tail)
                        }
                }
            _ =>
                if Arena.is_loop(a, h) and Arena.loop_lo(a, h) == 0 and Arena.loop_hi(a, h) == 1 {
                    # (.*ab)?.* -> .*
                    body = Arena.head(a, h)
                    r =
                        if Arena.is_concat(a, body) {
                            match (Build.pred_star(a, Arena.head(a, body)), Build.pred_star(a, t)) {
                                (Ok(body_head_pred), Ok(tail_pred)) =>
                                    if TSet.subset(Arena.sub(a, h), tail_pred) {
                                        if TSet.subset(body_head_pred, tail_pred) { Ok(t) } else if body == t { Ok(t) } else { Err(No) }
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
                        Err(_) => Build.sub03_06(a, h, t, ch, concat_tail)
                    }
                } else if Arena.is_loop(a, h) and Arena.loop_lo(a, h) == 0 {
                    # .{0,20}_* -> _*
                    match Build.pred_star(a, t) {
                        Ok(tail_pred) => if TSet.subset(Arena.sub(a, h), tail_pred) { { a, id: t } } else { Build.concat_register(a, h, t) }
                        Err(_) => Build.sub03_06(a, h, t, ch, concat_tail)
                    }
                } else {
                    Build.sub03_06(a, h, t, ch, concat_tail)
                }
        }

    # `mkConcat2_sub03_06`
    sub03_06 : Arena.A, U32, U32, U32, U32 -> Arena.R
    sub03_06 = |a, first_rep, t, second_rep, tail_node| {
        inner = Build.mk_concat2(a, first_rep, second_rep)
        a1 = inner.a
        if Build.is_pred_star(a1, inner.id) {
            # sub 06: (.*1)?.*a -> .*a
            Build.mk_concat2(a1, inner.id, tail_node)
        } else if Arena.is_concat(a1, tail_node) {
            tail_head = Arena.head(a1, tail_node)
            tail_tail = Arena.tail(a1, tail_node)
            if first_rep == tail_head and second_rep == tail_tail {
                # sub 03: .*1.*1$ -> (.*1){2,}
                Build.mk_loop(a1, tail_node, 2, 2)
            } else if Arena.is_concat(a1, tail_tail) and first_rep == tail_head and second_rep == Arena.head(a1, tail_tail) {
                # sub 04 + sub 05
                l = Build.mk_loop(a1, inner.id, 2, 2)
                Build.mk_concat2(l.a, l.id, Arena.tail(a1, tail_tail))
            } else if Arena.is_loop(a1, tail_head) and Arena.head(a1, tail_head) == inner.id {
                l = Build.mk_loop(a1, inner.id, Build.incr_loop(Arena.loop_lo(a1, tail_head), 1), Build.incr_loop(Arena.loop_hi(a1, tail_head), 1))
                Build.mk_concat2(l.a, l.id, tail_tail)
            } else {
                Build.concat_register(a1, first_rep, t)
            }
        } else {
            Build.concat_register(a1, first_rep, t)
        }
    }

    # --- mkLoop ----------------------------------------------------------------------

    mk_loop : Arena.A, U32, U32, U32 -> Arena.R
    mk_loop = |a, body, lo, hi| {
        key = Arena.key_loop(body, lo, hi)
        Build.interned(a, key, |a1| Build.memoed(key, Build.loop_rules(a1, body, lo, hi)))
    }

    # `n * m` stays a length rather than wrapping or colliding with the `none`
    # sentinel
    len_fits : U32, U32 -> Bool
    len_fits = |n, m| m == 0 or n <= (Arena.none - 1) // m

    loop_register : Arena.A, U32, U32, U32 -> Arena.R
    loop_register = |a, body, lo, hi| {
        key = Arena.key_loop(body, lo, hi)
        Build.interned(a, key, |a1| {
            # A repetition of a FIXED-LENGTH body has a fixed length too:
            # `(\r\n){2}` is four symbols. The rewrites fold a doubled
            # literal (`\r\n\r\n`, `abab`, `(?:ab){2}`) into exactly this
            # shape, and the length is what lets `Accel` take its literal
            # override instead of the full reverse sweep. Capped so a large
            # `{n,m}` cannot overflow.
            bmin = Arena.minl(a1, body)
            bmax = Arena.maxl(a1, body)
            minl = if bmin != Arena.none and Build.len_fits(lo, bmin) { lo * bmin } else { Arena.none }
            maxl = if bmax != Arena.none and hi != Arena.inf and Build.len_fits(hi, bmax) { hi * bmax } else { Arena.none }
            Arena.register(a1, key, { flags: Build.infer_loop(a1, body, lo), sub: Arena.sub(a1, body), minl, maxl, pend: Arena.pend(a1, body) })
        })
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
            concat_tail = Arena.tail(a, body)
            match Build.pred_star(a, ch) {
                Ok(pstar) => Build.loop_star_rule(a, body, lo, hi, TSet.subset(Arena.sub(a, concat_tail), pstar))
                Err(_) =>
                    match Build.pred_star(a, concat_tail) {
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
        Build.interned(a, key, |a1|
            if back and body == Arena.eps {
                { a: a1, id: body }
            } else if back and body == Arena.top_star {
                Build.look_create(a1, Arena.top_star, back, rel, pend)
            } else if !back and Arena.is_always_null(a1, body) {
                # IMPORTANT: finish pending lookahead
                Build.look_create(a1, Arena.eps, back, rel, pend)
            } else if body == Arena.bot {
                { a: a1, id: Arena.bot }
            } else {
                Build.look_create(a1, body, back, rel, pend)
            })
    }

    look_create : Arena.A, U32, Bool, U32, U32 -> Arena.R
    look_create = |a, raw_body, back, rel, pend| {
        normalized_body = if back { { a, id: raw_body } } else { Build.lookahead_normal_form(a, raw_body) }
        a1 = normalized_body.a
        body = normalized_body.id
        key = Arena.key_look(back, body, rel, pend)
        Build.interned(a1, key, |a2| {
            flags = Build.infer_lookaround(a2, body, back)
            nulls =
                if flags.bitwise_and(Arena.f_can_null) == 0 or pend == Arena.rs_empty {
                    { a: a2, id: Arena.rs_empty }
                } else {
                    Arena.rs_add_all(a2, rel, pend)
                }
            Arena.register(nulls.a, key, { flags, sub: Arena.full(a2), minl: 0, maxl: 0, pend: nulls.id })
        })
    }

    # rewrite a lookahead body to normal form: it ends with `_*` unless anchored
    lookahead_normal_form : Arena.A, U32 -> Arena.R
    lookahead_normal_form = |a, body|
        if body == Arena.eps or body == Arena.top_star or Build.ends_with_true_star(a, body) {
            { a, id: body }
        } else if Arena.is_concat(a, body)
            and Arena.head(a, body) == Arena.top_star
            and Arena.is_anchor(a, Arena.tail(a, body))
            and Arena.depends_anchor(a, body) {
            # not always correct but does not make a difference (RE#)
            { a, id: Arena.eps }
        } else if Arena.is_concat(a, body) and Arena.depends_anchor(a, body) {
            s = Build.split_tail(a, body)
            if Arena.depends_anchor(a, s.tail) { { a, id: body } } else { Build.mk_concat2(a, body, Arena.top_star) }
        } else {
            Build.mk_concat2(a, body, Arena.top_star)
        }

    # --- mkConcatChecked ---------------------------------------------------------------

    ## Concatenate with the lookaround-position checks and rewrites.
    mk_concat_checked : Arena.A, List(U32) -> Arena.R
    mk_concat_checked = |a, raw_nodes| {
        nodes = List.fold(raw_nodes, [], |acc, n| List.concat(acc, Build.collect_concat(a, n)))
        len = List.len(nodes)
        if len == 0 {
            { a, id: Arena.eps }
        } else if len == 1 {
            only_node = List.get(nodes, 0) ?? Arena.eps
            if Arena.is_or(a, only_node) and Arena.contains_look(a, only_node) {
                { a: Arena.fail(a, "Lookarounds inside union not supported\nMove lookarounds/anchors outside union ^1$|^2$ -> ^(1|2)$"), id: Arena.bot }
            } else {
                { a, id: only_node }
            }
        } else {
            n_last = List.get(nodes, len - 1) ?? Arena.eps
            n_prev = List.get(nodes, len - 2) ?? Arena.eps
            first_node = List.get(nodes, 0) ?? Arena.eps
            second_node = List.get(nodes, 1) ?? Arena.eps
            if Arena.is_lookahead(a, n_prev) and Arena.is_lookahead(a, n_last) {
                # merge suffixes
                first_ext = Build.mk_concat2(a, Arena.head(a, n_prev), Arena.top_star)
                second_ext = Build.mk_concat2(first_ext.a, Arena.head(a, n_last), Arena.top_star)
                combined_and = Build.mk_and_seq(second_ext.a, [first_ext.id, second_ext.id])
                merged = Build.mk_lookaround(combined_and.a, combined_and.id, False, 0, Arena.rs_empty)
                Build.mk_concat_checked(merged.a, List.append(List.take_first(nodes, len - 2), merged.id))
            } else if Arena.is_lookbehind(a, first_node) and Arena.is_lookbehind(a, second_node) {
                # merge prefixes
                first_ext = Build.mk_concat2(a, Arena.top_star, Arena.head(a, first_node))
                second_ext = Build.mk_concat2(first_ext.a, Arena.top_star, Arena.head(a, second_node))
                combined_and = Build.mk_and_seq(second_ext.a, [first_ext.id, second_ext.id])
                merged = Build.mk_lookaround(combined_and.a, combined_and.id, True, 0, Arena.rs_empty)
                Build.mk_concat_checked(merged.a, List.prepend(List.drop_first(nodes, 2), merged.id))
            } else {
                match Build.first_rewrite_index(a, nodes, 0) {
                    Err(_) => Build.mk_concat_list(a, nodes)
                    Ok(i) => Build.rewrite_at(a, nodes, i)
                }
            }
        }
    }

    unsupported_empty_left : Str
    unsupported_empty_left = "a lookbehind (or \\b, ^) after an expression that can be empty is unsupported; anchor it or make the expression non-empty"

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
                # that text (`a?\b\s` matches 0-9 on "a b  c,\n\nab"). The correct
                # rewrite needs a lookbehind inside a union, which RE#'s normal form
                # excludes, so the pattern is rejected instead of matched wrongly.
                { a: Arena.fail(a, Build.unsupported_empty_left), id: Arena.bot }
            } else if Arena.maxl(a, body) == 1 {
                left_concat = Build.mk_concat_list(a, left)
                look = Build.mk_concat2(left_concat.a, Arena.top_star, body)
                rem = Build.mk_concat_checked(look.a, right)
                combined_and = Build.mk_and_seq(rem.a, [left_concat.id, look.id])
                Build.mk_concat2(combined_and.a, combined_and.id, rem.id)
            } else {
                { a: Arena.fail(a, Build.unsupported_look), id: Arena.bot }
            }
        } else if Arena.is_lookahead(a, curr) {
            body = Arena.head(a, curr)
            rem = Build.mk_concat_checked(a, right)
            s = Build.split_tail(rem.a, body)
            look_len =
                if s.tail == Arena.top_star {
                    r = Build.mk_concat_list(rem.a, s.heads)
                    { a: r.a, len: Arena.maxl(r.a, r.id) }
                } else {
                    { a: rem.a, len: Arena.maxl(rem.a, body) }
                }
            if look_len.len == Arena.none {
                { a: Arena.fail(look_len.a, "unconstrained lookarounds are only supported as prefixes/suffixes"), id: Arena.bot }
            } else {
                match Build.rewrite_common_lookahead(look_len.a, curr, rem.id) {
                    Ok(rewritten) => Build.mk_concat_checked(rewritten.a, List.append(left, rewritten.id))
                    Err(a2) => { a: Arena.fail(a2, Build.unsupported_look), id: Arena.bot }
                }
            }
        } else if Build.has_prefix_or_suffix(a, curr) {
            if Arena.is_or(a, curr) {
                # attempt combining every or branch
                arms = Arena.map_ids(a, Arena.children(a, curr), |ax, arm|
                    Build.mk_concat_checked(ax, List.prepend(right, arm)))
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
        raw_body = Arena.head(a, look)
        s = Build.split_tail(a, raw_body)
        stripped_body = if s.tail == Arena.top_star { Build.mk_concat_list(a, s.heads) } else { { a, id: raw_body } }
        a1 = stripped_body.a
        body = stripped_body.id
        is_nonword_right = look == a1.anchors.nonword_right
        and_with = |ax, x| {
            c = Build.mk_concat2(ax, x, Arena.top_star)
            Build.mk_and_seq(c.a, [c.id, remaining])
        }
        if is_nonword_right and Build.is_pred_star(a1, remaining) {
            # a\b.* -> a(?=(\W.*|\z))
            nonword_node = Build.one(a1, a1.nonwordc)
            c = Build.mk_concat2(nonword_node.a, nonword_node.id, remaining)
            Ok(Build.mk_or2(c.a, c.id, Arena.end_anchor))
        } else if is_nonword_right
            and Arena.is_loop(a1, remaining)
            and Arena.loop_lo(a1, remaining) == 1
            and Arena.loop_hi(a1, remaining) == Arena.inf
            and Arena.is_singleton(a1, Arena.head(a1, remaining)) {
            # \b.+
            Ok(and_with(a1, body))
        } else if is_nonword_right and Arena.is_concat(a1, remaining) {
            # \b\s+abc
            nonword_node = Build.one(a1, a1.nonwordc)
            Ok(and_with(nonword_node.a, nonword_node.id))
        } else if is_nonword_right
            and Arena.is_loop(a1, remaining)
            and Arena.loop_lo(a1, remaining) == 0
            and Arena.is_concat(a1, Arena.head(a1, remaining))
            and Arena.is_singleton(a1, Arena.head(a1, Arena.head(a1, remaining))) {
            # \b(/[abc]*)
            nonword_node = Build.one(a1, a1.nonwordc)
            nonword_branch = and_with(nonword_node.a, nonword_node.id)
            Ok(Build.mk_or2(nonword_branch.a, look, nonword_branch.id))
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

    # --- relocation after eviction --------------------------------------------------

    ## Re-create node `id` of arena `src` inside `a` (which is `src` truncated to
    ## `marks`): ids below the mark are shared; anything newer is rebuilt through
    ## the constructors, refsets included.
    copy_node : Arena.A, Arena.A, Arena.Marks, U32 -> Arena.R
    copy_node = |src, a, m, id|
        if id.to_u64() < m.nodes {
            { a, id }
        } else {
            # the kinds are read out of `src`: `a` is the truncated arena the
            # node is being rebuilt into, and does not hold this id yet
            match Arena.kind_of(src, id) {
                Singleton => Build.one(a, Arena.tset(src, id))
                Concat => {
                    h = Build.copy_node(src, a, m, Arena.head(src, id))
                    t = Build.copy_node(src, h.a, m, Arena.tail(src, id))
                    Build.mk_concat2(t.a, h.id, t.id)
                }
                Loop => {
                    b = Build.copy_node(src, a, m, Arena.head(src, id))
                    Build.mk_loop(b.a, b.id, Arena.loop_lo(src, id), Arena.loop_hi(src, id))
                }
                Or => {
                    cs = Build.copy_children(src, a, m, id)
                    Build.mk_or_seq(cs.a, cs.ids)
                }
                And => {
                    cs = Build.copy_children(src, a, m, id)
                    Build.mk_and_seq(cs.a, cs.ids)
                }
                Not => {
                    b = Build.copy_node(src, a, m, Arena.head(src, id))
                    Build.mk_not(b.a, b.id)
                }
                LookAhead => Build.copy_look(src, a, m, id, False)
                LookBehind => Build.copy_look(src, a, m, id, True)
                # anchors are fixed nodes shared with `src` — nothing to rebuild
                Begin => { a, id }
                End => { a, id }
            }
        }

    copy_children : Arena.A, Arena.A, Arena.Marks, U32 -> Arena.Ids
    copy_children = |src, a, m, id|
        Arena.map_ids(a, Arena.children(src, id), |ax, c| Build.copy_node(src, ax, m, c))

    copy_look : Arena.A, Arena.A, Arena.Marks, U32, Bool -> Arena.R
    copy_look = |src, a, m, id, back| {
        b = Build.copy_node(src, a, m, Arena.head(src, id))
        pend = Arena.look_pend(src, id)
        rs = if pend.to_u64() < m.rs { { a: b.a, id: pend } } else { Arena.rs_intern(b.a, Arena.rs_get(src, pend)) }
        Build.mk_lookaround(rs.a, b.id, back, Arena.look_rel(src, id), rs.id)
    }

    # --- anchors and negative lookarounds (RegexBuilder anchors, RegexNodeConverter) --

    ## Create RE#'s well-known anchor nodes. `wordc`/`nonwordc` are the `\w`/`\W`
    ## tsets (0 when the pattern has no `\b`), `newline_tset` the `\n` tset (0 when no `^`/`$`).
    init_anchors : Arena.A, U64, U64, U64 -> Arena.A
    init_anchors = |a0, wordc, nonwordc, newline_tset| {
        a = { ..a0, wordc, nonwordc }
        mk_side = |ax, anchor, t, back| {
            o = Build.one(ax, t)
            b = Build.mk_or2(o.a, anchor, o.id)
            Build.mk_lookaround(b.a, b.id, back, 0, Arena.rs_empty)
        }
        nonword_left_node = mk_side(a, Arena.begin_anchor, nonwordc, True)
        word_left_node = mk_side(nonword_left_node.a, Arena.begin_anchor, wordc, True)
        nonword_right_node = mk_side(word_left_node.a, Arena.end_anchor, nonwordc, False)
        word_right_node = mk_side(nonword_right_node.a, Arena.end_anchor, wordc, False)
        # ^ ≡ (?<=\A|\n)   $ ≡ (?=\z|\n)
        caret_node = mk_side(word_right_node.a, Arena.begin_anchor, newline_tset, True)
        dollar_node = mk_side(caret_node.a, Arena.end_anchor, newline_tset, False)
        { ..dollar_node.a, anchors: { caret: caret_node.id, dollar: dollar_node.id, nonword_left: nonword_left_node.id, word_left: word_left_node.id, nonword_right: nonword_right_node.id, word_right: word_right_node.id, a_anchor: Arena.none, end_z: Arena.none } }
    }

    ## `(?!R)` / `(?<!R)` as positive lookarounds over complements
    rewrite_negative_lookaround : Arena.A, Bool, U32 -> Arena.R
    rewrite_negative_lookaround = |a, back, node|
        if Arena.is_singleton(a, node) {
            flipped = Build.one(a, TSet.compl(Arena.tset(a, node), a.minterm_count))
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
            starred = Build.mk_concat2(a, Arena.top_star, node)
            negated = Build.mk_not(starred.a, starred.id)
            anchored = Build.mk_concat2(negated.a, Arena.begin_anchor, negated.id)
            Build.mk_lookaround(anchored.a, anchored.id, True, 0, Arena.rs_empty)
        } else {
            # (?=~(R·_*)·\z) ≡ (?!R)
            starred = Build.mk_concat2(a, node, Arena.top_star)
            negated = Build.mk_not(starred.a, starred.id)
            anchored = Build.mk_concat2(negated.a, negated.id, Arena.end_anchor)
            Build.mk_lookaround(anchored.a, anchored.id, False, 0, Arena.rs_empty)
        }
}
