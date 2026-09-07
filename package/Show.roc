## Pretty-printer for nodes (RE#'s `Helpers.printNode`), for tests and debugging.
## Prints RE#'s notation: `_` for the full set, `⊥` for the empty set, `.` for
## `[^\n]`, `ε`, `~(...)`, `(?=...)`, `(?<=...)`, `\A`, `\z`, and `^`/`$` for
## the line-anchor lookarounds.
import Arena
import Trie
import TSet
import Utf8

Show := [].{
    show : Arena.A, Trie.T, U32 -> Str
    show = |a, t, id| {
        k = Arena.kind(a, id)
        if id == Arena.eps {
            "ε"
        } else if k == Arena.k_singleton {
            Show.tset(a, t, Arena.tset(a, id))
        } else if k == Arena.k_or {
            "(" |> Str.concat(Str.join_with(List.map(Arena.children(a, id), |c| Show.show(a, t, c)), "|")) |> Str.concat(")")
        } else if k == Arena.k_and {
            "(" |> Str.concat(Str.join_with(List.map(Arena.children(a, id), |c| Show.show(a, t, c)), "&")) |> Str.concat(")")
        } else if k == Arena.k_not {
            "~(${Show.show(a, t, Arena.head(a, id))})"
        } else if k == Arena.k_loop {
            body = Arena.head(a, id)
            lo = Arena.loop_lo(a, id)
            hi = Arena.loop_hi(a, id)
            inner0 = Show.show(a, t, body)
            inner = if Arena.is_singleton(a, body) { inner0 } else { "(${inner0})" }
            count =
                if lo == 0 and hi == Arena.inf { "*" }
                else if lo == 1 and hi == Arena.inf { "+" }
                else if lo == 0 and hi == 1 { "?" }
                else if lo == hi { "{${lo.to_str()}}" }
                else if hi == Arena.inf { "{${lo.to_str()},}" }
                else { "{${lo.to_str()},${hi.to_str()}}" }
            if lo == 2 and hi == 2 and Str.count_utf8_bytes(inner) == 1 { Str.concat(inner, inner) } else { Str.concat(inner, count) }
        } else if k == Arena.k_lookahead {
            inner = Show.strip_star(Show.show(a, t, Arena.head(a, id)))
            pend = if Arena.look_pend(a, id) == Arena.rs_empty { "" } else { "{...}" }
            r = "(?=${inner})${pend}"
            if r == "(?=(\\n|\\Z))" or r == "(?=(\\Z|\\n))" { "$" } else { r }
        } else if k == Arena.k_lookbehind {
            inner = Show.strip_star(Show.show(a, t, Arena.head(a, id)))
            pend = if Arena.look_pend(a, id) == Arena.rs_empty { "" } else { "{...}" }
            r = "(?<=${inner})${pend}"
            if r == "(?<=(\\n|\\A))" or r == "(?<=(\\A|\\n))" { "^" } else { r }
        } else if k == Arena.k_concat {
            Str.concat(Show.show(a, t, Arena.head(a, id)), Show.show(a, t, Arena.tail(a, id)))
        } else if k == Arena.k_end {
            "\\Z"
        } else {
            "\\A"
        }
    }

    # RE# drops a leading/trailing `_*` when printing a lookaround body
    strip_star : Str -> Str
    strip_star = |s|
        if Str.ends_with(s, "_*") and Str.count_utf8_bytes(s) > 2 { Str.drop_suffix(s, "_*") }
        else if Str.starts_with(s, "_*") and Str.count_utf8_bytes(s) > 2 { Str.drop_prefix(s, "_*") }
        else { s }

    ## a tset as a character class
    tset : Arena.A, Trie.T, U64 -> Str
    tset = |a, t, s|
        if TSet.is_full(s, a.nmt) {
            "_"
        } else if TSet.is_empty(s) {
            "⊥"
        } else {
            ranges = Show.ranges(t, s)
            neg_ranges = Show.ranges(t, TSet.compl(s, a.nmt).bitwise_and(TSet.compl(TSet.bit(t.invalid), a.nmt)))
            if s == TSet.bit(t.invalid) {
                # D8's Invalid symbol (no RE# notation exists; `\i` is ours)
                "\\i"
            } else if List.is_empty(neg_ranges) and !TSet.contains(s, t.invalid) {
                # every codepoint but not Invalid: RE# would say `_`
                "[\\s\\S]"
            } else if neg_ranges == [{ lo: 10, hi: 10 }] and !TSet.contains(s, t.invalid) {
                "."
            } else {
                match ranges {
                    [r] if r.lo == r.hi => Show.cp(r.lo)
                    _ =>
                        if List.len(neg_ranges) < List.len(ranges) and !TSet.contains(s, t.invalid) {
                            "[^${Show.class_body(neg_ranges)}]"
                        } else {
                            "[${Show.class_body(ranges)}]"
                        }
                }
            }
        }

    # merged codepoint ranges of every minterm in `s`
    ranges : Trie.T, U64 -> List({ lo : U32, hi : U32 })
    ranges = |t, s| {
        n = t.n_classes
        all = List.fold(Trie.upto(n.to_u64()), [], |acc, m|
            if TSet.contains(s, m.to_u32_wrap()) and m.to_u32_wrap() != t.invalid { List.concat(acc, Trie.ranges_of(t, m.to_u32_wrap())) } else { acc })
        sorted = List.sort_with(all, |x, y| U32.order_relative_to(x.lo, y.lo))
        List.fold(sorted, [], |acc, r|
            match List.last(acc) {
                Ok(q) if q.hi + 1 >= r.lo => List.append(List.drop_last(acc, 1), { lo: q.lo, hi: if r.hi > q.hi { r.hi } else { q.hi } })
                _ => List.append(acc, r)
            })
    }

    class_body : List({ lo : U32, hi : U32 }) -> Str
    class_body = |rs|
        List.map(rs, |r| if r.lo == r.hi { Show.cp(r.lo) } else if r.hi == r.lo + 1 { Str.concat(Show.cp(r.lo), Show.cp(r.hi)) } else if r.hi == 0x10_FFFF and r.lo == 0 { "_" } else { "${Show.cp(r.lo)}-${Show.cp(r.hi)}" })
        |> Str.join_with("")

    cp : U32 -> Str
    cp = |c|
        if c == 10 { "\\n" }
        else if c == 9 { "\\t" }
        else if c == 13 { "\\r" }
        else if c == 32 { " " }
        else if c < 32 or c == 127 { "\\x${Show.hex2(c)}" }
        else if List.contains(['(', ')', '&', '~', '.', '|', '^', '$', '[', ']', '\\', '*', '+', '?', '{', '}', '_'], c) { "\\${Utf8.cps_to_str([c])}" }
        else if c == 0x10_FFFF { "\\u{10FFFF}" }
        else { Utf8.cps_to_str([c]) }

    hex2 : U32 -> Str
    hex2 = |c| {
        d = |x| Utf8.cps_to_str([if x < 10 { 48 + x } else { 55 + x }])
        Str.concat(d(c.shr_zf_wrap(4).bitwise_and(15)), d(c.bitwise_and(15)))
    }
}
