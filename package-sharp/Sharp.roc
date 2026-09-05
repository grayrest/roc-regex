## The public surface (S11): RE# semantics — leftmost-longest, `&`/`~`/`_`,
## normal-form lookarounds, line anchors — over `List(U8)` haystacks with byte
## offsets, plus `_str` conveniences.
##
## `T` is a transparent record with documented-unstable fields (no field privacy
## in Roc). `compile` returns `Try`, so a literal pattern with a caller-side
## `unwrap` fails the BUILD with the rendered message; a runtime pattern returns
## an ordinary `Err`.
##
## M1: every search runs on the brute-force reference (`Ref`). M2 replaces the
## search paths with the derivative DFA; the compile pipeline stays.
import Arena
import Ast
import Build
import Conv
import Deriv
import Err
import Ref
import Show
import Trie
import TSet
import Utf8

Sharp := [].{
    ## The compiled pattern. `root` is the raw pattern node, `rev` its reversal,
    ## `rev_ts` `_*·rev` (the reverse search start), `noprefix` the pattern with
    ## its lookbehind prefix stripped (the forward end pass). Documented-unstable.
    T : { a : Arena.A, trie : Trie.T, root : U32, rev : U32, rev_ts : U32, ts : U32, noprefix : U32 }

    ## A match, as half-open byte offsets into the haystack.
    Span : { start : U64, end : U64 }

    compile : Str -> Try(Sharp.T, Err.Error)
    compile = |src|
        match Ast.parse(src) {
            Err(e) => Err(e)
            Ok(ast) => Sharp.compile_ast(src, ast)
        }

    nl_set : Ast.Set
    nl_set = { neg: False, ranges: [{ lo: 10, hi: 10 }] }
    w_set : Ast.Set
    w_set = { neg: False, ranges: Ast.ranges_w }
    s_set : Ast.Set
    s_set = { neg: False, ranges: Ast.ranges_s }

    compile_ast : Str, Ast -> Try(Sharp.T, Err.Error)
    compile_ast = |src, ast| {
        has_wb = Ast.has_wordb(ast)
        has_line = Ast.has_line_anchor(ast)
        sets0 = Ast.collect_sets(ast, [])
        sets1 = if has_wb { Ast.add_set(Ast.add_set(sets0, Sharp.w_set), Sharp.s_set) } else { sets0 }
        sets = if has_line { Ast.add_set(sets1, Sharp.nl_set) } else { sets1 }
        match Trie.build(Ast.flat_sets(sets)) {
            Err(TooManyClasses(n)) => Err(Err.whole(src, TooManyClasses({ limit: 63, given: n })))
            Ok(trie) => {
                ctx = { sets, tsets: trie.set_tsets, wordc: 0, spacec: 0 }
                wordc = if has_wb { Conv.tset_of(ctx, Sharp.w_set) } else { 0 }
                spacec = if has_wb { Conv.tset_of(ctx, Sharp.s_set) } else { 0 }
                nl = if has_line { Conv.tset_of(ctx, Sharp.nl_set) } else { 0 }
                a0 = Arena.init(trie.n_classes)
                a1 = Build.init_anchors(a0, wordc, TSet.compl(wordc, a0.nmt), nl)
                root = Conv.convert(a1, { ..ctx, wordc, spacec }, ast)
                match root.a.err {
                    Unsup(msg) => Err(Err.whole(src, Unsupported(msg)))
                    NoErr => {
                        rv = Deriv.rev(root.a, root.id)
                        rts = Build.mk_concat2(rv.a, Arena.top_star, rv.id)
                        ts = Build.mk_concat2(rts.a, Arena.top_star, root.id)
                        np = Deriv.without_lookback_prefix(ts.a, root.id)
                        match np.a.err {
                            Unsup(msg) => Err(Err.whole(src, Unsupported(msg)))
                            NoErr => Ok({ a: np.a, trie, root: root.id, rev: rv.id, rev_ts: rts.id, ts: ts.id, noprefix: np.id })
                        }
                    }
                }
            }
        }
    }

    ## The literal-pattern idiom: fold, and crash-with-message on a bad literal
    ## so the build fails.
    unwrap : Try(Sharp.T, Err.Error) -> Sharp.T
    unwrap = |r|
        match r {
            Ok(re) => re
            Err(e) => crash Err.render(e)
        }

    unwrap_labeled : Str, Try(Sharp.T, Err.Error) -> Sharp.T
    unwrap_labeled = |label, r|
        match r {
            Ok(re) => re
            Err(e) => crash "[${label}] ${Err.render(e)}"
        }

    ## All non-overlapping leftmost-longest matches.
    find_all : Sharp.T, List(U8) -> List(Sharp.Span)
    find_all = |re, hay| Ref.find_all(re.a, re.trie, re.root, hay)

    ## The first match. Documented as a full sweep: the reverse pass has to reach
    ## the haystack start before the leftmost start is known (S11).
    find : Sharp.T, List(U8) -> Try(Sharp.Span, [NoMatch])
    find = |re, hay|
        match List.first(Sharp.find_all(re, hay)) {
            Ok(s) => Ok(s)
            Err(_) => Err(NoMatch)
        }

    is_match : Sharp.T, List(U8) -> Bool
    is_match = |re, hay| !List.is_empty(Sharp.find_all(re, hay))

    count : Sharp.T, List(U8) -> U64
    count = |re, hay| List.len(Sharp.find_all(re, hay))

    ## The end of the shortest match anchored at offset 0, if any.
    first_end : Sharp.T, List(U8) -> Try(U64, [NoMatch])
    first_end = |re, hay|
        match List.first(Ref.ends_at_start(re.a, re.trie, re.root, hay)) {
            Ok(e) => Ok(e)
            Err(_) => Err(NoMatch)
        }

    ## The end of the longest match anchored at offset 0, if any.
    longest_end : Sharp.T, List(U8) -> Try(U64, [NoMatch])
    longest_end = |re, hay|
        match List.last(Ref.ends_at_start(re.a, re.trie, re.root, hay)) {
            Ok(e) => Ok(e)
            Err(_) => Err(NoMatch)
        }

    ## Replace every match. `rep` may contain `$0` (the match) and `$$` (`$`);
    ## RE# has no groups, so there is nothing else to reference.
    replace_all : Sharp.T, List(U8), List(U8) -> List(U8)
    replace_all = |re, hay, rep| {
        spans = Sharp.find_all(re, hay)
        r = List.fold(spans, { out: [], last: 0 }, |st, sp| {
            before = List.sublist(hay, { start: st.last, len: sp.start - st.last })
            matched = List.sublist(hay, { start: sp.start, len: sp.end - sp.start })
            { out: List.concat(List.concat(st.out, before), Sharp.expand(rep, matched, 0, [])), last: sp.end }
        })
        List.concat(r.out, List.sublist(hay, { start: r.last, len: List.len(hay) - r.last }))
    }

    expand : List(U8), List(U8), U64, List(U8) -> List(U8)
    expand = |rep, matched, i, out|
        match List.get(rep, i) {
            Err(_) => out
            Ok('$') =>
                match List.get(rep, i + 1) {
                    Ok('$') => Sharp.expand(rep, matched, i + 2, List.append(out, '$'))
                    Ok('0') => Sharp.expand(rep, matched, i + 2, List.concat(out, matched))
                    _ => Sharp.expand(rep, matched, i + 1, List.append(out, '$'))
                }
            Ok(b) => Sharp.expand(rep, matched, i + 1, List.append(out, b))
        }

    ## Split around matches: leading/trailing empty fields kept, one more field
    ## than matches.
    split : Sharp.T, List(U8) -> List(List(U8))
    split = |re, hay| {
        spans = Sharp.find_all(re, hay)
        r = List.fold(spans, { fields: [], last: 0 }, |st, sp|
            { fields: List.append(st.fields, List.sublist(hay, { start: st.last, len: sp.start - st.last })), last: sp.end })
        List.append(r.fields, List.sublist(hay, { start: r.last, len: List.len(hay) - r.last }))
    }

    # --- Str conveniences (copy in; the byte API is the real one) ---------------

    find_all_str : Sharp.T, Str -> List(Sharp.Span)
    find_all_str = |re, s| Sharp.find_all(re, Str.to_utf8(s))

    find_str : Sharp.T, Str -> Try(Sharp.Span, [NoMatch])
    find_str = |re, s| Sharp.find(re, Str.to_utf8(s))

    is_match_str : Sharp.T, Str -> Bool
    is_match_str = |re, s| Sharp.is_match(re, Str.to_utf8(s))

    count_str : Sharp.T, Str -> U64
    count_str = |re, s| Sharp.count(re, Str.to_utf8(s))

    replace_all_str : Sharp.T, Str, Str -> Str
    replace_all_str = |re, hay, rep| Str.from_utf8_lossy(Sharp.replace_all(re, Str.to_utf8(hay), Str.to_utf8(rep)))

    split_str : Sharp.T, Str -> List(Str)
    split_str = |re, hay| List.map(Sharp.split(re, Str.to_utf8(hay)), Str.from_utf8_lossy)

    # --- introspection (tests, debugging) ---------------------------------------

    ## one-line rendering of a compile error
    err_str : Err.Error -> Str
    err_str = |e| Err.to_str(e)

    ## the pattern node in RE#'s notation
    show : Sharp.T -> Str
    show = |re| Show.show(re.a, re.trie, re.root)

    ## any node in RE#'s notation
    show_node : Sharp.T, U32 -> Str
    show_node = |re, id| Show.show(re.a, re.trie, id)

    ## the minterms in RE#'s notation
    minterms : Sharp.T -> List(Str)
    minterms = |re| List.map(Trie.upto(re.trie.n_classes.to_u64()), |m| Show.tset(re.a, re.trie, TSet.bit(m.to_u32_wrap())))

    n_nodes : Sharp.T -> U64
    n_nodes = |re| Arena.n_nodes(re.a)

    ## the reverse pattern in RE#'s notation
    show_rev : Sharp.T -> Str
    show_rev = |re| Show.show(re.a, re.trie, re.rev)

    ## the `_*·rev` search-start node in RE#'s notation
    show_rev_ts : Sharp.T -> Str
    show_rev_ts = |re| Show.show(re.a, re.trie, re.rev_ts)

    ## the pattern with its lookbehind prefix stripped
    show_noprefix : Sharp.T -> Str
    show_noprefix = |re| Show.show(re.a, re.trie, re.noprefix)

    ## the derivative of a node by the class of codepoint `cp` at `loc`
    ## (0 begin, 1 center, 2 end), printed (tests: RE#'s `der1` helpers)
    derive_show : Sharp.T, U32, U32, U32 -> Str
    derive_show = |re, node, loc, cp| {
        mt = TSet.bit(Trie.class_of(re.trie, cp))
        d = Deriv.derivative(re.a, loc, mt, node)
        Show.show(d.a, re.trie, d.id)
    }

    ## the derivative of the raw pattern by the first codepoint of `s`
    der1 : Sharp.T, Str -> Str
    der1 = |re, s| Sharp.derive_show(re, re.root, Deriv.loc_begin, Sharp.first_cp(s))

    ## the derivative of `_*·pattern` by the first codepoint of `s`
    der1_ts : Sharp.T, Str -> Str
    der1_ts = |re, s| Sharp.derive_show(re, re.ts, Deriv.loc_begin, Sharp.first_cp(s))

    ## the End-location derivative of the reverse pattern by the LAST codepoint of `s`
    der1_rev : Sharp.T, Str -> Str
    der1_rev = |re, s| Sharp.derive_show(re, re.rev, Deriv.loc_end, Sharp.last_cp(s))

    first_cp : Str -> U32
    first_cp = |s| (Utf8.decode(Str.to_utf8(s), 0)).cp

    last_cp : Str -> U32
    last_cp = |s| {
        b = Str.to_utf8(s)
        (Utf8.decode(b, Utf8.sym_start(b, List.len(b) - 1))).cp
    }

    ## the derivative of the raw pattern at position `pos` (codepoint index) of `s`, Begin location as RE#'s `der1RPos`
    der1_at : Sharp.T, Str, U64 -> Str
    der1_at = |re, s, pos| {
        cps = Sharp.cps(Str.to_utf8(s), 0, [])
        Sharp.derive_show(re, re.root, Deriv.loc_begin, List.get(cps, pos) ?? 0)
    }

    cps : List(U8), U64, List(U32) -> List(U32)
    cps = |b, i, acc|
        if i >= List.len(b) { acc } else {
            d = Utf8.decode(b, i)
            Sharp.cps(b, i + d.len, List.append(acc, d.cp))
        }

    ## nullability of the raw pattern at a location (0 begin, 1 center, 2 end)
    nullable_at : Sharp.T, U32 -> Bool
    nullable_at = |re, loc| Deriv.nullable(re.a, loc, re.root)

    ## the raw pattern's flags byte (NodeFlags)
    root_flags : Sharp.T -> U8
    root_flags = |re| Arena.flags(re.a, re.root)

    rev_ts_flags : Sharp.T -> U8
    rev_ts_flags = |re| Arena.flags(re.a, re.rev_ts)

    ## RE#'s GetFixedLength of the reverse pattern
    rev_fixed_len : Sharp.T -> Try(U32, [NotFixed])
    rev_fixed_len = |re| Arena.fixed_len(re.a, re.rev)
}
