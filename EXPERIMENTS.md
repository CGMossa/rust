# Experiments & active work threads

Running log of what we're hacking on in this checkout, so a fresh session
knows the state without spelunking through branches. Tracked only on
`claude-dev` (see the "Working with claude-dev" section in `CLAUDE.md`).

_Last updated: 2026-08-06._

---

## 1. Unwind completion hook (std)

- **Branch:** `unwind-completion-hook` (renamed + rebased onto upstream/main
  2026-08-06; old names `create_final_unwinding`/`add_final_unwinding`
  deleted). The stale tracked CLAUDE.md was dropped from the branch.
- **Goal:** A global hook that runs **after** all Rust unwinding/drops complete,
  so an FFI function can take control of the program once Rust has cleaned up.
  Primary use case: a diverging (`-> !`) FFI handoff at end of unwind.
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
- **Review findings (2026-08-06):** (a) `was_caught` reports `true` even for
  panics that terminate a thread/main — the runtime's own `catch_unwind` in
  `lang_start`/`thread::spawn` catches them; `false` only on non-unwinding
  abort paths. Docs claim otherwise → fix docs or rethink the flag before
  any RFC/PR. No test covers uncaught-unwind-to-thread-death. (b) Hook fires
  once per catch layer under `resume_unwind` re-throws (undocumented).
  (c) A diverging hook holds the RwLock read guard forever; cross-thread
  set/take then blocks (document as intended). Mechanics are sound: hook
  runs outside the `#[rustc_nounwind]` catch callback, before
  `panic_count::decrease()`, so in-hook modification attempts panic→abort.

## 2. Windows-GNU `function_sections`

- **Branch:** `enable-windows-gnu-function-sections` (+ change currently in `git stash@{0}`)
- **Goal:** Flip `function_sections: false → true` in
  `compiler/rustc_target/src/spec/base/windows_gnu.rs` to test whether
  `--gc-sections` now strips dead functions on PE/COFF (binutils #11539).
- **Status:** one-line experiment, **stashed** as
  `stash@{0}: "wip: windows_gnu function_sections experiment + backtrace bump"`.
  The stash also carries a `library/backtrace` submodule pointer bump. Restore
  with `git stash pop` from the branch you want it on. Branch also has a
  `target-cpu-categories.md` + "target cpu categories" commit.
- **Validation:** build a windows-gnu target and check binary size / that
  `--gc-sections` drops unused functions. See `/bootstrap-config` scenario 5
  (cross-compiling) for the target build config.

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
- **Next:** historical-accuracy-bugs benchmark; "abstraction floor" (keep
  libm internals symbolic); upstream the two `-Z` flags.

---

## Parked ideas (not active work)

Six sketched-out diagnostic-tooling ideas for scientific computing (NaN
birth tracing, convergence observability, shadow-precision Miri,
reproducibility auditor, ULP golden tests, autodiff condition numbers) live
in `numerics-diagnostics-ideas.md` — recorded 2026-08-06, deliberately not
prioritized. Promote to a thread here if one gets picked up.

---

## How to update this file

Add a thread when you start real work on something; drop it to a one-line
"done/abandoned" note when it lands or dies. Keep the absolute date at the top
current. This lives on `claude-dev` — commit changes there, don't stage it into
a feature-branch PR.
