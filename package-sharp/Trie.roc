## The codepoint → minterm map (S9, log "Conventions").
##
## S1's cut-point partition (every range endpoint of every pattern set) gives
## atoms; atoms are then grouped by their membership signature over the pattern's
## sets into MINTERMS — RE#'s alphabet compression — so `\w+` costs 2 classes,
## not ~1400. S2's two-level trie (128-entry ASCII fast path, `cp >> 8` index,
## adjacent-deduped 256-wide leaves) stores minterm ids directly. The last
## minterm is D8's `Invalid` symbol, which no pattern set contains.
##
## Every folded artifact is a flat list of scalars (D12 rule 3).
Trie := [].{
    T : {
        ascii : List(U32),
        l1 : List(U32),
        leaves : List(U32),
        # minterm count, INCLUDING the trailing Invalid class
        n_classes : U32,
        # the Invalid class id (= n_classes - 1)
        invalid : U32,
        # one U64 tset per input set: bit m set iff minterm m ⊆ set
        set_tsets : List(U64),
        # for pretty-printing a tset: the cut points and each atom's minterm
        cuts : List(U32),
        mt_of_atom : List(U32),
    }

    ## Build from a flat `sets` table (each set `[neg, count, lo, hi, ...]`).
    ## Fails when the pattern needs more than 63 non-Invalid minterms.
    build : List(U32) -> Try(Trie.T, [TooManyClasses(U64)])
    build = |sets| {
        cuts = Trie.cut_points(sets)
        n_atoms = List.len(cuts) - 1
        n_sets = Trie.count_sets(sets, 0, 0)
        # signature per atom: membership across the sets, as a List(U8)
        g = Trie.upto(n_atoms)
            |> List.fold({ sigs: [], mt_of_atom: [] }, |st, a| {
                rep = List.get(cuts, a) ?? 0
                sig = Trie.signature(sets, n_sets, rep)
                match List.find_first_index(st.sigs, |s| s == sig) {
                    Ok(m) => { ..st, mt_of_atom: List.append(st.mt_of_atom, m.to_u32_wrap()) }
                    Err(_) => { sigs: List.append(st.sigs, sig), mt_of_atom: List.append(st.mt_of_atom, (List.len(st.sigs)).to_u32_wrap()) }
                }
            })
        n_mt = List.len(g.sigs)
        if n_mt > 63 {
            Err(TooManyClasses(n_mt))
        } else {
            set_tsets = Trie.upto(n_sets)
                |> List.map(|si| List.fold_with_index(g.sigs, 0.U64, |acc, sig, m|
                    if (List.get(sig, si) ?? 0) == 1 { acc.bitwise_or(1.U64.shl_wrap(m.to_u8_wrap())) } else { acc }))
            arrays = Trie.build_arrays(cuts, g.mt_of_atom)
            n_classes = (n_mt + 1).to_u32_wrap()
            Ok({ ascii: arrays.ascii, l1: arrays.l1, leaves: arrays.leaves, n_classes, invalid: n_classes - 1, set_tsets, cuts, mt_of_atom: g.mt_of_atom })
        }
    }

    count_sets : List(U32), U64, U64 -> U64
    count_sets = |sets, i, n|
        match List.get(sets, i) {
            Err(_) => n
            Ok(_) => {
                count = (List.get(sets, i + 1) ?? 0).to_u64()
                Trie.count_sets(sets, i + 2 + count * 2, n + 1)
            }
        }

    # membership of codepoint `rep` in each set, in set order
    signature : List(U32), U64, U32 -> List(U8)
    signature = |sets, n_sets, rep| Trie.sig_loop(sets, 0, n_sets, rep, [])

    sig_loop : List(U32), U64, U64, U32, List(U8) -> List(U8)
    sig_loop = |sets, i, remaining, rep, acc|
        if remaining == 0 {
            acc
        } else {
            neg = (List.get(sets, i) ?? 0) == 1
            count = (List.get(sets, i + 1) ?? 0).to_u64()
            inr = Trie.scan(sets, i + 2, count, rep)
            take = if neg { !inr } else { inr }
            Trie.sig_loop(sets, i + 2 + count * 2, remaining - 1, rep, List.append(acc, if take { 1 } else { 0 }))
        }

    ## Sorted, deduped cut points bounding the atoms. Atom a covers
    ## [cuts[a], cuts[a+1]).
    cut_points : List(U32) -> List(U32)
    cut_points = |sets| {
        raw = Trie.collect_cuts(sets, 0, [0, 0x11_0000])
        Trie.dedup_sorted(List.sort_with(raw, |a, b| U32.order_relative_to(a, b)))
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

    scan : List(U32), U64, U64, U32 -> Bool
    scan = |sets, at, count, cp|
        if count == 0 {
            False
        } else {
            lo = List.get(sets, at) ?? 0
            hi = List.get(sets, at + 1) ?? 0
            if cp >= lo and cp <= hi { True } else { Trie.scan(sets, at + 2, count - 1, cp) }
        }

    # --- trie arrays (S2), storing minterm ids ---------------------------------

    Arrays : { ascii : List(U32), l1 : List(U32), leaves : List(U32) }

    build_arrays : List(U32), List(U32) -> Trie.Arrays
    build_arrays = |cuts, mt_of_atom| {
        mt = |cp| List.get(mt_of_atom, (Trie.atom_of(cuts, cp)).to_u64()) ?? 0
        ascii = Trie.upto(128) |> List.map(|cp| mt(cp.to_u32_wrap()))
        n_blocks = 0x110000 // 256
        st = Trie.upto(n_blocks)
            |> List.fold({ l1: [], leaves: [], prev: [], count: 0 }, |s, h| {
                block = Trie.leaf_block(cuts, mt_of_atom, h)
                if s.count > 0 and block == s.prev {
                    { ..s, l1: List.append(s.l1, s.count - 1) }
                } else {
                    { l1: List.append(s.l1, s.count), leaves: List.concat(s.leaves, block), prev: block, count: s.count + 1 }
                }
            })
        { ascii, l1: st.l1, leaves: st.leaves }
    }

    leaf_block : List(U32), List(U32), U64 -> List(U32)
    leaf_block = |cuts, mt_of_atom, h| {
        base = (h * 256).to_u32_wrap()
        Trie.upto(256) |> List.map(|low| List.get(mt_of_atom, (Trie.atom_of(cuts, base + low.to_u32_wrap())).to_u64()) ?? 0)
    }

    ## [0, 1, ..., n-1] as U64.
    upto : U64 -> List(U64)
    upto = |n| Trie.upto_loop(n, 0, [])

    upto_loop : U64, U64, List(U64) -> List(U64)
    upto_loop = |n, i, acc| if i >= n { acc } else { Trie.upto_loop(n, i + 1, List.append(acc, i)) }

    ## minterm of a codepoint at runtime: ascii fast path, else two-level trie.
    class_of : Trie.T, U32 -> U32
    class_of = |t, cp|
        if cp < 128 {
            List.get(t.ascii, cp.to_u64()) ?? 0
        } else {
            block = List.get(t.l1, cp.shr_zf_wrap(8).to_u64()) ?? 0
            List.get(t.leaves, block.to_u64() * 256 + cp.bitwise_and(0xFF).to_u64()) ?? 0
        }

    ## the codepoint ranges of minterm `m` (for printing), merged.
    ranges_of : Trie.T, U32 -> List({ lo : U32, hi : U32 })
    ranges_of = |t, m| {
        n_atoms = List.len(t.mt_of_atom)
        Trie.upto(n_atoms)
        |> List.fold([], |acc, a|
            if (List.get(t.mt_of_atom, a) ?? 0) == m {
                lo = List.get(t.cuts, a) ?? 0
                hi = (List.get(t.cuts, a + 1) ?? 0x11_0000) - 1
                match List.last(acc) {
                    Ok(r) if r.hi + 1 == lo => List.append(List.drop_last(acc, 1), { lo: r.lo, hi })
                    _ => List.append(acc, { lo, hi })
                }
            } else {
                acc
            })
    }
}
