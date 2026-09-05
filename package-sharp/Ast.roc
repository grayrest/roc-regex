## RE#'s pattern syntax → AST (S8). Standard syntax plus `&` (intersection,
## binds between `|` and concatenation), `~(...)` (complement), `_` (universal
## wildcard), and lookarounds `(?=` `(?!` `(?<=` `(?<!`. `(...)` is a plain
## group (RE# has no captures). Lazy quantifiers are rejected, as RE# does.
## `^`/`$` are line anchors (S7); `\A`/`\z` the text anchors.
##
## Lexing, classes, escapes and `\p{}` are copied from `Comp`; the grammar is
## fresh. The AST is this module's nominal type; destructure it only with
## `match` (Owed upstream 2).
import Err
import Uni

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

    ## Parse a pattern. Budget 1 of D13 (pattern length) applies here.
    parse : Str -> Try(Ast, Err.Error)
    parse = |src| {
        toks0 = Ast.lex(Str.to_utf8(src), 0, [])
        ci = Ast.starts_ci(toks0)
        toks = if ci { List.drop_first(toks0, 4) } else { toks0 }
        given = List.len(toks)
        if given > 1000 {
            Err(Err.whole(src, PatternTooLong({ limit: 1000, given })))
        } else {
            match Ast.parse_alt({ src, toks, i: 0, depth: 0 }) {
                Ok(st) =>
                    if st.i < List.len(toks) {
                        Err(Ast.err_at(src, toks, st.i, GroupUnopened))
                    } else {
                        Ok(Ast.simplify(if ci { Ast.fold_ast(st.ast) } else { st.ast }))
                    }
                Err(e) => Err(e)
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
            d = Ast.decode(b, i)
            Ast.lex(b, i + d.len, List.append(acc, { cp: d.cp, off: i }))
        }

    # pattern text is a Roc `Str`, so it is valid UTF-8: a plain decoder suffices
    decode : List(U8), U64 -> { cp : U32, len : U64 }
    decode = |b, i| {
        b0 = Ast.at(b, i)
        if b0 < 0x80 {
            { cp: b0.to_u32(), len: 1 }
        } else if b0.bitwise_and(0xE0) == 0xC0 {
            hi = b0.bitwise_and(0x1F).to_u32().shl_wrap(6)
            { cp: hi.bitwise_or(Ast.cont(b, i + 1)), len: 2 }
        } else if b0.bitwise_and(0xF0) == 0xE0 {
            hi = b0.bitwise_and(0x0F).to_u32().shl_wrap(12)
            mid = Ast.cont(b, i + 1).shl_wrap(6)
            { cp: hi.bitwise_or(mid).bitwise_or(Ast.cont(b, i + 2)), len: 3 }
        } else {
            hi = b0.bitwise_and(0x07).to_u32().shl_wrap(18)
            m1 = Ast.cont(b, i + 1).shl_wrap(12)
            m2 = Ast.cont(b, i + 2).shl_wrap(6)
            { cp: hi.bitwise_or(m1).bitwise_or(m2).bitwise_or(Ast.cont(b, i + 3)), len: 4 }
        }
    }

    cont : List(U8), U64 -> U32
    cont = |b, i| Ast.at(b, i).bitwise_and(0x3F).to_u32()

    at : List(U8), U64 -> U8
    at = |b, i| List.get(b, i) ?? 0

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

    parse_alt : Ast.St -> Try(Ast.Out, Err.Error)
    parse_alt = |st|
        match Ast.parse_and(st) {
            Ok(first) => Ast.parse_alt_rest(st, first.i, [first.ast])
            Err(e) => Err(e)
        }

    parse_alt_rest : Ast.St, U64, List(Ast) -> Try(Ast.Out, Err.Error)
    parse_alt_rest = |st, i, arms|
        if Ast.cp_at(st.toks, i) == Ok('|') {
            match Ast.parse_and({ ..st, i: i + 1 }) {
                Ok(next) => Ast.parse_alt_rest(st, next.i, List.append(arms, next.ast))
                Err(e) => Err(e)
            }
        } else if List.len(arms) == 1 {
            Ok({ ast: List.get(arms, 0) ?? Empty, i })
        } else {
            Ok({ ast: Alt(arms), i })
        }

    parse_and : Ast.St -> Try(Ast.Out, Err.Error)
    parse_and = |st|
        match Ast.parse_cat(st) {
            Ok(first) => Ast.parse_and_rest(st, first.i, [first.ast])
            Err(e) => Err(e)
        }

    parse_and_rest : Ast.St, U64, List(Ast) -> Try(Ast.Out, Err.Error)
    parse_and_rest = |st, i, arms|
        if Ast.cp_at(st.toks, i) == Ok('&') {
            match Ast.parse_cat({ ..st, i: i + 1 }) {
                Ok(next) => Ast.parse_and_rest(st, next.i, List.append(arms, next.ast))
                Err(e) => Err(e)
            }
        } else if List.len(arms) == 1 {
            Ok({ ast: List.get(arms, 0) ?? Empty, i })
        } else {
            Ok({ ast: And(arms), i })
        }

    parse_cat : Ast.St -> Try(Ast.Out, Err.Error)
    parse_cat = |st| Ast.parse_cat_loop(st, st.i, [])

    parse_cat_loop : Ast.St, U64, List(Ast) -> Try(Ast.Out, Err.Error)
    parse_cat_loop = |st, i, acc| {
        c = Ast.cp_at(st.toks, i)
        stop = c == Ok('|') or c == Ok('&') or c == Ok(')') or c == Err(End)
        if stop {
            if List.is_empty(acc) {
                Ok({ ast: Empty, i })
            } else if List.len(acc) == 1 {
                Ok({ ast: List.get(acc, 0) ?? Empty, i })
            } else {
                Ok({ ast: Cat(acc), i })
            }
        } else {
            match Ast.parse_repeat({ ..st, i }) {
                Ok(out) => Ast.parse_cat_loop(st, out.i, List.append(acc, out.ast))
                Err(e) => Err(e)
            }
        }
    }

    parse_repeat : Ast.St -> Try(Ast.Out, Err.Error)
    parse_repeat = |st|
        match Ast.parse_atom(st) {
            Ok(atom) => Ast.apply_postfix(st, atom.i, atom.ast)
            Err(e) => Err(e)
        }

    apply_postfix : Ast.St, U64, Ast -> Try(Ast.Out, Err.Error)
    apply_postfix = |st, i, ast| {
        c = Ast.cp_at(st.toks, i)
        if c == Ok('*') {
            Ast.after_quant(st, i + 1, Loop(ast, 0, Ast.inf))
        } else if c == Ok('+') {
            Ast.after_quant(st, i + 1, Loop(ast, 1, Ast.inf))
        } else if c == Ok('?') {
            Ast.after_quant(st, i + 1, Loop(ast, 0, 1))
        } else if c == Ok('{') {
            Ast.parse_brace(st, i + 1, ast)
        } else {
            Ok({ ast, i })
        }
    }

    # a `?` after a quantifier is a lazy quantifier: unsupported in RE#. Any
    # further quantifier stacks (`a**` is `(a*)*`).
    after_quant : Ast.St, U64, Ast -> Try(Ast.Out, Err.Error)
    after_quant = |st, i, ast|
        if Ast.cp_at(st.toks, i) == Ok('?') {
            Err(Ast.err_at(st.src, st.toks, i, LazyQuantifierUnsupported))
        } else {
            Ast.apply_postfix(st, i, ast)
        }

    parse_brace : Ast.St, U64, Ast -> Try(Ast.Out, Err.Error)
    parse_brace = |st, i, ast| {
        lo = Ast.read_int(st.toks, i, 0, False)
        if !lo.any {
            Err(Ast.err_at(st.src, st.toks, i, RepetitionCountInvalid))
        } else {
            al = lo.i
            cc = Ast.cp_at(st.toks, al)
            if cc == Ok('}') {
                Ast.after_quant(st, al + 1, Loop(ast, lo.n, lo.n))
            } else if cc == Ok(',') {
                hi = Ast.read_int(st.toks, al + 1, 0, False)
                if Ast.cp_at(st.toks, hi.i) == Ok('}') {
                    if hi.any {
                        if hi.n < lo.n {
                            Err(Ast.err_at(st.src, st.toks, al + 1, RepetitionCountInvalid))
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
                Err(Ast.err_at(st.src, st.toks, al, RepetitionCountUnclosed))
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
        c = Ast.cp_at(st.toks, st.i)
        if c == Err(End) {
            Ok({ ast: Empty, i: st.i })
        } else if c == Ok('(') {
            Ast.parse_group(st)
        } else if c == Ok('~') {
            if Ast.cp_at(st.toks, st.i + 1) == Ok('(') {
                match Ast.parse_group({ ..st, i: st.i + 1 }) {
                    Ok(inner) => Ok({ ast: Not(inner.ast), i: inner.i })
                    Err(e) => Err(e)
                }
            } else {
                Err(Ast.err_at(st.src, st.toks, st.i, ComplementNeedsGroup))
            }
        } else if c == Ok('[') {
            Ast.parse_class(st.src, st.toks, st.i + 1)
        } else if c == Ok('.') {
            Ok({ ast: Chars({ neg: True, ranges: [{ lo: 10, hi: 10 }] }), i: st.i + 1 })
        } else if c == Ok('_') {
            Ok({ ast: Any, i: st.i + 1 })
        } else if c == Ok('^') {
            Ok({ ast: Look(Ast.look_caret), i: st.i + 1 })
        } else if c == Ok('$') {
            Ok({ ast: Look(Ast.look_dollar), i: st.i + 1 })
        } else if c == Ok('\\') {
            Ast.parse_escape(st.src, st.toks, st.i + 1)
        } else if c == Ok('*') or c == Ok('+') or c == Ok('?') {
            Err(Ast.err_at(st.src, st.toks, st.i, RepetitionMissing))
        } else {
            cp = match c { Ok(v) => v, Err(_) => 0 }
            Ok({ ast: Chars({ neg: False, ranges: [{ lo: cp, hi: cp }] }), i: st.i + 1 })
        }
    }

    # `(` at st.i: group, flags group, lookaround, or named group
    parse_group : Ast.St -> Try(Ast.Out, Err.Error)
    parse_group = |st|
        if st.depth >= Ast.nest_limit {
            Err(Err.whole(st.src, NestLimitExceeded({ limit: Ast.nest_limit, given: st.depth + 1 })))
        } else {
            h = Ast.group_head(st.toks, st.i)
            match Ast.parse_alt({ ..st, i: h.inner, depth: st.depth + 1 }) {
                Ok(inner) =>
                    if Ast.cp_at(st.toks, inner.i) == Ok(')') {
                        body = if h.ci { Ast.fold_ast(inner.ast) } else { inner.ast }
                        node =
                            match h.kind {
                                Plain => body
                                Ahead(neg) => LookAhead(body, neg)
                                Behind(neg) => LookBehind(body, neg)
                            }
                        Ok({ ast: node, i: inner.i + 1 })
                    } else {
                        Err(Ast.err_at(st.src, st.toks, st.i, GroupUnclosed))
                    }
                Err(e) => Err(e)
            }
        }

    GroupKind : [Plain, Ahead(Bool), Behind(Bool)]

    # classify a group opener at `i` ('(')
    group_head : List(Ast.Tok), U64 -> { kind : Ast.GroupKind, ci : Bool, inner : U64 }
    group_head = |toks, i|
        if Ast.cp_at(toks, i + 1) == Ok('?') {
            c2 = Ast.cp_at(toks, i + 2)
            if c2 == Ok('=') {
                { kind: Ahead(False), ci: False, inner: i + 3 }
            } else if c2 == Ok('!') {
                { kind: Ahead(True), ci: False, inner: i + 3 }
            } else if c2 == Ok('<') {
                c3 = Ast.cp_at(toks, i + 3)
                if c3 == Ok('=') {
                    { kind: Behind(False), ci: False, inner: i + 4 }
                } else if c3 == Ok('!') {
                    { kind: Behind(True), ci: False, inner: i + 4 }
                } else {
                    # (?<name> ... ) — a named group is a plain group
                    { kind: Plain, ci: False, inner: Ast.skip_name(toks, i + 3) }
                }
            } else if c2 == Ok('P') and Ast.cp_at(toks, i + 3) == Ok('<') {
                { kind: Plain, ci: False, inner: Ast.skip_name(toks, i + 4) }
            } else {
                # (?flags: ... ) or (?: ... )
                f = Ast.read_flags(toks, i + 2, { ci: False })
                { kind: Plain, ci: f.ci, inner: f.i + 1 }
            }
        } else {
            { kind: Plain, ci: False, inner: i + 1 }
        }

    skip_name : List(Ast.Tok), U64 -> U64
    skip_name = |toks, i|
        match Ast.cp_at(toks, i) {
            Ok('>') => i + 1
            Err(_) => i
            Ok(_) => Ast.skip_name(toks, i + 1)
        }

    read_flags : List(Ast.Tok), U64, { ci : Bool } -> { ci : Bool, i : U64 }
    read_flags = |toks, i, acc|
        match Ast.cp_at(toks, i) {
            Ok('i') => Ast.read_flags(toks, i + 1, { ci: True })
            Ok(':') => { ci: acc.ci, i }
            Ok(')') => { ci: acc.ci, i }
            Err(_) => { ci: acc.ci, i }
            _ => Ast.read_flags(toks, i + 1, acc)
        }

    parse_escape : Str, List(Ast.Tok), U64 -> Try(Ast.Out, Err.Error)
    parse_escape = |src, toks, i| {
        c = Ast.cp_at(toks, i)
        cls = |neg, rs| Ok({ ast: Chars({ neg, ranges: rs }), i: i + 1 })
        lit = |cp| Ok({ ast: Chars({ neg: False, ranges: [{ lo: cp, hi: cp }] }), i: i + 1 })
        match c {
            Err(_) => Err(Ast.err_at(src, toks, i, EscapeUnexpectedEof))
            Ok('d') => cls(False, Ast.ranges_d)
            Ok('D') => cls(True, Ast.ranges_d)
            Ok('w') => cls(False, Ast.ranges_w)
            Ok('W') => cls(True, Ast.ranges_w)
            Ok('s') => cls(False, Ast.ranges_s)
            Ok('S') => cls(True, Ast.ranges_s)
            Ok('b') => Ok({ ast: Look(Ast.look_wordb), i: i + 1 })
            Ok('B') => Ok({ ast: Look(Ast.look_nwordb), i: i + 1 })
            Ok('A') => Ok({ ast: Look(Ast.look_big_a), i: i + 1 })
            Ok('z') => Ok({ ast: Look(Ast.look_z), i: i + 1 })
            Ok('p') => Ast.parse_prop(src, toks, i + 1, False)
            Ok('P') => Ast.parse_prop(src, toks, i + 1, True)
            Ok('u') =>
                match Ast.parse_u(src, toks, i + 1) {
                    Ok(r) => Ok({ ast: Chars({ neg: False, ranges: [{ lo: r.cp, hi: r.cp }] }), i: r.i })
                    Err(e) => Err(e)
                }
            Ok('x') =>
                match Ast.read_hex(toks, i + 1, 2) {
                    Ok(r) => Ok({ ast: Chars({ neg: False, ranges: [{ lo: r.cp, hi: r.cp }] }), i: r.i })
                    Err(_) => Err(Ast.err_at(src, toks, i, EscapeUnrecognized))
                }
            Ok('n') => lit(10)
            Ok('t') => lit(9)
            Ok('r') => lit(13)
            Ok('f') => lit(12)
            Ok('v') => lit(11)
            Ok('e') => lit(27)
            Ok('a') => lit(7)
            Ok('0') => lit(0)
            Ok(v) if (v >= 'A' and v <= 'Z') or (v >= 'a' and v <= 'z') => Err(Ast.err_at(src, toks, i, EscapeUnrecognized))
            Ok(v) => lit(v)
        }
    }

    # \u{HEX} or \uHHHH; `i` is just past the `u`
    parse_u : Str, List(Ast.Tok), U64 -> Try({ cp : U32, i : U64 }, Err.Error)
    parse_u = |src, toks, i|
        if Ast.cp_at(toks, i) == Ok('{') {
            match Ast.find_brace(toks, i + 1) {
                Err(_) => Err(Ast.err_at(src, toks, i, EscapeUnrecognized))
                Ok(j) =>
                    match Ast.read_hex(toks, i + 1, j - (i + 1)) {
                        Ok(r) => Ok({ cp: r.cp, i: j + 1 })
                        Err(_) => Err(Ast.err_at(src, toks, i, EscapeUnrecognized))
                    }
            }
        } else {
            match Ast.read_hex(toks, i, 4) {
                Ok(r) => Ok(r)
                Err(_) => Err(Ast.err_at(src, toks, i, EscapeUnrecognized))
            }
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

    parse_prop : Str, List(Ast.Tok), U64, Bool -> Try(Ast.Out, Err.Error)
    parse_prop = |src, toks, i, neg|
        if Ast.cp_at(toks, i) == Ok('{') {
            match Ast.find_brace(toks, i + 1) {
                Err(_) => Err(Ast.err_at(src, toks, i, ClassUnclosed))
                Ok(j) => {
                    name = Ast.slice_str(toks, i + 1, j)
                    match Uni.lookup(name) {
                        Ok(hex) => Ok({ ast: Chars({ neg, ranges: Uni.ranges(hex) }), i: j + 1 })
                        Err(_) => Err(Ast.err_at(src, toks, i, EscapeUnrecognized))
                    }
                }
            }
        } else {
            Err(Ast.err_at(src, toks, i, EscapeUnrecognized))
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
        |> Ast.cps_to_str

    cps_to_str : List(U32) -> Str
    cps_to_str = |cps|
        List.fold(cps, [], |acc, cp| List.concat(acc, Ast.enc_cp(cp)))
        |> Str.from_utf8_lossy

    enc_cp : U32 -> List(U8)
    enc_cp = |cp|
        if cp < 0x80 {
            [cp.to_u8_wrap()]
        } else if cp < 0x800 {
            [(0xC0 + cp.shr_zf_wrap(6)).to_u8_wrap(), (0x80 + cp.bitwise_and(0x3F)).to_u8_wrap()]
        } else if cp < 0x10000 {
            [(0xE0 + cp.shr_zf_wrap(12)).to_u8_wrap(), (0x80 + cp.shr_zf_wrap(6).bitwise_and(0x3F)).to_u8_wrap(), (0x80 + cp.bitwise_and(0x3F)).to_u8_wrap()]
        } else {
            [(0xF0 + cp.shr_zf_wrap(18)).to_u8_wrap(), (0x80 + cp.shr_zf_wrap(12).bitwise_and(0x3F)).to_u8_wrap(), (0x80 + cp.shr_zf_wrap(6).bitwise_and(0x3F)).to_u8_wrap(), (0x80 + cp.bitwise_and(0x3F)).to_u8_wrap()]
        }

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

    fold_ranges : List(Ast.Rng) -> List(Ast.Rng)
    fold_ranges = |ranges|
        List.fold(ranges, ranges, |acc, r|
            if r.hi - r.lo < 1024 {
                List.concat(acc, Ast.fold_range_members(r.lo, r.hi, []))
            } else {
                acc
            })

    fold_range_members : U32, U32, List(Ast.Rng) -> List(Ast.Rng)
    fold_range_members = |cp, hi, acc|
        if cp > hi {
            acc
        } else {
            partners = Uni.fold_of(cp) |> List.map(|fp| { lo: fp, hi: fp })
            Ast.fold_range_members(cp + 1, hi, List.concat(acc, partners))
        }

    parse_class : Str, List(Ast.Tok), U64 -> Try(Ast.Out, Err.Error)
    parse_class = |src, toks, i0| {
        neg = Ast.cp_at(toks, i0) == Ok('^')
        i = if neg { i0 + 1 } else { i0 }
        Ast.class_items(src, toks, i, neg, [])
    }

    class_items : Str, List(Ast.Tok), U64, Bool, List(Ast.Rng) -> Try(Ast.Out, Err.Error)
    class_items = |src, toks, i, neg, acc|
        match Ast.cp_at(toks, i) {
            Err(_) => Err(Ast.err_at(src, toks, i, ClassUnclosed))
            Ok(']') if !List.is_empty(acc) => Ok({ ast: Chars({ neg, ranges: acc }), i: i + 1 })
            Ok('\\') =>
                match Ast.class_escape(src, toks, i + 1) {
                    Ok(step) => Ast.class_maybe_range(src, toks, step.i, neg, acc, step.ranges)
                    Err(e) => Err(e)
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
                Ok('\\') =>
                    match Ast.class_escape(src, toks, i + 2) {
                        Ok(step) =>
                            match step.ranges {
                                [r] if r.lo == r.hi and r.lo >= lo => Ast.class_items(src, toks, step.i, neg, List.append(acc, { lo, hi: r.lo }))
                                _ => Err(Ast.err_at(src, toks, i + 1, ClassRangeInvalid))
                            }
                        Err(e) => Err(e)
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
            Ok('d') => Ok({ ranges: Ast.ranges_d, i: i + 1 })
            Ok('D') => Ok({ ranges: Ast.complement(Ast.ranges_d), i: i + 1 })
            Ok('w') => Ok({ ranges: Ast.ranges_w, i: i + 1 })
            Ok('W') => Ok({ ranges: Ast.complement(Ast.ranges_w), i: i + 1 })
            Ok('s') => Ok({ ranges: Ast.ranges_s, i: i + 1 })
            Ok('S') => Ok({ ranges: Ast.complement(Ast.ranges_s), i: i + 1 })
            Ok('p') => Ast.class_prop(src, toks, i + 1, False)
            Ok('P') => Ast.class_prop(src, toks, i + 1, True)
            Ok('u') =>
                match Ast.parse_u(src, toks, i + 1) {
                    Ok(r) => Ok({ ranges: [{ lo: r.cp, hi: r.cp }], i: r.i })
                    Err(e) => Err(e)
                }
            Ok('x') =>
                match Ast.read_hex(toks, i + 1, 2) {
                    Ok(r) => Ok({ ranges: [{ lo: r.cp, hi: r.cp }], i: r.i })
                    Err(_) => Err(Ast.err_at(src, toks, i, EscapeUnrecognized))
                }
            Ok('n') => one(10)
            Ok('t') => one(9)
            Ok('r') => one(13)
            Ok('f') => one(12)
            Ok('v') => one(11)
            Ok('0') => one(0)
            Ok(v) => one(v)
        }
    }

    class_prop : Str, List(Ast.Tok), U64, Bool -> Try({ ranges : List(Ast.Rng), i : U64 }, Err.Error)
    class_prop = |src, toks, i, neg|
        if Ast.cp_at(toks, i) == Ok('{') {
            match Ast.find_brace(toks, i + 1) {
                Err(_) => Err(Ast.err_at(src, toks, i, ClassUnclosed))
                Ok(j) =>
                    match Uni.lookup(Ast.slice_str(toks, i + 1, j)) {
                        Ok(hex) => {
                            rs = Uni.ranges(hex)
                            Ok({ ranges: if neg { Ast.complement(rs) } else { rs }, i: j + 1 })
                        }
                        Err(_) => Err(Ast.err_at(src, toks, i, EscapeUnrecognized))
                    }
            }
        } else {
            Err(Ast.err_at(src, toks, i, EscapeUnrecognized))
        }

    ## complement of a set of ranges over [0, 0x10FFFF]
    complement : List(Ast.Rng) -> List(Ast.Rng)
    complement = |ranges| {
        sorted = List.sort_with(ranges, |a, b| U32.order_relative_to(a.lo, b.lo))
        r = List.fold(sorted, { out: [], next: 0 }, |st, rg|
            if rg.lo > st.next {
                { out: List.append(st.out, { lo: st.next, hi: rg.lo - 1 }), next: rg.hi + 1 }
            } else if rg.hi + 1 > st.next {
                { out: st.out, next: rg.hi + 1 }
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
                        Cat(zs) => List.concat(acc, zs)
                        Empty => acc
                        y => List.append(acc, y)
                    })
                if List.is_empty(ys) { Empty } else if List.len(ys) == 1 { List.get(ys, 0) ?? Empty } else { Cat(ys) }
            }
            Alt(xs) => {
                ys = List.fold(xs, [], |acc, x|
                    match Ast.simplify(x) {
                        Alt(zs) => List.concat(acc, zs)
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
                        And(zs) => List.concat(acc, zs)
                        y => List.append(acc, y)
                    })
                if List.len(ys) == 1 { List.get(ys, 0) ?? Empty } else { And(ys) }
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
