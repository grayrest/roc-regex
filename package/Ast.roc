## RE#'s pattern syntax → AST. Standard syntax plus `&` (intersection,
## binds between `|` and concatenation), `~(...)` (complement), `_` (universal
## wildcard), and lookarounds `(?=` `(?!` `(?<=` `(?<!`. `(...)` is a plain
## group (RE# has no captures). Lazy quantifiers are accepted and mean their
## greedy form, as in RE# (laziness has no meaning under set semantics).
## `^`/`$` are line anchors; `\A`/`\z` the text anchors.
##
## The AST is this module's nominal type; destructure it only with `match`.
import Err
import Uni
import Utf8

Ast := [
    Empty,
    Chars({ neg : Bool, ranges : List(Ast.Rng) }),
    Any,
    Cat(List(Ast)),
    Alt(List(Ast)),
    And(List(Ast)),
    Not(Ast),
    Loop(Ast, U32, U32),
    Look(U32),
    LookAhead(Ast, Bool),
    LookBehind(Ast, Bool),
].{
    Rng : { lo : U32, hi : U32 }

    ## unbounded loop upper bound (RE#'s Int32.MaxValue role)
    inf : U32
    inf = 0xFFFF_FFFF

    # Look kinds
    look_caret : U32
    look_caret = 0
    look_dollar : U32
    look_dollar = 1
    look_wordb : U32
    look_wordb = 2
    look_nwordb : U32
    look_nwordb = 3
    look_big_a : U32
    look_big_a = 4
    look_z : U32
    look_z = 5

    ## Parse a pattern. The pattern-length budget applies here.
    parse : Str -> Try(Ast, Err.Error)
    parse = |src| {
        all_toks = Ast.lex(Str.to_utf8(src), 0, [])
        case_insensitive = Ast.starts_ci(all_toks)
        toks = if case_insensitive { List.drop_first(all_toks, 4) } else { all_toks }
        given = List.len(toks)
        if given > 1000 {
            Err(Err.whole(src, PatternTooLong({ limit: 1000, given })))
        } else {
            st = Ast.parse_alt({ src, toks, i: 0, depth: 0 })?
            if st.i < List.len(toks) {
                Err(Ast.err_at(src, toks, st.i, GroupUnopened))
            } else {
                Ok(Ast.simplify(if case_insensitive { Ast.fold_ast(st.ast) } else { st.ast }))
            }
        }
    }

    # --- token stream ---------------------------------------------------------

    Tok : { cp : U32, off : U64 }

    lex : List(U8), U64, List(Ast.Tok) -> List(Ast.Tok)
    lex = |b, i, acc|
        if i >= List.len(b) {
            acc
        } else {
            # pattern text is a Roc `Str`, so it is valid UTF-8 and `Utf8.decode`
            # never reports `ok: False` here; its extra validation is free of
            # consequence and the `cp`/`len` it returns are the plain ones.
            d = Utf8.decode(b, i)
            Ast.lex(b, i + d.len, List.append(acc, { cp: d.cp, off: i }))
        }

    err_at : Str, List(Ast.Tok), U64, Err.Kind -> Err.Error
    err_at = |src, toks, i, kind| {
        off =
            match List.get(toks, i) {
                Ok(t) => t.off
                Err(_) => Str.count_utf8_bytes(src)
            }
        Err.err(src, off, kind)
    }

    cp_at : List(Ast.Tok), U64 -> Try(U32, [End])
    cp_at = |toks, i|
        match List.get(toks, i) {
            Ok(t) => Ok(t.cp)
            Err(_) => Err(End)
        }

    # --- character-class range sets --------------------------------------------

    ranges_d : List(Ast.Rng)
    ranges_d = Uni.ranges(Uni.d_hex)

    ranges_w : List(Ast.Rng)
    ranges_w = Uni.ranges(Uni.w_hex)

    ranges_s : List(Ast.Rng)
    ranges_s = Uni.ranges(Uni.s_hex)

    ## word-ness of a codepoint (the Unicode `\w` set), with an ASCII fast path
    is_word_cp : U32 -> Bool
    is_word_cp = |c|
        if c < 0x80 {
            (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95
        } else {
            List.any(Ast.ranges_w, |r| c >= r.lo and c <= r.hi)
        }

    # --- grammar: alt -> and -> cat -> repeat -> atom ---------------------------

    St : { src : Str, toks : List(Ast.Tok), i : U64, depth : U64 }
    Out : { ast : Ast, i : U64 }

    nest_limit : U64
    nest_limit = 250

    ## a level's arms as one node: none is `Empty`, one is itself, more is `wrap`
    node_of : List(Ast), (List(Ast) -> Ast) -> Ast
    node_of = |xs, wrap|
        if List.is_empty(xs) {
            Empty
        } else if List.len(xs) == 1 {
            List.get(xs, 0) ?? Empty
        } else {
            wrap(xs)
        }

    # `|` and `&` are the same left-associative level: parse one sub-expression,
    # then keep going while the separator is there. They differ only in the
    # separator, the tighter level below them and the node they build.
    parse_sep : Ast.St, U64, List(Ast), U32, (Ast.St -> Try(Ast.Out, Err.Error)), (List(Ast) -> Ast) -> Try(Ast.Out, Err.Error)
    parse_sep = |st, i, arms, sep, sub, wrap|
        if Ast.cp_at(st.toks, i) == Ok(sep) {
            next = sub({ ..st, i: i + 1 })?
            Ast.parse_sep(st, next.i, List.append(arms, next.ast), sep, sub, wrap)
        } else {
            Ok({ ast: Ast.node_of(arms, wrap), i })
        }

    parse_level : Ast.St, U32, (Ast.St -> Try(Ast.Out, Err.Error)), (List(Ast) -> Ast) -> Try(Ast.Out, Err.Error)
    parse_level = |st, sep, sub, wrap| {
        first = sub(st)?
        Ast.parse_sep(st, first.i, [first.ast], sep, sub, wrap)
    }

    parse_alt : Ast.St -> Try(Ast.Out, Err.Error)
    parse_alt = |st| Ast.parse_level(st, '|', Ast.parse_and, |xs| Alt(xs))

    parse_and : Ast.St -> Try(Ast.Out, Err.Error)
    parse_and = |st| Ast.parse_level(st, '&', Ast.parse_cat, |xs| And(xs))

    parse_cat : Ast.St -> Try(Ast.Out, Err.Error)
    parse_cat = |st| Ast.parse_cat_loop(st, st.i, [])

    parse_cat_loop : Ast.St, U64, List(Ast) -> Try(Ast.Out, Err.Error)
    parse_cat_loop = |st, i, acc| {
        c = Ast.cp_at(st.toks, i)
        stop = c == Ok('|') or c == Ok('&') or c == Ok(')') or c == Err(End)
        if stop {
            Ok({ ast: Ast.node_of(acc, |xs| Cat(xs)), i })
        } else {
            out = Ast.parse_repeat({ ..st, i })?
            Ast.parse_cat_loop(st, out.i, List.append(acc, out.ast))
        }
    }

    parse_repeat : Ast.St -> Try(Ast.Out, Err.Error)
    parse_repeat = |st| {
        atom = Ast.parse_atom(st)?
        Ast.apply_postfix(st, atom.i, atom.ast)
    }

    apply_postfix : Ast.St, U64, Ast -> Try(Ast.Out, Err.Error)
    apply_postfix = |st, i, ast|
        match Ast.cp_at(st.toks, i) {
            Ok('*') => Ast.after_quant(st, i + 1, Loop(ast, 0, Ast.inf))
            Ok('+') => Ast.after_quant(st, i + 1, Loop(ast, 1, Ast.inf))
            Ok('?') => Ast.after_quant(st, i + 1, Loop(ast, 0, 1))
            Ok('{') => Ast.parse_brace(st, i + 1, ast)
            _ => Ok({ ast, i })
        }

    # a `?` after a quantifier marks it lazy. Under set semantics laziness is
    # meaningless (`a*?` denotes the same language as `a*`), and RE# itself
    # accepts these and treats them as greedy (its converter maps `Lazyloop` to
    # `mkLoop`), so the marker is skipped. Any further quantifier stacks
    # (`a**` is `(a*)*`).
    after_quant : Ast.St, U64, Ast -> Try(Ast.Out, Err.Error)
    after_quant = |st, i, ast|
        if Ast.cp_at(st.toks, i) == Ok('?') {
            Ast.apply_postfix(st, i + 1, ast)
        } else {
            Ast.apply_postfix(st, i, ast)
        }

    parse_brace : Ast.St, U64, Ast -> Try(Ast.Out, Err.Error)
    parse_brace = |st, i, ast| {
        lo = Ast.read_int(st.toks, i, 0, False)
        if !lo.any {
            Err(Ast.err_at(st.src, st.toks, i, RepetitionCountInvalid))
        } else {
            after_lo = lo.i
            after_lo_cp = Ast.cp_at(st.toks, after_lo)
            if after_lo_cp == Ok('}') {
                Ast.after_quant(st, after_lo + 1, Loop(ast, lo.n, lo.n))
            } else if after_lo_cp == Ok(',') {
                hi = Ast.read_int(st.toks, after_lo + 1, 0, False)
                if Ast.cp_at(st.toks, hi.i) == Ok('}') {
                    if hi.any {
                        if hi.n < lo.n {
                            Err(Ast.err_at(st.src, st.toks, after_lo + 1, RepetitionCountInvalid))
                        } else {
                            Ast.after_quant(st, hi.i + 1, Loop(ast, lo.n, hi.n))
                        }
                    } else {
                        Ast.after_quant(st, hi.i + 1, Loop(ast, lo.n, Ast.inf))
                    }
                } else {
                    Err(Ast.err_at(st.src, st.toks, hi.i, RepetitionCountUnclosed))
                }
            } else {
                Err(Ast.err_at(st.src, st.toks, after_lo, RepetitionCountUnclosed))
            }
        }
    }

    read_int : List(Ast.Tok), U64, U32, Bool -> { n : U32, i : U64, any : Bool }
    read_int = |toks, i, acc, any|
        match Ast.cp_at(toks, i) {
            Ok(c) if c >= 48 and c <= 57 => Ast.read_int(toks, i + 1, acc * 10 + (c - 48), True)
            _ => { n: acc, i, any }
        }

    parse_atom : Ast.St -> Try(Ast.Out, Err.Error)
    parse_atom = |st| {
        one = |ast| Ok({ ast, i: st.i + 1 })
        match Ast.cp_at(st.toks, st.i) {
            Err(_) => Ok({ ast: Empty, i: st.i })
            Ok('(') => Ast.parse_group(st)
            Ok('~') =>
                if Ast.cp_at(st.toks, st.i + 1) == Ok('(') {
                    inner = Ast.parse_group({ ..st, i: st.i + 1 })?
                    Ok({ ast: Not(inner.ast), i: inner.i })
                } else {
                    Err(Ast.err_at(st.src, st.toks, st.i, ComplementNeedsGroup))
                }
            Ok('[') => Ast.parse_class(st.src, st.toks, st.i + 1)
            Ok('.') => one(Chars({ neg: True, ranges: [{ lo: 10, hi: 10 }] }))
            Ok('_') => one(Any)
            Ok('^') => one(Look(Ast.look_caret))
            Ok('$') => one(Look(Ast.look_dollar))
            Ok('\\') => Ast.parse_escape(st.src, st.toks, st.i + 1)
            Ok('*') | Ok('+') | Ok('?') => Err(Ast.err_at(st.src, st.toks, st.i, RepetitionMissing))
            Ok(cp) => one(Chars({ neg: False, ranges: [{ lo: cp, hi: cp }] }))
        }
    }

    # `(` at st.i: group, flags group, lookaround, or named group
    parse_group : Ast.St -> Try(Ast.Out, Err.Error)
    parse_group = |st|
        if st.depth >= Ast.nest_limit {
            Err(Err.whole(st.src, NestLimitExceeded({ limit: Ast.nest_limit, given: st.depth + 1 })))
        } else {
            h = Ast.group_head(st.toks, st.i)
            if h.bad {
                Err(Ast.err_at(st.src, st.toks, st.i + 2, FlagUnsupported))
            } else {
                inner = Ast.parse_alt({ ..st, i: h.inner, depth: st.depth + 1 })?
                if Ast.cp_at(st.toks, inner.i) != Ok(')') {
                    Err(Ast.err_at(st.src, st.toks, st.i, GroupUnclosed))
                } else {
                    body = if h.case_insensitive { Ast.fold_ast(inner.ast) } else { inner.ast }
                    node =
                        match h.kind {
                            Plain => body
                            Ahead(neg) => LookAhead(body, neg)
                            Behind(neg) => LookBehind(body, neg)
                        }
                    Ok({ ast: node, i: inner.i + 1 })
                }
            }
        }

    GroupKind : [Plain, Ahead(Bool), Behind(Bool)]

    # classify a group opener at `i` ('(')
    group_head : List(Ast.Tok), U64 -> { kind : Ast.GroupKind, case_insensitive : Bool, inner : U64, bad : Bool }
    group_head = |toks, i|
        if Ast.cp_at(toks, i + 1) == Ok('?') {
            after_q_cp = Ast.cp_at(toks, i + 2)
            if after_q_cp == Ok('=') {
                { kind: Ahead(False), case_insensitive: False, inner: i + 3, bad: False }
            } else if after_q_cp == Ok('!') {
                { kind: Ahead(True), case_insensitive: False, inner: i + 3, bad: False }
            } else if after_q_cp == Ok('<') {
                after_lt_cp = Ast.cp_at(toks, i + 3)
                if after_lt_cp == Ok('=') {
                    { kind: Behind(False), case_insensitive: False, inner: i + 4, bad: False }
                } else if after_lt_cp == Ok('!') {
                    { kind: Behind(True), case_insensitive: False, inner: i + 4, bad: False }
                } else {
                    # (?<name> ... ) — a named group is a plain group
                    { kind: Plain, case_insensitive: False, inner: Ast.skip_name(toks, i + 3), bad: False }
                }
            } else if after_q_cp == Ok('P') and Ast.cp_at(toks, i + 3) == Ok('<') {
                { kind: Plain, case_insensitive: False, inner: Ast.skip_name(toks, i + 4), bad: False }
            } else {
                # (?flags: ... ) or (?: ... )
                f = Ast.read_flags(toks, i + 2, { case_insensitive: False, bad: False })
                { kind: Plain, case_insensitive: f.case_insensitive, inner: f.i + 1, bad: f.bad or !f.scoped }
            }
        } else {
            { kind: Plain, case_insensitive: False, inner: i + 1, bad: False }
        }

    skip_name : List(Ast.Tok), U64 -> U64
    skip_name = |toks, i|
        match Ast.cp_at(toks, i) {
            Ok('>') => i + 1
            Err(_) => i
            Ok(_) => Ast.skip_name(toks, i + 1)
        }

    # An unimplemented flag is an ERROR, not a skip: skipping would give
    # `(?s:.)` and `(?U:a+)` the wrong meaning silently. `i` is the only one
    # implemented, and `.` already excludes `\n` unconditionally in RE#, so
    # there is no `(?s)`.
    #
    # `scoped` says the group ended at `:`, i.e. it is `(?flags:…)` and brackets
    # something. A group that ends at `)` is a flag SETTING for the rest of the
    # pattern, which only `starts_ci` handles and only at offset 0; anywhere
    # else it is unsupported: `a(?i)bc` is a `FlagUnsupported` error, not a
    # group holding `bc`.
    read_flags : List(Ast.Tok), U64, { case_insensitive : Bool, bad : Bool } -> { case_insensitive : Bool, i : U64, bad : Bool, scoped : Bool }
    read_flags = |toks, i, acc|
        match Ast.cp_at(toks, i) {
            Ok('i') => Ast.read_flags(toks, i + 1, { case_insensitive: True, bad: acc.bad })
            Ok(':') => { case_insensitive: acc.case_insensitive, i, bad: acc.bad, scoped: True }
            Ok(')') => { case_insensitive: acc.case_insensitive, i, bad: acc.bad, scoped: False }
            Err(_) => { case_insensitive: acc.case_insensitive, i, bad: acc.bad, scoped: False }
            _ => Ast.read_flags(toks, i + 1, { case_insensitive: acc.case_insensitive, bad: True })
        }

    ## `\d` `\w` `\s` and their negations — the one table both escape parsers
    ## read. They disagree on what to DO with `neg`: outside a class it is the
    ## `Chars` node's own flag, inside one the ranges are complemented in place.
    class_shorthand : U32 -> Try({ ranges : List(Ast.Rng), neg : Bool }, [NotShorthand])
    class_shorthand = |c|
        match c {
            'd' => Ok({ ranges: Ast.ranges_d, neg: False })
            'D' => Ok({ ranges: Ast.ranges_d, neg: True })
            'w' => Ok({ ranges: Ast.ranges_w, neg: False })
            'W' => Ok({ ranges: Ast.ranges_w, neg: True })
            's' => Ok({ ranges: Ast.ranges_s, neg: False })
            'S' => Ok({ ranges: Ast.ranges_s, neg: True })
            _ => Err(NotShorthand)
        }

    ## The single-character escapes both parsers share. `\e` and `\a` are NOT
    ## here: RE#'s class parser does not know them, so inside a class they stay
    ## the literals `e` and `a` and only `parse_escape` maps them.
    simple_escape : U32 -> Try(U32, [NotSimple])
    simple_escape = |c|
        match c {
            'n' => Ok(10)
            't' => Ok(9)
            'r' => Ok(13)
            'f' => Ok(12)
            'v' => Ok(11)
            '0' => Ok(0)
            _ => Err(NotSimple)
        }

    is_letter : U32 -> Bool
    is_letter = |v| (v >= 'A' and v <= 'Z') or (v >= 'a' and v <= 'z')

    parse_escape : Str, List(Ast.Tok), U64 -> Try(Ast.Out, Err.Error)
    parse_escape = |src, toks, i| {
        c = Ast.cp_at(toks, i)
        cls = |neg, rs| Ok({ ast: Chars({ neg, ranges: rs }), i: i + 1 })
        lit = |cp| Ok({ ast: Chars({ neg: False, ranges: [{ lo: cp, hi: cp }] }), i: i + 1 })
        match c {
            Err(_) => Err(Ast.err_at(src, toks, i, EscapeUnexpectedEof))
            Ok('b') => Ok({ ast: Look(Ast.look_wordb), i: i + 1 })
            Ok('B') => Ok({ ast: Look(Ast.look_nwordb), i: i + 1 })
            Ok('A') => Ok({ ast: Look(Ast.look_big_a), i: i + 1 })
            Ok('Z') => Ok({ ast: Look(Ast.look_z), i: i + 1 })
            # `\z` is RE#'s and Rust's spelling of the same anchor, and the
            # differential corpora are written in it. Accepted, not documented:
            # the pair this engine spells is `\A` and `\Z`.
            Ok('z') => Ok({ ast: Look(Ast.look_z), i: i + 1 })
            Ok('p') => Ast.parse_prop(src, toks, i + 1, False)
            Ok('P') => Ast.parse_prop(src, toks, i + 1, True)
            Ok('u') => {
                r = Ast.parse_u(src, toks, i + 1)?
                Ok({ ast: Chars({ neg: False, ranges: [{ lo: r.cp, hi: r.cp }] }), i: r.i })
            }
            Ok('x') => {
                r = Ast.hex_escape(src, toks, i, i + 1, 2)?
                Ok({ ast: Chars({ neg: False, ranges: [{ lo: r.cp, hi: r.cp }] }), i: r.i })
            }
            Ok('e') => lit(27)
            Ok('a') => lit(7)
            Ok(v) =>
                match Ast.class_shorthand(v) {
                    Ok(shorthand) => cls(shorthand.neg, shorthand.ranges)
                    Err(_) =>
                        match Ast.simple_escape(v) {
                            Ok(cp) => lit(cp)
                            Err(_) if Ast.is_letter(v) => Err(Ast.err_at(src, toks, i, EscapeUnrecognized))
                            Err(_) => lit(v)
                        }
                }
        }
    }

    # `read_hex` refuses with its own `BadHex`; every caller reports the same
    # `EscapeUnrecognized`, at `at` rather than at the digits.
    hex_escape : Str, List(Ast.Tok), U64, U64, U64 -> Try({ cp : U32, i : U64 }, Err.Error)
    hex_escape = |src, toks, at, i, n|
        Try.map_err(Ast.read_hex(toks, i, n), |_| Ast.err_at(src, toks, at, EscapeUnrecognized))

    # \u{HEX} or \uHHHH; `i` is just past the `u`
    parse_u : Str, List(Ast.Tok), U64 -> Try({ cp : U32, i : U64 }, Err.Error)
    parse_u = |src, toks, i|
        if Ast.cp_at(toks, i) == Ok('{') {
            j = Try.map_err(Ast.find_brace(toks, i + 1), |_| Ast.err_at(src, toks, i, EscapeUnrecognized))?
            r = Ast.hex_escape(src, toks, i, i + 1, j - (i + 1))?
            Ok({ cp: r.cp, i: j + 1 })
        } else {
            Ast.hex_escape(src, toks, i, i, 4)
        }

    read_hex : List(Ast.Tok), U64, U64 -> Try({ cp : U32, i : U64 }, [BadHex])
    read_hex = |toks, i, n|
        if n == 0 or n > 6 {
            Err(BadHex)
        } else {
            Ast.hex_loop(toks, i, n, 0)
        }

    hex_loop : List(Ast.Tok), U64, U64, U32 -> Try({ cp : U32, i : U64 }, [BadHex])
    hex_loop = |toks, i, n, acc|
        if n == 0 {
            if acc > 0x10_FFFF { Err(BadHex) } else { Ok({ cp: acc, i }) }
        } else {
            match Ast.cp_at(toks, i) {
                Ok(c) if c >= '0' and c <= '9' => Ast.hex_loop(toks, i + 1, n - 1, acc * 16 + (c - 48))
                Ok(c) if c >= 'a' and c <= 'f' => Ast.hex_loop(toks, i + 1, n - 1, acc * 16 + (c - 87))
                Ok(c) if c >= 'A' and c <= 'F' => Ast.hex_loop(toks, i + 1, n - 1, acc * 16 + (c - 55))
                _ => Err(BadHex)
            }
        }

    ## `\p{Name}` / `\P{Name}`: the braces, the name and the lookup. `neg` is the
    ## caller's business — see `class_shorthand` for why the two differ.
    prop_ranges : Str, List(Ast.Tok), U64 -> Try({ ranges : List(Ast.Rng), i : U64 }, Err.Error)
    prop_ranges = |src, toks, i|
        if Ast.cp_at(toks, i) == Ok('{') {
            j = Try.map_err(Ast.find_brace(toks, i + 1), |_| Ast.err_at(src, toks, i, ClassUnclosed))?
            hex = Try.map_err(Uni.lookup(Ast.slice_str(toks, i + 1, j)), |_| Ast.err_at(src, toks, i, EscapeUnrecognized))?
            Ok({ ranges: Uni.ranges(hex), i: j + 1 })
        } else {
            Err(Ast.err_at(src, toks, i, EscapeUnrecognized))
        }

    parse_prop : Str, List(Ast.Tok), U64, Bool -> Try(Ast.Out, Err.Error)
    parse_prop = |src, toks, i, neg| {
        p = Ast.prop_ranges(src, toks, i)?
        Ok({ ast: Chars({ neg, ranges: p.ranges }), i: p.i })
    }

    find_brace : List(Ast.Tok), U64 -> Try(U64, [End])
    find_brace = |toks, i|
        match Ast.cp_at(toks, i) {
            Err(_) => Err(End)
            Ok('}') => Ok(i)
            Ok(_) => Ast.find_brace(toks, i + 1)
        }

    slice_str : List(Ast.Tok), U64, U64 -> Str
    slice_str = |toks, lo, hi|
        List.sublist(toks, { start: lo, len: hi - lo })
        |> List.map(|t| t.cp)
        |> Utf8.cps_to_str

    # leading (?i) flag: tokens '(', '?', 'i', ')'
    starts_ci : List(Ast.Tok) -> Bool
    starts_ci = |toks|
        Ast.cp_at(toks, 0) == Ok('(') and Ast.cp_at(toks, 1) == Ok('?') and Ast.cp_at(toks, 2) == Ok('i') and Ast.cp_at(toks, 3) == Ok(')')

    # (?i): expand every Chars node with simple case-fold partners
    fold_ast : Ast -> Ast
    fold_ast = |ast|
        match ast {
            Empty => Empty
            Any => Any
            Look(_) => ast
            Chars(cs) => Chars({ neg: cs.neg, ranges: Ast.fold_ranges(cs.ranges) })
            Cat(xs) => Cat(List.map(xs, Ast.fold_ast))
            Alt(xs) => Alt(List.map(xs, Ast.fold_ast))
            And(xs) => And(List.map(xs, Ast.fold_ast))
            Not(x) => Not(Ast.fold_ast(x))
            Loop(x, lo, hi) => Loop(Ast.fold_ast(x), lo, hi)
            LookAhead(x, n) => LookAhead(Ast.fold_ast(x), n)
            LookBehind(x, n) => LookBehind(Ast.fold_ast(x), n)
        }

    # One pass over the orbit table per range, not one lookup per codepoint, so
    # folding holds at any range width: `(?i)[a-\u{525}]` matches a Kelvin sign.
    fold_ranges : List(Ast.Rng) -> List(Ast.Rng)
    fold_ranges = |ranges|
        List.fold(ranges, ranges, |acc, r| List.concat(acc, Uni.fold_partners_in(r.lo, r.hi)))

    parse_class : Str, List(Ast.Tok), U64 -> Try(Ast.Out, Err.Error)
    parse_class = |src, toks, start_i| {
        neg = Ast.cp_at(toks, start_i) == Ok('^')
        i = if neg { start_i + 1 } else { start_i }
        Ast.class_items(src, toks, i, neg, [])
    }

    class_items : Str, List(Ast.Tok), U64, Bool, List(Ast.Rng) -> Try(Ast.Out, Err.Error)
    class_items = |src, toks, i, neg, acc|
        match Ast.cp_at(toks, i) {
            Err(_) => Err(Ast.err_at(src, toks, i, ClassUnclosed))
            Ok(']') if !List.is_empty(acc) => Ok({ ast: Chars({ neg, ranges: acc }), i: i + 1 })
            Ok('\\') => {
                step = Ast.class_escape(src, toks, i + 1)?
                Ast.class_maybe_range(src, toks, step.i, neg, acc, step.ranges)
            }
            Ok(v) => Ast.class_maybe_range(src, toks, i + 1, neg, acc, [{ lo: v, hi: v }])
        }

    class_maybe_range : Str, List(Ast.Tok), U64, Bool, List(Ast.Rng), List(Ast.Rng) -> Try(Ast.Out, Err.Error)
    class_maybe_range = |src, toks, i, neg, acc, item| {
        single = List.len(item) == 1 and (match List.get(item, 0) { Ok(r) => r.lo == r.hi, Err(_) => False })
        dash = Ast.cp_at(toks, i) == Ok('-')
        next_close = Ast.cp_at(toks, i + 1) == Ok(']')
        if single and dash and !next_close {
            lo = (List.get(item, 0) ?? { lo: 0, hi: 0 }).lo
            match Ast.cp_at(toks, i + 1) {
                Ok('\\') => {
                    step = Ast.class_escape(src, toks, i + 2)?
                    match step.ranges {
                        [r] if r.lo == r.hi and r.lo >= lo => Ast.class_items(src, toks, step.i, neg, List.append(acc, { lo, hi: r.lo }))
                        _ => Err(Ast.err_at(src, toks, i + 1, ClassRangeInvalid))
                    }
                }
                Ok(hi) =>
                    if hi < lo {
                        Err(Ast.err_at(src, toks, i + 1, ClassRangeInvalid))
                    } else {
                        Ast.class_items(src, toks, i + 2, neg, List.append(acc, { lo, hi }))
                    }
                Err(_) => Err(Ast.err_at(src, toks, i + 1, ClassRangeInvalid))
            }
        } else {
            Ast.class_items(src, toks, i, neg, List.concat(acc, item))
        }
    }

    class_escape : Str, List(Ast.Tok), U64 -> Try({ ranges : List(Ast.Rng), i : U64 }, Err.Error)
    class_escape = |src, toks, i| {
        one = |cp| Ok({ ranges: [{ lo: cp, hi: cp }], i: i + 1 })
        match Ast.cp_at(toks, i) {
            Err(_) => Err(Ast.err_at(src, toks, i, EscapeUnexpectedEof))
            Ok('p') => Ast.class_prop(src, toks, i + 1, False)
            Ok('P') => Ast.class_prop(src, toks, i + 1, True)
            Ok('u') => {
                r = Ast.parse_u(src, toks, i + 1)?
                Ok({ ranges: [{ lo: r.cp, hi: r.cp }], i: r.i })
            }
            Ok('x') => {
                r = Ast.hex_escape(src, toks, i, i + 1, 2)?
                Ok({ ranges: [{ lo: r.cp, hi: r.cp }], i: r.i })
            }
            Ok(v) =>
                match Ast.class_shorthand(v) {
                    Ok(shorthand) => Ok({ ranges: if shorthand.neg { Ast.complement(shorthand.ranges) } else { shorthand.ranges }, i: i + 1 })
                    Err(_) => one(Ast.simple_escape(v) ?? v)
                }
        }
    }

    class_prop : Str, List(Ast.Tok), U64, Bool -> Try({ ranges : List(Ast.Rng), i : U64 }, Err.Error)
    class_prop = |src, toks, i, neg| {
        p = Ast.prop_ranges(src, toks, i)?
        Ok({ ranges: if neg { Ast.complement(p.ranges) } else { p.ranges }, i: p.i })
    }

    ## complement of a set of ranges over [0, 0x10FFFF]
    complement : List(Ast.Rng) -> List(Ast.Rng)
    complement = |ranges| {
        sorted = List.sort_with(ranges, |a, b| U32.order_relative_to(a.lo, b.lo))
        r = List.fold(sorted, { out: [], next: 0 }, |st, range|
            if range.lo > st.next {
                { out: List.append(st.out, { lo: st.next, hi: range.lo - 1 }), next: range.hi + 1 }
            } else if range.hi + 1 > st.next {
                { out: st.out, next: range.hi + 1 }
            } else {
                st
            })
        if r.next <= 0x10_FFFF { List.append(r.out, { lo: r.next, hi: 0x10_FFFF }) } else { r.out }
    }

    # --- normalization (what .NET's RegexParser does before RE# sees the tree) ----
    #
    # Nested `|` / `&` / concatenations are spliced into their parent, and an
    # alternation whose every arm is a (non-negated) class becomes one class, so
    # `a|b|c` is `[a-c]` and `(.*|(.*11.*|1.*))` is a flat 3-way union that the
    # star-subsumption rewrite can collapse. Semantics-preserving.

    simplify : Ast -> Ast
    simplify = |ast|
        match ast {
            Cat(xs) => {
                ys = List.fold(xs, [], |acc, x|
                    match Ast.simplify(x) {
                        Cat(nested_children) => List.concat(acc, nested_children)
                        Empty => acc
                        y => List.append(acc, y)
                    })
                Ast.node_of(ys, |arms| Cat(arms))
            }
            Alt(xs) => {
                ys = List.fold(xs, [], |acc, x|
                    match Ast.simplify(x) {
                        Alt(nested_children) => List.concat(acc, nested_children)
                        y => List.append(acc, y)
                    })
                if List.len(ys) == 1 {
                    List.get(ys, 0) ?? Empty
                } else if List.all(ys, Ast.is_pos_class) {
                    Chars({ neg: False, ranges: List.fold(ys, [], |acc, y| match y { Chars(cs) => List.concat(acc, cs.ranges), _ => acc }) })
                } else {
                    Alt(ys)
                }
            }
            And(xs) => {
                ys = List.fold(xs, [], |acc, x|
                    match Ast.simplify(x) {
                        And(nested_children) => List.concat(acc, nested_children)
                        y => List.append(acc, y)
                    })
                Ast.node_of(ys, |arms| And(arms))
            }
            Not(x) => Not(Ast.simplify(x))
            Loop(x, lo, hi) => Loop(Ast.simplify(x), lo, hi)
            LookAhead(x, n) => LookAhead(Ast.simplify(x), n)
            LookBehind(x, n) => LookBehind(Ast.simplify(x), n)
            _ => ast
        }

    is_pos_class : Ast -> Bool
    is_pos_class = |x|
        match x {
            Chars(cs) => !cs.neg
            _ => False
        }

    # --- pattern-level queries -------------------------------------------------

    ## does the pattern assert a word boundary anywhere?
    has_wordb : Ast -> Bool
    has_wordb = |ast| Ast.has_look_kind(ast, |k| k == Ast.look_wordb or k == Ast.look_nwordb)

    ## does the pattern use a line anchor (`^` / `$`)?
    has_line_anchor : Ast -> Bool
    has_line_anchor = |ast| Ast.has_look_kind(ast, |k| k == Ast.look_caret or k == Ast.look_dollar)

    ## does the pattern contain a lookahead or lookbehind (at any depth)?
    has_lookaround : Ast -> Bool
    has_lookaround = |ast|
        match ast {
            LookAhead(_, _) => True
            LookBehind(_, _) => True
            Cat(xs) => List.any(xs, Ast.has_lookaround)
            Alt(xs) => List.any(xs, Ast.has_lookaround)
            And(xs) => List.any(xs, Ast.has_lookaround)
            Not(x) => Ast.has_lookaround(x)
            Loop(x, _, _) => Ast.has_lookaround(x)
            _ => False
        }

    has_look_kind : Ast, (U32 -> Bool) -> Bool
    has_look_kind = |ast, f|
        match ast {
            Look(k) => f(k)
            Cat(xs) => List.any(xs, |x| Ast.has_look_kind(x, f))
            Alt(xs) => List.any(xs, |x| Ast.has_look_kind(x, f))
            And(xs) => List.any(xs, |x| Ast.has_look_kind(x, f))
            Not(x) => Ast.has_look_kind(x, f)
            Loop(x, _, _) => Ast.has_look_kind(x, f)
            LookAhead(x, _) => Ast.has_look_kind(x, f)
            LookBehind(x, _) => Ast.has_look_kind(x, f)
            _ => False
        }

    ## Every distinct character set in the pattern, in first-appearance order.
    ## The converter finds a `Chars` node's tset by looking its set up here.
    Set : { neg : Bool, ranges : List(Ast.Rng) }

    collect_sets : Ast, List(Ast.Set) -> List(Ast.Set)
    collect_sets = |ast, acc|
        match ast {
            Chars(cs) => Ast.add_set(acc, cs)
            Cat(xs) => List.fold(xs, acc, |a, x| Ast.collect_sets(x, a))
            Alt(xs) => List.fold(xs, acc, |a, x| Ast.collect_sets(x, a))
            And(xs) => List.fold(xs, acc, |a, x| Ast.collect_sets(x, a))
            Not(x) => Ast.collect_sets(x, acc)
            Loop(x, _, _) => Ast.collect_sets(x, acc)
            LookAhead(x, _) => Ast.collect_sets(x, acc)
            LookBehind(x, _) => Ast.collect_sets(x, acc)
            _ => acc
        }

    add_set : List(Ast.Set), Ast.Set -> List(Ast.Set)
    add_set = |acc, cs| if List.contains(acc, cs) { acc } else { List.append(acc, cs) }

    ## flatten sets to the Trie's `[neg, count, lo, hi, ...]` table
    flat_sets : List(Ast.Set) -> List(U32)
    flat_sets = |sets|
        List.fold(sets, [], |acc, cs| {
            negw = if cs.neg { 1 } else { 0 }
            head = List.concat(acc, [negw, (List.len(cs.ranges)).to_u32_wrap()])
            List.fold(cs.ranges, head, |a, r| List.concat(a, [r.lo, r.hi]))
        })
}
