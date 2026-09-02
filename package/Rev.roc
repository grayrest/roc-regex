## D5 — the three-pass span finder: forward DFA for the match end, reverse DFA
## for the start, then (for captures) the PikeVM anchored on the span.
##
## Both DFAs use a leftmost-first determinizer: the epsilon closure keeps NFA
## pcs in priority order and TRUNCATES at the first Match (lower-priority
## alternatives after a match are unreachable). The forward NFA carries a lazy
## dot-star prefix so its DFA is unanchored; the reverse NFA is anchored and run
## backward from the end. Built at compile time via constant folding.
import Comp
import Trie

Rev := [].{
    ## A leftmost DFA: dense table (state*nc + class -> state+1, 0=dead) and a
    ## match flag per state.
    D : { table : List(U32), hit : List(U8), nc : U32 }

    ## Build both DFAs at compile time (folds when the pattern is constant), or
    ## say why not. `HasLook` -> look assertions; `TooBig` -> over budget; either
    ## downgrades to the PikeVM (D10). Store the result in `Regex`'s engine.
    build : Comp.Compiled, U64 -> Try({ fwd : Rev.D, rev : Rev.D }, [HasLook, TooBig])
    build = |c, max_states|
        if Rev.has_look(c.prog, 0) {
            Err(HasLook)
        } else {
            nc = c.classes.n_classes
            match Rev.determinize(c.uprog, c.usplits, c.classes, nc, max_states) {
                Err(_) => Err(TooBig)
                Ok(fwd) =>
                    match Rev.determinize(c.rprog, c.rsplits, c.classes, nc, max_states) {
                        Err(_) => Err(TooBig)
                        Ok(rev) => Ok({ fwd, rev })
                    }
            }
        }

    has_look : List(U32), U64 -> Bool
    has_look = |prog, i|
        match List.get(prog, i) {
            Err(_) => False
            Ok(w) => if Comp.inst_op(w) == Comp.op_look { True } else { Rev.has_look(prog, i + 1) }
        }

    ## Run prebuilt DFAs: leftmost-first span, or NoMatch.
    find : { fwd : Rev.D, rev : Rev.D }, Trie.T, List(U8) -> Try({ start : U64, end : U64 }, [NoMatch])
    find = |d, classes, hay|
        match Rev.run_fwd(d.fwd, classes, hay) {
            Err(_) => Err(NoMatch)
            Ok(end) => Ok({ start: Rev.run_rev(d.rev, classes, hay, end), end })
        }

    ## is_match via the forward DFA (any match-state reachable).
    is_match : Rev.D, Trie.T, List(U8) -> Bool
    is_match = |fwd, classes, hay|
        match Rev.run_fwd(fwd, classes, hay) {
            Ok(_) => True
            Err(_) => False
        }

    # --- leftmost-first determinization ---------------------------------------

    determinize : List(U32), List(U32), Trie.T, U32, U64 -> Try(Rev.D, [TooBig])
    determinize = |prog, splits, classes, nc, max_states| {
        s0 = Rev.close_pri(prog, splits, [0], [])
        match Rev.explore(prog, splits, classes, nc, max_states, [s0], { table: [], hit: [], smap: [s0], next: 1 }) {
            Err(e) => Err(e)
            Ok(st) => Ok({ table: st.table, hit: st.hit, nc })
        }
    }

    explore = |prog, splits, classes, nc, max_states, work, st|
        match List.first(work) {
            Err(_) => Ok(st)
            Ok(set) => {
                rest = List.drop_first(work, 1)
                if (List.len(st.smap)).to_u64() > max_states {
                    Err(TooBig)
                } else {
                is_m = List.any(set, |pc| Comp.inst_op(List.get(prog, pc.to_u64()) ?? 0) == Comp.op_match)
                r = List.fold(Rev.upto(nc.to_u64()), { st, work: rest, ids: [] }, |acc, cls| {
                    tset = Rev.step(prog, splits, classes, set, cls.to_u32_wrap())
                    if List.is_empty(tset) {
                        { st: acc.st, work: acc.work, ids: List.append(acc.ids, 0) }
                    } else {
                        match Rev.index_of(acc.st.smap, tset) {
                            Ok(id) => { st: acc.st, work: acc.work, ids: List.append(acc.ids, id + 1) }
                            Err(_) => {
                                nid = acc.st.next
                                { st: { ..acc.st, smap: List.append(acc.st.smap, tset), next: nid + 1 }, work: List.append(acc.work, tset), ids: List.append(acc.ids, nid + 1) }
                            }
                        }
                    }
                })
                st2 = { ..r.st, table: List.concat(r.st.table, r.ids), hit: List.append(r.st.hit, if is_m { 1 } else { 0 }) }
                Rev.explore(prog, splits, classes, nc, max_states, r.work, st2)
                }
            }
        }

    # advance the Char pcs that accept `cls` (priority order preserved), then
    # epsilon-close with truncation
    step : List(U32), List(U32), Trie.T, List(U32), U32 -> List(U32)
    step = |prog, splits, classes, set, cls| {
        moved = List.fold(set, [], |m, pc| {
            w = List.get(prog, pc.to_u64()) ?? 0
            if Comp.inst_op(w) == Comp.op_char and Trie.accepts_atom(classes, Comp.inst_arg(w), cls) {
                List.append(m, pc + 1)
            } else {
                m
            }
        })
        Rev.close_pri(prog, splits, moved, [])
    }

    # priority-preserving epsilon closure, truncating at (and including) the
    # first Match. `stack` is processed front-to-back (DFS, higher priority
    # first). Returns Char/Match pcs in priority order, deduped keeping first.
    close_pri : List(U32), List(U32), List(U32), List(U32) -> List(U32)
    close_pri = |prog, splits, stack, out|
        match List.first(stack) {
            Err(_) => out
            Ok(pc) => {
                rest = List.drop_first(stack, 1)
                if List.contains(out, pc) {
                    Rev.close_pri(prog, splits, rest, out)
                } else {
                    w = List.get(prog, pc.to_u64()) ?? 0
                    op = Comp.inst_op(w)
                    arg = Comp.inst_arg(w)
                    if op == Comp.op_split {
                        t1 = List.get(splits, arg.to_u64()) ?? 0
                        t2 = List.get(splits, (arg + 1).to_u64()) ?? 0
                        Rev.close_pri(prog, splits, List.concat([t1, t2], rest), out)
                    } else if op == Comp.op_jmp {
                        Rev.close_pri(prog, splits, List.prepend(rest, arg), out)
                    } else if op == Comp.op_save {
                        Rev.close_pri(prog, splits, List.prepend(rest, pc + 1), out)
                    } else if op == Comp.op_match {
                        List.append(out, pc)
                    } else {
                        Rev.close_pri(prog, splits, rest, List.append(out, pc))
                    }
                }
            }
        }

    index_of = |sets, target| Rev.index_loop(sets, target, 0)
    index_loop = |sets, target, i|
        match List.get(sets, i.to_u64()) {
            Err(_) => Err(NotFound)
            Ok(s) => if s == target { Ok(i) } else { Rev.index_loop(sets, target, i + 1) }
        }

    upto : U64 -> List(U64)
    upto = |n| Rev.upto_loop(n, 0, [])
    upto_loop = |n, i, acc| if i >= n { acc } else { Rev.upto_loop(n, i + 1, List.append(acc, i)) }

    # --- searches -------------------------------------------------------------

    run_fwd : Rev.D, Trie.T, List(U8) -> Try(U64, [NoMatch])
    run_fwd = |d, classes, hay| Rev.fwd(d, classes, hay, 0, 0, Err(NoMatch))

    fwd : Rev.D, Trie.T, List(U8), U64, U32, Try(U64, [NoMatch]) -> Try(U64, [NoMatch])
    fwd = |d, classes, hay, pos, state, best| {
        best2 = if (List.get(d.hit, state.to_u64()) ?? 0) == 1 { Ok(pos) } else { best }
        if pos >= List.len(hay) {
            best2
        } else {
            dec = Comp.decode(hay, pos)
            cls = Trie.class_of(classes, dec.cp)
            nxt = List.get(d.table, state.to_u64() * d.nc.to_u64() + cls.to_u64()) ?? 0
            if nxt == 0 {
                best2
            } else {
                Rev.fwd(d, classes, hay, pos + dec.len, nxt - 1, best2)
            }
        }
    }

    # reverse DFA anchored at `end`, stepping backward; the smallest reached
    # position that is a match state is the leftmost start.
    run_rev : Rev.D, Trie.T, List(U8), U64 -> U64
    run_rev = |d, classes, hay, end| Rev.rev(d, classes, hay, end, end, 0, end)

    rev : Rev.D, Trie.T, List(U8), U64, U64, U32, U64 -> U64
    rev = |d, classes, hay, pos, end, state, best| {
        best2 = if (List.get(d.hit, state.to_u64()) ?? 0) == 1 { pos } else { best }
        if pos == 0 {
            best2
        } else {
            cs = Rev.cp_start(hay, pos - 1)
            dec = Comp.decode(hay, cs)
            cls = Trie.class_of(classes, dec.cp)
            nxt = List.get(d.table, state.to_u64() * d.nc.to_u64() + cls.to_u64()) ?? 0
            if nxt == 0 {
                best2
            } else {
                Rev.rev(d, classes, hay, cs, end, nxt - 1, best2)
            }
        }
    }

    cp_start : List(U8), U64 -> U64
    cp_start = |hay, i| {
        b = List.get(hay, i) ?? 0
        if b >= 0x80 and b < 0xC0 and i > 0 { Rev.cp_start(hay, i - 1) } else { i }
    }
}
