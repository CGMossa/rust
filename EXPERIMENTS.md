# Experiments & active work threads

Running log of what we're hacking on in this checkout, so a fresh session
knows the state without spelunking through branches. Tracked only on
`claude-dev` (see the "Working with claude-dev" section in `CLAUDE.md`).

_Last updated: 2026-08-07._

---

## 1. Unwind completion hook (std)

- **Branch:** `unwind-completion-hook` (renamed + rebased onto upstream/main
  2026-08-06; old names `create_final_unwinding`/`add_final_unwinding`
  deleted). The stale tracked CLAUDE.md was dropped from the branch.
- **Goal:** A global hook that runs **after** all Rust unwinding/drops complete,
  so an FFI function can take control of the program once Rust has cleaned up.
  Primary use case: a diverging (`-> !`) FFI handoff at end of unwind —
  concretely, interop with **R's longjmp-based error handling**: `Rf_error`
  longjmps, and longjmp across live Rust frames skips destructors, so the
  hook lets a panic unwind fully (drops run) and *then* jump back into R.
  This is why `was_caught == false` must mean "no further Rust code runs on
  this thread" (guaranteed since the rethrow-invisible rework).
- **API:** `std::panic::{set_unwind_hook, take_unwind_hook}` +
  `UnwindCompletionInfo { payload(), was_caught() }`. Library feature gate
  `unwind_completion_hook` (unstable, no compiler feature entry needed).
- **Key files:** `library/std/src/{panic,panicking,rt}.rs`,
  `library/panic_abort/src/lib.rs`, unstable-book doc, 5 UI tests in
  `tests/ui/panics/unwind-completion-hook-*.rs`.
- **Toolchain:** `rust-unwind-hook` → `build/host/stage1-unwind-hook`
  (snapshot, rebuilt 2026-08-06 on the new base; re-snapshot after rebuilds).
- **Status:** rebased onto upstream/main (7608eb7b07e), conflict was only the
  `catch_unwind` intrinsic call site (upstream now returns bool, branches
  swapped; hook ordering preserved). All 5 UI tests pass; API smoke-tested.
  Design notes in `unwind-completion-hook-plan.md`; usage/API in
  `INSTRUCTIONS.md` (both on that branch). See also the `unwind-hook` skill.
- **Review findings (2026-08-06) — all addressed by the rework
  (`5d258dbff77`):** (a) `was_caught` used to report `true` even for panics
  that terminate a thread/main (runtime's own `catch_unwind` in
  `lang_start`/`thread::spawn` caught them). Fixed: runtime root catches go
  through internal `CatchScope::ThreadRoot` (`panic::catch_unwind_root`),
  so thread-death unwinds now report `false` — verified live and by two new
  UI tests (`-uncaught`, `-thread`); 80/80 in tests/ui/panics pass.
  (b) Per-catch-layer firing under `resume_unwind` — now documented.
  (c) Diverging hook wedging set/take — fixed: hook stored as
  `Option<Arc<_>>`, invocation snapshots the Arc and drops the lock before
  calling. API is now Arc-symmetric: `set_unwind_hook(Arc<_>)`,
  `take_unwind_hook() -> Option<Arc<_>>` (round-trippable). Ordering
  invariant unchanged: hook runs outside the `#[rustc_nounwind]` catch
  callback, before `panic_count::decrease()`. Follow-up (`73e76e943bb`)
  briefly made scope/TLS suspend-and-rethrow catches report `false`, but
  the open question ("should they instead be invisible?") was decided
  **invisible** (`d6f7b01a73d`, 2026-08-06): those catches don't fire the
  hook at all, so it fires exactly once per completed unwind — `true` at a
  user recovery, `false` at thread/main root or abort (`CatchScope` is now
  three-way `User`/`ThreadRoot`/`Rethrow`; helpers `catch_unwind_root` +
  `catch_unwind_rethrow`). Caveat: user-level `resume_unwind` is a new
  unwind, so user catch-and-rethrow still fires per user catch. 8 UI
  tests, 81/81 pass; semantics smoke-tested live on the refreshed
  `rust-unwind-hook` snapshot.

## 2. Windows-GNU `function_sections` — WRAPPED (2026-08-07)

- **Contribution-ready branch:** `enable-windows-gnu-function-sections` @
  `cb3226e7f1f` — single +6/−2 commit flipping the base-spec default, with
  a data-carrying commit message. Filing gated only on a Windows runtime
  pass (CI or wine); local validation was static-only.
- **Full write-up (lines, data, considerations, repro):**
  `win-gnu-fs-validation/REPORT.md` on this branch. Headline yields:
  **−7%** with GNU ld (capped by pdata rooting), **−68%** with rust-lld
  (fs is the prerequisite for lld's PE gc). linkme findings + two
  validated fixes (`.jcr` anchor crate patch — upstream candidate, PR
  draft ready — and KEEP linker script) live in
  `win-gnu-fs-validation/linkme-test/`; linkme is silently broken on
  windows-gnu *today* (plain release bin keeps 1 of 3 elements).
- **Original motivation:** `linkme` failing in staticlib outputs on
  windows-gnu (R/Rtools: Rust staticlib linked into package DLLs).
  Recommended stack there: patched linkme + `lto = "fat"`.
- **Toolchain:** `rust-win-gnu-fs` → `build/host/stage1-win-gnu-fs`
  snapshot; `bootstrap.toml` keeps the `[target.x86_64-pc-windows-gnu]`
  cc/ar/linker block; `brew mingw-w64` (GCC 16.1, binutils 2.46.1).
- **Next actions when picked up:** (1) file the linkme PR, (2) Windows CI
  runtime pass then the rustc PR, (3) open the rust-lld-for-windows-gnu
  conversation. Details in REPORT.md §Next actions.

## 3. Compiler-internals book

- **Branch:** `rust-compiler-internals-book`
- **Goal:** A standalone "The Rust You Don't See" internals book
  (`rust-compiler-internals-book.md`, ~3.8k lines) + a "Chapter 11: Tutorials"
  addition. Pure docs, no compiler changes.
- **Status:** drafted on branch, ~4 months stale.

## 4. Numerical-accuracy "inlined-calculation lens"

- **Branch:** `claude-dev` only so far (design notes, no tree changes).
- **Goal:** Tooling that shows the *composed* floating-point computation of a
  program — post-inlining, post-monomorphization MIR, loops kept as loops — so
  a reviewer can spot accuracy losses that live across function boundaries:
  divide-then-rescale round-trips, early rounding/casts, and above all
  cancellation in convergence *stopping criteria*.
- **Status:** PoC verified 2026-07-18; **scale-tested 2026-08-06** on
  `nalgebra` + `interpn`. Verdict: the stable-flags recipe fails on real
  crates — the MIR inliner's *hard-coded* depth limits
  (`HISTORY_DEPTH_LIMIT=20`, `TOP_DOWN_DEPTH_LIMIT=5` in
  `rustc_mir_transform/src/inline.rs`) hide exactly the numerically
  interesting helpers (nalgebra's `delimit_subproblem` = the eigen
  convergence criterion; interpn's `interp_weights`/`dot4`, despite
  `#[inline]`). Fixed by **branch `inline-mir-depth-limit-flags`** (commit
  `472f72b6297`): adds `-Zinline-mir-history-depth-limit` +
  `-Zinline-mir-top-down-depth-limit`. With a stage1 build of that branch the
  criterion is fully visible (details + recipe v2 + flag guidance in
  `numerical-accuracy-lens.md` §10). Tier-1 pretty-printer prototyped:
  `mir-lens/mir_lens.py` (this branch; infix folding, debug names,
  provenance tags, `--fp-core`, `--scope`).
- **Toolchain:** `rust-mir-lens` rustup link → `build/host/stage1-mir-lens`,
  a copy-on-write snapshot of the flags-branch build. Dedicated link + own
  directory so stage1 rebuilds can't repoint it (`./x clean` does remove it;
  rebuild from the branch + re-snapshot to restore). The floating `stage1`
  link also exists and tracks whatever was last built.
- **Printer v2 (2026-08-07):** `--fp-core` now preserves loop structure
  (heads show exit conditions, back-edge gotos kept); `--scope` slices with
  dataflow closure (consuming statements included); new repeatable
  `--floor <substring>` implements the abstraction floor (collapses matching
  provenance runs into `⟨callee: N stmts elided⟩`); `// DBG:` comment lines
  filtered. Validated on the lens-demo crate in all modes.
- **Next:** historical-accuracy-bugs benchmark; upstream the two `-Z` flags;
  rustc-side follow-up idea — detect *polymorphic recursion* in the inliner
  (same DefId, growing substs) instead of bounding all depth, so history
  limits could be lifted on generic-heavy crates; tier-2 printer
  (expression-DAG reconstruction to fold enum plumbing); verifier track
  (error bounds / condition numbers) parked in
  `numerics-diagnostics-ideas.md`.

---

## Parked ideas (not active work)

Six sketched-out diagnostic-tooling ideas for scientific computing (NaN
birth tracing, convergence observability, shadow-precision Miri,
reproducibility auditor, ULP golden tests, autodiff condition numbers) live
in `numerics-diagnostics-ideas.md` — recorded 2026-08-06, deliberately not
prioritized. Promote to a thread here if one gets picked up.

## Reference research (kept on this branch)

- `target-cpu-categories.md` — survey of default `target-cpu`/SIMD baselines
  per architecture, x86-64 microarchitecture levels, cross-compilation
  support, efficiency ranking (written 2026-04; rescued 2026-08-06 from the
  `enable-windows-gnu-function-sections` branch, where it didn't belong).
  Useful when picking `-C target-cpu` for numerical builds.

---

## How to update this file

Add a thread when you start real work on something; drop it to a one-line
"done/abandoned" note when it lands or dies. Keep the absolute date at the top
current. This lives on `claude-dev` — commit changes there, don't stage it into
a feature-branch PR.
