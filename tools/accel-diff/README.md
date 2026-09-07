# Accelerator differential

Every accelerator is a claim that the stretch it jumps over holds no match.
`Sharp.find_all_plain` runs the same automaton with `Accel.none` — no literal
override, no prefix or potential-start scan, no length lookup, no skips — so it
decides all of those claims at once, and the two must return identical spans on
every input.

```bash
tools/accel-diff/run.sh [haystack_bytes]     # default 262144
```

Written for the third byte in `Rlit.rfind_pair2`'s scan window (design log,
2026-09-07). Sibling of [`tools/skip-diff`](../skip-diff/README.md), which
turns the per-state skips off and leaves the accelerators ON: that is the other
axis, and neither subsumes the other.

The 31 patterns are chosen for which accelerator they select, which
`Accel.run_of` and `Accel.pick_anchor` decide from the pattern's sets: a pure
literal takes the override; a literal run behind `\b` takes a prefix scan with
a rare-byte pair, and a third byte when its anchor is common enough
(`\bthe\b` does, `Holmes` does not); a leading `.*` takes a potential start; a
non-ASCII run makes the anchor hit land inside a symbol. Two patterns with no
accelerator at all ride along as controls.

Each runs over twelve haystacks: the 256 KB bench haystack, the same with a
lone continuation byte (`0x80`) and with an invalid byte (`0xFF`) at every
997th position, the same with non-ASCII flattened to `x`, and eight short ones.
The stride is coprime with 16 so the damaged bytes land at every alignment of
the SIMD windows the scans read.

Spans compare by count and by a positional checksum, so a reordering or a
shifted bound fails as loudly as a missing match. `run.sh` exits non-zero on
any divergence.

## It has teeth

Checked by breaking the scan three ways and confirming this catches each
(2026-09-07, at 372 cases):

| break | result |
|---|---|
| the second partner's distance off by one | 310/372 |
| the pair's direction inverted | 301/372 |
| a partner load that would cross an edge made a REQUIREMENT rather than skipped | 365/372 |

**The eight short haystacks exist because of that third row.** A partner load
is skipped when it would cross the start or end of the haystack, and the window
then keeps every lane — the partner filters, it never requires. Those are the
only two windows where that fallback is reachable, and none of the four 256 KB
haystacks happens to put a match in either of them: with only those, breaking
the fallback read a clean 124/124. The short haystacks put a match in the first
and the last 16-byte window on purpose.
