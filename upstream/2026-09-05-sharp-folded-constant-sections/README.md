# A large folded structure costs ~2.2x its data size, split across two sections

Roc `release-fast-84812227`, macOS arm64, `--opt=size`. Numbers re-measured
after the trie in this repo was made byte-wide; the ratio is what matters and
it did not change.

## What we expected

A compile-time-folded regex stores its codepoint-class trie as flat
`List(U32)` tables. `fld_ascii.roc` (`[A-Za-z]+`) and `fld_word.roc` (`\w+`)
differ only in that class, and print their own table lengths. The difference
between them is 50024 `U32` elements, so 200096 bytes.

## What we measured

    size -m fld_ascii ; size -m fld_word

| section | `[A-Za-z]+` | `\w+` | delta |
|---|---|---|---|
| `__TEXT,__const` | 33376 | 74608 | +41232 |
| `__DATA_CONST,__const` | 55728 | 96376 | +40648 |
| `__TEXT,__text` | 441952 | 442988 | +1036 |

The two deltas are within 1.5% of each other, which is the whole point: the
same table is charged twice, once per section.

Each section grows by about the size of the table, so the pattern costs
roughly twice the data it holds. The excess scales with the table rather than
being a fixed overhead.

The excess is not the source tables the trie was derived from. Those live in
`package-sharp/Uni.roc` as hex strings totalling 62328 bytes for the whole
module, of which `\w` is 9552.

Sampling 512-byte blocks of `__TEXT,__const` that contain at least 24 distinct
byte values, so that a coincidental match on repetitive data is excluded, 14 of
52 appear verbatim in `__DATA_CONST,__const`. So the two sections overlap in
content, partially.

## Control: a folded list on its own does not do this

`flat_big.roc` folds a bare `List(U32)` of 50000 elements and reads it at a
runtime index. `rec_in_record.roc` wraps the same list in a record, and a
nested-record variant behaves identically.

| app | `__TEXT,__const` | `__DATA_CONST,__const` |
|---|---|---|
| bare `List(U32)`, n=50000 | 16488 | 206752 |
| same list inside a record | 16488 | 206752 |
| same list nested two deep | 16488 | 206752 |

Exactly 4 bytes per element, all of it in `__DATA_CONST,__const`, none in
`__TEXT,__const`, and record nesting changes nothing. Sweeping n confirms the
rate: n=1000 gives 10752, n=20000 gives 86752, n=50000 gives 206752.

So the simple case is stored once, at exactly its data size, in one section.
The folded regex is stored across both, at about 2.2x. What in the larger
structure triggers the second copy is not established here.

## Why it matters

Every folded pattern pays this, and it is the dominant term for any pattern
using a Unicode class. On the bench set a `\w` pattern's binary is about 824 KB against a 725 KB
baseline, and roughly half of that increase is the duplicate rather than the
table.

## Repro

    roc build --opt=size fld_ascii.roc && roc build --opt=size fld_word.roc
    size -m fld_ascii ; size -m fld_word

`tools/sharp-size/breakdown.sh` in this repo reports the same split per
pattern across the whole bench set.
