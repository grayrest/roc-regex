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
import Bset
import Build
import Deriv
import Dfa
import Rlit
import TSet
import Trie
import Utf8

Accel := [].{
    T : {
        init : Dfa.Init,
        len : Dfa.Len,
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
        sp0 = Accel.set_prefix(e, t, sets, rev_ts)
        sp =
            match sp0.init {
                NoInit => { e: sp0.e, init: Accel.potential_start(t, Accel.potential_sets(sp0.e.a, rev), sp0.e.s_rev_ts) }
                _ => sp0
            }
        ll = Accel.infer_len(sp.e, t, noprefix)
        len = ll.len
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
        { e: ll.e, accel: { init: sp.init, len, override } }
    }

    # --- LengthLookup (RE#'s `inferLengthLookup`) -------------------------------------

    ## `getFixedPrefixLength`: how many leading symbols of `node` have a fixed
    ## length, and what remains after them (lookarounds and anchors count as
    ## zero and drop out; a bounded loop `x{lo,hi}` contributes `lo` and leaves
    ## `x{0,hi-lo}`)
    FP : { a : Arena.A, len : Try(U32, [NoLen]), rem : Try(U32, [NoRem]) }

    fixed_prefix : Arena.A, U32, U32 -> Accel.FP
    fixed_prefix = |a, acc, node| {
        k = Arena.kind(a, node)
        if node == Arena.eps {
            { a, len: Ok(acc), rem: Err(NoRem) }
        } else if k == Arena.k_concat {
            h = Arena.head(a, node)
            tl = Arena.tail(a, node)
            hp = Accel.fixed_prefix(a, acc, h)
            match (hp.len, hp.rem) {
                (Ok(n), Err(_)) => Accel.fixed_prefix(hp.a, n, tl)
                (Ok(n), Ok(r)) => {
                    c = Build.mk_concat2(hp.a, r, tl)
                    { a: c.a, len: Ok(n), rem: Ok(c.id) }
                }
                _ => if acc == 0 { { a: hp.a, len: Err(NoLen), rem: Err(NoRem) } } else { { a: hp.a, len: Ok(acc), rem: Ok(node) } }
            }
        } else if k == Arena.k_singleton {
            { a, len: Ok(1 + acc), rem: Err(NoRem) }
        } else if k == Arena.k_loop {
            body = Arena.head(a, node)
            lo = Arena.loop_lo(a, node)
            hi = Arena.loop_hi(a, node)
            if Arena.is_singleton(a, body) and lo == hi {
                { a, len: Ok(lo + acc), rem: Err(NoRem) }
            } else if Arena.is_singleton(a, body) and lo != 0 {
                l = Build.mk_loop(a, body, 0, if hi == Arena.inf { hi } else { hi - lo })
                { a: l.a, len: Ok(lo + acc), rem: Ok(l.id) }
            } else {
                { a, len: Err(NoLen), rem: Ok(node) }
            }
        } else if k == Arena.k_lookahead or k == Arena.k_lookbehind or k == Arena.k_begin or k == Arena.k_end {
            { a, len: Ok(acc), rem: Err(NoRem) }
        } else {
            # Or, And, Not
            { a, len: Err(NoLen), rem: Ok(node) }
        }
    }

    ## `inferLengthLookup` for the forward pattern `noprefix`
    infer_len : Dfa.E, Trie.T, U32 -> { e : Dfa.E, len : Dfa.Len }
    infer_len = |e, t, noprefix|
        match Arena.fixed_len(e.a, noprefix) {
            Ok(n) => { e, len: FixedLength(n) }
            Err(_) => {
                fp = Accel.fixed_prefix(e.a, 0, noprefix)
                match (fp.len, fp.rem) {
                    (Ok(plen), Ok(rem)) => {
                        e1 = { ..e, a: fp.a }
                        st = Dfa.get_state(e1, rem, False)
                        e2 = st.e
                        a = e2.a
                        body = Arena.head(a, rem)
                        if Arena.is_loop(a, rem) and Arena.loop_lo(a, rem) == 0 and Arena.is_singleton(a, body) and Arena.loop_hi(a, rem) <= 255 and TSet.count(Arena.tset(a, body)) == 1 {
                            { e: e2, len: RemainingSets(plen, TSet.lowest(Arena.tset(a, body)), Arena.loop_hi(a, rem)) }
                        } else {
                            # one live derivative `der`, always nullable, whose own derivatives all die.
                            # Deviation from RE#: minterms that kill `rem` (→ bot) are ignored here — on
                            # our alphabet the `Invalid` class kills every negated class, so `[^,]*,`
                            # would never qualify. Sound because a recorded start guarantees a match
                            # exists, so no killing symbol can precede the terminator.
                            d1 = Accel.derivs_merged(a, rem, [noprefix, rem])
                            fallback = { e: { ..e2, a: d1.a }, len: PrefixEnd(plen, st.id) }
                            # (and only when the remainder itself is not nullable: otherwise a
                            # killing symbol ends the match right there, before any terminator)
                            match List.drop_if(d1.pairs, |(_, x)| x == Arena.bot) {
                                [(mt, der)] if Arena.is_always_null(d1.a, der) and TSet.count(mt) == 1 and !Arena.can_be_null(d1.a, rem) => {
                                    # `der` must be a dead end: EVERY minterm kills it. RE# excludes
                                    # derivatives back to `rem`/`der` here, which the bot-dropping above
                                    # would make unsound (`a.*c`: `.*c|()` steps back to `.*c` on most
                                    # symbols and the match goes on to the last `c`).
                                    d2 = Accel.derivs_merged(d1.a, der, [])
                                    e3 = { ..e2, a: d2.a }
                                    match d2.pairs {
                                        [(_, x)] if x == Arena.bot => {
                                            ds = Dfa.get_state(e3, der, False)
                                            nk = Dfa.nk(ds.e, ds.id)
                                            skips = (List.get(ds.e.skip_ok, ds.id.to_u64()) ?? 0) == 1
                                            if nk != Dfa.nk_pending and !skips {
                                                c = TSet.lowest(mt)
                                                bytes = List.keep_if(Arena.upto(128), |b| (List.get(t.ascii, b) ?? 0) == c) |> List.map(|b| b.to_u8_wrap())
                                                { e: ds.e, len: SetLookup(plen, c, nk, Bset.table(bytes)) }
                                            } else {
                                                { e: ds.e, len: PrefixEnd(plen, st.id) }
                                            }
                                        }
                                        _ => { e: e3, len: PrefixEnd(plen, st.id) }
                                    }
                                }
                                _ => fallback
                            }
                        }
                    }
                    _ => { e: { ..e, a: fp.a }, len: MatchEnd }
                }
            }
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

    ## Search the rarest set (a single ASCII byte, or a `Bset` table), verify the
    ## others, land in the state `_*·rev` reaches after the whole prefix
    ## (`applyPrefixSetsChecked`). Needs two or more sets: a single set is what
    ## the initial state's own skip set already does.
    set_prefix : Dfa.E, Trie.T, List(U64), U32 -> { e : Dfa.E, init : Dfa.Init }
    set_prefix = |e, t, sets, rev_ts|
        match Accel.pick_anchor(t, sets) {
            Err(_) => { e, init: NoInit }
            Ok(_) if List.len(sets) < 2 => { e, init: NoInit }
            # a set anchor on the first symbol is the initial state's own skip set
            # with verification and a landing added: measured slower (`[0-9]{2,4}`)
            Ok(anchor) if anchor.i == 0 and anchor.single == False => { e, init: NoInit }
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
                    { e: st.e, init: Prefix({ sets, anchor: anchor.i, single: anchor.single, anchor_byte: anchor.b, anchor_tab: anchor.tab, state: st.id, land: True }) }
                }
            }
        }

    ## RE#'s `calcPotentialMatchStart`: when no exact prefix applies, the union
    ## of first sets over ALL live derivatives at each depth (until one can be
    ## nullable, 200 nodes or 20 sets). An occurrence marks where a match MAY
    ## start; the sweep resumes at its end in the initial state.
    potential_sets : Arena.A, U32 -> List(U64)
    potential_sets = |a, start| {
        p = Accel.prefix_node(a, start)
        Accel.potential_loop(p.a, [p.id], [Arena.bot, start], [])
    }

    potential_loop : Arena.A, List(U32), List(U32), List(U64) -> List(U64)
    potential_loop = |a, nodes, redundant, acc|
        if List.is_empty(nodes) or List.len(nodes) > 200 or List.len(acc) >= 20 or List.any(nodes, |n| Arena.can_be_null(a, n)) {
            acc
        } else {
            r = List.fold(nodes, { a, ss: 0, next: [] }, |st, n| {
                d = Accel.derivs_merged(st.a, n, redundant)
                List.fold(d.pairs, { ..st, a: d.a }, |st2, (mt, der)| {
                    { ..st2, ss: TSet.union(st2.ss, mt), next: if List.contains(st2.next, der) { st2.next } else { List.append(st2.next, der) } }
                })
            })
            Accel.potential_loop(r.a, r.next, redundant, List.append(acc, r.ss))
        }

    ## the potential-start accelerator, when the sets have a rare one and are
    ## not just a head (RE#'s `useOnlyHead`: the initial skip set covers that)
    potential_start : Trie.T, List(U64), U32 -> Dfa.Init
    potential_start = |t, sets, rev_ts_state|
        if List.len(sets) < 2 {
            NoInit
        } else {
            match Accel.pick_anchor(t, sets) {
                Err(_) => NoInit
                Ok(anchor) =>
                    # RE#'s `useOnlyHead`, sharpened: the initial state's skip set already
                    # jumps to the first set with no verification, so an occurrence check
                    # only pays when a later set is clearly rarer than the first
                    if anchor.i == 0 or anchor.w * 2 > Bset.weight(Accel.ascii_bytes(t, List.get(sets, 0) ?? 0)) {
                        NoInit
                    } else {
                        Potential({ sets, anchor: anchor.i, single: anchor.single, anchor_byte: anchor.b, anchor_tab: anchor.tab, state: rev_ts_state, land: False })
                    }
            }
        }

    # the ASCII bytes of a minterm set
    ascii_bytes : Trie.T, U64 -> List(U8)
    ascii_bytes = |t, s| List.keep_if(Arena.upto(128), |b| TSet.contains(s, List.get(t.ascii, b) ?? 0)) |> List.map(|b| b.to_u8_wrap())

    Anchor : { i : U64, single : Bool, b : U8, tab : List(U8), w : U64 }

    # the rarest set by RE#'s commonality weight, skipping sets too common to
    # search for; a single ASCII codepoint uses the byte kernel
    pick_anchor : Trie.T, List(U64) -> Try(Accel.Anchor, [NoAnchor])
    pick_anchor = |t, sets|
        List.fold_with_index(sets, Err(NoAnchor), |best, s, i| {
            bytes = Accel.ascii_bytes(t, s)
            if Bset.too_common(bytes) or TSet.contains(s, t.invalid) {
                best
            } else {
                w = Bset.weight(bytes)
                cand =
                    match Accel.single_cp(t, s) {
                        Ok(cp) if cp < 0x80 => { i, single: True, b: cp.to_u8_wrap(), tab: [], w }
                        _ => { i, single: False, b: 0, tab: Bset.table(bytes), w }
                    }
                match best {
                    Ok(bb) => if w < bb.w { Ok(cand) } else { best }
                    Err(_) => Ok(cand)
                }
            }
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
