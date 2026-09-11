## The public surface: RE# semantics — leftmost-longest, `&`/`~`/`_`,
## normal-form lookarounds, line anchors — over `List(U8)` haystacks with byte
## offsets, plus `_str` conveniences.
##
## `T` is a transparent record with documented-unstable fields (no field privacy
## in Roc). `compile` returns `Try`, so a literal pattern with a caller-side
## `unwrap` fails the BUILD with the rendered message; a runtime pattern returns
## an ordinary `Err`.
##
## Searches run on the derivative automaton (`Dfa`); the brute-force reference
## (`Ref`) stays reachable as `find_all_ref` for the differential.
import Accel
import Arena
import Ast
import Build
import Conv
import Deriv
import Dfa
import Err
import Ref
import Teddy
import Show
import Trie
import TSet
import Utf8

Regex := [].{
    ## The compiled pattern. `root` is the raw pattern node, `rev` its reversal,
    ## `rev_ts` `_*·rev` (the reverse search start), `noprefix` the pattern with
    ## its lookbehind prefix stripped (the forward end pass). Documented-unstable.
    Pattern : { a : Arena.A, trie : Trie.T, root : U32, rev : U32, rev_ts : U32, ts : U32, noprefix : U32, e : Dfa.E, accel : Accel.T, lits : Regex.Lits }

    ## The literal-alternation accelerator, with its Teddy tables ALREADY BUILT.
    ## Building them at compile time keeps them out of the per-search path and
    ## folds them into the artifact like every other table.
    Lits : [NoLits, Lits(List(List(U8)), Teddy.T)]

    ## States the fold may explore — the artifact budget (256 KB provisional)
    ## over the table stride, capped at `fold_state_cap`. The cap is for a
    ## pattern whose state space is input-dependent (an unbounded lookahead),
    ## which would otherwise explore without bound; the scan extends the table
    ## at runtime.
    max_states : U32 -> U64
    max_states = |minterm_count| {
        by_bytes = 262144 // (minterm_count.to_u64() * 4)
        if by_bytes < Regex.fold_state_cap { by_bytes } else { Regex.fold_state_cap }
    }

    fold_state_cap : U64
    fold_state_cap = 1024

    ## A match, as half-open byte offsets into the haystack.
    Span : { start : U64, end : U64 }

    compile : Str -> Try(Regex.Pattern, Err.Error)
    compile = |src| {
        ast = Ast.parse(src)?
        Regex.compile_ast(src, ast)
    }

    nl_set : Ast.Set
    nl_set = { neg: False, ranges: [{ lo: 10, hi: 10 }] }
    w_set : Ast.Set
    w_set = { neg: False, ranges: Ast.ranges_w }
    s_set : Ast.Set
    s_set = { neg: False, ranges: Ast.ranges_s }

    ## The converter records an unsupported construct in an arena FIELD rather
    ## than returning it, so the failure has to be picked up between steps.
    ## Lifting it into the `Try` the caller is already threading is what keeps
    ## `compile_ast` a straight line.
    checked : Str, Arena.A -> Try(Arena.A, Err.Error)
    checked = |src, a|
        match a.err {
            Unsup(msg) => Err(Err.whole(src, Unsupported(msg)))
            NoErr => Ok(a)
        }

    ## the literal-alternation accelerator for a pattern, or `NoLits`: a pattern
    ## that already has a literal override does not need one, and both the
    ## literal set and Teddy may decline.
    lits_of : Accel.T, Arena.A, Trie.T, U32 -> Regex.Lits
    lits_of = |accel, a, trie, root|
        match accel.override {
            NoOverride =>
                match Accel.literal_set(a, trie, root) {
                    Ok(literals) => match Teddy.build(literals) { Ok(teddy) => Lits(literals, teddy), Err(_) => NoLits }
                    Err(_) => NoLits
                }
            _ => NoLits
        }

    compile_ast : Str, Ast -> Try(Regex.Pattern, Err.Error)
    compile_ast = |src, ast| {
        has_wb = Ast.has_wordb(ast)
        has_line = Ast.has_line_anchor(ast)
        base_sets = Ast.collect_sets(ast, [])
        sets_with_wb = if has_wb { Ast.add_set(Ast.add_set(base_sets, Regex.w_set), Regex.s_set) } else { base_sets }
        sets = if has_line { Ast.add_set(sets_with_wb, Regex.nl_set) } else { sets_with_wb }
        trie = Try.map_err(Trie.build(Ast.flat_sets(sets)), |e| match e { TooManyClasses(n) => Err.whole(src, TooManyClasses({ limit: 63, given: n })) })?
        ctx = { sets, tsets: trie.set_tsets, wordc: 0, spacec: 0 }
        wordc = if has_wb { Conv.tset_of(ctx, Regex.w_set) } else { 0 }
        spacec = if has_wb { Conv.tset_of(ctx, Regex.s_set) } else { 0 }
        nl_tset = if has_line { Conv.tset_of(ctx, Regex.nl_set) } else { 0 }
        arena_init = Arena.init(trie.n_classes)
        arena_anchored = Build.init_anchors(arena_init, wordc, TSet.compl(wordc, arena_init.minterm_count), nl_tset)
        root = Conv.convert(arena_anchored, { ..ctx, wordc, spacec }, ast)
        root_a = Regex.checked(src, root.a)?
        reversed = Deriv.rev(root_a, root.id)
        rev_search_start = Build.mk_concat2(reversed.a, Arena.top_star, reversed.id)
        search_start = Build.mk_concat2(rev_search_start.a, Arena.top_star, root.id)
        noprefix_node = Deriv.without_lookback_prefix(search_start.a, root.id)
        noprefix_node_a = Regex.checked(src, noprefix_node.a)?
        at_start = Deriv.at_input_start(noprefix_node_a, root.id)
        dfa_init = Dfa.init(at_start.a, rev_search_start.id, noprefix_node.id, at_start.id, Regex.max_states(trie.n_classes))
        accel_out = Accel.analyze(dfa_init, trie, root.id, reversed.id, rev_search_start.id, noprefix_node.id)
        e = Dfa.freeze(Dfa.explore(accel_out.e), trie)
        lits = Regex.lits_of(accel_out.accel, e.a, trie, root.id)
        Ok({ a: e.a, trie, root: root.id, rev: reversed.id, rev_ts: rev_search_start.id, ts: search_start.id, noprefix: noprefix_node.id, e, accel: accel_out.accel, lits })
    }

    ## The literal-pattern idiom: `Regex.build("…")` folds the pattern at build
    ## time and fails the BUILD with the rendered message when the literal is
    ## bad. `report_errs` is the same thing over an already-compiled `Try`, for
    ## a caller that wants `compile` and the crash separately.
    build : Str -> Regex.Pattern
    build = |src| Regex.report_errs(Regex.compile(src))

    report_errs : Try(Regex.Pattern, Err.Error) -> Regex.Pattern
    report_errs = |r|
        match r {
            Ok(re) => re
            Err(e) => crash Err.render(e)
        }

    labeled_errs : Str, Try(Regex.Pattern, Err.Error) -> Regex.Pattern
    labeled_errs = |label, r|
        match r {
            Ok(re) => re
            Err(e) => crash "[${label}] ${Err.render(e)}"
        }

    ## All non-overlapping leftmost-longest matches.
    ## A union of literals is Teddy over all of them at once, with the literals
    ## ordered longest-first at compile time so the first one matching at a
    ## position is the longest, which is what leftmost-longest asks for. `Err`
    ## when the pattern is not such a union, or when Teddy declines the set, in
    ## which case the ordinary scan runs.
    ##
    ## Dispatched here rather than inside `Dfa.find_all_fast_opts`: another arm
    ## in that function slows every pattern that does not take it, so the hot
    ## scan does not learn about this at all.
    lit_set_spans : Regex.Lits, List(U8) -> Try(List(Regex.Span), [NoSet])
    lit_set_spans = |lits, hay|
        match lits {
            NoLits => Err(NoSet)
            # Uncapped: Teddy's single-loop scan beats the ordinary scan even
            # when matches are dense, so there is no case to bail out of.
            Lits(_, teddy) => Try.map_err(Teddy.match_lits(teddy, hay, List.len(hay) + 1), |_| NoSet)
        }

    ## The threaded scan reports SYMBOL indices; `h.pos` maps a symbol index back
    ## to the byte offset the public API promises.
    byte_spans : List(U32), List(Regex.Span) -> List(Regex.Span)
    byte_spans = |pos, spans|
        List.map(spans, |span| { start: (List.get(pos, span.start) ?? 0).to_u64(), end: (List.get(pos, span.end) ?? 0).to_u64() })

    find_all : Regex.Pattern, List(U8) -> List(Regex.Span)
    find_all = |re, hay|
        match Regex.lit_set_spans(re.lits, hay) {
            Ok(lit_spans) => lit_spans
            Err(_) =>
                if re.e.complete {
                    # a complete fold is a read-only table: the byte-loop scans
                    Dfa.find_all_fast(re.e, re.trie, re.accel, hay)
                } else {
                    h = Ref.prepare(re.trie, hay)
                    r = Dfa.find_all(re.e, h)
                    Regex.byte_spans(h.pos, r.spans)
                }
        }

    ## `find_all` on the fast scan with every accelerator off (A/B measurement)
    find_all_plain : Regex.Pattern, List(U8) -> List(Regex.Span)
    find_all_plain = |re, hay|
        if re.e.complete { Dfa.find_all_fast_opts(re.e, re.trie, Accel.none, hay, False, False) } else { Regex.find_all_threaded(re, hay) }

    ## `find_all` with the compile-time accelerators but no per-state skips
    find_all_noskip : Regex.Pattern, List(U8) -> List(Regex.Span)
    find_all_noskip = |re, hay|
        if re.e.complete { Dfa.find_all_fast_opts(re.e, re.trie, re.accel, hay, False, False) } else { Regex.find_all_threaded(re, hay) }

    ## `find_all` on the threaded (extensible) scan regardless of completeness —
    ## the corpus cross-checks it against the fast path
    find_all_threaded : Regex.Pattern, List(U8) -> List(Regex.Span)
    find_all_threaded = |re, hay| {
        h = Ref.prepare(re.trie, hay)
        r = Dfa.find_all(re.e, h)
        Regex.byte_spans(h.pos, r.spans)
    }

    ## `find_all`, also returning the regex with every state the scan minted:
    ## a caller looping over haystacks threads it so an incomplete fold is not
    ## re-derived per call.
    find_all_grow : Regex.Pattern, List(U8) -> (Regex.Pattern, List(Regex.Span))
    find_all_grow = |re, hay| {
        h = Ref.prepare(re.trie, hay)
        r = Dfa.find_all(re.e, h)
        ({ ..re, e: r.e, a: r.e.a }, Regex.byte_spans(h.pos, r.spans))
    }

    ## The runtime state cap (RE#'s `MaxDfaCapacity`, default 100k): past it a
    ## scan evicts back to the folded prefix and continues. Exposed so the
    ## corpus can force eviction.
    with_runtime_cap : Regex.Pattern, U64 -> Regex.Pattern
    with_runtime_cap = |re, cap| { ..re, e: { ..re.e, runtime_cap: cap } }

    ## The same, on the brute-force reference — the differential's oracle.
    find_all_ref : Regex.Pattern, List(U8) -> List(Regex.Span)
    find_all_ref = |re, hay| Ref.find_all(re.a, re.trie, re.root, hay)

    ## The reverse sweep's match-start positions as byte offsets, in the order
    ## recorded (RE#'s `nullable_positions` tests).
    match_starts : Regex.Pattern, List(U8) -> List(U64)
    match_starts = |re, hay| {
        h = Ref.prepare(re.trie, hay)
        r = Dfa.starts(re.e, h)
        List.map(r.acc, |p| (List.get(h.pos, p) ?? 0).to_u64())
    }

    ## the accelerators chosen for this pattern, for tests
    accel_str : Regex.Pattern -> Str
    accel_str = |re| {
        anchor_of = |p| if p.single { Str.from_utf8_lossy([p.anchor_byte]) } else { "set" }
        init =
            match re.accel.init {
                Prefix(p) => "prefix=${List.len(p.sets).to_str()}sets@${p.anchor.to_str()}(${anchor_of(p)})"
                Potential(p) => "potential=${List.len(p.sets).to_str()}sets@${p.anchor.to_str()}(${anchor_of(p)})"
                ClassRun(r) => "classrun=x${r.lo.to_str()}"
                NoInit => "prefix=none"
            }
        len =
            match re.accel.len {
                FixedLength(n) => "len=${n.to_str()}"
                PrefixEnd(k, st) => "len=prefix${k.to_str()}+end@${st.to_str()}"
                SetLookup(k, c, null_kind, _) => "len=prefix${k.to_str()}+set${c.to_str()}(nk${null_kind.to_str()})"
                RemainingSets(k, c, m) => "len=prefix${k.to_str()}+upto${m.to_str()}x${c.to_str()}"
                MatchEnd => "len=any"
            }
        override_str =
            match re.accel.override {
                Literal(l, _, _) => "override=${Str.from_utf8_lossy(l)}"
                NoOverride =>
                    match re.lits {
                        NoLits => "override=none"
                        Lits(literals, _) => "override=set[${literals |> List.map(|l| Str.from_utf8_lossy(l)) |> Str.join_with("|")}]"
                    }
            }
        "${init} ${len} ${override_str}"
    }

    ## the fast reverse sweep alone (profiling): match starts, accelerated or not
    match_starts_fast : Regex.Pattern, List(U8), Bool -> List(U64)
    match_starts_fast = |re, hay, accel|
        if accel { Dfa.starts_fast(re.e, re.trie, re.accel.init, hay) } else { Dfa.starts_fast_opts(re.e, re.trie, NoInit, hay, False) }

    ## the reverse sweep with the prefix accelerator but no per-state skips
    match_starts_noskip : Regex.Pattern, List(U8) -> List(U64)
    match_starts_noskip = |re, hay| Dfa.starts_fast_opts(re.e, re.trie, re.accel.init, hay, False)

    ## how many states of a complete fold carry a skip set (diagnostics)
    n_skip_states : Regex.Pattern -> U64
    n_skip_states = |re| List.count_if(re.e.skip_ok, |x| x != 0)

    ## Did the fold explore every reachable state?
    is_complete : Regex.Pattern -> Bool
    is_complete = |re| re.e.complete

    n_states : Regex.Pattern -> U64
    n_states = |re| Dfa.n_states(re.e)

    ## The leftmost match, as a list of zero or one. Documented as a full
    ## sweep: the reverse pass has to reach the haystack start before the
    ## leftmost start is known. `find` and `is_match` share it so that neither
    ## computes every match to answer about one.
    find_first : Regex.Pattern, List(U8) -> List(Regex.Span)
    find_first = |re, hay|
        match Regex.find(re, hay) {
            Ok(s) => [s]
            Err(_) => []
        }

    ## The leftmost match. Documented as a full sweep for a general pattern: the
    ## reverse pass has to reach the haystack start before the leftmost start is
    ## known.
    ##
    ## The literal case is dispatched HERE rather than inside
    ## `Dfa.find_all_fast_opts`. Reaching the kernel through `find_first_fast`
    ## -> `find_all_fast_opts` passes `Dfa.E` — eighteen fields, fourteen of
    ## them heap lists — down two call levels, and every pass refcounts all of
    ## them, which on a short haystack costs many times the SIMD kernel itself.
    ## Dispatch once, outside, and hand the loop only what it reads.
    find : Regex.Pattern, List(U8) -> Try(Regex.Span, [NoMatch])
    find = |re, hay|
        match re.accel.override {
            Literal(lit, padded, mask) => Dfa.first_literal(hay, lit, padded, mask)
            NoOverride =>
                match Regex.lit_set_spans(re.lits, hay) {
                    Ok(lit_spans) => Try.map_err(List.first(lit_spans), |_| NoMatch)
                    Err(_) => {
                        r = if re.e.complete { Dfa.find_first_fast(re.e, re.trie, re.accel, hay) } else { Regex.find_all_threaded(re, hay) }
                        Try.map_err(List.first(r), |_| NoMatch)
                    }
                }
        }

    ## Whether any match exists. Unlike `find`, this does not need the LEFTMOST
    ## match, so the reverse sweep can stop at the first start it records rather
    ## than running to the haystack start. The candidate is then verified with
    ## the forward pass, and a candidate that yields no end falls back to the
    ## full scan, so the answer does not depend on assuming that a recorded
    ## start always has one.
    is_match : Regex.Pattern, List(U8) -> Bool
    is_match = |re, hay|
        if re.e.complete {
            match re.accel.override {
                # a pure literal is already a literal search, and the kernel is
                # reached without passing the engine record (see `find`)
                Literal(lit, padded, mask) => Dfa.first_literal(hay, lit, padded, mask) != Err(NoMatch)
                NoOverride => {
                    cands = Dfa.first_starts(re.e, re.trie, re.accel.init, hay)
                    if List.is_empty(cands) {
                        False
                    } else {
                        sorted_cands = List.sort_with(cands, |x, y| U64.order_relative_to(x, y))
                        if List.len(Dfa.ends_fast(re.e, re.trie, re.accel.len, hay, sorted_cands, True, False, True)) > 0 {
                            True
                        } else {
                            List.len(Regex.find_first(re, hay)) > 0
                        }
                    }
                }
            }
        } else {
            List.len(Regex.find_first(re, hay)) > 0
        }

    count : Regex.Pattern, List(U8) -> U64
    count = |re, hay| List.len(Regex.find_all(re, hay))

    ## The oracle for the two above: every end of a match anchored at offset 0,
    ## from the structural reference. Ascending, so its first and last are what
    ## `first_end` and `longest_end` must return.
    ends_at_start_ref : Regex.Pattern, List(U8) -> List(U64)
    ends_at_start_ref = |re, hay| Ref.ends_at_start(re.a, re.trie, re.root, hay)

    ## The end of the SHORTEST match anchored at offset 0, if any.
    ##
    ## This and `longest_end` are the parse primitive: the caller drives one
    ## step per piece over a slice of its buffer, and the piece IS the slice
    ## `0..end`. The haystack is the slice, so `\A` is its start, `\z` its end,
    ## and a lookbehind or `\b` at 0 sees beginning-of-input.
    ##
    ## A nullable pattern legitimately answers `Ok(0)`; a caller stepping a
    ## sequence must check that it made progress. `end == List.len(hay)` says
    ## the match ran to the edge of the slice and might extend given more input.
    first_end : Regex.Pattern, List(U8) -> Try(U64, [NoMatch])
    first_end = |re, hay|
        if re.e.complete {
            Try.map_err((Dfa.ends_at_start_fast(re.e, re.trie, hay)).first, |_| NoMatch)
        } else {
            Try.map_err(List.first(Ref.ends_at_start(re.a, re.trie, re.root, hay)), |_| NoMatch)
        }

    ## The end of the LONGEST match anchored at offset 0, if any. See
    ## `first_end` for the slice semantics.
    longest_end : Regex.Pattern, List(U8) -> Try(U64, [NoMatch])
    longest_end = |re, hay|
        if re.e.complete {
            Try.map_err((Dfa.ends_at_start_fast(re.e, re.trie, hay)).last, |_| NoMatch)
        } else {
            Try.map_err(List.last(Ref.ends_at_start(re.a, re.trie, re.root, hay)), |_| NoMatch)
        }

    ## Replace every match. `rep` may contain `$0` (the match) and `$$` (`$`);
    ## RE# has no groups, so there is nothing else to reference.
    replace_all : Regex.Pattern, List(U8), List(U8) -> List(U8)
    replace_all = |re, hay, rep| {
        spans = Regex.find_all(re, hay)
        r = List.fold(spans, { out: [], last: 0 }, |st, span| {
            before = List.sublist(hay, { start: st.last, len: span.start - st.last })
            matched = List.sublist(hay, { start: span.start, len: span.end - span.start })
            { out: List.concat(List.concat(st.out, before), Regex.expand(rep, matched, 0, [])), last: span.end }
        })
        List.concat(r.out, List.sublist(hay, { start: r.last, len: List.len(hay) - r.last }))
    }

    expand : List(U8), List(U8), U64, List(U8) -> List(U8)
    expand = |rep, matched, i, out|
        match List.get(rep, i) {
            Err(_) => out
            Ok('$') =>
                match List.get(rep, i + 1) {
                    Ok('$') => Regex.expand(rep, matched, i + 2, List.append(out, '$'))
                    Ok('0') => Regex.expand(rep, matched, i + 2, List.concat(out, matched))
                    _ => Regex.expand(rep, matched, i + 1, List.append(out, '$'))
                }
            Ok(b) => Regex.expand(rep, matched, i + 1, List.append(out, b))
        }

    ## Split around matches: leading/trailing empty fields kept, one more field
    ## than matches.
    split : Regex.Pattern, List(U8) -> List(List(U8))
    split = |re, hay| {
        spans = Regex.find_all(re, hay)
        r = List.fold(spans, { fields: [], last: 0 }, |st, span|
            { fields: List.append(st.fields, List.sublist(hay, { start: st.last, len: span.start - st.last })), last: span.end })
        List.append(r.fields, List.sublist(hay, { start: r.last, len: List.len(hay) - r.last }))
    }

    # --- Str conveniences (copy in; the byte API is the real one) ---------------

    find_all_str : Regex.Pattern, Str -> List(Regex.Span)
    find_all_str = |re, s| Regex.find_all(re, Str.to_utf8(s))

    find_str : Regex.Pattern, Str -> Try(Regex.Span, [NoMatch])
    find_str = |re, s| Regex.find(re, Str.to_utf8(s))

    is_match_str : Regex.Pattern, Str -> Bool
    is_match_str = |re, s| Regex.is_match(re, Str.to_utf8(s))

    count_str : Regex.Pattern, Str -> U64
    count_str = |re, s| Regex.count(re, Str.to_utf8(s))

    replace_all_str : Regex.Pattern, Str, Str -> Str
    replace_all_str = |re, hay, rep| Str.from_utf8_lossy(Regex.replace_all(re, Str.to_utf8(hay), Str.to_utf8(rep)))

    split_str : Regex.Pattern, Str -> List(Str)
    split_str = |re, hay| List.map(Regex.split(re, Str.to_utf8(hay)), Str.from_utf8_lossy)

    # --- introspection (tests, debugging) ---------------------------------------

    ## one-line rendering of a compile error
    err_str : Err.Error -> Str
    err_str = |e| Err.to_str(e)

    ## the pattern node in RE#'s notation
    show : Regex.Pattern -> Str
    show = |re| Show.show(re.a, re.trie, re.root)

    ## any node in RE#'s notation
    show_node : Regex.Pattern, U32 -> Str
    show_node = |re, id| Show.show(re.a, re.trie, id)

    ## the minterms in RE#'s notation
    minterms : Regex.Pattern -> List(Str)
    minterms = |re| List.map(Trie.upto(re.trie.n_classes.to_u64()), |m| Show.tset(re.a, re.trie, TSet.bit(m.to_u32_wrap())))

    n_nodes : Regex.Pattern -> U64
    n_nodes = |re| Arena.n_nodes(re.a)

    ## the reverse pattern in RE#'s notation
    show_rev : Regex.Pattern -> Str
    show_rev = |re| Show.show(re.a, re.trie, re.rev)

    ## the `_*·rev` search-start node in RE#'s notation
    show_rev_ts : Regex.Pattern -> Str
    show_rev_ts = |re| Show.show(re.a, re.trie, re.rev_ts)

    ## the pattern with its lookbehind prefix stripped
    show_noprefix : Regex.Pattern -> Str
    show_noprefix = |re| Show.show(re.a, re.trie, re.noprefix)

    ## the derivative of a node by the class of codepoint `cp` at `loc`
    ## (0 begin, 1 center, 2 end), printed (tests: RE#'s `der1` helpers)
    derive_show : Regex.Pattern, U32, U32, U32 -> Str
    derive_show = |re, node, loc, cp| {
        class_tset = TSet.bit(Trie.class_of(re.trie, cp))
        d = Deriv.derivative(re.a, loc, class_tset, node)
        Show.show(d.a, re.trie, d.id)
    }

    ## the derivative of the raw pattern by the first codepoint of `s`
    der1 : Regex.Pattern, Str -> Str
    der1 = |re, s| Regex.derive_show(re, re.root, Deriv.loc_begin, Regex.first_cp(s))

    ## the derivative of `_*·pattern` by the first codepoint of `s`
    der1_ts : Regex.Pattern, Str -> Str
    der1_ts = |re, s| Regex.derive_show(re, re.ts, Deriv.loc_begin, Regex.first_cp(s))

    ## the End-location derivative of the reverse pattern by the LAST codepoint of `s`
    der1_rev : Regex.Pattern, Str -> Str
    der1_rev = |re, s| Regex.derive_show(re, re.rev, Deriv.loc_end, Regex.last_cp(s))

    first_cp : Str -> U32
    first_cp = |s| (Utf8.decode(Str.to_utf8(s), 0)).cp

    last_cp : Str -> U32
    last_cp = |s| {
        b = Str.to_utf8(s)
        (Utf8.decode(b, Utf8.sym_start(b, List.len(b) - 1))).cp
    }

    ## the derivative of the raw pattern at position `pos` (codepoint index) of `s`, Begin location as RE#'s `der1RPos`
    der1_at : Regex.Pattern, Str, U64 -> Str
    der1_at = |re, s, pos| {
        cp_list = Regex.cps(Str.to_utf8(s), 0, [])
        Regex.derive_show(re, re.root, Deriv.loc_begin, List.get(cp_list, pos) ?? 0)
    }

    cps : List(U8), U64, List(U32) -> List(U32)
    cps = |b, i, acc|
        if i >= List.len(b) { acc } else {
            d = Utf8.decode(b, i)
            Regex.cps(b, i + d.len, List.append(acc, d.cp))
        }

    ## the derivative chain of the prefix-free pattern through `s` (Center
    ## location), each node printed with its nullability and pending set
    derive_chain : Regex.Pattern, Str -> List(Str)
    derive_chain = |re, s| {
        cp_list = Regex.cps(Str.to_utf8(s), 0, [])
        st = List.fold(cp_list, { a: re.a, id: re.noprefix, out: [Regex.describe(re.a, re.trie, re.noprefix)] }, |acc, cp| {
            class_tset = TSet.bit(Trie.class_of(re.trie, cp))
            d = Deriv.derivative(acc.a, Deriv.loc_center, class_tset, acc.id)
            { a: d.a, id: d.id, out: List.append(acc.out, Regex.describe(d.a, re.trie, d.id)) }
        })
        st.out
    }

    ## the derivative chain of `node` reading the haystack LEFTWARD from byte
    ## `from` for `count` symbols (Center location), for tracing the reverse sweep
    derive_chain_rev : Regex.Pattern, U32, List(U8), U64, U64 -> List(Str)
    derive_chain_rev = |re, node, hay, from, n_steps| {
        h = Ref.prepare(re.trie, hay)
        # symbol index of byte `from`
        sym_i = List.fold_with_index(h.pos, 0, |acc, p, i| if p.to_u64() == from { i } else { acc })
        st = List.fold(Arena.upto(n_steps), { a: re.a, id: node, i: sym_i, out: [Regex.describe(re.a, re.trie, node)] }, |acc, _|
            if acc.i == 0 { acc } else {
                cls = (List.get(h.cls, acc.i - 1) ?? 0).to_u32()
                d = Deriv.derivative(acc.a, Deriv.loc_center, TSet.bit(cls), acc.id)
                { a: d.a, id: d.id, i: acc.i - 1, out: List.append(acc.out, "@${(List.get(h.pos, acc.i - 1) ?? 0).to_u64().to_str()} ${Regex.describe(d.a, re.trie, d.id)}") }
            })
        st.out
    }

    rev_node : Regex.Pattern -> U32
    rev_node = |re| re.rev

    describe : Arena.A, Trie.T, U32 -> Str
    describe = |a, t, id| {
        pend = Arena.rs_get(a, Arena.pend(a, id)) |> List.map(|p| "(${Arena.pair_start(p).to_str()},${Arena.pair_end(p).to_str()})") |> Str.join_with(" ")
        looks = if Arena.is_lookahead(a, id) { " rel=${Arena.look_rel(a, id).to_str()} lpend=${Arena.rs_get(a, Arena.look_pend(a, id)) |> List.map(|p| "(${Arena.pair_start(p).to_str()},${Arena.pair_end(p).to_str()})") |> Str.join_with(" ")}" } else { "" }
        "${Show.show(a, t, id)}  [null=${if Arena.is_always_null(a, id) { "always" } else if Arena.can_be_null(a, id) { "can" } else { "no" }} pend={${pend}}${looks} id=${id.to_str()}]"
    }

    ## nullability of the raw pattern at a location (0 begin, 1 center, 2 end)
    nullable_at : Regex.Pattern, U32 -> Bool
    nullable_at = |re, loc| Deriv.nullable(re.a, loc, re.root)

    ## the raw pattern's flags byte (NodeFlags)
    root_flags : Regex.Pattern -> U8
    root_flags = |re| Arena.flags(re.a, re.root)

    rev_ts_flags : Regex.Pattern -> U8
    rev_ts_flags = |re| Arena.flags(re.a, re.rev_ts)

    ## RE#'s GetFixedLength of the reverse pattern
    rev_fixed_len : Regex.Pattern -> Try(U32, [NotFixed])
    rev_fixed_len = |re| Arena.fixed_len(re.a, re.rev)
}
