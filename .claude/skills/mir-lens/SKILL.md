---
name: mir-lens
description: Run the numerical-accuracy "inlined-calculation lens" on a crate - flatten a numerical computation across all function boundaries via forced MIR inlining and pretty-print the composed floating-point expressions. Use when the user wants to see the "full code" / composed calculation of numerical or simulation code, review floating-point accuracy (cancellation, divide/rescale round-trips, convergence stopping criteria), or says "lens", "mir-lens", or "show the inlined calculation".
---

# The inlined-calculation lens

Shows the *composed* floating-point computation of a program — every call
flattened into its caller (post-inlining, post-monomorphization MIR), loops
kept as loops — so a reviewer can spot accuracy hazards that live across
function boundaries. Full background: `numerical-accuracy-lens.md` (repo
root, claude-dev). Pretty-printer: `mir-lens/mir_lens.py`.

## Prerequisites

- Toolchain `rust-mir-lens` must exist (`rustup toolchain list`). It is a
  snapshot of the `inline-mir-depth-limit-flags` branch build at
  `build/host/stage1-mir-lens`, and carries the two non-upstream flags the
  recipe needs (`-Zinline-mir-history-depth-limit`,
  `-Zinline-mir-top-down-depth-limit`).
- **If missing** (e.g. after `./x clean`): rebuild and re-snapshot —
  ```bash
  git switch inline-mir-depth-limit-flags
  ./x build library
  cp -Rc build/host/stage1 build/host/stage1-mir-lens   # APFS clone
  rustup toolchain link rust-mir-lens build/host/stage1-mir-lens
  ```
  Never point the link at the mutable `build/host/stage1` — snapshot first
  (other experiments rebuild that directory).

### Availability / pinning (verified 2026-08-07)

- The link is **machine-local**: rustup can run it (`cargo +rust-mir-lens`,
  `rustup run rust-mir-lens`) but not download it. Another machine rebuilds
  the branch and links its own snapshot (commands above).
- A project can pin it with `rust-toolchain.toml`:
  ```toml
  [toolchain]
  channel = "rust-mir-lens"
  ```
  Custom linked names are valid channels; `rustup which rustc` then resolves
  to the snapshot, and since stage1 ships no cargo, rustup's shim silently
  falls back to the default toolchain's cargo — exactly what the recipe
  expects.
- Pinning only makes the flags *available* — the lens is still the explicit
  recipe invocation below. Do NOT bake the recipe's RUSTFLAGS into a
  project's `.cargo/config.toml`; they would distort every normal build.

## Recipe

From the target crate's directory (a scratch wrapper crate with one thin
`pub fn` per computation of interest works best — see "Scoping" below):

```bash
RUSTFLAGS="-Zcross-crate-inline-threshold=always" \
  cargo +rust-mir-lens rustc --release -- \
  -Zmir-opt-level=2 -Zinline-mir=yes \
  -Zinline-mir-threshold=100000 -Zinline-mir-hint-threshold=100000 \
  -Zinline-mir-history-depth-limit=64 -Zinline-mir-top-down-depth-limit=100000 \
  -Zinline-mir-preserve-debug=yes \
  --emit=mir
```

- Output lands in `$CARGO_TARGET_DIR/release/deps/<crate>-<hash>.mir`
  (this machine sets `CARGO_TARGET_DIR=/Users/elea/.cargo-target` in
  `~/.cargo/config.toml` — the crate-local `target/` will NOT exist).
- Delete stale `.mir` files first and `touch src/lib.rs` to force re-emit.
- `RUSTFLAGS` must carry `-Zcross-crate-inline-threshold=always` so
  *dependencies* encode their MIR for inlining; the other flags go after
  `--` (leaf crate only).

### Flag guidance

- `history-depth-limit=64` is the sweet spot. Large values (10000+) can send
  compile time pathological on generic-heavy crates (polymorphic-recursion
  unrolling) — nalgebra went >5 min at 10000, 2.5 s at 64.
- `top-down-depth-limit` is safe to set huge; history is what guards
  recursion.
- `-Zinline-mir-preserve-debug=yes` is required or callee variable names are
  dropped and the pretty-printer prints `_171` instead of `t`.
- Sanity check that inlining worked: `grep -c "inlined" out.mir` should be
  large; list what *stayed* calls with
  `grep -oE '= [A-Za-z_][^(]*\(' out.mir | sort | uniq -c | sort -rn` —
  only intrinsics (`ctpop`, `saturating_sub`, `float_to_int_unchecked`,
  `cold_path`) and panic paths should remain. Named library functions in
  that list mean the flags/toolchain aren't being picked up.

## Pretty-printing

```bash
python3 mir-lens/mir_lens.py <file>.mir --fn <substring>            # one function, full
python3 mir-lens/mir_lens.py <file>.mir --fn <substring> --fp-core  # float dataflow only
python3 mir-lens/mir_lens.py <file>.mir --fn <substring> --scope <callee-substring>
python3 mir-lens/mir_lens.py <file>.mir --fn <substring> --floor libm --floor <callee>
```

- `--fp-core` drops non-float statements and panic/fmt machinery (~100:1
  noise reduction) but keeps each surviving block's control flow, so loops
  stay readable: `(loop head)` blocks show their exit condition even when
  it's iterator plumbing, and `[loop back-edge]` gotos are kept.
- `--scope` is a dataflow slice: statements whose inlining provenance
  matches, **plus** statements consuming values that scope produced (so the
  criterion that *uses* a scoped result is included). Provenance tags print
  as `← callee::path` with generics stripped, so filter by bare names
  (`delimit_subproblem`, not `SymmetricEigen::<f64>::delimit_subproblem`).
- `--floor` (repeatable) is the abstraction floor: statements whose
  provenance matches collapse into one `⟨callee: N stmts elided⟩` marker —
  use it to keep libm/builtin internals symbolic (`--floor libm`) or to hide
  an already-reviewed helper.
- Known printer gaps: some `Result`/`ControlFlow` enum plumbing still shows
  (full folding needs tier-2 expression-DAG reconstruction); `--floor`
  elides by provenance, so values flowing out of a floored scope may print
  as raw `_N` locals.

## Scoping the analysis

Never lens a whole application. Make a scratch crate depending on the
library under review, with one thin wrapper per computation of interest
(`pub fn` taking/returning plain floats/arrays), and lens that. Prefer small
crates (e.g. interpn) over heavyweight generic stacks (nalgebra) for
exploratory passes; bring in the big ones only for targeted questions.

## What to look for in the output

- Subtractions of near-equal quantities in loop-head criteria (cancellation
  exactly when the residual is smallest).
- A `Div` whose result is later multiplied by the same factor
  (divide→rescale round-trips across function boundaries).
- Values recomputed from rounded intermediates instead of propagated
  (e.g. `x0 = start + step*floor(i)` feeding `loc - x0`).
- Casts down and back up across API boundaries; float constants shown at
  their true value (`1e-12` prints as `9.9999999999999998E-13`).
