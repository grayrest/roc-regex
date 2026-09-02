## The public surface. `Regex` is a transparent record with documented-unstable
## fields — Roc has no field privacy and the nominal type that would give it
## segfaults the compiler (Owed upstream 2). Do not depend on the field layout.
##
## `compile` returns `Try`, so a literal pattern with a caller-side `unwrap`
## fails the BUILD with the rendered message (D7); a runtime pattern returns an
## ordinary `Err`. One function, one code path (D1).
import Comp
import Pike
import Trie
import Dfa
import Lit
import Err

Regex := [].{
    ## The compiled pattern. Fields are unstable (see above). M1's engine is
    ## always the PikeVM; the `Dfa` arm and its tables are M3.
    ## The `engine` field records M3's outcome (D10): `Dfa` for a look-free
    ## pattern whose table fit the budget, else `Pike`. Documented-unstable.
    T : { prog : List(U32), splits : List(U32), classes : Trie.T, n_groups : U32, prefix : List(U8), engine : [Pike, Dfa(Dfa.T)] }

    ## A match, as half-open BYTE offsets into the haystack (D3, D15).
    Span : { start : U64, end : U64 }

    compile : Str -> Try(Regex.T, Err.Error)
    compile = |src|
        match Comp.compile(src) {
            Err(e) => Err(e)
            Ok(c) => {
                # budget: max_artifact_bytes / (n_classes * 4); provisional 256 KB
                nc = if c.classes.n_classes == 0 { 1 } else { c.classes.n_classes }
                max_states = 262144 // (nc.to_u64() * 4)
                engine =
                    match Dfa.build(c, max_states) {
                        Ok(d) => Dfa(d)
                        Err(_) => Pike
                    }
                Ok({ prog: c.prog, splits: c.splits, classes: c.classes, n_groups: c.n_groups, prefix: c.prefix, engine })
            }
        }

    ## The documented literal-pattern idiom: fold, and crash-with-message on a
    ## bad literal so the build fails (D7).
    unwrap : Try(Regex.T, Err.Error) -> Regex.T
    unwrap = |r|
        match r {
            Ok(re) => re
            Err(e) => crash Err.render(e)
        }

    ## As `unwrap`, but the message names the pattern via a caller label — worth
    ## more than the caret when several regexes report at the same file position.
    unwrap_labeled : Str, Try(Regex.T, Err.Error) -> Regex.T
    unwrap_labeled = |label, r|
        match r {
            Ok(re) => re
            Err(e) => crash "[${label}] ${Err.render(e)}"
        }

    ## Leftmost-first search over a byte haystack. When a required-literal prefix
    ## was extracted (M4, D6), scan for it and run the engine anchored at each
    ## candidate; otherwise the PikeVM's own unanchored search.
    find : Regex.T, List(U8) -> Try(Regex.Span, [NoMatch])
    find = |re, hay|
        if List.is_empty(re.prefix) {
            Pike.find(Regex.base(re), hay)
        } else {
            Regex.find_pf(Regex.base(re), hay, re.prefix, 0)
        }

    find_pf : Comp.Compiled, List(U8), List(U8), U64 -> Try(Regex.Span, [NoMatch])
    find_pf = |c, hay, prefix, at|
        match Lit.find_candidate(hay, at, prefix) {
            Err(_) => Err(NoMatch)
            Ok(cand) =>
                match Pike.match_at(c, hay, cand) {
                    Ok(slots) => Ok({ start: List.get(slots, 0) ?? 0, end: List.get(slots, 1) ?? 0 })
                    Err(_) => Regex.find_pf(c, hay, prefix, cand + 1)
                }
        }

    ## All capture spans: index 0 is the whole match, i is group i. An
    ## unset/non-participating group is `Err(NoGroup)`.
    captures : Regex.T, List(U8) -> Try(List(Try(Regex.Span, [NoGroup])), [NoMatch])
    captures = |re, hay|
        match Pike.captures(Regex.base(re), hay) {
            Err(_) => Err(NoMatch)
            Ok(slots) => Ok(Regex.pair_slots(slots, 0, []))
        }

    pair_slots : List(U64), U64, List(Try(Regex.Span, [NoGroup])) -> List(Try(Regex.Span, [NoGroup]))
    pair_slots = |slots, i, acc|
        if i + 1 >= List.len(slots) {
            acc
        } else {
            s = List.get(slots, i) ?? 0xFFFF_FFFF_FFFF_FFFF
            e = List.get(slots, i + 1) ?? 0xFFFF_FFFF_FFFF_FFFF
            span = if s == 0xFFFF_FFFF_FFFF_FFFF or e == 0xFFFF_FFFF_FFFF_FFFF { Err(NoGroup) } else { Ok({ start: s, end: e }) }
            Regex.pair_slots(slots, i + 2, List.append(acc, span))
        }

    ## Whether the pattern matches anywhere in the haystack.
    is_match : Regex.T, List(U8) -> Bool
    is_match = |re, hay|
        match re.engine {
            Dfa(d) => Dfa.is_match(d, re.classes, hay)
            Pike =>
                match Pike.find(Regex.base(re), hay) {
                    Ok(_) => True
                    Err(_) => False
                }
        }

    # the Comp.Compiled view (drop the engine field) for Pike, which is
    # engine-agnostic.
    base : Regex.T -> Comp.Compiled
    base = |re| { prog: re.prog, splits: re.splits, classes: re.classes, n_groups: re.n_groups, prefix: re.prefix }


    ## --- iteration and rewriting (D15, D14) ---------------------------------

    ## All non-overlapping matches as slot arrays, applying D14's empty-match
    ## advance: an empty match abutting the previous match end is skipped, and
    ## after any empty match the cursor steps one symbol so it cannot loop.
    all_caps : Regex.T, List(U8) -> List(List(U64))
    all_caps = |re, hay| Regex.all_loop(re, hay, 0, Regex.sentinel, [])

    sentinel : U64
    sentinel = 0xFFFF_FFFF_FFFF_FFFF

    all_loop : Regex.T, List(U8), U64, U64, List(List(U64)) -> List(List(U64))
    all_loop = |re, hay, at, last_end, acc|
        if at > List.len(hay) {
            acc
        } else {
            match Pike.captures_from(Regex.base(re), hay, at) {
                Err(_) => acc
                Ok(slots) => {
                    s = List.get(slots, 0) ?? 0
                    e = List.get(slots, 1) ?? 0
                    if s == e and e == last_end {
                        Regex.all_loop(re, hay, Regex.next_bound(hay, e), last_end, acc)
                    } else {
                        nat = if s == e { Regex.next_bound(hay, e) } else { e }
                        Regex.all_loop(re, hay, nat, e, List.append(acc, slots))
                    }
                }
            }
        }

    next_bound : List(U8), U64 -> U64
    next_bound = |hay, p|
        if p >= List.len(hay) { p + 1 } else { p + Comp.decode(hay, p).len }

    ## All whole-match spans.
    find_all : Regex.T, List(U8) -> List(Regex.Span)
    find_all = |re, hay|
        List.map(Regex.all_caps(re, hay), |sl| { start: List.get(sl, 0) ?? 0, end: List.get(sl, 1) ?? 0 })

    ## Replace every match. `rep` carries `$N` group refs (longest-digit-run) and
    ## `$$` -> `$`; an unknown ref expands to empty (D15). Byte API.
    replace_all : Regex.T, List(U8), List(U8) -> List(U8)
    replace_all = |re, hay, rep| {
        caps = Regex.all_caps(re, hay)
        r = List.fold(caps, { out: [], last: 0 }, |st, sl| {
            s = List.get(sl, 0) ?? 0
            e = List.get(sl, 1) ?? 0
            before = List.sublist(hay, { start: st.last, len: s - st.last })
            expanded = Regex.expand(rep, hay, sl)
            { out: List.concat(List.concat(st.out, before), expanded), last: e }
        })
        List.concat(r.out, List.sublist(hay, { start: r.last, len: List.len(hay) - r.last }))
    }

    expand : List(U8), List(U8), List(U64) -> List(U8)
    expand = |rep, hay, slots| Regex.expand_loop(rep, hay, slots, 0, [])

    expand_loop : List(U8), List(U8), List(U64), U64, List(U8) -> List(U8)
    expand_loop = |rep, hay, slots, i, out|
        match List.get(rep, i) {
            Err(_) => out
            Ok(0x24) => {
                nx = List.get(rep, i + 1) ?? 0
                if nx == 0x24 {
                    Regex.expand_loop(rep, hay, slots, i + 2, List.append(out, 0x24))
                } else if nx >= 48 and nx <= 57 {
                    d = Regex.read_num(rep, i + 1, 0)
                    grp = Regex.group_bytes(hay, slots, d.n)
                    Regex.expand_loop(rep, hay, slots, d.i, List.concat(out, grp))
                } else {
                    Regex.expand_loop(rep, hay, slots, i + 1, List.append(out, 0x24))
                }
            }
            Ok(b) => Regex.expand_loop(rep, hay, slots, i + 1, List.append(out, b))
        }

    read_num : List(U8), U64, U64 -> { n : U64, i : U64 }
    read_num = |rep, i, acc|
        match List.get(rep, i) {
            Ok(b) if b >= 48 and b <= 57 => Regex.read_num(rep, i + 1, acc * 10 + (b - 48).to_u64())
            _ => { n: acc, i }
        }

    group_bytes : List(U8), List(U64), U64 -> List(U8)
    group_bytes = |hay, slots, g| {
        s = List.get(slots, g * 2) ?? Regex.sentinel
        e = List.get(slots, g * 2 + 1) ?? Regex.sentinel
        if s == Regex.sentinel or e == Regex.sentinel { [] } else { List.sublist(hay, { start: s, len: e - s }) }
    }

    ## Split around matches, with leading/trailing empty fields and one more
    ## field than matches (D15).
    split : Regex.T, List(U8) -> List(List(U8))
    split = |re, hay| {
        caps = Regex.all_caps(re, hay)
        r = List.fold(caps, { fields: [], last: 0 }, |st, sl| {
            s = List.get(sl, 0) ?? 0
            e = List.get(sl, 1) ?? 0
            field = List.sublist(hay, { start: st.last, len: s - st.last })
            { fields: List.append(st.fields, field), last: e }
        })
        List.append(r.fields, List.sublist(hay, { start: r.last, len: List.len(hay) - r.last }))
    }

    replace_all_str : Regex.T, Str, Str -> Str
    replace_all_str = |re, hay, rep|
        Str.from_utf8(Regex.replace_all(re, Str.to_utf8(hay), Str.to_utf8(rep))) ?? ""

    split_str : Regex.T, Str -> List(Str)
    split_str = |re, hay|
        List.map(Regex.split(re, Str.to_utf8(hay)), |f| Str.from_utf8(f) ?? "")

    ## Convenience: search a `Str`. Copies to `List(U8)` (D3 — the byte API is
    ## the real one; this pays a copy in).
    find_str : Regex.T, Str -> Try(Regex.Span, [NoMatch])
    find_str = |re, s| Regex.find(re, Str.to_utf8(s))

    is_match_str : Regex.T, Str -> Bool
    is_match_str = |re, s| Regex.is_match(re, Str.to_utf8(s))
}
