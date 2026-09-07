## HTTP/1.1 request framing on `Regex` (H2, H3, H8 of
## `plans/2026-09-06-http-parse.md`).
##
## The caller drives each step. Every piece is a byte range of the request
## buffer, and `slice` turns it into bytes when they are wanted — `List.sublist`
## is a view, so nothing here copies the buffer.
##
## Framing waits for the blank line that ends the header block: a buffer
## without it is `Incomplete`, not an error, so a caller reading from a socket
## can call again with more bytes.
##
## Headers are parsed EAGERLY, in the same pass. H2 originally chose to pull
## each header on demand, on the reasoning that materializing all of them would
## cost more than the two or three a handler reads. The measurement says the
## opposite by an order of magnitude: one `find_all` of `\r\n` locates every
## line boundary in a single SIMD pass over the block (~250 ns for a typical
## request), where each on-demand lookup was a separate leftmost search costing
## ~920 ns. Three lookups went from ~2770 ns to one shared ~250.
##
## What that trades away is the regex in the header lookup itself: with the
## line boundaries known, matching a header NAME is a case-insensitive byte
## compare, which is what it always was.
import re.Regex

Http := [].{
    ## A byte range of the request buffer.
    Piece : { start : U64, end : U64 }

    ## One header, as two ranges of the buffer. The value has its surrounding
    ## optional whitespace already trimmed (RFC 7230 OWS).
    Field : { name : Http.Piece, value : Http.Piece }

    ## A framed request. `body` is the offset just past the blank line.
    Req : {
        method : Http.Piece,
        target : Http.Piece,
        version : Http.Piece,
        fields : List(Http.Field),
        body : U64,
    }

    Err : [
        # no blank line yet: read more and call again
        Incomplete,
        # the request line is not METHOD SP TARGET SP HTTP/d.d CRLF
        BadRequestLine,
        # a header line starts with SP or HT (obs-fold, RFC 7230 deprecated)
        ObsFold,
        # a header line has no `:`
        BadHeader,
    ]

    ## Frame a request: the request line, then every header, in one pass.
    frame : List(U8) -> Try(Http.Req, Http.Err)
    frame = |buf| {
        # every `\r\n` in the buffer, from one SIMD literal scan. This locates
        # the request line's end, each header line's end, and the blank line
        # that ends the block, so framing needs no separate terminator search.
        ends = Regex.find_all(Http.crlf_m, buf)
        match List.first(ends) {
            Err(_) => Err(Incomplete)
            Ok(rl) =>
                match Http.request_line(buf, rl.start) {
                    Err(e) => Err(e)
                    Ok(rq) =>
                        match Http.fields_from(buf, ends, 1, rl.end, []) {
                            Err(e) => Err(e)
                            Ok(fs) => Ok({ method: rq.method, target: rq.target, version: rq.version, fields: fs.fields, body: fs.body })
                        }
                }
        }
    }

    ## The three pieces of the request line, each one anchored step over a view
    ## of the buffer. `eol` is where the line's `\r\n` begins.
    request_line : List(U8), U64 -> Try({ method : Http.Piece, target : Http.Piece, version : Http.Piece }, Http.Err)
    request_line = |buf, eol|
        match Http.take(Http.method_m, buf, 0) {
            Err(_) => Err(BadRequestLine)
            Ok(m) =>
                match Http.take(Http.target_m, buf, m) {
                    Err(_) => Err(BadRequestLine)
                    Ok(tg) =>
                        match Http.take(Http.version_m, buf, tg) {
                            Err(_) => Err(BadRequestLine)
                            # the version must run exactly to the line's end, so
                            # a trailing "HTTP/1.1x" is rejected rather than
                            # silently truncated
                            Ok(v) =>
                                if v != eol {
                                    Err(BadRequestLine)
                                } else {
                                    Ok({
                                        method: { start: 0, end: m },
                                        # the separating spaces are one byte each
                                        target: { start: m + 1, end: tg },
                                        version: { start: tg + 1, end: v },
                                    })
                                }
                        }
                }
        }

    ## Walk the line ends from `i`, turning each into a `Field`, until the blank
    ## line. `at` is where the current line starts.
    fields_from : List(U8), List(Regex.Span), U64, U64, List(Http.Field) -> Try({ fields : List(Http.Field), body : U64 }, Http.Err)
    fields_from = |buf, ends, i, at, acc|
        match List.get(ends, i) {
            # the block is not terminated yet
            Err(_) => Err(Incomplete)
            Ok(e) =>
                if e.start == at {
                    # a zero-length line: the blank line that ends the block
                    Ok({ fields: acc, body: e.end })
                } else if Http.is_ows(List.get(buf, at) ?? 0) {
                    Err(ObsFold)
                } else {
                    match Http.colon_at(buf, at, e.start) {
                        Err(_) => Err(BadHeader)
                        Ok(c) =>
                            Http.fields_from(buf, ends, i + 1, e.end, List.append(acc, {
                                name: { start: at, end: c },
                                value: Http.trim_ows(buf, { start: c + 1, end: e.start }),
                            }))
                    }
                }
        }

    # the first `:` in `at..stop`. A `while`, not recursion: this runs once per
    # byte of every header name in the request.
    colon_at : List(U8), U64, U64 -> Try(U64, [NoColon])
    colon_at = |buf, at, stop| {
        var i = at
        var found = stop
        while i < stop {
            if (List.get(buf, i) ?? 0) == ':' {
                found = i
                i = stop
            } else {
                i = i + 1
            }
        }
        if found == stop { Err(NoColon) } else { Ok(found) }
    }

    ## The bytes of a piece.
    slice : List(U8), Http.Piece -> List(U8)
    slice = |buf, p| List.sublist(buf, { start: p.start, len: p.end - p.start })

    ## The bytes of a piece as `Str`, for a caller that wants one.
    slice_str : List(U8), Http.Piece -> Str
    slice_str = |buf, p| Str.from_utf8_lossy(Http.slice(buf, p))

    ## The value of a named header, matched case-insensitively as HTTP requires.
    ## The first occurrence wins.
    header : List(U8), Http.Req, Str -> Try(Http.Piece, [Missing])
    header = |buf, req, name| Http.header_bytes(buf, req, Str.to_utf8(name))

    ## `header` with the name already as bytes. A server looks the same few
    ## headers up on every request from constant names; `Str.to_utf8` allocates,
    ## and at ~160 ns a lookup that conversion was most of the cost. A `List(U8)`
    ## literal at a top level is folded into the artifact, so this pays nothing.
    header_bytes : List(U8), Http.Req, List(U8) -> Try(Http.Piece, [Missing])
    header_bytes = |buf, req, want| {
        # an indexed loop, not `List.find_first`: a closure per field is the
        # cost the hot-loop notes describe, and there is one call per header a
        # handler reads
        n = List.len(want)
        fs = req.fields
        nf = List.len(fs)
        var i = 0
        var hit = Err(Missing)
        while i < nf {
            f = List.get(fs, i) ?? { name: { start: 0, end: 0 }, value: { start: 0, end: 0 } }
            if f.name.end - f.name.start == n and Http.eq_ci_at(buf, f.name.start, want, 0, n) {
                hit = Ok(f.value)
                i = nf
            } else {
                i = i + 1
            }
        }
        hit
    }

    ## Are `n` bytes of the buffer at `at` equal to `want`, ASCII-case-
    ## insensitively? Header names are ASCII by RFC 7230, so folding a byte is
    ## one range test.
    eq_ci_at : List(U8), U64, List(U8), U64, U64 -> Bool
    eq_ci_at = |buf, at, want, from, n| {
        var i = from
        var ok = True
        while ok and i < n {
            if Http.lower(List.get(buf, at + i) ?? 0) == Http.lower(List.get(want, i) ?? 1) {
                i = i + 1
            } else {
                ok = False
            }
        }
        ok
    }

    lower : U8 -> U8
    lower = |c| if c >= 'A' and c <= 'Z' { c + 32 } else { c }

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

    ## One anchored step over a suffix of the buffer: how far does `m` reach
    ## from `at`? The slice is a view, so a step costs no copy.
    take : Regex.Pattern, List(U8), U64 -> Try(U64, [NoMatch])
    take = |m, buf, at|
        match Regex.longest_end(m, List.sublist(buf, { start: at, len: List.len(buf) - at })) {
            Err(_) => Err(NoMatch)
            Ok(0) => Err(NoMatch)
            Ok(e) => Ok(at + e)
        }

    ## The matchers, one automaton each rather than one per call. Each is a
    ## literal pattern at a top level, so `Regex.compile` folds it into the
    ## artifact at build time.
    method_m : Regex.Pattern
    method_m = Regex.build("[A-Z]+")

    # the request target: anything up to the space before the version
    target_m : Regex.Pattern
    target_m = Regex.build(" [!-~]+")

    version_m : Regex.Pattern
    version_m = Regex.build(" HTTP/[0-9]\\.[0-9]")

    crlf_m : Regex.Pattern
    crlf_m = Regex.build("\r\n")
}
