## The reverse sweep, replaced, for patterns shaped `C+ · rest`
## (`Accel.class_runs` carries the soundness argument, `Dfa.Scan` the data).
##
## This lives outside `Dfa` on purpose. It only calls into `Dfa`, but putting it
## THERE cost 11-26% on `caps_email`, `.*Holmes` and the two literal rows --
## none of which execute it -- purely through code layout, the same effect that
## moved the literal-set dispatch out of `Dfa` in M4.
import Bset
import Deriv
import Dfa
import Trie
import Utf8

Runs := [].{
    ## For `C+ · rest` the starts can be scanned for directly, so this finds a
    ## candidate with `Bset`, runs the forward end pass from it, and resumes at
    ## the match end: one loop, no start list, no sweep.
    ##
    ## The end pass is `Dfa.ends_fast`'s general branch, but it always runs the
    ## WHOLE pattern from `s_noprefix`. Every length lookup presupposes that the
    ## start is genuine, because the sweep proved it; this scan proves only that
    ## the first symbol is in `C`, so a `PrefixEnd(k, st)` that skips `k` symbols
    ## and resumes mid-pattern invents matches -- `\s{2,}` reported a two-space
    ## match at a lone space, and `\w+[^a][ab]*` one starting at an invalid byte.
    ## Verifying from the top costs the `k` symbols it used to skip, which is 1
    ## for both rows this path serves.
    ##
    ## A candidate that fails lets the REST of its `C` run be skipped: every
    ## later position in the run would fail too. That step is the one that needs
    ## `exact` -- a `C` whose scan counts non-ASCII bytes as members would run
    ## the skip past a true start.
    find_all_runs : Dfa.E, Trie.T, Dfa.Scan, List(U8), Bool, Bool -> List({ start : U64, end : U64 })
    find_all_runs = |e, t, scan, hay, skip, first_only| {
        n = List.len(hay)
        at = e.atable
        nk_table = e.st_nk
        # an empty table when skipping is off, as the other scans do: `List.get
        # ?? 0` then never says 1, and the loop carries no Bool
        skip_ok = if skip { e.skip_ok } else { [] }
        skip_lo = e.skip_lo
        table = e.table
        minterm_count = e.minterm_count.to_u64()
        s_start = e.s_noprefix
        class_tab = match scan { ClassRuns(c) => c.tab, NoScan => [] }
        class_stops = match scan { ClassRuns(c) => c.stops, NoScan => True }
        complement_tab = match scan { ClassRuns(c) => c.ctab, NoScan => [] }
        class_exact = match scan { ClassRuns(c) => c.exact, NoScan => False }
        var $spans = []
        var $pos = 0
        var $running = n > 0
        while $running {
            candidate =
                if class_stops {
                    Bset.find(hay, class_tab, 0, $pos)
                } else {
                    Bset.find_ascii(hay, class_tab, 0, $pos)
                }
            match candidate {
                Err(_) => {
                    $running = False
                }
                Ok(start) => {
                    # `best` as a U64 with a sentinel, not `Try(U64, [NoEnd])`:
                    # a nullable tail is nullable at EVERY position, so a tag
                    # would be built once per byte (design log, the end pass).
                    var $best = Dfa.no_end
                    if start >= n {
                        $best = Dfa.to_pos(Dfa.at_eoi_fast(e, s_start, hay, n, Err(NoEnd)))
                    } else {
                        var $scan_pos = start
                        var $s = s_start
                        if start == 0 and Dfa.flags(e, s_start).bitwise_and(Dfa.fl_anchor_null) != 0 and Deriv.nullable(e.a, Deriv.loc_begin, Dfa.st_node_of(e, s_start)) {
                            $best = 0
                        }
                        while $s != Dfa.dead {
                            byte_before_skip = List.get(hay, $scan_pos) ?? 0
                            skip_kind = List.get(skip_ok, $s.to_u64()) ?? 0
                            # `skip_kind` of 2 says the state loops on every
                            # non-ASCII symbol as well, so the scan may pass one
                            # rather than stop at it (`Dfa.skip_sets`)
                            if skip_kind != 0 and !(byte_before_skip >= 0x80 and skip_kind == 1) and !Bset.member_ascii(skip_lo, $s.to_u64(), byte_before_skip) {
                                $scan_pos =
                                    match (if skip_kind == 1 { Bset.find(hay, skip_lo, $s.to_u64(), $scan_pos + 1) } else { Bset.find_ascii(hay, skip_lo, $s.to_u64(), $scan_pos + 1) }) {
                                        Ok(q) => q
                                        Err(_) => n - 1
                                    }
                            }
                            k = List.get(nk_table, $s.to_u64()) ?? Dfa.nk_notnull
                            if k == Dfa.nk_current {
                                $best = $scan_pos
                            } else if k == Dfa.nk_prev {
                                $best = Utf8.retreat(hay, $scan_pos, 1)
                            } else if k != Dfa.nk_notnull {
                                $best = Dfa.to_pos(Dfa.null_fallback_fast(e, $s, hay, $scan_pos, Dfa.from_pos($best)))
                            }
                            b = List.get(hay, $scan_pos) ?? 0
                            if b < 0x80 {
                                $s = (List.get(at, $s.to_u64() * 128 + b.to_u64()) ?? Dfa.dead_u16).to_u32()
                                $scan_pos = $scan_pos + 1
                            } else {
                                d = Utf8.decode(hay, $scan_pos)
                                cp_class = if d.ok { Trie.class_of(t, d.cp) } else { t.invalid }
                                $s = List.get(table, $s.to_u64() * minterm_count + cp_class.to_u64()) ?? Dfa.dead
                                $scan_pos = $scan_pos + d.len
                            }
                            if $scan_pos >= n {
                                $best = Dfa.to_pos(Dfa.at_eoi_fast(e, $s, hay, n, Dfa.from_pos($best)))
                                $s = Dfa.dead
                            }
                        }
                    }
                    match Dfa.from_pos($best) {
                        Ok(end_pos) => {
                            $spans = List.append($spans, { start, end: end_pos })
                            $pos = if end_pos > start { end_pos } else { start + 1 }
                            if first_only { $running = False }
                        }
                        Err(_) => {
                            # no match here, so none later in this run of `C`
                            $pos =
                                if class_exact {
                                    match Bset.find(hay, complement_tab, 0, start) {
                                        Ok(q) => if q > start { q } else { start + 1 }
                                        Err(_) => n
                                    }
                                } else {
                                    b = List.get(hay, start) ?? 0
                                    if b < 0x80 { start + 1 } else { start + (Utf8.decode(hay, start)).len }
                                }
                        }
                    }
                    if $pos >= n { $running = False }
                }
            }
        }
        $spans
    }
}
