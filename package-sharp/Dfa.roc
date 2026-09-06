## The derivative automaton and RE#'s `llmatch` (S3, `Regex.fs`).
##
## States are regex nodes; `table[state * nmt + cls]` is the next state, `0`
## meaning not computed yet. `explore` fills the table eagerly (at build time
## when the pattern is a literal) up to a state budget; a scan that reaches an
## unexplored transition computes the derivative there and extends the record,
## which is threaded linearly through every scan. `complete` says whether the
## fold finished. State id 1 is the dead state (node `bot`); 0 is never a state.
##
## Positions are symbol indices over a prepared haystack (`Ref.Hay`): each
## codepoint, or one `Invalid` symbol per malformed run, is one step, which is
## what the lookahead `rel` counters count. Spans convert to bytes at the end.
import Arena
import Bset
import Build
import Deriv
import Lit
import Ref
import Rlit
import Teddy
import Trie
import TSet
import Utf8

Dfa := [].{
    E : {
        a : Arena.A,
        nmt : U32,
        # per state (index = state id; index 0 is a dummy)
        st_node : List(U32),
        st_flags : List(U8),
        st_nk : List(U8),
        st_pend : List(U32),
        # symbol offset of the earliest pending nullable; `Arena.ps` is 16-bit
        st_minpend : List(U16),
        # node id -> state id (0 = none); may be shorter than the arena
        node_state : List(U32),
        table : List(U32),
        end_table : List(U32),
        s_rev_ts : U32,
        s_noprefix : U32,
        max_states : U64,
        complete : Bool,
        # the folded prefix (S4): `freeze` records it after `explore`; a scan
        # that mints past `runtime_cap` states evicts back to it
        fold_states : U64,
        fold_marks : Arena.Marks,
        runtime_cap : U64,
        # Complete folds only: fused ASCII byte -> next state, `state * 128 + byte`.
        # A complete fold is capped at `Sharp.fold_state_cap` states, so a state id
        # fits a U16 here. `table` and `end_table` cannot narrow the same way: the
        # extensible path mints states at scan time up to `runtime_cap`.
        atable : List(U16),
        # complete folds only (RE#'s per-state startsets / `CanSkipFlag`): for
        # state `s`, `skip_ok[s] == 1` says the bytes that change the state form
        # a rare enough set that a scan in `s` can skip to the nearest one;
        # `skip_lo` holds its `Bset` table at `s * 16`
        skip_ok : List(U8),
        skip_lo : List(U8),
        # does any state skip? (the per-step skip check costs ~0.6 ns; off when useless)
        any_skip : Bool,
    }

    dead : U32
    dead = 1

    # the same state, as stored in `atable`
    dead16 : U16
    dead16 = 1

    # StateFlags
    fl_initial : U8
    fl_initial = 1
    fl_anchor_null : U8
    fl_anchor_null = 4
    fl_begin_null : U8
    fl_begin_null = 16
    fl_end_null : U8
    fl_end_null = 32
    fl_always : U8
    fl_always = 64
    fl_pending : U8
    fl_pending = 128

    # NullKind
    nk_notnull : U8
    nk_notnull = 255
    nk_current : U8
    nk_current = 0
    nk_prev : U8
    nk_prev = 1
    nk_pending : U8
    nk_pending = 4

    R : { e : Dfa.E, id : U32 }

    ## An engine over the arena with the dead state and the two start states.
    init : Arena.A, U32, U32, U64 -> Dfa.E
    init = |a, rev_ts, noprefix, max_states| {
        e0 = {
            a, nmt: a.nmt,
            st_node: [0], st_flags: [0], st_nk: [Dfa.nk_notnull], st_pend: [0], st_minpend: [0],
            node_state: [], table: List.repeat(0.U32, a.nmt.to_u64()), end_table: List.repeat(0.U32, a.nmt.to_u64()),
            s_rev_ts: 0, s_noprefix: 0, max_states, complete: True,
            fold_states: 0, fold_marks: Arena.marks(a), runtime_cap: Dfa.default_runtime_cap, atable: [], skip_ok: [], skip_lo: [], any_skip: False,
        }
        d = Dfa.get_state(e0, Arena.bot, False)
        r1 = Dfa.get_state(d.e, rev_ts, True)
        r2 = Dfa.get_state(r1.e, noprefix, False)
        { ..r2.e, s_rev_ts: r1.id, s_noprefix: r2.id }
    }

    ## RE#'s `MaxDfaCapacity`
    default_runtime_cap : U64
    default_runtime_cap = 100_000

    ## Record the fold's extent; everything created later can be evicted. For a
    ## complete fold, also fuse the ASCII byte -> state table the fast scans use
    ## (`ascii` is the trie's byte -> class table).
    freeze : Dfa.E, List(U8) -> Dfa.E
    freeze = |e, ascii| {
        n = List.len(e.st_node)
        atable =
            if e.complete {
                List.map(Arena.upto(n * 128), |i| {
                    s = i // 128
                    b = i % 128
                    cls = (List.get(ascii, b) ?? 0).to_u64()
                    (List.get(e.table, s * e.nmt.to_u64() + cls) ?? 0).to_u16_wrap()
                })
            } else {
                []
            }
        sk = if e.complete { Dfa.skip_sets(e, ascii, n) } else { { ok: [], lo: [] } }
        { ..e, fold_states: n, fold_marks: Arena.marks(e.a), atable, skip_ok: sk.ok, skip_lo: sk.lo, any_skip: List.any(sk.ok, |x| x == 1) }
    }

    # RE#'s `_createStartset` for every state of a complete fold: the minterms
    # whose transition leaves the state (for the initial state, also not to
    # dead) as an ASCII byte set; skippable when neither empty nor full and not
    # too common. Non-ASCII bytes stop a skip regardless (`Bset`).
    skip_sets : Dfa.E, List(U8), U64 -> { ok : List(U8), lo : List(U8) }
    skip_sets = |e, ascii, n| {
        nmt = e.nmt.to_u64()
        List.fold(Arena.upto(n), { ok: [], lo: [] }, |acc, s| {
            initial = s == e.s_rev_ts.to_u64()
            ss = List.fold(Arena.upto(nmt), 0, |ts, m| {
                d = (List.get(e.table, s * nmt + m) ?? 0).to_u64()
                if d != s and (!initial or d != Dfa.dead.to_u64()) { TSet.union(ts, TSet.bit(m.to_u32_wrap())) } else { ts }
            })
            bytes = List.keep_if(Arena.upto(128), |b| TSet.contains(ss, (List.get(ascii, b) ?? 0).to_u32())) |> List.map(|b| b.to_u8_wrap())
            usable = s > Dfa.dead.to_u64() and ss != 0 and ss != TSet.full(e.nmt) and !Bset.too_common(bytes)
            { ok: List.append(acc.ok, if usable { 1 } else { 0 }), lo: List.concat(acc.lo, Bset.table(bytes)) }
        })
    }

    ## Drop every state and node minted since the fold, keeping only the node of
    ## state `s`, rebuilt into the truncated arena; returns its new state.
    evict : Dfa.E, U32 -> Dfa.R
    evict = |e, s| {
        node = Dfa.st_node_of(e, s)
        m = e.fold_marks
        n = e.fold_states
        a1 = Arena.truncate(e.a, m)
        e1 = { ..e,
            a: a1,
            st_node: List.take_first(e.st_node, n),
            st_flags: List.take_first(e.st_flags, n),
            st_nk: List.take_first(e.st_nk, n),
            st_pend: List.take_first(e.st_pend, n),
            st_minpend: List.take_first(e.st_minpend, n),
            node_state: List.take_first(e.node_state, m.nodes) |> List.map(|v| if v.to_u64() < n { v } else { 0 }),
            table: List.take_first(e.table, n * e.nmt.to_u64()),
            end_table: List.take_first(e.end_table, n * e.nmt.to_u64()),
        }
        r = Build.copy_node(e.a, e1.a, m, node)
        Dfa.get_state({ ..e1, a: r.a }, r.id, False)
    }

    n_states : Dfa.E -> U64
    n_states = |e| List.len(e.st_node) - 1

    ## the state for a node, creating it if needed (`_getOrCreateState`)
    get_state : Dfa.E, U32, Bool -> Dfa.R
    get_state = |e, node, initial| {
        existing = List.get(e.node_state, node.to_u64()) ?? 0
        if existing != 0 {
            { e, id: existing }
        } else {
            a = e.a
            id = (List.len(e.st_node)).to_u32_wrap()
            always = Arena.is_always_null(a, node)
            can = Arena.can_be_null(a, node)
            f0 = if always { Dfa.fl_always } else { 0 }
            f1 = if can and Arena.depends_anchor(a, node) { f0.bitwise_or(Dfa.fl_anchor_null) } else { f0 }
            f2 = if initial { f1.bitwise_or(Dfa.fl_initial) } else { f1 }
            f3 = if can and Deriv.nullable(a, Deriv.loc_end, node) { f2.bitwise_or(Dfa.fl_end_null) } else { f2 }
            f4 = if can and Deriv.nullable(a, Deriv.loc_begin, node) { f3.bitwise_or(Dfa.fl_begin_null) } else { f3 }
            # Deviation from RE#, which takes the node's whole pending set when the
            # node CAN be nullable: a lookahead whose body is nullable only at the
            # input start (`~(a_*)\A`) then had its positions marked at every step
            # (`(?<!a.)` on "abc" reported 2-2). Here the Center-location set drives
            # the scan; `handle_input_start`/`at_eoi` recompute for Begin and End.
            pairs = if Arena.contains_look(a, node) and can and !initial { Dfa.pend_at(a, node, Deriv.loc_center) } else { [] }
            has_pend = !List.is_empty(pairs)
            f5 = if has_pend { f4.bitwise_or(Dfa.fl_pending) } else { f4 }
            rs = if has_pend { Arena.rs_intern(a, pairs) } else { { a, id: Arena.rs_empty } }
            pend = rs.id
            minpend = match List.first(pairs) { Ok(p) => Arena.ps(p), Err(_) => 0 }
            nk =
                if !always { Dfa.nk_notnull }
                else if !has_pend { Dfa.nk_current }
                else if pairs == [Arena.pack(1, 1)] { Dfa.nk_prev }
                else { Dfa.nk_pending }
            ns = Dfa.pad(e.node_state, node.to_u64() + 1)
            e1 = { ..e,
                a: rs.a,
                st_node: List.append(e.st_node, node),
                st_flags: List.append(e.st_flags, f5),
                st_nk: List.append(e.st_nk, nk),
                st_pend: List.append(e.st_pend, pend),
                st_minpend: List.append(e.st_minpend, minpend.to_u16_wrap()),
                node_state: List.set(ns, node.to_u64(), id) ?? ns,
                table: List.concat(e.table, List.repeat(0.U32, e.nmt.to_u64())),
                end_table: List.concat(e.end_table, List.repeat(0.U32, e.nmt.to_u64())),
            }
            { e: e1, id }
        }
    }

    pad : List(U32), U64 -> List(U32)
    pad = |l, n| if List.len(l) >= n { l } else { List.concat(l, List.repeat(0.U32, n - List.len(l))) }

    st_node_of : Dfa.E, U32 -> U32
    st_node_of = |e, s| List.get(e.st_node, s.to_u64()) ?? Arena.bot

    flags : Dfa.E, U32 -> U8
    flags = |e, s| List.get(e.st_flags, s.to_u64()) ?? 0

    nk : Dfa.E, U32 -> U8
    nk = |e, s| List.get(e.st_nk, s.to_u64()) ?? Dfa.nk_notnull

    is_null : Dfa.E, U32 -> Bool
    is_null = |e, s| Dfa.nk(e, s) != Dfa.nk_notnull

    ## the Center transition on class `cls`, computing and recording it on a miss
    step : Dfa.E, U32, U32 -> Dfa.R
    step = |e, s, cls| {
        idx = s.to_u64() * e.nmt.to_u64() + cls.to_u64()
        nxt = List.get(e.table, idx) ?? 0
        if nxt != 0 {
            { e, id: nxt }
        } else {
            # over the cap with runtime-minted states present: evict first (a cap
            # below the folded prefix can never be satisfied, so it is ignored)
            ev = if List.len(e.st_node) > e.runtime_cap and List.len(e.st_node) > e.fold_states { Dfa.evict(e, s) } else { { e, id: s } }
            idx2 = ev.id.to_u64() * ev.e.nmt.to_u64() + cls.to_u64()
            d = Deriv.derivative(ev.e.a, Deriv.loc_center, TSet.bit(cls), Dfa.st_node_of(ev.e, ev.id))
            r = Dfa.get_state({ ..ev.e, a: d.a }, d.id, False)
            { e: { ..r.e, table: List.set(r.e.table, idx2, r.id) ?? r.e.table }, id: r.id }
        }
    }

    ## the End-location transition (the first step of the reverse sweep)
    step_end : Dfa.E, U32, U32 -> Dfa.R
    step_end = |e, s, cls| {
        idx = s.to_u64() * e.nmt.to_u64() + cls.to_u64()
        nxt = List.get(e.end_table, idx) ?? 0
        if nxt != 0 {
            { e, id: nxt }
        } else {
            ev = if List.len(e.st_node) > e.runtime_cap and List.len(e.st_node) > e.fold_states { Dfa.evict(e, s) } else { { e, id: s } }
            idx2 = ev.id.to_u64() * ev.e.nmt.to_u64() + cls.to_u64()
            d = Deriv.derivative(ev.e.a, Deriv.loc_end, TSet.bit(cls), Dfa.st_node_of(ev.e, ev.id))
            r = Dfa.get_state({ ..ev.e, a: d.a }, d.id, False)
            { e: { ..r.e, end_table: List.set(r.e.end_table, idx2, r.id) ?? r.e.end_table }, id: r.id }
        }
    }

    ## Fill the table breadth-first from the start states, up to the budget.
    explore : Dfa.E -> Dfa.E
    explore = |e0| {
        # the reverse start's End transitions come first (RE# does the same)
        e1 =
            if Arena.depends_anchor(e0.a, Dfa.st_node_of(e0, e0.s_rev_ts)) {
                List.fold(Arena.upto(e0.nmt.to_u64()), e0, |acc, c| (Dfa.step_end(acc, acc.s_rev_ts, c.to_u32_wrap())).e)
            } else {
                e0
            }
        Dfa.explore_from(e1, 1)
    }

    # states are numbered in creation order, so a cursor over state ids is the
    # BFS queue. A `while` loop: one iteration per state, not one stack frame.
    explore_from : Dfa.E, U64 -> Dfa.E
    explore_from = |e0, s0| {
        var e = e0
        var s = s0
        var running = True
        while running {
            if s >= List.len(e.st_node) {
                running = False
            } else if List.len(e.st_node) > e.max_states {
                e = { ..e, complete: False }
                running = False
            } else {
                e = List.fold(Arena.upto(e.nmt.to_u64()), e, |acc, c| (Dfa.step(acc, s.to_u32_wrap(), c.to_u32_wrap())).e)
                s = s + 1
            }
        }
        e
    }

    # --- the reverse sweep: every position where a match starts ------------------

    Acc : { e : Dfa.E, acc : List(U64) }

    ## RE#'s `HandleInputEnd` + `collect` + `HandleInputStart`: the match-start
    ## positions (symbol indices), in RE#'s right-to-left order
    starts : Dfa.E, Ref.Hay -> Dfa.Acc
    starts = |e, h|
        if h.n == 0 {
            s = e.s_rev_ts
            node = Dfa.st_node_of(e, s)
            { e, acc: if Deriv.nullable(e.a, Deriv.loc_both, node) { [0] } else { [] } }
        } else {
            st = Dfa.handle_input_end(e, h)
            col = Dfa.collect(st.e, h, st.pos, st.s, st.acc)
            Dfa.handle_input_start(col.e, col.s, col.acc)
        }

    # returns the state and position after the (possibly anchor-aware) first step
    handle_input_end : Dfa.E, Ref.Hay -> { e : Dfa.E, s : U32, pos : U64, acc : List(U64) }
    handle_input_end = |e, h| {
        s0 = e.s_rev_ts
        node = Dfa.st_node_of(e, s0)
        f = Dfa.flags(e, s0)
        null_at_end = f.bitwise_and(Dfa.fl_always) != 0 or Deriv.nullable(e.a, Deriv.loc_end, node)
        if !(null_at_end or Arena.depends_anchor(e.a, node)) {
            { e, s: s0, pos: h.n, acc: [] }
        } else {
            pos0 = h.n
            acc0 = if null_at_end { if f.bitwise_and(Dfa.fl_pending) != 0 { Dfa.add_pending_rev(e, s0, [], pos0) } else { [pos0] } } else { [] }
            # one End-location step over the last symbol
            r = Dfa.step_end(e, s0, List.get(h.cls, pos0 - 1) ?? 0)
            pos = pos0 - 1
            if pos != 0 {
                acc1 = if Dfa.is_null(r.e, r.id) { Dfa.set_null_full(r.e, r.id, acc0, pos) } else { acc0 }
                { e: r.e, s: r.id, pos, acc: acc1 }
            } else {
                nd = Dfa.st_node_of(r.e, r.id)
                really = Dfa.flags(r.e, r.id).bitwise_and(Dfa.fl_always) != 0 or Deriv.nullable(r.e.a, Deriv.loc_begin, nd)
                acc1 =
                    if really {
                        k = Dfa.nk(r.e, r.id)
                        if k == Dfa.nk_current or k == Dfa.nk_prev {
                            List.append(acc0, k.to_u64())
                        } else {
                            pairs = Arena.rs_get(r.e.a, List.get(r.e.st_pend, r.id.to_u64()) ?? 0)
                            if List.is_empty(pairs) { List.append(acc0, 0) } else { Dfa.add_pairs(acc0, pairs, pos) }
                        }
                    } else {
                        acc0
                    }
                { e: r.e, s: r.id, pos, acc: acc1 }
            }
        }
    }

    # `collect_noskip`: walk right to left recording every nullable position
    collect : Dfa.E, Ref.Hay, U64, U32, List(U64) -> { e : Dfa.E, s : U32, acc : List(U64) }
    collect = |e0, h, pos0, s0, acc0| {
        var e = e0
        var pos = pos0
        var s = s0
        var acc = acc0
        while pos > 0 {
            p = pos - 1
            r = Dfa.step(e, s, List.get(h.cls, p) ?? 0)
            e = r.e
            s = r.id
            if Dfa.is_null(e, s) {
                acc = Dfa.set_null_full(e, s, acc, p)
            }
            pos = p
        }
        { e, s, acc }
    }

    # `HandleInputStart`: what is nullable at position 0 with the Begin location
    handle_input_start : Dfa.E, U32, List(U64) -> Dfa.Acc
    handle_input_start = |e, s, acc| {
        # Deviation from RE#'s `HandleInputStart`, which reads the state's NullKind
        # (a Center-location notion) here: at the input start the matches are the
        # pending positions of the branches nullable at Begin, plus 0 for a branch
        # nullable there with nothing pending (`(?<!a.)` on "abc" lost 0-0).
        node = Dfa.st_node_of(e, s)
        a = e.a
        if Dfa.flags(e, s).bitwise_and(Dfa.fl_always) != 0 or Deriv.nullable(a, Deriv.loc_begin, node) {
            tail = List.take_last(acc, 8)
            fresh = List.keep_if(Dfa.add_pairs([], Dfa.pend_at(a, node, Deriv.loc_begin), 0), |p| !List.contains(tail, p))
            acc1 = List.concat(acc, fresh)
            { e, acc: if Dfa.fresh_at(a, node, Deriv.loc_begin) and !List.contains(tail, 0) and !List.contains(fresh, 0) { List.append(acc1, 0) } else { acc1 } }
        } else {
            { e, acc }
        }
    }

    pend_at : Arena.A, U32, U32 -> List(U32)
    pend_at = |a, node, loc| {
        branches = if Arena.is_or(a, node) { Arena.children(a, node) } else { [node] }
        List.fold(branches, [], |acc, c|
            if Arena.pend(a, c) != Arena.rs_empty and Deriv.nullable(a, loc, c) { List.concat(acc, Arena.rs_get(a, Arena.pend(a, c))) } else { acc })
        |> Arena.rs_normalize
    }

    ## `hasFreshBeginNullableBranch`, for any location: a branch nullable at `loc`
    ## with nothing pending is a match at the current position in its own right
    fresh_at : Arena.A, U32, U32 -> Bool
    fresh_at = |a, node, loc| {
        branches = if Arena.is_or(a, node) { Arena.children(a, node) } else { [node] }
        List.any(branches, |c| Arena.pend(a, c) == Arena.rs_empty and Deriv.nullable(a, loc, c))
    }

    set_null_full : Dfa.E, U32, List(U64), U64 -> List(U64)
    set_null_full = |e, s, acc, pos| {
        k = Dfa.nk(e, s)
        if k == Dfa.nk_current or k == Dfa.nk_prev {
            List.append(acc, pos + k.to_u64())
        } else {
            Dfa.add_pending_rev(e, s, acc, pos)
        }
    }

    add_pending_rev : Dfa.E, U32, List(U64), U64 -> List(U64)
    add_pending_rev = |e, s, acc, pos|
        Dfa.add_pairs(acc, Arena.rs_get(e.a, List.get(e.st_pend, s.to_u64()) ?? 0), pos)

    # ranges from last to first, each from `e` down to `s`, offset by `pos`
    add_pairs : List(U64), List(U32), U64 -> List(U64)
    add_pairs = |acc, pairs, pos|
        List.fold_rev(pairs, acc, |p, ac| {
            s = Arena.ps(p).to_u64()
            en = Arena.pe(p).to_u64()
            List.fold(Arena.upto(en - s + 1), ac, |ac2, i| List.append(ac2, en - i + pos))
        })

    # --- the forward end pass ----------------------------------------------------

    EndR : { e : Dfa.E, end : Try(U64, [NoEnd]) }

    ## `end_noskip`: the longest match end from `start` using the prefix-free pattern
    ends_from : Dfa.E, Ref.Hay, U64 -> Dfa.EndR
    ends_from = |e, h, start|
        if start == h.n {
            { e, end: Dfa.at_eoi(e, e.s_noprefix, start, Err(NoEnd)) }
        } else {
            # see `ends_fast`: an anchor behind a nullable head is nullable only at the input start
            best0 = if start == 0 and Dfa.flags(e, e.s_noprefix).bitwise_and(Dfa.fl_anchor_null) != 0 and Deriv.nullable(e.a, Deriv.loc_begin, Dfa.st_node_of(e, e.s_noprefix)) { Ok(0) } else { Err(NoEnd) }
            Dfa.end_loop(e, h, start, e.s_noprefix, best0)
        }

    end_loop : Dfa.E, Ref.Hay, U64, U32, Try(U64, [NoEnd]) -> Dfa.EndR
    end_loop = |e0, h, pos0, s0, best0| {
        var e = e0
        var pos = pos0
        var s = s0
        var best = best0
        while s != Dfa.dead {
            if Dfa.is_null(e, s) {
                k = Dfa.nk(e, s)
                best = if k == Dfa.nk_current or k == Dfa.nk_prev { Ok(pos - k.to_u64()) } else { Dfa.null_fallback(e, s, pos, best) }
            }
            r = Dfa.step(e, s, List.get(h.cls, pos) ?? 0)
            e = r.e
            s = r.id
            pos = pos + 1
            if pos == h.n {
                best = Dfa.at_eoi(e, s, pos, best)
                s = Dfa.dead
            }
        }
        { e, end: best }
    }

    # `set_null_fwd_fallback`: a pending-nullable state's most recent candidate
    null_fallback : Dfa.E, U32, U64, Try(U64, [NoEnd]) -> Try(U64, [NoEnd])
    null_fallback = |e, s, pos, best|
        if Dfa.flags(e, s).bitwise_and(Dfa.fl_pending) != 0 {
            cand = pos - (List.get(e.st_minpend, s.to_u64()) ?? 0).to_u64()
            Dfa.max_end(best, cand)
        } else {
            Ok(pos)
        }

    max_end : Try(U64, [NoEnd]), U64 -> Try(U64, [NoEnd])
    max_end = |best, cand|
        match best {
            Ok(b) => Ok(if cand > b { cand } else { b })
            Err(_) => Ok(cand)
        }

    # `HandleInputEndFwd`: nullability at end of input (precise for anchors, log)
    at_eoi : Dfa.E, U32, U64, Try(U64, [NoEnd]) -> Try(U64, [NoEnd])
    at_eoi = |e, s, pos, best| {
        # Deviation from RE#'s `HandleInputEndFwd` (NullKind first, End location
        # only for anchor states without pending positions): at the end of input
        # the candidates are the position itself, for a branch nullable at End with
        # nothing pending, and `pos - offset` for the pending pairs of branches
        # nullable at End; the largest wins (`b?(?!c&d)` on "b" ended at 0).
        node = Dfa.st_node_of(e, s)
        a = e.a
        if !Arena.can_be_null(a, node) {
            best
        } else {
            loc = if pos == 0 { Deriv.loc_both } else { Deriv.loc_end }
            b1 = if Dfa.fresh_at(a, node, loc) { Ok(pos) } else { best }
            List.fold(Dfa.pend_at(a, node, loc), b1, |b, p| Dfa.max_end(b, pos - Arena.ps(p).to_u64()))
        }
    }

    # --- llmatch -----------------------------------------------------------------

    Spans : { e : Dfa.E, spans : List({ start : U64, end : U64 }) }

    find_all : Dfa.E, Ref.Hay -> Dfa.Spans
    find_all = |e, h| {
        st = Dfa.starts(e, h)
        # RE# walks `starts` backwards assuming it is right-to-left, but lookaround
        # resolutions record positions out of order (log, "RE# divergences" 2), so
        # sort ascending first; skip starts inside the previous match
        sorted_starts = List.sort_with(st.acc, |x, y| U64.order_relative_to(x, y)) |> Dfa.dedup
        fin = List.fold(sorted_starts, { e: st.e, spans: [], next_valid: 0 }, |acc, s|
            if s < acc.next_valid {
                acc
            } else {
                r = Dfa.ends_from(acc.e, h, s)
                match r.end {
                    Ok(en) => { e: r.e, spans: List.append(acc.spans, { start: s, end: en }), next_valid: en }
                    # a recorded start always has an end; keep going if it somehow does not
                    Err(_) => { ..acc, e: r.e }
                }
            })
        { e: fin.e, spans: fin.spans }
    }

    ## Is the reverse sweep's output already in descending position order? It is
    ## unless pending nullables (lookaheads) resolved positions out of order,
    ## which is the case RE# gets wrong and this port sorts for.
    is_descending : List(U64) -> Bool
    is_descending = |sts| {
        n = List.len(sts)
        var i = 1
        var desc = True
        while desc and i < n {
            desc = (List.get(sts, i) ?? 0) <= (List.get(sts, i - 1) ?? 0)
            i = i + 1
        }
        desc
    }

    dedup : List(U64) -> List(U64)
    dedup = |xs| List.fold(xs, [], |acc, x| if List.last(acc) == Ok(x) { acc } else { List.append(acc, x) })

    # --- complete folds: byte loops over the fused table, no threading -----------
    #
    # Everything a complete fold needs is read-only, so these scans take `e` by
    # reference, index the haystack directly (ASCII through `atable`, other
    # symbols through the trie), and report byte offsets. Pending-nullable
    # offsets are symbol counts, so they move by `Utf8.advance`/`retreat`.

    ## The accelerators the fast scans consult (S13; built by `Accel`)
    Init : [NoInit, Prefix(Rlit.Prefix), Potential(Rlit.Prefix)]
    ## RE#'s `LengthLookup`, how the end pass finds a match's end. Lengths are
    ## in symbols. `PrefixEnd(k, st)`: the first `k` symbols are fixed, scan
    ## from there in state `st`. `SetLookup(k, cls, nk, tab)`: after `k`
    ## symbols the match ends at the first symbol of class `cls` (`tab` its
    ## ASCII bytes as a `Bset` table), inclusive when `nk` is CurrentNull.
    ## `RemainingSets(k, cls, m)`: `k` symbols then up to `m` symbols of `cls`.
    Len : [MatchEnd, FixedLength(U32), PrefixEnd(U32, U32), SetLookup(U32, U32, U8, List(U8)), RemainingSets(U32, U32, U32)]
    Override : [NoOverride, Literal(List(U8))]
    Accels : { init : Dfa.Init, len : Dfa.Len, override : Dfa.Override }

    ## RE#'s llmatch on a complete fold, as byte spans
    find_all_fast : Dfa.E, Trie.T, Dfa.Accels, List(U8) -> List({ start : U64, end : U64 })
    find_all_fast = |e, t, ac, hay| Dfa.find_all_fast_opts(e, t, ac, hay, True)

    ## `skip` turns the per-state skip sets off (A/B measurement)
    find_all_fast_opts : Dfa.E, Trie.T, Dfa.Accels, List(U8), Bool -> List({ start : U64, end : U64 })
    find_all_fast_opts = |e, t, ac, hay, skip|
        match ac.override {
            Literal(lit) => Dfa.find_all_literal(hay, lit)
            NoOverride => {
                sk = skip and e.any_skip
                raw = Dfa.starts_fast_opts(e, t, ac.init, hay, sk)
                # RE#'s `llmatch_ends` walks its accumulator backwards, which is
                # already ascending position order, instead of materializing a
                # sorted copy. That copy cost 15-25% of the scan on a dense class,
                # where the sweep records 5-9 starts for every match it keeps. The
                # sort is still needed when lookarounds resolved out of order.
                desc = Dfa.is_descending(raw)
                sts = if desc { raw } else { List.sort_with(raw, |x, y| U64.order_relative_to(x, y)) }
                Dfa.ends_fast(e, t, ac.len, hay, sts, sk, desc)
            }
        }

    ## The forward end pass over the starts (RE#'s `llmatch_ends`), read
    ## backwards when `descending` so that no ordered copy is needed: a
    ## start inside the previous match is dropped, every other start gets the
    ## longest end from `s_noprefix`. One function, `while` loops, tables bound
    ## once: calling `end_fast` per start passed the engine record each time
    ## (4.9 ms against 0.5 ms for 40k matches), and a `List.fold` closure over
    ## the starts copied its captured environment per start (8 ms for 262k).
    ends_fast : Dfa.E, Trie.T, Dfa.Len, List(U8), List(U64), Bool, Bool -> List({ start : U64, end : U64 })
    ends_fast = |e, t, len, hay, sts, skip, descending| {
        n = List.len(hay)
        at = e.atable
        nks = e.st_nk
        # an empty table when skipping is off: `List.get ?? 0` then never says 1, and
        # the loop carries no Bool (a runtime `skip and …` per step cost ~1.5 ns)
        skip_ok = if skip { e.skip_ok } else { [] }
        skip_lo = e.skip_lo
        table = e.table
        nmt = e.nmt.to_u64()
        # the length lookup as scalars (a tag union live across the loop is slow)
        kind = match len { MatchEnd => 0, FixedLength(_) => 1, PrefixEnd(_, _) => 2, SetLookup(_, _, _, _) => 3, RemainingSets(_, _, _) => 4 }
        plen = match len { FixedLength(k) => k.to_u64(), PrefixEnd(k, _) => k.to_u64(), SetLookup(k, _, _, _) => k.to_u64(), RemainingSets(k, _, _) => k.to_u64(), MatchEnd => 0 }
        s_start = match len { PrefixEnd(_, st) => st, _ => e.s_noprefix }
        cls = match len { SetLookup(_, c, _, _) => c, RemainingSets(_, c, _) => c, _ => 0 }
        nkd = match len { SetLookup(_, _, k, _) => k, _ => 0 }
        rem = match len { RemainingSets(_, _, r) => r.to_u64(), _ => 0 }
        tab = match len { SetLookup(_, _, _, tb) => tb, _ => [] }
        ascii = t.ascii
        n_sts = List.len(sts)
        var spans = []
        var next_valid = 0
        # the previous start considered. Equal starts are adjacent in position
        # order, so this does the deduplication the sorted copy used to do.
        var prev = 0xFFFF_FFFF_FFFF_FFFF
        var i = 0
        while i < n_sts {
            start = if descending { List.get(sts, n_sts - 1 - i) ?? 0 } else { List.get(sts, i) ?? 0 }
            i = i + 1
            dup = start == prev
            prev = start
            if dup or start < next_valid {
                {}
            } else if kind == 1 {
                en = Utf8.advance(hay, start, plen)
                spans = List.append(spans, { start, end: en })
                next_valid = en
            } else if kind == 3 {
                # `llmatch_ends_setlookup_mt`: the first symbol of `cls` after the prefix
                var pos = Utf8.advance(hay, start, plen)
                var found = False
                while found == False and pos < n {
                    match Bset.find(hay, tab, 0, pos) {
                        Err(_) => {
                            pos = n
                        }
                        Ok(p) => {
                            b = List.get(hay, p) ?? 0
                            if b < 0x80 {
                                pos = p
                                found = True
                            } else {
                                d = Utf8.decode(hay, p)
                                c = if d.ok { Trie.class_of(t, d.cp) } else { t.invalid }
                                if c == cls {
                                    pos = p
                                    found = True
                                } else {
                                    pos = p + d.len
                                }
                            }
                        }
                    }
                }
                en = if nkd == Dfa.nk_current and pos < n { Utf8.advance(hay, pos, 1) } else { pos }
                spans = List.append(spans, { start, end: en })
                next_valid = en
            } else if kind == 4 {
                # `llmatch_ends_remaining_set`: up to `rem` more symbols of `cls`
                var pos = start
                var j = 0
                while j < plen {
                    pb = List.get(hay, pos) ?? 0
                    pos = if pb < 0x80 { pos + 1 } else { pos + (Utf8.decode(hay, pos)).len }
                    j = j + 1
                }
                var c = 0
                var go = True
                while go and c < rem and pos < n {
                    b = List.get(hay, pos) ?? 0
                    if b < 0x80 {
                        if (List.get(ascii, b.to_u64()) ?? 0).to_u32() == cls {
                            pos = pos + 1
                            c = c + 1
                        } else {
                            go = False
                        }
                    } else {
                        d = Utf8.decode(hay, pos)
                        cc = if d.ok { Trie.class_of(t, d.cp) } else { t.invalid }
                        if cc == cls {
                            pos = pos + d.len
                            c = c + 1
                        } else {
                            go = False
                        }
                    }
                }
                spans = List.append(spans, { start, end: pos })
                next_valid = pos
            } else {
                # MatchEnd, or PrefixEnd: scan from the start (or past the fixed prefix)
                var pos0 = start
                var j = 0
                while j < plen {
                    pb = List.get(hay, pos0) ?? 0
                    pos0 = if pb < 0x80 { pos0 + 1 } else { pos0 + (Utf8.decode(hay, pos0)).len }
                    j = j + 1
                }
                if pos0 >= n {
                    match Dfa.at_eoi_fast(e, s_start, hay, n, Err(NoEnd)) {
                        Ok(en) => {
                            spans = List.append(spans, { start, end: en })
                            next_valid = en
                        }
                        Err(_) => {}
                    }
                } else {
                    var pos = pos0
                    var s = s_start
                    # an anchor that survived `without_lookback_prefix` behind a nullable
                    # head (`_*\A`) is nullable only at the input start, which the
                    # NullKind check inside the loop never sees
                    var best = if pos0 == 0 and Dfa.flags(e, s_start).bitwise_and(Dfa.fl_anchor_null) != 0 and Deriv.nullable(e.a, Deriv.loc_begin, Dfa.st_node_of(e, s_start)) { Ok(0) } else { Err(NoEnd) }
                    while s != Dfa.dead {
                        b0 = List.get(hay, pos) ?? 0
                        # RE#'s forward `CanSkip`: the state loops on every byte up to the
                        # nearest member; the last such position is the best end, so jump
                        # there (never past the last byte: the regular step then reaches
                        # the end-of-input handling)
                        if (List.get(skip_ok, s.to_u64()) ?? 0) == 1 and !Bset.member(skip_lo, s.to_u64(), b0) {
                            pos =
                                match Bset.find(hay, skip_lo, s.to_u64(), pos + 1) {
                                    Ok(p) => p
                                    Err(_) => n - 1
                                }
                        }
                        k = List.get(nks, s.to_u64()) ?? Dfa.nk_notnull
                        if k == Dfa.nk_current {
                            best = Ok(pos)
                        } else if k == Dfa.nk_prev {
                            best = Ok(Utf8.retreat(hay, pos, 1))
                        } else if k != Dfa.nk_notnull {
                            best = Dfa.null_fallback_fast(e, s, hay, pos, best)
                        }
                        b = List.get(hay, pos) ?? 0
                        if b < 0x80 {
                            s = (List.get(at, s.to_u64() * 128 + b.to_u64()) ?? Dfa.dead16).to_u32()
                            pos = pos + 1
                        } else {
                            d = Utf8.decode(hay, pos)
                            cc = if d.ok { Trie.class_of(t, d.cp) } else { t.invalid }
                            s = List.get(table, s.to_u64() * nmt + cc.to_u64()) ?? Dfa.dead
                            pos = pos + d.len
                        }
                        if pos >= n {
                            best = Dfa.at_eoi_fast(e, s, hay, n, best)
                            s = Dfa.dead
                        }
                    }
                    match best {
                        Ok(en) => {
                            spans = List.append(spans, { start, end: en })
                            next_valid = en
                        }
                        Err(_) => {}
                    }
                }
            }
        }
        spans
    }

    find_all_literal : List(U8), List(U8) -> List({ start : U64, end : U64 })
    find_all_literal = |hay, lit| {
        plen = List.len(lit)
        cands = Teddy.byte_candidates_capped(List.get(lit, 0) ?? 0, hay, List.len(hay) + 1) ?? []
        fin = List.fold(cands, { spans: [], last_end: 0 }, |acc, at|
            if at < acc.last_end or !(Lit.matches(hay, at, lit, plen)) {
                acc
            } else {
                { spans: List.append(acc.spans, { start: at, end: at + plen }), last_end: at + plen }
            })
        fin.spans
    }

    # next state on the symbol ending at `pos`; returns the state and the symbol's start
    step_rev_fast : Dfa.E, Trie.T, List(U8), U32, U64 -> { s : U32, cs : U64 }
    step_rev_fast = |e, t, hay, s, pos| {
        b = List.get(hay, pos - 1) ?? 0
        if b < 0x80 {
            { s: (List.get(e.atable, s.to_u64() * 128 + b.to_u64()) ?? Dfa.dead16).to_u32(), cs: pos - 1 }
        } else {
            d = Utf8.decode_rev(hay, pos)
            cls = if d.ok { Trie.class_of(t, d.cp) } else { t.invalid }
            { s: List.get(e.table, s.to_u64() * e.nmt.to_u64() + cls.to_u64()) ?? Dfa.dead, cs: d.cs }
        }
    }

    ## the reverse sweep on a complete fold: match-start byte offsets
    starts_fast : Dfa.E, Trie.T, Dfa.Init, List(U8) -> List(U64)
    starts_fast = |e, t, ini, hay| Dfa.starts_fast_opts(e, t, ini, hay, True)

    starts_fast_opts : Dfa.E, Trie.T, Dfa.Init, List(U8), Bool -> List(U64)
    starts_fast_opts = |e, t, ini, hay, skip| {
        n = List.len(hay)
        if n == 0 {
            if Deriv.nullable(e.a, Deriv.loc_both, Dfa.st_node_of(e, e.s_rev_ts)) { [0] } else { [] }
        } else {
            s0 = e.s_rev_ts
            node = Dfa.st_node_of(e, s0)
            f = Dfa.flags(e, s0)
            null_at_end = f.bitwise_and(Dfa.fl_always) != 0 or Deriv.nullable(e.a, Deriv.loc_end, node)
            st =
                if !(null_at_end or Arena.depends_anchor(e.a, node)) {
                    { s: s0, pos: n, acc: [] }
                } else {
                    acc0 = if null_at_end { if f.bitwise_and(Dfa.fl_pending) != 0 { Dfa.add_pending_fast(e, s0, [], hay, n) } else { [n] } } else { [] }
                    d = Utf8.decode_rev(hay, n)
                    cls = if d.ok { Trie.class_of(t, d.cp) } else { t.invalid }
                    # the fold fills End transitions only for an anchor-dependent
                    # start; otherwise End equals Center
                    s1e = List.get(e.end_table, s0.to_u64() * e.nmt.to_u64() + cls.to_u64()) ?? 0
                    s1 = if s1e != 0 { s1e } else { List.get(e.table, s0.to_u64() * e.nmt.to_u64() + cls.to_u64()) ?? Dfa.dead }
                    pos = d.cs
                    if pos != 0 {
                        { s: s1, pos, acc: if Dfa.is_null(e, s1) { Dfa.set_null_fast(e, s1, acc0, hay, pos) } else { acc0 } }
                    } else {
                        nd = Dfa.st_node_of(e, s1)
                        really = Dfa.flags(e, s1).bitwise_and(Dfa.fl_always) != 0 or Deriv.nullable(e.a, Deriv.loc_begin, nd)
                        acc1 =
                            if really {
                                k = Dfa.nk(e, s1)
                                if k == Dfa.nk_current or k == Dfa.nk_prev {
                                    List.append(acc0, Utf8.advance(hay, 0, k.to_u64()))
                                } else {
                                    pairs = Arena.rs_get(e.a, List.get(e.st_pend, s1.to_u64()) ?? 0)
                                    if List.is_empty(pairs) { List.append(acc0, 0) } else { Dfa.add_pairs_fast(acc0, pairs, hay, 0) }
                                }
                            } else {
                                acc0
                            }
                        { s: s1, pos, acc: acc1 }
                    }
                }
            col = Dfa.collect_fast(e, t, ini, hay, st.pos, st.s, st.acc, skip)
            Dfa.start_fast(e, col.s, col.acc, hay)
        }
    }

    # `collect_skip`: in the start state, a required prefix lets the sweep jump
    # to the prefix's last occurrence and land in the state it leads to (RE#'s
    # `TrySkipInitialRevChar`); no match can start in the skipped stretch. In
    # any state with a skip set, the sweep jumps to the nearest byte that
    # changes the state (RE#'s `skip_active_rev`).
    #
    # The two loops are separate functions with nothing but scalars and the
    # lists they read alive: a single loop that matched on the accelerator
    # value, or merely had the prefix record in scope, ran 4-35x slower
    # (measured 4.6 ms and 36 ms against 1.1 ms for 256 KB of `[A-Za-z]+`).
    collect_fast : Dfa.E, Trie.T, Dfa.Init, List(U8), U64, U32, List(U64), Bool -> { s : U32, acc : List(U64) }
    collect_fast = |e, t, ini, hay, pos0, s0, acc0, skip|
        match ini {
            NoInit => Dfa.collect_plain(e, t, hay, pos0, s0, acc0, skip)
            Prefix(pf) => Dfa.collect_prefix(e, t, pf, hay, pos0, s0, acc0, skip)
            Potential(pf) => Dfa.collect_prefix(e, t, pf, hay, pos0, s0, acc0, skip)
        }

    collect_plain : Dfa.E, Trie.T, List(U8), U64, U32, List(U64), Bool -> { s : U32, acc : List(U64) }
    collect_plain = |e, t, hay, pos0, s0, acc0, skip| {
        # The tables the loop reads are bound once, and every append to `acc`
        # is written out in this function: passing the engine record to a
        # helper per step cost 4-5x, and mixing inline appends with appends
        # inside a helper that took `acc` corrupted the heap (a Roc
        # miscompile, see upstream/2026-09-05-sharp-var-list-append).
        at = e.atable
        nks = e.st_nk
        # an empty table when skipping is off: `List.get ?? 0` then never says 1, and
        # the loop carries no Bool (a runtime `skip and …` per step cost ~1.5 ns)
        skip_ok = if skip { e.skip_ok } else { [] }
        skip_lo = e.skip_lo
        table = e.table
        nmt = e.nmt.to_u64()
        var pos = pos0
        var s = s0
        var acc = acc0
        while pos > 0 {
            b = List.get(hay, pos - 1) ?? 0
            if (List.get(skip_ok, s.to_u64()) ?? 0) == 1 and !Bset.member(skip_lo, s.to_u64(), b) {
                # RE#'s `skip_active_rev`: the state loops on every byte back to
                # the nearest member, so each skipped position (all ASCII, one
                # byte per symbol) is a match start when the state is nullable
                np =
                    match Bset.rfind(hay, skip_lo, s.to_u64(), pos - 1) {
                        Ok(p) => p + 1
                        Err(_) => 0
                    }
                k = List.get(nks, s.to_u64()) ?? Dfa.nk_notnull
                if k != Dfa.nk_notnull {
                    var p = pos
                    while p > np {
                        p = p - 1
                        if k == Dfa.nk_current {
                            acc = List.append(acc, p)
                        } else if k == Dfa.nk_prev {
                            acc = List.append(acc, Utf8.advance(hay, p, 1))
                        } else {
                            extra = Dfa.pend_positions(e, s, hay, p)
                            var j = 0
                            while j < List.len(extra) {
                                acc = List.append(acc, List.get(extra, j) ?? 0)
                                j = j + 1
                            }
                        }
                    }
                }
                pos = np
            } else {
                if b < 0x80 {
                    s = (List.get(at, s.to_u64() * 128 + b.to_u64()) ?? Dfa.dead16).to_u32()
                    pos = pos - 1
                } else {
                    d = Utf8.decode_rev(hay, pos)
                    cls = if d.ok { Trie.class_of(t, d.cp) } else { t.invalid }
                    s = List.get(table, s.to_u64() * nmt + cls.to_u64()) ?? Dfa.dead
                    pos = d.cs
                }
                k = List.get(nks, s.to_u64()) ?? Dfa.nk_notnull
                if k == Dfa.nk_current {
                    acc = List.append(acc, pos)
                } else if k == Dfa.nk_prev {
                    acc = List.append(acc, Utf8.advance(hay, pos, 1))
                } else if k != Dfa.nk_notnull {
                    extra = Dfa.pend_positions(e, s, hay, pos)
                    var j = 0
                    while j < List.len(extra) {
                        acc = List.append(acc, List.get(extra, j) ?? 0)
                        j = j + 1
                    }
                }
            }
        }
        { s, acc }
    }

    collect_prefix : Dfa.E, Trie.T, Rlit.Prefix, List(U8), U64, U32, List(U64), Bool -> { s : U32, acc : List(U64) }
    collect_prefix = |e, t, pf, hay, pos0, s0, acc0, skip| {
        at = e.atable
        nks = e.st_nk
        # an empty table when skipping is off: `List.get ?? 0` then never says 1, and
        # the loop carries no Bool (a runtime `skip and …` per step cost ~1.5 ns)
        skip_ok = if skip { e.skip_ok } else { [] }
        skip_lo = e.skip_lo
        table = e.table
        nmt = e.nmt.to_u64()
        start_state = e.s_rev_ts
        land = pf.state
        lands = pf.land
        var pos = pos0
        var s = s0
        var acc = acc0
        while pos > 0 {
            if s == start_state {
                # an exact prefix: jump to its start and land; a potential start: resume
                # at the occurrence's end and re-read it, stepping once when the
                # occurrence ends right here so the sweep always progresses
                match Rlit.rfind_sets(hay, t, pf, pos) {
                    Ok(occ) => {
                        if lands {
                            pos = occ.start
                            s = land
                        } else if occ.end < pos {
                            pos = occ.end
                        } else {
                            b = List.get(hay, pos - 1) ?? 0
                            if b < 0x80 {
                                s = (List.get(at, s.to_u64() * 128 + b.to_u64()) ?? Dfa.dead16).to_u32()
                                pos = pos - 1
                            } else {
                                d = Utf8.decode_rev(hay, pos)
                                cls = if d.ok { Trie.class_of(t, d.cp) } else { t.invalid }
                                s = List.get(table, s.to_u64() * nmt + cls.to_u64()) ?? Dfa.dead
                                pos = d.cs
                            }
                        }
                    }
                    Err(_) => {
                        pos = 0
                    }
                }
                k = List.get(nks, s.to_u64()) ?? Dfa.nk_notnull
                if k == Dfa.nk_current {
                    acc = List.append(acc, pos)
                } else if k == Dfa.nk_prev {
                    acc = List.append(acc, Utf8.advance(hay, pos, 1))
                } else if k != Dfa.nk_notnull {
                    extra = Dfa.pend_positions(e, s, hay, pos)
                    var j = 0
                    while j < List.len(extra) {
                        acc = List.append(acc, List.get(extra, j) ?? 0)
                        j = j + 1
                    }
                }
            } else {
                b = List.get(hay, pos - 1) ?? 0
                if (List.get(skip_ok, s.to_u64()) ?? 0) == 1 and !Bset.member(skip_lo, s.to_u64(), b) {
                    # RE#'s `skip_active_rev`: the state loops on every byte back to
                    # the nearest member, so each skipped position (all ASCII, one
                    # byte per symbol) is a match start when the state is nullable
                    np =
                        match Bset.rfind(hay, skip_lo, s.to_u64(), pos - 1) {
                            Ok(p) => p + 1
                            Err(_) => 0
                        }
                    k = List.get(nks, s.to_u64()) ?? Dfa.nk_notnull
                    if k != Dfa.nk_notnull {
                        var p = pos
                        while p > np {
                            p = p - 1
                            if k == Dfa.nk_current {
                                acc = List.append(acc, p)
                            } else if k == Dfa.nk_prev {
                                acc = List.append(acc, Utf8.advance(hay, p, 1))
                            } else {
                                extra = Dfa.pend_positions(e, s, hay, p)
                                var j = 0
                                while j < List.len(extra) {
                                    acc = List.append(acc, List.get(extra, j) ?? 0)
                                    j = j + 1
                                }
                            }
                        }
                    }
                    pos = np
                } else {
                    if b < 0x80 {
                        s = (List.get(at, s.to_u64() * 128 + b.to_u64()) ?? Dfa.dead16).to_u32()
                        pos = pos - 1
                    } else {
                        d = Utf8.decode_rev(hay, pos)
                        cls = if d.ok { Trie.class_of(t, d.cp) } else { t.invalid }
                        s = List.get(table, s.to_u64() * nmt + cls.to_u64()) ?? Dfa.dead
                        pos = d.cs
                    }
                    k = List.get(nks, s.to_u64()) ?? Dfa.nk_notnull
                    if k == Dfa.nk_current {
                        acc = List.append(acc, pos)
                    } else if k == Dfa.nk_prev {
                        acc = List.append(acc, Utf8.advance(hay, pos, 1))
                    } else if k != Dfa.nk_notnull {
                        extra = Dfa.pend_positions(e, s, hay, pos)
                        var j = 0
                        while j < List.len(extra) {
                            acc = List.append(acc, List.get(extra, j) ?? 0)
                            j = j + 1
                        }
                    }
                }
            }
        }
        { s, acc }
    }

    ## the positions a pending-nullable state marks at `pos` (fresh list)
    pend_positions : Dfa.E, U32, List(U8), U64 -> List(U64)
    pend_positions = |e, s, hay, pos|
        Dfa.add_pairs_fast([], Arena.rs_get(e.a, List.get(e.st_pend, s.to_u64()) ?? 0), hay, pos)

    start_fast : Dfa.E, U32, List(U64), List(U8) -> List(U64)
    start_fast = |e, s, acc, hay| {
        # see `handle_input_start`
        node = Dfa.st_node_of(e, s)
        a = e.a
        if Dfa.flags(e, s).bitwise_and(Dfa.fl_always) != 0 or Deriv.nullable(a, Deriv.loc_begin, node) {
            tail = List.take_last(acc, 8)
            fresh = List.keep_if(Dfa.add_pairs_fast([], Dfa.pend_at(a, node, Deriv.loc_begin), hay, 0), |p| !List.contains(tail, p))
            acc1 = List.concat(acc, fresh)
            if Dfa.fresh_at(a, node, Deriv.loc_begin) and !List.contains(tail, 0) and !List.contains(fresh, 0) { List.append(acc1, 0) } else { acc1 }
        } else {
            acc
        }
    }

    set_null_fast : Dfa.E, U32, List(U64), List(U8), U64 -> List(U64)
    set_null_fast = |e, s, acc, hay, pos| {
        k = Dfa.nk(e, s)
        if k == Dfa.nk_current {
            List.append(acc, pos)
        } else if k == Dfa.nk_prev {
            List.append(acc, Utf8.advance(hay, pos, 1))
        } else {
            Dfa.add_pending_fast(e, s, acc, hay, pos)
        }
    }

    add_pending_fast : Dfa.E, U32, List(U64), List(U8), U64 -> List(U64)
    add_pending_fast = |e, s, acc, hay, pos|
        Dfa.add_pairs_fast(acc, Arena.rs_get(e.a, List.get(e.st_pend, s.to_u64()) ?? 0), hay, pos)

    add_pairs_fast : List(U64), List(U32), List(U8), U64 -> List(U64)
    add_pairs_fast = |acc, pairs, hay, pos|
        List.fold_rev(pairs, acc, |p, ac| {
            s = Arena.ps(p).to_u64()
            en = Arena.pe(p).to_u64()
            List.fold(Arena.upto(en - s + 1), ac, |ac2, i| List.append(ac2, Utf8.advance(hay, pos, en - i)))
        })

    ## the forward end pass on a complete fold, from byte offset `start`
    end_fast : Dfa.E, Trie.T, List(U8), U64 -> Try(U64, [NoEnd])
    end_fast = |e, t, hay, start| Dfa.end_fast_opts(e, t, hay, start, True)

    end_fast_opts : Dfa.E, Trie.T, List(U8), U64, Bool -> Try(U64, [NoEnd])
    end_fast_opts = |e, t, hay, start, skip| {
        n = List.len(hay)
        if start >= n {
            Dfa.at_eoi_fast(e, e.s_noprefix, hay, n, Err(NoEnd))
        } else {
            at = e.atable
            nks = e.st_nk
            # an empty table when skipping is off: `List.get ?? 0` then never says 1, and
            # the loop carries no Bool (a runtime `skip and …` per step cost ~1.5 ns)
            skip_ok = if skip { e.skip_ok } else { [] }
            skip_lo = e.skip_lo
            table = e.table
            nmt = e.nmt.to_u64()
            var pos = start
            var s = e.s_noprefix
            var best = Err(NoEnd)
            while s != Dfa.dead {
                b0 = List.get(hay, pos) ?? 0
                # RE#'s forward `CanSkip`: the state loops on every byte up to the
                # nearest member; the last such position is the best end, so jump
                # there (never past the last byte: the regular step then reaches
                # the end-of-input handling)
                if (List.get(skip_ok, s.to_u64()) ?? 0) == 1 and !Bset.member(skip_lo, s.to_u64(), b0) {
                    pos =
                        match Bset.find(hay, skip_lo, s.to_u64(), pos + 1) {
                            Ok(p) => p
                            Err(_) => n - 1
                        }
                }
                k = List.get(nks, s.to_u64()) ?? Dfa.nk_notnull
                if k == Dfa.nk_current {
                    best = Ok(pos)
                } else if k == Dfa.nk_prev {
                    best = Ok(Utf8.retreat(hay, pos, 1))
                } else if k != Dfa.nk_notnull {
                    best = Dfa.null_fallback_fast(e, s, hay, pos, best)
                }
                b = List.get(hay, pos) ?? 0
                if b < 0x80 {
                    s = (List.get(at, s.to_u64() * 128 + b.to_u64()) ?? Dfa.dead16).to_u32()
                    pos = pos + 1
                } else {
                    d = Utf8.decode(hay, pos)
                    cls = if d.ok { Trie.class_of(t, d.cp) } else { t.invalid }
                    s = List.get(table, s.to_u64() * nmt + cls.to_u64()) ?? Dfa.dead
                    pos = pos + d.len
                }
                if pos >= n {
                    best = Dfa.at_eoi_fast(e, s, hay, n, best)
                    s = Dfa.dead
                }
            }
            best
        }
    }

    null_fallback_fast : Dfa.E, U32, List(U8), U64, Try(U64, [NoEnd]) -> Try(U64, [NoEnd])
    null_fallback_fast = |e, s, hay, pos, best|
        if Dfa.flags(e, s).bitwise_and(Dfa.fl_pending) != 0 {
            Dfa.max_end(best, Utf8.retreat(hay, pos, (List.get(e.st_minpend, s.to_u64()) ?? 0).to_u64()))
        } else {
            Ok(pos)
        }

    at_eoi_fast : Dfa.E, U32, List(U8), U64, Try(U64, [NoEnd]) -> Try(U64, [NoEnd])
    at_eoi_fast = |e, s, hay, pos, best| {
        # see `at_eoi`
        node = Dfa.st_node_of(e, s)
        a = e.a
        if !Arena.can_be_null(a, node) {
            best
        } else {
            loc = if pos == 0 { Deriv.loc_both } else { Deriv.loc_end }
            b1 = if Dfa.fresh_at(a, node, loc) { Ok(pos) } else { best }
            List.fold(Dfa.pend_at(a, node, loc), b1, |b, p| Dfa.max_end(b, Utf8.retreat(hay, pos, Arena.ps(p).to_u64())))
        }
    }

}
