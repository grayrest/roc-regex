# Two crashes in package-sharp debug helpers (2026-09-05)

`roc build` (dev backend, release-fast-84812227) of either app succeeds; running
it crashes before printing. Both compile the corpus' "lookback 2" log-line
pattern; `Sharp.find_all` on the same pattern and haystack runs fine (the
corpus runner does it).

- `show-rev-segv.roc` — `Sharp.show_rev` (the node printer on the reverse
  pattern): SIGSEGV in `libsystem_malloc tiny_free_no_lock` (EXC_BAD_ACCESS,
  address 0x5b00000066), i.e. a bad free / refcount. No unwind info past
  frame 0.
- `derive-chain-rev-sigbus.roc` — `Sharp.derive_chain_rev`: SIGBUS (stack
  overflow) with exit 138.

Not yet reduced to a package-free repro.
