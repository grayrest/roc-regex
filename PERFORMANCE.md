# Performance

## The benchmark

`tools/bench/run.sh` times `find_all` over one haystack for ten patterns, on
three engines, and prints the ratios.

The haystack is generated (`tools/bench/src/gen.rs`), 256 KB by default, from a
fixed word bank of Sherlock Holmes vocabulary with numbers, email-shaped tokens
and Greek words injected, plus the literal `Moriarty` once every ~700 tokens.
It is deterministic, so every run and every engine reads the same bytes. It
carries 9900 non-ASCII bytes in 842 runs, which matters below.

Per pattern, each engine compiles once, then runs `find_all` in a loop and
reports nanoseconds per call. Rust runs both its meta engine, the one you get
from `Regex::new`, and its PikeVM from `regex-automata`, so a reader can tell
an algorithmic difference from an implementation one. Match counts are compared
against Rust, and a row whose counts differ is marked `DIFF` and does not
count.

Noise handling, because these rows move 6-12% between runs on the same binary:

- each binary runs five times and the per-pattern minimum is kept, since noise
  only ever inflates a figure;
- a freshly built binary reads about 80% slow on its first run, so there is a
  discarded warm-up run;
- A/B comparisons alternate the two binaries within one session. A blocked
  comparison (all of A, then all of B) read 1.36x for a change that alternated
  at 1.04x.

## Standing

`tools/bench/run.sh`, 2026-10-23, at commit `b56c4d1`, Roc
`release-fast-ec598185`, basic-cli 0.26.0. Nanoseconds per
`find_all` over 256 KB; `sharp/meta` is this engine over Rust's meta engine.

| pattern | sharp ns | rustMeta ns | rustPV ns | sharp/meta | Rust `Regex::new` ns |
|---|---|---|---|---|---|
| `Holmes` | 26539 | 27694 | 3461197 | 0.96x | 42666 |
| `Moriarty` | 9685 | 9928 | 3357240 | 0.98x | 37209 |
| `Sherlock\|Holmes\|…` | 411985 | 425063 | 5323968 | 0.97x | 102208 |
| `[A-Za-z]+` | 1041302 | 2200447 | 7959574 | 0.47x | 74583 |
| `[0-9]{2,4}` | 58831 | 107178 | 3495754 | 0.55x | 154709 |
| `\bthe\b` | 175633 | 188051 | 5479967 | 0.93x | 91583 |
| `\w+\s+\w+` | 1093568 | 1536698 | 8670654 | 0.71x | 540667 |
| `(\w+)@(\w+)` | 62635 | 68617 | 8416293 | 0.91x | 694375 |
| `\p{L}+` | 1260139 | 2055972 | 8124430 | 0.61x | 267500 |
| `.*Holmes` | 238116 | 642980 | 6988553 | 0.37x | 262250 |

All ten match counts agree with Rust. The last column is what Rust pays to
compile each pattern at run time; a folded Roc pattern pays zero. The older
engine in `package-dfa` reads 0.67x to 1.91x Rust and is behind `Regex` on
every row but `Moriarty`, where its literal scan is a few percent faster.

All ten rows are at or below Rust's meta engine, the first time that has held
across the set. The four rows that a scan finds its own starts for —
`[A-Za-z]+`, `[0-9]{2,4}`, `\w+\s+\w+`, `\p{L}+`, the rows where a scan
replaces the reverse sweep — are the four furthest ahead after `.*Holmes`. The
three literal rows read 0.96x to 1.00x from run to run, which is the size of
the noise on these rows and worth remembering before reading anything into a
2% move. The engine is ahead of Rust's PikeVM on every row by a wide margin,
which says only that it is a DFA and the PikeVM is not.

On one tree, two passes of paired runs put `ec598185` at 0.86x to 0.97x of
`10e922df` on every row, which is what took the Teddy row from 1.09x Rust to
0.97x and `\bthe\b` from 1.09x to 0.94x with no change to either scan (log,
2026-10-23).

Against RE# itself, the engine this one ports, `tools/sharp-bench/run.sh`
measured on 2026-09-06 (RE# under .NET in Release with server GC, warmed up so
its JIT and lazy DFA are filled before timing):

| pattern | sharp ns | RE# ns | sharp/RE# |
|---|---|---|---|
| `(\w+)@(\w+)` | 84900 | 648833 | 0.13x |
| `.*Holmes` | 372050 | 993625 | 0.37x |
| `[0-9]{2,4}` | 189800 | 449458 | 0.42x |
| `Moriarty` | 11050 | 25167 | 0.44x |
| `Holmes` | 46650 | 81000 | 0.58x |
| `\bthe\b` | 375300 | 632584 | 0.59x |
| `Sherlock\|Holmes\|…` | 940750 | 1027041 | 0.92x |
| `[A-Za-z]+` | 2590500 | 2385458 | 1.09x |
| `\p{L}+` | 2650700 | 2355583 | 1.13x |
| `\w+\s+\w+` | 2680700 | 2035792 | 1.32x |

That measurement predates both the ordering fix and the class-run sweep, and
the three losses were the dense-class rows. All three have since dropped far
below the RE# column on the bench above — `[A-Za-z]+` to 1041302, `\p{L}+` to
1260139, `\w+\s+\w+` to 1093568 — so the port is ahead of those RE# figures on
all ten. That sets `run.sh` numbers against a `sharp-bench` measurement, so
read it as a direction rather than a ratio. The RE# side has not been
re-measured; it needs `dotnet` and the RE# checkout. RE# also pays 0.4 to 8.9 ms per pattern to
construct at every process start; a folded Roc pattern pays nothing.

## The patterns

What each row exercises and which path the engine takes on it. The path
column is `Regex.accel_str` on the compiled pattern; states and minterms are
the automaton's size after RE#'s rewrites.

| id | pattern | states | minterms | path |
|---|---|---|---|---|
| `literal_dense` | `Holmes` | 15 | 8 | literal override |
| `literal_sparse` | `Moriarty` | 19 | 9 | literal override |
| `teddy_alt` | `Sherlock\|Holmes\|Watson\|Adler\|Irene\|Norton\|Baker\|John` | 69 | 23 | literal set (Teddy) |
| `class_plus` | `[A-Za-z]+` | 5 | 3 | run scan, no sweep (`scan=runs`; `Rrun` also applies and loses by 1.16x) |
| `bounded_num` | `[0-9]{2,4}` | 9 | 3 | class-run sweep (`classrun=x2`); remaining-sets end pass |
| `word_bound` | `\bthe\b` | 12 | 7 | prefix skip on `h` with `t`,`e` as filters; fixed length 3 |
| `two_words` | `\w+\s+\w+` | 9 | 4 | run scan for `\w`, no sweep (`scan=runs`) |
| `caps_email` | `(\w+)@(\w+)` | 9 | 4 | prefix skip on `@` |
| `uni_letters` | `\p{L}+` | 5 | 3 | run scan for `\p{L}`, no sweep (`scan=runs`) |
| `dotstar_lit` | `.*Holmes` | 20 | 9 | prefix skip on `H`; three skipping states |

**`Holmes` and `Moriarty`.** The pattern is exactly a literal, so `find_all`
never runs the automaton. A fused SIMD scan compares 16-byte windows against
the literal's rarest byte and verifies the rest in place. The dense row
(several thousand hits) measures per-match overhead, the sparse row (tens of
hits) measures the scan itself. Both sit at about 1.0x Rust, whose `memmem`
does the same thing. On x86-64 Rust would use 256-bit vectors here and Roc has
only 128-bit ones; on this arm64 machine both are 128-bit, so the comparison is
kernel against kernel.

**The eight-name alternation.** The pattern is a union of literals, so the
engine runs Teddy: a 3-byte fingerprint of every literal packed into nibble
tables, two table lookups per window, a candidate mask, and a verify per
candidate. The literals are ordered longest-first at compile time so the first
to verify at a position is the longest, which is what leftmost-longest needs.
RE#'s own design has no literal-set accelerator (it skips to the eight
capitals); this row is the one place the port added something the original
lacks. 0.97x; it read 1.09-1.14x on `10e922df` with the same scan. Getting
there by hand had not worked: fusing the verify into the scan through a closure
was 70% slower, unrolling four windows was 130% slower from register spills,
and the monomorphic fused scan that shipped bought 4%.

**`[A-Za-z]+` and `\p{L}+`.** Neither has a literal, a skippable class or a
bounded length, so no *forward* accelerator applies, and both record a possible
start at nearly every position (205101 starts for 40056 matches).

Neither runs the reverse sweep any more. Both are `C+` with nothing after it,
so `Runs` scans for the class, runs the end pass from each candidate and
resumes at the match end. 0.47x and 0.61x.

The remaining gap between them is what the class costs the scan. `[A-Za-z]+`
holds no non-ASCII codepoint, so its scan may pass over a multibyte symbol and
a failed candidate skips the rest of its run. `\p{L}+` holds plenty, so its
scan must stop at every multibyte symbol, a failed candidate may only advance
one symbol, and its 9900 non-ASCII bytes go through UTF-8 decode and the class
trie rather than the fused ASCII byte-to-state table.

`[A-Za-z]+` is also the one row both replacements claim: `Rrun` applies too,
and routing it there instead reads 1.16x, so `Runs` takes it.

**`[0-9]{2,4}`.** The end pass is a length lookup (two fixed digits, then up to
two more from the set) rather than a DFA walk, and the reverse pass is now the
class-run sweep: a match can start exactly where two digits do, so the whole
sweep is one scan for digit runs plus arithmetic. 0.55x.

Getting there took three rounds and the middle one was the instructive part.
The row was 1.75x, and the whole difference was the 9900 non-ASCII bytes —
replace them with `x` and it read 0.92x while Rust did not move. Letting the
skip pass over them took it to 1.18x. What was left was not in the scans but
between them: the kernel is 0.08 ns a byte, and the row was 2533 re-entries
into it plus a byte walk over 842 non-ASCII runs, 4554 digit steps and 2863
appends. Three attempts to shave those each won here and lost more on the dense
rows. What actually worked was removing the re-entries altogether, which is
what a sweep with no automaton in it does.

**`\bthe\b`.** Every match contains `the`, so the sweep searches backwards for
`h` and requires `t` and `e` at their offsets in the same window before
leaving the kernel. Word-boundary checking is in the automaton: the prefix
search lands in the state after `the` and the `\b` on each side is a
lookaround resolved by the neighbouring symbol. The end pass is
`FixedLength(3)`, which profiled at 6 µs of the row. 0.93x. The lesson of this
row is that the SIMD kernel was never the cost: one pass over the haystack
counting hits takes 22 µs, and re-entering it per hit cost ~16 ns a call.
Filtering with three bytes cut the re-entries from 13473 to 2394.

**`\w+\s+\w+`.** Was the widest row at 1.33x and is now 0.71x. It has no
literal, no prefix accelerator and no skippable class, so for a long time it
was the two-pass design undiluted: the sweep recorded 210198 starts for 21091
matches, and decomposed into 491 µs of ASCII stepping, 259 µs of nullability
reads, 155 µs of start appends and about a millisecond of forward pass, against
Rust's single pass of 1.55 ms.

What removed it was not making any of those cheaper. `\w+\s+\w+` is
`C+ · rest`, so `Runs` scans for `\w` directly, runs the forward end pass from
each candidate and resumes at the match end — the sweep, the start list and the
210198 appends all stop existing. `\w` holds non-ASCII codepoints, so the scan
must stop at every multibyte symbol and a failed candidate cannot skip the rest
of its run; both cost it, and it still lands below Rust.

**`(\w+)@(\w+)`.** The groups are plain groups here (no captures), and Rust's
`find_iter` does not compute captures either, so both engines do the same
work. Every match contains `@`, which is rare (1157 occurrences), so the sweep
jumps from `@` to `@` and runs the automaton only around each. 0.91x. Short
matches at low density make this the row most sensitive to per-candidate fixed
cost, and it moved 1.29x to 0.97x mostly from removing work done once per
candidate rather than per byte; the current compiler took it to 0.91x.

**`.*Holmes`.** The sweep skips to `H`, verifies `Holmes`, then extends
leftward through `.*`, where the state's skip set contains only `\n` and `H`,
so that is another SIMD skip. 0.37x, the fastest row relative to Rust by a
distance. I have not profiled why Rust is slow here; a leading `.*` defeats
its prefix literal extraction, and it may be scanning forward from every line.

## What limits further gains

In order of how much of the remaining gap each accounts for. The diagnoses
below were made on `release-fast-10e922df` and have not been re-profiled since
the compiler moved to `ec598185`.

### The two-pass design on dense matches

The reverse sweep followed by a forward pass is RE#'s algorithm and the source
of leftmost-longest semantics, boolean operators and lookarounds in DFA states.
On a pattern with a match every few bytes it records a start at most positions
and then walks most of the text a second time. That used to be the whole story
on the dense rows, and **no bench row is made of it any more**: every one of
them either has an accelerator that skips between rare bytes, or has the sweep
replaced outright by a scan that finds its own starts (`Rrun` for one class
repeated, `Runs` for `C+ · rest` — see the design log, 2026-09-07 and
2026-09-11). Nothing about per-byte codegen was ever wrong on those rows: on an
all-ASCII copy of the haystack `[0-9]{2,4}` beat Rust before any of this.

The three structural candidates that were listed here, and what became of
them:

- ~~**Compressing runs of consecutive starts**~~ — **this does not work, and
  the earlier entry here saying it "needs an exactness gate" was wrong.** The
  claim was that only the leftmost of a run of consecutive starts survives
  `ends_fast`. `[a-z][a-z]` on `"aaaa"` refutes it: starts 0, 1, 2 give
  `[0,2)` and `[2,4)`, and compressed to start 0 they give one match. Dropping
  `p+1` is safe, but the run also holds `p+2`, `p+4` … which are the starts of
  the FOLLOWING non-overlapping matches. Over 38 patterns x 18 haystacks, 76
  of 684 cases differ and 40 of those are inside the gate that was about to be
  written — every pattern whose matches tile. `\w+\s+\w+` is not one of them,
  which is why a one-pattern check read "same" and the idea survived here for
  two revisions.
- ~~**A reverse length lookup**~~ — **shipped** (`Rrun`, 2026-09-07). Where the
  reversed pattern is one minterm set repeated `lo..hi` with `lo >= 1` and no
  non-ASCII member, `_*·S{lo,hi}` is nullable at `p` exactly when `lo` symbols
  of `S` start at `p`, so the sweep is one pipelined SIMD scan for runs of `S`
  plus arithmetic on their extents. `[0-9]{2,4}` 1.18x -> 0.59x, `[A-Za-z]+`
  0.85x -> 0.73x, ~2% on three other rows.
- ~~**A forward accelerator for the end pass**~~ — overtaken. What was left of
  `\w+\s+\w+` after `Rrun` could not reach it turned out not to need a
  forward accelerator at all: `Runs` (2026-09-11) replaces the SWEEP for
  `C+ · rest`, which is its shape, and the end pass it already had was enough.
  1.33x -> 0.80x. `Rrun` and `Runs` both stay — removing `Rrun` costs
  `[0-9]{2,4}` 2.06x, because `Runs` excludes bounded repeats on purpose.

### Reference counting of the engine record

Everything above concerns 256 KB haystacks. On short inputs the engine's cost is
fixed per call, and `sample` on a binary doing nothing but the reverse sweep
found where:

| haystack | `roc_llvm_rc_decref_*` | engine code |
|---|---|---|
| 1 byte | 73.8% | 26.2% |
| 256 bytes | 58.8% | 41.2% |

Three quarters of a short sweep is reference counting. The engine record
`Dfa.E` has eighteen fields, fourteen of them lists, with a nested arena
record, and the struct-level decrement routines walk it field by field on
entry and exit of each of the four functions that take it. Those functions
return nothing that contains the record, so the arguments are pure borrows and
the refcount traffic is work the program cannot observe.

Two fixes were built and both were worse or invalid. A narrower record of just
the tables the loops read measured 142-160 ns against 85-100 for the full one,
because it still has to carry the arena and the pending-nullable list and is
constructed per call. A flat-argument version measured 30 ns but had dropped a
code path, so its number is not evidence. The diagnosis stands without a fix,
and the fix has to come from the compiler: borrow inference, or a way to hand a
loop tables it does not walk.

One method note that cost a day: a probe that takes `Dfa.E` and reads one
scalar measures 1 ns, because the compiler elides refcounting when the fields
are unused. A no-op is not a null hypothesis for refcounting.

Where it shows: the non-literal `find` path has ~560 ns of fixed cost on a
300-byte haystack, and `package-http`, which parses HTTP/1.1 requests with this
engine's `longest_end` and `find_all`, is 4.3x off Rust's `httparse` at 1658
ns per request on `ec598185` (5.0x and 2074 ns on `10e922df`) after
everything else was fixed. Everything else was four
per-call setups the 256 KB bench had hidden: a doubled literal (`\r\n\r\n`
rewrites to `(\r\n){2}`) that lost its fixed length and so its literal
override (787 to 63 ns), a recursive nullability walk run once per scan when a
flag already held the answer, Teddy's tables rebuilt on every search of a
literal-set pattern (820-856 ns), and a `Try` tag built per byte in the forward
end pass for a nullable tail (3.87 to 3.10 ns a byte, the only one of the four
that also helped long haystacks).

### One procedure at the edge of its register budget

Roc and LLVM inline a whole scan path into one procedure (23716 bytes, 5929
instructions for `(\w+)@(\w+)`), and it sits at the edge of the register
budget. Any change to it, anywhere, can add spill stores to the innermost loop.
This is the root cause of the 4-26% swings on rows that do not execute the
changed code, which looked like placement effects until `otool` showed the
spill delta.

Measured instances, each on a 256 KB scan:

- adding a two-arm `match` to `Regex.find_all` cost 20% on a pattern taking
  neither arm: the procedure shrank 524 bytes, 48 fewer loads, 29 more stores;
- adding one `Bool` parameter to a small function inlined into a per-byte
  loop, with behaviour pinned identical, cost 13-22%;
- matching a tag union inside a loop to pick behaviour cost 6-14%, and hoisting
  the tag to a local did not help, so it is the payload extraction;
- a `List.fold` with a closure over 262k items copied its captured environment
  per item: 8 ms against 0.5 ms for a `while` over an index;
- a helper that takes the engine record, called per step or per match, costs
  ~100 ns a call when not inlined;
- the identical class lookup called through `Trie.class_of` from another
  module costs 7 ns more per call than written inline in the caller, because
  the call boundary is not inlined.

The rules that came out of this, and that the code follows: hot loops are one
function with tables bound to locals, `while` rather than fold, no closures and
no tag dispatch inside, and a duplicated loop body per variant. New code goes
in a new module, never into a hot one. When a decision must live in a hot
entry point, it is folded into a branch that is already there rather than added
as a new one; that is how the 20% above was recovered. The diagnosis recipe is
in the log: `roc build --keep-temp`, one `_roc__proc_<id>` symbol per
procedure, `sample` for the hot one, `otool -tvV` and a mnemonic histogram for
the spill delta.

### Bounds-checked loads

The per-byte reverse loop makes six bounds-checked loads where Rust's lazy DFA
makes three unchecked ones and a threshold compare. Tagging the transition
table's spare bits with the destination state's nullability and skip flag
would cut it to two loads and one compare, and it was built, encoded
correctly, and was slower in three shapes (1.11-1.18x, 1.04x, 1.02-1.04x).
The last shape removes exactly one load and nothing else, and still loses.
Until Roc has unchecked indexing this lever is closed, and the memory note
says not to re-propose it.

### Kernel re-entry

A SIMD kernel run as one pass over the haystack costs 1.3 ns a window. The
same kernel re-entered per hit costs ~11 ns a window, and the difference
survives hoisting its vectors out of the call and inlining its body entirely.
It is a loop-carried dependency: the next window's address is the previous
hit's position, which comes out of a `clz` of a mask that comes out of a load,
so the machine cannot run ahead. One pass has no such chain and pipelines
eight windows deep.

The consequence is that the lever on a skip-heavy row is the number of times
the scan is left, not the cost of leaving it. `\bthe\b` went from 1.24x to
1.00x by filtering on three bytes instead of one. `[0-9]{2,4}` had no filter to
add — every digit run is a real state change — and was fixed the other way
instead: the reverse length lookup leaves it with no scan to re-enter at all.

### List growth

Pre-sizing the start accumulator is slower in Roc, not faster: 210198 appends
growing from `[]` cost 229 µs, from `List.with_capacity(210198)` 390 µs, and
from a haystack-sized reserve 315 µs. Recorded because it is the opposite of
what one would try first.

### Vector width

Roc exposes 128-bit vectors only. On this arm64 machine Rust's NEON kernels
are also 128-bit, so the literal and Teddy rows compare like for like. On
x86-64 with AVX2 Rust would run 256-bit `memchr` and fat Teddy and this engine
would not, so expect the literal and alternation rows to read worse there.

## Artifact size and the fold

`tools/sharp-size/probe.sh <haystack>` builds one app per pattern under
`/usr/bin/time` and reports build time, compiler RSS, binary size, state count
and whether the fold completed. `tools/sharp-size/breakdown.sh` splits a binary
into code and constant data against a baseline and sums the engine's own
tables from their element counts.

**Folding makes a build faster, not slower.** With `--no-cache` and
`--opt=size`, an app holding one folded complete pattern builds in 2.5-5.1 s at
about 460 MB of compiler RSS. The same app compiling its pattern at run time
takes 28.7 s and 817 MB: the compiler then has to lower the whole pattern
compiler — parser, derivatives, DFA construction — to native code, where a
folded pattern lets all of it be dropped. The exception is a pattern whose
state space depends on the input, such as `a(?=.*b)`: capped at 1024 states it
builds in 11.9 s and 553 MB. Exploring it uncapped reached 13108 states at
+10 s, +4.3 GB and +3.7 MB of binary when measured on 2026-09-05, which is why
the fold stops at 1024 states and the scan extends the table at run time past
that.

`probe.sh` prints 10-13 s and 600-700 MB for the same builds. Each probe app is
new to roc's cache, and a first cached build pays for filling it: one app
measured 9.4 s on its first cached build, 2.5 s with `--no-cache` and 2.1 s on
its second cached build.

**Engine code now varies by pattern.** Against `breakdown.sh`'s `a+` baseline,
a class-run sweep, the code deltas run from -54 KB for `Holmes`, whose literal
override never touches the automaton, and -50 KB for `[0-9]{2,4}`, to +78 KB
for `\bthe\b`. The three run-scan rows are within 1 KB of the baseline and
the other complete folds add 6-11 KB. An incomplete fold keeps the derivative
machinery, the arena constructors and the threaded scan: +498 KB of code. When
this was first measured, on 2026-09-05, every complete fold was within about
5 KB of every other and the scanning engine was a fixed ~225 KB. Which paths
the current compiler drops for which pattern has not been worked out:
`[0-9]{2,4}` takes the same sweep as `a+` and is still 50 KB smaller.

**Per-pattern data is the class trie, and Unicode dominates it.** After the
trie's ids were narrowed to bytes and uniform blocks made to share one
constant leaf, an ASCII pattern's trie is ~10 KB and a `\w` pattern's ~50 KB
(down from 220 KB). Transition tables are 16-bit for complete folds and small:
the largest here is the alternation at 30.8 KB across 69 states.

**Whole binaries are mostly the platform.** basic-cli 0.26 added 1.9 MB to
every binary: on one compiler at `--opt=size`, an empty 0.21 app is 390 KB and
an empty 0.26 app 2.30 MB. Over that, the
regex costs 18 KB for `Holmes`, 104 KB for `[A-Za-z]+`, 221 KB for `\bthe\b`
and 752 KB for the incomplete `a(?=.*b)`.

**A folded structure is stored once, at its data size.** On `84812227`
(2026-09-07) it was stored at ~2.2x: the trie's elements appeared once in
`__TEXT,__const` and a second time in `__DATA_CONST,__const`, while a bare
folded list was stored once (reproducer in
`upstream/2026-09-05-sharp-folded-constant-sections/`). With the current
package the reproducer's `\w+` adds 41216 bytes to `__TEXT,__const` and none to
`__DATA_CONST,__const`, against 41220 bytes of trie growth, on both `10e922df`
and `ec598185`; across `breakdown.sh` the `\p{L}+` row's constant delta equals
its trie delta to the byte. Whether the compiler or a package change removed
the second copy was not isolated.

**Dropping the trie's leaves entirely was tried and is 1.6x slower on
non-ASCII text.** The cut points and per-atom minterms already are the
codepoint map, and a search over them shrank the trie 13x, but the lookup went
from two reads to a loop and the whole bench set ran 1.5-1.6x slower on mixed
scripts. The two-read shape stayed.

## Compiler bugs met along the way

Each has a reproducer under `upstream/`. None was designed around.

- `2026-09-05-sharp-var-list-append`: a `var` list appended both inline and
  inside a helper in one loop corrupts the heap. Layout-dependent, deterministic
  under Guard Malloc. Every append in the scan loops is now inline.
- `2026-09-05-sharp-folded-constant-sections`: the 2.2x artifact storage above.
  Does not reproduce with the current package, on `10e922df` or `ec598185`.
- `2026-09-05-sharp-debug-crashes`: two debug helpers (`show_rev`,
  `derive_chain_rev`) crash on a large lookaround pattern; `find_all` on the
  same pattern is fine.
- `2026-09-06-dfa-crossmodule-sigbus`: `Dfa.find_first_fast` and
  `Dfa.ends_fast` SIGBUS when called directly from an app, and run fine when
  reached through `Regex.find`. This is why the profiling above had to be
  indirect.
- `2026-09-06-two-modules-folded-constant`: an app importing two modules that
  each hold a folded constant panics the compiler.
- `roc build` reports "successfully building" with a non-zero error count and a
  non-zero exit on warnings, so the tools judge success by the produced binary.

## Levers ruled out

Each of these was built and measured, and the result is the reason not to try
it again without new information.

| lever | result |
|---|---|
| byte-alphabet DFA instead of codepoints | UTF-8 expansion multiplied folded states by ~100 in the earlier engine; for ASCII the codepoint overhead is already zero |
| transition-entry tagging (nullability, skip bit in spare `U16` bits) | slower in three shapes; needs unchecked indexing |
| closure-fused Teddy verify | 70% slower |
| 4x-unrolled Teddy scan | 130% slower, register spills |
| a second SIMD kernel, or a stop/pass mask, for the non-ASCII skip | wins the row, taxes three dense rows 3-8%, net loss; rejected twice |
| four-wide scalar walk over non-ASCII runs | same arithmetic, rejected |
| `List.with_capacity` for the start accumulator | slower |
| a narrower tables-only record for the loops | slower, must still carry the arena |
| compressing consecutive starts | WRONG, not merely ungated: a run of starts holds the starts of the following non-overlapping matches too |
| dropping the trie's leaves for a cut-point search | 1.6x slower on non-ASCII |
| converting the threaded (incomplete-fold) scan to byte offsets | 1.3-1.7x slower; the prepared haystack is a cache, not a redundant pass |
| the range kernel for `[0-9]{2,4}` | tried and reverted (log, 2026-09-06) |

## Levers still open

- Unchecked indexing in Roc would reopen transition-entry tagging: two loads
  and one compare per byte instead of six loads.
- Borrow inference, or any way to pass a record of tables without walking it,
  would take most of the fixed per-call cost, which is the whole story on
  short inputs.
- The reverse sweep still runs for every pattern that is not a literal, does
  not have a prefix accelerator and is not `C+ · rest`. Extending the run scan
  past a LEADING unbounded class run — an interior one, or a bounded leading
  one — needs a different closure argument than the one `Accel.class_runs`
  rests on, and no bench row asks for it.
- The ASCII-pass skip is wired only into the plain reverse sweep. The prefix
  sweep and both forward loops have the same shape and did not get it, because
  no bench pattern would use it and each is another perturbation of a hot loop.
- Case-insensitive prefix accelerators: the parser handles `(?i)`, the
  accelerator does not look for folded prefixes.
- Skip sets on the threaded scan for incomplete folds; RE# computes them
  lazily per state and this port computes them only at freeze.

## Tools

| tool | what it measures |
|---|---|
| `tools/bench/run.sh [bytes]` | the table above: `Regex`, `Dfa` (`package-dfa`), Rust meta, Rust PikeVM |
| `tools/sharp-bench/run.sh` | this engine against RE# itself (needs `dotnet` and the RE# checkout) |
| `tools/sharp-size/probe.sh <hay> [size\|speed]` | fold cost, artifact size, ns per `find_all` per pattern |
| `tools/sharp-size/breakdown.sh <hay>` | code vs data per pattern, engine tables summed |
| `tools/http-bench/run.sh` | `package-http` against Rust `httparse` + `matchit` |
| `tools/skip-diff`, `tools/accel-diff` | correctness differentials for the skips and the accelerators, with skips or accelerators forced off as the oracle |
