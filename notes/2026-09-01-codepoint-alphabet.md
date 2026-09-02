# The codepoint alphabet — two studies

Both run 2026-09-01, after the four adversarial reviews. Together they reverse
D3 and retire the two findings that had blocked the build order.

The reviews had established, over a **byte** alphabet: ordinary Unicode patterns
determinize to 0.6–10 MB of table; Unicode `\b` cannot go in a DFA at all; and
folding a 276-character production pattern OOM-killed the compiler. This note is
what changed when the alphabet changed.

## Study A — fold cost over a codepoint alphabet

Rigs: session scratchpad `cp/`, a line-for-line twin of the earlier `q/` rig.
Four differences only: atoms are U32 codepoints; `\w` emits **one** class edge
instead of a 598-instruction `Utf8Sequences` byte-range alternation; the stride
is a real in-Roc equivalence-class pass instead of a fixed 256; and a shared
1,600-entry packed codepoint→class range table is folded alongside every
artifact, so the codepoint column carries its full cost. Baseline empty
basic-cli app: 0.24 s / 136 MB / 390,528 B.

| 276-char pattern | byte alphabet | codepoint alphabet |
|---|---|---|
| `prod_email_uni` | 2.75 s / 1,066 MB / 80,517,360 B | **0.31 s / 140 MB / 456,624 B** |
| `prod_route_uni` | 1.64 s / 790 MB / 44,894,640 B | **0.31 s / 139 MB / 456,624 B** |
| `prod_log_uni` | 0.65 s / 319 MB / 12,916,272 B | **0.33 s / 141 MB / 440,208 B** |
| `prod_ident_uni` | 0.33 s / 160 MB / 1,884,704 B | **0.31 s / 140 MB / 423,792 B** |

Every codepoint build sits at the empty-app floor, so the **200–345×** RSS-excess
ratios and **250–1,490×** artifact ratios are lower bounds, not point estimates.
The mechanism is confirmed by instruction counts rather than inferred:
`(\w+)./(\w+)` + 264 literals is `2×599 + 267 = 1465` instructions byte-side and
`2×2 + 267 = 271` codepoint-side, both measured exactly.

**Caveat on the ASCII control rows:** the byte rig uses a fixed 256 stride with
no equivalence-class compression, so for patterns with no Unicode class the
comparison overstates by roughly the 2.3× byte-class factor measured earlier.
For Unicode patterns it barely matters — the dominant term is instruction count,
which stride does not touch. Read the Unicode ratios as ~125× rather than 250×.

### The ceiling changes kind

| pattern class | byte ceiling (1 GB RSS) | codepoint ceiling |
|---|---|---|
| literal, ASCII classes, nested groups | ≥4,500 chars — **parser stack** | ≥4,500 — parser stack |
| `\w{10,20}` repeated | **≈50 chars** — RSS | ≥4,500 — parser stack |
| Unicode mixed unit repeated | **≈100 chars** — RSS | ≥4,500 — parser stack |
| `\w{500,999}` repeated | **&lt;11 chars** — RSS | ≈1,250 chars — RSS |

Six of seven pattern classes now bind on the **alphabet-independent parser-stack
limit, measured at 4,500–4,600 characters in both alphabets**, with 2.5–5× RSS
headroom. Only unbounded counted repetition still hits memory first.

### The inner loop, which nobody had priced

Six separately-built binaries, one matcher each; identical match counts verified
on every haystack; 4,000,000 codepoints per haystack, generated at runtime so
nothing folds.

| lookup structure | ns/symbol | MB/s vs byte loop (ASCII / mixed / heavy) |
|---|---|---|
| byte: three chained `List.get` | 1.951 ns/B | 1.00 |
| **codepoint, two-level trie + 128-entry ASCII fast path** | **1.957 ns/cp** | **1.00 / 1.12 / 1.73** |
| codepoint, binary search over packed ranges | 14.204 ns/cp | 0.14 / 0.16 / 0.29 |

**The trie costs nothing** — decode and lookup disappear into the bounds-checked
`List.get` chain both loops already pay — and it wins on non-ASCII input because
it iterates once per codepoint rather than once per byte. **Binary search over
the packed range list costs 3.4–7.3×.** So the packed table is the right storage
format and the wrong lookup path; the ASCII fast path is what makes the alphabet
change free. This is a design constraint, not an implementation detail.

**Null result, reported as such:** a rig meant to price the cache benefit of a
472-byte table against a 10 MB one found no difference, because with a single
word class the state trajectory touches ~20 rows and never exercises the
footprint. The locality advantage implied by the state collapse is real and
remains unpriced.

## Study B — Unicode word boundaries, verified against the crate

Prototype: 1,785 lines of Rust in scratchpad `cpdfa/` — `regex-syntax` HIR →
Thompson NFA over codepoint range sets → codepoint equivalence classes →
powerset construction ported rule-for-rule from `util/determinize/mod.rs` →
forward leftmost-first + reverse `MatchKind::All` three-pass search. Oracle:
`regex` 1.13.1 and `regex_automata::meta::Regex` with `Input::range`.

### Why the byte DFA refuses — a guard, not an impossibility

`regex-automata-0.4.18/src/dfa/determinize.rs:216`:

```rust
if self.nfa.look_set_any().contains_word_unicode()
    && !self.config.quit.contains_range(0x80, 0xFF)
{
    return Err(BuildError::unsupported_dfa_word_boundary_unicode());
}
```

The entire word-boundary mechanism is one bit set from an ASCII-only test —
`util/determinize/mod.rs:341` sets `is_from_word` from `Unit::is_word_byte`
(`util/alphabet.rs:171`), whose set is `[0-9A-Za-z_]` (`util/utf8.rs:16`), and
`mod.rs:163-184` then satisfies **both** the ASCII and the Unicode assertion from
it. The crate states the consequence itself, `util/look.rs:863`:

> "We need to mark all ranges of bytes whose pairs result in evaluating `\b`
> differently. This isn't technically correct for Unicode word boundaries, but
> DFAs can't handle those anyway…"

The second reason is structural in the start-state API: `util/start.rs:122` is
`look_behind: Option<u8>` — one byte cannot name the previous codepoint. The
look-behind itself is **bounded at 4 bytes** (`util/look.rs:1593`), so unbounded
look-behind was never the obstacle.

### Results — 4,810,141 checks, 0 disagreements

| suite | patterns | checks | disagreements |
|---|---|---|---|
| curated: 29 patterns × 26 haystacks × every offset + `find_iter` | 29 | 6,902 | **0** |
| `regex-1.13.1/testdata`, 744 of 858 cases, offset sweep | 744 | 4,090 | **0** |
| randomized differential fuzz, 8 seeds × 10,000 patterns | 79,997 | 4,799,149 | **0** |

Including **91 of the 92** `\b{start}`/`\b{end}` cases. Haystacks included
`"héllo wörld"`, `"日本 foo bar"`, `"naïve café"`, `"foo→bar"`, emoji, combining
marks, zero-width space, `Ⅻ` (word in Unicode `\w`, not in ASCII), fullwidth
`ＡＢＣ`, `"β123"`, ASCII controls and CRLF text.

At the blocker:

    "\b\w+\b" on "héllo wörld"
      byte dense DFA (quit set):  Err(MatchError(Quit { byte: 195, offset: 1 }))
      codepoint DFA prototype:    Some((0, 6))
      regex crate (oracle):       Some((0, 6))

### Negative controls — the harness bites

| control | curated | fuzz (358,048 checks) |
|---|---|---|
| Unicode word predicate degraded to ASCII (i.e. the crate's own approximation) | 772 | **26,841** |
| 7 start configs merged back to the crate's 6 | 290 | **9,060** |

A third control earned its place: the first fuzz run showed 394 disagreements,
and an isolation control reproduced them with **no assertions on pure-ASCII
haystacks** — proving the cause had nothing to do with codepoints. It was naive
`x*` compilation; `nfa/thompson/compiler.rs:1250` documents that `x*` must be
compiled as `(x+)?` when `x` can match empty (rust-lang/regex#779). After
porting the real repetition handling: zero.

### The costs, measured

- **Start configurations: 7, not 6.** `WordByte` splits into `AsciiWordChar` and
  `NonAsciiWordChar`. Verified load-bearing by the control above. Determinization
  dedupes 14 slots to ~6 distinct start states in practice.
- **Determinizer state key: one extra bit.** `is_from_word` becomes
  `is_from_word_ascii` + `is_from_word_unicode`, 3 valid combinations, same flag
  byte, `LookSet` widths unchanged. Measured max 15–16 bytes, mean 11.5–11.8.
  It costs **zero states** — the correct build is usually *smaller* than the
  incorrect one (`\b\w+\b`: 12/13 states correct vs 14/17 degraded).
- **Selection:** one `utf8::decode_last` / `decode` at search start instead of a
  byte load, bounded at 4 bytes, using routines `look.rs` already has.
- **All 18 `Look` variants are decidable.** None is category "not representable".

### Sizes, checked in the same run

| pattern | cp states (f+r) | cp classes | cp bytes | byte bytes | ratio |
|---|---|---|---|---|---|
| `\w{10,20}` | 79 | 3 | **1,264** | 19,714,560 | 15,597× |
| `(?i)[\p{L}\p{N}_]{4,12}` | 49 | 3 | 784 | 12,380,160 | 15,791× |
| `\w{5}` | 30 | 3 | 480 | 5,316,096 | 11,075× |
| `[\w.+-]+@[\w-]+\.[\w.]+` | 42 | 7 | 1,344 | 4,950,016 | 3,683× |
| `\b\w+\b` | 25 | 4 | **400** | *no correct byte DFA exists* | — |

State collapse 131–493×, byte collapse 818–15,791×, because the alphabet falls
from 107–119 byte classes to 3–7 codepoint classes and the stride from 128 to 4
or 8. **The largest codepoint table produced anywhere in the run was 1,856
bytes.** Determinization of both directions took 0.03–5.0 ms.

## What this costs — the gap that forced a new decision

A codepoint alphabet has no symbol for an undecodable byte. Verified:
`(?-u:[^a])`, `(?-u:.)` and `(?-u:\b..\b)` compile to byte classes reaching
`0xFF`, and `regex::bytes::Regex` matches the single byte `0xC3` inside `"é"`.
That is not expressible over codepoints. ASCII-only `(?-u)` patterns such as
`(?-u:[a-z])` and `(?-u:\bfoo\b)` are fine and were verified.

About **40 of the 858 corpus cases** sit in this gap — 21 invalid-UTF-8 haystacks
and 19 byte-class patterns. Resolved by D3's amendment: one alphabet, with an
explicit **invalid** symbol class for undecodable bytes.

## Not verified

1. The 7th start configuration (`CustomLineTerminator`) — reasoned only.
2. Anything about invalid UTF-8. The **invalid** symbol class D3 now adopts is
   reasoned, not tested: it implies an 8th start configuration and a third
   look-behind value, because `WordUnicodeNegate`, `WordStartHalfUnicode` and
   `WordEndHalfUnicode` are defined not to match adjacent to undecodable bytes
   (`util/look.rs:1075`, `:1220`, `:1250`). This is M1 work with a test, not an
   open question — but it is untested today.
3. The locality benefit of the small table (study A's null result).
