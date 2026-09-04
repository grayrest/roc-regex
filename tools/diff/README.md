# Differential harness (D9)

`gen.rs` uses the Rust `regex` crate as an oracle: for a corpus of
(pattern, haystack) pairs in the M1 subset it emits a Roc program whose cases
carry Rust's `find_iter` spans as the expected answer. The Roc program runs the
same patterns through this package and reports every divergence.

```
cd tools/diff
cargo run --quiet --bin gen > /tmp/difftest.roc
# edit the `re:` path in /tmp/difftest.roc if needed, then:
roc build --no-cache --output=/tmp/difftest /tmp/difftest.roc && /tmp/difftest
```

**Use `--output`** (or `cd` to where you want the binary): `roc build FILE`
ignores FILE's directory and writes the binary, named by FILE's basename, into
the *current* directory. Without `--output`, `roc build /tmp/difftest.roc`
lands `./difftest` (here, `tools/diff/difftest`) while `&& /tmp/difftest` runs a
*different* path — a stale binary from an earlier run if one exists. Since the
package is compiled into the binary, that silently validates old `package/`
code against your new edits.

Result: agrees with the Rust crate across the corpus (patterns × haystacks in
`gen.rs`), including empty matches, `\b`/`\B` (incl. Unicode over non-ASCII
haystacks), `^`/`$`, alternation, and `(a*)*` / `(a|b)*abb` / `a|` / `.*`.
