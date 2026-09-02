# Compile-time construction — how the artifact is built decides what it costs

The study behind rev-2's D12. Run 2026-09-01; **written up 2026-09-02 after an
audit found its numbers cited in a decision with no note to source them.** That
was a process failure: a decision stood for a day on figures that existed only
in a chat transcript.

Rigs: session scratchpad `q/` (`mktpl.py` generates `T_<emit>_<table>.tpl` over
`emit ∈ {concat, set, size}` × `table ∈ {concat, append}`; `meas.sh` wraps
`/usr/bin/time -l roc build --no-cache`). Baseline empty basic-cli app:
**0.22–0.25 s / 137 MB / 390,528 B**. Semantic equivalence is verified, not
assumed: all six construction variants on a common pattern produce a
byte-identical binary (`shasum d207433a3337…`).

**Read every byte-alphabet row here as inflated.** The rig uses a fixed 256-wide
stride with no equivalence-class compression. A later audit rebuilt the same
patterns at their honest stride (97–100) and found the artifact figures ~2.6×
high, time ~1.66×, RSS ~1.43×. The *construction* comparisons below are A/B on
identical output and are unaffected; the absolute byte-side magnitudes are not.

## 1. `List.concat` on a growing accumulator is quadratic; `List.append` is flat

Identical pipelines — recursive-descent parser → nominal `Ast` → Thompson
`List(Inst)` → `List(U32)` table — differing only in two lines:

```roc
# A (chunked concat)                    # B (append into the live accumulator)
cells = build_row(inst, base, [], 0)    build_row(inst, base, acc, 0)
List.concat(acc, cells)
```

| pattern chars | table cells | binary (both) | **A: concat** | **B: append** |
|---|---|---|---|---|
| 288 | 57,600 | 620,672 | 0.27 s / 162 MB | 0.27 s / **138 MB** |
| 1,152 | 229,632 | 1,310,144 | 0.34 s / 528 MB | 0.30 s / **150 MB** |
| 2,304 | 459,008 | 2,229,456 | 0.53 s / 1,735 MB | 0.34 s / **177 MB** |
| 4,608 | 917,760 | 4,068,048 | 1.14–1.28 s / **5,172–6,232 MB** | 0.42 s / **248 MB** |

A grows 3.2–4.4× per doubling of pattern length; B grows 2.2–3.1× and is **45×
smaller at the top of the range**. The 4,608-char A row is run-to-run noisy
(5.2–6.2 GB); B is stable to ±2 MB.

On 276-character production patterns, same A/B, same binary:

| pattern | concat | flat append |
|---|---|---|
| `prod_ident_uni` | 0.45 s / 1,190 MB | 0.36 s / **162 MB** |
| `prod_log_uni` | 14.42 s / 7,783 MB | 0.71 s / **324 MB** |
| `prod_route_uni` | 18.21 s / 7,638 MB → **OOM-killed, no binary** | 1.77 s / **791 MB** |

**The original construction OOM-kills the compiler on a 276-character regex.**

## 2. `List.set` is worse, and it is the shape an NFA back-patcher wants

One million `List.append`s, with `List.set(acc, 0, 7)` fired every KK
iterations:

| `List.set` calls | wall | peak RSS | retained per call |
|---|---|---|---|
| 0 | 0.34 s | 177 MB | — |
| 100 | 0.38 s | 541 MB | 3.6 MB |
| 1,000 | 0.76 s | 3,985 MB | 3.8 MB |
| 10,000 | 16.28 s | 6,852 MB | thrashing |

**`List.set` copies the whole list at compile time and never frees.** Emitter ×
table cross on a 288-char pattern (15,543,552 cells, 62.7 MB binary):

| emit style | table style | wall | peak RSS |
|---|---|---|---|
| concat | concat | — | **OOM-killed** |
| **set** (back-patch) | append | 5.44–6.03 s | **5,375–6,634 MB** |
| concat | append | 2.13 s | 870 MB |
| **size** (forward append, precomputed subtree sizes) | append | 2.18–2.21 s | **903–906 MB** |

The winning emitter computes subtree sizes ahead of the write so it can append
forward-only — never concat, never patch.

## 3. Both cost terms are linear in the artifact

`F<N>` stores a `List(U32)` of N built by pure `List.append`; `S<N>` builds the
identical list and folds it to a `U64` so nothing is stored.

| N cells | artifact bytes | F: stored | S: discarded | storage | transient |
|---|---|---|---|---|---|
| 1,000,000 | 4,005,824 | 0.32 s / 176 MB | 0.42 s / 144 MB | 32 MB | 7 MB |
| 4,000,000 | 16,022,336 | 0.51 s / 308 MB | 0.93 s / 171 MB | 137 MB | 34 MB |
| 16,000,000 | 64,121,216 | 1.31 s / 762 MB | 2.97 s / 275 MB | 487 MB | 138 MB |

Storage ≈ **7.6 bytes of compiler RSS per artifact byte** (30 B per `U32`);
transient ≈ **2.2 bytes per artifact byte**. Total ≈ **10× the stored artifact**,
roughly 3:1. This is the floor for any construction.

Peak RSS is ~85% artifact size and ~15% AST node count — the per-cell overhead
climbs from 39 to 209 MB per million cells as the AST goes from 0 to 4,500
nodes, adding roughly **30 KB of compiler RSS per pattern character**
independent of the table.

## 4. The parser stack, not memory, binds first for most pattern classes

Measured directly, and **identical across both alphabets** — it is AST recursion
depth, which the alphabet does not touch:

| chars | result |
|---|---|
| 4,500 | 0.50 s / 376 MB / builds |
| 4,600 and above | `The Roc compiler overflowed its stack memory and had to exit.` |

Exit 134, no file, no line, and when a slow fold precedes it the last named
definition is one that *succeeded*. Under the byte alphabet only 4 of 7 pattern
classes reached this limit; under codepoints 6 of 7 do.

## 5. With flat construction, N regex constants stop multiplying peak RSS

| rig | patterns | construction | peak RSS |
|---|---|---|---|
| `mrek128` | 1 × 2,304 chars | concat | 1,732 MB |
| `two128` | 2 × 2,304 chars | concat | **3,308 MB (1.91×)** |
| `mrek128_flat` | 1 × 2,304 chars | append | 178 MB |
| `two128_flat` | 2 × 2,304 chars | append | **188 MB (1.06×)** |

Additivity of concurrent folds is real, but it is additivity of the *quadratic
transient*. Under flat construction the per-fold transient is a few MB, so N
regexes cost N × artifact storage and nothing else — 8 constants add 104 MB over
1, for 10.6 MB more artifact. Build time stays sublinear in N (8× the work, 2.5×
the time), so parallel folding remains a win.

## Caveat carried

Compile-time evaluation frees nothing during a root's evaluation. Every rule
above is a consequence of that one fact, and it is the reason a budget on the
finished artifact cannot bound the build (rev-2 D13).
