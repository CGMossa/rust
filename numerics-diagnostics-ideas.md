# Parked ideas: diagnostic tooling for scientific computing in Rust

**Status:** ideas only — recorded 2026-08-06, explicitly *not* prioritized.
None of these is active work; they are intricate and each needs a real
design pass before starting. Kept here so they aren't lost. Context: all of
them grew out of the inlined-calculation lens work
(`numerical-accuracy-lens.md`), and several reuse its infrastructure
(post-inlining MIR + `scope (inlined …)` provenance + the
`inline-mir-depth-limit-flags` rustc branch + `mir-lens/mir_lens.py`).

Rough order: leverage-per-effort, cheapest entry points flagged.

---

## 1. "Where was this NaN born?"

- **Catches:** the most common numerics debugging question — a NaN/Inf shows
  up in output and nobody knows which operation created it. Fortran has
  `-ffpe-trap`; Rust has nothing.
- **Mechanism:** diagnostic build mode that instruments FP ops at the MIR
  level (post-inlining) and reports the *first creation site* of each
  NaN/Inf, with inlining provenance mapping back to source spans.
- **Builds on:** the lens does the flatten+provenance+span reporting half
  already; the new part is an instrumentation MIR pass (insert an `is_nan`/
  `is_infinite` check + logging call after each FP op — or trap via FP
  status flags where the target allows).
- **Effort:** rustc-side pass = weeks; a cruder proc-macro/newtype version
  (wrap `f64` in a checked type inside a marked module) = days, no compiler
  changes, and would validate demand.
- **First step if picked up:** the newtype prototype on one real solver.

## 2. Convergence observability + ulp-jitter harness

- **Catches:** stopping criteria that decide based on rounding noise —
  iteration-count variance under 1-ulp input jitter is a direct measurement.
  Also produces residual-trajectory telemetry that is useful diagnostics on
  its own.
- **Mechanism:** instrument convergence loops (iteration count, criterion
  value at exit, residual per iteration); run N times with ulp-jittered
  inputs; report variance. The lens can already *find* float-conditioned
  loop back-edges mechanically, which is the auto-instrumentation hook.
- **Builds on:** lens loop/criterion detection; `tracing` for the telemetry.
- **Effort:** proc-macro-on-a-loop version = days. Automatic MIR-level
  instrumentation = weeks. Jitter harness = a small library either way.
- **First step if picked up:** hand-instrument one Newton/ODE loop with a
  macro + proptest jitter driver; see if iteration-variance finds anything
  real before building automation.

## 3. Shadow-precision Miri mode

- **Catches:** where significant digits are actually lost on real inputs
  (cancellation is a *value* property; static analysis can only rank
  suspects). The dynamic half of the lens's hybrid design; a maintained,
  cross-platform successor to the dead Herbgrind.
- **Mechanism:** Miri already interprets MIR including floats. Add a mode
  executing every FP op twice — native f64 + MPFR/double-double shadow —
  diverging-digit report keyed by provenance.
- **Builds on:** Miri's interpreter architecture (this checkout has the
  subtree); would be a genuinely upstreamable Miri contribution.
- **Effort:** research-grade; months. Miri review bar is high. Biggest
  design question: shadow-value plumbing through memory (arrays, structs),
  not just scalars in registers.
- **First step if picked up:** discuss with Miri maintainers whether the
  feature is wanted before writing code.

## 4. Reproducibility auditor

- **Catches:** run-to-run and cross-platform drift: rayon reduction order,
  HashMap iteration feeding FP accumulators, FMA contraction differences,
  SIMD-width-dependent reassociation, libm variation. For regulated work
  (pharmacometrics), documented reproducibility can matter more than raw
  accuracy.
- **Mechanism:** two halves. Static: lint-style sweep for known
  nondeterminism sources feeding float dataflow. Dynamic: A/B harness —
  same inputs, permuted thread counts / target features / platforms,
  ULP-diff the outputs.
- **Builds on:** clippy lint infrastructure for the static half; idea 5's
  ULP-diff machinery for the dynamic half.
- **Effort:** dynamic harness = days-to-weeks and useful alone; static
  sweep = weeks (each nondeterminism source is its own lint).
- **First step if picked up:** the A/B harness on one workspace crate,
  thread-count permutation only.

## 5. ULP-aware golden tests

- **Catches:** refactoring fear — "did this change move the numbers?" CI
  fails when results drift by more than N ulps from a snapshot, with
  per-platform baselines. Pairs with the lens: diff the two composed
  expressions to see *why*.
- **Mechanism:** `insta`-style snapshot library with ULP tolerances,
  float-aware serialization, per-target baseline files.
- **Builds on:** nothing compiler-side — pure library. The cheapest idea
  here by far.
- **Effort:** weekend prototype; a week to make pleasant.
- **First step if picked up:** wrap one existing simulation test in it.

## 6. Condition numbers via std::autodiff (Enzyme)

- **Catches:** distinguishes ugly-but-harmless expressions from ones that
  amplify input error 10^6× — per-output condition numbers, mechanically.
  Annotating the lens's sliced DAG with sensitivity is what §7 of the lens
  doc calls the biggest missing judgment input.
- **Mechanism:** build rustc with `llvm.enzyme = true` (this checkout can);
  differentiate a marked output w.r.t. inputs; combine gradients with input
  ranges to rank nodes of the composed expression.
- **Builds on:** in-tree `std::autodiff`; lens slicing for the report.
- **Effort:** the Enzyme build + one differentiated criterion = days to
  demo; integrating into a coherent report = weeks. Enzyme's maturity is
  the risk.
- **First step if picked up:** Enzyme-build this checkout, differentiate
  one stopping criterion, sanity-check the numbers by hand.

---

*If any of these gets picked up, promote it to a numbered thread in
`EXPERIMENTS.md` and move its notes into a proper design doc.*
