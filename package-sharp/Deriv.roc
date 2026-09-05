## Brzozowski derivatives over the arena (RE#'s `Algorithm.fs`): location-aware
## nullability, the derivative by one minterm, pattern reversal, and the
## lookbehind-prefix strip the forward pass uses. Locations are RE#'s
## `LocationKind`: `begin` (position 0), `center`, `end` (position len) — they
## decide whether `\A`/`\z` are nullable at the position being derived.
import Arena
import Build
import TSet

Deriv := [].{
    loc_begin : U32
    loc_begin = 0
    loc_center : U32
    loc_center = 1
    loc_end : U32
    loc_end = 2
    ## the empty input: position 0 is both the beginning and the end
    loc_both : U32
    loc_both = 3

    ## does the node match the empty string at this location?
    nullable : Arena.A, U32, U32 -> Bool
    nullable = |a, loc, id|
        if !Arena.can_be_null(a, id) {
            False
        } else if Arena.is_always_null(a, id) {
            True
        } else {
            k = Arena.kind(a, id)
            if k == Arena.k_singleton {
                False
            } else if k == Arena.k_or {
                List.any(Arena.children(a, id), |c| Deriv.nullable(a, loc, c))
            } else if k == Arena.k_and {
                List.all(Arena.children(a, id), |c| Deriv.nullable(a, loc, c))
            } else if k == Arena.k_loop {
                Arena.loop_lo(a, id) == 0 or Deriv.nullable(a, loc, Arena.head(a, id))
            } else if k == Arena.k_not {
                !Deriv.nullable(a, loc, Arena.head(a, id))
            } else if k == Arena.k_concat {
                Deriv.nullable(a, loc, Arena.head(a, id)) and Deriv.nullable(a, loc, Arena.tail(a, id))
            } else if k == Arena.k_lookahead or k == Arena.k_lookbehind {
                Deriv.nullable(a, loc, Arena.head(a, id))
            } else if k == Arena.k_end {
                loc == Deriv.loc_end or loc == Deriv.loc_both
            } else {
                loc == Deriv.loc_begin or loc == Deriv.loc_both
            }
        }

    decr : U32 -> U32
    decr = |x| if x == Arena.inf or x == 0 { x } else { x - 1 }

    ## the derivative of node `id` by minterm `mt` (a one-bit tset) at `loc`
    derivative : Arena.A, U32, U64, U32 -> Arena.R
    derivative = |a, loc, mt, id| {
        k = Arena.kind(a, id)
        if k == Arena.k_singleton {
            { a, id: if TSet.intersects(Arena.tset(a, id), mt) { Arena.eps } else { Arena.bot } }
        } else if k == Arena.k_loop {
            body = Arena.head(a, id)
            decr_loop = Build.mk_loop(a, body, Deriv.decr(Arena.loop_lo(a, id)), Deriv.decr(Arena.loop_hi(a, id)))
            d = Deriv.derivative(decr_loop.a, loc, mt, body)
            Build.mk_concat2(d.a, d.id, decr_loop.id)
        } else if k == Arena.k_or {
            ds = Deriv.derive_children(a, loc, mt, Arena.children(a, id), Arena.bot)
            if List.is_empty(ds.ids) {
                { a: ds.a, id: Arena.bot }
            } else if List.len(ds.ids) == 1 {
                { a: ds.a, id: List.get(ds.ids, 0) ?? Arena.bot }
            } else {
                Build.mk_or(ds.a, Arena.sort_dedup(ds.ids))
            }
        } else if k == Arena.k_and {
            ds = Deriv.derive_children(a, loc, mt, Arena.children(a, id), Arena.top_star)
            if List.is_empty(ds.ids) {
                { a: ds.a, id: Arena.top_star }
            } else if List.len(ds.ids) == 1 {
                { a: ds.a, id: List.get(ds.ids, 0) ?? Arena.top_star }
            } else {
                Build.mk_and(ds.a, Arena.sort_dedup(ds.ids))
            }
        } else if k == Arena.k_not {
            d = Deriv.derivative(a, loc, mt, Arena.head(a, id))
            Build.mk_not(d.a, d.id)
        } else if k == Arena.k_concat {
            h = Arena.head(a, id)
            t = Arena.tail(a, id)
            dh = Deriv.derivative(a, loc, mt, h)
            rs = Build.mk_concat2(dh.a, dh.id, t)
            if Deriv.nullable(rs.a, loc, h) {
                dt = Deriv.derivative(rs.a, loc, mt, t)
                if dt.id == Arena.bot {
                    { a: dt.a, id: rs.id }
                } else if rs.id == Arena.bot {
                    dt
                } else {
                    Build.mk_or2(dt.a, rs.id, dt.id)
                }
            } else {
                rs
            }
        } else if k == Arena.k_lookahead {
            Deriv.derive_lookahead(a, loc, mt, id)
        } else if k == Arena.k_lookbehind {
            d = Deriv.derivative(a, loc, mt, Arena.head(a, id))
            Build.mk_lookaround(d.a, d.id, True, 0, Arena.rs_empty)
        } else {
            { a, id: Arena.bot }
        }
    }

    # derivatives of children, dropping `skip` (bot for Or, top_star for And)
    derive_children : Arena.A, U32, U64, List(U32), U32 -> { a : Arena.A, ids : List(U32) }
    derive_children = |a, loc, mt, ids, skip|
        List.fold(ids, { a, ids: [] }, |acc, c| {
            d = Deriv.derivative(acc.a, loc, mt, c)
            if d.id == skip { { a: d.a, ids: acc.ids } } else { { a: d.a, ids: List.append(acc.ids, d.id) } }
        })

    # a lookahead's derivative carries how far back the match end lies (`rel`)
    # and, once the body has been nullable, the pending relative positions
    derive_lookahead : Arena.A, U32, U64, U32 -> Arena.R
    derive_lookahead = |a, loc, mt, id| {
        r = Arena.head(a, id)
        rel = Arena.look_rel(a, id)
        pend = Arena.look_pend(a, id)
        d = Deriv.derivative(a, loc, mt, r)
        a1 = d.a
        der = d.id
        if pend != Arena.rs_empty {
            Build.mk_lookaround(a1, der, False, rel + 1, pend)
        } else if Deriv.nullable(a1, loc, der) {
            # initialize the first relative nullable position
            Build.mk_lookaround(a1, der, False, rel + 1, Arena.rs_zero)
        } else if Arena.is_concat(a1, der) and Arena.head(a1, der) == Arena.top_star {
            ct = Arena.tail(a1, der)
            anchored_tail =
                Arena.is_anchor(a1, ct)
                or (Arena.is_concat(a1, ct) and Arena.is_anchor(a1, Arena.head(a1, ct)) and Arena.tail(a1, ct) == Arena.top_star)
            if anchored_tail {
                Build.mk_lookaround(a1, Arena.eps, False, rel + 1, Arena.rs_zero)
            } else {
                Build.mk_lookaround(a1, der, False, rel + 1, Arena.rs_zero)
            }
        } else {
            Build.mk_lookaround(a1, der, False, rel + 1, Arena.rs_zero)
        }
    }

    ## reverse a regex: asdf -> fdsa (lookaheads become lookbehinds and back)
    rev : Arena.A, U32 -> Arena.R
    rev = |a, id| {
        k = Arena.kind(a, id)
        if k == Arena.k_singleton or k == Arena.k_begin or k == Arena.k_end {
            { a, id }
        } else if k == Arena.k_or {
            rs = Deriv.rev_all(a, Arena.children(a, id))
            Build.mk_or(rs.a, Arena.sort_dedup(rs.ids))
        } else if k == Arena.k_and {
            rs = Deriv.rev_all(a, Arena.children(a, id))
            Build.mk_and(rs.a, Arena.sort_dedup(rs.ids))
        } else if k == Arena.k_loop {
            b = Deriv.rev(a, Arena.head(a, id))
            Build.mk_loop(b.a, b.id, Arena.loop_lo(a, id), Arena.loop_hi(a, id))
        } else if k == Arena.k_not {
            b = Deriv.rev(a, Arena.head(a, id))
            Build.mk_not(b.a, b.id)
        } else if k == Arena.k_lookahead {
            body = Arena.head(a, id)
            s = Build.split_tail(a, body)
            inner =
                if s.tail == Arena.top_star {
                    c = Build.mk_concat_list(a, s.heads)
                    Deriv.rev(c.a, c.id)
                } else {
                    Deriv.rev(a, body)
                }
            Build.mk_lookaround(inner.a, inner.id, True, 0, Arena.rs_empty)
        } else if k == Arena.k_lookbehind {
            body = Arena.head(a, id)
            inner =
                if Arena.is_concat(a, body) and Arena.head(a, body) == Arena.top_star {
                    Deriv.rev(a, Arena.tail(a, body))
                } else {
                    Deriv.rev(a, body)
                }
            Build.mk_lookaround(inner.a, inner.id, False, 0, Arena.rs_empty)
        } else {
            # concat: reverse the chain
            rs = Deriv.rev_all(a, Build.collect_concat(a, id))
            Build.mk_concat_list(rs.a, List.fold(rs.ids, [], |acc, x| List.prepend(acc, x)))
        }
    }

    rev_all : Arena.A, List(U32) -> { a : Arena.A, ids : List(U32) }
    rev_all = |a, ids|
        List.fold(ids, { a, ids: [] }, |acc, c| {
            r = Deriv.rev(acc.a, c)
            { a: r.a, ids: List.append(acc.ids, r.id) }
        })

    ## `mkNodeWithoutLookbackPrefix`: the pattern with its leading lookbehind
    ## (already verified by the reverse pass) removed
    without_lookback_prefix : Arena.A, U32 -> Arena.R
    without_lookback_prefix = |a, id| {
        k = Arena.kind(a, id)
        if k == Arena.k_lookbehind or k == Arena.k_begin or k == Arena.k_end {
            { a, id: Arena.eps }
        } else if k == Arena.k_concat {
            h = Arena.head(a, id)
            t = Arena.tail(a, id)
            if Arena.is_lookbehind(a, h) {
                Deriv.without_lookback_prefix(a, t)
            } else if Arena.is_always_null(a, h) {
                ct = Deriv.without_lookback_prefix(a, t)
                Build.mk_concat2(ct.a, h, ct.id)
            } else {
                ch = Deriv.without_lookback_prefix(a, h)
                if ch.id == Arena.eps { Deriv.without_lookback_prefix(ch.a, t) } else { Build.mk_concat2(ch.a, ch.id, t) }
            }
        } else if k == Arena.k_or {
            rs = Deriv.wlp_all(a, Arena.children(a, id))
            Build.mk_or(rs.a, Arena.sort_dedup(rs.ids))
        } else if k == Arena.k_and {
            rs = Deriv.wlp_all(a, Arena.children(a, id))
            Build.mk_and(rs.a, Arena.sort_dedup(rs.ids))
        } else {
            { a, id }
        }
    }

    wlp_all : Arena.A, List(U32) -> { a : Arena.A, ids : List(U32) }
    wlp_all = |a, ids|
        List.fold(ids, { a, ids: [] }, |acc, c| {
            r = Deriv.without_lookback_prefix(acc.a, c)
            { a: r.a, ids: List.append(acc.ids, r.id) }
        })
}
