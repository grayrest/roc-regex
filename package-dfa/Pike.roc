## S5 — the PikeVM, without mutation, now with capture slots (M1.5).
##
## A thread is `{ pc, slots }`; the slot array holds 2·(n_groups+1) byte offsets,
## slot 0/1 being the whole match. `Save` copies the slot array and writes one
## entry (O(slots) per save, small). Membership dedup is a generation-stamped
## `visited` array (`visited[pc] == gen` means "already in this thread set"):
## O(1) test, a new set is `gen += 1`, no reallocation. The closure DFS uses an
## index-based stack (`stack` buffer + `sp` count) rather than allocating
## list slices per step. Both `visited` and `stack` are threaded linearly (never
## bundled) so `List.set` reuses them in place. First thread at a pc wins,
## keeping its slots — leftmost-first (S5, S4).
import Comp
import Trie

Pike := [].{
    Th : { pc : U32, slots : List(U64) }
    Cl : { ths : List(Pike.Th), gen : U32 }
    Clv : { cl : Pike.Cl, visited : List(U32), stack : List(U32) }
    M : Try(List(U64), [NoMatch])

    # Whole-match engine (find / find_all / is_match / prefilter): a thread
    # carries only its start position, no slot list — so there is no per-thread
    # slot allocation at all. `end` is the position where `Match` fires. The
    # capture engine above (slots) is kept for `captures` / `replace` / `split`.
    Span : { start : U64, end : U64 }
    WTh : { pc : U32, start : U64 }
    # a thread queue is a reused `ths` buffer plus a live count `n` (entries
    # 0..n are live; the buffer itself grows only to the high-water mark and is
    # double-buffered across positions).
    WCl : { ths : List(Pike.WTh), n : U64, gen : U32 }
    WM : Try(Pike.Span, [NoMatch])
    WClv : { cl : Pike.WCl, visited : List(U32), stack : List(U32) }
    # `wexec` hands back the built next queue `nl` and the now-free current
    # buffer `cur` so the caller can reuse it as the next step's scratch buffer.
    WStep : { nl : Pike.WCl, cur : List(Pike.WTh), matched : Pike.WM, visited : List(U32), stack : List(U32) }

    ## The full slot array (2·(n_groups+1) entries). Unset slots are `no_pos`.
    captures : Comp.Compiled, List(U8) -> Pike.M
    captures = |c, hay| {
        len = List.len(hay)
        ns = (c.n_groups.to_u64() + 1) * 2
        visited = List.repeat(0, List.len(c.prog))
        Pike.run(c, hay, len, ns, 0, { ths: [], gen: 1 }, Err(NoMatch), visited, [])
    }

    captures_from : Comp.Compiled, List(U8), U64 -> Pike.M
    captures_from = |c, hay, at| {
        len = List.len(hay)
        ns = (c.n_groups.to_u64() + 1) * 2
        visited = List.repeat(0, List.len(c.prog))
        Pike.run(c, hay, len, ns, at, { ths: [], gen: 1 }, Err(NoMatch), visited, [])
    }

    no_pos : U64
    no_pos = 0xFFFF_FFFF_FFFF_FFFF

    run : Comp.Compiled, List(U8), U64, U64, U64, Pike.Cl, Pike.M, List(U32), List(U32) -> Pike.M
    run = |c, hay, len, ns, pos, cl0, matched, visited, stack| {
        seeded =
            match matched {
                Err(_) => Pike.add(c, hay, pos, len, cl0, { pc: 0, slots: List.repeat(Pike.no_pos, ns) }, visited, stack)
                Ok(_) => { cl: cl0, visited, stack }
            }
        nl0 = { ths: [], gen: seeded.cl.gen + 1 }
        step = Pike.exec(c, hay, pos, len, seeded.cl.ths, 0, nl0, matched, seeded.visited, seeded.stack)
        if pos >= len {
            step.matched
        } else if List.is_empty(step.cl.ths) and Pike.settled(step.matched) {
            step.matched
        } else {
            npos = pos + Comp.decode(hay, pos).len
            Pike.run(c, hay, len, ns, npos, step.cl, step.matched, step.visited, step.stack)
        }
    }

    settled : Pike.M -> Bool
    settled = |m|
        match m {
            Ok(_) => True
            Err(_) => False
        }

    Step : { cl : Pike.Cl, matched : Pike.M, visited : List(U32), stack : List(U32) }

    exec : Comp.Compiled, List(U8), U64, U64, List(Pike.Th), U64, Pike.Cl, Pike.M, List(U32), List(U32) -> Pike.Step
    exec = |c, hay, pos, len, ths, ti, nl, matched, visited, stack|
        match List.get(ths, ti) {
            Err(_) => { cl: nl, matched, visited, stack }
            Ok(th) => {
                w = List.get(c.prog, th.pc.to_u64()) ?? 0
                op = Comp.inst_op(w)
                arg = Comp.inst_arg(w)
                if op == Comp.op_char {
                    if pos < len and Pike.in_set(c.classes, arg, Comp.decode(hay, pos).cp) {
                        npos = pos + Comp.decode(hay, pos).len
                        r = Pike.add(c, hay, npos, len, nl, { pc: th.pc + 1, slots: th.slots }, visited, stack)
                        Pike.exec(c, hay, pos, len, ths, ti + 1, r.cl, matched, r.visited, r.stack)
                    } else {
                        Pike.exec(c, hay, pos, len, ths, ti + 1, nl, matched, visited, stack)
                    }
                } else if op == Comp.op_match {
                    { cl: nl, matched: Ok(th.slots), visited, stack }
                } else {
                    Pike.exec(c, hay, pos, len, ths, ti + 1, nl, matched, visited, stack)
                }
            }
        }

    # push v at index i of the reused stack buffer, growing it only at the frontier
    spush : List(U32), U64, U32 -> List(U32)
    spush = |stack, i, v|
        if i < List.len(stack) { List.set(stack, i, v) ?? stack } else { List.append(stack, v) }

    add : Comp.Compiled, List(U8), U64, U64, Pike.Cl, Pike.Th, List(U32), List(U32) -> Pike.Clv
    add = |c, hay, pos, len, cl, th, visited, stack|
        Pike.close(c, hay, pos, len, cl, visited, Pike.spush(stack, 0, th.pc), 1, th.slots)

    close : Comp.Compiled, List(U8), U64, U64, Pike.Cl, List(U32), List(U32), U64, List(U64) -> Pike.Clv
    close = |c, hay, pos, len, cl, visited, stack, sp, slots|
        if sp == 0 {
            { cl, visited, stack }
        } else {
            pc = List.get(stack, sp - 1) ?? 0
            sp1 = sp - 1
            if (List.get(visited, pc.to_u64()) ?? 0) == cl.gen {
                Pike.close(c, hay, pos, len, cl, visited, stack, sp1, slots)
            } else {
                visited2 = List.set(visited, pc.to_u64(), cl.gen) ?? visited
                w = List.get(c.prog, pc.to_u64()) ?? 0
                op = Comp.inst_op(w)
                arg = Comp.inst_arg(w)
                if op == Comp.op_split {
                    t1 = List.get(c.splits, arg.to_u64()) ?? 0
                    t2 = List.get(c.splits, (arg + 1).to_u64()) ?? 0
                    stack2 = Pike.spush(Pike.spush(stack, sp1, t2), sp1 + 1, t1)
                    Pike.close(c, hay, pos, len, cl, visited2, stack2, sp1 + 2, slots)
                } else if op == Comp.op_jmp {
                    Pike.close(c, hay, pos, len, cl, visited2, Pike.spush(stack, sp1, arg), sp1 + 1, slots)
                } else if op == Comp.op_look {
                    if Pike.look_ok(hay, pos, len, arg) {
                        Pike.close(c, hay, pos, len, cl, visited2, Pike.spush(stack, sp1, pc + 1), sp1 + 1, slots)
                    } else {
                        Pike.close(c, hay, pos, len, cl, visited2, stack, sp1, slots)
                    }
                } else if op == Comp.op_save {
                    slots2 = List.set(slots, arg.to_u64(), pos) ?? slots
                    Pike.close(c, hay, pos, len, cl, visited2, Pike.spush(stack, sp1, pc + 1), sp1 + 1, slots2)
                } else {
                    cl3 = { ths: List.append(cl.ths, { pc, slots }), gen: cl.gen }
                    Pike.close(c, hay, pos, len, cl3, visited2, stack, sp1, slots)
                }
            }
        }

    # ---- whole-match engine (start-only payload) ----

    wsettled : Pike.WM -> Bool
    wsettled = |m|
        match m {
            Ok(_) => True
            Err(_) => False
        }

    ## Leftmost-first whole-match span from 0, or NoMatch.
    wfind : Comp.Compiled, List(U8) -> Pike.WM
    wfind = |c, hay| Pike.wfind_from(c, hay, 0)

    ## Leftmost-first whole-match span at or after `at`. Two `ths` buffers
    ## (`cur` and the spare `[]`) are double-buffered across positions.
    wfind_from : Comp.Compiled, List(U8), U64 -> Pike.WM
    wfind_from = |c, hay, at| {
        len = List.len(hay)
        visited = List.repeat(0, List.len(c.prog))
        Pike.wrun(c, hay, len, at, { ths: [], n: 0, gen: 1 }, [], Err(NoMatch), visited, [])
    }

    ## Anchored whole-match: does the pattern match starting exactly at `at`?
    wmatch_at : Comp.Compiled, List(U8), U64 -> Pike.WM
    wmatch_at = |c, hay, at| {
        len = List.len(hay)
        visited = List.repeat(0, List.len(c.prog))
        r = Pike.wadd(c, hay, at, len, { ths: [], n: 0, gen: 1 }, { pc: 0, start: at }, visited, [])
        Pike.warun(c, hay, len, at, r.cl, [], Err(NoMatch), r.visited, r.stack)
    }

    # push a thread at index i of the reused queue buffer (grow only at frontier)
    wpush : List(Pike.WTh), U64, Pike.WTh -> List(Pike.WTh)
    wpush = |ths, i, th|
        if i < List.len(ths) { List.set(ths, i, th) ?? ths } else { List.append(ths, th) }

    # `cur` holds this position's threads; `spare` is the buffer the next queue
    # is built into. After exec, the two swap: the consumed `cur` buffer becomes
    # next position's spare.
    wrun : Comp.Compiled, List(U8), U64, U64, Pike.WCl, List(Pike.WTh), Pike.WM, List(U32), List(U32) -> Pike.WM
    wrun = |c, hay, len, pos, cur, spare, matched, visited, stack| {
        seeded =
            match matched {
                Err(_) => Pike.wadd(c, hay, pos, len, cur, { pc: 0, start: 0 }, visited, stack)
                Ok(_) => { cl: cur, visited, stack }
            }
        nl0 = { ths: spare, n: 0, gen: seeded.cl.gen + 1 }
        step = Pike.wexec(c, hay, pos, len, seeded.cl.ths, seeded.cl.n, 0, nl0, matched, seeded.visited, seeded.stack)
        if pos >= len {
            step.matched
        } else if step.nl.n == 0 and Pike.wsettled(step.matched) {
            step.matched
        } else {
            npos = pos + Comp.decode(hay, pos).len
            Pike.wrun(c, hay, len, npos, step.nl, step.cur, step.matched, step.visited, step.stack)
        }
    }

    # anchored: never re-seeds
    warun : Comp.Compiled, List(U8), U64, U64, Pike.WCl, List(Pike.WTh), Pike.WM, List(U32), List(U32) -> Pike.WM
    warun = |c, hay, len, pos, cur, spare, matched, visited, stack| {
        nl0 = { ths: spare, n: 0, gen: cur.gen + 1 }
        step = Pike.wexec(c, hay, pos, len, cur.ths, cur.n, 0, nl0, matched, visited, stack)
        if pos >= len {
            step.matched
        } else if step.nl.n == 0 {
            step.matched
        } else {
            npos = pos + Comp.decode(hay, pos).len
            Pike.warun(c, hay, len, npos, step.nl, step.cur, step.matched, step.visited, step.stack)
        }
    }

    wexec : Comp.Compiled, List(U8), U64, U64, List(Pike.WTh), U64, U64, Pike.WCl, Pike.WM, List(U32), List(U32) -> Pike.WStep
    wexec = |c, hay, pos, len, cur, cn, ti, nl, matched, visited, stack|
        if ti >= cn {
            { nl, cur, matched, visited, stack }
        } else {
            th = List.get(cur, ti) ?? { pc: 0, start: 0 }
            w = List.get(c.prog, th.pc.to_u64()) ?? 0
            op = Comp.inst_op(w)
            if op == Comp.op_match {
                { nl, cur, matched: Ok({ start: th.start, end: pos }), visited, stack }
            } else {
                arg = Comp.inst_arg(w)
                if pos < len and Pike.in_set(c.classes, arg, Comp.decode(hay, pos).cp) {
                    npos = pos + Comp.decode(hay, pos).len
                    r = Pike.wadd(c, hay, npos, len, nl, { pc: th.pc + 1, start: th.start }, visited, stack)
                    Pike.wexec(c, hay, pos, len, cur, cn, ti + 1, r.cl, matched, r.visited, r.stack)
                } else {
                    Pike.wexec(c, hay, pos, len, cur, cn, ti + 1, nl, matched, visited, stack)
                }
            }
        }

    wadd : Comp.Compiled, List(U8), U64, U64, Pike.WCl, Pike.WTh, List(U32), List(U32) -> Pike.WClv
    wadd = |c, hay, pos, len, cl, th, visited, stack|
        Pike.wclose(c, hay, pos, len, cl, visited, Pike.spush(stack, 0, th.pc), 1, th.start)

    wclose : Comp.Compiled, List(U8), U64, U64, Pike.WCl, List(U32), List(U32), U64, U64 -> Pike.WClv
    wclose = |c, hay, pos, len, cl, visited, stack, sp, start|
        if sp == 0 {
            { cl, visited, stack }
        } else {
            pc = List.get(stack, sp - 1) ?? 0
            sp1 = sp - 1
            if (List.get(visited, pc.to_u64()) ?? 0) == cl.gen {
                Pike.wclose(c, hay, pos, len, cl, visited, stack, sp1, start)
            } else {
                visited2 = List.set(visited, pc.to_u64(), cl.gen) ?? visited
                w = List.get(c.prog, pc.to_u64()) ?? 0
                op = Comp.inst_op(w)
                arg = Comp.inst_arg(w)
                if op == Comp.op_split {
                    t1 = List.get(c.splits, arg.to_u64()) ?? 0
                    t2 = List.get(c.splits, (arg + 1).to_u64()) ?? 0
                    stack2 = Pike.spush(Pike.spush(stack, sp1, t2), sp1 + 1, t1)
                    Pike.wclose(c, hay, pos, len, cl, visited2, stack2, sp1 + 2, start)
                } else if op == Comp.op_jmp {
                    Pike.wclose(c, hay, pos, len, cl, visited2, Pike.spush(stack, sp1, arg), sp1 + 1, start)
                } else if op == Comp.op_look {
                    if Pike.look_ok(hay, pos, len, arg) {
                        Pike.wclose(c, hay, pos, len, cl, visited2, Pike.spush(stack, sp1, pc + 1), sp1 + 1, start)
                    } else {
                        Pike.wclose(c, hay, pos, len, cl, visited2, stack, sp1, start)
                    }
                } else if op == Comp.op_save {
                    start2 = if arg == 0 { pos } else { start }
                    Pike.wclose(c, hay, pos, len, cl, visited2, Pike.spush(stack, sp1, pc + 1), sp1 + 1, start2)
                } else {
                    cl3 = { ths: Pike.wpush(cl.ths, cl.n, { pc, start }), n: cl.n + 1, gen: cl.gen }
                    Pike.wclose(c, hay, pos, len, cl3, visited2, stack, sp1, start)
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
