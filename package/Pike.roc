## S5 — the PikeVM, without mutation, now with capture slots (M1.5).
##
## A thread is `{ pc, slots }`; the slot array holds 2·(n_groups+1) byte offsets,
## slot 0/1 being the whole match. `Save` copies the slot array and writes one
## entry (O(slots) per save, small). Membership is `seen`-by-pc; the first thread
## at a pc wins, keeping its slots — which is leftmost-first (S5, S4).
import Comp
import Trie

Pike := [].{
    Th : { pc : U32, slots : List(U64) }
    Cl : { ths : List(Pike.Th), seen : List(U32) }
    M : Try(List(U64), [NoMatch])

    ## Whole-match span, or NoMatch.
    find : Comp.Compiled, List(U8) -> Try({ start : U64, end : U64 }, [NoMatch])
    find = |c, hay|
        match Pike.captures(c, hay) {
            Ok(sl) => Ok({ start: List.get(sl, 0) ?? 0, end: List.get(sl, 1) ?? 0 })
            Err(_) => Err(NoMatch)
        }

    ## The full slot array (2·(n_groups+1) entries). Unset slots are `no_pos`.
    captures : Comp.Compiled, List(U8) -> Pike.M
    captures = |c, hay| {
        len = List.len(hay)
        ns = (c.n_groups.to_u64() + 1) * 2
        Pike.run(c, hay, len, ns, 0, { ths: [], seen: [] }, Err(NoMatch))
    }

    captures_from : Comp.Compiled, List(U8), U64 -> Pike.M
    captures_from = |c, hay, at| {
        len = List.len(hay)
        ns = (c.n_groups.to_u64() + 1) * 2
        Pike.run(c, hay, len, ns, at, { ths: [], seen: [] }, Err(NoMatch))
    }

    ## Anchored: does the pattern match starting exactly at `at`? Seeds one
    ## thread at `at` and never re-seeds, so the match (if any) starts at `at`.
    ## Used by the M4 prefilter, which supplies candidate start positions.
    match_at : Comp.Compiled, List(U8), U64 -> Pike.M
    match_at = |c, hay, at| {
        len = List.len(hay)
        ns = (c.n_groups.to_u64() + 1) * 2
        cl = Pike.add(c, hay, at, len, { ths: [], seen: [] }, { pc: 0, slots: List.repeat(Pike.no_pos, ns) })
        Pike.arun(c, hay, len, at, cl, Err(NoMatch))
    }

    # like run, but never seeds new starts (anchored)
    arun : Comp.Compiled, List(U8), U64, U64, Pike.Cl, Pike.M -> Pike.M
    arun = |c, hay, len, pos, cl, matched| {
        step = Pike.exec(c, hay, pos, len, cl.ths, 0, { ths: [], seen: [] }, matched)
        if pos >= len {
            step.matched
        } else if List.is_empty(step.cl.ths) {
            step.matched
        } else {
            npos = pos + Comp.decode(hay, pos).len
            Pike.arun(c, hay, len, npos, step.cl, step.matched)
        }
    }

    no_pos : U64
    no_pos = 0xFFFF_FFFF_FFFF_FFFF

    run : Comp.Compiled, List(U8), U64, U64, U64, Pike.Cl, Pike.M -> Pike.M
    run = |c, hay, len, ns, pos, cl0, matched| {
        cl =
            match matched {
                Err(_) => Pike.add(c, hay, pos, len, cl0, { pc: 0, slots: List.repeat(Pike.no_pos, ns) })
                Ok(_) => cl0
            }
        step = Pike.exec(c, hay, pos, len, cl.ths, 0, { ths: [], seen: [] }, matched)
        if pos >= len {
            step.matched
        } else if List.is_empty(step.cl.ths) and Pike.settled(step.matched) {
            step.matched
        } else {
            npos = pos + Comp.decode(hay, pos).len
            Pike.run(c, hay, len, ns, npos, step.cl, step.matched)
        }
    }

    settled : Pike.M -> Bool
    settled = |m|
        match m {
            Ok(_) => True
            Err(_) => False
        }

    Step : { cl : Pike.Cl, matched : Pike.M }

    exec : Comp.Compiled, List(U8), U64, U64, List(Pike.Th), U64, Pike.Cl, Pike.M -> Pike.Step
    exec = |c, hay, pos, len, ths, ti, nl, matched|
        match List.get(ths, ti) {
            Err(_) => { cl: nl, matched }
            Ok(th) => {
                w = List.get(c.prog, th.pc.to_u64()) ?? 0
                op = Comp.inst_op(w)
                arg = Comp.inst_arg(w)
                if op == Comp.op_char {
                    if pos < len and Pike.in_set(c.classes, arg, Comp.decode(hay, pos).cp) {
                        npos = pos + Comp.decode(hay, pos).len
                        nl2 = Pike.add(c, hay, npos, len, nl, { pc: th.pc + 1, slots: th.slots })
                        Pike.exec(c, hay, pos, len, ths, ti + 1, nl2, matched)
                    } else {
                        Pike.exec(c, hay, pos, len, ths, ti + 1, nl, matched)
                    }
                } else if op == Comp.op_match {
                    { cl: nl, matched: Ok(th.slots) }
                } else {
                    Pike.exec(c, hay, pos, len, ths, ti + 1, nl, matched)
                }
            }
        }

    add : Comp.Compiled, List(U8), U64, U64, Pike.Cl, Pike.Th -> Pike.Cl
    add = |c, hay, pos, len, cl, th| Pike.close(c, hay, pos, len, cl, [th.pc], th.slots)

    close : Comp.Compiled, List(U8), U64, U64, Pike.Cl, List(U32), List(U64) -> Pike.Cl
    close = |c, hay, pos, len, cl, stack, slots|
        match List.last(stack) {
            Err(_) => cl
            Ok(pc) => {
                rest = List.drop_last(stack, 1)
                if List.contains(cl.seen, pc) {
                    Pike.close(c, hay, pos, len, cl, rest, slots)
                } else {
                    cl2 = { ths: cl.ths, seen: List.append(cl.seen, pc) }
                    w = List.get(c.prog, pc.to_u64()) ?? 0
                    op = Comp.inst_op(w)
                    arg = Comp.inst_arg(w)
                    if op == Comp.op_split {
                        t1 = List.get(c.splits, arg.to_u64()) ?? 0
                        t2 = List.get(c.splits, (arg + 1).to_u64()) ?? 0
                        Pike.close(c, hay, pos, len, cl2, List.concat(rest, [t2, t1]), slots)
                    } else if op == Comp.op_jmp {
                        Pike.close(c, hay, pos, len, cl2, List.append(rest, arg), slots)
                    } else if op == Comp.op_look {
                        if Pike.look_ok(hay, pos, len, arg) {
                            Pike.close(c, hay, pos, len, cl2, List.append(rest, pc + 1), slots)
                        } else {
                            Pike.close(c, hay, pos, len, cl2, rest, slots)
                        }
                    } else if op == Comp.op_save {
                        slots2 = List.set(slots, arg.to_u64(), pos) ?? slots
                        Pike.close(c, hay, pos, len, cl2, List.append(rest, pc + 1), slots2)
                    } else {
                        cl3 = { ths: List.append(cl.ths, { pc, slots }), seen: cl2.seen }
                        Pike.close(c, hay, pos, len, cl3, rest, slots)
                    }
                }
            }
        }

    in_set : Trie.T, U32, U32 -> Bool
    in_set = |t, set_ord, cp| Trie.accepts_atom(t, set_ord, Trie.class_of(t, cp))

    look_ok : List(U8), U64, U64, U32 -> Bool
    look_ok = |hay, pos, len, k|
        if k == Comp.look_start {
            pos == 0
        } else if k == Comp.look_end {
            pos == len
        } else {
            wb = Pike.word_before(hay, pos) != Pike.word_after(hay, pos, len)
            if k == Comp.look_wordb { wb } else { !wb }
        }

    word_after : List(U8), U64, U64 -> Bool
    word_after = |hay, pos, len|
        if pos >= len { False } else { Comp.is_word_cp(Comp.decode(hay, pos).cp) }

    word_before : List(U8), U64 -> Bool
    word_before = |hay, pos|
        if pos == 0 {
            False
        } else {
            start = Pike.cp_start(hay, pos - 1)
            Comp.is_word_cp(Comp.decode(hay, start).cp)
        }

    cp_start : List(U8), U64 -> U64
    cp_start = |hay, i| {
        b = List.get(hay, i) ?? 0
        if b >= 0x80 and b < 0xC0 and i > 0 {
            Pike.cp_start(hay, i - 1)
        } else {
            i
        }
    }
}
