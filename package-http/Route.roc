## matchit 0.8 route strings -> pieces (H7 of
## `plans/2026-09-06-http-parse.md`).
##
## This module is the route SYNTAX only: a route string becomes a piece list,
## with matchit's validity rules enforced. `Rtrie` turns pieces into the
## structure that matches them, and no regex is involved in routing at all --
## H7's selection pattern was replaced by H4's radix-trie reopen once M4
## measured the per-route DFA pass at 60% of a request.
##
## Syntax, as matchit 0.8:
##   /users/{id}          a named parameter, non-empty, up to the next `/`
##   /img{id}.png         a prefix and suffix around it; at most one per segment
##   /{*rest}             a catch-all, only as the last segment, non-empty
##   /{{literal}}         `{{` and `}}` are escaped braces
##
Route := [].{
    ## One piece of a route. `Static` carries its literal bytes; `Param` and
    ## `CatchAll` carry the name they bind.
    Piece : [Static(List(U8)), Param(Str), CatchAll(Str)]

    Err : [
        # `{` with no `}`, an empty name, or a stray `}`
        InvalidParam,
        # two parameters in one segment (`/{a}-{b}`)
        InvalidParamSegment,
        # `{*rest}` anywhere but the last segment
        InvalidCatchAll,
    ]

    ## Split a route into pieces. Static runs are merged, so `/a/b` is one
    ## `Static` and the segment structure lives only in the bytes.
    parse : Str -> Try(List(Route.Piece), Route.Err)
    parse = |path| {
        b = Str.to_utf8(path)
        Route.scan(b, 0, [], [], False)
    }

    # `lit` accumulates the current static run; `seen_catch` rejects anything
    # after a catch-all (matchit: last segment only)
    scan : List(U8), U64, List(U8), List(Route.Piece), Bool -> Try(List(Route.Piece), Route.Err)
    scan = |b, i, lit, out, seen_catch|
        if i >= List.len(b) {
            Ok(Route.flush(lit, out))
        } else {
            c = List.get(b, i) ?? 0
            if c == '{' and (List.get(b, i + 1) ?? 0) == '{' {
                Route.scan(b, i + 2, List.append(lit, '{'), out, seen_catch)
            } else if c == '}' and (List.get(b, i + 1) ?? 0) == '}' {
                Route.scan(b, i + 2, List.append(lit, '}'), out, seen_catch)
            } else if c == '}' {
                Err(InvalidParam)
            } else if c == '{' {
                if seen_catch {
                    Err(InvalidCatchAll)
                } else {
                    match Route.close_brace(b, i + 1) {
                        Err(e) => Err(e)
                        Ok(j) => {
                            catch = (List.get(b, i + 1) ?? 0) == '*'
                            from = if catch { i + 2 } else { i + 1 }
                            if j <= from {
                                Err(InvalidParam)
                            } else {
                                name = Str.from_utf8_lossy(List.sublist(b, { start: from, len: j - from }))
                                out2 = Route.flush(lit, out)
                                piece = if catch { CatchAll(name) } else { Param(name) }
                                if catch and !Route.rest_is_empty(b, j + 1) {
                                    Err(InvalidCatchAll)
                                } else if !catch and Route.segment_has_param(b, j + 1) {
                                    Err(InvalidParamSegment)
                                } else {
                                    Route.scan(b, j + 1, [], List.append(out2, piece), catch)
                                }
                            }
                        }
                    }
                }
            } else {
                Route.scan(b, i + 1, List.append(lit, c), out, seen_catch)
            }
        }

    flush : List(U8), List(Route.Piece) -> List(Route.Piece)
    flush = |lit, out| if List.is_empty(lit) { out } else { List.append(out, Static(lit)) }

    # index of the `}` closing a parameter opened before `i`; a `/` or a second
    # `{` before it means the braces do not match
    close_brace : List(U8), U64 -> Try(U64, Route.Err)
    close_brace = |b, i|
        if i >= List.len(b) {
            Err(InvalidParam)
        } else {
            c = List.get(b, i) ?? 0
            if c == '}' { Ok(i) } else if c == '/' or c == '{' { Err(InvalidParam) } else { Route.close_brace(b, i + 1) }
        }

    # is the remainder of the route free of another `{` before the next `/`?
    segment_has_param : List(U8), U64 -> Bool
    segment_has_param = |b, i|
        if i >= List.len(b) {
            False
        } else {
            c = List.get(b, i) ?? 0
            if c == '/' {
                False
            } else if c == '{' and (List.get(b, i + 1) ?? 0) == '{' {
                Route.segment_has_param(b, i + 2)
            } else if c == '{' {
                True
            } else {
                Route.segment_has_param(b, i + 1)
            }
        }

    rest_is_empty : List(U8), U64 -> Bool
    rest_is_empty = |b, i| i >= List.len(b)

}
