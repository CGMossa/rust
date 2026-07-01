# Experiments & active work threads

Running log of what we're hacking on in this checkout, so a fresh session
knows the state without spelunking through branches. Tracked only on
`claude-dev` (see the "Working with claude-dev" section in `CLAUDE.md`).

_Last updated: 2026-07-01._

---

## 1. Unwind completion hook (std)

- **Branch:** `create_final_unwinding` (superseded early cut: `add_final_unwinding`, empty)
- **Goal:** A global hook that runs **after** all Rust unwinding/drops complete,
  so an FFI function can take control of the program once Rust has cleaned up.
  Primary use case: a diverging (`-> !`) FFI handoff at end of unwind.
- **API:** `std::panic::{set_unwind_hook, take_unwind_hook}` +
  `UnwindCompletionInfo { payload(), was_caught() }`. Library feature gate
  `unwind_completion_hook` (unstable, no compiler feature entry needed).
- **Key files:** `library/std/src/{panic,panicking,rt}.rs`,
  `library/panic_abort/src/lib.rs`, unstable-book doc, 5 UI tests in
  `tests/ui/panics/unwind-completion-hook-*.rs`.
- **Toolchain:** built std is linked as rustup toolchain `rust-unwind-hook`
  (`./x build library/std` then `rustup toolchain link rust-unwind-hook build/host/stage1`;
  re-link not needed after rebuilds — rustup points at the build dir).
- **Status:** implemented on branch. Design notes in
  `unwind-completion-hook-plan.md`; usage/API in `INSTRUCTIONS.md` (both on that
  branch). Branch is ~7 months behind upstream — rebase before continuing.

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

---

## How to update this file

Add a thread when you start real work on something; drop it to a one-line
"done/abandoned" note when it lands or dies. Keep the absolute date at the top
current. This lives on `claude-dev` — commit changes there, don't stage it into
a feature-branch PR.
