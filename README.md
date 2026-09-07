# roc-regex

A regular expression engine for Roc, compiled while your program builds.

A pattern written as a string literal is compiled during `roc build`: the
finished automaton and its lookup tables are stored in the binary, and nothing
is parsed or compiled when the program runs. A pattern built at run time goes
through the same function and compiles then. There is no macro, no code
generator and no build step; the compiler's evaluation of pure functions does
the work.

The engine is the `Sharp` module in [`package/`](package/). It is a port of
[RE#](https://github.com/ieviev/resharp), a derivative-based matcher, which
gives it a different feel from Perl-style engines:

- **Leftmost-longest matches.** `a|ab` on `ab` matches `ab`. Perl, Rust and
  JavaScript would match `a`.
- **Set operators.** `&` is intersection, `~(…)` is complement, `_` matches
  any character. `_*cat_*&_*dog_*` is a string containing both words, in
  either order; `~(_*\d\d_*)` is a string with no two consecutive digits.
- **Lookarounds** `(?=…)`, `(?!…)`, `(?<=…)`, `(?<!…)` and `\b`, in a
  restricted form that keeps matching linear.
- **No captures, no lazy quantifiers, no backreferences.** `(…)` only groups.
  A match is a pair of byte offsets.
- **Throughput near Rust's `regex` crate** on a 256 KB prose benchmark, and
  zero compile cost at run time. See [Benchmarks](#benchmarks) and
  [PERFORMANCE.md](PERFORMANCE.md).

Correctness rests on three oracles: RE#'s own 331-case corpus, a brute-force
reference interpreter fuzzed at 18000 cases with zero divergences, and a
differential against RE# running under .NET. Where RE# was found to be wrong,
the engine gives the textbook answer and the divergence is listed.

## Example

[`examples/readme.roc`](examples/readme.roc):

```roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	re: "../package/main.roc",
}
import pf.Stdout
import re.Sharp

# A literal pattern is compiled while the program builds, and the finished
# automaton is stored in the binary. A pattern that does not parse fails the
# build with a message and a caret under the offending character.
email : Sharp.T
email = Sharp.unwrap(Sharp.compile("\\w+@\\w+\\.\\w+"))

# `&` is intersection: a line that mentions both names, in either order.
both : Sharp.T
both = Sharp.unwrap(Sharp.compile(".*Holmes.*&.*Watson.*"))

main! = |_args| {
	text = "Watson wrote to holmes@baker.st; Holmes replied from 221b@baker.st."
	bytes = Str.to_utf8(text)

	# Every non-overlapping match, as half-open byte offsets into `bytes`.
	addresses = List.map(Sharp.find_all(email, bytes), |sp| Str.from_utf8_lossy(List.sublist(bytes, { start: sp.start, len: sp.end - sp.start })))
	Stdout.line!(Str.join_with(addresses, ", "))?

	# `$0` in the replacement is the matched text.
	Stdout.line!(Sharp.replace_all_str(email, text, "<$0>"))?

	Stdout.line!(if Sharp.is_match_str(both, text) { "mentions both" } else { "does not mention both" })?
	Ok({})
}
```

```
holmes@baker.st, 221b@baker.st
Watson wrote to <holmes@baker.st>; Holmes replied from <221b@baker.st>.
mentions both
```

Two things to know about the build-time compile:

- It happens for a top-level definition whose argument is a literal. The same
  call inside `main!` runs at run time, with the same result and the same
  speed once compiled.
- `Sharp.unwrap` crashes with the rendered error when compilation fails. At
  build time that crash is a build failure, which is the point: a typo in a
  pattern is caught before the program exists.

```
sharp: unclosed group
  | a(b
  |  ^
```

## How matching works

A pattern names a set of strings. `[0-9]{2,4}` is every string of two to four
digits; `.*Holmes.*&.*Watson.*` is every line that contains both names.
Searching means finding substrings of the haystack that belong to the set, and
this engine reports the leftmost one, extended as far as it will go, then
continues after it.

Most engines do this by simulating a nondeterministic automaton (Rust's
`regex`, RE2, Go) or by backtracking (Perl, PCRE, JavaScript). This one uses
Brzozowski derivatives, following RE# (Varatalu et al.,
[POPL 2025](https://dl.acm.org/doi/abs/10.1145/3704837)).

### Derivatives

The derivative of a pattern by a character is the pattern for what is left to
match after that character.

| pattern | character | derivative |
|---|---|---|
| `abc` | `a` | `bc` |
| `abc` | `x` | `⊥`, the empty set: no match continues from here |
| `a*b` | `a` | `a*b` |
| `[0-9]{2,4}` | `7` | `[0-9]{1,3}` |
| `a\|ab` | `a` | `ε\|b`: the empty string, or `b` |
| `A&B` | `c` | (derivative of `A`) `&` (derivative of `B`) |
| `~(A)` | `c` | `~(`derivative of `A)` |

A pattern is *nullable* when it matches the empty string. If the pattern you
are holding after consuming some characters is nullable, those characters are
a match. The last two rows are why intersection and complement are cheap here
and absent from most engines: they distribute through the derivative, so a
state can hold `A&B` as easily as `A`.

### States are patterns

Every distinct pattern reached by taking derivatives is a state of a
deterministic automaton (DFA), and the transition on a character is the
derivative. Two things keep the number of states finite and small. Patterns
are interned in an arena, so structurally equal patterns are the same node.
And every constructor normalizes: alternations are flattened, sorted and
deduplicated, `ε|R` becomes `R?`, `a{2}a{3}` becomes `a{5}`, a branch that is
subsumed by another is dropped, and so on through RE#'s rewrite rules, ported
one for one. `\w+\s+\w+` has 9 states; the eight-name alternation in the
benchmark has 69.

### The alphabet

The automaton does not step on codepoints, let alone bytes. The pattern's
character sets partition all codepoints into *minterms*, the classes the
pattern can tell apart. `[0-9]{2,4}` has three: digits, everything else, and
the class for malformed UTF-8. The transition table is states by minterms. A
haystack byte reaches its minterm through a small trie: for ASCII the trie is
fused with the transition table into one byte-to-next-state lookup per state,
and a non-ASCII sequence is decoded and looked up in a two-level table.

The alphabet is codepoints rather than bytes on purpose. A byte-level DFA has
to encode UTF-8 structure in its states, and in an earlier engine in this
repository 99% of a Unicode pattern's states were that bookkeeping.

### Finding matches: sweep backwards, then extend forwards

`find_all` is RE#'s `llmatch`:

1. **The reverse sweep.** Reverse the pattern, prefix it with `_*`, and run
   that automaton from the end of the haystack toward the start. Wherever the
   state is nullable, a match of the original pattern can begin at that
   position. Record it.
2. **The forward end pass.** Walk the recorded starts left to right. From
   each, run the forward automaton until it reaches `⊥`, remembering the last
   position where it was nullable: that is the longest match from that start.
   Skip every recorded start inside that match, since matches do not overlap,
   and continue from its end.

Leftmost-longest falls out: the sweep knows every possible start, so the
forward pass only extends from real ones and never has to guess where a match
begins. The price is two passes over the text on patterns that match densely.
On `\w+\s+\w+` over prose the sweep records 210198 possible starts for 21091
matches, and that two-pass structure is where the remaining gap to Rust sits.

### Skipping

At compile time, after the rewrites, the engine derives accelerators from the
node graph (so they see through `&` and `~`) and stores them beside the tables:

- A pattern that is exactly a literal never runs the automaton: `find_all` is
  a SIMD substring search.
- A union of up to eight literals runs Teddy, a SIMD multi-literal scan,
  followed by a verify.
- When every match begins with a fixed run of symbols, the sweep searches
  backwards for the rarest byte of that run (with up to two more bytes of the
  run as filters), verifies the rest, and lands in the state after it.
  `(\w+)@(\w+)` jumps from `@` to `@`.
- A state that only a rare set of bytes can leave skips to the nearest such
  byte with a SIMD byte-set search. `.*` skips to the next newline.
- When every match has one length, or a fixed prefix plus a bounded tail, the
  forward pass is arithmetic instead of a DFA walk.

### Anchors, boundaries and lookarounds

`^`, `$`, `\A` and `\z` are nodes whose nullability depends on where in the
input the automaton is (start, middle, end). `\b` is rewritten into lookarounds
over the neighbouring symbol. A lookahead is carried inside a state: it counts
symbols since the position it is checking and resolves once its body is
decided. A body of bounded length keeps the state space finite; `a(?=.*b)`
does not, which is why the build-time exploration stops at 1024 states and
lets the scan extend the table at run time.

### Build time and run time

`Sharp.compile` parses, builds the node graph, computes the minterms, and
explores every reachable state up to the cap. When Roc evaluates that call
during the build, the transition tables, class trie and accelerator tables
become constants in the binary, and the parser and derivative code are
dead-code-eliminated from a binary whose every pattern folded completely. A
complete fold adds no measurable build time.

An incomplete fold (a lookahead of unbounded length) ships its node arena too.
A scan that reaches an unexplored transition computes the derivative there
and extends its table; past 100000 states it evicts back to the folded prefix
and continues, so memory is bounded and the answer is never wrong. Each call
starts from the folded prefix unless the caller threads the extended pattern
through `find_all_grow`.

## Benchmarks

`tools/bench/run.sh` times `find_all` over a generated 256 KB haystack of
English prose with numbers, addresses and Greek words mixed in, for ten
patterns, against the vendored Rust `regex` 1.13 crate. Each pattern is
compiled once, outside the timing loop, on both sides. Match counts are
checked against Rust. The figure kept is the per-pattern minimum over five
runs. Apple M1, Roc `release-fast-5f9a6e18`, 2026-09-07.

| pattern | Sharp ns | Rust meta ns | Sharp / Rust | what it exercises |
|---|---|---|---|---|
| `Holmes` | 27250 | 26572 | 1.03x | literal search, dense hits |
| `Moriarty` | 10150 | 9801 | 1.04x | literal search, rare hits |
| `Sherlock\|Holmes\|Watson\|…` (8 names) | 466450 | 422045 | 1.11x | Teddy multi-literal scan |
| `[A-Za-z]+` | 1925750 | 2195412 | 0.88x | bare automaton, dense matches |
| `[0-9]{2,4}` | 126000 | 108010 | 1.17x | byte-set skipping |
| `\bthe\b` | 203150 | 203697 | 1.00x | prefix search plus word boundaries |
| `\w+\s+\w+` | 1968000 | 1541489 | 1.28x | bare automaton, no accelerator |
| `(\w+)@(\w+)` | 66250 | 67813 | 0.98x | prefix search on a rare byte |
| `\p{L}+` | 2009250 | 2047656 | 0.98x | Unicode class, non-ASCII decoding |
| `.*Holmes` | 304450 | 641115 | 0.47x | prefix search plus newline skipping |

Read this as "the same neighbourhood as Rust", not "faster than Rust". Five of
ten rows are at or below Rust's meta engine, two more are within 5%, and the
widest is 1.28x. The
engine is a DFA with SIMD prefilters, as Rust's is, and where the same
accelerator fires on both sides the rows land within a few percent. Where
this engine is behind, it is running its two passes over text that Rust
covers in one; where it is ahead, its reverse sweep is skipping between rare
bytes that Rust's forward scan cannot use.

Two costs the table does not show. Rust's `Regex::new` takes 17 to 690 µs per
pattern here at every process start, and RE# 0.4 to 8.9 ms; a folded Roc
pattern takes none. And on short inputs this engine's per-call fixed cost is
the dominant term; [PERFORMANCE.md](PERFORMANCE.md) has that measurement, the
per-pattern analysis, and what limits further gains.

## Syntax reference

### Reading a pattern

Most characters match themselves: `Holmes` matches exactly those six
characters. Everything else is built from single-character matchers and
operators. From tightest to loosest binding: a quantifier applies to the atom
before it; adjacent atoms match in sequence; `&` intersects; `|` alternates.
So `ab|cd` is `(ab)|(cd)` and `a|b&c` is `a|(b&c)`. Parentheses group.

### One character

| syntax | matches |
|---|---|
| `a` | the character `a` |
| `.` | any character except newline |
| `_` | any character at all, newline included |
| `\n` `\t` `\r` `\f` `\v` `\e` `\a` `\0` | newline, tab, carriage return, form feed, vertical tab, escape, bell, NUL |
| `\x41` | the codepoint given by two hex digits |
| `\u0041`, `\u{1F600}` | the codepoint given by four hex digits, or by up to six in braces |
| `\.` `\*` `\(` `\\` `\&` `\_` … | the punctuation character itself |

Escaping a letter that has no meaning (`\q`) is an error rather than a silent
literal.

### Character classes

| syntax | matches |
|---|---|
| `[abc]` | one of `a`, `b`, `c` |
| `[a-z]` | one codepoint in the range, inclusive |
| `[^abc]` | one character that is not `a`, `b` or `c` (newline included) |
| `[\d_\p{Greek}a-f]` | classes, escapes and ranges combine inside brackets |
| `\d` `\D` | a decimal digit in any script, per Unicode, or anything else |
| `\w` `\W` | a word character (letters, digits, marks, connectors, per Unicode), or anything else |
| `\s` `\S` | whitespace, per Unicode, or anything else |
| `\p{L}` `\P{L}` | a codepoint with the property, or without it |

A `]` first in the brackets is literal (`[]a]`), and so is a trailing `-`
(`[a-]`). The Unicode tables are the Rust `regex` crate's. Properties
available to `\p{…}`: general categories `L` (`Letter`), `Lu`, `Ll`, `N`
(`Number`), `Nd`, `P` (`Punctuation`), `Sm`, `Zs`, and scripts `Greek`,
`Latin`, `Cyrillic`, `Han`.

### Repetition

| syntax | matches the atom |
|---|---|
| `a*` | zero or more times |
| `a+` | one or more times |
| `a?` | zero or one time |
| `a{3}` | exactly three times |
| `a{3,}` | three or more times |
| `a{3,5}` | three to five times |

Greedy and lazy have no meaning under leftmost-longest matching: the match is
the longest one whatever the quantifier, so `a*?` is accepted and means `a*`.
Quantifiers stack: `a**` is `(a*)*`. `{,5}` is an error.

### Combining

| syntax | meaning |
|---|---|
| `ab` | `a` then `b` |
| `a\|b` | `a` or `b` |
| `a&b` | a string that is both an `a` and a `b` |
| `~(a)` | any string that is not an `a`; the parentheses are required |
| `(a)`, `(?:a)`, `(?<name>a)` | grouping, all equivalent; nothing is captured |

`&` and `~` are where this engine earns its keep. Some idioms, from RE#'s
documentation:

| pattern | matches |
|---|---|
| `_*a_*` | any string containing `a` |
| `~(_*a_*)` | any string not containing `a` |
| `_*cat_*&_*dog_*` | contains both `cat` and `dog` |
| `(_*a_*)&~(_*b_*)` | contains `a` and not `b` |
| `_*cat_*&_*dog_*&_{5,30}` | contains both, and is 5 to 30 characters long |
| `c...&...s` | a four-letter word starting with `c` and ending with `s` |
| `~(_*\n\n_*)` | a single paragraph: no blank line inside |

Prefer `_*` to `.*` inside a complement: `~(.*xyz.*)` means "no `xyz` on this
line", which matches any string with a newline in it.

### Anchors

| syntax | matches the empty string |
|---|---|
| `^` | at the start of a line: at the start of input, or right after a `\n` |
| `$` | at the end of a line: at the end of input, or right before a `\n` |
| `\A` | at the start of the input |
| `\z` | at the end of the input |
| `\b` | at a word boundary: between a `\w` character and a `\W` one, or an edge |

`^` and `$` are always line anchors. There is no multiline flag because there
is no single-line mode. To match the whole input, write `\A…\z`.

`\B` (not a word boundary) is rejected, as in RE#. `\b` must have a character
matcher next to it (`\b` alone is an error).

### Lookarounds

| syntax | matches the empty string when |
|---|---|
| `(?=a)` | an `a` follows |
| `(?!a)` | no `a` follows |
| `(?<=a)` | an `a` precedes |
| `(?<!a)` | no `a` precedes |

Lookarounds live inside automaton states, which is what keeps matching linear,
and that works only in RE#'s normal form: a lookbehind at the start of a
branch, a lookahead at its end, `\b` anywhere, and intersections of such
branches. `(?<=ab)cd(?=ef)` is fine, and so is
`(?<=author).*&.*and.*`. Rejected, with a message saying so:

- a lookaround in the middle of a branch: `a(?=bb)b`. Fold the tail into the
  lookaround instead, `ab(?=b)`;
- a lookaround inside a lookaround body, or inside `~(…)`;
- a union of branches that start with different lookbehinds;
- something that can be empty before a lookbehind, `\b` or `^`:
  `\s*\bword\b`. RE# accepts this and returns a match that swallows the
  prefix; here it is an error.

Because there are no captures, `(?<=ab)cd(?=ef)` is also how you get the
effect of one capture group: the match is `cd`, with `ab` and `ef` checked
but not included.

### Flags

`(?i)` at the very start of the pattern, or `(?i:…)` around part of it, makes
that part case-insensitive using Unicode simple case folding. Every other
flag (`(?s)`, `(?m)`, `(?x)`, `(?U)`, `(?-i)`) and a `(?i)` anywhere but the
start are errors, so a pattern cannot silently mean something else. `.`
already excludes newline and `^`/`$` are already per line, so `s` and `m`
have nothing to switch.

### What a match is

- **Leftmost, then longest.** Of all substrings in the pattern's set, the one
  that starts earliest wins, and among those the longest. `a|ab` on `ab` is
  `[0,2)`. Perl and Rust prefer the first alternative and would answer
  `[0,1)`.
- **Non-overlapping.** After a match ending at `e`, the next match starts at
  or after `e`.
- **Empty matches are reported.** A pattern that can match the empty string
  matches at every position where nothing longer does, including at the end
  of the previous match: `.*(?=aaa)` on `baaa` gives `[0,1)` and `[1,1)`.
  `a*` on `bbb` gives four empty matches.
- **Offsets are bytes, spans are half-open.** Haystacks are `List(U8)`; the
  `_str` functions convert a `Str` for you and hand back a `Str`.
- **Malformed UTF-8 is one symbol per bad run.** A bad lead byte and the
  continuation bytes after it form one symbol that matches only `_` and the
  inside of a complement, never `.` or a class. Match boundaries never land
  inside a multi-byte character, so slicing the haystack at a span is safe.

### Limits

| limit | value | what happens past it |
|---|---|---|
| pattern length | 1000 tokens | compile error |
| group nesting | 250 | compile error |
| distinct character classes | 63 | compile error |
| states explored at build time | 1024 | the scan extends the table at run time |
| states minted at run time | 100000 | the scan evicts to the folded prefix and continues |

## API reference

Everything is in the `Sharp` module. Haystacks are `List(U8)` and every
search function has a `_str` twin that takes a `Str`. The byte API is the real
one; the `Str` twins call `Str.to_utf8` and convert results back with
`Str.from_utf8_lossy`.

### Types

```roc
Sharp.T          # a compiled pattern; a record whose fields are documented-unstable
Sharp.Span : { start : U64, end : U64 }   # half-open byte offsets
Err.Error : { pattern : Str, at : [Whole, At(Err.Span)], kind : Err.Kind }
```

`Err.Kind` is a tag union you can match on: `GroupUnclosed`, `GroupUnopened`,
`ClassUnclosed`, `ClassRangeInvalid`, `RepetitionMissing`,
`RepetitionCountUnclosed`, `RepetitionCountInvalid`, `EscapeUnrecognized`,
`EscapeUnexpectedEof`, `ComplementNeedsGroup`, `FlagUnsupported`,
`Unsupported(Str)` for RE#'s rejections (their messages are RE#'s own),
`PatternTooLong`, `NestLimitExceeded` and `TooManyClasses`, the last three
carrying `{ limit, given }`.

### Compiling

```roc
Sharp.compile : Str -> Try(Sharp.T, Err.Error)
Sharp.unwrap : Try(Sharp.T, Err.Error) -> Sharp.T
Sharp.unwrap_labeled : Str, Try(Sharp.T, Err.Error) -> Sharp.T
Sharp.err_str : Err.Error -> Str          # one line, for logs
Err.render : Err.Error -> Str             # the message, the pattern, a caret
Err.message : Err.Kind -> Str             # the bare sentence
```

`unwrap` crashes with `Err.render`'s output; `unwrap_labeled` prefixes a label
so a build with many patterns says which one failed. Use them for literal
patterns, where the crash is a build failure. For a run-time pattern, match on
the `Try`.

### Searching

```roc
Sharp.is_match    : Sharp.T, List(U8) -> Bool
Sharp.find        : Sharp.T, List(U8) -> Try(Sharp.Span, [NoMatch])
Sharp.find_all    : Sharp.T, List(U8) -> List(Sharp.Span)
Sharp.count       : Sharp.T, List(U8) -> U64
Sharp.replace_all : Sharp.T, List(U8), List(U8) -> List(U8)
Sharp.split       : Sharp.T, List(U8) -> List(List(U8))

Sharp.is_match_str, find_str, find_all_str, count_str : … Str …
Sharp.replace_all_str : Sharp.T, Str, Str -> Str
Sharp.split_str : Sharp.T, Str -> List(Str)
```

`find_all` returns every non-overlapping leftmost-longest match in order.
`find` is its first span. `replace_all` replaces every match with the
replacement, in which `$0` is the matched text and `$$` is a literal `$`;
there is nothing else to reference. `split` returns the text between matches,
keeping leading and trailing empty fields, so there is always one more field
than matches.

What each costs, because the algorithm makes them unequal:

| function | work |
|---|---|
| `find_all`, `count`, `replace_all`, `split` | the full reverse sweep and forward pass |
| `find` | the full reverse sweep (the leftmost start is not known until the sweep reaches the haystack start), then one forward extension. A pure literal pattern is a forward substring search instead |
| `is_match` | the reverse sweep stops at the first start it records, verifies it forwards, and falls back to a full search only if that start has no end. On a haystack that matches near its end this is constant time |

### Anchored matching

```roc
Sharp.first_end   : Sharp.T, List(U8) -> Try(U64, [NoMatch])
Sharp.longest_end : Sharp.T, List(U8) -> Try(U64, [NoMatch])
```

Both match the pattern anchored at offset 0 of the haystack and return where
the shortest, or the longest, such match ends, with no reverse sweep at all.
They are the building block for parsers that step through a buffer piece by
piece: call them on a slice, and the slice is the whole input as far as `\A`,
`\z`, `\b` and lookbehinds are concerned. A pattern that matches the empty
string answers `Ok(0)`, so a caller stepping a sequence must check that it made
progress; an answer equal to the slice length means the match ran to the edge
and might extend given more input. [`package-http/`](package-http/) frames
HTTP/1.1 requests this way.

### Incomplete folds

```roc
Sharp.is_complete      : Sharp.T -> Bool
Sharp.n_states         : Sharp.T -> U64
Sharp.find_all_grow    : Sharp.T, List(U8) -> (Sharp.T, List(Sharp.Span))
Sharp.with_runtime_cap : Sharp.T, U64 -> Sharp.T
```

`is_complete` says whether compilation explored every reachable state. When
it did not (an unbounded lookahead such as `a(?=.*b)`), every search starts
from the folded prefix and re-derives states as it goes. `find_all_grow` also
returns the pattern with every state the search minted, so a caller looping
over haystacks can thread it and pay for each state once. `with_runtime_cap`
sets the eviction threshold (default 100000 states).

### Introspection

```roc
Sharp.show      : Sharp.T -> Str          # the pattern after rewrites, in RE#'s notation
Sharp.minterms  : Sharp.T -> List(Str)    # the alphabet classes the pattern distinguishes
Sharp.accel_str : Sharp.T -> Str          # which accelerators compiled in
Sharp.n_nodes   : Sharp.T -> U64
```

The rest of the module's exports (`find_all_ref`, `find_all_plain`,
`find_all_noskip`, `find_all_threaded`, `match_starts`, `der1`,
`derive_chain`, …) are oracles and tracing hooks for the test tools. They are
documented in [`package/Sharp.roc`](package/Sharp.roc) and are not part of
the interface a program should depend on.

## The rest of the repository

| path | what |
|---|---|
| [`package/`](package/) | the `Sharp` engine. [`package/README.md`](package/README.md) lists its modules and the commands that check it |
| [`package-dfa/`](package-dfa/) | `Regex`, the engine this repository started with: a port of Rust's `regex` crate with leftmost-first semantics and captures. Frozen; it is the Rust-semantics oracle and a second data point for Roc codegen |
| [`package-http/`](package-http/) | HTTP/1.1 framing and matchit-syntax routing built on `Sharp`'s public API |
| [`examples/`](examples/) | this README's example, the benchmark drivers, smoke tests |
| [`tools/`](tools/) | the benchmark, the RE# and Rust differentials, the fuzzer, the artifact-size probes |
| [`plans/`](plans/), [`notes/`](notes/) | the design records and the measurement log. [`plans/2026-09-05-package-sharp.md`](plans/2026-09-05-package-sharp.md) is the engine's design; [`notes/2026-09-05-package-sharp-design-log.md`](notes/2026-09-05-package-sharp-design-log.md) is every decision and number since |
| [`upstream/`](upstream/) | reproducers for the Roc compiler bugs found along the way |
| [PERFORMANCE.md](PERFORMANCE.md) | the benchmark in depth, and what limits the engine |

Checking the engine, from the repository root:

```bash
python3 tools/sharp-corpus/gen.py > /tmp/c.roc && roc build /tmp/c.roc && /tmp/c a b
```

runs RE#'s 331-case corpus through four engines and cross-checks them;
`package/README.md` has the fuzz, differential, size and benchmark commands.
