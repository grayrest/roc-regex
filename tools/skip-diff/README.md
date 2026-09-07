# Skip differential

Every per-state skip in `Dfa` is an assertion that the automaton would have
looped over the stretch it jumps. `Sharp.find_all_noskip` runs the same
automaton with all of them off, so it decides the assertion directly: the two
must return identical spans on every input.

```bash
tools/skip-diff/run.sh [haystack_bytes]     # default 262144
```

Written for `skip_ok[s] == 2` (design log, 2026-09-07) — the flag that lets a
state whose leaving set is pure ASCII pass over a multibyte symbol instead of
decoding it. That path needs a haystack that HAS non-ASCII and states the
fuzz's short haystacks rarely build, which is why it is not covered there.

The 28 patterns span the cases the flag's two conditions distinguish:

- pure-ASCII leaving sets that qualify (`[0-9]`, `[A-Z]{2}`, `[.,;:]`);
- leaving sets that must not, because they hold a codepoint **the haystack
  actually contains** — the generated text is Greek, so `[0-9λ]` and `μ[a-z]`
  are the ones with teeth, and `[0-9]|é` is not. `\d` is Unicode-aware, so it
  belongs to this group too;
- **nullable** skip states (`[0-9]{0,3}`), which must not qualify whatever
  their leaving set: a nullable skip records each skipped POSITION as a match
  start, and the interior symbol boundaries of a passed-over multibyte run are
  never computed.

Each pattern runs over four 256 KB haystacks — the bench haystack as
generated, then with a lone continuation byte (`0x80`) and an invalid byte
(`0xFF`) at every 997th position, then with every non-ASCII byte replaced by
`x`. The stride is coprime with 16, so the damaged bytes land at every
alignment of the SIMD windows the skip scans with, and the `0xFF` pass puts
D8's `Invalid` symbol inside the skipped stretch.

Spans compare by count and by a positional checksum, so a reordering or a
shifted bound fails as loudly as a missing match. `run.sh` exits non-zero on
any divergence.

## It has teeth

Both conditions were checked by removing them from `Dfa.skip_sets` and
confirming this catches it (2026-09-07, at 112 cases):

| condition removed | result |
|---|---|
| no non-ASCII minterm leaves the state | 103/112 — `[0-9λ]`, `[.,;:ω]`, `[0-9ε]+` |
| the state is not nullable | 109/112 — `[0-9]{0,3}`, ~4100 empty matches lost |

An earlier 18-pattern version of this list caught NEITHER: its non-ASCII
patterns were all spelled with `é`, which the haystack does not contain, and
it had no nullable skip state at all. A differential that cannot fail is worth
what it costs to run.
