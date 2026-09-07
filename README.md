# roc-regex

A regular expression library for Roc. Matches patterns against a list of bytes.

There are two novelties: the engine is a pure function so Roc's constant folding can
compile the pattern at build time (including syntax checking) while other engines do
the compilation at runtime. The other unsual feature is that this engine uses
[RE#](https://github.com/ieviev/resharp) engine's matching algorithm which offers a
slighly different feautre set:

- **Leftmost-longest matches.** `a|ab` on `ab` matches `ab`. Perl, Rust and
  JavaScript would match `a`.
- **Additional Wildcard** `.` is any utf-8 codepoint except newline while `_` is ANY byte.
- **Set operators.** `&` is intersection, `~(…)` is complement`. So *cat.*&.*dog.*`
  is a string containing both words on a single line, in either order;
  `~(_*\d\d_*)` is a string with no two consecutive digits.
- **Lookarounds** `(?=…)`, `(?!…)`, `(?<=…)`, `(?<!…)` and `\b`, in a restricted
  form that keeps matching linear.
- **No captures, no lazy quantifiers, no backreferences.** `(…)` only groups.
  Capture use cases have support through other mechanisms. The other two are
  incompatible with the algorithm.

The main reason is speed. This originally ported Rust's `regex` crate, which
is still available in `./package-dfa` but the RE# approach turned out to be
better on every metric (speed, startup, output size) outside of som adversarial
edge cases.

This library is a LLM driven port of the `regex` crate and RE#. Credit for the
clever parts go entirely to them. This is a purely deriviative implementation
with no novel research.

## Example

[`examples/readme.roc`](examples/readme.roc):

```roc
app [main!] {
	pf: # basic-cli ...
	re: "./package/main.roc",
}
import pf.Stdout
import re.Regex

# A literal pattern is compiled while the program builds, and the finished
# automaton is stored in the binary. A pattern that does not parse fails the
# build with a message and a caret under the offending character.
email : Regex.Pattern
email = Regex.build("\\w+@\\w+\\.\\w+")

# `&` is intersection: a line that mentions both names, in either order.
both : Regex.Pattern
both = Regex.build(".*Holmes.*&.*Watson.*")

main! = |_args| {
	text = "Watson wrote to holmes@baker.st; Holmes replied from 221b@baker.st."
	bytes = Str.to_utf8(text)

	# Every non-overlapping match, as half-open byte offsets into `bytes`.
	addresses = List.map(Regex.find_all(email, bytes), |sp| Str.from_utf8_lossy(List.sublist(bytes, { start: sp.start, len: sp.end - sp.start })))
	Stdout.line!(Str.join_with(addresses, ", "))?

	# `$0` in the replacement is the matched text.
	Stdout.line!(Regex.replace_all_str(email, text, "<$0>"))?

	Stdout.line!(if Regex.is_match_str(both, text) { "mentions both" } else { "does not mention both" })?
	Ok({})
}
```

```
holmes@baker.st, 221b@baker.st
Watson wrote to <holmes@baker.st>; Holmes replied from <221b@baker.st>.
mentions both
```

Build-time compilation will not happen in an effectful context. In the above
example the `Regex.build` are top level assignments. If the calls were in
`main!` the pattern matching table is built in memory at runtime. There's no
difference in behavior between the two once the call returns.

`Regex.build` crashes on a syntax error in the pattern. At compile time this
surfaces as a build error.

## How matching works

Most engines match patterns by simulating a nondeterministic automaton (Rust's
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

A pattern is *nullable* when it matches the empty string. If the derivative you
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

1. **The reverse sweep.** Reverse the pattern, prefix it with `.*`, and run
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
matches, and that two-pass structure is what the widest row in the benchmark
below is made of.

It is not always two passes over an automaton, though. When the whole pattern
is one class repeated, a match can begin exactly where that class's minimum
number of symbols does, so step 1 collapses into a single SIMD scan for runs of
the class and some arithmetic on their extents — `[0-9]{2,4}` and `[A-Za-z]+`
are the two rows furthest AHEAD of Rust for that reason.

### Skipping

Regex engines, particularly Rust's, are very highly tuned so matching perf
also involves special casing common use cases alongside the the main engine.
At pattern compile time, after the rewrites, the engine derives accelerators
from the node graph (so they see through `&` and `~`) and stores them beside
the main scan tables:

- A pattern that is exactly a literal never runs the automaton: `find_all` is
  a SIMD substring search.
- A union of up to eight literals runs Teddy, a SIMD multi-literal scan,
  followed by a verify.
- When every match begins with a fixed run of symbols, the sweep searches
  backwards for the rarest byte of that run with up to two more bytes of the
  run as filters, verifies the rest, and lands in the state after it.
  In the pattern `(\w+)@(\w+)` the scanner jumps from `@` to `@` and verifies
  the two word patterns at each point.
- A state that only a rare set of bytes can leave skips to the nearest such
  byte with a SIMD byte-set search. `.*` skips to the next newline.
- When every match has one length, or a fixed prefix plus a bounded tail, the
  forward pass is arithmetic instead of a DFA walk.
- When the whole pattern is one class repeated, the reverse sweep is not an
  automaton at all. A match can begin exactly where the class's minimum number
  of symbols does, so the pass is one SIMD scan for runs of the class plus
  arithmetic on their extents: no automaton steps, and nothing that makes the
  scan stop and restart. `[0-9]{2,4}` and `[A-Za-z]+` take this.

### Anchors, boundaries and lookarounds

`^`, `$`, `\A` and `\Z` are nodes whose nullability depends on where in the
input the automaton is (start, middle, end). `\b` is rewritten into lookarounds
over the neighbouring symbol. A lookahead is carried inside a state: it counts
symbols since the position it is checking and resolves once its body is
decided. A body of bounded length keeps the state space finite; `a(?=.*b)`
does not, which is why the build-time exploration stops at 1024 states and
lets the scan extend the table at run time.

### Build time and run time

`Regex.compile` parses, builds the node graph, computes the minterms, and
explores every reachable state up to the cap. When Roc evaluates that call
during the build, the transition tables, class trie and accelerator tables
become constants in the binary, and the parser and derivative code are
dead-code-eliminated from a binary whose every pattern folded completely. A
complete fold adds milliseconds to the build time.

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

| pattern | Roc ns | Rust ns | Roc / Rust | what it exercises |
|---|---|---|---|---|
| `Holmes` | 28350 | 27027 | 1.05x | literal search, dense hits |
| `Moriarty` | 10250 | 9969 | 1.03x | literal search, rare hits |
| `Sherlock\|Holmes\|Watson\|…` (8 names) | 479750 | 425248 | 1.13x | Teddy multi-literal scan |
| `[A-Za-z]+` | 1613400 | 2205824 | 0.73x | one class repeated: no reverse automaton |
| `[0-9]{2,4}` | 64250 | 108872 | 0.59x | the same, over a sparse class |
| `\bthe\b` | 209300 | 204994 | 1.02x | prefix search plus word boundaries |
| `\w+\s+\w+` | 2055750 | 1544425 | 1.33x | bare automaton, no accelerator |
| `(\w+)@(\w+)` | 67350 | 68611 | 0.98x | prefix search on a rare byte |
| `\p{L}+` | 2007550 | 2061462 | 0.97x | Unicode class, non-ASCII decoding |
| `.*Holmes` | 313550 | 644285 | 0.49x | prefix search plus newline skipping |

This engine is generally in the same ballpark as Rust's. Five of ten rows are
at or below Rust's engine, three more are within 5%, and the widest is 1.33x.
`\bthe\b` sits at parity and reads either side of 1.00 between runs. Both
engines are DFA with SIMD prefilters, and where the same accelerator fires on
both sides the rows land within a few percent. Where this engine is behind, it
is running its two passes over text that Rust covers in one. Where it is ahead,
either the reverse sweep is skipping between rare bytes that Rust's forward
scan cannot use, or the pattern is one class repeated and there is no reverse
automaton to run at all.

Two costs the table does not show. Rust's `Regex::new` takes 17 to 690 µs per
pattern here at every process start, and RE# 0.4 to 8.9 ms; a folded Roc
pattern takes none. And on short inputs this engine's per-call fixed cost is
the dominant term; [PERFORMANCE.md](PERFORMANCE.md) has that measurement, the
per-pattern analysis, and what limits further gains.

## Syntax reference

### Reading a pattern

Most characters match themselves as literals: `Holmes` matches exactly those six
characters. More complex patterns are built from single-character matchers and
operators. From tightest to loosest binding: a quantifier applies to the atom
before it; adjacent atoms match in sequence; `&` intersects; `|` alternates.
So `ab|cd` is `(ab)|(cd)` and `a|b&c` is `a|(b&c)`. Parentheses group and do not
capture.

### Atoms

| syntax | matches |
|---|---|
| `a` | the character `a` |
| `.` | any character except newline |
| `_` | any character at all, newline included |
| `\n` `\t` `\r` `\f` `\v` `\e` `\a` `\0` | newline, tab, carriage return, form feed, vertical tab, escape, bell, NUL |
| `\x41` | the codepoint given by two hex digits |
| `\u0041`, `\u{1F600}` | the codepoint given by four hex digits, or by up to six in braces |
| `\.` `\*` `\(` `\\` `\&` `\_` … | backslash escape for control characters |

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
Quantifiers stack: `a**` is `(a*)*`. Repetition must follow a lieteral or class so
 `{,5}` is an error.

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
| `\Z` | at the end of the input |
| `\b` | at a word boundary: between a `\w` character and a `\W` one, or an edge |

`^` and `$` are always line anchors. There is no multiline flag because there
is no single-line mode. To match the whole input, write `\A…\Z`.

`\z` is also accepted for the input end, because RE#'s and Rust's test corpora
are written in it and the differentials feed their pattern strings to both
engines unchanged. `\A` and `\Z` is the pair this engine spells.

`\B` (not a word boundary) is rejected, as in RE#. `\b` must have a character
matcher next to it so `\b` alone is an error.

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

### Matches

- **Leftmost, then longest.** Of all substrings in the pattern's set, the one
  that starts earliest wins, and among those the longest. `a|ab` on `ab` is
  `[0,2)`. Perl and Rust prefer the first alternative and would answer
  `[0,1)`.
- **Non-overlapping.** After a match ending at `e`, the next match starts at
  (for a zero width pattern at the start) or after `e`.
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

Everything is in the `Regex` module. Haystacks are `List(U8)` and every
search function has a `_str` twin that takes a `Str`. The byte API is the real
one; the `Str` twins call `Str.to_utf8` and convert results back with
`Str.from_utf8_lossy`.

### Types

```roc
Regex.Pattern          # a compiled pattern; a record whose fields are documented-unstable
Regex.Span : { start : U64, end : U64 }   # half-open byte offsets
Err.Error : { pattern : Str, at : [Whole, At(Err.Span)], kind : Err.Kind }
```

`Err.Kind` is a tag union:
  * `GroupUnclosed` / `GroupUnopened`
  * `ClassUnclosed`
  * `ClassRangeInvalid`
  * `RepetitionMissing`
  * `RepetitionCountUnclosed`/ `RepetitionCountInvalid`
  * `EscapeUnrecognized`/ `EscapeUnexpectedEof`
  * `ComplementNeedsGroup`
  * `FlagUnsupported`
  * `Unsupported(Str)` matches RE#'s rejections,
  * `PatternTooLong`, `NestLimitExceeded` and `TooManyClasses` carry `{ limit, given }`.

### Compiling

```roc
# The literal-pattern idiom: compile, and crash with the rendered message
Regex.build : Str -> Regex.Pattern

# Actually does the compilation
Regex.compile : Str -> Try(Regex.Pattern, Err.Error)

# Error Reporting
Regex.report_errs : Try(Regex.Pattern, Err.Error) -> Regex.Pattern
Regex.labeled_errs : Str, Try(Regex.Pattern, Err.Error) -> Regex.Pattern
Regex.err_str : Err.Error -> Str          # one line, for logs
Err.message : Err.Kind -> Str             # the bare sentence
Err.render : Err.Error -> Str             # matches Roc's errs: the message, the pattern, a caret
```

`unwrap` crashes with `Err.render`'s output; `unwrap_labeled` prefixes a label
so a build with many patterns says which one failed. Use them for literal
patterns, where the crash is a build failure.

### Searching

```roc
Regex.is_match    : Regex.Pattern, List(U8) -> Bool
Regex.find        : Regex.Pattern, List(U8) -> Try(Regex.Span, [NoMatch])
Regex.find_all    : Regex.Pattern, List(U8) -> List(Regex.Span)
Regex.count       : Regex.Pattern, List(U8) -> U64
Regex.replace_all : Regex.Pattern, List(U8), List(U8) -> List(U8)
Regex.split       : Regex.Pattern, List(U8) -> List(List(U8))

Regex.is_match_str, find_str, find_all_str, count_str : … Str …
Regex.replace_all_str : Regex.Pattern, Str, Str -> Str
Regex.split_str : Regex.Pattern, Str -> List(Str)
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
Regex.first_end   : Regex.Pattern, List(U8) -> Try(U64, [NoMatch])
Regex.longest_end : Regex.Pattern, List(U8) -> Try(U64, [NoMatch])
```

Both match the pattern anchored at offset 0 of the haystack and return where
the shortest, or the longest, such match ends, with no reverse sweep at all.
They are the building block for parsers that step through a buffer piece by
piece: call them on a slice, and the slice is the whole input as far as `\A`,
`\Z`, `\b` and lookbehinds are concerned. A pattern that matches the empty
string answers `Ok(0)`, so a caller stepping a sequence must check that it made
progress; an answer equal to the slice length means the match ran to the edge
and might extend given more input. [`package-http/`](package-http/) frames
HTTP/1.1 requests this way.

### Incomplete folds

```roc
Regex.is_complete      : Regex.Pattern -> Bool
Regex.n_states         : Regex.Pattern -> U64
Regex.find_all_grow    : Regex.Pattern, List(U8) -> (Regex.Pattern, List(Regex.Span))
Regex.with_runtime_cap : Regex.Pattern, U64 -> Regex.Pattern
```

`is_complete` says whether compilation explored every reachable state. When
it did not (an unbounded lookahead such as `a(?=.*b)`), every search starts
from the folded prefix and re-derives states as it goes. `find_all_grow` also
returns the pattern with every state the search minted, so a caller looping
over haystacks can thread it and pay for each state once. `with_runtime_cap`
sets the eviction threshold (default 100000 states).

### Introspection

```roc
Regex.show      : Regex.Pattern -> Str          # the pattern after rewrites
Regex.minterms  : Regex.Pattern -> List(Str)    # the alphabet classes the pattern distinguishes
Regex.accel_str : Regex.Pattern -> Str          # which accelerators compiled in
Regex.n_nodes   : Regex.Pattern -> U64
```

The rest of the module's exports (`find_all_ref`, `find_all_plain`,
`find_all_noskip`, `find_all_threaded`, `match_starts`, `der1`,
`derive_chain`, …) are oracles and tracing hooks for the test tools. They are
documented in [`package/Regex.roc`](package/Regex.roc) and are not part of
the interface a program should depend on. If you do need one, file an issue
so it can be formally part of the public interface.

## The rest of the repository

| path | what |
|---|---|
| [`package/`](package/) | the `Regex` engine.|
| [`package-dfa/`](package-dfa/) | `Dfa`, a port of Rust's `regex` crate and the repo's first engine attempt. A bit slower (within 2x), works fine, and has captures if you want that. |
| [`package-http/`](package-http/) | Experiment in regex HTTP parsing. Used to compare match overhead; not enough text for our fast matchers to pay for the engine startup versus a tuned,specialized match |
| [`examples/`](examples/) | this README's example, the benchmark drivers, smoke tests |
| [`tools/`](tools/) | the benchmark, the RE# and Rust differentials, the fuzzer, the artifact-size probes |
| [`plans/`](plans/), [`notes/`](notes/) | Project decision logs and LLM build campaign |
| [`upstream/`](upstream/) | reproducers for the Roc compiler bugs found along the way |
| [PERFORMANCE.md](PERFORMANCE.md) | benchmark details, what limits engine performance |

[PERFORMANCE.md](PERFORMANCE.md)'s last section lists the fuzz, differential,
size and benchmark commands and what each one measures.
