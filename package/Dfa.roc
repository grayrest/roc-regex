## M3 — eager determinization over the codepoint-class alphabet.
##
## A forward DFA for accelerated `is_match`: states are epsilon-closed sets of
## NFA pcs, transitions are keyed by class (the trie's atoms), and the start
## state is folded into every step so the search is unanchored (D2). Built at
## compile time, so it folds into the artifact. Patterns with look assertions
## (`\b ^ $`) and all capture work stay on the PikeVM (D5's reverse pass and
## capture pass are not yet built); determinization refuses them here. A pattern
## whose table would exceed the budget downgrades to the PikeVM (D10).
import Comp
import Trie

Dfa := [].{
    ## dense transition table (row-major: state*n_classes + class -> state+1,
    ## 0 = dead), accepting flags, and the alphabet width.
    T : {
        table : List(U32),
        accept : List(U8),
        n_classes : U32,
        start : U32,
    }

    dead : U32
    dead = 0

    ## Build a DFA, or say why not. `HasLook` -> the PikeVM must handle it;
    ## `TooBig` -> downgrade (D10). `max_states` is `max_artifact_bytes /
    ## (n_classes*4)`.
    build : Comp.Compiled, U64 -> Try(Dfa.T, [HasLook, TooBig])
    build = |c, max_states|
        if Dfa.has_look(c.prog, 0) {
            Err(HasLook)
        } else {
            nc = c.classes.n_classes
            start_set = Dfa.close(c, [0], [])
            r = Dfa.explore(c, nc, max_states, [start_set], { table: [], accept: [], smap: [start_set], next: 1 })
            match r {
                Ok(st) => Ok({ table: st.table, accept: st.accept, n_classes: nc, start: 0 })
                Err(_) => Err(TooBig)
            }
        }

    has_look : List(U32), U64 -> Bool
    has_look = |prog, i|
        match List.get(prog, i) {
            Err(_) => False
            Ok(w) => if Comp.inst_op(w) == Comp.op_look { True } else { Dfa.has_look(prog, i + 1) }
        }

    # BFS over subsets. State `st` carries: table, accept, the discovered
    # pc-sets `smap`, and `next` id. Types are inferred to avoid List(List(U32))
    # in a record-field annotation (unsupported inside the methods block).

    explore : Comp.Compiled, U32, U64, List(List(U32)), _ -> Try(_, [TooBig])
    explore = |c, nc, max_states, work, st|
        match List.first(work) {
            Err(_) => Ok(st)
            Ok(set) => {
                rest = List.drop_first(work, 1)
                if (List.len(st.smap)).to_u64() > max_states {
                    Err(TooBig)
                } else {
                    accept = List.any(set, |pc| Comp.inst_op(List.get(c.prog, pc.to_u64()) ?? 0) == Comp.op_match)
                    start_set = Dfa.close(c, [0], [])
                    r = List.fold(Dfa.upto(nc.to_u64()), { st, work: rest, ids: [] }, |acc, cls| {
                        tset = Dfa.target(c, set, start_set, cls.to_u32_wrap())
                        match Dfa.index_of(acc.st.smap, tset) {
                            Ok(id) => { st: acc.st, work: acc.work, ids: List.append(acc.ids, id + 1) }
                            Err(_) => {
                                nid = acc.st.next
                                { st: { ..acc.st, smap: List.append(acc.st.smap, tset), next: nid + 1 }, work: List.append(acc.work, tset), ids: List.append(acc.ids, nid + 1) }
                            }
                        }
                    })
                    st2 = { ..r.st, table: List.concat(r.st.table, r.ids), accept: List.append(r.st.accept, if accept { 1 } else { 0 }) }
                    Dfa.explore(c, nc, max_states, r.work, st2)
                }
            }
        }

    # target state for one class: advance matching Char threads, always union the
    # start closure back in so the search stays unanchored (never dead).
    target : Comp.Compiled, List(U32), List(U32), U32 -> List(U32)
    target = |c, set, start_set, cls| {
        moved = List.fold(set, [], |m, pc| {
            w = List.get(c.prog, pc.to_u64()) ?? 0
            if Comp.inst_op(w) == Comp.op_char and Trie.accepts_atom(c.classes, Comp.inst_arg(w), cls) {
                List.append(m, pc + 1)
            } else {
                m
            }
        })
        if List.is_empty(moved) {
            start_set
        } else {
            Dfa.close(c, List.concat(moved, [0]), [])
        }
    }

    # epsilon closure over split/jmp/save (look already excluded), sorted+deduped
    close : Comp.Compiled, List(U32), List(U32) -> List(U32)
    close = |c, stack, out|
        match List.last(stack) {
            Err(_) => Dfa.sort_dedup(out)
            Ok(pc) => {
                rest = List.drop_last(stack, 1)
                if List.contains(out, pc) {
                    Dfa.close(c, rest, out)
                } else {
                    out2 = List.append(out, pc)
                    w = List.get(c.prog, pc.to_u64()) ?? 0
                    op = Comp.inst_op(w)
                    arg = Comp.inst_arg(w)
                    if op == Comp.op_split {
                        t1 = List.get(c.splits, arg.to_u64()) ?? 0
                        t2 = List.get(c.splits, (arg + 1).to_u64()) ?? 0
                        Dfa.close(c, List.concat(rest, [t1, t2]), out2)
                    } else if op == Comp.op_jmp {
                        Dfa.close(c, List.append(rest, arg), out2)
                    } else if op == Comp.op_save {
                        Dfa.close(c, List.append(rest, pc + 1), out2)
                    } else {
                        Dfa.close(c, rest, out2)
                    }
                }
            }
        }

    sort_dedup : List(U32) -> List(U32)
    sort_dedup = |xs| {
        sorted = List.sort_with(xs, U32.compare)
        List.fold(sorted, [], |a, x| if (List.last(a) ?? 0xFFFF_FFFF) == x and !List.is_empty(a) { a } else { List.append(a, x) })
    }

    index_of : List(List(U32)), List(U32) -> Try(U32, [NotFound])
    index_of = |sets, target| Dfa.index_loop(sets, target, 0)

    index_loop : List(List(U32)), List(U32), U32 -> Try(U32, [NotFound])
    index_loop = |sets, target, i|
        match List.get(sets, i.to_u64()) {
            Err(_) => Err(NotFound)
            Ok(s) => if s == target { Ok(i) } else { Dfa.index_loop(sets, target, i + 1) }
        }

    upto : U64 -> List(U64)
    upto = |n| Dfa.upto_loop(n, 0, [])
    upto_loop : U64, U64, List(U64) -> List(U64)
    upto_loop = |n, i, acc| if i >= n { acc } else { Dfa.upto_loop(n, i + 1, List.append(acc, i)) }

    ## does the pattern match anywhere? (unanchored, look-free)
    is_match : Dfa.T, Trie.T, List(U8) -> Bool
    is_match = |d, classes, hay| Dfa.run(d, classes, hay, 0, d.start)

    run : Dfa.T, Trie.T, List(U8), U64, U32 -> Bool
    run = |d, classes, hay, pos, state|
        if (List.get(d.accept, state.to_u64()) ?? 0) == 1 {
            True
        } else if pos >= List.len(hay) {
            False
        } else {
            dec = Comp.decode(hay, pos)
            cls = Trie.class_of(classes, dec.cp)
            nxt = List.get(d.table, state.to_u64() * d.n_classes.to_u64() + cls.to_u64()) ?? 0
            if nxt == Dfa.dead {
                Dfa.run(d, classes, hay, pos + dec.len, d.start)
            } else {
                Dfa.run(d, classes, hay, pos + dec.len, nxt - 1)
            }
        }
}
