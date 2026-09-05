## M4 — literal comparison for the prefilter seam (D6).
##
## `matches` is the memcmp a candidate verify runs once a scan has proposed an
## offset. The scalar SCANNERS that used to live here (`find_candidate`, `scan`,
## `find_in_set`) are gone: every entry point now shares one plan, whose scans
## are the SIMD ones in `Teddy`.
Lit := [].{
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
