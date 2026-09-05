## AST → regex nodes (RE#'s `RegexNodeConverter.fs`). Character classes become
## singletons over their tsets; `_` is `top`; `^`/`$`/`\A`/`\z` are the arena's
## anchor nodes; `\b` is rewritten from its neighbours into one of RE#'s four
## one-sided word-border lookarounds; negative lookarounds become positive
## lookarounds over complements. Every concatenation goes through
## `mk_concat_checked` (tier 3).
import Arena
import Ast
import Build
import TSet

Conv := [].{
    ## the compiled alphabet: the pattern's sets (as collected) and their tsets,
    ## plus the `\w` and `\s` tsets for the word-border heuristic
    Ctx : { sets : List(Ast.Set), tsets : List(U64), wordc : U64, spacec : U64 }

    Ids : { a : Arena.A, ids : List(U32) }

    tset_of : Conv.Ctx, Ast.Set -> U64
    tset_of = |ctx, cs|
        match List.find_first_index(ctx.sets, |s| s == cs) {
            Ok(i) => List.get(ctx.tsets, i) ?? 0
            Err(_) => 0
        }

    ## convert a whole pattern
    convert : Arena.A, Conv.Ctx, Ast -> Arena.R
    convert = |a, ctx, ast| {
        r = Conv.conv_list(a, ctx, ast)
        Build.mk_concat_checked(r.a, r.ids)
    }

    # the node(s) an AST contributes to an enclosing concatenation (`loop acc node`)
    conv_list : Arena.A, Conv.Ctx, Ast -> Conv.Ids
    conv_list = |a, ctx, ast|
        match ast {
            Empty => { a, ids: [] }
            Any => { a, ids: [Arena.top] }
            Chars(cs) => {
                r = Build.one(a, Conv.tset_of(ctx, cs))
                { a: r.a, ids: [r.id] }
            }
            Cat(xs) => Conv.conv_concat(a, ctx, xs)
            Alt(xs) => {
                arms = Conv.conv_arms(a, ctx, xs)
                r = Build.mk_or_seq(arms.a, arms.ids)
                { a: r.a, ids: [r.id] }
            }
            And(xs) => {
                arms = Conv.conv_arms(a, ctx, xs)
                r = Build.mk_and_seq(arms.a, arms.ids)
                { a: r.a, ids: [r.id] }
            }
            Not(x) => {
                inner = Conv.convert(a, ctx, x)
                r = Build.mk_not(inner.a, inner.id)
                { a: r.a, ids: [r.id] }
            }
            Loop(x, lo, hi) =>
                if Conv.is_wordb(x) {
                    { a: Arena.fail(a, "turning a word boundary into a loop does not make any sense"), ids: [Arena.bot] }
                } else {
                    inner = Conv.convert(a, ctx, x)
                    r = Build.mk_loop(inner.a, inner.id, lo, hi)
                    { a: r.a, ids: [r.id] }
                }
            Look(k) =>
                if k == Ast.look_caret {
                    { a, ids: [a.anc.caret] }
                } else if k == Ast.look_dollar {
                    { a, ids: [a.anc.dollar] }
                } else if k == Ast.look_big_a {
                    { a, ids: [Arena.begin_anchor] }
                } else if k == Ast.look_z {
                    { a, ids: [Arena.end_anchor] }
                } else if k == Ast.look_wordb {
                    # a `\b` with no neighbours at all
                    { a: Arena.fail(a, "\\b is only supported when next to word or non-word characters"), ids: [Arena.bot] }
                } else {
                    { a: Arena.fail(a, "Failed to parse word non-boundary"), ids: [Arena.bot] }
                }
            LookAhead(x, neg) => {
                body = Conv.convert(a, ctx, x)
                r = if neg { Build.rewrite_negative_lookaround(body.a, False, body.id) } else { Build.mk_lookaround(body.a, body.id, False, 0, Arena.rs_empty) }
                { a: r.a, ids: [r.id] }
            }
            LookBehind(x, neg) => {
                body = Conv.convert(a, ctx, x)
                r = if neg { Build.rewrite_negative_lookaround(body.a, True, body.id) } else { Build.mk_lookaround(body.a, body.id, True, 0, Arena.rs_empty) }
                { a: r.a, ids: [r.id] }
            }
        }

    # each arm of an Alt/And, converted as its own checked concatenation
    conv_arms : Arena.A, Conv.Ctx, List(Ast) -> Conv.Ids
    conv_arms = |a, ctx, xs|
        List.fold(xs, { a, ids: [] }, |acc, x| {
            r = Conv.convert(acc.a, ctx, x)
            { a: r.a, ids: List.append(acc.ids, r.id) }
        })

    # a concatenation: `\b` items see their neighbours (`convertAdjacent`)
    conv_concat : Arena.A, Conv.Ctx, List(Ast) -> Conv.Ids
    conv_concat = |a, ctx, xs|
        List.fold_with_index(xs, { a, ids: [] }, |acc, x, i| {
            r = Conv.conv_adjacent(acc.a, ctx, xs, i, x)
            { a: r.a, ids: List.concat(acc.ids, r.ids) }
        })

    conv_adjacent : Arena.A, Conv.Ctx, List(Ast), U64, Ast -> Conv.Ids
    conv_adjacent = |a, ctx, xs, i, x|
        match x {
            Alt(arms) => {
                # every arm sees the same neighbours
                rs = List.fold(arms, { a, ids: [] }, |acc, arm| {
                    inner = Conv.conv_adjacent(acc.a, ctx, xs, i, arm)
                    c = Build.mk_concat_checked(inner.a, inner.ids)
                    { a: c.a, ids: List.append(acc.ids, c.id) }
                })
                o = Build.mk_or_seq(rs.a, rs.ids)
                { a: o.a, ids: [o.id] }
            }
            Look(k) if k == Ast.look_wordb => {
                r = Conv.rewrite_word_border(a, ctx, xs, i)
                { a: r.a, ids: [r.id] }
            }
            _ => Conv.conv_list(a, ctx, x)
        }

    is_wordb : Ast -> Bool
    is_wordb = |x|
        match x {
            Look(k) => k == Ast.look_wordb
            _ => False
        }

    # --- word borders (`rewriteWordBorder`) ------------------------------------------

    Kind : [WordChar, NonWordChar, WordOption, NonWordOption, Unknown, Edge]

    # RE#'s `inferSet` heuristic for a class: no whitespace -> word; no word
    # characters -> non-word; otherwise unknown. Single codepoints are exact.
    set_kind : Conv.Ctx, Ast.Set -> Conv.Kind
    set_kind = |ctx, cs| {
        single =
            match cs.ranges {
                [r] if r.lo == r.hi and !cs.neg => Ok(r.lo)
                _ => Err(NotSingle)
            }
        match single {
            Ok(cp) => if Ast.is_word_cp(cp) { WordChar } else { NonWordChar }
            Err(_) => {
                t = Conv.tset_of(ctx, cs)
                if !TSet.intersects(t, ctx.spacec) { WordChar }
                else if !TSet.intersects(t, ctx.wordc) { NonWordChar }
                else { Unknown }
            }
        }
    }

    # `determineWordBorderNodeKind`: what kind of character borders this node
    # on its left (`left` True) or right edge
    node_kind : Conv.Ctx, Bool, Ast -> Conv.Kind
    node_kind = |ctx, left, ast|
        match ast {
            Chars(cs) => Conv.set_kind(ctx, cs)
            Loop(x, lo, _) =>
                match x {
                    Chars(cs) => {
                        k = Conv.set_kind(ctx, cs)
                        if lo == 0 {
                            match k {
                                WordChar => WordOption
                                NonWordChar => NonWordOption
                                other => other
                            }
                        } else {
                            k
                        }
                    }
                    _ => Unknown
                }
            Cat(xs) => {
                edge = if left { List.last(xs) } else { List.first(xs) }
                match edge {
                    Ok(e) => Conv.node_kind(ctx, left, e)
                    Err(_) => Unknown
                }
            }
            And(xs) =>
                List.fold_until(xs, Unknown, |acc, x|
                    match Conv.node_kind(ctx, left, x) {
                        WordChar => Break(WordChar)
                        NonWordChar => Break(NonWordChar)
                        _ => Continue(acc)
                    })
            LookAhead(x, False) => Conv.node_kind(ctx, left, x)
            LookBehind(x, False) => Conv.node_kind(ctx, left, x)
            _ => Unknown
        }

    to_left : Conv.Ctx, List(Ast), U64 -> Conv.Kind
    to_left = |ctx, xs, idx|
        if idx == 0 {
            Edge
        } else {
            k = Conv.node_kind(ctx, True, List.get(xs, idx - 1) ?? Empty)
            match k {
                WordOption => if Conv.to_left(ctx, xs, idx - 1) == WordChar { WordChar } else { Unknown }
                NonWordOption => if Conv.to_left(ctx, xs, idx - 1) == NonWordChar { NonWordChar } else { Unknown }
                other => other
            }
        }

    to_right : Conv.Ctx, List(Ast), U64 -> Conv.Kind
    to_right = |ctx, xs, idx|
        if idx + 1 >= List.len(xs) {
            Edge
        } else {
            k = Conv.node_kind(ctx, False, List.get(xs, idx + 1) ?? Empty)
            match k {
                WordOption => if Conv.to_right(ctx, xs, idx + 1) == WordChar { WordChar } else { Unknown }
                NonWordOption => if Conv.to_right(ctx, xs, idx + 1) == NonWordChar { NonWordChar } else { Unknown }
                other => other
            }
        }

    rewrite_word_border : Arena.A, Conv.Ctx, List(Ast), U64 -> Arena.R
    rewrite_word_border = |a, ctx, xs, idx| {
        left = Conv.to_left(ctx, xs, idx)
        right = Conv.to_right(ctx, xs, idx)
        match (left, right) {
            (NonWordChar, WordChar) => { a, id: Arena.eps }
            (WordChar, NonWordChar) => { a, id: Arena.eps }
            (WordChar, _) => { a, id: a.anc.nwr }
            (NonWordChar, _) => { a, id: a.anc.wr }
            (_, WordChar) => { a, id: a.anc.nwl }
            (_, NonWordChar) => { a, id: a.anc.wl }
            (Edge, Edge) => { a: Arena.fail(a, "\\b is only supported when next to word or non-word characters"), id: Arena.bot }
            _ => { a: Arena.fail(a, "Resharp does not support unconstrained word borders, rewrite \\b.*\\b to \\b\\w+\\b or \\b\\s+\\b to show which side the word is on"), id: Arena.bot }
        }
    }
}
