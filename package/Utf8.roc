## UTF-8 decoding over `List(U8)` haystacks with D8's `Invalid` symbol: a
## malformed sequence decodes as one `Invalid` symbol whose extent is the first
## byte plus every continuation byte following it (D8 rule 1). Well-formedness
## is structural (lead byte, continuation count, no overlongs, no surrogates).
Utf8 := [].{
    Sym : { cp : U32, len : U64, ok : Bool }

    ## decode the symbol starting at byte offset `i`
    decode : List(U8), U64 -> Utf8.Sym
    decode = |b, i| {
        b0 = Utf8.at(b, i)
        if b0 < 0x80 {
            { cp: b0.to_u32(), len: 1, ok: True }
        } else if b0 >= 0xC2 and b0 <= 0xDF {
            b1 = Utf8.at(b, i + 1)
            if Utf8.is_cont(b1) {
                { cp: b0.bitwise_and(0x1F).to_u32().shl_wrap(6).bitwise_or(Utf8.low6(b1)), len: 2, ok: True }
            } else {
                Utf8.invalid(b, i)
            }
        } else if b0 >= 0xE0 and b0 <= 0xEF {
            b1 = Utf8.at(b, i + 1)
            b2 = Utf8.at(b, i + 2)
            lo_ok = if b0 == 0xE0 { b1 >= 0xA0 and b1 <= 0xBF } else if b0 == 0xED { b1 >= 0x80 and b1 <= 0x9F } else { Utf8.is_cont(b1) }
            if lo_ok and Utf8.is_cont(b2) {
                cp = b0.bitwise_and(0x0F).to_u32().shl_wrap(12).bitwise_or(Utf8.low6(b1).shl_wrap(6)).bitwise_or(Utf8.low6(b2))
                { cp, len: 3, ok: True }
            } else {
                Utf8.invalid(b, i)
            }
        } else if b0 >= 0xF0 and b0 <= 0xF4 {
            b1 = Utf8.at(b, i + 1)
            b2 = Utf8.at(b, i + 2)
            b3 = Utf8.at(b, i + 3)
            lo_ok = if b0 == 0xF0 { b1 >= 0x90 and b1 <= 0xBF } else if b0 == 0xF4 { b1 >= 0x80 and b1 <= 0x8F } else { Utf8.is_cont(b1) }
            if lo_ok and Utf8.is_cont(b2) and Utf8.is_cont(b3) {
                cp = b0.bitwise_and(0x07).to_u32().shl_wrap(18).bitwise_or(Utf8.low6(b1).shl_wrap(12)).bitwise_or(Utf8.low6(b2).shl_wrap(6)).bitwise_or(Utf8.low6(b3))
                { cp, len: 4, ok: True }
            } else {
                Utf8.invalid(b, i)
            }
        } else {
            Utf8.invalid(b, i)
        }
    }

    # the Invalid symbol at `i`: byte `i` plus the run of continuation bytes after it
    invalid : List(U8), U64 -> Utf8.Sym
    invalid = |b, i| { cp: 0, len: 1 + Utf8.cont_run(b, i + 1, 0), ok: False }

    cont_run : List(U8), U64, U64 -> U64
    cont_run = |b, i, n|
        if i < List.len(b) and Utf8.is_cont(Utf8.at(b, i)) { Utf8.cont_run(b, i + 1, n + 1) } else { n }

    is_cont : U8 -> Bool
    is_cont = |x| x >= 0x80 and x <= 0xBF

    low6 : U8 -> U32
    low6 = |x| x.bitwise_and(0x3F).to_u32()

    at : List(U8), U64 -> U8
    at = |b, i| List.get(b, i) ?? 0

    ## the byte offset where the symbol containing byte `i` starts: back over
    ## continuation bytes (a bare continuation run is itself an Invalid symbol
    ## starting at its first byte, so this is right for both cases).
    sym_start : List(U8), U64 -> U64
    sym_start = |b, i|
        if i > 0 and Utf8.is_cont(Utf8.at(b, i)) { Utf8.sym_start(b, i - 1) } else { i }

    ## The symbol ENDING at byte position `pos` (exclusive), for right-to-left
    ## scans: `cs` is where it starts. Valid UTF-8 decodes exactly; a malformed
    ## sequence is one Invalid symbol back to its lead byte, or, for a run of
    ## bare continuation bytes, back to the byte after the preceding non-
    ## continuation byte. Invalid input may segment differently forwards and
    ## backwards (D8 rule 7).
    decode_rev : List(U8), U64 -> { cs : U64, cp : U32, ok : Bool }
    decode_rev = |b, pos| {
        i = pos - 1
        bi = Utf8.at(b, i)
        if bi < 0x80 {
            { cs: i, cp: bi.to_u32(), ok: True }
        } else {
            l = Utf8.sym_start(b, i)
            bl = Utf8.at(b, l)
            if !Utf8.is_cont(bl) and bl < 0x80 {
                # bare continuation run after an ASCII byte
                { cs: l + 1, cp: 0, ok: False }
            } else if Utf8.is_cont(bl) {
                # the run reaches offset 0 with no lead
                { cs: l, cp: 0, ok: False }
            } else {
                d = Utf8.decode(b, l)
                if d.ok and l + d.len == pos { { cs: l, cp: d.cp, ok: True } } else { { cs: l, cp: 0, ok: False } }
            }
        }
    }

    ## the byte position `k` symbols after `pos`
    advance : List(U8), U64, U64 -> U64
    advance = |b, pos, k|
        if k == 0 or pos >= List.len(b) { pos + k } else { Utf8.advance(b, pos + (Utf8.decode(b, pos)).len, k - 1) }

    ## the byte position `k` symbols before `pos`
    retreat : List(U8), U64, U64 -> U64
    retreat = |b, pos, k|
        if k == 0 or pos == 0 { pos } else { Utf8.retreat(b, (Utf8.decode_rev(b, pos)).cs, k - 1) }

    ## encode one codepoint
    encode : U32 -> List(U8)
    encode = |cp|
        if cp < 0x80 {
            [cp.to_u8_wrap()]
        } else if cp < 0x800 {
            [(0xC0 + cp.shr_zf_wrap(6)).to_u8_wrap(), (0x80 + cp.bitwise_and(0x3F)).to_u8_wrap()]
        } else if cp < 0x10000 {
            [(0xE0 + cp.shr_zf_wrap(12)).to_u8_wrap(), (0x80 + cp.shr_zf_wrap(6).bitwise_and(0x3F)).to_u8_wrap(), (0x80 + cp.bitwise_and(0x3F)).to_u8_wrap()]
        } else {
            [(0xF0 + cp.shr_zf_wrap(18)).to_u8_wrap(), (0x80 + cp.shr_zf_wrap(12).bitwise_and(0x3F)).to_u8_wrap(), (0x80 + cp.shr_zf_wrap(6).bitwise_and(0x3F)).to_u8_wrap(), (0x80 + cp.bitwise_and(0x3F)).to_u8_wrap()]
        }

    ## a list of codepoints as a `Str` (lossy on the impossible case)
    cps_to_str : List(U32) -> Str
    cps_to_str = |cps|
        List.fold(cps, [], |acc, cp| List.concat(acc, Utf8.encode(cp)))
        |> Str.from_utf8_lossy
}
