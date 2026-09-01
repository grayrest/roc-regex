# roc-regex

A port of Rust's `regex` crate to Roc, using the compiler's compile-time
evaluation of pure functions in place of an ahead-of-time compilation mode.
`Regex.compile("…")` on a literal pattern is evaluated during the build and the
table is stored in the executable; the same call on a runtime pattern runs at
runtime. One function, one code path, no macro and no build step.

Nothing is implemented. The design is in
[`plans/2026-09-01-roc-regex.md`](plans/2026-09-01-roc-regex.md) and it is
**NOT REVIEWED**.

| document | status |
|---|---|
| [`plans/2026-09-01-roc-regex.md`](plans/2026-09-01-roc-regex.md) | **NOT REVIEWED** — 12 decisions from one design interview; central claim unverified at scale by design, M1 attacks it |
| [`notes/2026-09-01-fold-probe-log.md`](notes/2026-09-01-fold-probe-log.md) | measurements only; rigs in `notes/probes/fold/` |

Numbers in these documents are measured or absent. The one number the plan most
depends on — the state count of a determinized Unicode pattern — is absent, and
M0 exists to take it before any Roc is written.
