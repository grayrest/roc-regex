## Accelerators derived from the node graph (RE#'s `Optimizations.fs`),
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
import Rrun
import Teddy
import TSet
import Trie
import Utf8

Accel := [].{
    T : {
        init : Dfa.Init,
        len : Dfa.Len,
        # `Literal` carries the literal, the same bytes padded to a 16-lane
        # vector, and the lane mask for its length, so the scan allocates
        # nothing before it looks at a byte.
        override : [NoOverride, Literal(List(U8), List(U8), U16)],
    }

    none : Accel.T
    none = { init: NoInit, len: MatchEnd, override: NoOverride }

    ## `scan` rides here rather than in `Accel.T`: that record is `Dfa.Accels`,
    ## which every fast scan takes as an argument, and widening it cost 15-19%
    ## on `caps_email` and `.*Holmes`. It is read once per search.
    R : { e : Dfa.E, accel : Accel.T, scan : Dfa.Scan }

    ## Analyze the pattern: `root` is the raw pattern, `rev` its reverse,
    ## `rev_ts` `_*·rev`, `noprefix` the forward pattern. May create the prefix's
    ## landing state.
    analyze : Dfa.E, Trie.T, U32, U32, U32, U32 -> Accel.R
    analyze = |e, t, root, rev, rev_ts, noprefix| {
        a = e.a
        sets = Accel.prefix_sets(a, rev)
        raw_prefix = Accel.set_prefix(e, t, sets, rev_ts)
        resolved_prefix =
            match raw_prefix.init {
                NoInit => { e: raw_prefix.e, init: Accel.potential_start(t, Accel.potential_sets(raw_prefix.e.a, rev), raw_prefix.e.s_rev_ts) }
                _ => raw_prefix
            }
        len_result = Accel.infer_len(resolved_prefix.e, t, noprefix)
        len = len_result.len
        # the pattern is exactly a literal (RE#'s `inferOverrideRegex`, which looks
        # at the RAW pattern: a lookbehind stripped from `noprefix` still rules it out)
        override =
            match (Accel.literal_of(t, sets), len) {
                (Ok(lit), FixedLength(n)) =>
                    if n.to_u64() == List.len(sets) and !Arena.depends_anchor(resolved_prefix.e.a, root) and !Arena.contains_look(resolved_prefix.e.a, root) and !Arena.depends_anchor(resolved_prefix.e.a, rev) {
                        Literal(lit, Accel.pad16(lit), Accel.lane_mask(lit))
                    } else {
                        NoOverride
                    }
                _ => NoOverride
            }
        # the strongest of the three: it replaces the sweep rather than
        # accelerating it, so it wins where it applies
        init =
            match Accel.class_run(resolved_prefix.e.a, t, rev) {
                Ok(spec) => ClassRun(spec)
                Err(_) => resolved_prefix.init
            }
        scan =
            match override {
                NoOverride => Accel.class_runs(len_result.e, t, root, noprefix, resolved_prefix.init)
                _ => NoScan
            }
        { e: len_result.e, accel: { init, len, override }, scan }
    }

    ## Can the scan find its own starts, and skip the reverse sweep entirely?
    ##
    ## RE#'s llmatch sweeps `_*·rev(R)` right to left to collect every match
    ## START, then runs a forward end pass from each. On `\w+\s+\w+` that sweep
    ## is 44% of the row and yields 210198 starts for 21091 matches. It cannot
    ## be shortened -- the reverse state at `p` summarises every byte to the
    ## RIGHT of `p`, so it has to read the whole haystack before the first start
    ## is known -- but for one shape of pattern it can be replaced.
    ##
    ## When `R = C+ · rest` with `C` a single class and the repeat unbounded,
    ## every match start is a position in `C`, and for `p < q` inside one run of
    ## `C`:
    ##
    ##   * `q` a start implies `p` a start, and
    ##   * `end(p) >= end(q)`
    ##
    ## both because any split `C+` takes from `q` is also available from `p`,
    ## which just gives `C+` more to absorb. So a scan for `C` finds every start
    ## in order, and a candidate that FAILS lets the rest of its run be skipped.
    ##
    ## The repeat must be unbounded. `[0-9]{2,4}` on "12345" has `end(0) = 4`
    ## and `end(1) = 5`, so a later start outlives an earlier one and leftmost
    ## alone stops being enough. That shape is `Rrun`'s, not this one's.
    ##
    ## `rest` is unconstrained -- the argument only needs the split point to be
    ## reachable -- but a LEADING lookbehind is fatal: `without_lookback_prefix`
    ## strips it into `noprefix`, so the forward pass never tests it and only
    ## the sweep did. Hence `np == root`.
    ##
    ## Gated to `init == NoInit`: a pattern whose sweep already skips between
    ## anchor bytes -- `(\w+)@(\w+)` finds its 779 starts in 70 us -- would be
    ## an order of magnitude worse reading every byte forward. `Regex.compile`
    ## adds `not any_skip` for the same reason, once the fold is frozen.
    class_runs : Dfa.E, Trie.T, U32, U32, Dfa.Init -> Dfa.Scan
    class_runs = |e, t, root, np, init| {
        a = e.a
        head = if Arena.is_concat(a, root) { Arena.head(a, root) } else { root }
        if init != NoInit or np != root or Arena.depends_anchor(a, root) {
            NoScan
        } else if !Arena.is_loop(a, head) or Arena.loop_lo(a, head) < 1 or Arena.loop_hi(a, head) != Arena.inf {
            NoScan
        } else {
            body = Arena.head(a, head)
            if !Arena.is_singleton(a, body) {
                NoScan
            } else {
                cls = Arena.tset(a, body)
                bytes = Accel.ascii_bytes(t, cls)
                comp = List.keep_if(Arena.upto(128), |b| !List.contains(bytes, b.to_u8_wrap())) |> List.map(|b| b.to_u8_wrap())
                stops = TSet.intersects(cls, Dfa.nonascii_classes(t))
                if List.is_empty(bytes) and stops {
                    NoScan
                } else {
                    ClassRuns({ tab: Bset.table(bytes), stops, ctab: Bset.table(comp), exact: !stops })
                }
            }
        }
    }

    ## `Rrun`'s gate: is the reversed pattern one set of minterms repeated at
    ## least `lo >= 1` times, with no non-ASCII codepoint in it? Then a match
    ## starts exactly where `lo` symbols of that set do, and the sweep is a
    ## scan for its runs (see `Rrun`).
    ##
    ## `lo == 0` is excluded and not an oversight: `S{0,n}` is nullable at
    ## EVERY position, including ones with no symbol of `S` at all, which no
    ## enumeration of `S`-runs can produce.
    class_run : Arena.A, Trie.T, U32 -> Try(Rrun.Spec, [NotRun])
    class_run = |a, t, rev| {
        looped = Arena.is_loop(a, rev)
        body = if looped { Arena.head(a, rev) } else { rev }
        lo = if looped { Arena.loop_lo(a, rev).to_u64() } else { 1 }
        body_ts = Arena.tset(a, body)
        if !Arena.is_singleton(a, body) or body_ts == 0 or lo < 1 or TSet.inter(body_ts, Dfa.nonascii_classes(t)) != 0 {
            Err(NotRun)
        } else {
            bytes = Accel.ascii_bytes(t, body_ts)
            if List.is_empty(bytes) { Err(NotRun) } else { Ok({ tab: Bset.table(bytes), lo }) }
        }
    }

    ## the literal padded to 16 bytes, so a scan can load it as one vector
    pad16 : List(U8) -> List(U8)
    pad16 = |lit| List.take_first(List.concat(lit, List.repeat(0.U8, 16)), 16)

    ## the lanes of `pad16` that are the literal rather than padding
    lane_mask : List(U8) -> U16
    lane_mask = |lit| {
        n = List.len(lit)
        if n >= 16 { 0xFFFF } else { (1.U16.shl_wrap(n.to_u8_wrap())) - 1 }
    }

    # --- LengthLookup (RE#'s `inferLengthLookup`) -------------------------------------

    ## `getFixedPrefixLength`: how many leading symbols of `node` have a fixed
    ## length, and what remains after them (lookarounds and anchors count as
    ## zero and drop out; a bounded loop `x{lo,hi}` contributes `lo` and leaves
    ## `x{0,hi-lo}`)
    FP : { a : Arena.A, len : Try(U32, [NoLen]), rem : Try(U32, [NoRem]) }

    fixed_prefix : Arena.A, U32, U32 -> Accel.FP
    fixed_prefix = |a, acc, node|
        # an id test, not a kind test, so it comes before the dispatch
        if node == Arena.eps {
            { a, len: Ok(acc), rem: Err(NoRem) }
        } else {
            match Arena.kind_of(a, node) {
                Concat => {
                    h = Arena.head(a, node)
                    tail_node = Arena.tail(a, node)
                    head_fp = Accel.fixed_prefix(a, acc, h)
                    match (head_fp.len, head_fp.rem) {
                        (Ok(n), Err(_)) => Accel.fixed_prefix(head_fp.a, n, tail_node)
                        (Ok(n), Ok(r)) => {
                            c = Build.mk_concat2(head_fp.a, r, tail_node)
                            { a: c.a, len: Ok(n), rem: Ok(c.id) }
                        }
                        _ => if acc == 0 { { a: head_fp.a, len: Err(NoLen), rem: Err(NoRem) } } else { { a: head_fp.a, len: Ok(acc), rem: Ok(node) } }
                    }
                }
                Singleton => { a, len: Ok(1 + acc), rem: Err(NoRem) }
                Loop => {
                    body = Arena.head(a, node)
                    lo = Arena.loop_lo(a, node)
                    hi = Arena.loop_hi(a, node)
                    if Arena.is_singleton(a, body) and lo == hi {
                        { a, len: Ok(lo + acc), rem: Err(NoRem) }
                    } else if Arena.is_singleton(a, body) and lo != 0 {
                        l = Build.mk_loop(a, body, 0, if hi == Arena.inf { hi } else { hi - lo })
                        { a: l.a, len: Ok(lo + acc), rem: Ok(l.id) }
                    } else if lo == hi and lo != 0 {
                        # An exact repetition of a FIXED-LENGTH body is fixed-length
                        # too, not only a singleton one. The rewrites fold a doubled
                        # literal into exactly this shape — `\r\n\r\n` becomes
                        # `(\r\n){2}`, and so do `abab`, `aaaa`, `xyxy` — so measuring
                        # the body here is what leaves those patterns their literal
                        # override instead of a full reverse sweep.
                        body_fp = Accel.fixed_prefix(a, 0, body)
                        match (body_fp.len, body_fp.rem) {
                            (Ok(body_len), Err(_)) => { a: body_fp.a, len: Ok(acc + lo * body_len), rem: Err(NoRem) }
                            _ => { a: body_fp.a, len: Err(NoLen), rem: Ok(node) }
                        }
                    } else {
                        { a, len: Err(NoLen), rem: Ok(node) }
                    }
                }
                # lookarounds and anchors match no symbol, so they drop out
                LookAhead | LookBehind | Begin | End => { a, len: Ok(acc), rem: Err(NoRem) }
                Or | And | Not => { a, len: Err(NoLen), rem: Ok(node) }
            }
        }

    ## `inferLengthLookup` for the forward pattern `noprefix`
    infer_len : Dfa.E, Trie.T, U32 -> { e : Dfa.E, len : Dfa.Len }
    infer_len = |e, t, noprefix|
        match Arena.fixed_len(e.a, noprefix) {
            Ok(n) => { e, len: FixedLength(n) }
            Err(_) => {
                noprefix_fp = Accel.fixed_prefix(e.a, 0, noprefix)
                match (noprefix_fp.len, noprefix_fp.rem) {
                    (Ok(plen), Ok(rem)) => {
                        e_after_prefix = { ..e, a: noprefix_fp.a }
                        st = Dfa.get_state(e_after_prefix, rem, False)
                        e_after_rem_state = st.e
                        a = e_after_rem_state.a
                        body = Arena.head(a, rem)
                        if Arena.is_loop(a, rem) and Arena.loop_lo(a, rem) == 0 and Arena.is_singleton(a, body) and Arena.loop_hi(a, rem) <= 255 and TSet.count(Arena.tset(a, body)) == 1 {
                            { e: e_after_rem_state, len: RemainingSets(plen, TSet.lowest(Arena.tset(a, body)), Arena.loop_hi(a, rem)) }
                        } else {
                            # one live derivative `der`, always nullable, whose own derivatives all die.
                            # Deviation from RE#: minterms that kill `rem` (→ bot) are ignored here — on
                            # our alphabet the `Invalid` class kills every negated class, so `[^,]*,`
                            # would never qualify. Sound because a recorded start guarantees a match
                            # exists, so no killing symbol can precede the terminator.
                            rem_derivs = Accel.derivs_merged(a, rem, [noprefix, rem])
                            fallback = { e: { ..e_after_rem_state, a: rem_derivs.a }, len: PrefixEnd(plen, st.id) }
                            # (and only when the remainder itself is not nullable: otherwise a
                            # killing symbol ends the match right there, before any terminator)
                            match List.drop_if(rem_derivs.pairs, |(_, x)| x == Arena.bot) {
                                [(minterm, der)] if Arena.is_always_null(rem_derivs.a, der) and TSet.count(minterm) == 1 and !Arena.can_be_null(rem_derivs.a, rem) => {
                                    # `der` must be a dead end: EVERY minterm kills it. RE# excludes
                                    # derivatives back to `rem`/`der` here, which the bot-dropping above
                                    # would make unsound (`a.*c`: `.*c|()` steps back to `.*c` on most
                                    # symbols and the match goes on to the last `c`).
                                    der_derivs = Accel.derivs_merged(rem_derivs.a, der, [])
                                    e_after_der_merge = { ..e_after_rem_state, a: der_derivs.a }
                                    match der_derivs.pairs {
                                        [(_, x)] if x == Arena.bot => {
                                            der_state = Dfa.get_state(e_after_der_merge, der, False)
                                            null_kind = Dfa.null_kind(der_state.e, der_state.id)
                                            skips = (List.get(der_state.e.skip_ok, der_state.id.to_u64()) ?? 0) != 0
                                            if null_kind != Dfa.nk_pending and !skips {
                                                c = TSet.lowest(minterm)
                                                bytes = List.keep_if(Arena.upto(128), |b| (List.get(t.ascii, b) ?? 0).to_u32() == c) |> List.map(|b| b.to_u8_wrap())
                                                { e: der_state.e, len: SetLookup(plen, c, null_kind, Bset.table(bytes)) }
                                            } else {
                                                { e: der_state.e, len: PrefixEnd(plen, st.id) }
                                            }
                                        }
                                        _ => { e: e_after_der_merge, len: PrefixEnd(plen, st.id) }
                                    }
                                }
                                _ => fallback
                            }
                        }
                    }
                    _ => { e: { ..e, a: noprefix_fp.a }, len: MatchEnd }
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

    ## The pattern as a set of literal alternatives, when its language is a
    ## finite set of two to eight non-empty strings and it holds no anchor or
    ## lookaround. Ordered LONGEST FIRST, because `Teddy.match_lits` takes the
    ## first literal that matches at a position and leftmost-longest wants the
    ## longest.
    ##
    ## Not part of `Accel.T`: threading it through `Dfa.Accels` would put another
    ## arm in `find_all_fast_opts` and cost every pattern, so `Regex` holds it and
    ## dispatches before the scan.
    literal_set : Arena.A, Trie.T, U32 -> Try(List(List(U8)), [NotLiteralSet])
    literal_set = |a, t, root|
        if Arena.depends_anchor(a, root) or Arena.contains_look(a, root) {
            Err(NotLiteralSet)
        } else {
            lits = Accel.literal_lang(a, t, root, 8)?
            if List.len(lits) < 2 or List.any(lits, List.is_empty) {
                # one literal is the `Literal` override's job, and Teddy
                # cannot bucket an empty one
                Err(NotLiteralSet)
            } else {
                ordered = List.sort_with(lits, |x, y| U64.order_relative_to(List.len(y), List.len(x)))
                match Teddy.build(ordered) {
                    Ok(_) => Ok(ordered)
                    Err(_) => Err(NotLiteralSet)
                }
            }
        }

    ## The language of a node as a finite set of strings, or `Err` once it is not
    ## one or exceeds `max` members. Recursive because the builder merges shared
    ## affixes: `Watson|Norton` is stored as a concat whose head is a union, not
    ## as two literal chains, which a flat walk misses.
    literal_lang : Arena.A, Trie.T, U32, U64 -> Try(List(List(U8)), [NotLiteralSet])
    literal_lang = |a, t, id, max|
        # an id test, not a kind test, so it comes before the dispatch
        if id == Arena.eps {
            Ok([[]])
        } else {
            match Arena.kind_of(a, id) {
                Singleton =>
                    match Accel.single_cp(t, Arena.tset(a, id)) {
                        Ok(cp) => Ok([Utf8.encode(cp)])
                        Err(_) => Err(NotLiteralSet)
                    }
                Concat =>
                    match (Accel.literal_lang(a, t, Arena.head(a, id), max), Accel.literal_lang(a, t, Arena.tail(a, id), max)) {
                        (Ok(head_lits), Ok(tail_lits)) =>
                            if List.len(head_lits) * List.len(tail_lits) > max {
                                Err(NotLiteralSet)
                            } else {
                                Ok(List.fold(head_lits, [], |acc, h| List.concat(acc, List.map(tail_lits, |tail_lit| List.concat(h, tail_lit)))))
                            }
                        _ => Err(NotLiteralSet)
                    }
                Or =>
                    List.fold(Arena.children(a, id), Ok([]), |acc, c|
                        match (acc, Accel.literal_lang(a, t, c, max)) {
                            (Ok(lits), Ok(cs)) =>
                                if List.len(lits) + List.len(cs) > max { Err(NotLiteralSet) } else { Ok(List.concat(lits, cs)) }
                            _ => Err(NotLiteralSet)
                        })
                Loop | And | Not | LookAhead | LookBehind | Begin | End => Err(NotLiteralSet)
            }
        }

    # --- calcPrefixSets --------------------------------------------------------------

    ## `getPrefixNode`: strip what does not constrain the first symbols
    prefix_node : Arena.A, U32 -> Arena.R
    prefix_node = |a, id|
        match Arena.kind_of(a, id) {
            Loop => {
                n = Arena.loop_lo(a, id)
                Build.mk_loop(a, Arena.head(a, id), n, n)
            }
            Concat => {
                h = Arena.head(a, id)
                t = Arena.tail(a, id)
                if Arena.is_loop(a, h) and Arena.loop_lo(a, h) == 0 and (Arena.loop_hi(a, h) == Arena.inf or Arena.loop_hi(a, h) == 1) {
                    Accel.prefix_node(a, t)
                } else if Arena.is_loop(a, h) and Arena.loop_hi(a, h) == Arena.inf {
                    n = Arena.loop_lo(a, h)
                    l = Build.mk_loop(a, Arena.head(a, h), n, n)
                    Build.mk_concat2(l.a, l.id, t)
                } else if Arena.is_or(a, h) {
                    cs = Arena.map_ids(a, Arena.children(a, h), Accel.prefix_node)
                    o = Build.mk_or_seq(cs.a, cs.ids)
                    Build.mk_concat2(o.a, o.id, t)
                } else if Arena.is_lookbehind(a, h) {
                    body = Arena.head(a, h)
                    # a lookbehind body is `_*·x`; only `x` constrains the symbols here
                    inner = if Arena.is_concat(a, body) and Arena.head(a, body) == Arena.top_star { Arena.tail(a, body) } else { body }
                    c = Build.mk_concat2(a, inner, t)
                    Accel.prefix_node(c.a, c.id)
                } else {
                    { a, id }
                }
            }
            LookAhead => { a, id: Arena.head(a, id) }
            Singleton | Or | And | Not | LookBehind | Begin | End => { a, id }
        }

    ## the (minterm set, derivative) pairs of a node, derivatives grouped,
    ## excluding those in `redundant`
    derivs_merged : Arena.A, U32, List(U32) -> { a : Arena.A, pairs : List((U64, U32)) }
    derivs_merged = |a, node, redundant|
        List.fold(Arena.upto(a.minterm_count.to_u64()), { a, pairs: [] }, |acc, m| {
            d = Deriv.derivative(acc.a, Deriv.loc_center, TSet.bit(m.to_u32_wrap()), node)
            if List.contains(redundant, d.id) {
                { a: d.a, pairs: acc.pairs }
            } else {
                match List.find_first_index(acc.pairs, |(_, id)| id == d.id) {
                    Ok(i) => {
                        (tset, id) = List.get(acc.pairs, i) ?? (0, 0)
                        { a: d.a, pairs: List.set(acc.pairs, i, (tset.bitwise_or(TSet.bit(m.to_u32_wrap())), id)) ?? acc.pairs }
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
                [(minterm, der)] => if der == node { [] } else { Accel.prefix_loop(d.a, der, redundant, List.append(acc, minterm)) }
                _ => acc
            }
        }

    # --- the prefix accelerator (RE#'s StringPrefix / SearchValuesPrefix) --------------

    ## The `Prefix` and `Potential` specs are one record: the sets, the anchor
    ## within them and the run around it decide the search, and the two differ
    ## only in the state the sweep resumes in and whether it LANDS there
    ## (`land`: after an exact prefix the automaton is in the state the prefix
    ## leads to, after a potential start it is back in the initial one).
    prefix_spec : Accel.Anchor, Accel.Run, List(U64), U32, Bool -> Rlit.Prefix
    prefix_spec = |anchor, r, sets, state, land|
        { sets, anchor: anchor.i, single: anchor.single, anchor_byte: anchor.b, anchor_tab: anchor.tab, state, land,
          pair: r.pair, pair_byte: r.byte, pair_back: r.back, pair_dist: r.dist,
          triple: r.triple, triple_byte: r.triple_byte, triple_back: r.triple_back, triple_dist: r.triple_dist }

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
            # with verification and a landing added, which is slower than the skip
            # set alone (`[0-9]{2,4}`)
            Ok(anchor) if anchor.i == 0 and anchor.single == False => { e, init: NoInit }
            Ok(anchor) => {
                # derive `_*·rev` through the prefix; every minterm of a set must agree
                applied = List.fold_until(sets, { a: e.a, id: rev_ts, ok: True }, |acc, s| {
                    minterm_ids = List.keep_if(Arena.upto(acc.a.minterm_count.to_u64()), |m| TSet.contains(s, m.to_u32_wrap()))
                    r = List.fold(minterm_ids, { a: acc.a, ids: [] }, |st, m| {
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
                    r = Accel.run_of(t, sets, anchor.i)
                    { e: st.e, init: Prefix(Accel.prefix_spec(anchor, r, sets, st.id, True)) }
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
            r = List.fold(nodes, { a, set_union: 0, next: [] }, |st, n| {
                d = Accel.derivs_merged(st.a, n, redundant)
                List.fold(d.pairs, { ..st, a: d.a }, |pair_acc, (minterm, der)| {
                    { ..pair_acc, set_union: TSet.union(pair_acc.set_union, minterm), next: if List.contains(pair_acc.next, der) { pair_acc.next } else { List.append(pair_acc.next, der) } }
                })
            })
            Accel.potential_loop(r.a, r.next, redundant, List.append(acc, r.set_union))
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
                        r = Accel.run_of(t, sets, anchor.i)
                        Potential(Accel.prefix_spec(anchor, r, sets, rev_ts_state, False))
                    }
            }
        }

    # the ASCII bytes of a minterm set
    ascii_bytes : Trie.T, U64 -> List(U8)
    ascii_bytes = |t, s| List.keep_if(Arena.upto(128), |b| TSet.contains(s, (List.get(t.ascii, b) ?? 0).to_u32())) |> List.map(|b| b.to_u8_wrap())

    ## A second byte the anchor's occurrence must be accompanied by, at a fixed
    ## distance: `pair` is False when there is none.
    Run : { pair : Bool, byte : U8, back : Bool, dist : U64, triple : Bool, triple_byte : U8, triple_back : Bool, triple_dist : U64 }

    ## `Bset.byte_weight` of the rarest anchor worth a third window compare: `b`, so
    ## every letter from `b` up qualifies and the capitals, digits and
    ## punctuation that make good anchors on their own do not.
    triple_min_weight : U64
    triple_min_weight = 24

    ## `\bthe\b` anchors on `h`, which occurs 13473 times on the bench haystack
    ## against 1216 matches, so nearly every hit is rejected and the sweep is
    ## mostly the cost of finding and rejecting them. When the sets around the
    ## anchor are single ASCII codepoints they spell a literal run, and a second
    ## byte of that run can be folded into the search itself (memchr's rare byte
    ## pair): one more window compare rejects `h` that is not preceded by `t`
    ## before it ever reaches verification.
    ##
    ## Returns the rarest OTHER byte of the maximal run containing the anchor,
    ## as a signed distance from it, or `pair: False` when the run is shorter
    ## than two.
    run_of : Trie.T, List(U64), U64 -> Accel.Run
    run_of = |t, sets, anchor| {
        m = List.len(sets)
        anchor_fwd = m - 1 - anchor
        no_pair = { pair: False, byte: 0, back: False, dist: 0, triple: False, triple_byte: 0, triple_back: False, triple_dist: 0 }
        match Accel.byte_at(t, sets, m, anchor_fwd) {
            Err(_) => no_pair
            Ok(_) => {
                lo = Accel.run_down(t, sets, m, anchor_fwd)
                hi = Accel.run_up(t, sets, m, anchor_fwd)
                if hi == lo {
                    no_pair
                } else {
                    best = Accel.rarest_other(t, sets, m, anchor_fwd, lo, hi, anchor_fwd)
                    # a THIRD byte of the run, excluding the two already taken,
                    # and only when the anchor is a COMMON byte. Every hit that
                    # survives the window is a scan restart, and the third window
                    # compare costs about a nanosecond a window whether or not it
                    # filters, so only a common anchor leaves enough restarts for
                    # it to pay: `h` (96) does, `H` and `@` (3 and 1) do not.
                    anchor_byte = Accel.byte_at(t, sets, m, anchor_fwd) ?? 0
                    triple_idx = if Bset.byte_weight(anchor_byte) >= Accel.triple_min_weight { Accel.rarest_other(t, sets, m, anchor_fwd, lo, hi, best) } else { anchor_fwd }
                    { pair: True,
                      byte: Accel.byte_at(t, sets, m, best) ?? 0, back: best < anchor_fwd, dist: if best < anchor_fwd { anchor_fwd - best } else { best - anchor_fwd },
                      triple: triple_idx != anchor_fwd and triple_idx != best,
                      triple_byte: Accel.byte_at(t, sets, m, triple_idx) ?? 0, triple_back: triple_idx < anchor_fwd, triple_dist: if triple_idx < anchor_fwd { anchor_fwd - triple_idx } else { triple_idx - anchor_fwd } }
                }
            }
        }
    }

    # the rarest index of the run in `lo..hi` that is neither the anchor `anchor_fwd`
    # nor `taken`; `anchor_fwd` back when there is none
    rarest_other : Trie.T, List(U64), U64, U64, U64, U64, U64 -> U64
    rarest_other = |t, sets, m, anchor_fwd, lo, hi, taken| {
        best = List.fold(Arena.upto(hi - lo + 1), { j: anchor_fwd, rank: 255 }, |acc, i| {
            j = lo + i
            r = Rlit.rank(Accel.byte_at(t, sets, m, j) ?? 0)
            if j != anchor_fwd and j != taken and r < acc.rank { { j, rank: r } } else { acc }
        })
        best.j
    }

    # the byte of forward index `j`, when its set is one ASCII codepoint
    byte_at : Trie.T, List(U64), U64, U64 -> Try(U8, [NotSingle])
    byte_at = |t, sets, m, j|
        if j >= m {
            Err(NotSingle)
        } else {
            match Accel.single_cp(t, List.get(sets, m - 1 - j) ?? 0) {
                Ok(cp) if cp < 0x80 => Ok(cp.to_u8_wrap())
                _ => Err(NotSingle)
            }
        }

    run_down : Trie.T, List(U64), U64, U64 -> U64
    run_down = |t, sets, m, j|
        if j == 0 { 0 } else if Accel.byte_at(t, sets, m, j - 1) == Err(NotSingle) { j } else { Accel.run_down(t, sets, m, j - 1) }

    run_up : Trie.T, List(U64), U64, U64 -> U64
    run_up = |t, sets, m, j|
        if Accel.byte_at(t, sets, m, j + 1) == Err(NotSingle) { j } else { Accel.run_up(t, sets, m, j + 1) }

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
                    Ok(cur_best) => if w < cur_best.w { Ok(cand) } else { best }
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
