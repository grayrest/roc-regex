## matchit 0.8 routes on `Sharp` (H4, H7 of `plans/2026-09-06-http-parse.md`).
##
## A route string is translated ONCE, at compile time, into two things: a
## selection pattern that the whole path is matched against, and a piece list
## that extraction steps over. `Sharp` never learns the route syntax.
##
## Syntax, as matchit 0.8:
##   /users/{id}          a named parameter, non-empty, up to the next `/`
##   /img{id}.png         a prefix and suffix around it; at most one per segment
##   /{*rest}             a catch-all, only as the last segment, non-empty
##   /{{literal}}         `{{` and `}}` are escaped braces
##
## Precedence is matchit's, not registration order: static beats parameter
## beats catch-all at the first segment where two routes differ. Routes are
## sorted by their segment-kind sequence at build time, so the first selection
## pattern that matches is the winner. Two routes that could match the same
## path and differ only in parameter NAMES are a conflict, as
## `matchit::InsertError::Conflict`.
import sharp.Sharp

Route := [].{
    ## One piece of a route. `Static` carries its literal bytes; `Param` and
    ## `CatchAll` carry the name they bind.
    Piece : [Static(List(U8)), Param(Str), CatchAll(Str)]

    ## A parsed route: the pieces, and the selection pattern compiled from them.
    T : { pieces : List(Route.Piece), sel : Sharp.T, path : Str }

    Err : [
        # `{` with no `}`, an empty name, or a stray `}`
        InvalidParam,
        # two parameters in one segment (`/{a}-{b}`)
        InvalidParamSegment,
        # `{*rest}` anywhere but the last segment
        InvalidCatchAll,
        # the selection pattern did not compile (a bug here, not in the route)
        BadPattern(Str),
    ]

    ## Parse and compile one route.
    compile : Str -> Try(Route.T, Route.Err)
    compile = |path|
        match Route.pieces_of(path) {
            Err(e) => Err(e)
            Ok(ps) =>
                match Sharp.compile(Route.pattern_of(ps)) {
                    Err(e) => Err(BadPattern(Sharp.err_str(e)))
                    Ok(sel) => Ok({ pieces: ps, sel, path })
                }
        }

    # --- the route string -> pieces ---------------------------------------------

    ## Split a route into pieces. Static runs are merged, so `/a/b` is one
    ## `Static` and the segment structure lives only in the bytes.
    pieces_of : Str -> Try(List(Route.Piece), Route.Err)
    pieces_of = |path| {
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

    # --- the pieces -> a selection pattern ---------------------------------------

    ## The anchored pattern the whole path is matched against. A parameter
    ## becomes `[^/]+` and a catch-all `_+`; both are non-empty, as matchit's
    ## are. Statics are escaped, including RE#'s own metacharacters.
    pattern_of : List(Route.Piece) -> Str
    pattern_of = |ps|
        Str.join_with(
            List.concat(
                List.prepend(
                    List.map(ps, |p|
                        match p {
                            Static(bytes) => Route.escape(bytes)
                            Param(_) => "[^/]+"
                            CatchAll(_) => "_+"
                        }),
                    "\\A"),
                ["\\z"]),
            "",
        )

    ## Escape one static run for RE#'s syntax. Beyond the usual metacharacters
    ## this must cover `_` (the universal set), `&` (intersection) and `~`
    ## (complement), which are operators here and are ordinary characters in
    ## every other flavour -- an unescaped `_` in `/user_profiles/{id}` would
    ## make the route match anything.
    escape : List(U8) -> Str
    escape = |bytes|
        Str.from_utf8_lossy(
            List.fold(bytes, [], |acc, c|
                if Route.is_meta(c) { List.concat(acc, ['\\', c]) } else { List.append(acc, c) }))

    is_meta : U8 -> Bool
    is_meta = |c| List.contains(Route.metas, c)

    metas : List(U8)
    metas = ['\\', '.', '+', '*', '?', '(', ')', '[', ']', '{', '}', '|', '^', '$', '_', '&', '~', '-']

    # --- matching ----------------------------------------------------------------

    ## Does this route match the whole path?
    matches : Route.T, List(U8) -> Bool
    matches = |r, path| Sharp.is_match(r.sel, path)

    ## The route's parameters, in order, as slices of `path`. Only call this on
    ## a route whose selection pattern matched: the pieces are stepped in order
    ## and a mismatch answers `Err(NoMatch)` rather than guessing.
    params : Route.T, List(U8) -> Try(List({ name : Str, value : List(U8) }), [NoMatch])
    params = |r, path| Route.step(r.pieces, path, 0, [])

    step : List(Route.Piece), List(U8), U64, List({ name : Str, value : List(U8) }) -> Try(List({ name : Str, value : List(U8) }), [NoMatch])
    step = |ps, path, at, acc|
        match List.first(ps) {
            Err(_) => if at == List.len(path) { Ok(acc) } else { Err(NoMatch) }
            Ok(p) => {
                rest = List.drop_first(ps, 1)
                match p {
                    Static(bytes) => {
                        n = List.len(bytes)
                        if List.sublist(path, { start: at, len: n }) == bytes {
                            Route.step(rest, path, at + n, acc)
                        } else {
                            Err(NoMatch)
                        }
                    }
                    Param(name) =>
                        # The parameter runs to the end of its segment, but a
                        # static SUFFIX in the same segment belongs to the route,
                        # not the value: `/images/img{id}.png` on
                        # "/images/img9.png" binds "9", not "9.png". The greedy
                        # `[^/]+` takes the whole segment, so the suffix is
                        # subtracted here. matchit allows at most one parameter
                        # per segment, so there is exactly one suffix to remove.
                        match Route.take(Route.seg_matcher, path, at) {
                            Err(_) => Err(NoMatch)
                            Ok(seg_end) => {
                                suf = Route.in_segment_head(rest)
                                k = List.len(suf)
                                if k == 0 {
                                    Route.step(rest, path, seg_end, List.append(acc, { name, value: List.sublist(path, { start: at, len: seg_end - at }) }))
                                } else if seg_end < at + k + 1 or List.sublist(path, { start: seg_end - k, len: k }) != suf {
                                    Err(NoMatch)
                                } else {
                                    Route.step(rest, path, seg_end - k, List.append(acc, { name, value: List.sublist(path, { start: at, len: seg_end - k - at }) }))
                                }
                            }
                        }
                    CatchAll(name) =>
                        match Route.take(Route.rest_matcher, path, at) {
                            Err(_) => Err(NoMatch)
                            Ok(e) => Route.step(rest, path, e, List.append(acc, { name, value: List.sublist(path, { start: at, len: e - at }) }))
                        }
                }
            }
        }

    ## The part of the next piece that lies in the current segment: the leading
    ## bytes of a following `Static`, up to its first `/`. Empty when the next
    ## piece is not a static or the static starts a new segment.
    in_segment_head : List(Route.Piece) -> List(U8)
    in_segment_head = |ps|
        match List.first(ps) {
            Ok(Static(bytes)) =>
                match List.find_first_index(bytes, |c| c == '/') {
                    Ok(i) => List.take_first(bytes, i)
                    Err(_) => bytes
                }
            _ => []
        }

    ## One anchored step: how far does `m` reach from `at`? The slice is a view
    ## of `path`, so a step costs no copy of the haystack.
    ##
    ## A parameter is greedy and its own segment, so the LONGEST end is the one
    ## wanted; the static that follows then has to line up, and `step` reports
    ## `NoMatch` if it does not.
    take : Sharp.T, List(U8), U64 -> Try(U64, [NoMatch])
    take = |m, path, at|
        match Sharp.longest_end(m, List.sublist(path, { start: at, len: List.len(path) - at })) {
            Err(_) => Err(NoMatch)
            Ok(0) => Err(NoMatch)
            Ok(e) => Ok(at + e)
        }

    ## The two piece matchers, shared by every route: one automaton each rather
    ## than one per parameter (H7).
    seg_matcher : Sharp.T
    seg_matcher = Sharp.unwrap(Sharp.compile("[^/]+"))

    rest_matcher : Sharp.T
    rest_matcher = Sharp.unwrap(Sharp.compile("_+"))
}
