## The public surface. `Dfa` is a transparent record with documented-unstable
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

Dfa := [].{
    ## The compiled pattern. Fields are unstable (see above). M1's engine is
    ## always the PikeVM; the `Dfa` arm and its tables are M3.
    ## The `engine` field records M3's outcome (D10): `Three` carries the D5
    ## forward+reverse DFAs for a look-free pattern within budget, else `Pike`.
    ## Documented-unstable.
    T : { comp : Comp.Compiled, engine : Dfa.Engine, plan : Dfa.Plan }

    ## M3's outcome (D10): `Three` carries the D5 forward+reverse DFAs for a
    ## look-free pattern within budget, else the PikeVM.
    Engine : [Pike, Three(Rev.Engine)]

    ## How a search runs, decided ONCE at compile time and shared by `find`,
    ## `is_match` and `find_all` — they used to pick their own prefilters, so an
    ## improvement landed on one and not the others, and the two could disagree.
    ##
    ## `scan` produces candidate offsets, `verify` turns a candidate into a span
    ## or rejects it, and `k` is the selectivity gate: the scan bails to the
    ## plain engine once it produces more than `len / k` candidates, because past
    ## that density verifying every candidate costs more than a straight DFA
    ## pass. `k` therefore tracks the VERIFY cost — an anchored-DFA verify
    ## rejects in a step or two (~ns) and keeps the loose gate, while a PikeVM
    ## verify (~µs) keeps the tight one.
    ##
    ## Any Teddy tables are built here rather than per call, so a literal pattern
    ## folds them into the artifact.
    Plan : {
        scan : [ScanNone, ScanByte(U8), ScanTeddy(Teddy.T), ScanRange(U8, U8)],
        verify : [VerEngine, VerMemcmp(List(U8)), VerMemcmpAlt(Teddy.T), VerDfa(Rev.D), VerPike, VerInner(Rev.InnerD)],
        k : U64,
    }

    ## A match, as half-open BYTE offsets into the haystack (D3, D15).
    Span : { start : U64, end : U64 }

    compile : Str -> Try(Dfa.T, Err.Error)
    compile = |src|
        match Comp.compile(src) {
            Err(e) => Err(e)
            Ok(c) => {
                nc = if c.classes.n_classes == 0 { 1 } else { c.classes.n_classes }
                max_states = Dfa.dfa_table_budget // (nc.to_u64() * Dfa.dfa_entry_bytes)
                engine =
                    match Rev.build(c, max_states) {
                        Ok(d) => Three(d)
                        Err(_) => Pike
                    }
                Ok({ comp: c, engine, plan: Dfa.plan_of(c, engine) })
            }
        }

    ## The documented literal-pattern idiom: fold, and crash-with-message on a
    ## bad literal so the build fails (D7).
    unwrap : Try(Dfa.T, Err.Error) -> Dfa.T
    unwrap = |r|
        match r {
            Ok(re) => re
            Err(e) => crash Err.render(e)
        }

    ## As `unwrap`, but the message names the pattern via a caller label — worth
    ## more than the caret when several regexes report at the same file position.
    unwrap_labeled : Str, Try(Dfa.T, Err.Error) -> Dfa.T
    unwrap_labeled = |label, r|
        match r {
            Ok(re) => re
            Err(e) => crash "[${label}] ${Err.render(e)}"
        }

    ## Leftmost-first search over a byte haystack: the first match, or NoMatch.
    ## Runs the same plan as `find_all` and stops at the first verified
    ## candidate, so every prefilter reaches this entry point too.
    find : Dfa.T, List(U8) -> Try(Dfa.Span, [NoMatch])
    find = |re, hay|
        match re.plan.verify {
            VerEngine => Dfa.find_engine(re, hay)
            _ => Dfa.find_chunked(re, hay, Dfa.first_chunk)
        }

    # The prefix length `find` scans before verifying what it has, and the factor
    # it grows by when nothing matched.
    first_chunk : U64
    first_chunk = 256

    chunk_growth : U64
    chunk_growth = 4

    # Search a GROWING PREFIX of the haystack, verifying after each round.
    #
    # Handing the whole haystack to the scan and verifying afterwards is right
    # for `find_all`, which needs every candidate anyway, but wrong for `find`:
    # it made an early match far more expensive than the plain DFA pass it
    # replaced (a match at offset 0 of a 256 KB haystack measured 310 ns through
    # the DFA and 30 µs through a full scan). Quadrupling prefixes keep the
    # no-match win — one SIMD pass instead of a full DFA pass, ~100x here — while
    # an early match only pays for its own chunk. The rounds are geometric, so
    # re-scanning and re-verifying from 0 each round costs a constant factor.
    #
    # Leftmost-first survives because a round reports candidates in increasing
    # order and covers every position below its limit, so the first candidate
    # that verifies is the leftmost match.
    find_chunked : Dfa.T, List(U8), U64 -> Try(Dfa.Span, [NoMatch])
    find_chunked = |re, hay, limit| {
        len = List.len(hay)
        lim = if limit > len { len } else { limit }
        match Dfa.scan_candidates_upto(re.plan, hay, lim, len) {
            # too dense for the prefilter to pay for itself: the DFA is cheaper
            Err(_) => Dfa.find_engine(re, hay)
            Ok(cands) =>
                match List.first(Dfa.verify_candidates(re, hay, cands, True)) {
                    Ok(span) => Ok(span)
                    Err(_) =>
                        if lim >= len {
                            Err(NoMatch)
                        } else {
                            Dfa.find_chunked(re, hay, limit * Dfa.chunk_growth)
                        }
                }
        }
    }

    # no prefilter: the engine's own unanchored search
    find_engine : Dfa.T, List(U8) -> Try(Dfa.Span, [NoMatch])
    find_engine = |re, hay|
        match re.engine {
            Three(d) => Rev.find(d, re.comp.classes, hay)
            Pike => Pike.wfind(re.comp, hay)
        }

    ## All capture spans: index 0 is the whole match, i is group i. An
    ## unset/non-participating group is `Err(NoGroup)`.
    captures : Dfa.T, List(U8) -> Try(List(Try(Dfa.Span, [NoGroup])), [NoMatch])
    captures = |re, hay|
        match Pike.captures(re.comp, hay) {
            Err(_) => Err(NoMatch)
            Ok(slots) => Ok(Dfa.pair_slots(slots, 0, []))
        }

    pair_slots : List(U64), U64, List(Try(Dfa.Span, [NoGroup])) -> List(Try(Dfa.Span, [NoGroup]))
    pair_slots = |slots, i, acc|
        if i + 1 >= List.len(slots) {
            acc
        } else {
            s = List.get(slots, i) ?? 0xFFFF_FFFF_FFFF_FFFF
            e = List.get(slots, i + 1) ?? 0xFFFF_FFFF_FFFF_FFFF
            span = if s == 0xFFFF_FFFF_FFFF_FFFF or e == 0xFFFF_FFFF_FFFF_FFFF { Err(NoGroup) } else { Ok({ start: s, end: e }) }
            Dfa.pair_slots(slots, i + 2, List.append(acc, span))
        }

    ## PikeVM find, bypassing the engine choice — for differential validation of
    ## the three-pass against the reference simulator.
    find_pike : Dfa.T, List(U8) -> Try(Dfa.Span, [NoMatch])
    find_pike = |re, hay| Pike.wfind(re.comp, hay)

    ## Whether the pattern matches anywhere in the haystack.
    is_match : Dfa.T, List(U8) -> Bool
    is_match = |re, hay|
        match re.engine {
            # A forward-only DFA pass answers this without finding the start —
            # cheaper than `find` when there is no prefilter. But an outermost
            # `$` (`eoi_only`) skips the forward end-scan entirely (see
            # `Rev.find_from`), and a prefiltered pattern is better served by its
            # plan, so both of those go through `find`.
            Three(d) =>
                if d.fwd.eoi_only or !(Dfa.is_plain(re.plan)) {
                    match Dfa.find(re, hay) { Ok(_) => True Err(_) => False }
                } else {
                    Rev.is_match(d.fwd, re.comp.classes, hay)
                }
            Pike =>
                match Dfa.find(re, hay) {
                    Ok(_) => True
                    Err(_) => False
                }
        }

    is_plain : Dfa.Plan -> Bool
    is_plain = |plan| match plan.verify { VerEngine => True, _ => False }


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
    all_caps : Dfa.T, List(U8) -> List(List(U64))
    all_caps = |re, hay| {
        len = List.len(hay)
        var $at = 0
        var $last_end = Dfa.sentinel
        var $acc = []
        var $running = True
        while $running {
            if $at > len {
                $running = False
            } else {
                match Pike.captures_from(re.comp, hay, $at) {
                    Err(_) => {
                        $running = False
                    }
                    Ok(slots) => {
                        s = List.get(slots, 0) ?? 0
                        e = List.get(slots, 1) ?? 0
                        if s == e and e == $last_end {
                            $at = Dfa.next_bound(hay, e)
                        } else {
                            $acc = List.append($acc, slots)
                            $last_end = e
                            $at = if s == e { Dfa.next_bound(hay, e) } else { e }
                        }
                    }
                }
            }
        }
        $acc
    }

    sentinel : U64
    sentinel = 0xFFFF_FFFF_FFFF_FFFF

    next_bound : List(U8), U64 -> U64
    next_bound = |hay, p|
        if p >= List.len(hay) { p + 1 } else { p + Comp.decode(hay, p).len }

    ## All whole-match spans. Uses the start-only whole-match engine (no
    ## per-thread slot allocation), with the same D14 empty-match advance as
    ## `all_caps`. `all_caps` (full slots) is kept for `captures`/`replace`/`split`.
    # Artifact budget for one DFA transition table: entries are U32, and the
    # table is `n_states * n_classes` of them, so a build over this many states
    # is refused (`TooBig`) and the pattern falls back to the PikeVM.
    dfa_table_budget : U64
    dfa_table_budget = 262144

    dfa_entry_bytes : U64
    dfa_entry_bytes = 4

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

    # the plan for a pattern with no usable prefilter
    plan_engine : Dfa.Plan
    plan_engine = { scan: ScanNone, verify: VerEngine, k: 1 }

    # Choose the search plan. Runs once, at compile time, so for a literal
    # pattern the whole thing — Teddy tables included — folds into the artifact.
    # The order is by selectivity: a required prefix beats a leading-literal set,
    # which beats a first-byte class, which beats a required interior literal.
    plan_of : Comp.Compiled, Dfa.Engine -> Dfa.Plan
    plan_of = |c, engine| {
        av = match engine { Three(d) => d.averify, Pike => NoVerify }
        # the verify kind sets the density gate: see `Plan`
        dv = match av { Verify(d) => VerDfa(d), NoVerify => VerPike }
        dk = match av { Verify(_) => Dfa.inner_prefilter_k, NoVerify => Dfa.prefilter_k }
        if !List.is_empty(c.prefix) {
            fb = List.get(c.prefix, 0) ?? 0
            if c.exact {
                # the match IS the prefix: memcmp verify, fixed-length span, no
                # DFA and no per-byte trie lookup
                { scan: ScanByte(fb), verify: VerMemcmp(c.prefix), k: Dfa.inner_prefilter_k }
            } else {
                # A multi-byte prefix scans a Teddy fingerprint (m<=3), so
                # candidates ~= actual literal occurrences rather than every
                # position of a common first byte — `\bthe\b` scans the "the"
                # fingerprint (~2.4k hits) instead of every `t` (~18k). A
                # single-byte prefix keeps the leaner first-byte memchr.
                scan =
                    if List.len(c.prefix) >= 2 {
                        match Teddy.build([c.prefix]) {
                            Ok(t) => ScanTeddy(t)
                            Err(_) => ScanByte(fb)
                        }
                    } else {
                        ScanByte(fb)
                    }
                { scan, verify: dv, k: dk }
            }
        } else if !List.is_empty(c.tlits) {
            # alternation of leading literals (`Sherlock|Holmes|…`): Teddy over
            # the literal SET
            match Teddy.build(c.tlits) {
                Err(_) => Dfa.plan_engine
                Ok(t) =>
                    if c.exact_alt {
                        { scan: ScanTeddy(t), verify: VerMemcmpAlt(t), k: Dfa.inner_prefilter_k }
                    } else {
                        { scan: ScanTeddy(t), verify: dv, k: dk }
                    }
            }
        } else {
            match engine {
                # No DFA was built (buried anchors, or over budget). A first-byte
                # SET still prefilters the PikeVM: one-byte literals give a Teddy
                # whose fingerprint is exact, so candidates are exactly the
                # positions holding one of those bytes.
                Pike =>
                    if List.len(c.fbytes) == 1 {
                        { scan: ScanByte(List.get(c.fbytes, 0) ?? 0), verify: VerPike, k: Dfa.prefilter_k }
                    } else if !List.is_empty(c.fbytes) {
                        match Teddy.build(List.map(c.fbytes, |b| [b])) {
                            Ok(t) => { scan: ScanTeddy(t), verify: VerPike, k: Dfa.prefilter_k }
                            Err(_) => Dfa.plan_engine
                        }
                    } else {
                        Dfa.plan_engine
                    }
                Three(d) =>
                    match c.frange {
                        # First-byte class prefilter: SIMD range-scan for the next
                        # byte in [lo,hi]. Turns a sparse class (`[0-9]{2,4}`)
                        # from a full per-byte DFA pass into a scan over just the
                        # candidate bytes.
                        Range(lo, hi) =>
                            match av {
                                Verify(x) => { scan: ScanRange(lo, hi), verify: VerDfa(x), k: Dfa.inner_prefilter_k }
                                NoVerify => Dfa.plan_engine
                            }
                        # No leading literal or class — but maybe a required
                        # INTERIOR literal (`\w+@\w+`): memchr it, then a local
                        # reverse/forward search per hit.
                        NoRange =>
                            match d.inner {
                                Inner(inr) => { scan: ScanByte(List.get(inr.lit, 0) ?? 0), verify: VerInner(inr), k: Dfa.inner_prefilter_k }
                                NoInner => Dfa.plan_engine
                            }
                    }
            }
        }
    }

    find_all : Dfa.T, List(U8) -> List(Dfa.Span)
    find_all = |re, hay|
        match re.plan.verify {
            VerEngine => Dfa.find_all_engine(re, hay)
            # A pure literal alternation is the one plan whose verify can run
            # INSIDE the scan: the matches are exactly the branch literals, so
            # the fused scan never materializes a candidate list. `find` still
            # runs it through the shared loop, which stops at the first hit.
            VerMemcmpAlt(t) =>
                match Teddy.match_lits(t, hay, List.len(hay) // re.plan.k) {
                    Ok(spans) => spans
                    Err(_) => Dfa.find_all_engine(re, hay)
                }
            _ =>
                match Dfa.scan_candidates(re.plan, hay) {
                    Ok(cands) => Dfa.verify_candidates(re, hay, cands, False)
                    # too many candidates for the prefilter to pay for itself
                    Err(_) => Dfa.find_all_engine(re, hay)
                }
        }

    # The candidate scan. Every arm is capped at `len / k`: past that density the
    # prefilter loses to a straight DFA pass, and `Err(TooMany)` says so.
    scan_candidates : Dfa.Plan, List(U8) -> Try(List(U64), [TooMany])
    scan_candidates = |plan, hay| {
        cap = List.len(hay) // plan.k
        match plan.scan {
            ScanNone => Ok([])
            ScanByte(b) => Teddy.byte_candidates_capped(b, hay, cap)
            ScanTeddy(t) => Teddy.candidates_capped(t, hay, cap)
            ScanRange(lo, hi) => Teddy.range_candidates_capped(lo, hi, hay, cap)
        }
    }

    # As `scan_candidates` over `hay[0..limit]`. The density gate still uses the
    # WHOLE haystack length, so a growing-prefix search never bails to the engine
    # any sooner than `find_all` would.
    scan_candidates_upto : Dfa.Plan, List(U8), U64, U64 -> Try(List(U64), [TooMany])
    scan_candidates_upto = |plan, hay, limit, len| {
        cap = len // plan.k
        match plan.scan {
            ScanNone => Ok([])
            ScanByte(b) => Teddy.byte_candidates_upto(b, hay, limit, cap)
            ScanTeddy(t) => Teddy.candidates_upto(t, hay, limit, cap)
            ScanRange(lo, hi) => Teddy.range_candidates_upto(lo, hi, hay, limit, cap)
        }
    }

    # The candidate loop, specialized per verify kind. The plan is matched ONCE,
    # here, and each loop below is monomorphic.
    #
    # A single loop with the `match plan.verify` inside it reads better and was
    # tried first, but extracting the tag payload every iteration cost 14% on
    # bounded_num and 6% on word_bound (hoisting the tag to a local did not help
    # — it is the payload extraction, not the field read). Same lesson as the
    # closure-fused Teddy scan: in Roc, the hot loop wants nothing polymorphic in
    # it. What the loops share instead is their SHAPE and this comment: take the
    # next candidate, skip it if it falls inside the previous match (which is
    # what keeps matches non-overlapping and leftmost-first), verify, append.
    # `first_only` stops after one match — that is `find`.
    #
    # Every plan that reaches here has a required literal, class or interior
    # literal, so the pattern cannot match empty and needs no empty-match
    # advance; that lives in `find_all_engine`, for the patterns that can.
    verify_candidates : Dfa.T, List(U8), List(U64), Bool -> List(Dfa.Span)
    verify_candidates = |re, hay, cands, first_only|
        match re.plan.verify {
            VerMemcmp(lit) => Dfa.verify_memcmp(lit, hay, cands, first_only)
            VerMemcmpAlt(t) => Dfa.verify_memcmp_alt(t, hay, cands, first_only)
            VerDfa(av) => Dfa.verify_dfa(av, re.comp.classes, hay, cands, first_only)
            VerPike => Dfa.verify_pike(re.comp, hay, cands, first_only)
            VerInner(inr) => Dfa.verify_inner_all(inr, re.comp.classes, hay, cands, first_only)
            VerEngine => []
        }

    # the match IS the literal: one memcmp, fixed-length span, no DFA and no
    # per-byte trie lookup
    verify_memcmp : List(U8), List(U8), List(U64), Bool -> List(Dfa.Span)
    verify_memcmp = |lit, hay, cands, first_only| {
        ncand = List.len(cands)
        len = List.len(hay)
        plen = List.len(lit)
        var $i = 0
        var $last_end = 0
        var $acc = []
        var $running = True
        while $running {
            if $i >= ncand {
                $running = False
            } else {
                at = List.get(cands, $i) ?? 0
                # `at + plen <= len` is load-bearing, not defensive: `Lit.eq`
                # reads a missing haystack byte as 0, so without it a literal
                # containing a NUL byte "matches" past the end and the emitted
                # span has `end > len` (which then underflows `split`).
                if at < $last_end or at + plen > len or !(Lit.matches(hay, at, lit, plen)) {
                    $i = $i + 1
                } else {
                    $acc = List.append($acc, { start: at, end: at + plen })
                    $last_end = at + plen
                    $i = $i + 1
                    $running = !first_only
                }
            }
        }
        $acc
    }

    # pure literal alternation: which branch matches here, in pattern order
    verify_memcmp_alt : Teddy.T, List(U8), List(U64), Bool -> List(Dfa.Span)
    verify_memcmp_alt = |t, hay, cands, first_only| {
        ncand = List.len(cands)
        len = List.len(hay)
        var $i = 0
        var $last_end = 0
        var $acc = []
        var $running = True
        while $running {
            if $i >= ncand {
                $running = False
            } else {
                at = List.get(cands, $i) ?? 0
                if at < $last_end {
                    $i = $i + 1
                } else {
                    match Teddy.lit_end(t, hay, at, 0, len) {
                        Err(_) => {
                            $i = $i + 1
                        }
                        Ok(e) => {
                            $acc = List.append($acc, { start: at, end: e })
                            $last_end = e
                            $i = $i + 1
                            $running = !first_only
                        }
                    }
                }
            }
        }
        $acc
    }

    # anchored DFA from the candidate: it matches iff the pattern matches THERE,
    # a tight table loop with no per-candidate allocation
    verify_dfa : Rev.D, Trie.T, List(U8), List(U64), Bool -> List(Dfa.Span)
    verify_dfa = |av, classes, hay, cands, first_only| {
        ncand = List.len(cands)
        var $i = 0
        var $last_end = 0
        var $acc = []
        var $running = True
        while $running {
            if $i >= ncand {
                $running = False
            } else {
                at = List.get(cands, $i) ?? 0
                if at < $last_end {
                    $i = $i + 1
                } else {
                    match Rev.run_fwd_from(av, classes, hay, at) {
                        Err(_) => {
                            $i = $i + 1
                        }
                        Ok(e) => {
                            $acc = List.append($acc, { start: at, end: e })
                            $last_end = e
                            $i = $i + 1
                            $running = !first_only
                        }
                    }
                }
            }
        }
        $acc
    }

    # anchor patterns / PikeVM engine, where no anchored verify DFA was built
    verify_pike : Comp.Compiled, List(U8), List(U64), Bool -> List(Dfa.Span)
    verify_pike = |c, hay, cands, first_only| {
        ncand = List.len(cands)
        var $i = 0
        var $last_end = 0
        var $acc = []
        var $running = True
        while $running {
            if $i >= ncand {
                $running = False
            } else {
                at = List.get(cands, $i) ?? 0
                if at < $last_end {
                    $i = $i + 1
                } else {
                    match Pike.wmatch_at(c, hay, at) {
                        Err(_) => {
                            $i = $i + 1
                        }
                        Ok(span) => {
                            $acc = List.append($acc, span)
                            $last_end = span.end
                            $i = $i + 1
                            $running = !first_only
                        }
                    }
                }
            }
        }
        $acc
    }

    # required interior literal: a local reverse scan for the start, then forward
    verify_inner_all : Rev.InnerD, Trie.T, List(U8), List(U64), Bool -> List(Dfa.Span)
    verify_inner_all = |inr, classes, hay, cands, first_only| {
        ncand = List.len(cands)
        len = List.len(hay)
        var $i = 0
        var $last_end = 0
        var $acc = []
        var $running = True
        while $running {
            if $i >= ncand {
                $running = False
            } else {
                at = List.get(cands, $i) ?? 0
                if at < $last_end {
                    $i = $i + 1
                } else {
                    match Dfa.verify_inner(inr, classes, hay, at, $last_end, len) {
                        Err(_) => {
                            $i = $i + 1
                        }
                        Ok(span) => {
                            $acc = List.append($acc, span)
                            $last_end = span.end
                            $i = $i + 1
                            $running = !first_only
                        }
                    }
                }
            }
        }
        $acc
    }

    # Reverse-inner verify for an interior-literal candidate `p`: run the reverse
    # DFA of LEFT·lit backward from `p+litlen` (floored at the previous match
    # end). It both confirms the literal is at `p` and yields the leftmost start
    # `s`. The end comes from `end`: `FromStart(full)` runs the anchored
    # full-pattern DFA from `s` (greedy-correct for a LEFT that can run past the
    # literal); `FromLit(rfwd)` runs the anchored lit·RIGHT DFA from `p` (hard
    # separator — the end is RIGHT-determined, so LEFT isn't re-scanned).
    verify_inner : Rev.InnerD, Trie.T, List(U8), U64, U64, U64 -> Try(Dfa.Span, [NoMatch])
    verify_inner = |inr, classes, hay, p, floor, len| {
        pe = p + List.len(inr.lit)
        if pe > len {
            Err(NoMatch)
        } else {
            match Rev.run_rev_check(inr.lrev, classes, hay, pe, floor) {
                Err(_) => Err(NoMatch)
                Ok(s) => {
                    end_r =
                        match inr.end {
                            FromStart(full) => Rev.run_fwd_from(full, classes, hay, s)
                            FromLit(rfwd) => Rev.run_fwd_from(rfwd, classes, hay, p)
                        }
                    match end_r {
                        Err(_) => Err(NoMatch)
                        Ok(e) => Ok({ start: s, end: e })
                    }
                }
            }
        }
    }

    find_all_engine : Dfa.T, List(U8) -> List(Dfa.Span)
    find_all_engine = |re, hay| {
        len = List.len(hay)
        var $at = 0
        var $last_end = Dfa.sentinel
        var $acc = []
        var $running = True
        while $running {
            if $at > len {
                $running = False
            } else {
                # DFA iterator step for look-free in-budget patterns (Three);
                # the PikeVM otherwise. Same empty-match advancement either way.
                next =
                    match re.engine {
                        Three(d) => Rev.find_from(d, re.comp.classes, hay, $at)
                        Pike => Pike.wfind_from(re.comp, hay, $at)
                    }
                match next {
                    Err(_) => {
                        $running = False
                    }
                    Ok(span) => {
                        s = span.start
                        e = span.end
                        if s == e and e == $last_end {
                            $at = Dfa.next_bound(hay, e)
                        } else {
                            $acc = List.append($acc, span)
                            $last_end = e
                            $at = if s == e { Dfa.next_bound(hay, e) } else { e }
                        }
                    }
                }
            }
        }
        $acc
    }

    ## Replace every match. `rep` carries `$N` group refs (longest-digit-run) and
    ## `$$` -> `$`; an unknown ref expands to empty (D15). Byte API.
    replace_all : Dfa.T, List(U8), List(U8) -> List(U8)
    replace_all = |re, hay, rep| {
        caps = Dfa.all_caps(re, hay)
        r = List.fold(caps, { out: [], last: 0 }, |st, sl| {
            s = List.get(sl, 0) ?? 0
            e = List.get(sl, 1) ?? 0
            before = List.sublist(hay, { start: st.last, len: s - st.last })
            expanded = Dfa.expand(rep, hay, sl)
            { out: List.concat(List.concat(st.out, before), expanded), last: e }
        })
        List.concat(r.out, List.sublist(hay, { start: r.last, len: List.len(hay) - r.last }))
    }

    expand : List(U8), List(U8), List(U64) -> List(U8)
    expand = |rep, hay, slots| Dfa.expand_loop(rep, hay, slots, 0, [])

    expand_loop : List(U8), List(U8), List(U64), U64, List(U8) -> List(U8)
    expand_loop = |rep, hay, slots, i, out|
        match List.get(rep, i) {
            Err(_) => out
            Ok(0x24) => {
                nx = List.get(rep, i + 1) ?? 0
                if nx == 0x24 {
                    Dfa.expand_loop(rep, hay, slots, i + 2, List.append(out, 0x24))
                } else if nx >= 48 and nx <= 57 {
                    d = Dfa.read_num(rep, i + 1, 0)
                    grp = Dfa.group_bytes(hay, slots, d.n)
                    Dfa.expand_loop(rep, hay, slots, d.i, List.concat(out, grp))
                } else {
                    Dfa.expand_loop(rep, hay, slots, i + 1, List.append(out, 0x24))
                }
            }
            Ok(b) => Dfa.expand_loop(rep, hay, slots, i + 1, List.append(out, b))
        }

    read_num : List(U8), U64, U64 -> { n : U64, i : U64 }
    read_num = |rep, i, acc|
        match List.get(rep, i) {
            Ok(b) if b >= 48 and b <= 57 => Dfa.read_num(rep, i + 1, acc * 10 + (b - 48).to_u64())
            _ => { n: acc, i }
        }

    group_bytes : List(U8), List(U64), U64 -> List(U8)
    group_bytes = |hay, slots, g| {
        s = List.get(slots, g * 2) ?? Dfa.sentinel
        e = List.get(slots, g * 2 + 1) ?? Dfa.sentinel
        if s == Dfa.sentinel or e == Dfa.sentinel { [] } else { List.sublist(hay, { start: s, len: e - s }) }
    }

    ## Split around matches, with leading/trailing empty fields and one more
    ## field than matches (D15).
    split : Dfa.T, List(U8) -> List(List(U8))
    split = |re, hay| {
        caps = Dfa.all_caps(re, hay)
        r = List.fold(caps, { fields: [], last: 0 }, |st, sl| {
            s = List.get(sl, 0) ?? 0
            e = List.get(sl, 1) ?? 0
            field = List.sublist(hay, { start: st.last, len: s - st.last })
            { fields: List.append(st.fields, field), last: e }
        })
        List.append(r.fields, List.sublist(hay, { start: r.last, len: List.len(hay) - r.last }))
    }

    replace_all_str : Dfa.T, Str, Str -> Str
    replace_all_str = |re, hay, rep|
        Str.from_utf8(Dfa.replace_all(re, Str.to_utf8(hay), Str.to_utf8(rep))) ?? ""

    split_str : Dfa.T, Str -> List(Str)
    split_str = |re, hay|
        List.map(Dfa.split(re, Str.to_utf8(hay)), |f| Str.from_utf8(f) ?? "")

    ## Convenience: search a `Str`. Copies to `List(U8)` (D3 — the byte API is
    ## the real one; this pays a copy in).
    find_str : Dfa.T, Str -> Try(Dfa.Span, [NoMatch])
    find_str = |re, s| Dfa.find(re, Str.to_utf8(s))

    is_match_str : Dfa.T, Str -> Bool
    is_match_str = |re, s| Dfa.is_match(re, Str.to_utf8(s))
}
