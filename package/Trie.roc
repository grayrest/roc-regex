## S1 + S2 — the codepoint equivalence-class partition and the two-level class
## trie that maps a codepoint to its class in O(1).
##
## The partition (S1) is the finest set of atoms such that every pattern class is
## a union of whole atoms: collect every range endpoint, sort, dedup. The trie
## (S2) is three flat arrays (D12 rule 3: no nested structure in the artifact) —
## a 128-entry ASCII fast path, a `cp >> 8` level-1 index, and 256-wide leaf
## blocks deduped adjacent-only (D12 rule 4). Class 0 is "no atom / dead".
Trie := [].{
    ## Built classes: the trie arrays plus, per Char set, a bitset over atoms.
    ## `n_classes` counts atoms; `set_bits` words per set = ceil(n_classes/32).
    T : {
        ascii : List(U32),
        l1 : List(U32),
        leaves : List(U32),
        n_classes : U32,
        accepts : List(U32),
        set_words : U64,
    }

    ## Build the partition and trie from a program's flat `sets` table (each set
    ## is `[neg, count, lo, hi, ...]`), and the accept-bitset for each set.
    build : List(U32) -> Trie.T
    build = |sets| {
        cuts = Trie.cut_points(sets)
        n = List.len(cuts) - 1
        n_classes = n.to_u32_wrap()
        set_words = (n + 31) // 32
        accepts = Trie.build_accepts(sets, cuts, set_words)
        arrays = Trie.build_arrays(cuts)
        { ascii: arrays.ascii, l1: arrays.l1, leaves: arrays.leaves, n_classes, accepts, set_words }
    }

    ## Sorted, deduped cut points bounding the atoms. Atom a covers
    ## [cuts[a], cuts[a+1]).
    cut_points : List(U32) -> List(U32)
    cut_points = |sets| {
        raw = Trie.collect_cuts(sets, 0, [0, 0x11_0000])
        Trie.dedup_sorted(List.sort_with(raw, U32.compare))
    }

    collect_cuts : List(U32), U64, List(U32) -> List(U32)
    collect_cuts = |sets, i, acc|
        match List.get(sets, i) {
            Err(_) => acc
            Ok(_neg) => {
                count = (List.get(sets, i + 1) ?? 0).to_u64()
                after = Trie.collect_ranges(sets, i + 2, count, acc)
                Trie.collect_cuts(sets, i + 2 + count * 2, after)
            }
        }

    collect_ranges : List(U32), U64, U64, List(U32) -> List(U32)
    collect_ranges = |sets, at, count, acc|
        if count == 0 {
            acc
        } else {
            lo = List.get(sets, at) ?? 0
            hi = List.get(sets, at + 1) ?? 0
            hi1 = if hi >= 0x10_FFFF { 0x11_0000 } else { hi + 1 }
            Trie.collect_ranges(sets, at + 2, count - 1, List.concat(acc, [lo, hi1]))
        }

    dedup_sorted : List(U32) -> List(U32)
    dedup_sorted = |xs|
        List.fold(xs, [], |acc, x|
            if (List.last(acc) ?? 0xFFFF_FFFF) == x and !List.is_empty(acc) { acc } else { List.append(acc, x) })

    ## atom id of a codepoint: largest a with cuts[a] <= cp.
    atom_of : List(U32), U32 -> U32
    atom_of = |cuts, cp| Trie.atom_search(cuts, cp, 0, List.len(cuts) - 1)

    atom_search : List(U32), U32, U64, U64 -> U32
    atom_search = |cuts, cp, lo, hi|
        if hi - lo <= 1 {
            lo.to_u32_wrap()
        } else {
            mid = (lo + hi) // 2
            if (List.get(cuts, mid) ?? 0) <= cp {
                Trie.atom_search(cuts, cp, mid, hi)
            } else {
                Trie.atom_search(cuts, cp, lo, mid)
            }
        }

    # per-set accept bitset over atoms
    build_accepts : List(U32), List(U32), U64 -> List(U32)
    build_accepts = |sets, cuts, set_words| Trie.accepts_loop(sets, cuts, set_words, 0, [])

    accepts_loop : List(U32), List(U32), U64, U64, List(U32) -> List(U32)
    accepts_loop = |sets, cuts, set_words, i, acc|
        match List.get(sets, i) {
            Err(_) => acc
            Ok(neg) => {
                count = (List.get(sets, i + 1) ?? 0).to_u64()
                bits = Trie.set_bitset(sets, i, cuts, set_words)
                Trie.accepts_loop(sets, cuts, set_words, i + 2 + count * 2, List.concat(acc, bits))
            }
        }

    # one set's bitset: atom a is accepted iff (cuts[a] in ranges) XOR neg
    set_bitset : List(U32), U64, List(U32), U64 -> List(U32)
    set_bitset = |sets, i, cuts, set_words| {
        neg = (List.get(sets, i) ?? 0) == 1
        n_atoms = List.len(cuts) - 1
        words0 = List.repeat(0.U32, set_words)
        Trie.upto(n_atoms)
        |> List.fold(words0, |w, a| {
            rep = List.get(cuts, a) ?? 0
            inr = Trie.in_ranges(sets, i, rep)
            take = if neg { !inr } else { inr }
            if take { Trie.set_bit(w, a.to_u32_wrap()) } else { w }
        })
    }

    in_ranges : List(U32), U64, U32 -> Bool
    in_ranges = |sets, i, cp| {
        count = (List.get(sets, i + 1) ?? 0).to_u64()
        Trie.scan(sets, i + 2, count, cp)
    }

    scan : List(U32), U64, U64, U32 -> Bool
    scan = |sets, at, count, cp|
        if count == 0 {
            False
        } else {
            lo = List.get(sets, at) ?? 0
            hi = List.get(sets, at + 1) ?? 0
            if cp >= lo and cp <= hi { True } else { Trie.scan(sets, at + 2, count - 1, cp) }
        }

    set_bit : List(U32), U32 -> List(U32)
    set_bit = |w, a| {
        wi = (a // 32).to_u64()
        bit = 1.U32.shl_wrap((a % 32).to_u8_wrap())
        cur = List.get(w, wi) ?? 0
        List.set(w, wi, cur.bitwise_or(bit)) ?? w
    }

    ## does set `si` (its bitset) accept atom `a`?
    accepts_atom : Trie.T, U32, U32 -> Bool
    accepts_atom = |t, si, a| {
        base = si.to_u64() * t.set_words
        wi = base + (a // 32).to_u64()
        bit = 1.U32.shl_wrap((a % 32).to_u8_wrap())
        (List.get(t.accepts, wi) ?? 0).bitwise_and(bit) != 0
    }

    # --- trie arrays (S2) -----------------------------------------------------
    #
    # ascii[128] direct; l1[cp>>8] -> leaf-block index; leaves[block*256 + low].
    # Leaf blocks are deduped adjacent-only: a block equal to its predecessor
    # reuses it (D12 rule 4).

    Arrays : { ascii : List(U32), l1 : List(U32), leaves : List(U32) }

    build_arrays : List(U32) -> Trie.Arrays
    build_arrays = |cuts| {
        ascii = Trie.upto(128) |> List.map(|cp| Trie.atom_of(cuts, cp.to_u32_wrap()))
        n_blocks = 0x110000 // 256
        st = Trie.upto(n_blocks)
            |> List.fold({ l1: [], leaves: [], prev: [], count: 0 }, |s, h| {
                block = Trie.leaf_block(cuts, h)
                if s.count > 0 and block == s.prev {
                    { ..s, l1: List.append(s.l1, s.count - 1) }
                } else {
                    { l1: List.append(s.l1, s.count), leaves: List.concat(s.leaves, block), prev: block, count: s.count + 1 }
                }
            })
        { ascii, l1: st.l1, leaves: st.leaves }
    }

    leaf_block : List(U32), U64 -> List(U32)
    leaf_block = |cuts, h| {
        base = (h * 256).to_u32_wrap()
        Trie.upto(256) |> List.map(|low| Trie.atom_of(cuts, base + low.to_u32_wrap()))
    }


    ## [0, 1, ..., n-1] as U64.
    upto : U64 -> List(U64)
    upto = |n| Trie.upto_loop(n, 0, [])

    upto_loop : U64, U64, List(U64) -> List(U64)
    upto_loop = |n, i, acc| if i >= n { acc } else { Trie.upto_loop(n, i + 1, List.append(acc, i)) }

    ## class of a codepoint at runtime: ascii fast path, else two-level trie.
    class_of : Trie.T, U32 -> U32
    class_of = |t, cp|
        if cp < 128 {
            List.get(t.ascii, cp.to_u64()) ?? 0
        } else {
            block = List.get(t.l1, cp.shr_zf_wrap(8).to_u64()) ?? 0
            List.get(t.leaves, block.to_u64() * 256 + cp.bitwise_and(0xFF).to_u64()) ?? 0
        }
}
