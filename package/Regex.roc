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
import Err

Regex := [].{
    ## The compiled pattern. Fields are unstable (see above). M1's engine is
    ## always the PikeVM; the `Dfa` arm and its tables are M3.
    T : { prog : List(U32), splits : List(U32), classes : Trie.T }

    ## A match, as half-open BYTE offsets into the haystack (D3, D15).
    Span : { start : U64, end : U64 }

    compile : Str -> Try(Regex.T, Err.Error)
    compile = |src| Comp.compile(src)

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

    ## Leftmost-first search over a byte haystack.
    find : Regex.T, List(U8) -> Try(Regex.Span, [NoMatch])
    find = |re, hay| Pike.find(re, hay)

    ## Whether the pattern matches anywhere in the haystack.
    is_match : Regex.T, List(U8) -> Bool
    is_match = |re, hay|
        match Pike.find(re, hay) {
            Ok(_) => True
            Err(_) => False
        }

    ## Convenience: search a `Str`. Copies to `List(U8)` (D3 — the byte API is
    ## the real one; this pays a copy in).
    find_str : Regex.T, Str -> Try(Regex.Span, [NoMatch])
    find_str = |re, s| Pike.find(re, Str.to_utf8(s))

    is_match_str : Regex.T, Str -> Bool
    is_match_str = |re, s| Regex.is_match(re, Str.to_utf8(s))
}
