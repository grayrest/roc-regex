## D7 — the error type and its renderer, extended with RE#'s rejections.
##
## `Error` is one record carrying the pattern, an optional span, and a `kind`.
## Every field is documented-unstable (no field privacy in Roc). `kind` is public
## and matchable; `render` is the only supported way to produce a message.
Err := [].{
    Pos : { offset : U64, col : U64 }

    Span : { start : Err.Pos, end : Err.Pos }

    ## What went wrong. The parse kinds track `regex-syntax`'s names; the
    ## `Unsupported` kinds carry RE#'s own messages (its
    ## `UnsupportedPatternException` texts) so the corpus' `tests07_unsupported`
    ## and the dotnet diff can be compared message for message.
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
        ComplementNeedsGroup,
        # RE# feature set
        LazyQuantifierUnsupported,
        Unsupported(Str),
        # budgets (D13) and the U64 solver's width (S9)
        PatternTooLong({ limit : U64, given : U64 }),
        NestLimitExceeded({ limit : U64, given : U64 }),
        TooManyClasses({ limit : U64, given : U64 }),
    ]

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
            ComplementNeedsGroup => "complement must be written ~( ... )"
            LazyQuantifierUnsupported => "RE# does not support lazy quantifiers (*?, +?, ??, {n,m}?)"
            Unsupported(msg) => msg
            PatternTooLong(b) => "pattern too long: limit ${b.limit.to_str()}, given ${b.given.to_str()}"
            NestLimitExceeded(b) => "nesting too deep: limit ${b.limit.to_str()}, given ${b.given.to_str()}"
            TooManyClasses(b) => "pattern distinguishes too many character classes: limit ${b.limit.to_str()}, given ${b.given.to_str()}"
        }

    ## One line, no caret — for logs.
    to_str : Err.Error -> Str
    to_str = |e|
        match e.at {
            Whole => "sharp: ${Err.message(e.kind)}"
            At(s) => "sharp: ${Err.message(e.kind)} at byte ${s.start.offset.to_str()}"
        }

    ## The diagnostic: message, then the pattern with a caret.
    render : Err.Error -> Str
    render = |e| {
        head = "sharp: ${Err.message(e.kind)}"
        match e.at {
            Whole => "${head}\n  | ${e.pattern}"
            At(s) => {
                col = Err.col_of(e.pattern, s.start.offset)
                pad = Str.repeat(" ", col)
                "${head}\n  | ${e.pattern}\n  | ${pad}^"
            }
        }
    }

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
