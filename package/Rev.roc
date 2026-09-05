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
    ## A leftmost DFA: dense table (state*nc + class -> state+1, 0=dead).
    ## `accept_eoi[state]` is the accept flag at end-of-input. `accept_on` is
    ## EMPTY for a look-free DFA (then `accept_eoi` doubles as the per-state match
    ## flag, checked at every position); for a `\b`/`\B` DFA it is populated
    ## per-transition (`accept_on[state*nc + cls]` = a match ends at the position
    ## *before* `cls`), because a boundary adjacent to Match resolves against the
    ## following symbol. `accept_on` non-empty is the "has word boundaries" flag.
    ## `eoi_only` (outermost `$`): the forward scan records a match only at
    ## end-of-input. `anchored` (outermost `^`): the forward `uprog` is anchored
    ## (no dot-star), so a search may only begin at position 0 — `run_fwd_from`
    ## refuses a non-zero start. Both are forward-only (the reverse D leaves them
    ## False).
    ## `atable` is an ASCII-fused transition table (`atable[state*128 + byte]` =
    ## the next state for that ASCII byte, folding the byte->class->next indirection
    ## into one lookup — the hot path for prose). Empty when unfused (word-boundary
    ## DFAs, or a state count over the fuse budget); the scan then falls back to the
    ## class-lookup path.
    D : { table : List(U32), atable : List(U32), accept_on : List(U8), accept_eoi : List(U8), nc : U32, eoi_only : Bool, anchored : Bool }

    # Cap on fused-table size (entries): 128 per state, so this bounds the extra
    # artifact bytes at 256 KB (65536 * 4). Larger DFAs skip the fuse.
    atable_budget : U64
    atable_budget = 65536

    ## Build both DFAs at compile time (folds when the pattern is constant), or
    ## say why not. `HasLook` -> `^`/`$` assertions (still PikeVM); `TooBig` ->
    ## over budget; either downgrades to the PikeVM (D10). `\b`/`\B` are handled
    ## in the determinizer (word boundaries baked into the transition function
    ## over the codepoint alphabet).
    build : Comp.Compiled, U64 -> Try({ fwd : Rev.D, rev : Rev.D, averify : [NoVerify, Verify(Rev.D)], inner : [NoInner, Inner({ lit : List(U8), lrev : Rev.D, full : Rev.D })] }, [HasLook, TooBig])
    build = |c, max_states|
        # `uprog`/`rprog` have outermost `^`/`$` stripped (Comp), so an anchor
        # remaining here is a *buried* one -> bail to the PikeVM.
        if Rev.has_anchor(c.uprog, 0) {
            Err(HasLook)
        } else {
            nc = c.classes.n_classes
            wb = Comp.has_wb(c.uprog, 0)
            det = |prog, splits| if wb { Rev.determinize_wb(prog, splits, c.classes, nc, c.word_set, max_states) } else { Rev.determinize(prog, splits, c.classes, nc, max_states) }
            # Anchored verify DFA for the literal-prefix prefilter: `c.prog`
            # (Save0·body·Save1·Match) is already the anchored forward NFA (no
            # dot-star), so determinizing it gives a DFA that, run from a candidate
            # position, matches iff the pattern matches THERE — a tight table loop
            # verify with no per-candidate allocation (vs the PikeVM `wmatch_at`).
            # Only for plain prefix patterns: outermost `^`/`$` need the anchors
            # `c.prog` keeps but the determinizer can't take, so those keep the
            # PikeVM verify.
            has_frange = match c.frange {
                Range(_, _) => True
                NoRange => False
            }
            averify =
                if (!List.is_empty(c.prefix) or has_frange) and !c.anchored_start and !c.accept_eoi_only {
                    match det(c.prog, c.splits) {
                        Ok(av) => Verify(av)
                        Err(_) => NoVerify
                    }
                } else {
                    NoVerify
                }
            # reverse-inner literal prefilter DFAs. `lrev` is reverse(LEFT·lit):
            # run backward from `p+litlen` it confirms the literal at `p` and
            # yields the leftmost start. `full` is the anchored full-pattern
            # forward DFA (det of `c.prog`): run from that start it gives the
            # leftmost-first end, which is what makes a greedy variable-length
            # LEFT correct (e.g. `(a|b)*abb`). Both share the class trie.
            inner =
                match c.inner {
                    Inner(s) =>
                        match det(s.lrev_prog, s.lrev_splits) {
                            Err(_) => NoInner
                            Ok(lrev) =>
                                match det(c.prog, c.splits) {
                                    Err(_) => NoInner
                                    Ok(full) => Inner({ lit: s.lit, lrev, full })
                                }
                        }
                    NoInner => NoInner
                }
            match det(c.uprog, c.usplits) {
                Err(_) => Err(TooBig)
                Ok(fwd0) =>
                    # the outermost-anchor constraints ride on the forward D only
                    match det(c.rprog, c.rsplits) {
                        Err(_) => Err(TooBig)
                        Ok(rev) => Ok({ fwd: { ..fwd0, eoi_only: c.accept_eoi_only, anchored: c.anchored_start }, rev, averify, inner })
                    }
            }
        }

    # `^`/`$` still force the PikeVM; `\b`/`\B` do not (handled in the DFA).
    has_anchor : List(U32), U64 -> Bool
    has_anchor = |prog, i|
        match List.get(prog, i) {
            Err(_) => False
            Ok(w) =>
                if Comp.inst_op(w) == Comp.op_look and (Comp.inst_arg(w) == Comp.look_start or Comp.inst_arg(w) == Comp.look_end) {
                    True
                } else {
                    Rev.has_anchor(prog, i + 1)
                }
        }

    ## Run prebuilt DFAs: leftmost-first span, or NoMatch.
    find : { fwd : Rev.D, rev : Rev.D, averify : [NoVerify, Verify(Rev.D)], inner : [NoInner, Inner({ lit : List(U8), lrev : Rev.D, full : Rev.D })] }, Trie.T, List(U8) -> Try({ start : U64, end : U64 }, [NoMatch])
    find = |d, classes, hay| Rev.find_from(d, classes, hay, 0)

    ## Leftmost-first span at-or-after `at` — the iterator step for `find_all`.
    ## The forward scan starts at `at`; the reverse start-scan is floored at `at`
    ## so the returned start is >= at (non-overlapping with the previous match).
    ##
    ## An outermost `$` (`eoi_only`) short-circuits the forward end-scan: the end
    ## is `len` by definition, so we only run the reverse from `len` to find the
    ## leftmost start (>= `at`), reporting NoMatch when no match ends at `len`.
    ## An outermost `^` (`anchored`) additionally requires that start to be 0.
    find_from : { fwd : Rev.D, rev : Rev.D, averify : [NoVerify, Verify(Rev.D)], inner : [NoInner, Inner({ lit : List(U8), lrev : Rev.D, full : Rev.D })] }, Trie.T, List(U8), U64 -> Try({ start : U64, end : U64 }, [NoMatch])
    find_from = |d, classes, hay, at|
        if d.fwd.eoi_only {
            len = List.len(hay)
            if at > len {
                Err(NoMatch)
            } else {
                match Rev.run_rev_check(d.rev, classes, hay, len, at) {
                    Err(_) => Err(NoMatch)
                    Ok(start) => if d.fwd.anchored and start != 0 { Err(NoMatch) } else { Ok({ start, end: len }) }
                }
            }
        } else {
            match Rev.run_fwd_from(d.fwd, classes, hay, at) {
                Err(_) => Err(NoMatch)
                Ok(end) => Ok({ start: Rev.run_rev_from(d.rev, classes, hay, end, at), end })
            }
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
            Ok(st) => {
                n_states = List.len(st.hit)
                atable = if n_states * 128 <= Rev.atable_budget { Rev.fuse_ascii(st.table, classes.ascii, nc.to_u64(), n_states) } else { [] }
                Ok({ table: st.table, atable, accept_on: [], accept_eoi: st.hit, nc, eoi_only: False, anchored: False })
            }
        }
    }

    # Build the ASCII-fused transition table: for each state and each ASCII byte,
    # look up its class in `ascii` and pre-resolve the `table[state*nc + class]`
    # transition, so the scan indexes `atable[state*128 + byte]` directly.
    fuse_ascii : List(U32), List(U32), U64, U64 -> List(U32)
    fuse_ascii = |table, ascii, nc, n_states|
        List.map(Rev.upto(n_states * 128), |i| {
            s = i // 128
            b = i % 128
            cls = List.get(ascii, b) ?? 0
            List.get(table, s * nc + cls.to_u64()) ?? 0
        })

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

    # --- word-boundary determinization (\b / \B in the DFA) -------------------
    #
    # A wb state is `{ pcs, lw }`: the pending closure plus whether the codepoint
    # that entered the state was a word codepoint. Two start states are seeded
    # (lw False then True → ids 0 and 1) so a mid-string / reverse scan can begin
    # from the correct left-context. `word_set` is the folded `\w` set ordinal;
    # `is_word_class a` = is class `a` a word class.

    WbState : { pcs : List(U32), lw : Bool }

    determinize_wb : List(U32), List(U32), Trie.T, U32, U64, U64 -> Try(Rev.D, [TooBig])
    determinize_wb = |prog, splits, classes, nc, word_set, max_states| {
        pcs0 = Rev.close_pri(prog, splits, [0], [])
        s0f = { pcs: pcs0, lw: False }
        s0t = { pcs: pcs0, lw: True }
        ciw = List.map(Rev.upto(nc.to_u64()), |a| Trie.accepts_atom(classes, word_set.to_u32_wrap(), a.to_u32_wrap()))
        match Rev.explore_wb(prog, splits, classes, nc, ciw, max_states, [s0f, s0t], { table: [], acc_on: [], acc_eoi: [], smap: [s0f, s0t], next: 2 }) {
            Err(e) => Err(e)
            Ok(st) => Ok({ table: st.table, atable: [], accept_on: st.acc_on, accept_eoi: st.acc_eoi, nc, eoi_only: False, anchored: False })
        }
    }

    is_match_pc : List(U32), List(U32) -> Bool
    is_match_pc = |prog, pcs| List.any(pcs, |pc| Comp.inst_op(List.get(prog, pc.to_u64()) ?? 0) == Comp.op_match)

    explore_wb = |prog, splits, classes, nc, ciw, max_states, work, st|
        match List.first(work) {
            Err(_) => Ok(st)
            Ok(state) => {
                rest = List.drop_first(work, 1)
                if (List.len(st.smap)).to_u64() > max_states {
                    Err(TooBig)
                } else {
                    lw = state.lw
                    # accept at end-of-input: right side is non-word
                    eoi = Rev.close_resolve(prog, splits, state.pcs, [], [], lw != False, lw == False)
                    is_eoi = Rev.is_match_pc(prog, eoi)
                    r = List.fold(Rev.upto(nc.to_u64()), { st, work: rest, ids: [], accs: [] }, |acc, cls| {
                        rw = List.get(ciw, cls) ?? False
                        wok = lw != rw
                        resolved = Rev.close_resolve(prog, splits, state.pcs, [], [], wok, !wok)
                        accept = if Rev.is_match_pc(prog, resolved) { 1 } else { 0 }
                        moved = List.fold(resolved, [], |m, pc| {
                            w = List.get(prog, pc.to_u64()) ?? 0
                            if Comp.inst_op(w) == Comp.op_char and Trie.accepts_atom(classes, Comp.inst_arg(w), cls.to_u32_wrap()) {
                                List.append(m, pc + 1)
                            } else {
                                m
                            }
                        })
                        tset = Rev.close_pri(prog, splits, moved, [])
                        accs2 = List.append(acc.accs, accept)
                        if List.is_empty(tset) {
                            { st: acc.st, work: acc.work, ids: List.append(acc.ids, 0), accs: accs2 }
                        } else {
                            tstate = { pcs: tset, lw: rw }
                            match Rev.index_of_wb(acc.st.smap, tstate) {
                                Ok(id) => { st: acc.st, work: acc.work, ids: List.append(acc.ids, id + 1), accs: accs2 }
                                Err(_) => {
                                    nid = acc.st.next
                                    { st: { ..acc.st, smap: List.append(acc.st.smap, tstate), next: nid + 1 }, work: List.append(acc.work, tstate), ids: List.append(acc.ids, nid + 1), accs: accs2 }
                                }
                            }
                        }
                    })
                    st2 = { ..r.st, table: List.concat(r.st.table, r.ids), acc_on: List.concat(r.st.acc_on, r.accs), acc_eoi: List.append(r.st.acc_eoi, if is_eoi { 1 } else { 0 }) }
                    Rev.explore_wb(prog, splits, classes, nc, ciw, max_states, r.work, st2)
                }
            }
        }

    index_of_wb : List(Rev.WbState), Rev.WbState -> Try(U32, [NotFound])
    index_of_wb = |states, target| Rev.iw_loop(states, target, 0)
    iw_loop = |states, target, i|
        match List.get(states, i.to_u64()) {
            Err(_) => Err(NotFound)
            Ok(s) => if s.lw == target.lw and s.pcs == target.pcs { Ok(i) } else { Rev.iw_loop(states, target, i + 1) }
        }

    # resolve pending Looks in `stack` at a position with the given
    # word-boundary / non-word-boundary flags, following satisfied assertions and
    # dropping unsatisfied ones; yields Char/Match pcs in priority order.
    close_resolve : List(U32), List(U32), List(U32), List(U32), List(U32), Bool, Bool -> List(U32)
    close_resolve = |prog, splits, stack, seen, out, wok, nwok|
        match List.first(stack) {
            Err(_) => out
            Ok(pc) => {
                rest = List.drop_first(stack, 1)
                if List.contains(seen, pc) {
                    Rev.close_resolve(prog, splits, rest, seen, out, wok, nwok)
                } else {
                    seen2 = List.append(seen, pc)
                    w = List.get(prog, pc.to_u64()) ?? 0
                    op = Comp.inst_op(w)
                    arg = Comp.inst_arg(w)
                    if op == Comp.op_split {
                        t1 = List.get(splits, arg.to_u64()) ?? 0
                        t2 = List.get(splits, (arg + 1).to_u64()) ?? 0
                        Rev.close_resolve(prog, splits, List.concat([t1, t2], rest), seen2, out, wok, nwok)
                    } else if op == Comp.op_jmp {
                        Rev.close_resolve(prog, splits, List.prepend(rest, arg), seen2, out, wok, nwok)
                    } else if op == Comp.op_save {
                        Rev.close_resolve(prog, splits, List.prepend(rest, pc + 1), seen2, out, wok, nwok)
                    } else if op == Comp.op_look {
                        pass = if arg == Comp.look_wordb { wok } else if arg == Comp.look_nwordb { nwok } else { False }
                        if pass {
                            Rev.close_resolve(prog, splits, List.prepend(rest, pc + 1), seen2, out, wok, nwok)
                        } else {
                            Rev.close_resolve(prog, splits, rest, seen2, out, wok, nwok)
                        }
                    } else if op == Comp.op_match {
                        List.append(out, pc)
                    } else {
                        Rev.close_resolve(prog, splits, rest, seen2, List.append(out, pc), wok, nwok)
                    }
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
    close_pri = |prog, splits, stack, out| Rev.close_go(prog, splits, stack, [], out)

    # `seen` tracks EVERY visited pc (split/jmp/save included), so an epsilon
    # cycle through a nullable loop (e.g. `(a*)+`) terminates. `out` is the
    # priority-ordered Char/Match result; truncated at the first Match.
    close_go : List(U32), List(U32), List(U32), List(U32), List(U32) -> List(U32)
    close_go = |prog, splits, stack, seen, out|
        match List.first(stack) {
            Err(_) => out
            Ok(pc) => {
                rest = List.drop_first(stack, 1)
                if List.contains(seen, pc) {
                    Rev.close_go(prog, splits, rest, seen, out)
                } else {
                    seen2 = List.append(seen, pc)
                    w = List.get(prog, pc.to_u64()) ?? 0
                    op = Comp.inst_op(w)
                    arg = Comp.inst_arg(w)
                    if op == Comp.op_split {
                        t1 = List.get(splits, arg.to_u64()) ?? 0
                        t2 = List.get(splits, (arg + 1).to_u64()) ?? 0
                        Rev.close_go(prog, splits, List.concat([t1, t2], rest), seen2, out)
                    } else if op == Comp.op_jmp {
                        Rev.close_go(prog, splits, List.prepend(rest, arg), seen2, out)
                    } else if op == Comp.op_save {
                        Rev.close_go(prog, splits, List.prepend(rest, pc + 1), seen2, out)
                    } else if op == Comp.op_look {
                        # leave the assertion pending in the set; a transition
                        # resolves it once both sides' word-ness are known
                        # (`close_resolve`). Look-free progs never reach this.
                        Rev.close_go(prog, splits, rest, seen2, List.append(out, pc))
                    } else if op == Comp.op_match {
                        List.append(out, pc)
                    } else {
                        Rev.close_go(prog, splits, rest, seen2, List.append(out, pc))
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

    # `accept_on` non-empty selects the word-boundary scan; otherwise the plain
    # look-free scan (where `accept_eoi` is the per-state match flag).
    is_wb : Rev.D -> Bool
    is_wb = |d| !(List.is_empty(d.accept_on))

    run_fwd : Rev.D, Trie.T, List(U8) -> Try(U64, [NoMatch])
    run_fwd = |d, classes, hay|
        if Rev.is_wb(d) { Rev.fwd_wb(d, classes, hay, 0, 0, Err(NoMatch)) } else { Rev.fwd(d, classes, hay, 0, 0, Err(NoMatch)) }

    # forward end-scan starting at `at`. Terminates at the leftmost match's end:
    # the leftmost-first determinizer truncates the lazy dot-star closure at the
    # first Match, so the state goes dead just past the match rather than looping
    # to EOF — this is what keeps `find_all` iteration linear (see the DFA-find_all
    # scope note). No explicit end bound is needed for that.
    run_fwd_from : Rev.D, Trie.T, List(U8), U64 -> Try(U64, [NoMatch])
    run_fwd_from = |d, classes, hay, at|
        # an outermost `^` anchors the forward DFA to position 0: a search that
        # starts anywhere else (find_all iteration) cannot match.
        if d.anchored and at != 0 {
            Err(NoMatch)
        } else if Rev.is_wb(d) {
            Rev.fwd_wb(d, classes, hay, at, Rev.wstart_fwd(hay, at), Err(NoMatch))
        } else if List.is_empty(d.atable) {
            Rev.fwd_c(d, classes, hay, at, 0, Err(NoMatch))
        } else {
            Rev.fwd(d, classes, hay, at, 0, Err(NoMatch))
        }

    # left-context start state for a forward scan beginning at `at`: state 1 if
    # the codepoint ending just before `at` is a word codepoint, else state 0
    # (determinize_wb seeds [nonword, word] as ids 0, 1).
    wstart_fwd : List(U8), U64 -> U32
    wstart_fwd = |hay, at|
        if at > 0 and Comp.is_word_cp(Comp.decode(hay, Rev.cp_start(hay, at - 1)).cp) { 1 } else { 0 }

    fwd : Rev.D, Trie.T, List(U8), U64, U32, Try(U64, [NoMatch]) -> Try(U64, [NoMatch])
    fwd = |d, classes, hay, pos, state, best| {
        best2 = if (List.get(d.accept_eoi, state.to_u64()) ?? 0) == 1 { Ok(pos) } else { best }
        if pos >= List.len(hay) {
            best2
        } else {
            # ASCII fast path: skip the UTF-8 decode and the class_of dispatch —
            # the byte is its own codepoint and indexes the class table directly.
            b0 = List.get(hay, pos) ?? 0
            if b0 < 0x80 {
                nxt = List.get(d.atable, state.to_u64() * 128 + b0.to_u64()) ?? 0
                if nxt == 0 { best2 } else { Rev.fwd(d, classes, hay, pos + 1, nxt - 1, best2) }
            } else {
                dec = Comp.decode(hay, pos)
                cls = Trie.class_of(classes, dec.cp)
                nxt = List.get(d.table, state.to_u64() * d.nc.to_u64() + cls.to_u64()) ?? 0
                if nxt == 0 { best2 } else { Rev.fwd(d, classes, hay, pos + dec.len, nxt - 1, best2) }
            }
        }
    }

    # class-lookup forward scan: the fallback when the fused `atable` was skipped
    # (state count over the fuse budget). ASCII still skips the decode, but goes
    # byte -> class -> table like the non-ASCII path.
    fwd_c : Rev.D, Trie.T, List(U8), U64, U32, Try(U64, [NoMatch]) -> Try(U64, [NoMatch])
    fwd_c = |d, classes, hay, pos, state, best| {
        best2 = if (List.get(d.accept_eoi, state.to_u64()) ?? 0) == 1 { Ok(pos) } else { best }
        if pos >= List.len(hay) {
            best2
        } else {
            b0 = List.get(hay, pos) ?? 0
            if b0 < 0x80 {
                cls = List.get(classes.ascii, b0.to_u64()) ?? 0
                nxt = List.get(d.table, state.to_u64() * d.nc.to_u64() + cls.to_u64()) ?? 0
                if nxt == 0 { best2 } else { Rev.fwd_c(d, classes, hay, pos + 1, nxt - 1, best2) }
            } else {
                dec = Comp.decode(hay, pos)
                cls = Trie.class_of(classes, dec.cp)
                nxt = List.get(d.table, state.to_u64() * d.nc.to_u64() + cls.to_u64()) ?? 0
                if nxt == 0 { best2 } else { Rev.fwd_c(d, classes, hay, pos + dec.len, nxt - 1, best2) }
            }
        }
    }

    # word-boundary forward scan: accept is per position (`accept_on[state,cls]`
    # resolves the boundary against the following codepoint) with `accept_eoi`
    # at end-of-input (right side = non-word).
    fwd_wb : Rev.D, Trie.T, List(U8), U64, U32, Try(U64, [NoMatch]) -> Try(U64, [NoMatch])
    fwd_wb = |d, classes, hay, pos, state, best|
        if pos >= List.len(hay) {
            if (List.get(d.accept_eoi, state.to_u64()) ?? 0) == 1 { Ok(pos) } else { best }
        } else {
            dec = Comp.decode(hay, pos)
            cls = Trie.class_of(classes, dec.cp)
            idx = state.to_u64() * d.nc.to_u64() + cls.to_u64()
            best2 = if (List.get(d.accept_on, idx) ?? 0) == 1 { Ok(pos) } else { best }
            nxt = List.get(d.table, idx) ?? 0
            if nxt == 0 {
                best2
            } else {
                Rev.fwd_wb(d, classes, hay, pos + dec.len, nxt - 1, best2)
            }
        }

    # reverse DFA anchored at `end`, stepping backward; the smallest reached
    # position that is a match state is the leftmost start.
    run_rev : Rev.D, Trie.T, List(U8), U64 -> U64
    run_rev = |d, classes, hay, end| Rev.run_rev_from(d, classes, hay, end, 0)

    # sentinel "no start found" for the existence-reporting reverse
    no_start : U64
    no_start = 0xFFFF_FFFF_FFFF_FFFF

    # reverse from `end` (floored at `lo`) reporting whether a match actually ends
    # at `end`: `Ok(leftmost start)` if an accept state was reached, else NoMatch.
    # Used by the outermost-`$` path, where the forward end-scan is skipped and
    # `end == len` is given — so we must confirm a match exists there.
    run_rev_check : Rev.D, Trie.T, List(U8), U64, U64 -> Try(U64, [NoMatch])
    run_rev_check = |d, classes, hay, end, lo| {
        r = Rev.rev_dispatch(d, classes, hay, end, lo, Rev.no_start)
        if r == Rev.no_start { Err(NoMatch) } else { Ok(r) }
    }

    # as `run_rev`, but the backward scan stops at floor `lo` (so the leftmost
    # start it can report is `lo`) — used by `find_from` to keep matches
    # non-overlapping across iteration.
    run_rev_from : Rev.D, Trie.T, List(U8), U64, U64 -> U64
    run_rev_from = |d, classes, hay, end, lo|
        Rev.rev_dispatch(d, classes, hay, end, lo, end)

    # left-context start state for the reverse scan beginning at `end`: in the
    # reversed reading the "already-seen" side is the codepoint at `end`.
    wstart_rev : List(U8), U64 -> U32
    wstart_rev = |hay, end|
        if end < List.len(hay) and Comp.is_word_cp(Comp.decode(hay, end).cp) { 1 } else { 0 }

    rev : Rev.D, Trie.T, List(U8), U64, U64, U32, U64 -> U64
    rev = |d, classes, hay, pos, lo, state, best| {
        best2 = if (List.get(d.accept_eoi, state.to_u64()) ?? 0) == 1 { pos } else { best }
        if pos <= lo {
            best2
        } else {
            # ASCII fast path: a byte < 0x80 is a one-byte codepoint, so its start
            # is `pos-1` and it indexes the class table directly — no scan back to
            # a codepoint boundary, no decode, no class_of dispatch.
            b = List.get(hay, pos - 1) ?? 0
            if b < 0x80 {
                nxt = List.get(d.atable, state.to_u64() * 128 + b.to_u64()) ?? 0
                if nxt == 0 { best2 } else { Rev.rev(d, classes, hay, pos - 1, lo, nxt - 1, best2) }
            } else {
                cs = Rev.cp_start(hay, pos - 1)
                dec = Comp.decode(hay, cs)
                cls = Trie.class_of(classes, dec.cp)
                nxt = List.get(d.table, state.to_u64() * d.nc.to_u64() + cls.to_u64()) ?? 0
                if nxt == 0 { best2 } else { Rev.rev(d, classes, hay, cs, lo, nxt - 1, best2) }
            }
        }
    }

    # picks the reverse scan variant: word-boundary, fused-`atable`, or the
    # class-lookup fallback (fused table skipped). `best0` is the initial `best`
    # (`no_start` to report existence, `end` for the plain leftmost start).
    rev_dispatch : Rev.D, Trie.T, List(U8), U64, U64, U64 -> U64
    rev_dispatch = |d, classes, hay, end, lo, best0|
        if Rev.is_wb(d) {
            Rev.rev_wb(d, classes, hay, end, lo, Rev.wstart_rev(hay, end), best0)
        } else if List.is_empty(d.atable) {
            Rev.rev_c(d, classes, hay, end, lo, 0, best0)
        } else {
            Rev.rev(d, classes, hay, end, lo, 0, best0)
        }

    # class-lookup reverse scan: the fallback when the fused `atable` was skipped.
    rev_c : Rev.D, Trie.T, List(U8), U64, U64, U32, U64 -> U64
    rev_c = |d, classes, hay, pos, lo, state, best| {
        best2 = if (List.get(d.accept_eoi, state.to_u64()) ?? 0) == 1 { pos } else { best }
        if pos <= lo {
            best2
        } else {
            b = List.get(hay, pos - 1) ?? 0
            if b < 0x80 {
                cls = List.get(classes.ascii, b.to_u64()) ?? 0
                nxt = List.get(d.table, state.to_u64() * d.nc.to_u64() + cls.to_u64()) ?? 0
                if nxt == 0 { best2 } else { Rev.rev_c(d, classes, hay, pos - 1, lo, nxt - 1, best2) }
            } else {
                cs = Rev.cp_start(hay, pos - 1)
                dec = Comp.decode(hay, cs)
                cls = Trie.class_of(classes, dec.cp)
                nxt = List.get(d.table, state.to_u64() * d.nc.to_u64() + cls.to_u64()) ?? 0
                if nxt == 0 { best2 } else { Rev.rev_c(d, classes, hay, cs, lo, nxt - 1, best2) }
            }
        }
    }

    # word-boundary reverse scan. A start recorded at `pos` is gated by the
    # codepoint to its left (the one about to be consumed going backward), via
    # `accept_on`; at the true haystack start (pos 0) that left side is non-word,
    # so `accept_eoi` applies.
    rev_wb : Rev.D, Trie.T, List(U8), U64, U64, U32, U64 -> U64
    rev_wb = |d, classes, hay, pos, lo, state, best| {
        accepted =
            if pos == 0 {
                (List.get(d.accept_eoi, state.to_u64()) ?? 0) == 1
            } else {
                lc = Trie.class_of(classes, Comp.decode(hay, Rev.cp_start(hay, pos - 1)).cp)
                (List.get(d.accept_on, state.to_u64() * d.nc.to_u64() + lc.to_u64()) ?? 0) == 1
            }
        best2 = if accepted { pos } else { best }
        if pos <= lo {
            best2
        } else {
            cs = Rev.cp_start(hay, pos - 1)
            dec = Comp.decode(hay, cs)
            cls = Trie.class_of(classes, dec.cp)
            nxt = List.get(d.table, state.to_u64() * d.nc.to_u64() + cls.to_u64()) ?? 0
            if nxt == 0 {
                best2
            } else {
                Rev.rev_wb(d, classes, hay, cs, lo, nxt - 1, best2)
            }
        }
    }

    cp_start : List(U8), U64 -> U64
    cp_start = |hay, i| {
        b = List.get(hay, i) ?? 0
        if b >= 0x80 and b < 0xC0 and i > 0 { Rev.cp_start(hay, i - 1) } else { i }
    }
}
