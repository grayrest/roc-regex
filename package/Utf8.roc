## UTF-8 decoding over `List(U8)` haystacks with the `Invalid` symbol: a
## malformed sequence decodes as one `Invalid` symbol whose extent is the first
## byte plus every continuation byte following it. Well-formedness is
## structural (lead byte, continuation count, no overlongs, no surrogates).
Utf8 := [].{
    Sym : { cp : U32, len : U64, ok : Bool }

    ## decode the symbol starting at byte offset `i`
    decode : List(U8), U64 -> Utf8.Sym
    decode = |b, i| {
        lead = Utf8.at(b, i)
        if lead < 0x80 {
            { cp: lead.to_u32(), len: 1, ok: True }
        } else if lead >= 0xC2 and lead <= 0xDF {
            cont1 = Utf8.at(b, i + 1)
            if Utf8.is_cont(cont1) {
                { cp: lead.bitwise_and(0x1F).to_u32().shl_wrap(6).bitwise_or(Utf8.continuation_bits(cont1)), len: 2, ok: True }
            } else {
                Utf8.invalid(b, i)
            }
        } else if lead >= 0xE0 and lead <= 0xEF {
            cont1 = Utf8.at(b, i + 1)
            cont2 = Utf8.at(b, i + 2)
            lo_ok = if lead == 0xE0 { cont1 >= 0xA0 and cont1 <= 0xBF } else if lead == 0xED { cont1 >= 0x80 and cont1 <= 0x9F } else { Utf8.is_cont(cont1) }
            if lo_ok and Utf8.is_cont(cont2) {
                cp = lead.bitwise_and(0x0F).to_u32().shl_wrap(12).bitwise_or(Utf8.continuation_bits(cont1).shl_wrap(6)).bitwise_or(Utf8.continuation_bits(cont2))
                { cp, len: 3, ok: True }
            } else {
                Utf8.invalid(b, i)
            }
        } else if lead >= 0xF0 and lead <= 0xF4 {
            cont1 = Utf8.at(b, i + 1)
            cont2 = Utf8.at(b, i + 2)
            cont3 = Utf8.at(b, i + 3)
            lo_ok = if lead == 0xF0 { cont1 >= 0x90 and cont1 <= 0xBF } else if lead == 0xF4 { cont1 >= 0x80 and cont1 <= 0x8F } else { Utf8.is_cont(cont1) }
            if lo_ok and Utf8.is_cont(cont2) and Utf8.is_cont(cont3) {
                cp = lead.bitwise_and(0x07).to_u32().shl_wrap(18).bitwise_or(Utf8.continuation_bits(cont1).shl_wrap(12)).bitwise_or(Utf8.continuation_bits(cont2).shl_wrap(6)).bitwise_or(Utf8.continuation_bits(cont3))
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

    continuation_bits : U8 -> U32
    continuation_bits = |x| x.bitwise_and(0x3F).to_u32()

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
    ## backwards.
    decode_rev : List(U8), U64 -> { cs : U64, cp : U32, ok : Bool }
    decode_rev = |b, pos| {
        i = pos - 1
        prev_byte = Utf8.at(b, i)
        if prev_byte < 0x80 {
            { cs: i, cp: prev_byte.to_u32(), ok: True }
        } else {
            l = Utf8.sym_start(b, i)
            start_byte = Utf8.at(b, l)
            if !Utf8.is_cont(start_byte) and start_byte < 0x80 {
                # bare continuation run after an ASCII byte
                { cs: l + 1, cp: 0, ok: False }
            } else if Utf8.is_cont(start_byte) {
                # the run reaches offset 0 with no lead
                { cs: l, cp: 0, ok: False }
            } else {
                d = Utf8.decode(b, l)
                if d.ok and l + d.len == pos {
                    { cs: l, cp: d.cp, ok: True }
                } else if d.ok and l + d.len < pos {
                    # A VALID symbol at `l` that ends STRICTLY before `pos`:
                    # the bytes
                    # between its end and `pos` are a bare continuation run, and
                    # the symbol is not part of it. Returning `l` here reported
                    # the run as starting at the symbol and swallowed it, so the
                    # reverse sweep lost any match ending there -- `\w+` on
                    # `π` followed by a stray `0x80` found nothing at all, while
                    # the reference, the forward scans and `π` followed by
                    # `0xFF` (not a continuation byte, so a different branch)
                    # all found `π`.
                    #
                    # The bound has to be strict. A `pos` INSIDE a symbol has
                    # `l + d.len > pos`, and returning that would hand a reverse
                    # scan a position ahead of where it started; the corpus
                    # segfaulted on it.
                    { cs: l + d.len, cp: 0, ok: False }
                } else {
                    { cs: l, cp: 0, ok: False }
                }
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
