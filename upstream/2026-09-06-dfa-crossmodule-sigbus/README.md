# `Dfa.find_first_fast` / `Dfa.ends_fast` SIGBUS when called from an app

Calling either of these exposed functions from an app crashes the built binary
with SIGBUS (exit 138) and no output. The identical search reached through
`Sharp.find`, which calls `Dfa.find_first_fast` internally, runs fine.

    Roc compiler version release-fast-5f9a6e18

## Reproduce

```
roc build --output=out_ok    ok.roc     && ./out_ok    a b   # prints 39
roc build --output=out_crash crash.roc  && ./out_crash a b   # exit 138, no output
```

Both build with 0 errors. `crash.roc` differs from `ok.roc` only in reaching
the search through

```roc
Dfa.find_first_fast(hn.e, hn.trie, hn.accel, b)
```

instead of `Sharp.find(hn, b)`. `Dfa.ends_fast(hn.e, hn.trie, hn.accel.len, b,
starts, True, True, True)` behaves the same way.

The arguments are fields of a `Sharp.T` built by a folded `Sharp.compile`:
`Dfa.E` (a record of eighteen fields, fourteen of them lists, plus a nested
`Arena.A`), `Trie.T`, and `Accel.T` (three tag fields). Reading scalar fields of
the same `Sharp.T` from an app is fine, and so is `Sharp.match_starts_fast`,
which is a thin `Sharp` wrapper that passes `re.e`, `re.trie` and
`re.accel.init` to `Dfa.starts_fast` — so it is not simply "passing `Dfa.E`
across a package boundary".

## Why it matters here

These are the engine's two scan halves, and timing them separately is how you
find out which one a search spends its time in. Hitting this three times during
one profiling session is what forced the decomposition in
`notes/2026-09-05-package-sharp-design-log.md` ("The forward end pass") to be
done indirectly — growing the match with a padded pattern and subtracting the
sweep — rather than by measuring the pass directly.

Belongs with the two debug-helper crashes already recorded in
`upstream/2026-09-05-sharp-debug-crashes/`.
