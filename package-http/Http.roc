## HTTP/1.1 request framing on `Sharp` (H2, H3, H8 of
## `plans/2026-09-06-http-parse.md`).
##
## The caller drives each step. Every piece is a `List.sublist` view of the
## request buffer, so nothing here copies the bytes: a `Piece` is a byte range
## and `slice` turns it into the bytes when they are wanted.
##
## Framing waits for the `\r\n\r\n` that ends the header block: a buffer
## without it is `Incomplete`, not an error, so a caller reading from a socket
## can call again with more bytes. Headers are NOT parsed up front -- `header`
## runs one anchored search over the header block per lookup, which for the
## handful a request handler reads is less work than materializing all of them.
import sharp.Sharp

Http := [].{
    ## A byte range of the request buffer.
    Piece : { start : U64, end : U64 }

    ## A framed request. `headers` is the extent of the header block, not its
    ## contents; `body` starts after the terminator.
    Req : {
        method : Http.Piece,
        target : Http.Piece,
        version : Http.Piece,
        headers : Http.Piece,
        body : U64,
    }

    Err : [
        # no `\r\n\r\n` yet: read more and call again
        Incomplete,
        # the request line is not METHOD SP TARGET SP HTTP/d.d CRLF
        BadRequestLine,
        # a header line starts with SP or HT (obs-fold, RFC 7230 deprecated)
        ObsFold,
        # the header block has a line that is not `name: value`
        BadHeader,
    ]

    ## Frame a request. One anchored step per piece of the request line, then
    ## the header block's extent.
    frame : List(U8) -> Try(Http.Req, Http.Err)
    frame = |buf|
        match Http.find_terminator(buf) {
            Err(_) => Err(Incomplete)
            Ok(t) =>
                # the request line ends at the first CRLF, which the terminator
                # search has already proved exists
                match Http.take(Http.method_m, buf, 0) {
                    Err(_) => Err(BadRequestLine)
                    Ok(m) =>
                        match Http.take(Http.target_m, buf, m) {
                            Err(_) => Err(BadRequestLine)
                            Ok(tg) =>
                                match Http.take(Http.version_m, buf, tg) {
                                    Err(_) => Err(BadRequestLine)
                                    Ok(v) =>
                                        if v + 2 > t.end or !Http.at_crlf(buf, v) {
                                            Err(BadRequestLine)
                                        } else if Http.is_obs_fold(buf, v + 2) {
                                            Err(ObsFold)
                                        } else {
                                            Ok({
                                                method: { start: 0, end: m },
                                                # the separating spaces are one byte each
                                                target: { start: m + 1, end: tg },
                                                version: { start: tg + 1, end: v },
                                                headers: { start: v + 2, end: t.start + 2 },
                                                body: t.end,
                                            })
                                        }
                                }
                        }
                }
        }

    ## The bytes of a piece.
    slice : List(U8), Http.Piece -> List(U8)
    slice = |buf, p| List.sublist(buf, { start: p.start, len: p.end - p.start })

    ## The bytes of a piece as `Str`, for a caller that wants one.
    slice_str : List(U8), Http.Piece -> Str
    slice_str = |buf, p| Str.from_utf8_lossy(Http.slice(buf, p))

    ## The value of a named header, case-insensitively, with surrounding
    ## optional whitespace trimmed. On demand: one anchored search of the
    ## header block per call.
    ##
    ## `name` must be a header name, not a pattern -- it is escaped before it
    ## reaches the engine.
    header : List(U8), Http.Req, Str -> Try(Http.Piece, [Missing])
    header = |buf, req, name|
        match Sharp.compile(Http.name_pattern(name)) {
            Err(_) => Err(Missing)
            Ok(m) => Http.header_with(buf, req, m)
        }

    ## `header` with the matcher supplied, for a caller that looks the same
    ## header up repeatedly: `Sharp.compile` folds at build time only for a
    ## literal pattern, and a name assembled at runtime compiles at runtime.
    header_with : List(U8), Http.Req, Sharp.T -> Try(Http.Piece, [Missing])
    header_with = |buf, req, m| {
        block = Http.slice(buf, req.headers)
        match Sharp.find(m, block) {
            Err(_) => Err(Missing)
            Ok(s) => {
                at = req.headers.start + s.end
                match Sharp.longest_end(Http.value_m, List.sublist(buf, { start: at, len: List.len(buf) - at })) {
                    Err(_) => Ok({ start: at, end: at })
                    Ok(e) => Ok(Http.trim_ows(buf, { start: at, end: at + e }))
                }
            }
        }
    }

    ## The pattern matching one header's name and the colon and optional
    ## whitespace after it, anchored to the start of a line. `^` is a line
    ## anchor in RE# always, so "the start of a header line" needs nothing
    ## more; `(?i)` makes the name case-insensitive, as HTTP requires.
    name_pattern : Str -> Str
    name_pattern = |name|
        Str.join_with(["(?i)^", Http.escape(Str.to_utf8(name)), ":[ \t]*"], "")

    escape : List(U8) -> Str
    escape = |bytes|
        Str.from_utf8_lossy(
            List.fold(bytes, [], |acc, c|
                if List.contains(Http.metas, c) { List.concat(acc, ['\\', c]) } else { List.append(acc, c) }))

    # RE#'s metacharacters, which include `_`, `&` and `~`
    metas : List(U8)
    metas = ['\\', '.', '+', '*', '?', '(', ')', '[', ']', '{', '}', '|', '^', '$', '_', '&', '~', '-']

    ## Drop spaces and horizontal tabs from both ends of a piece (RFC 7230 OWS).
    trim_ows : List(U8), Http.Piece -> Http.Piece
    trim_ows = |buf, p| {
        var s = p.start
        var e = p.end
        while s < e and Http.is_ows(List.get(buf, s) ?? 0) {
            s = s + 1
        }
        while e > s and Http.is_ows(List.get(buf, e - 1) ?? 0) {
            e = e - 1
        }
        { start: s, end: e }
    }

    is_ows : U8 -> Bool
    is_ows = |c| c == ' ' or c == '\t'

    # --- the anchored steps ------------------------------------------------------

    ## One anchored step over a suffix of the buffer: how far does `m` reach
    ## from `at`? The slice is a view, so a step costs no copy -- which is what
    ## makes a whole request one forward pass rather than a quadratic one.
    take : Sharp.T, List(U8), U64 -> Try(U64, [NoMatch])
    take = |m, buf, at|
        match Sharp.longest_end(m, List.sublist(buf, { start: at, len: List.len(buf) - at })) {
            Err(_) => Err(NoMatch)
            Ok(0) => Err(NoMatch)
            Ok(e) => Ok(at + e)
        }

    at_crlf : List(U8), U64 -> Bool
    at_crlf = |buf, i| (List.get(buf, i) ?? 0) == '\r' and (List.get(buf, i + 1) ?? 0) == '\n'

    # a header line may not begin with SP or HT (obsolete line folding)
    is_obs_fold : List(U8), U64 -> Bool
    is_obs_fold = |buf, i| Http.is_ows(List.get(buf, i) ?? 0)

    ## The end of the header block: the first `\r\n\r\n`. Returns the range of
    ## the terminator itself, so `start` is where the last header line ended
    ## and `end` is where the body begins.
    find_terminator : List(U8) -> Try({ start : U64, end : U64 }, [NoMatch])
    find_terminator = |buf|
        match Sharp.find(Http.term_m, buf) {
            Err(_) => Err(NoMatch)
            Ok(s) => Ok({ start: s.start, end: s.end })
        }

    ## The matchers, one automaton each rather than one per call. Each is a
    ## literal pattern at a top level, so `Sharp.compile` folds it into the
    ## artifact at build time.
    method_m : Sharp.T
    method_m = Sharp.unwrap(Sharp.compile("[A-Z]+"))

    # the request target: anything up to the space before the version
    target_m : Sharp.T
    target_m = Sharp.unwrap(Sharp.compile(" [!-~]+"))

    version_m : Sharp.T
    version_m = Sharp.unwrap(Sharp.compile(" HTTP/[0-9]\\.[0-9]"))

    value_m : Sharp.T
    value_m = Sharp.unwrap(Sharp.compile("[^\r\n]*"))

    term_m : Sharp.T
    term_m = Sharp.unwrap(Sharp.compile("\r\n\r\n"))
}
