# Differential harness (D9)

`gen.rs` uses the Rust `regex` crate as an oracle: for a corpus of
(pattern, haystack) pairs in the M1 subset it emits a Roc program whose cases
carry Rust's `find_iter` spans as the expected answer. The Roc program runs the
same patterns through this package and reports every divergence.

```
cd tools/diff
cargo run --quiet --bin gen > /tmp/difftest.roc
# edit the `re:` path in /tmp/difftest.roc if needed, then:
roc build --no-cache /tmp/difftest.roc && /tmp/difftest
```

M1.5 result: **860/860 agree** (44 patterns × 20 haystacks), including empty
matches, `\b`, anchors, alternation, and `(a*)*` / `(a|b)*abb` / `a|` / `.*`.
