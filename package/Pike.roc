## S5 — the PikeVM, without mutation, now with capture slots (M1.5).
##
## A thread is `{ pc, slots }`; the slot array holds 2·(n_groups+1) byte offsets,
## slot 0/1 being the whole match. `Save` copies the slot array and writes one
## entry (O(slots) per save, small). Membership dedup is a generation-stamped
## `visited` array (`visited[pc] == gen` means "already in this thread set"):
## O(1) test, and a new thread set is a `gen += 1` with no reallocation. The
## array is threaded linearly so `List.set` can reuse it in place. The first
## thread at a pc wins, keeping its slots — leftmost-first (S5, S4).
import Comp
import Trie

Pike := [].{
    Th : { pc : U32, slots : List(U64) }
    Cl : { ths : List(Pike.Th), gen : U32 }
    Clv : { cl : Pike.Cl, visited : List(U32) }
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
        visited = List.repeat(0, List.len(c.prog))
        Pike.run(c, hay, len, ns, 0, { ths: [], gen: 1 }, Err(NoMatch), visited)
    }

    captures_from : Comp.Compiled, List(U8), U64 -> Pike.M
    captures_from = |c, hay, at| {
        len = List.len(hay)
        ns = (c.n_groups.to_u64() + 1) * 2
        visited = List.repeat(0, List.len(c.prog))
        Pike.run(c, hay, len, ns, at, { ths: [], gen: 1 }, Err(NoMatch), visited)
    }

    ## Anchored: does the pattern match starting exactly at `at`? Seeds one
    ## thread at `at` and never re-seeds, so the match (if any) starts at `at`.
    ## Used by the M4 prefilter, which supplies candidate start positions.
    match_at : Comp.Compiled, List(U8), U64 -> Pike.M
    match_at = |c, hay, at| {
        len = List.len(hay)
        ns = (c.n_groups.to_u64() + 1) * 2
        visited = List.repeat(0, List.len(c.prog))
        r = Pike.add(c, hay, at, len, { ths: [], gen: 1 }, { pc: 0, slots: List.repeat(Pike.no_pos, ns) }, visited)
        Pike.arun(c, hay, len, at, r.cl, Err(NoMatch), r.visited)
    }

    # like run, but never seeds new starts (anchored)
    arun : Comp.Compiled, List(U8), U64, U64, Pike.Cl, Pike.M, List(U32) -> Pike.M
    arun = |c, hay, len, pos, cl, matched, visited| {
        nl0 = { ths: [], gen: cl.gen + 1 }
        step = Pike.exec(c, hay, pos, len, cl.ths, 0, nl0, matched, visited)
        if pos >= len {
            step.matched
        } else if List.is_empty(step.cl.ths) {
            step.matched
        } else {
            npos = pos + Comp.decode(hay, pos).len
            Pike.arun(c, hay, len, npos, step.cl, step.matched, step.visited)
        }
    }

    no_pos : U64
    no_pos = 0xFFFF_FFFF_FFFF_FFFF

    run : Comp.Compiled, List(U8), U64, U64, U64, Pike.Cl, Pike.M, List(U32) -> Pike.M
    run = |c, hay, len, ns, pos, cl0, matched, visited| {
        seeded =
            match matched {
                Err(_) => Pike.add(c, hay, pos, len, cl0, { pc: 0, slots: List.repeat(Pike.no_pos, ns) }, visited)
                Ok(_) => { cl: cl0, visited }
            }
        nl0 = { ths: [], gen: seeded.cl.gen + 1 }
        step = Pike.exec(c, hay, pos, len, seeded.cl.ths, 0, nl0, matched, seeded.visited)
        if pos >= len {
            step.matched
        } else if List.is_empty(step.cl.ths) and Pike.settled(step.matched) {
            step.matched
        } else {
            npos = pos + Comp.decode(hay, pos).len
            Pike.run(c, hay, len, ns, npos, step.cl, step.matched, step.visited)
        }
    }

    settled : Pike.M -> Bool
    settled = |m|
        match m {
            Ok(_) => True
            Err(_) => False
        }

    Step : { cl : Pike.Cl, matched : Pike.M, visited : List(U32) }

    exec : Comp.Compiled, List(U8), U64, U64, List(Pike.Th), U64, Pike.Cl, Pike.M, List(U32) -> Pike.Step
    exec = |c, hay, pos, len, ths, ti, nl, matched, visited|
        match List.get(ths, ti) {
            Err(_) => { cl: nl, matched, visited }
            Ok(th) => {
                w = List.get(c.prog, th.pc.to_u64()) ?? 0
                op = Comp.inst_op(w)
                arg = Comp.inst_arg(w)
                if op == Comp.op_char {
                    if pos < len and Pike.in_set(c.classes, arg, Comp.decode(hay, pos).cp) {
                        npos = pos + Comp.decode(hay, pos).len
                        r = Pike.add(c, hay, npos, len, nl, { pc: th.pc + 1, slots: th.slots }, visited)
                        Pike.exec(c, hay, pos, len, ths, ti + 1, r.cl, matched, r.visited)
                    } else {
                        Pike.exec(c, hay, pos, len, ths, ti + 1, nl, matched, visited)
                    }
                } else if op == Comp.op_match {
                    { cl: nl, matched: Ok(th.slots), visited }
                } else {
                    Pike.exec(c, hay, pos, len, ths, ti + 1, nl, matched, visited)
                }
            }
        }

    add : Comp.Compiled, List(U8), U64, U64, Pike.Cl, Pike.Th, List(U32) -> Pike.Clv
    add = |c, hay, pos, len, cl, th, visited| Pike.close(c, hay, pos, len, cl, visited, [th.pc], th.slots)

    close : Comp.Compiled, List(U8), U64, U64, Pike.Cl, List(U32), List(U32), List(U64) -> Pike.Clv
    close = |c, hay, pos, len, cl, visited, stack, slots|
        match List.last(stack) {
            Err(_) => { cl, visited }
            Ok(pc) => {
                rest = List.drop_last(stack, 1)
                if (List.get(visited, pc.to_u64()) ?? 0) == cl.gen {
                    Pike.close(c, hay, pos, len, cl, visited, rest, slots)
                } else {
                    visited2 = List.set(visited, pc.to_u64(), cl.gen) ?? visited
                    w = List.get(c.prog, pc.to_u64()) ?? 0
                    op = Comp.inst_op(w)
                    arg = Comp.inst_arg(w)
                    if op == Comp.op_split {
                        t1 = List.get(c.splits, arg.to_u64()) ?? 0
                        t2 = List.get(c.splits, (arg + 1).to_u64()) ?? 0
                        Pike.close(c, hay, pos, len, cl, visited2, List.concat(rest, [t2, t1]), slots)
                    } else if op == Comp.op_jmp {
                        Pike.close(c, hay, pos, len, cl, visited2, List.append(rest, arg), slots)
                    } else if op == Comp.op_look {
                        if Pike.look_ok(hay, pos, len, arg) {
                            Pike.close(c, hay, pos, len, cl, visited2, List.append(rest, pc + 1), slots)
                        } else {
                            Pike.close(c, hay, pos, len, cl, visited2, rest, slots)
                        }
                    } else if op == Comp.op_save {
                        slots2 = List.set(slots, arg.to_u64(), pos) ?? slots
                        Pike.close(c, hay, pos, len, cl, visited2, List.append(rest, pc + 1), slots2)
                    } else {
                        cl3 = { ths: List.append(cl.ths, { pc, slots }), gen: cl.gen }
                        Pike.close(c, hay, pos, len, cl3, visited2, rest, slots)
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
