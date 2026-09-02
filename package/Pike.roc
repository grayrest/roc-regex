## S5 — the PikeVM, without mutation.
##
## The thread list is an insertion-ordered `List({ pc, start })`; membership is a
## `seen` list of pcs, which replaces Rust's sparse-set index. Epsilon closure is
## an explicit worklist (a `List(U32)` stack), never recursion, so a deeply
## nested pattern cannot overflow the stack. Preference order is positional:
## threads earlier in the list win, which gives leftmost-first (S5, S4).
import Comp

Pike := [].{
    Th : { pc : U32, start : U64 }
    Cl : { ths : List(Pike.Th), seen : List(U32) }

    ## Leftmost-first search. Returns the byte span of the leftmost match, or
    ## `NoMatch`. `find` and `is_match` (Regex) are thin wrappers.
    find : Comp.Prog, List(U8) -> Try({ start : U64, end : U64 }, [NoMatch])
    find = |prog, hay| {
        len = List.len(hay)
        Pike.run(prog, hay, len, 0, { ths: [], seen: [] }, Err(NoMatch))
    }

    run : Comp.Prog, List(U8), U64, U64, Pike.Cl, Try({ start : U64, end : U64 }, [NoMatch]) -> Try({ start : U64, end : U64 }, [NoMatch])
    run = |prog, hay, len, pos, cl0, matched| {
        # seed a new start thread at this position while no match yet
        cl =
            match matched {
                Err(_) => Pike.add(prog, hay, pos, len, cl0, { pc: 0, start: pos })
                Ok(_) => cl0
            }
        step = Pike.exec(prog, hay, pos, len, cl.ths, 0, { ths: [], seen: [] }, matched)
        next_pos =
            if pos >= len {
                pos
            } else {
                pos + Comp.decode(hay, pos).len
            }
        if pos >= len {
            step.matched
        } else if List.is_empty(step.cl.ths) and Pike.done(step.matched) {
            step.matched
        } else {
            Pike.run(prog, hay, len, next_pos, step.cl, step.matched)
        }
    }

    done : Try({ start : U64, end : U64 }, [NoMatch]) -> Bool
    done = |m|
        match m {
            Ok(_) => True
            Err(_) => False
        }

    # run the current thread list against the symbol at `pos`, building the next
    Step : { cl : Pike.Cl, matched : Try({ start : U64, end : U64 }, [NoMatch]) }

    exec : Comp.Prog, List(U8), U64, U64, List(Pike.Th), U64, Pike.Cl, Try({ start : U64, end : U64 }, [NoMatch]) -> Pike.Step
    exec = |prog, hay, pos, len, ths, ti, nl, matched|
        match List.get(ths, ti) {
            Err(_) => { cl: nl, matched }
            Ok(th) => {
                w = List.get(prog.prog, th.pc.to_u64()) ?? 0
                op = Comp.inst_op(w)
                arg = Comp.inst_arg(w)
                if op == Comp.op_char {
                    if pos < len and Pike.in_set(prog, arg, Comp.decode(hay, pos).cp) {
                        npos = pos + Comp.decode(hay, pos).len
                        nl2 = Pike.add(prog, hay, npos, len, nl, { pc: th.pc + 1, start: th.start })
                        Pike.exec(prog, hay, pos, len, ths, ti + 1, nl2, matched)
                    } else {
                        Pike.exec(prog, hay, pos, len, ths, ti + 1, nl, matched)
                    }
                } else if op == Comp.op_match {
                    # leftmost-first: this thread wins, discard the rest
                    { cl: nl, matched: Ok({ start: th.start, end: pos }) }
                } else {
                    Pike.exec(prog, hay, pos, len, ths, ti + 1, nl, matched)
                }
            }
        }

    # epsilon closure: add a thread and everything reachable by split/jmp/look
    add : Comp.Prog, List(U8), U64, U64, Pike.Cl, Pike.Th -> Pike.Cl
    add = |prog, hay, pos, len, cl, th| Pike.close(prog, hay, pos, len, cl, [th.pc], th.start)

    close : Comp.Prog, List(U8), U64, U64, Pike.Cl, List(U32), U64 -> Pike.Cl
    close = |prog, hay, pos, len, cl, stack, start|
        match List.last(stack) {
            Err(_) => cl
            Ok(pc) => {
                rest = List.drop_last(stack, 1)
                if List.contains(cl.seen, pc) {
                    Pike.close(prog, hay, pos, len, cl, rest, start)
                } else {
                    cl2 = { ths: cl.ths, seen: List.append(cl.seen, pc) }
                    w = List.get(prog.prog, pc.to_u64()) ?? 0
                    op = Comp.inst_op(w)
                    arg = Comp.inst_arg(w)
                    if op == Comp.op_split {
                        t1 = List.get(prog.splits, arg.to_u64()) ?? 0
                        t2 = List.get(prog.splits, (arg + 1).to_u64()) ?? 0
                        # push t2 then t1 so t1 (higher priority) pops first
                        Pike.close(prog, hay, pos, len, cl2, List.concat(rest, [t2, t1]), start)
                    } else if op == Comp.op_jmp {
                        Pike.close(prog, hay, pos, len, cl2, List.append(rest, arg), start)
                    } else if op == Comp.op_look {
                        if Pike.look_ok(hay, pos, len, arg) {
                            Pike.close(prog, hay, pos, len, cl2, List.append(rest, pc + 1), start)
                        } else {
                            Pike.close(prog, hay, pos, len, cl2, rest, start)
                        }
                    } else {
                        # char or match: a real thread
                        cl3 = { ths: List.append(cl.ths, { pc, start }), seen: cl2.seen }
                        Pike.close(prog, hay, pos, len, cl3, rest, start)
                    }
                }
            }
        }

    in_set : Comp.Prog, U32, U32 -> Bool
    in_set = |prog, idx, cp| {
        i = idx.to_u64()
        negw = List.get(prog.sets, i) ?? 0
        count = (List.get(prog.sets, i + 1) ?? 0).to_u64()
        hit = Pike.scan_ranges(prog.sets, i + 2, count, cp)
        if negw == 1 { !hit } else { hit }
    }

    scan_ranges : List(U32), U64, U64, U32 -> Bool
    scan_ranges = |sets, at, count, cp|
        if count == 0 {
            False
        } else {
            lo = List.get(sets, at) ?? 0
            hi = List.get(sets, at + 1) ?? 0
            if cp >= lo and cp <= hi {
                True
            } else {
                Pike.scan_ranges(sets, at + 2, count - 1, cp)
            }
        }

    # look assertions (M1): ^ $ \b \B
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

    # walk back over UTF-8 continuation bytes to the start of the codepoint
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
