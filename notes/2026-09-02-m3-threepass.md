# M3 continued — the reverse DFA and three-pass find (D5)

The forward-only DFA (is_match) is now a full **three-pass span finder** (D5):
forward DFA for the match end, reverse DFA for the start, both leftmost-first,
both built at compile time so they fold into the artifact. `find` returns exact
spans from the DFAs; captures/`replace`/`split` still layer on the PikeVM.

## Construction

- **Reverse NFA** (`Comp.reverse_ast` + a second `emit`): the AST reversed
  (concatenation order flipped, groups flattened), compiled into the same class
  sets so the trie is shared.
- **Unanchored forward NFA** (`uprog`): a **lazy dot-star** prefix then the
  pattern. The dot-star is one persistent lowest-priority thread; the leftmost
  determinizer truncates it away once the pattern matches, so a later start can
  never override the leftmost one — a per-step re-seed (which I tried first) gets
  this wrong.
- **Leftmost-first determinizer** (`Rev.determinize`): the epsilon closure keeps
  pcs in priority order and **truncates at the first Match** (lower-priority
  alternatives after a match are unreachable). This is what makes `ab|a` prefer
  `ab` and `a|ab` prefer `a`. Both DFAs carry a per-state match flag and a state
  budget (`Err(TooBig)` -> downgrade); look assertions -> `Err(HasLook)` ->
  PikeVM. Recorded in `Regex`'s `engine : [Pike, Three({fwd, rev})]`.
- **Searches**: forward records the last match-state offset before dead (the
  leftmost-first end); reverse runs backward from that end, smallest reached
  match-state position is the start.

## Validation — and the bug it found

The bounded checks first: 240/240 vs the PikeVM reference and 180/180 directly
vs Rust on ASCII look-free patterns (`ab|a`, `a|ab`, `(a|b)*abb`, lazy `a.*?c`,
`.*`, empty matches, `{n,m}`).

Those were **not enough**, and I reported the three-pass validated before it was.
Neither bounded corpus contained an empty-loopable quantifier, and `Rev.close_pri`
had a non-termination bug: it deduped only the Char/Match pcs it output, never the
split/jmp/save nodes it walked, so a nullable body under `+`/`*` — `(a*)+`,
`(a*)*` — is a pure epsilon cycle and the closure looped forever. The PikeVM was
never affected (its closure tracks every pc in `seen`), which is exactly why the
original 1431 passed and this hid. Fixed in `186ef1c` (`close_go` tracks all
visited pcs).

**With the fix the full 1431-case differential harness completes: 1431/1431 agree
with the Rust crate** across `find_all` (PikeVM), `is_match` (DFA) and the
prefiltered three-pass `find`, in ~50 s. smoke 21/21. The lesson is the plan's
own: a bounded corpus is not a differential campaign, and the bug that survives
is the one your sample happens to miss (here, `(a*)+`).

## Cost and a caveat

For a **folded** (constant) pattern the DFAs are built at compile time: literal
`[a-z]+[0-9]+` builds in ~1 s and embeds forward+reverse DFAs at a 33 KB
artifact delta, engine `three-pass`. For a **runtime** pattern the determinization
runs at runtime (D2 — runtime patterns pay); the 1431-case harness compiles every
case at runtime via `List.map`, so it pays full determinization ×1431 and takes
~50 s (~35 ms/case) — the runtime cost, not a folded-use cost.

Still deferred: Unicode `\b` in the DFA (look patterns use the PikeVM), captures
directly from the reverse pass (they layer on `match_at`), and stride/`U16`
minimisation.
