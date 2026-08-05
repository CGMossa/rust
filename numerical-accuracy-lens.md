# The "inlined-calculation lens" for numerical accuracy review

**Status:** idea validated with a proof-of-concept (2026-07-18); **scale-tested
on real crates (2026-08-06)** — see §10. The stock recipe fails at scale
(hard-coded inliner depth limits hide exactly the interesting code); a rustc
patch adding two `-Z` flags fixes it (branch `inline-mir-depth-limit-flags`),
and a tier-1 pretty-printer prototype lives in `mir-lens/` (this branch).

---

## 1. The idea

Writing a numerical library forces the author to *split* the calculation:
into functions, types, normalization steps, helper crates. Each split is a
design decision whose numerical consequences are invisible unless you write
the alternative. So real libraries end up with computations that are

- evaluated **too early** (a quantity computed and rounded before the context
  that would have let it stay exact),
- **divided, then rescaled, then divided again** — round-trips through a scale
  factor that cancel algebraically but not in floating point,
- **cast** down and back up across an API boundary.

Every individual function looks locally sensible. The damage lives in the
*composition*, which no one ever sees on one screen.

The proposal: a compilation mode that produces the **"inlined" view of the
whole calculation** — every call flattened into its caller, loops kept as
loops — so a reviewer (human expert, or an AI doing a systematic pass) can
inspect the composed dataflow and spot exactly these patterns: "this divide
is multiplied back three frames up", "this cast is undone later", "this
residual is a difference of two near-equal quantities".

**Where it matters most: convergence.** Not *reaching* convergence —
*determining* it. Stopping criteria are almost always small differences of
large quantities (`x*x - c`, `norm(x_new - x_old)`, a residual), computed by
catastrophic cancellation **exactly when they are smallest**, i.e. near the
solution. An accuracy bug in the criterion doesn't make the answer a little
wrong; it makes the iteration stop at the wrong time (too early: wrong
answer; too late / never: oscillating on noise). This is the highest-leverage
place to point the lens.

## 2. Why the compiler can't fix this itself (and why *review* is the right frame)

IEEE 754 strictness means rustc/LLVM are **forbidden** from reassociating,
canceling, or otherwise algebraically rewriting floating-point code. `(a/b)*b`
survives `-O3` untouched — the optimizer can *see* the waste but must not act
on it. The existing escape hatch (fast-math flags, the `algebraic_*` float
methods) is the opposite of what numerics people need: "compiler, rewrite
anything, blindly, with no report of what you did".

This idea is the controlled middle path: **surface** the composed computation
to a reviewer who is allowed to decide *semantically* whether a rewrite is
sound. The compiler does the flattening (which it is good at and allowed to
do — inlining doesn't change FP semantics); the reviewer does the judgment
(which the compiler is prohibited from doing). That division of labor is
exactly why the niche is unserved.

## 3. Why it's *not* a custom target — and what the right hook is

A target spec (`compiler/rustc_target/src/spec/`) describes machine/ABI/
linker properties. It cannot change how much inlining happens or what output
form the compiler emits. What the idea actually wants is an **alternate
consumer of post-inlining, post-monomorphization MIR**. Candidate mechanisms,
in increasing ambition:

1. **Existing flags + a post-processor** — `-Zinline-mir` + `--emit=mir`
   already produce the flattened view (see §4). A small tool makes it
   readable.
2. **A rustc-driver tool** (same architecture as Clippy/Miri): drive the
   compiler as a library, take monomorphized MIR, force-inline, slice, and
   pretty-print. Distributable as `cargo accuracy`.
3. **A custom codegen backend** (`rustc_codegen_ssa` has pluggable backends —
   precedent: cranelift, GCC): a backend whose "machine code" is a readable
   symbolic-math IR. Cute framing, probably more machinery than needed.

Post-**monomorphization** matters, and is an advantage over source review:
generic code shows its *actual* float widths and casts after instantiation.

## 4. Proof of concept (2026-07-18)

### Demo source

A fake "library" where every function is locally reasonable and the
composition is not: `update` round-trips a scale factor, and `sqrt_newton`
has the classic cancellation-prone stopping criterion, split across
`#[inline]` helpers so no single function shows the problem.

```rust
#![crate_type = "lib"]

// Each function is locally reasonable. The composition is not.

#[inline]
fn normalize(v: f64, scale: f64) -> f64 {
    v / scale
}

#[inline]
fn step(x: f64, delta: f64, scale: f64) -> f64 {
    x + normalize(delta, scale)
}

// Caller re-scales right back up: (x + delta/scale) * scale
pub fn update(x: f64, delta: f64, scale: f64) -> f64 {
    step(x, delta, scale) * scale
}

#[inline]
fn newton_step(x: f64, c: f64) -> f64 {
    0.5 * (x + c / x)
}

#[inline]
fn residual(x: f64, c: f64) -> f64 {
    x * x - c // catastrophic cancellation exactly when it matters
}

pub fn sqrt_newton(c: f64) -> f64 {
    let mut x = c;
    while residual(x, c).abs() > 1e-12 * c {
        x = newton_step(x, c);
    }
    x
}
```

### Command

Works on **stable 1.97.1** with `RUSTC_BOOTSTRAP=1` (or any nightly without
it):

```bash
RUSTC_BOOTSTRAP=1 rustc -O -Zmir-opt-level=2 -Zinline-mir=yes \
    -Zinline-mir-threshold=500 -Zinline-mir-hint-threshold=500 \
    --emit=mir numdemo.rs -o numdemo.mir
```

### What comes out

`update` is one body — the divide-then-multiply-back is visible in a single
scope, with provenance annotations saying which source function each piece
came from:

```
fn update(_1: f64, _2: f64, _3: f64) -> f64 {
    debug x => _1; debug delta => _2; debug scale => _3;
    scope 1 (inlined step) {
        scope 2 (inlined normalize) { }
    }
    bb0: {
        _5 = Div(copy _2, copy _3);   // delta / scale   ← from normalize()
        _4 = Add(copy _1, move _5);   // x + …           ← from step()
        _0 = Mul(move _4, copy _3);   // … * scale       ← the round-trip
        return;
    }
}
```

`sqrt_newton` keeps its loop as a CFG (`bb1 → bb4 → {bb2 → bb1 | bb3}`), with
the stopping criterion fully inlined into the loop header (trimmed):

```
fn sqrt_newton(_1: f64) -> f64 {
    scope 2 (inlined residual) { … }
    scope 3 (inlined core::f64::<impl f64>::abs) { }
    scope 4 (inlined newton_step) { … }

    bb1: {                                  // loop header = the criterion
        _7 = Mul(copy _5, copy _5);         // x * x        ← residual()
        _4 = Sub(move _7, copy _1);         //   … - c      ← the cancellation
        _3 = fabs::<f64>(move _4) -> bb4;
    }
    bb4: {
        _6 = Mul(const 9.9999999999999998E-13f64, copy _1);  // 1e-12 * c
        _2 = Gt(move _3, move _6);
        switchInt(move _2) -> [0: bb3, otherwise: bb2];
    }
    bb2: {                                  // the Newton step, inlined
        _9 = Div(copy _1, copy _0);
        _8 = Add(copy _0, move _9);
        _0 = Mul(const 0.5f64, move _8);
        goto -> bb1;
    }
    bb3: { return; }
}
```

Note even the literal shows its true value: `1e-12` is really
`9.9999999999999998E-13`.

### What this demonstrates

- **Composition is visible.** The `(x + delta/scale) * scale` round-trip and
  the `x*x - c` cancellation each appear in one place, despite being split
  across three source functions.
- **Loops survive** as CFG with the criterion in the loop header — no
  unrolling, exactly the "still loops are present" requirement.
- **Provenance survives.** `scope N (inlined f)` maps every operation back to
  its source function; debug info maps locals back to source names. A report
  can point at real source spans.
- **Post-monomorphization**: actual float widths, actual constants.

### What's missing (the gap a tool would fill)

- MIR is **three-address code**: `_5 = Div(_2,_3); _4 = Add(_1,_5)` instead
  of `x + delta/scale`. Reconstructing infix expression DAGs from the
  temporaries (copy-prop + use-count) is a small, well-understood
  transformation — Clippy does similar reconstruction all the time.
- Inlining is heuristic even with high thresholds; a dedicated tool would
  force-inline everything inlinable and *mark* what it couldn't.
- No value/range information — see §7.

## 5. Prior art (nobody does exactly this; several do halves of it)

- **Herbie** (herbie.uwplse.org) — takes a single FP expression (FPCore) and
  searches for a more accurate rewriting via equality saturation. The rewrite
  half of the pipeline. Its e-graph engine is **`egg` — a Rust crate**, so
  the rewrite-search machinery already exists natively in Rust.
- **Herbgrind** (Valgrind tool, same research group) — the closest existing
  thing to the whole idea, but **dynamic**: runs the binary, reconstructs
  composed FP expression trees *across function boundaries*, shadows values
  in MPFR high precision, reports the symbolic expression of any inaccurate
  result. Linux/x86_64 only, effectively unmaintained.
- **CADNA / Verrou / Verificarlo** — stochastic arithmetic (random rounding /
  Monte Carlo Arithmetic). Their flagship application is precisely the
  convergence point: detecting when a residual has **zero significant digits
  left**, i.e. the numerically optimal iteration to stop at. Verrou runs on
  unmodified binaries under Valgrind (Linux); Verificarlo is an LLVM/clang
  wrapper (no real Rust path); CADNA is a C/Fortran library.
- **FPTaylor / Daisy / Gappa** — static rounding-error bounds for extracted
  expressions (Taylor forms / SMT / proof assistant flavors).
- **Clippy** already ships two small syntactic cousins:
  `clippy::suboptimal_flops` and `clippy::imprecise_flops` (suggest
  `mul_add`, `ln_1p`, `exp_m1`, `hypot`, …) — but they only look *within* an
  expression as written, never across function boundaries. The whole point
  of the lens is that the interesting expressions only exist after inlining.

## 6. What to build — three tiers

1. **MIR post-processor** (days): consume `--emit=mir` output (or drive
   `rustc_driver` to get structured MIR), run copy-propagation over the
   temporaries, and pretty-print each function as infix expression DAGs with
   loops shown as recurrences (`x ← 0.5*(x + c/x) while |x²−c| > 1e-12·c`).
   Immediately reviewable by a human or an LLM pass.
2. **`cargo accuracy`, a rustc-driver tool** (weeks; Clippy/Miri
   architecture): monomorphized MIR → force-inline → let the user **mark a
   value of interest** (e.g. the convergence predicate, via an attribute or
   a path argument) → **backward-slice** the FP dataflow to just what feeds
   it → emit the composed expression with source spans from the inlining
   scopes. Slicing is what keeps real programs reviewable.
3. **E-graph detection pass** (research-grade): feed the sliced DAGs to `egg`
   with accuracy-oriented rewrite rules, so `(a/b)*b → a`-class findings are
   *detected* mechanically and reported as suggestions at source locations —
   never applied silently. This is "Herbie, but the expressions are found for
   you and mapped back to your Rust code."

## 7. Known weaknesses — and how the proposal gets better

- **Expression explosion.** Inline-everything on a real crate produces
  unreviewably huge dataflow. *Fix:* never dump whole programs — backward
  slicing from a marked criterion is the product, the whole-program view is
  just the substrate. Plus DAG sharing (print common subexpressions once) and
  symbolic loop summaries (recurrences, not unrolled bodies).
- **Inlining barriers.** `dyn Trait`, function pointers, extern calls
  (BLAS/LAPACK!) stop the flattening. *Fix:* render them as opaque nodes with
  their signature, and let the user attach a declared error model
  ("`dgemm` ≈ exact + n·ε") so analysis can continue through them. Also:
  cross-crate inlining needs callee MIR in metadata — build dependencies with
  `-Zcross-crate-inline-threshold=always` so the lens sees through the
  workspace, not just one crate.
- **Syntax alone can't judge accuracy.** `x*x - c` is fine or fatal depending
  on ranges — cancellation is a *value* property. *Fix (the biggest one):*
  make the tool **hybrid**. Pair the static composed-expression view with
  dynamic information on representative inputs: shadow high-precision
  execution (MPFR via `rug`, or pure-Rust bigfloats) or 1-ulp jitter runs,
  and annotate each node of the static DAG with observed ranges /
  significant-digit counts. Static gives *where and what to rewrite*; dynamic
  gives *whether it matters*. Neither alone is trustworthy.
- **Branches make expressions piecewise.** `abs`, `max`, pivoting introduce
  path conditions. *Fix:* keep the CFG (already the plan) and print guarded
  expressions per path where feasible; don't pretend a piecewise function is
  one formula.
- **MIR is unstable.** A tool parsing `--emit=mir` text will break every few
  releases. *Fix:* build on the sanctioned tool interface (the Stable MIR
  project — `stable_mir`, being reworked under the `rustc_public` name) or
  pin a toolchain the way Clippy/Miri do.
- **Versus Herbgrind** (honest comparison): this proposal is compile-time,
  cross-platform (Herbgrind is Linux/x86_64 Valgrind), speaks Rust types and
  source spans natively, and sees code paths that a given run never executes.
  Herbgrind sees actual runtime values, which the static view fundamentally
  lacks — another reason the hybrid design above is the real answer, and why
  a maintained, Rust-native successor to an unmaintained tool is a
  contribution in itself.
- **Condition numbers for free (stretch).** The in-tree Enzyme/`std::autodiff`
  work gives derivatives of the criterion w.r.t. inputs — i.e. condition
  numbers — mechanically. A rustc built with `llvm.enzyme` (this checkout can
  do that) could annotate the sliced DAG with sensitivity information, which
  is precisely what distinguishes "ugly but harmless" from "this decides your
  iteration count".

## 8. Playbook: trying this on an established workspace crate *today*

No new tooling required; roughly in order of effort:

1. **The MIR lens, as-is.** On a workspace member:
   ```bash
   RUSTC_BOOTSTRAP=1 RUSTFLAGS="-Zcross-crate-inline-threshold=always" \
     cargo rustc -p <crate> --release -- \
     -Zmir-opt-level=2 -Zinline-mir=yes \
     -Zinline-mir-threshold=500 -Zinline-mir-hint-threshold=500 --emit=mir
   ```
   Output lands in `target/release/deps/*.mir`. For one function at a time,
   `-Zdump-mir=<substring> -Zdump-mir-graphviz=yes` writes per-pass dumps and
   `.dot` CFGs to `mir_dump/`. `cargo-show-asm` (`cargo install
   cargo-show-asm; cargo asm --mir "crate::path::fn"`) is the ergonomic
   per-function front-end.
2. **Clippy's FP lints** (the shallow cousins, zero setup):
   ```bash
   cargo clippy -- -W clippy::suboptimal_flops -W clippy::imprecise_flops
   ```
3. **Shadow-precision differential testing.** Make the hot path generic over
   `num_traits::Float`, instantiate with `f64` and an MPFR type (`rug`;
   pure-Rust alternatives exist if GMP linkage is a pain), drive both with
   `proptest`, count matching digits. Cheap, brutal, finds real bugs.
4. **The f32 canary.** Same generic code at `f32`: where `f32` falls apart
   noisily is usually where `f64` is quietly bleeding half its digits.
5. **Poor-man's stochastic arithmetic.** Monte Carlo over 1-ulp jitter on the
   inputs; watch the variance of outputs **and of iteration counts of
   convergence loops**. Iteration-count variance under ulp-level noise is a
   direct measurement of the "determining convergence" thesis.
6. **Herbie on extracted expressions.** Take the composed expressions the MIR
   lens reveals, transcribe to FPCore, run the Herbie web demo — it proposes
   the accuracy-preserving rewriting and estimates bits gained.
7. **Verrou under Docker/Linux** on the release binary (no recompile):
   random rounding modes; unstable stopping criteria show up as run-to-run
   iteration-count scatter. Herbgrind (x86_64) automates the
   expression-extraction half dynamically, if it still builds.
8. **Stretch, in this checkout:** build rustc with `llvm.enzyme = true` and
   use `std::autodiff` to get derivatives/condition numbers of a criterion.

## 9. Next steps

- [x] Scale test on real crates (`nalgebra`, `interpn`) — done 2026-08-06,
      see §10. Verdict: recipe as written fails at scale; fixable in rustc.
- [x] Prototype the tier-1 pretty-printer — `mir-lens/mir_lens.py` on
      `claude-dev` (infix folding, debug-info naming, inlining provenance
      tags, `--fp-core` float-slice, `--scope` provenance-slice).
- [ ] Pick 2–3 known historical accuracy bugs in public crates and check the
      lens would have made them visible — the honest benchmark for whether
      this is worth tier 2.
- [ ] "Abstraction floor" for the lens: keep `floor`/`sqrt`/libm internals as
      symbolic leaves instead of inlined bit-twiddling (§10.5). Either don't
      inline `libm::`/`core::*::math` (compiler side), or re-fold those
      scopes in the post-processor (provenance makes this mechanical).
- [ ] Upstream conversation for the two `-Z` flags (§10.3): small,
      self-contained, useful to anyone experimenting with the MIR inliner.

## 10. Scale test on real crates (2026-08-06)

Setup: a scratch crate with one thin wrapper per computation of interest,
compiled with the §8.1 recipe. Targets: `nalgebra` 0.33 (`normalize`,
`angle`, `try_normalize`, quaternion `slerp`, 3×3 `symmetric_eigen`) and — as
a smaller, more tractable subject — `interpn` 0.11 (1-D linear, 2-D
multilinear, 1-D cubic Hermite, gradients; `default-features = false` to keep
rayon out of the picture).

### 10.1 The doc's recipe fails at scale

With thresholds at 500 (as written in §4/§8), essentially **nothing
interesting inlines** on a real library: `nalgebra` `angle_between` stayed a
single opaque call — the `acos(dot/(|a||b|))` composition it exists to test
was invisible. Real generic bodies (iterator folds, closures, loops) blow
past cost 500 immediately. Cranking `-Zinline-mir-threshold` to 100 000 fixes
that layer (327 → 7 274 lines of MIR for the nalgebra wrappers; the
`Div(dot, Mul(norm,norm))` → `clamp` → `acos` chain becomes visible in one
block, with `acos` kept as a named leaf — which is what you want).

### 10.2 The real blocker: hard-coded depth limits

Even at threshold 100 000, what stayed opaque was precisely the numerical
heart of each crate:

- `nalgebra`: `SymmetricEigen::delimit_subproblem` — **where the QR
  algorithm's convergence criterion lives** — plus the `GivensRotation::c/s`
  accessors and `shape()` (whose non-inlining also blocks const-prop from
  killing dead generic machinery).
- `interpn`: `interp_weights` (the cubic Hermite weight computation), `dot4`
  (the 4-point dot product it feeds), `index_arr_fixed_dims`. All three are
  even marked `#[inline]`.

Root cause (`compiler/rustc_mir_transform/src/inline.rs`): two **hard-coded**
constants, `HISTORY_DEPTH_LIMIT = 20` and `TOP_DOWN_DEPTH_LIMIT = 5`. Every
inlined callee that brings in >1 call-like terminator bumps a counter that
only resets at the root body; past the limit the inliner (a) refuses to even
*inspect* unmarked callees and (b) accepts `#[inline]`-marked ones only if
their body is a **single basic block** (any `mul_add` call or branch
disqualifies). Inlining one big library function (`do_decompose`) exhausts
the top-down budget instantly, so everything below it is cut — the deeper
(= more composed = more interesting) the computation, the more certainly it
is hidden. No `-Z` flag controls these, unlike the cost thresholds.

### 10.3 Fix: two new -Z flags (branch `inline-mir-depth-limit-flags`)

Commit `479a3376f1f` (~14 lines) adds `-Zinline-mir-history-depth-limit` and
`-Zinline-mir-top-down-depth-limit`, mirroring the `inline_mir_threshold`
flag family, defaults unchanged. Empirical results with a stage1 build:

- `interpn`: 26 609 → **84 984 lines**; `interp_weights`/`dot4` now appear as
  67 `(inlined …)` scopes. Remaining calls are only true leaves (`ctpop`,
  `saturating_sub`, `float_to_int_unchecked`, `cold_path`) and panic paths —
  exactly the right stopping points.
- `nalgebra` `eigenvalues3`: 149 270 lines, `delimit_subproblem` inlined; the
  deflation criterion is finally *visible*:
  `2.2204460492503131E-16 * (fabs(diag[m]) + fabs(diag[m+1]))` vs
  `fabs(off_diag[m])`, sitting in loop-header blocks with provenance intact.
  This is the §1 thesis demonstrated end-to-end on shipping library code.

**Flag guidance:** `history-depth-limit=64` is a sweet spot. Setting it to
10 000 sent compile time pathological (>5 min, likely polymorphic-recursion
unrolling through the generic dimension types); at 64 the same crate
flattens in **2.5 s**. `top-down-depth-limit` can be huge (100 000) safely —
it's the history limit that guards recursion.

### 10.4 Recipe v2

```bash
RUSTFLAGS="-Zcross-crate-inline-threshold=always" \
  cargo +stage1 rustc --release -- \
  -Zmir-opt-level=2 -Zinline-mir=yes \
  -Zinline-mir-threshold=100000 -Zinline-mir-hint-threshold=100000 \
  -Zinline-mir-history-depth-limit=64 -Zinline-mir-top-down-depth-limit=100000 \
  -Zinline-mir-preserve-debug=yes \
  --emit=mir
```

New vs §8.1: the two depth flags (need the patched rustc; `stage1` = build of
`inline-mir-depth-limit-flags`) and `-Zinline-mir-preserve-debug=yes` —
without it release builds drop callee debug info during inlining and the
pretty-printer loses all source-level names (`_171` instead of `t`).

### 10.5 Tier-1 pretty-printer prototype (`mir-lens/mir_lens.py`)

Parses `--emit=mir` text; folds single-use temporaries into infix
expressions; names locals from debug info; tags every line with its
`(inlined …)` provenance; keeps loops as CFG with back-edges marked;
`--fp-core` drops non-float dataflow and panic/fmt machinery (measured noise
on real code is ~100:1 — `angle_between` flattens to ~2 400 raw MIR lines of
which ~25 matter); `--scope substr` prints only statements from a matching
inlined callee — a poor man's preview of tier-2 slicing. Output that made
`linear1d` reviewable at a glance:

```
slope = (y1 - y0) / (x1 - x0)      ← Linear1D::eval_one
dx    = loc - x0                    ← Linear1D::eval_one
v     = slope*dx + y0               ← interpn::mul_add
...
i  = (loc - grid.start) / grid.step ← RegularGrid1D::index
x0 = start + step * floor(i)        ← RegularGrid1D::at   (recomputed, feeds dx!)
```

Known gaps: `Result`/`ControlFlow` plumbing still leaks through; libm
internals (`floor` bit-twiddling) should be re-abstracted into symbolic
leaves (the provenance scopes make that mechanical — "abstraction floor",
§9); scope-slice only catches statements whose *result* local is declared in
the target scope.

### 10.6 What this changes about the plan

The §6 tier list stands, but tier 1 now has two halves: (a) the rustc-side
flags (done, needs upstreaming) and (b) the post-processor (prototyped).
The compile-time blowup at extreme history limits reinforces §7's point that
whole-program dumps are the substrate, not the product — tier 2's
mark-and-slice is where this becomes a tool rather than an experiment.
