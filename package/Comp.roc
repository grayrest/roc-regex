## Parser (M1 subset) + Thompson NFA compiler, over one module because a
## recursive nominal AST's variants are opaque across module boundaries.
##
## Exposes only plain data: `compile : Str -> Try(Comp.Prog, Err.Error)`. The AST
## never leaves this module. Emission is forward-only with precomputed subtree
## sizes (S3): no `List.set`, so the compiler folds without back-patching (D12).
import Err
import Trie

## The AST is the module's nominal type, so its `Cat(List(Comp))` recursion goes
## through the nominal (as roc-markdown's `Inl` does). Destructured only with
## `match`, never a lambda argument pattern (Owed upstream 2). {n,m} is desugared
## to Cat/Star/Quest before compilation, so the compiler sees only these.
Comp := [
    Empty,
    Chars({ neg : Bool, ranges : List(Comp.Rng) }),
    Cat(List(Comp)),
    Alt(List(Comp)),
    Star(Comp, Bool),
    Plus(Comp, Bool),
    Quest(Comp, Bool),
    Look(U32),
    Group(Comp, U32),
].{
    ## A regex class or literal, stored as codepoint ranges plus a negation flag.
    Rng : { lo : U32, hi : U32 }

    ## The compiled program (S3): a flat instruction list plus two side tables.
    ## `sets[op]` is `[neg, count, lo, hi, ...]`; `splits[op]` is `[t1, t2]`.
    Prog : {
        prog : List(U32),
        sets : List(U32),
        splits : List(U32),
        n_sets : U64,
    }

    ## The finished program: instructions, split targets, and the class trie.
    ## `sets` does not survive — it is compile scaffolding for the partition.
    Compiled : {
        prog : List(U32),
        splits : List(U32),
        classes : Trie.T,
        n_groups : U32,
    }

    # --- instruction encoding -------------------------------------------------

    op_char : U32
    op_char = 0
    op_split : U32
    op_split = 1
    op_jmp : U32
    op_jmp = 2
    op_match : U32
    op_match = 3
    op_look : U32
    op_look = 4
    op_save : U32
    op_save = 5

    look_start : U32
    look_start = 0
    look_end : U32
    look_end = 1
    look_wordb : U32
    look_wordb = 2
    look_nwordb : U32
    look_nwordb = 3

    inst : U32, U32 -> U32
    inst = |op, operand| op.shl_wrap(28).bitwise_or(operand)

    inst_op : U32 -> U32
    inst_op = |w| w.shr_zf_wrap(28)

    inst_arg : U32 -> U32
    inst_arg = |w| w.bitwise_and(0x0FFF_FFFF)

    # --- entry point ----------------------------------------------------------

    ## Parse then compile. A parse error is returned as `Err`; a caller-side
    ## `unwrap` on a literal pattern turns it into a build failure (D7).
    compile : Str -> Try(Comp.Compiled, Err.Error)
    compile = |src| {
        toks = Comp.lex(Str.to_utf8(src), 0, [])
        given = List.len(toks)
        if given > 1000 {
            Err(Err.whole(src, PatternTooLong({ limit: 1000, given })))
        } else {
            match Comp.parse_alt({ src, toks, i: 0 }) {
                Ok(st) =>
                    if st.i < List.len(toks) {
                        # a leftover `)` with no opener
                        Err(Comp.err_at(src, toks, st.i, GroupUnopened))
                    } else {
                        numbered = Comp.number(st.ast, 1)
                        n_groups = numbered.next - 1
                        # wrap in group 0: Save0 ; body ; Save1 ; Match
                        prog0 = { prog: [Comp.inst(Comp.op_save, 0)], sets: [], splits: [], n_sets: 0 }
                        p1 = Comp.emit(prog0, numbered.ast, 1)
                        p2 = Comp.push_inst(p1, Comp.inst(Comp.op_save, 1))
                        prog = List.append(p2.prog, Comp.inst(Comp.op_match, 0))
                        Ok({ prog, splits: p2.splits, classes: Trie.build(p2.sets), n_groups })
                    }
                Err(e) => Err(e)
            }
        }
    }

    # --- token stream ---------------------------------------------------------
    #
    # Decode the pattern to `{ cp, off }` once, so the parser works in codepoints
    # while error spans stay in bytes (D7).

    Tok : { cp : U32, off : U64 }

    lex : List(U8), U64, List(Comp.Tok) -> List(Comp.Tok)
    lex = |b, i, acc|
        if i >= List.len(b) {
            acc
        } else {
            d = Comp.decode(b, i)
            Comp.lex(b, i + d.len, List.append(acc, { cp: d.cp, off: i }))
        }

    ## Decode one UTF-8 codepoint at byte offset `i`. Malformed bytes decode as
    ## the byte value with length 1 (the M1 subset has no invalid-UTF-8 patterns
    ## to worry about; D8's `Invalid` class is M3).
    decode : List(U8), U64 -> { cp : U32, len : U64 }
    decode = |b, i| {
        b0 = Comp.at(b, i)
        if b0 < 0x80 {
            { cp: b0.to_u32(), len: 1 }
        } else if b0.bitwise_and(0xE0) == 0xC0 {
            hi = b0.bitwise_and(0x1F).to_u32().shl_wrap(6)
            { cp: hi.bitwise_or(Comp.cont(b, i + 1)), len: 2 }
        } else if b0.bitwise_and(0xF0) == 0xE0 {
            hi = b0.bitwise_and(0x0F).to_u32().shl_wrap(12)
            mid = Comp.cont(b, i + 1).shl_wrap(6)
            { cp: hi.bitwise_or(mid).bitwise_or(Comp.cont(b, i + 2)), len: 3 }
        } else {
            hi = b0.bitwise_and(0x07).to_u32().shl_wrap(18)
            m1 = Comp.cont(b, i + 1).shl_wrap(12)
            m2 = Comp.cont(b, i + 2).shl_wrap(6)
            { cp: hi.bitwise_or(m1).bitwise_or(m2).bitwise_or(Comp.cont(b, i + 3)), len: 4 }
        }
    }

    cont : List(U8), U64 -> U32
    cont = |b, i| Comp.at(b, i).bitwise_and(0x3F).to_u32()

    at : List(U8), U64 -> U8
    at = |b, i| List.get(b, i) ?? 0

    tok_at : List(Comp.Tok), U64 -> Try({ cp : U32, off : U64 }, [End])
    tok_at = |toks, i|
        match List.get(toks, i) {
            Ok(t) => Ok(t)
            Err(_) => Err(End)
        }

    err_at : Str, List(Comp.Tok), U64, Err.Kind -> Err.Error
    err_at = |src, toks, i, kind| {
        off =
            match List.get(toks, i) {
                Ok(t) => t.off
                Err(_) => Str.count_utf8_bytes(src)
            }
        Err.err(src, off, kind)
    }
    # --- character-class range sets (M1: \w \d \s are ASCII; Unicode is M2) ----

    ranges_d : List(Comp.Rng)
    ranges_d = [{ lo: 48, hi: 57 }]

    ranges_w : List(Comp.Rng)
    ranges_w = [{ lo: 48, hi: 57 }, { lo: 65, hi: 90 }, { lo: 95, hi: 95 }, { lo: 97, hi: 122 }]

    ranges_s : List(Comp.Rng)
    ranges_s = [{ lo: 9, hi: 13 }, { lo: 32, hi: 32 }]

    is_word_cp : U32 -> Bool
    is_word_cp = |c| (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or c == 95 or (c >= 97 and c <= 122)

    # --- parser: alt -> cat -> repeat -> atom (S: M1 subset) -------------------

    St : { src : Str, toks : List(Comp.Tok), i : U64 }
    Out : { ast : Comp, i : U64 }

    cp_at : List(Comp.Tok), U64 -> Try(U32, [End])
    cp_at = |toks, i|
        match List.get(toks, i) {
            Ok(t) => Ok(t.cp)
            Err(_) => Err(End)
        }

    parse_alt : Comp.St -> Try(Comp.Out, Err.Error)
    parse_alt = |st|
        match Comp.parse_cat(st) {
            Ok(first) => Comp.parse_alt_rest(st.src, st.toks, first.i, [first.ast])
            Err(e) => Err(e)
        }

    parse_alt_rest : Str, List(Comp.Tok), U64, List(Comp) -> Try(Comp.Out, Err.Error)
    parse_alt_rest = |src, toks, i, arms|
        if Comp.cp_at(toks, i) == Ok(0x7C) {
            match Comp.parse_cat({ src, toks, i: i + 1 }) {
                Ok(next) => Comp.parse_alt_rest(src, toks, next.i, List.append(arms, next.ast))
                Err(e) => Err(e)
            }
        } else if List.len(arms) == 1 {
            Ok({ ast: List.get(arms, 0) ?? Empty, i })
        } else {
            Ok({ ast: Alt(arms), i })
        }

    parse_cat : Comp.St -> Try(Comp.Out, Err.Error)
    parse_cat = |st| Comp.parse_cat_loop(st.src, st.toks, st.i, [])

    parse_cat_loop : Str, List(Comp.Tok), U64, List(Comp) -> Try(Comp.Out, Err.Error)
    parse_cat_loop = |src, toks, i, acc| {
        c = Comp.cp_at(toks, i)
        stop = c == Ok(0x7C) or c == Ok(0x29) or c == Err(End)
        if stop {
            if List.is_empty(acc) {
                Ok({ ast: Empty, i })
            } else if List.len(acc) == 1 {
                Ok({ ast: List.get(acc, 0) ?? Empty, i })
            } else {
                Ok({ ast: Cat(acc), i })
            }
        } else {
            match Comp.parse_repeat({ src, toks, i }) {
                Ok(out) => Comp.parse_cat_loop(src, toks, out.i, List.append(acc, out.ast))
                Err(e) => Err(e)
            }
        }
    }

    parse_repeat : Comp.St -> Try(Comp.Out, Err.Error)
    parse_repeat = |st|
        match Comp.parse_atom(st) {
            Ok(atom) => Comp.apply_postfix(st.src, st.toks, atom.i, atom.ast)
            Err(e) => Err(e)
        }

    apply_postfix : Str, List(Comp.Tok), U64, Comp -> Try(Comp.Out, Err.Error)
    apply_postfix = |src, toks, i, ast| {
        c = Comp.cp_at(toks, i)
        if c == Ok(0x2A) {
            g = Comp.greedy(toks, i + 1)
            Ok({ ast: Star(ast, g.greedy), i: g.i })
        } else if c == Ok(0x2B) {
            g = Comp.greedy(toks, i + 1)
            Ok({ ast: Plus(ast, g.greedy), i: g.i })
        } else if c == Ok(0x3F) {
            g = Comp.greedy(toks, i + 1)
            Ok({ ast: Quest(ast, g.greedy), i: g.i })
        } else if c == Ok(0x7B) {
            Comp.parse_brace(src, toks, i + 1, ast)
        } else {
            Ok({ ast, i })
        }
    }

    greedy : List(Comp.Tok), U64 -> { greedy : Bool, i : U64 }
    greedy = |toks, i|
        if Comp.cp_at(toks, i) == Ok(0x3F) {
            { greedy: False, i: i + 1 }
        } else {
            { greedy: True, i }
        }

    parse_brace : Str, List(Comp.Tok), U64, Comp -> Try(Comp.Out, Err.Error)
    parse_brace = |src, toks, i, ast| {
        lo = Comp.read_int(toks, i, 0, False)
        if !lo.any {
            Err(Comp.err_at(src, toks, i, RepetitionCountInvalid))
        } else {
            al = lo.i
            cc = Comp.cp_at(toks, al)
            if cc == Ok(0x7D) {
                g = Comp.greedy(toks, al + 1)
                Ok({ ast: Comp.repeat_exact(ast, lo.n, g.greedy), i: g.i })
            } else if cc == Ok(0x2C) {
                hi = Comp.read_int(toks, al + 1, 0, False)
                if Comp.cp_at(toks, hi.i) == Ok(0x7D) {
                    g = Comp.greedy(toks, hi.i + 1)
                    if hi.any {
                        Ok({ ast: Comp.repeat_range(ast, lo.n, hi.n, g.greedy), i: g.i })
                    } else {
                        Ok({ ast: Comp.repeat_atleast(ast, lo.n, g.greedy), i: g.i })
                    }
                } else {
                    Err(Comp.err_at(src, toks, hi.i, RepetitionCountUnclosed))
                }
            } else {
                Err(Comp.err_at(src, toks, al, RepetitionCountUnclosed))
            }
        }
    }

    read_int : List(Comp.Tok), U64, U32, Bool -> { n : U32, i : U64, any : Bool }
    read_int = |toks, i, acc, any|
        match Comp.cp_at(toks, i) {
            Ok(c) if c >= 48 and c <= 57 => Comp.read_int(toks, i + 1, acc * 10 + (c - 48), True)
            _ => { n: acc, i, any }
        }

    repeat_exact : Comp, U32, Bool -> Comp
    repeat_exact = |ast, n, _g|
        if n == 0 { Empty } else { Cat(List.repeat(ast, n.to_u64())) }

    repeat_atleast : Comp, U32, Bool -> Comp
    repeat_atleast = |ast, n, g|
        if n == 0 {
            Star(ast, g)
        } else {
            Cat(List.append(List.repeat(ast, (n - 1).to_u64()), Plus(ast, g)))
        }

    repeat_range : Comp, U32, U32, Bool -> Comp
    repeat_range = |ast, n, m, g|
        Cat(List.concat(List.repeat(ast, n.to_u64()), List.repeat(Quest(ast, g), (m - n).to_u64())))

    parse_atom : Comp.St -> Try(Comp.Out, Err.Error)
    parse_atom = |st| {
        c = Comp.cp_at(st.toks, st.i)
        if c == Err(End) {
            Ok({ ast: Empty, i: st.i })
        } else if c == Ok(0x28) {
            noncap = Comp.cp_at(st.toks, st.i + 1) == Ok(0x3F) and Comp.cp_at(st.toks, st.i + 2) == Ok(0x3A)
            inner_i = if noncap { st.i + 3 } else { st.i + 1 }
            match Comp.parse_alt({ src: st.src, toks: st.toks, i: inner_i }) {
                Ok(inner) =>
                    if Comp.cp_at(st.toks, inner.i) == Ok(0x29) {
                        node = if noncap { inner.ast } else { Group(inner.ast, 0) }
                        Ok({ ast: node, i: inner.i + 1 })
                    } else {
                        Err(Comp.err_at(st.src, st.toks, st.i, GroupUnclosed))
                    }
                Err(e) => Err(e)
            }
        } else if c == Ok(0x5B) {
            Comp.parse_class(st.src, st.toks, st.i + 1)
        } else if c == Ok(0x2E) {
            Ok({ ast: Chars({ neg: True, ranges: [{ lo: 10, hi: 10 }] }), i: st.i + 1 })
        } else if c == Ok(0x5E) {
            Ok({ ast: Look(Comp.look_start), i: st.i + 1 })
        } else if c == Ok(0x24) {
            Ok({ ast: Look(Comp.look_end), i: st.i + 1 })
        } else if c == Ok(0x5C) {
            Comp.parse_escape(st.src, st.toks, st.i + 1)
        } else if c == Ok(0x2A) or c == Ok(0x2B) or c == Ok(0x3F) {
            Err(Comp.err_at(st.src, st.toks, st.i, RepetitionMissing))
        } else {
            cp = match c { Ok(v) => v, Err(_) => 0 }
            Ok({ ast: Chars({ neg: False, ranges: [{ lo: cp, hi: cp }] }), i: st.i + 1 })
        }
    }

    parse_escape : Str, List(Comp.Tok), U64 -> Try(Comp.Out, Err.Error)
    parse_escape = |src, toks, i| {
        c = Comp.cp_at(toks, i)
        cls = |neg, rs| Ok({ ast: Chars({ neg, ranges: rs }), i: i + 1 })
        lit = |cp| Ok({ ast: Chars({ neg: False, ranges: [{ lo: cp, hi: cp }] }), i: i + 1 })
        match c {
            Err(_) => Err(Comp.err_at(src, toks, i, EscapeUnexpectedEof))
            Ok(0x64) => cls(False, Comp.ranges_d)
            Ok(0x44) => cls(True, Comp.ranges_d)
            Ok(0x77) => cls(False, Comp.ranges_w)
            Ok(0x57) => cls(True, Comp.ranges_w)
            Ok(0x73) => cls(False, Comp.ranges_s)
            Ok(0x53) => cls(True, Comp.ranges_s)
            Ok(0x62) => Ok({ ast: Look(Comp.look_wordb), i: i + 1 })
            Ok(0x42) => Ok({ ast: Look(Comp.look_nwordb), i: i + 1 })
            Ok(0x6E) => lit(10)
            Ok(0x74) => lit(9)
            Ok(0x72) => lit(13)
            Ok(0x66) => lit(12)
            Ok(0x76) => lit(11)
            Ok(0x30) => lit(0)
            Ok(v) if (v >= 0x41 and v <= 0x5A) or (v >= 0x61 and v <= 0x7A) => Err(Comp.err_at(src, toks, i, EscapeUnrecognized))
            Ok(v) => lit(v)
        }
    }

    parse_class : Str, List(Comp.Tok), U64 -> Try(Comp.Out, Err.Error)
    parse_class = |src, toks, i0| {
        neg = Comp.cp_at(toks, i0) == Ok(0x5E)
        i = if neg { i0 + 1 } else { i0 }
        Comp.class_items(src, toks, i, neg, [])
    }

    class_items : Str, List(Comp.Tok), U64, Bool, List(Comp.Rng) -> Try(Comp.Out, Err.Error)
    class_items = |src, toks, i, neg, acc|
        match Comp.cp_at(toks, i) {
            Err(_) => Err(Comp.err_at(src, toks, i, ClassUnclosed))
            Ok(0x5D) if !List.is_empty(acc) => Ok({ ast: Chars({ neg, ranges: acc }), i: i + 1 })
            Ok(0x5C) =>
                match Comp.class_escape(src, toks, i + 1) {
                    Ok(step) => Comp.class_maybe_range(src, toks, step.i, neg, acc, step.ranges)
                    Err(e) => Err(e)
                }
            Ok(v) => Comp.class_maybe_range(src, toks, i + 1, neg, acc, [{ lo: v, hi: v }])
        }

    class_maybe_range : Str, List(Comp.Tok), U64, Bool, List(Comp.Rng), List(Comp.Rng) -> Try(Comp.Out, Err.Error)
    class_maybe_range = |src, toks, i, neg, acc, item| {
        single = List.len(item) == 1
        dash = Comp.cp_at(toks, i) == Ok(0x2D)
        next_close = Comp.cp_at(toks, i + 1) == Ok(0x5D)
        if single and dash and !next_close {
            lo = (List.get(item, 0) ?? { lo: 0, hi: 0 }).lo
            match Comp.cp_at(toks, i + 1) {
                Ok(hi) if hi != 0x5C =>
                    if hi < lo {
                        Err(Comp.err_at(src, toks, i + 1, ClassRangeInvalid))
                    } else {
                        Comp.class_items(src, toks, i + 2, neg, List.append(acc, { lo, hi }))
                    }
                _ => Err(Comp.err_at(src, toks, i + 1, ClassRangeInvalid))
            }
        } else {
            Comp.class_items(src, toks, i, neg, List.concat(acc, item))
        }
    }

    class_escape : Str, List(Comp.Tok), U64 -> Try({ ranges : List(Comp.Rng), i : U64 }, Err.Error)
    class_escape = |src, toks, i| {
        one = |cp| Ok({ ranges: [{ lo: cp, hi: cp }], i: i + 1 })
        match Comp.cp_at(toks, i) {
            Err(_) => Err(Comp.err_at(src, toks, i, EscapeUnexpectedEof))
            Ok(0x64) => Ok({ ranges: Comp.ranges_d, i: i + 1 })
            Ok(0x77) => Ok({ ranges: Comp.ranges_w, i: i + 1 })
            Ok(0x73) => Ok({ ranges: Comp.ranges_s, i: i + 1 })
            Ok(0x6E) => one(10)
            Ok(0x74) => one(9)
            Ok(0x72) => one(13)
            Ok(v) => one(v)
        }
    }


    # assign source-order group indices (pre-order); returns numbered ast + count
    NumSt : { ast : Comp, next : U32 }

    number : Comp, U32 -> Comp.NumSt
    number = |ast, g|
        match ast {
            Empty => { ast: Empty, next: g }
            Chars(_) => { ast, next: g }
            Look(_) => { ast, next: g }
            Star(x, gr) => {
                s = Comp.number(x, g)
                { ast: Star(s.ast, gr), next: s.next }
            }
            Plus(x, gr) => {
                s = Comp.number(x, g)
                { ast: Plus(s.ast, gr), next: s.next }
            }
            Quest(x, gr) => {
                s = Comp.number(x, g)
                { ast: Quest(s.ast, gr), next: s.next }
            }
            Group(x, _) => {
                s = Comp.number(x, g + 1)
                { ast: Group(s.ast, g), next: s.next }
            }
            Cat(xs) => {
                r = Comp.number_list(xs, g)
                { ast: Cat(r.list), next: r.next }
            }
            Alt(xs) => {
                r = Comp.number_list(xs, g)
                { ast: Alt(r.list), next: r.next }
            }
        }

    number_list : List(Comp), U32 -> { list : List(Comp), next : U32 }
    number_list = |xs, g|
        List.fold(xs, { list: [], next: g }, |acc, x| {
            s = Comp.number(x, acc.next)
            { list: List.append(acc.list, s.ast), next: s.next }
        })

    # --- NFA compiler (S3): forward-only, sizes precomputed --------------------

    nullable : Comp -> Bool
    nullable = |ast|
        match ast {
            Empty => True
            Chars(_) => False
            Look(_) => True
            Cat(xs) => List.all(xs, Comp.nullable)
            Alt(xs) => List.any(xs, Comp.nullable)
            Star(_, _) => True
            Plus(x, _) => Comp.nullable(x)
            Quest(_, _) => True
            Group(x, _) => Comp.nullable(x)
        }

    size : Comp -> U64
    size = |ast|
        match ast {
            Empty => 0
            Chars(_) => 1
            Look(_) => 1
            Cat(xs) => List.fold(xs, 0, |a, x| a + Comp.size(x))
            Alt(xs) => List.fold(xs, 0, |a, x| a + Comp.size(x)) + 2 * (List.len(xs) - 1)
            Star(x, _) => Comp.size(x) + 2
            Plus(x, _) => Comp.size(x) + 1
            Quest(x, _) => Comp.size(x) + 1
            Group(x, _) => Comp.size(x) + 2
        }

    push_set : Comp.Prog, Bool, List(Comp.Rng) -> { p : Comp.Prog, idx : U32 }
    push_set = |p, neg, ranges| {
        idx = p.n_sets.to_u32_wrap()
        negw = if neg { 1 } else { 0 }
        head = [negw, (List.len(ranges)).to_u32_wrap()]
        body = List.fold(ranges, head, |a, r| List.concat(a, [r.lo, r.hi]))
        { p: { ..p, sets: List.concat(p.sets, body), n_sets: p.n_sets + 1 }, idx }
    }

    push_split : Comp.Prog, U32, U32 -> { p : Comp.Prog, idx : U32 }
    push_split = |p, t1, t2| {
        idx = (List.len(p.splits)).to_u32_wrap()
        { p: { ..p, splits: List.concat(p.splits, [t1, t2]) }, idx }
    }

    push_inst : Comp.Prog, U32 -> Comp.Prog
    push_inst = |p, w| { ..p, prog: List.append(p.prog, w) }

    emit : Comp.Prog, Comp, U32 -> Comp.Prog
    emit = |p, ast, pc|
        match ast {
            Empty => p
            Chars(cs) => {
                s = Comp.push_set(p, cs.neg, cs.ranges)
                Comp.push_inst(s.p, Comp.inst(Comp.op_char, s.idx))
            }
            Look(k) => Comp.push_inst(p, Comp.inst(Comp.op_look, k))
            Cat(xs) => Comp.emit_cat(p, xs, pc)
            Alt(xs) => Comp.emit_alt(p, xs, pc, pc + (Comp.size(ast)).to_u32_wrap())
            Star(x, g) =>
                if Comp.nullable(x) {
                    Comp.emit(p, Quest(Plus(x, g), g), pc)
                } else {
                    sx = (Comp.size(x)).to_u32_wrap()
                    enter = pc + 1
                    after = pc + 1 + sx + 1
                    pair = if g { { a: enter, b: after } } else { { a: after, b: enter } }
                    s = Comp.push_split(p, pair.a, pair.b)
                    p1 = Comp.push_inst(s.p, Comp.inst(Comp.op_split, s.idx))
                    p2 = Comp.emit(p1, x, enter)
                    Comp.push_inst(p2, Comp.inst(Comp.op_jmp, pc))
                }
            Plus(x, g) => {
                sx = (Comp.size(x)).to_u32_wrap()
                back = pc
                after = pc + sx + 1
                pair = if g { { a: back, b: after } } else { { a: after, b: back } }
                p1 = Comp.emit(p, x, pc)
                s = Comp.push_split(p1, pair.a, pair.b)
                Comp.push_inst(s.p, Comp.inst(Comp.op_split, s.idx))
            }
            Quest(x, g) => {
                sx = (Comp.size(x)).to_u32_wrap()
                enter = pc + 1
                after = pc + 1 + sx
                pair = if g { { a: enter, b: after } } else { { a: after, b: enter } }
                s = Comp.push_split(p, pair.a, pair.b)
                p1 = Comp.push_inst(s.p, Comp.inst(Comp.op_split, s.idx))
                Comp.emit(p1, x, enter)
            }
            Group(x, gi) => {
                p1 = Comp.push_inst(p, Comp.inst(Comp.op_save, gi * 2))
                p2 = Comp.emit(p1, x, pc + 1)
                Comp.push_inst(p2, Comp.inst(Comp.op_save, gi * 2 + 1))
            }
        }

    emit_cat : Comp.Prog, List(Comp), U32 -> Comp.Prog
    emit_cat = |p, xs, pc|
        match List.first(xs) {
            Err(_) => p
            Ok(x) => {
                p1 = Comp.emit(p, x, pc)
                Comp.emit_cat(p1, List.drop_first(xs, 1), pc + (Comp.size(x)).to_u32_wrap())
            }
        }

    emit_alt : Comp.Prog, List(Comp), U32, U32 -> Comp.Prog
    emit_alt = |p, xs, pc, endpc|
        if List.len(xs) <= 1 {
            match List.first(xs) {
                Ok(x) => Comp.emit(p, x, pc)
                Err(_) => p
            }
        } else {
            x = List.first(xs) ?? Empty
            sx = (Comp.size(x)).to_u32_wrap()
            arm_x = pc + 1
            after_jmp = pc + 1 + sx + 1
            s = Comp.push_split(p, arm_x, after_jmp)
            p1 = Comp.push_inst(s.p, Comp.inst(Comp.op_split, s.idx))
            p2 = Comp.emit(p1, x, arm_x)
            p3 = Comp.push_inst(p2, Comp.inst(Comp.op_jmp, endpc))
            Comp.emit_alt(p3, List.drop_first(xs, 1), after_jmp, endpc)
        }

}
