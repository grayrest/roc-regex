## M4 — the prefilter seam (D6).
##
## `find_candidate` is the one entry point: given a required-literal prefix, the
## next byte offset at/after `at` where that prefix occurs, or NoCandidate. A
## scalar first-byte scan then a compare — the "byte-set scan then verify" rung.
## No SIMD (none is user-facing in Roc); Rabin-Karp for multi-literal sets is the
## deferred second rung. When SIMD builtins land this is the one file to swap.
Lit := [].{
    ## next occurrence of `pat` in `hay` at or after `at`. Empty `pat` means the
    ## caller did not extract a prefix — every position is a candidate.
    find_candidate : List(U8), U64, List(U8) -> Try(U64, [NoCandidate])
    find_candidate = |hay, at, pat|
        if List.is_empty(pat) {
            if at <= List.len(hay) { Ok(at) } else { Err(NoCandidate) }
        } else {
            Lit.scan(hay, at, pat, List.first(pat) ?? 0, List.len(pat))
        }

    scan : List(U8), U64, List(U8), U8, U64 -> Try(U64, [NoCandidate])
    scan = |hay, at, pat, b0, plen|
        if at + plen > List.len(hay) {
            Err(NoCandidate)
        } else if (List.get(hay, at) ?? 0) == b0 and Lit.matches(hay, at, pat, plen) {
            Ok(at)
        } else {
            Lit.scan(hay, at + 1, pat, b0, plen)
        }

    matches : List(U8), U64, List(U8), U64 -> Bool
    matches = |hay, at, pat, plen| Lit.eq(hay, at, pat, 0, plen)

    eq : List(U8), U64, List(U8), U64, U64 -> Bool
    eq = |hay, at, pat, i, plen|
        if i >= plen {
            True
        } else if (List.get(hay, at + i) ?? 0) == (List.get(pat, i) ?? 1) {
            Lit.eq(hay, at, pat, i + 1, plen)
        } else {
            False
        }
}
