---
name: unwind-hook
description: Use or develop the experimental std unwind-completion hook - a global callback that runs after all Rust unwinding/drops complete, so an FFI function can take control post-cleanup. Use when the user wants code to run after unwinding finishes, a diverging FFI handoff at end of panic, mentions "unwind hook", "unwind completion", set_unwind_hook, or works on the unwind-completion-hook branch.
---

# The unwind completion hook (experimental std feature)

A global hook invoked **after** all destructors have run during unwinding —
just before `catch_unwind` returns `Err` — and, in non-unwinding abort paths
(`panic=abort`, nounwind panics, `immediate-abort`), right before the abort.
Primary use case: a diverging (`-> !`) FFI handoff once Rust cleanup is done.

Everything lives on branch **`unwind-completion-hook`** (renamed from
`create_final_unwinding`; rebased onto upstream/main 2026-08-06, all 5 UI
tests passing). Design notes: `unwind-completion-hook-plan.md`; usage doc:
`INSTRUCTIONS.md` (both tracked on that branch). Library feature gate:
`unwind_completion_hook` (unstable, library-only — no compiler change).

## Toolchain

Prebuilt: rustup toolchain `rust-unwind-hook` → `build/host/stage1-unwind-hook`
(a snapshot; safe from stage1 rebuilds, but `./x clean` removes it).

Rebuild when stale/missing:
```bash
git switch unwind-completion-hook
./x build library
cp -Rc build/host/stage1 build/host/stage1-unwind-hook
rustup toolchain link rust-unwind-hook build/host/stage1-unwind-hook
```
Never link toolchains at the mutable `build/host/stage1` — snapshot first.

## API

```rust
#![feature(unwind_completion_hook)]
use std::panic;

panic::set_unwind_hook(Box::new(|info: &panic::UnwindCompletionInfo<'_>| {
    let payload: &(dyn std::any::Any + Send) = info.payload();
    let caught: bool = info.was_caught();
    // safe point: all Rust drops on this thread's unwind path have run
}));
let prev = panic::take_unwind_hook(); // restore default (no-op), returns old
```

Compile/run: `rustc +rust-unwind-hook file.rs` or `cargo +rust-unwind-hook …`.

## Semantics (verified on the rebased branch)

- Fires once per completed unwind segment: every `catch_unwind` that catches
  a panic fires it — so a payload re-thrown with `resume_unwind` through N
  catch layers fires the hook N times.
- **`was_caught` is `true` even for "uncaught" panics** that kill a thread or
  main, because the runtime's own `catch_unwind` (in `lang_start` /
  `thread::spawn`) is what catches them. `false` occurs only on
  non-unwinding paths: `panic=abort`, panics that can't unwind (nounwind /
  double panic), `immediate-abort`. (Known doc/API wart — the docs' claim
  that thread-termination reports `false` is wrong; see review notes in
  EXPERIMENTS.md thread 1.)
- Inside the hook, `thread::panicking()` is `true`; calling
  `set_unwind_hook`/`take_unwind_hook` there panics (by design → nested
  panic → abort). The hook runs outside the `#[rustc_nounwind]` catch
  callback, before `panic_count::decrease()`.
- A diverging hook holds the internal `RwLock` read guard forever; other
  threads calling set/take will block indefinitely — fine for the intended
  "hand off and never return" use, but don't diverge casually.
- `panic=abort`: destructors do NOT run, but the hook still fires before the
  abort (wired via `__rust_invoke_unwind_hook` in `std::rt`, called from
  `panic_abort`).
- Unset hook = no-op; the panic path takes a read lock either way.

## Tests

`tests/ui/panics/unwind-completion-hook-{catch,payload,take,diverge,abort}.rs`
```bash
./x test tests/ui/panics --test-args unwind-completion-hook
```

## Key files (for development)

- `library/std/src/panicking.rs` — `UNWIND_HOOK` storage, set/take,
  `invoke_unwind_hook*`, the `catch_unwind` panic-path call site (ordering
  comment there is load-bearing).
- `library/std/src/panic.rs` — `UnwindCompletionInfo`, re-exports, module docs.
- `library/std/src/rt.rs` — `__rust_invoke_unwind_hook` internal symbol.
- `library/panic_abort/src/lib.rs` — abort-runtime call site.
- Unstable-book page: `src/doc/unstable-book/src/library-features/unwind-completion-hook.md`.
