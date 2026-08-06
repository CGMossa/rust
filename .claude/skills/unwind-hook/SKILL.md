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
`create_final_unwinding`; rebased onto upstream/main and then reworked
2026-08-06 — truthful `was_caught`, lock-free invocation, Arc API; all 8 UI
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
use std::sync::Arc;

panic::set_unwind_hook(Arc::new(|info: &panic::UnwindCompletionInfo<'_>| {
    let payload: &(dyn std::any::Any + Send) = info.payload();
    let caught: bool = info.was_caught();
    // safe point: all Rust drops on this thread's unwind path have run
}));
let prev = panic::take_unwind_hook(); // Option<Arc<_>>; re-registerable as-is
```

Compile/run: `rustc +rust-unwind-hook file.rs` or `cargo +rust-unwind-hook …`.

## Semantics (verified on the reworked branch)

- **The hook fires exactly once per completed unwind.** `was_caught` is
  `true` for a user-level `catch_unwind` recovery (program continues);
  `false` when the unwind ended the thread's normal execution: thread/`main`
  roots (destructors ran; spawned threads still deliver the payload to
  `join()`) and non-unwinding aborts (`panic=abort`, nounwind panics,
  `immediate-abort`; destructors did NOT run). **A diverging FFI handoff
  keys off `!info.was_caught()`** — at that point the thread runs no
  further user code.
- **Suspend-and-rethrow catches are invisible**: the runtime's internal
  catches that always continue the unwind (`thread::scope` closure panics,
  TLS destructor cleanup) do not fire the hook at all; it fires wherever
  the unwind finally lands. Internally three-way `CatchScope`:
  `User` (fires `true`), `ThreadRoot` (fires `false`,
  `panic::catch_unwind_root`), `Rethrow` (silent,
  `panic::catch_unwind_rethrow`).
- Caveat: user-level `resume_unwind` starts a *new* unwind of the same
  payload — a payload caught and re-thrown by user code through N user
  catch layers fires the hook N times (each user catch is a recovery).
- Inside the hook, `thread::panicking()` is `true`; calling
  `set_unwind_hook`/`take_unwind_hook` there panics (by design → nested
  panic → abort). The hook runs outside the `#[rustc_nounwind]` catch
  callback, before `panic_count::decrease()`.
- Invocation snapshots the `Arc` and releases the lock before calling: a
  diverging hook does NOT block other threads from calling set/take, and a
  panic caught inside the hook re-enters the invoke path safely.
- `panic=abort`: destructors do NOT run, but the hook still fires before the
  abort (wired via `__rust_invoke_unwind_hook` in `std::rt`, called from
  `panic_abort`).
- Unset hook = no-op; the panic path takes a read lock either way.

## Tests

`tests/ui/panics/unwind-completion-hook-{catch,payload,take,diverge,abort,uncaught,thread,scope}.rs`
```bash
./x test tests/ui/panics --test-args unwind-completion-hook
```

## Key files (for development)

- `library/std/src/panicking.rs` — `UNWIND_HOOK` storage (`Option<Arc<_>>`),
  `CatchScope`, set/take, `invoke_unwind_hook*`,
  `catch_unwind_with_scope` panic-path call site (ordering comment there is
  load-bearing).
- `library/std/src/panic.rs` — `UnwindCompletionInfo`, `catch_unwind_root`,
  `catch_unwind_rethrow`, re-exports, module docs.
- `library/std/src/thread/{lifecycle,scoped}.rs`,
  `library/std/src/sys/thread_local/os.rs` — runtime catch sites.
- `library/std/src/rt.rs` — `__rust_invoke_unwind_hook` internal symbol.
- `library/panic_abort/src/lib.rs` — abort-runtime call site.
- Unstable-book page: `src/doc/unstable-book/src/library-features/unwind-completion-hook.md`.
