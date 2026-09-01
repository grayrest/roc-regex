# Fold probes

Rigs for [`../../2026-09-01-fold-probe-log.md`](../../2026-09-01-fold-probe-log.md).
Each is a standalone app on basic-cli 0.21.0. Run a cold fold with

```bash
roc build --no-cache <rig>.roc
```

and compare build time against run time — that difference *is* the measurement.

| rig | shows |
|---|---|
| `fold.roc` | compile-time evaluation is real and unbudgeted (§1) |
| `fold6.roc` | heap values fold, ship in the binary, survive to runtime (§2) |
| `inbody.roc` | folding is not restricted to top-level definitions (§3) |
| `shapes.roc` | tag unions, nested lists and records with `Str` all fold (§4) |
| `crashy.roc` | a `crash` while folding is a build error (§5) |
| `errs.roc` / `errs_bad.roc` | `Try` + caller-side `unwrap` turns a bad literal pattern into a build failure (§5) |
| `v1`–`v5.roc` | fold eligibility is per-call, all-or-nothing on arguments (§7) — `v3` is the one that does *not* fold |
| `varB.roc` + `engB/` | compiler SIGSEGV on a data-carrying nominal type (§10) |
| `varE.roc` | the namespace-module idiom, which works |

`tbl.roc` is a **template**, not a runnable rig: `TY`, `TYL` and `NNN` are
substituted to produce one app per element width. §8 was taken with

```bash
for ty in U8 U16 U32 U64; do
  low=$(echo $ty | tr 'A-Z' 'a-z')
  sed "s/TYL/${low}_wrap/g; s/TY/$ty/g; s/NNN/1_000_000/" tbl.roc > t.roc
  roc build --no-cache t.roc >/dev/null 2>&1
  printf "%-4s %s\n" "$ty" "$(stat -f%z t)"
done
```

against a 390 704-byte baseline. Note the shell quoting: `$low_wrap` silently
expands to nothing and builds a stale binary, which is how §8 got the wrong
answer the first time.
