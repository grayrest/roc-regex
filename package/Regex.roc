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
import Lit
import Rev
import Teddy
import Err

Regex := [].{
    ## The compiled pattern. Fields are unstable (see above). M1's engine is
    ## always the PikeVM; the `Dfa` arm and its tables are M3.
    ## The `engine` field records M3's outcome (D10): `Three` carries the D5
    ## forward+reverse DFAs for a look-free pattern within budget, else `Pike`.
    ## Documented-unstable.
    T : { prog : List(U32), splits : List(U32), classes : Trie.T, n_groups : U32, prefix : List(U8), rprog : List(U32), rsplits : List(U32), uprog : List(U32), usplits : List(U32), fbytes : List(U8), frange : [NoRange, Range(U8, U8)], exact : Bool, exact_alt : Bool, tlits : List(List(U8)), word_set : U64, engine : [Pike, Three({ fwd : Rev.D, rev : Rev.D, averify : [NoVerify, Verify(Rev.D)], inner : [NoInner, Inner({ lit : List(U8), lrev : Rev.D, full : Rev.D })] })] }

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
                    match Rev.build(c, max_states) {
                        Ok(d) => Three(d)
                        Err(_) => Pike
                    }
                Ok({ prog: c.prog, splits: c.splits, classes: c.classes, n_groups: c.n_groups, prefix: c.prefix, rprog: c.rprog, rsplits: c.rsplits, uprog: c.uprog, usplits: c.usplits, fbytes: c.fbytes, frange: c.frange, exact: c.exact, exact_alt: c.exact_alt, tlits: c.tlits, word_set: c.word_set, engine })
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
        if !List.is_empty(re.tlits) {
            # SIMD Teddy over the leading-literal set (M4, D6)
            match Teddy.build(re.tlits) {
                Ok(t) => Regex.find_teddy(Regex.base(re), hay, Teddy.candidates(t, hay), 0)
                Err(_) => Regex.find_engine(re, hay)
            }
        } else {
            Regex.find_engine(re, hay)
        }

    find_engine : Regex.T, List(U8) -> Try(Regex.Span, [NoMatch])
    find_engine = |re, hay|
        match re.engine {
            Three(d) => Rev.find(d, re.classes, hay)
            Pike =>
                if !List.is_empty(re.prefix) {
                    Regex.find_pf(Regex.base(re), hay, re.prefix, 0)
                } else if !List.is_empty(re.fbytes) {
                    Regex.find_fb(Regex.base(re), hay, re.fbytes, 0)
                } else {
                    Pike.wfind(Regex.base(re), hay)
                }
        }

    # run the engine anchored at each Teddy candidate, in order; first match wins
    # (leftmost-first, since every match starts with a leading literal)
    find_teddy : Comp.Compiled, List(U8), List(U64), U64 -> Try(Regex.Span, [NoMatch])
    find_teddy = |c, hay, cands, i|
        match List.get(cands, i) {
            Err(_) => Err(NoMatch)
            Ok(at) =>
                match Pike.wmatch_at(c, hay, at) {
                    Ok(span) => Ok(span)
                    Err(_) => Regex.find_teddy(c, hay, cands, i + 1)
                }
        }

    # first-byte-set prefilter (D6 second rung): scan for a byte in the set, run
    # the engine anchored there; every match starts with one of these bytes.
    find_fb : Comp.Compiled, List(U8), List(U8), U64 -> Try(Regex.Span, [NoMatch])
    find_fb = |c, hay, set, at|
        match Lit.find_in_set(hay, at, set) {
            Err(_) => Err(NoMatch)
            Ok(cand) =>
                match Pike.wmatch_at(c, hay, cand) {
                    Ok(span) => Ok(span)
                    Err(_) => Regex.find_fb(c, hay, set, cand + 1)
                }
        }

    find_pf : Comp.Compiled, List(U8), List(U8), U64 -> Try(Regex.Span, [NoMatch])
    find_pf = |c, hay, prefix, at|
        match Lit.find_candidate(hay, at, prefix) {
            Err(_) => Err(NoMatch)
            Ok(cand) =>
                match Pike.wmatch_at(c, hay, cand) {
                    Ok(span) => Ok(span)
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

    ## PikeVM find, bypassing the engine choice — for differential validation of
    ## the three-pass against the reference simulator.
    find_pike : Regex.T, List(U8) -> Try(Regex.Span, [NoMatch])
    find_pike = |re, hay| Pike.wfind(Regex.base(re), hay)

    ## Whether the pattern matches anywhere in the haystack.
    is_match : Regex.T, List(U8) -> Bool
    is_match = |re, hay|
        match re.engine {
            # an outermost `$` skips the forward end-scan (see Rev.find_from), so
            # is_match goes through the full span finder for that case; otherwise
            # the forward-only DFA suffices.
            Three(d) => if d.fwd.eoi_only { (match Rev.find(d, re.classes, hay) { Ok(_) => True Err(_) => False }) } else { Rev.is_match(d.fwd, re.classes, hay) }
            Pike =>
                match Regex.find(re, hay) {
                    Ok(_) => True
                    Err(_) => False
                }
        }

    # the Comp.Compiled view (drop the engine field) for Pike, which is
    # engine-agnostic.
    base : Regex.T -> Comp.Compiled
    # `anchored_start`/`accept_eoi_only` matter only to the DFA build (they are
    # baked into the engine there); the PikeVM view keeps the anchors in `prog`,
    # so they default to False here.
    base = |re| { prog: re.prog, splits: re.splits, classes: re.classes, n_groups: re.n_groups, prefix: re.prefix, rprog: re.rprog, rsplits: re.rsplits, uprog: re.uprog, usplits: re.usplits, fbytes: re.fbytes, frange: re.frange, exact: re.exact, inline_start: False, exact_alt: False, tlits: re.tlits, word_set: re.word_set, anchored_start: False, accept_eoi_only: False, inner: NoInner }


    ## --- iteration and rewriting (D15, D14) ---------------------------------

    ## All non-overlapping matches as slot arrays, applying D14's empty-match
    ## advance: an empty match abutting the previous match end is skipped, and
    ## after any empty match the cursor steps one symbol so it cannot loop.
    ## An explicit `while` loop rather than a recursive helper: it advances the
    ## cursor by one match (or one symbol after an empty match) until
    ## `captures_from` reports no more. A recursive form here would rely on the
    ## LLVM (`--opt=speed`) backend eliminating a tail call whose body inlines
    ## the whole matcher, which it does not — the stack then grows one frame per
    ## match and overflows (SIGBUS) after a few thousand matches. The loop keeps
    ## stack use O(1) regardless of match count.
    all_caps : Regex.T, List(U8) -> List(List(U64))
    all_caps = |re, hay| {
        comp = Regex.base(re)
        len = List.len(hay)
        var at = 0
        var last_end = Regex.sentinel
        var acc = []
        var running = True
        while running {
            if at > len {
                running = False
            } else {
                match Pike.captures_from(comp, hay, at) {
                    Err(_) => {
                        running = False
                    }
                    Ok(slots) => {
                        s = List.get(slots, 0) ?? 0
                        e = List.get(slots, 1) ?? 0
                        if s == e and e == last_end {
                            at = Regex.next_bound(hay, e)
                        } else {
                            acc = List.append(acc, slots)
                            last_end = e
                            at = if s == e { Regex.next_bound(hay, e) } else { e }
                        }
                    }
                }
            }
        }
        acc
    }

    sentinel : U64
    sentinel = 0xFFFF_FFFF_FFFF_FFFF

    next_bound : List(U8), U64 -> U64
    next_bound = |hay, p|
        if p >= List.len(hay) { p + 1 } else { p + Comp.decode(hay, p).len }

    ## All whole-match spans. Uses the start-only whole-match engine (no
    ## per-thread slot allocation), with the same D14 empty-match advance as
    ## `all_caps`. `all_caps` (full slots) is kept for `captures`/`replace`/`split`.
    # Adaptive-prefilter selectivity gate: use the literal prefilter only while
    # candidates stay below len/K, where K is the point at which per-candidate
    # verification (~a couple µs) overtakes a straight DFA byte-scan (~ns/byte).
    # Denser than that and the prefilter loses, so we fall back to the DFA.
    prefilter_k : U64
    prefilter_k = 512

    # The reverse-inner path (interior literal) gets a far looser gate: a missed
    # candidate costs only a short local reverse-DFA scan, not a full PikeVM
    # `wmatch_at`, so the prefilter stays a win at much higher literal density.
    # Measured crossover is past `e`-in-prose density (~1 per 10 bytes, ~5% loss);
    # len/4 keeps every realistic interior literal on the fast path and only bails
    # when the literal byte saturates the haystack.
    inner_prefilter_k : U64
    inner_prefilter_k = 4

    # Candidate scan for a required literal prefix. A multi-byte prefix uses a
    # Teddy fingerprint (m<=3 bytes) so candidates ~= actual literal occurrences
    # rather than every position of a common first byte — e.g. `\bthe\b` (prefix
    # "the") scans the "the" fingerprint (~2.4k) instead of every `t` (~18k). A
    # single-byte prefix, or an unsuitable Teddy, keeps the leaner first-byte
    # memchr.
    prefix_candidates : List(U8), List(U8), U64 -> Try(List(U64), [TooMany])
    prefix_candidates = |prefix, hay, cap|
        if List.len(prefix) >= 2 {
            match Teddy.build([prefix]) {
                Ok(t) => Teddy.candidates_capped(t, hay, cap)
                Err(_) => Teddy.byte_candidates_capped(List.get(prefix, 0) ?? 0, hay, cap)
            }
        } else {
            Teddy.byte_candidates_capped(List.get(prefix, 0) ?? 0, hay, cap)
        }

    find_all : Regex.T, List(U8) -> List(Regex.Span)
    find_all = |re, hay|
        # With a required literal prefix, SIMD-scan for candidates and verify each
        # — a big win when the literal is rare. The capped scan bails to the DFA
        # when the literal is dense (candidates > len/prefilter_k), where scanning
        # every byte with the DFA is cheaper than verifying at every candidate.
        if !List.is_empty(re.prefix) {
            # memchr-style scan for the prefix's FIRST byte, then verify each
            # candidate. Leaner than a Teddy fingerprint (one eq per window, no
            # dedup). The cap tracks the verify cost: an anchored-DFA verify
            # rejects a false positive in a step or two (~ns), so it keeps the
            # loose `inner_prefilter_k` gate — a selective-but-frequent first byte
            # like Holmes's `H` (one per match, but >len/512) still prefilters
            # rather than falling to a full DFA pass. The PikeVM verify is ~µs, so
            # it keeps the tight `prefilter_k` gate.
            fb = List.get(re.prefix, 0) ?? 0
            if re.exact {
                # Pure literal: the match IS the prefix, so verify with a memcmp
                # and emit a fixed-length span — no DFA, no trie lookups per byte.
                match Teddy.byte_candidates_capped(fb, hay, List.len(hay) // Regex.inner_prefilter_k) {
                    Ok(cands) => Regex.find_all_literal(re.prefix, hay, cands)
                    Err(_) => Regex.find_all_engine(re, hay)
                }
            } else {
                verify = match re.engine {
                    Three(d) => d.averify
                    Pike => NoVerify
                }
                k = match verify {
                    Verify(_) => Regex.inner_prefilter_k
                    NoVerify => Regex.prefilter_k
                }
                match Regex.prefix_candidates(re.prefix, hay, List.len(hay) // k) {
                    Ok(cands) =>
                        match verify {
                            Verify(av) => Regex.find_all_teddy_dfa(av, re.classes, hay, cands)
                            NoVerify => Regex.find_all_teddy(Regex.base(re), hay, cands)
                        }
                    Err(_) => Regex.find_all_engine(re, hay)
                }
            }
        } else if !List.is_empty(re.tlits) {
            # Alternation of leading literals (e.g. `Sherlock|Holmes|…`): SIMD Teddy
            # over the literal SET for candidates. A pure literal alternation
            # (`exact_alt`) verifies each candidate by memcmp — which branch, in
            # order — and emits a fixed-length span, no DFA. Otherwise the branches
            # carry more structure, so verify with the anchored DFA (or PikeVM).
            verify = match re.engine {
                Three(d) => d.averify
                Pike => NoVerify
            }
            k = if re.exact_alt {
                Regex.inner_prefilter_k
            } else {
                match verify {
                    Verify(_) => Regex.inner_prefilter_k
                    NoVerify => Regex.prefilter_k
                }
            }
            match Teddy.build(re.tlits) {
                Ok(t) =>
                    match Teddy.candidates_capped(t, hay, List.len(hay) // k) {
                        Ok(cands) =>
                            if re.exact_alt {
                                Regex.find_all_teddy_lits(re.tlits, hay, cands)
                            } else {
                                match verify {
                                    Verify(av) => Regex.find_all_teddy_dfa(av, re.classes, hay, cands)
                                    NoVerify => Regex.find_all_teddy(Regex.base(re), hay, cands)
                                }
                            }
                        Err(_) => Regex.find_all_engine(re, hay)
                    }
                Err(_) => Regex.find_all_engine(re, hay)
            }
        } else {
            match re.engine {
                Three(d) =>
                    match re.frange {
                        # First-byte class prefilter: SIMD range-scan for the next
                        # byte in [lo,hi], verify each with the anchored DFA. Turns
                        # a sparse class (e.g. `[0-9]{2,4}`) from a full per-byte
                        # DFA pass into a scan over just the candidate bytes. Same
                        # short-verify economics as the inner path → same cap.
                        Range(lo, hi) =>
                            match d.averify {
                                Verify(av) =>
                                    match Teddy.range_candidates_capped(lo, hi, hay, List.len(hay) // Regex.inner_prefilter_k) {
                                        Ok(cands) => Regex.find_all_teddy_dfa(av, re.classes, hay, cands)
                                        Err(_) => Regex.find_all_engine(re, hay)
                                    }
                                NoVerify => Regex.find_all_engine(re, hay)
                            }
                        # No leading literal or class — but maybe a required
                        # INTERIOR literal (e.g. `\w+@\w+`): memchr it, then a
                        # local reverse/forward search per hit.
                        NoRange =>
                            match d.inner {
                                Inner(inr) =>
                                    match Teddy.byte_candidates_capped(List.get(inr.lit, 0) ?? 0, hay, List.len(hay) // Regex.inner_prefilter_k) {
                                        Ok(cands) => Regex.find_all_inner(inr, re.classes, hay, cands)
                                        Err(_) => Regex.find_all_engine(re, hay)
                                    }
                                NoInner => Regex.find_all_engine(re, hay)
                            }
                    }
                Pike => Regex.find_all_engine(re, hay)
            }
        }

    # reverse-inner verify: for each interior-literal candidate `p`, run the
    # reverse DFA of LEFT·lit backward from `p+litlen` (floored at the previous
    # match end). It both confirms the literal is present at `p` and yields the
    # leftmost start `s`; the anchored full-pattern DFA from `s` then gives the
    # leftmost-first end (greedy-correct for a variable-length LEFT).
    find_all_inner : { lit : List(U8), lrev : Rev.D, full : Rev.D }, Trie.T, List(U8), List(U64) -> List(Regex.Span)
    find_all_inner = |inr, classes, hay, cands| {
        ncand = List.len(cands)
        len = List.len(hay)
        litlen = List.len(inr.lit)
        var i = 0
        var last_end = 0
        var acc = []
        var running = True
        while running {
            if i >= ncand {
                running = False
            } else {
                p = List.get(cands, i) ?? 0
                pe = p + litlen
                if p < last_end or pe > len {
                    i = i + 1
                } else {
                    match Rev.run_rev_check(inr.lrev, classes, hay, pe, last_end) {
                        Err(_) => {
                            i = i + 1
                        }
                        Ok(s) =>
                            match Rev.run_fwd_from(inr.full, classes, hay, s) {
                                Err(_) => {
                                    i = i + 1
                                }
                                Ok(e) => {
                                    acc = List.append(acc, { start: s, end: e })
                                    last_end = e
                                    i = i + 1
                                }
                            }
                    }
                }
            }
        }
        acc
    }

    # pure-literal verify: the whole match is the literal, so a memcmp confirms a
    # candidate and the span is a fixed length. No DFA, no per-byte trie lookup.
    # A literal is never empty, so a candidate inside the previous match is
    # skipped (keeps matches non-overlapping and leftmost-first).
    find_all_literal : List(U8), List(U8), List(U64) -> List(Regex.Span)
    find_all_literal = |lit, hay, cands| {
        ncand = List.len(cands)
        plen = List.len(lit)
        var i = 0
        var last_end = 0
        var acc = []
        var running = True
        while running {
            if i >= ncand {
                running = False
            } else {
                at = List.get(cands, i) ?? 0
                if at < last_end or !(Lit.matches(hay, at, lit, plen)) {
                    i = i + 1
                } else {
                    acc = List.append(acc, { start: at, end: at + plen })
                    last_end = at + plen
                    i = i + 1
                }
            }
        }
        acc
    }

    # pure-literal-alternation verify: at each candidate, find the first branch
    # (pattern order = leftmost-first) that matches by memcmp and emit its span —
    # no DFA. A false-positive Teddy candidate (no branch matches) is skipped.
    find_all_teddy_lits : List(List(U8)), List(U8), List(U64) -> List(Regex.Span)
    find_all_teddy_lits = |lits, hay, cands| {
        ncand = List.len(cands)
        var i = 0
        var last_end = 0
        var acc = []
        var running = True
        while running {
            if i >= ncand {
                running = False
            } else {
                at = List.get(cands, i) ?? 0
                if at < last_end {
                    i = i + 1
                } else {
                    match Regex.first_lit_match(lits, hay, at, 0) {
                        Ok(plen) => {
                            acc = List.append(acc, { start: at, end: at + plen })
                            last_end = at + plen
                            i = i + 1
                        }
                        Err(_) => {
                            i = i + 1
                        }
                    }
                }
            }
        }
        acc
    }

    # length of the first literal (in order) that matches at `at`, else NoMatch.
    first_lit_match : List(List(U8)), List(U8), U64, U64 -> Try(U64, [NoMatch])
    first_lit_match = |lits, hay, at, li|
        match List.get(lits, li) {
            Err(_) => Err(NoMatch)
            Ok(lit) =>
                if Lit.matches(hay, at, lit, List.len(lit)) {
                    Ok(List.len(lit))
                } else {
                    Regex.first_lit_match(lits, hay, at, li + 1)
                }
        }

    # verify literal-prefix candidates with the anchored DFA: run it from each
    # candidate — matches iff the pattern matches there, a tight table loop with
    # no per-candidate allocation. A literal-prefixed pattern never matches empty,
    # so a candidate inside the previous match is skipped.
    find_all_teddy_dfa : Rev.D, Trie.T, List(U8), List(U64) -> List(Regex.Span)
    find_all_teddy_dfa = |av, classes, hay, cands| {
        ncand = List.len(cands)
        var i = 0
        var last_end = 0
        var acc = []
        var running = True
        while running {
            if i >= ncand {
                running = False
            } else {
                at = List.get(cands, i) ?? 0
                if at < last_end {
                    i = i + 1
                } else {
                    match Rev.run_fwd_from(av, classes, hay, at) {
                        Ok(end) => {
                            acc = List.append(acc, { start: at, end })
                            last_end = end
                            i = i + 1
                        }
                        Err(_) => {
                            i = i + 1
                        }
                    }
                }
            }
        }
        acc
    }

    # verify literal-prefix candidates with the PikeVM (anchor patterns / Pike
    # engine, where no anchored verify DFA was built).
    find_all_teddy : Comp.Compiled, List(U8), List(U64) -> List(Regex.Span)
    find_all_teddy = |c, hay, cands| {
        ncand = List.len(cands)
        var i = 0
        var last_end = 0
        var acc = []
        var running = True
        while running {
            if i >= ncand {
                running = False
            } else {
                at = List.get(cands, i) ?? 0
                if at < last_end {
                    i = i + 1
                } else {
                    match Pike.wmatch_at(c, hay, at) {
                        Ok(span) => {
                            acc = List.append(acc, span)
                            last_end = span.end
                            i = i + 1
                        }
                        Err(_) => {
                            i = i + 1
                        }
                    }
                }
            }
        }
        acc
    }

    find_all_engine : Regex.T, List(U8) -> List(Regex.Span)
    find_all_engine = |re, hay| {
        comp = Regex.base(re)
        len = List.len(hay)
        var at = 0
        var last_end = Regex.sentinel
        var acc = []
        var running = True
        while running {
            if at > len {
                running = False
            } else {
                # DFA iterator step for look-free in-budget patterns (Three);
                # the PikeVM otherwise. Same empty-match advancement either way.
                next =
                    match re.engine {
                        Three(d) => Rev.find_from(d, re.classes, hay, at)
                        Pike => Pike.wfind_from(comp, hay, at)
                    }
                match next {
                    Err(_) => {
                        running = False
                    }
                    Ok(span) => {
                        s = span.start
                        e = span.end
                        if s == e and e == last_end {
                            at = Regex.next_bound(hay, e)
                        } else {
                            acc = List.append(acc, span)
                            last_end = e
                            at = if s == e { Regex.next_bound(hay, e) } else { e }
                        }
                    }
                }
            }
        }
        acc
    }

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
