## D7 — the error type and its renderer.
##
## `Error` is one record carrying the pattern, an optional span, and a `kind`,
## rather than a pattern-carrying variant per kind (D7). Every field is
## documented-unstable: Roc has no field privacy and the nominal type that would
## give it segfaults the compiler (Owed upstream 2), so the layout is public
## whether or not that is intended.
##
## `kind` is public and matchable; `render` is the only supported way to produce
## a message (S6). The renderer emits a window, never the whole pattern, inside a
## 66-display-column budget, because the compile-time crash formatter reflows on
## display width (D7, corrected 2026-09-02).
Err := [].{
    ## A byte offset into the pattern, with the display column for the caret.
    ## `offset` is bytes (for slicing); `col` is display columns (for the caret).
    Pos : { offset : U64, col : U64 }

    ## A half-open span of the pattern.
    Span : { start : Err.Pos, end : Err.Pos }

    ## What went wrong. Names track `regex-syntax` so the differential harness
    ## maps 1:1 (D7). M1 uses the parse subset; the full ~47-kind enumeration
    ## and D13's budget kinds arrive with the milestones that raise them.
    Kind : [
        # parse
        GroupUnclosed,
        GroupUnopened,
        ClassUnclosed,
        ClassRangeInvalid,
        RepetitionMissing,
        RepetitionCountUnclosed,
        RepetitionCountInvalid,
        EscapeUnrecognized,
        EscapeUnexpectedEof,
        FlagUnsupported,
        # budgets (D13)
        PatternTooLong({ limit : U64, given : U64 }),
        NestLimitExceeded({ limit : U64, given : U64 }),
        NfaSizeLimitExceeded({ limit : U64, given : U64 }),
    ]

    ## The error itself.
    Error : {
        pattern : Str,
        at : [Whole, At(Err.Span)],
        kind : Err.Kind,
    }

    err : Str, U64, Err.Kind -> Err.Error
    err = |pattern, offset, kind|
        { pattern, at: At({ start: { offset, col: offset }, end: { offset, col: offset } }), kind }

    whole : Str, Err.Kind -> Err.Error
    whole = |pattern, kind| { pattern, at: Whole, kind }

    ## The bare sentence for a kind — no pattern, no caret.
    message : Err.Kind -> Str
    message = |kind|
        match kind {
            GroupUnclosed => "unclosed group"
            GroupUnopened => "unopened group"
            ClassUnclosed => "unclosed character class"
            ClassRangeInvalid => "invalid character class range"
            RepetitionMissing => "repetition operator missing its operand"
            RepetitionCountUnclosed => "unclosed repetition count"
            RepetitionCountInvalid => "invalid repetition count"
            EscapeUnrecognized => "unrecognized escape"
            EscapeUnexpectedEof => "incomplete escape at end of pattern"
            FlagUnsupported => "unsupported inline flag (only `i` is implemented)"
            PatternTooLong(b) => "pattern too long: limit ${b.limit.to_str()}, given ${b.given.to_str()}"
            NestLimitExceeded(b) => "nesting too deep: limit ${b.limit.to_str()}, given ${b.given.to_str()}"
            NfaSizeLimitExceeded(b) => "pattern compiles too large: limit ${b.limit.to_str()} bytes, given ${b.given.to_str()}"
        }

    ## One line, no caret — for logs.
    to_str : Err.Error -> Str
    to_str = |e|
        match e.at {
            Whole => "regex: ${Err.message(e.kind)}"
            At(s) => "regex: ${Err.message(e.kind)} at byte ${s.start.offset.to_str()}"
        }
    ## S6 — the diagnostic. Message, then the pattern with a caret. M1 renders the
    ## whole pattern (patterns are short); the 66-display-column windowing (D7) is
    ## an M1.5 refinement. `render` is the only supported way to produce a message.
    render : Err.Error -> Str
    render = |e| {
        head = "regex: ${Err.message(e.kind)}"
        match e.at {
            Whole => "${head}\n  | ${e.pattern}"
            At(s) => {
                col = Err.col_of(e.pattern, s.start.offset)
                pad = Str.repeat(" ", col)
                "${head}\n  | ${e.pattern}\n  | ${pad}^"
            }
        }
    }

    ## Display column of a byte offset: count codepoints before it (M1 ASCII
    ## approximation; East-Asian width is M1.5).
    col_of : Str, U64 -> U64
    col_of = |pattern, offset|
        Err.count_cps(Str.to_utf8(pattern), 0, offset, 0)

    count_cps : List(U8), U64, U64, U64 -> U64
    count_cps = |b, i, offset, n|
        if i >= offset or i >= List.len(b) {
            n
        } else {
            step = Err.cp_len(List.get(b, i) ?? 0)
            Err.count_cps(b, i + step, offset, n + 1)
        }

    cp_len : U8 -> U64
    cp_len = |b0|
        if b0 < 0x80 { 1 } else if b0.bitwise_and(0xE0) == 0xC0 { 2 } else if b0.bitwise_and(0xF0) == 0xE0 { 3 } else { 4 }

}
