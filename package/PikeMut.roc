## DORMANT EXPERIMENT — not imported by the library; `Regex.all_caps` uses the
## functional `Pike`. This mutable-buffer engine is CORRECT but, under the
## shipped `--opt=speed` backend, ~2.4× slower than `Pike` (24 vs 10 ms/find_all
## @16 KiB); why is not established (its speed build is too slow to profile).
## Its `--opt=speed` build blows up in Roc's optimization passes (not LLVM;
## dev builds in ~1 s) — a single giant mutable function is atypical Roc code.
## Do NOT trust dev-backend numbers for this: the dev and speed pipelines differ
## by Roc's fold/inline/in-place/specialization passes. See
## notes/2026-09-02-pikemut.md. Wire into `all_caps` to reproduce.
##
## Mutable-buffer PikeVM prototype (allocation-reduction experiment).
##
## `find_all_mut` computes every non-overlapping match in ONE call, allocating
## its working buffers once and reusing them across the whole haystack — both
## across input positions and across match restarts. This is the key difference
## from the functional `Pike` (rebuilds `List`s every step) and from a per-match
## `captures_from` (reallocates its state once per match): here the only
## per-match allocation is the result slot array itself.
##
## Buffers, all preallocated `var`s reused for the entire scan:
##   * two thread queues (clist/nlist): a `pc` list + a flat slot arena
##     (`slot[i*ns .. i*ns+ns)`), so no per-thread `List`s / nested refcounts;
##   * generation-counter dedup sets (`seen[pc] == gen`), cleared by bumping gen;
##   * a reused DFS work-stack for the (inlined) epsilon-closure.
## Sizes are bounded by the program length, so `List.set` never reallocates
## mid-scan (which corrupts aliased buffers under the current backend).
##
## Same leftmost-first + D14 empty-match semantics as `Regex.all_caps`.
## Compared in notes/2026-09-02-pikemut.md.
import Comp
import Trie
import Pike

PikeMut := [].{
    no_pos : U64
    no_pos = 0xFFFF_FFFF_FFFF_FFFF

    sentinel : U64
    sentinel = 0xFFFF_FFFF_FFFF_FFFF

    next_bound : List(U8), U64 -> U64
    next_bound = |hay, p|
        if p >= List.len(hay) { p + 1 } else { p + Comp.decode(hay, p).len }

    ## All non-overlapping match slot arrays, leftmost-first, with D14's
    ## empty-match advance. Buffers allocated once and reused for the whole scan.
    find_all_mut : Comp.Compiled, List(U8) -> List(List(U64))
    find_all_mut = |c, hay| {
        prog = c.prog
        splits = c.splits
        classes = c.classes
        len = List.len(hay)
        plen = List.len(prog)
        ns = (c.n_groups.to_u64() + 1) * 2
        maxth = plen + 1
        maxstk = (plen * 8) + 16

        var cpc = List.repeat(0, maxth)
        var cslot = List.repeat(PikeMut.no_pos, maxth * ns)
        var ccn = 0
        var cseen = List.repeat(0, plen)
        var cgen = 0
        var npc = List.repeat(0, maxth)
        var nslot = List.repeat(PikeMut.no_pos, maxth * ns)
        var ncn = 0
        var nseen = List.repeat(0, plen)
        var ngen = 0
        var stk = List.repeat(0, maxstk)
        var sc = 0
        var dslots = List.repeat(PikeMut.no_pos, ns)

        var results = []
        var last_end = PikeMut.sentinel
        var at = 0
        var scanning = True

        while scanning {
            if at > len {
                scanning = False
            } else {
                # ---- one leftmost-first search starting at `at`, reusing buffers ----
                ccn = 0
                cgen = cgen + 1
                var matched = Err(NoMatch)
                var have = False
                var pos = at
                var running = True

                while running {
                    dlen = if pos < len { Comp.decode(hay, pos).len } else { 1 }
                    cp_here = if pos < len { Comp.decode(hay, pos).cp } else { 0 }

                    # seed a start thread into CLIST at pos, until matched
                    if have == False {
                        var jr = 0
                        while jr < ns {
                            dslots = List.set(dslots, jr, PikeMut.no_pos) ?? dslots
                            jr = jr + 1
                        }
                        stk = List.set(stk, sc, 0) ?? stk
                        sc = sc + 1
                        var going = True
                        while going {
                            if sc == 0 {
                                going = False
                            } else {
                                sc = sc - 1
                                p = List.get(stk, sc) ?? 0
                                pu = p.to_u64()
                                if (List.get(cseen, pu) ?? 0) == cgen {
                                    {}
                                } else {
                                    cseen = List.set(cseen, pu, cgen) ?? cseen
                                    w = List.get(prog, pu) ?? 0
                                    op = Comp.inst_op(w)
                                    arg = Comp.inst_arg(w)
                                    if op == Comp.op_split {
                                        t1 = List.get(splits, arg.to_u64()) ?? 0
                                        t2 = List.get(splits, (arg + 1).to_u64()) ?? 0
                                        stk = List.set(stk, sc, t2) ?? stk
                                        sc = sc + 1
                                        stk = List.set(stk, sc, t1) ?? stk
                                        sc = sc + 1
                                    } else if op == Comp.op_jmp {
                                        stk = List.set(stk, sc, arg) ?? stk
                                        sc = sc + 1
                                    } else if op == Comp.op_look {
                                        if Pike.look_ok(hay, pos, len, arg) {
                                            stk = List.set(stk, sc, p + 1) ?? stk
                                            sc = sc + 1
                                        } else {
                                            {}
                                        }
                                    } else if op == Comp.op_save {
                                        dslots = List.set(dslots, arg.to_u64(), pos) ?? dslots
                                        stk = List.set(stk, sc, p + 1) ?? stk
                                        sc = sc + 1
                                    } else {
                                        cpc = List.set(cpc, ccn, p) ?? cpc
                                        base = ccn * ns
                                        var jw = 0
                                        while jw < ns {
                                            cslot = List.set(cslot, base + jw, List.get(dslots, jw) ?? PikeMut.no_pos) ?? cslot
                                            jw = jw + 1
                                        }
                                        ccn = ccn + 1
                                    }
                                }
                            }
                        }
                    } else {
                        {}
                    }

                    # clear NLIST for this step
                    ncn = 0
                    ngen = ngen + 1

                    var i = 0
                    var cut = False
                    while (i < ccn) and (cut == False) {
                        p = List.get(cpc, i) ?? 0
                        w = List.get(prog, p.to_u64()) ?? 0
                        op = Comp.inst_op(w)
                        if op == Comp.op_match {
                            mbase = i * ns
                            var res = []
                            var jm = 0
                            while jm < ns {
                                res = List.append(res, List.get(cslot, mbase + jm) ?? PikeMut.no_pos)
                                jm = jm + 1
                            }
                            matched = Ok(res)
                            have = True
                            cut = True
                        } else {
                            arg = Comp.inst_arg(w)
                            if pos < len and Pike.in_set(classes, arg, cp_here) {
                                cbase = i * ns
                                var jl = 0
                                while jl < ns {
                                    dslots = List.set(dslots, jl, List.get(cslot, cbase + jl) ?? PikeMut.no_pos) ?? dslots
                                    jl = jl + 1
                                }
                                stk = List.set(stk, sc, p + 1) ?? stk
                                sc = sc + 1
                                var going2 = True
                                npos = pos + dlen
                                while going2 {
                                    if sc == 0 {
                                        going2 = False
                                    } else {
                                        sc = sc - 1
                                        q = List.get(stk, sc) ?? 0
                                        qu = q.to_u64()
                                        if (List.get(nseen, qu) ?? 0) == ngen {
                                            {}
                                        } else {
                                            nseen = List.set(nseen, qu, ngen) ?? nseen
                                            w2 = List.get(prog, qu) ?? 0
                                            op2 = Comp.inst_op(w2)
                                            arg2 = Comp.inst_arg(w2)
                                            if op2 == Comp.op_split {
                                                u1 = List.get(splits, arg2.to_u64()) ?? 0
                                                u2 = List.get(splits, (arg2 + 1).to_u64()) ?? 0
                                                stk = List.set(stk, sc, u2) ?? stk
                                                sc = sc + 1
                                                stk = List.set(stk, sc, u1) ?? stk
                                                sc = sc + 1
                                            } else if op2 == Comp.op_jmp {
                                                stk = List.set(stk, sc, arg2) ?? stk
                                                sc = sc + 1
                                            } else if op2 == Comp.op_look {
                                                if Pike.look_ok(hay, npos, len, arg2) {
                                                    stk = List.set(stk, sc, q + 1) ?? stk
                                                    sc = sc + 1
                                                } else {
                                                    {}
                                                }
                                            } else if op2 == Comp.op_save {
                                                dslots = List.set(dslots, arg2.to_u64(), npos) ?? dslots
                                                stk = List.set(stk, sc, q + 1) ?? stk
                                                sc = sc + 1
                                            } else {
                                                npc = List.set(npc, ncn, q) ?? npc
                                                nbase = ncn * ns
                                                var jw2 = 0
                                                while jw2 < ns {
                                                    nslot = List.set(nslot, nbase + jw2, List.get(dslots, jw2) ?? PikeMut.no_pos) ?? nslot
                                                    jw2 = jw2 + 1
                                                }
                                                ncn = ncn + 1
                                            }
                                        }
                                    }
                                }
                            } else {
                                {}
                            }
                        }
                        i = i + 1
                    }

                    if pos >= len {
                        running = False
                    } else if ncn == 0 and have {
                        running = False
                    } else {
                        tpc = cpc
                        cpc = npc
                        npc = tpc
                        tslot = cslot
                        cslot = nslot
                        nslot = tslot
                        tcn = ccn
                        ccn = ncn
                        ncn = tcn
                        tseen = cseen
                        cseen = nseen
                        nseen = tseen
                        tgen = cgen
                        cgen = ngen
                        ngen = tgen
                        pos = pos + dlen
                    }
                }

                # ---- fold the leftmost match into results (D14 advance) ----
                match matched {
                    Err(_) => {
                        scanning = False
                    }
                    Ok(slots) => {
                        s = List.get(slots, 0) ?? 0
                        e = List.get(slots, 1) ?? 0
                        if s == e and e == last_end {
                            at = PikeMut.next_bound(hay, e)
                        } else {
                            results = List.append(results, slots)
                            last_end = e
                            at = if s == e { PikeMut.next_bound(hay, e) } else { e }
                        }
                    }
                }
            }
        }
        results
    }
}
