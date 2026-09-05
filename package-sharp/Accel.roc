## Accelerators derived from the node graph (S13, RE#'s `Optimizations.fs`),
## computed at compile time after the rewrites, so they see through `&`/`~`.
##
## - `init`: RE#'s `InitialAccelerator.StringPrefix` — `calcPrefixSets` walks
##   derivatives of the reverse pattern while exactly one non-dead derivative
##   exists; when every set on that path is a single codepoint, the reverse
##   sweep can `rfind` the literal from its start state and land in the state
##   the prefix leads to.
## - `len`: RE#'s `LengthLookup.FixedLength` — every match has the same length
##   (in symbols), so the forward end pass is unnecessary.
## - `override`: RE#'s `MatchOverride.FixedLengthString` — the pattern IS a
##   literal, so `find_all` is a literal search.
import Arena
import Build
import Deriv
import Dfa
import Rlit
import TSet
import Trie
import Utf8

Accel := [].{
    T : {
        init : [NoInit, Prefix(Rlit.Prefix)],
        len : [MatchEnd, FixedLength(U32)],
        override : [NoOverride, Literal(List(U8))],
    }

    none : Accel.T
    none = { init: NoInit, len: MatchEnd, override: NoOverride }

    R : { e : Dfa.E, accel : Accel.T }

    ## Analyze the pattern: `root` is the raw pattern, `rev` its reverse,
    ## `rev_ts` `_*·rev`, `noprefix` the forward pattern. May create the prefix's
    ## landing state.
    analyze : Dfa.E, Trie.T, U32, U32, U32, U32 -> Accel.R
    analyze = |e, t, root, rev, rev_ts, noprefix| {
        a = e.a
        sets = Accel.prefix_sets(a, rev)
        sp = Accel.set_prefix(e, t, sets, rev_ts)
        len =
            match Arena.fixed_len(sp.e.a, noprefix) {
                Ok(n) => FixedLength(n)
                Err(_) => MatchEnd
            }
        # the pattern is exactly a literal (RE#'s `inferOverrideRegex`, which looks
        # at the RAW pattern: a lookbehind stripped from `noprefix` still rules it out)
        override =
            match (Accel.literal_of(t, sets), len) {
                (Ok(lit), FixedLength(n)) =>
                    if n.to_u64() == List.len(sets) and !Arena.depends_anchor(sp.e.a, root) and !Arena.contains_look(sp.e.a, root) and !Arena.depends_anchor(sp.e.a, rev) {
                        Literal(lit)
                    } else {
                        NoOverride
                    }
                _ => NoOverride
            }
        { e: sp.e, accel: { init: sp.init, len, override } }
    }

    # the prefix as forward literal bytes, when every set is one codepoint
    literal_of : Trie.T, List(U64) -> Try(List(U8), [NotLiteral])
    literal_of = |t, sets|
        if List.is_empty(sets) {
            Err(NotLiteral)
        } else {
            cps = List.map(sets, |s| Accel.single_cp(t, s))
            if List.any(cps, |c| c == Err(NotSingle)) {
                Err(NotLiteral)
            } else {
                Ok(List.fold_rev(cps, [], |c, acc| match c { Ok(cp) => List.concat(acc, Utf8.encode(cp)), Err(_) => acc }))
            }
        }

    count_cps : List(U8) -> U64
    count_cps = |b| List.count_if(b, |x| x < 0x80 or x >= 0xC0)

    # --- calcPrefixSets --------------------------------------------------------------

    ## `getPrefixNode`: strip what does not constrain the first symbols
    prefix_node : Arena.A, U32 -> Arena.R
    prefix_node = |a, id| {
        k = Arena.kind(a, id)
        if k == Arena.k_loop {
            n = Arena.loop_lo(a, id)
            Build.mk_loop(a, Arena.head(a, id), n, n)
        } else if k == Arena.k_concat {
            h = Arena.head(a, id)
            t = Arena.tail(a, id)
            if Arena.is_loop(a, h) and Arena.loop_lo(a, h) == 0 and (Arena.loop_hi(a, h) == Arena.inf or Arena.loop_hi(a, h) == 1) {
                Accel.prefix_node(a, t)
            } else if Arena.is_loop(a, h) and Arena.loop_hi(a, h) == Arena.inf {
                n = Arena.loop_lo(a, h)
                l = Build.mk_loop(a, Arena.head(a, h), n, n)
                Build.mk_concat2(l.a, l.id, t)
            } else if Arena.is_or(a, h) {
                cs = List.fold(Arena.children(a, h), { a, ids: [] }, |acc, c| {
                    r = Accel.prefix_node(acc.a, c)
                    { a: r.a, ids: List.append(acc.ids, r.id) }
                })
                o = Build.mk_or_seq(cs.a, cs.ids)
                Build.mk_concat2(o.a, o.id, t)
            } else if Arena.is_lookbehind(a, h) {
                body = Arena.head(a, h)
                if Arena.is_concat(a, body) and Arena.head(a, body) == Arena.top_star {
                    c = Build.mk_concat2(a, Arena.tail(a, body), t)
                    Accel.prefix_node(c.a, c.id)
                } else {
                    c = Build.mk_concat2(a, body, t)
                    Accel.prefix_node(c.a, c.id)
                }
            } else {
                { a, id }
            }
        } else if k == Arena.k_lookahead {
            { a, id: Arena.head(a, id) }
        } else {
            { a, id }
        }
    }

    ## the (minterm set, derivative) pairs of a node, derivatives grouped,
    ## excluding those in `redundant`
    derivs_merged : Arena.A, U32, List(U32) -> { a : Arena.A, pairs : List((U64, U32)) }
    derivs_merged = |a, node, redundant|
        List.fold(Arena.upto(a.nmt.to_u64()), { a, pairs: [] }, |acc, m| {
            d = Deriv.derivative(acc.a, Deriv.loc_center, TSet.bit(m.to_u32_wrap()), node)
            if List.contains(redundant, d.id) {
                { a: d.a, pairs: acc.pairs }
            } else {
                match List.find_first_index(acc.pairs, |(_, id)| id == d.id) {
                    Ok(i) => {
                        (ts, id) = List.get(acc.pairs, i) ?? (0, 0)
                        { a: d.a, pairs: List.set(acc.pairs, i, (ts.bitwise_or(TSet.bit(m.to_u32_wrap())), id)) ?? acc.pairs }
                    }
                    Err(_) => { a: d.a, pairs: List.append(acc.pairs, (TSet.bit(m.to_u32_wrap()), d.id)) }
                }
            }
        })

    ## the minterm sets every match must begin with (reverse-reading order)
    prefix_sets : Arena.A, U32 -> List(U64)
    prefix_sets = |a, start| {
        p = Accel.prefix_node(a, start)
        redundant = [Arena.bot, start, p.id]
        Accel.prefix_loop(p.a, p.id, redundant, [])
    }

    prefix_loop : Arena.A, U32, List(U32), List(U64) -> List(U64)
    prefix_loop = |a, node, redundant, acc|
        if (!List.is_empty(acc) and List.contains(redundant, node)) or Arena.can_be_null(a, node) {
            acc
        } else {
            d = Accel.derivs_merged(a, node, redundant)
            match d.pairs {
                [(mt, der)] => if der == node { [] } else { Accel.prefix_loop(d.a, der, redundant, List.append(acc, mt)) }
                _ => acc
            }
        }

    # --- the prefix accelerator (RE#'s StringPrefix / SearchValuesPrefix) --------------

    ## Search the rarest single-ASCII-codepoint set, verify the others, land in the
    ## state `_*·rev` reaches after the whole prefix (`applyPrefixSetsChecked`).
    set_prefix : Dfa.E, Trie.T, List(U64), U32 -> { e : Dfa.E, init : Dfa.Init }
    set_prefix = |e, t, sets, rev_ts|
        match Accel.pick_anchor(t, sets) {
            Err(_) => { e, init: NoInit }
            Ok(anchor) => {
                # derive `_*·rev` through the prefix; every minterm of a set must agree
                applied = List.fold_until(sets, { a: e.a, id: rev_ts, ok: True }, |acc, s| {
                    ms = List.keep_if(Arena.upto(acc.a.nmt.to_u64()), |m| TSet.contains(s, m.to_u32_wrap()))
                    r = List.fold(ms, { a: acc.a, ids: [] }, |st, m| {
                        d = Deriv.derivative(st.a, Deriv.loc_center, TSet.bit(m.to_u32_wrap()), acc.id)
                        { a: d.a, ids: List.append(st.ids, d.id) }
                    })
                    first = List.get(r.ids, 0) ?? Arena.bot
                    if List.is_empty(r.ids) or !List.all(r.ids, |x| x == first) {
                        Break({ a: r.a, id: acc.id, ok: False })
                    } else {
                        Continue({ a: r.a, id: first, ok: True })
                    }
                })
                if applied.ok == False {
                    { e: { ..e, a: applied.a }, init: NoInit }
                } else {
                    st = Dfa.get_state({ ..e, a: applied.a }, applied.id, False)
                    { e: st.e, init: Prefix({ sets, anchor: anchor.i, anchor_byte: anchor.b, state: st.id }) }
                }
            }
        }

    # the rarest set that is a single ASCII codepoint (RE#'s weighting; ours is
    # `Rlit.rank`); none -> no accelerator (every set "too common")
    pick_anchor : Trie.T, List(U64) -> Try({ i : U64, b : U8 }, [NoAnchor])
    pick_anchor = |t, sets|
        List.fold_with_index(sets, Err(NoAnchor), |best, s, i|
            match Accel.single_cp(t, s) {
                Ok(cp) if cp < 0x80 => {
                    b = cp.to_u8_wrap()
                    match best {
                        Ok(bb) => if Rlit.rank(b) < Rlit.rank(bb.b) { Ok({ i, b }) } else { best }
                        Err(_) => Ok({ i, b })
                    }
                }
                _ => best
            })

    # a minterm set that is exactly one codepoint
    single_cp : Trie.T, U64 -> Try(U32, [NotSingle])
    single_cp = |t, s|
        if TSet.count(s) != 1 or TSet.contains(s, t.invalid) {
            Err(NotSingle)
        } else {
            match Trie.ranges_of(t, TSet.lowest(s)) {
                [r] if r.lo == r.hi => Ok(r.lo)
                _ => Err(NotSingle)
            }
        }
}
