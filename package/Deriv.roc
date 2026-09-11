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
            match Arena.kind_of(a, id) {
                Singleton => False
                Or => List.any(Arena.children(a, id), |c| Deriv.nullable(a, loc, c))
                And => List.all(Arena.children(a, id), |c| Deriv.nullable(a, loc, c))
                Loop => Arena.loop_lo(a, id) == 0 or Deriv.nullable(a, loc, Arena.head(a, id))
                Not => !Deriv.nullable(a, loc, Arena.head(a, id))
                Concat => Deriv.nullable(a, loc, Arena.head(a, id)) and Deriv.nullable(a, loc, Arena.tail(a, id))
                LookAhead | LookBehind => Deriv.nullable(a, loc, Arena.head(a, id))
                End => loc == Deriv.loc_end or loc == Deriv.loc_both
                Begin => loc == Deriv.loc_begin or loc == Deriv.loc_both
            }
        }

    decr : U32 -> U32
    decr = |x| if x == Arena.inf or x == 0 { x } else { x - 1 }

    ## the derivative of node `id` by `minterm` (a one-bit tset) at `loc`
    derivative : Arena.A, U32, U64, U32 -> Arena.R
    derivative = |a, loc, minterm, id|
        match Arena.kind_of(a, id) {
            Singleton => { a, id: if TSet.intersects(Arena.tset(a, id), minterm) { Arena.eps } else { Arena.bot } }
            Loop => {
                body = Arena.head(a, id)
                decr_loop = Build.mk_loop(a, body, Deriv.decr(Arena.loop_lo(a, id)), Deriv.decr(Arena.loop_hi(a, id)))
                d = Deriv.derivative(decr_loop.a, loc, minterm, body)
                Build.mk_concat2(d.a, d.id, decr_loop.id)
            }
            Or => {
                child_ds = Deriv.derive_children(a, loc, minterm, Arena.children(a, id), Arena.bot)
                if List.is_empty(child_ds.ids) {
                    { a: child_ds.a, id: Arena.bot }
                } else if List.len(child_ds.ids) == 1 {
                    { a: child_ds.a, id: List.get(child_ds.ids, 0) ?? Arena.bot }
                } else {
                    Build.mk_or(child_ds.a, Arena.sort_dedup(child_ds.ids))
                }
            }
            And => {
                child_ds = Deriv.derive_children(a, loc, minterm, Arena.children(a, id), Arena.top_star)
                if List.is_empty(child_ds.ids) {
                    { a: child_ds.a, id: Arena.top_star }
                } else if List.len(child_ds.ids) == 1 {
                    { a: child_ds.a, id: List.get(child_ds.ids, 0) ?? Arena.top_star }
                } else {
                    Build.mk_and(child_ds.a, Arena.sort_dedup(child_ds.ids))
                }
            }
            Not => {
                d = Deriv.derivative(a, loc, minterm, Arena.head(a, id))
                Build.mk_not(d.a, d.id)
            }
            Concat => {
                h = Arena.head(a, id)
                t = Arena.tail(a, id)
                head_der = Deriv.derivative(a, loc, minterm, h)
                rs = Build.mk_concat2(head_der.a, head_der.id, t)
                if Deriv.nullable(rs.a, loc, h) {
                    tail_der = Deriv.derivative(rs.a, loc, minterm, t)
                    if tail_der.id == Arena.bot {
                        { a: tail_der.a, id: rs.id }
                    } else if rs.id == Arena.bot {
                        tail_der
                    } else {
                        Build.mk_or2(tail_der.a, rs.id, tail_der.id)
                    }
                } else {
                    rs
                }
            }
            LookAhead => Deriv.derive_lookahead(a, loc, minterm, id)
            LookBehind => {
                d = Deriv.derivative(a, loc, minterm, Arena.head(a, id))
                Build.mk_lookaround(d.a, d.id, True, 0, Arena.rs_empty)
            }
            # an anchor consumes nothing, so any symbol kills it
            Begin | End => { a, id: Arena.bot }
        }

    # derivatives of children, dropping `skip` (bot for Or, top_star for And)
    derive_children : Arena.A, U32, U64, List(U32), U32 -> { a : Arena.A, ids : List(U32) }
    derive_children = |a, loc, minterm, ids, skip|
        List.fold(ids, { a, ids: [] }, |acc, c| {
            d = Deriv.derivative(acc.a, loc, minterm, c)
            if d.id == skip { { a: d.a, ids: acc.ids } } else { { a: d.a, ids: List.append(acc.ids, d.id) } }
        })

    # a lookahead's derivative carries how far back the match end lies (`rel`)
    # and, once the body has been nullable, the pending relative positions
    derive_lookahead : Arena.A, U32, U64, U32 -> Arena.R
    derive_lookahead = |a, loc, minterm, id| {
        r = Arena.head(a, id)
        rel = Arena.look_rel(a, id)
        pend = Arena.look_pend(a, id)
        d = Deriv.derivative(a, loc, minterm, r)
        a1 = d.a
        body_der = d.id
        if pend != Arena.rs_empty {
            Build.mk_lookaround(a1, body_der, False, rel + 1, pend)
        } else if Deriv.nullable(a1, loc, body_der) {
            # initialize the first relative nullable position
            Build.mk_lookaround(a1, body_der, False, rel + 1, Arena.rs_zero)
        } else if Arena.is_concat(a1, body_der) and Arena.head(a1, body_der) == Arena.top_star {
            after_star = Arena.tail(a1, body_der)
            anchored_tail =
                Arena.is_anchor(a1, after_star)
                or (Arena.is_concat(a1, after_star) and Arena.is_anchor(a1, Arena.head(a1, after_star)) and Arena.tail(a1, after_star) == Arena.top_star)
            if anchored_tail {
                Build.mk_lookaround(a1, Arena.eps, False, rel + 1, Arena.rs_zero)
            } else {
                Build.mk_lookaround(a1, body_der, False, rel + 1, Arena.rs_zero)
            }
        } else {
            Build.mk_lookaround(a1, body_der, False, rel + 1, Arena.rs_zero)
        }
    }

    ## reverse a regex: asdf -> fdsa (lookaheads become lookbehinds and back)
    rev : Arena.A, U32 -> Arena.R
    rev = |a, id|
        match Arena.kind_of(a, id) {
            Singleton | Begin | End => { a, id }
            Or => {
                rs = Arena.map_ids(a, Arena.children(a, id), Deriv.rev)
                Build.mk_or(rs.a, Arena.sort_dedup(rs.ids))
            }
            And => {
                rs = Arena.map_ids(a, Arena.children(a, id), Deriv.rev)
                Build.mk_and(rs.a, Arena.sort_dedup(rs.ids))
            }
            Loop => {
                b = Deriv.rev(a, Arena.head(a, id))
                Build.mk_loop(b.a, b.id, Arena.loop_lo(a, id), Arena.loop_hi(a, id))
            }
            Not => {
                b = Deriv.rev(a, Arena.head(a, id))
                Build.mk_not(b.a, b.id)
            }
            LookAhead => {
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
            }
            LookBehind => {
                body = Arena.head(a, id)
                inner =
                    if Arena.is_concat(a, body) and Arena.head(a, body) == Arena.top_star {
                        Deriv.rev(a, Arena.tail(a, body))
                    } else {
                        Deriv.rev(a, body)
                    }
                Build.mk_lookaround(inner.a, inner.id, False, 0, Arena.rs_empty)
            }
            Concat => {
                # reverse the chain
                rs = Arena.map_ids(a, Build.collect_concat(a, id), Deriv.rev)
                Build.mk_concat_list(rs.a, List.fold(rs.ids, [], |acc, x| List.prepend(acc, x)))
            }
        }

    ## `mkNodeWithoutLookbackPrefix`: the pattern with its leading lookbehind
    ## (already verified by the reverse pass) removed
    without_lookback_prefix : Arena.A, U32 -> Arena.R
    without_lookback_prefix = |a, id|
        match Arena.kind_of(a, id) {
            LookBehind | Begin | End => { a, id: Arena.eps }
            Concat => {
                h = Arena.head(a, id)
                t = Arena.tail(a, id)
                if Arena.is_lookbehind(a, h) {
                    Deriv.without_lookback_prefix(a, t)
                } else {
                    # Deviation from RE#, which also strips through an always-nullable
                    # head (`x*(?<=a)b` -> `x*b`, `_*\A` -> `_*`): only a lookbehind or
                    # anchor at the very start is the one the reverse sweep verified;
                    # after a nullable head it must stay and be judged at its position
                    # (stripping it lets `_*\A` end at 2 on "xa" instead of 0).
                    ch = Deriv.without_lookback_prefix(a, h)
                    if ch.id == Arena.eps { Deriv.without_lookback_prefix(ch.a, t) } else { Build.mk_concat2(ch.a, ch.id, t) }
                }
            }
            Or => {
                rs = Arena.map_ids(a, Arena.children(a, id), Deriv.without_lookback_prefix)
                Build.mk_or(rs.a, Arena.sort_dedup(rs.ids))
            }
            And => {
                rs = Arena.map_ids(a, Arena.children(a, id), Deriv.without_lookback_prefix)
                Build.mk_and(rs.a, Arena.sort_dedup(rs.ids))
            }
            # nothing to strip: the node does not start with a verified prefix
            Singleton | Loop | Not | LookAhead => { a, id }
        }

    ## The node as it stands at the INPUT START, for a match anchored at offset
    ## 0 (`Regex.first_end` / `longest_end`).
    ##
    ## The mirror of `without_lookback_prefix`, and needed for the same reason
    ## read the other way. A search's forward pass may drop the lookbehind
    ## prefix because the reverse sweep verified it at that start; an anchored
    ## match has had no sweep, and the prefix cannot simply be kept either,
    ## because a lookbehind derivative walks its body FORWARD -- keeping it makes
    ## `(?<=ab)cd` match "abcd" at 0. So the prefix is RESOLVED here instead: at
    ## offset 0 a lookbehind holds exactly when its body matches the empty
    ## string there, `\A` holds always, and `\z` is left for the end-of-input
    ## handler to judge.
    ##
    ## As in `without_lookback_prefix`, this does not resolve through a merely
    ## nullable head (`x*(?<=a)b`): only a prefix at the very start is at offset
    ## 0 for certain, and one after a nullable head is judged at its position by
    ## the forward pass, as it is in a search.
    at_input_start : Arena.A, U32 -> Arena.R
    at_input_start = |a, id|
        match Arena.kind_of(a, id) {
            LookBehind => { a, id: if Deriv.nullable(a, Deriv.loc_begin, Arena.head(a, id)) { Arena.eps } else { Arena.bot } }
            Begin => { a, id: Arena.eps }
            Concat => {
                h = Arena.head(a, id)
                t = Arena.tail(a, id)
                ch = Deriv.at_input_start(a, h)
                if ch.id == Arena.bot {
                    { a: ch.a, id: Arena.bot }
                } else if ch.id == Arena.eps {
                    Deriv.at_input_start(ch.a, t)
                } else {
                    Build.mk_concat2(ch.a, ch.id, t)
                }
            }
            Or => {
                rs = Arena.map_ids(a, Arena.children(a, id), Deriv.at_input_start)
                Build.mk_or(rs.a, Arena.sort_dedup(rs.ids))
            }
            And => {
                rs = Arena.map_ids(a, Arena.children(a, id), Deriv.at_input_start)
                Build.mk_and(rs.a, Arena.sort_dedup(rs.ids))
            }
            # nothing to resolve at offset 0; `End` in particular is left for the
            # end-of-input handler, as the doc comment above says
            Singleton | Loop | Not | LookAhead | End => { a, id }
        }
}
