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

## Validation

- **240/240** — the three-pass `find` agrees with the PikeVM reference on ASCII
  look-free patterns, including `ab|a`, `a|ab`, `(a|b)*abb`, lazy `a.*?c`, `.*`,
  empty matches, `{n,m}`.
- **180/180** — three-pass `find` agrees **directly with the Rust crate** on
  15 patterns × 12 haystacks (leftmost-first cases included).
- smoke 21/21; `find_all`/`replace`/`split` (unchanged PikeVM paths) remain at
  the M1.5/M2 differential result.

## Cost and a caveat

For a **folded** (constant) pattern the DFAs are built at compile time: literal
`[a-z]+[0-9]+` builds in ~1 s and embeds forward+reverse DFAs at a 33 KB
artifact delta, engine `three-pass`. For a **runtime** pattern the determinization
runs at runtime (D2 — runtime patterns pay), which is why the 1431-case
differential harness (which compiles every case at runtime via `List.map`) no
longer completes quickly with the DFA paths; the DFA is validated on the bounded
corpora above, and the PikeVM core on the full 1431.

Still deferred: Unicode `\b` in the DFA (look patterns use the PikeVM), captures
directly from the reverse pass (they layer on `match_at`), and stride/`U16`
minimisation.
