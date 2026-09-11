## Symbolic character sets over the pattern's minterms: a `U64` bitset with
## bit `i` set when minterm `i` is in the set. This is RE#'s `UInt64Solver`; a
## pattern with more than 64 minterms is rejected at compile time. `n` is the
## minterm count and fixes the `full` mask.
TSet := [].{
    ## mask of the low `n` bits
    full : U32 -> U64
    full = |n|
        if n >= 64 { 0xFFFF_FFFF_FFFF_FFFF } else { 1.U64.shl_wrap(n.to_u8_wrap()) - 1 }

    bit : U32 -> U64
    bit = |i| 1.U64.shl_wrap(i.to_u8_wrap())

    is_empty : U64 -> Bool
    is_empty = |s| s == 0

    is_full : U64, U32 -> Bool
    is_full = |s, n| s == TSet.full(n)

    inter : U64, U64 -> U64
    inter = |x, y| x.bitwise_and(y)

    union : U64, U64 -> U64
    union = |x, y| x.bitwise_or(y)

    compl : U64, U32 -> U64
    compl = |x, n| TSet.full(n).bitwise_and(x.bitwise_not())

    ## minterm `i` in `s`
    contains : U64, U32 -> Bool
    contains = |s, i| s.bitwise_and(TSet.bit(i)) != 0

    ## RE#'s `elemOfSet pred loc_pred`: the two sets intersect
    intersects : U64, U64 -> Bool
    intersects = |x, y| x.bitwise_and(y) != 0

    ## `small` ⊆ `large` (RE#'s `Solver.containsSet larger smaller`)
    subset : U64, U64 -> Bool
    subset = |small, large| small.bitwise_and(large) == small

    ## number of set bits
    count : U64 -> U32
    count = |s| s.count_one_bits().to_u32()

    ## index of the lowest set bit (s != 0)
    lowest : U64 -> U32
    lowest = |s| s.count_trailing_zero_bits().to_u32()
}
