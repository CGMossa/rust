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

## 2. Windows-GNU `function_sections`

- **Branch:** `enable-windows-gnu-function-sections` — rebuilt 2026-08-06 as a
  single commit (`650a46f1f84`) on upstream/main (7608eb7b07e).
- **Goal:** Flip `function_sections: false → true` in
  `compiler/rustc_target/src/spec/base/windows_gnu.rs` to test whether
  `--gc-sections` now strips dead functions on PE/COFF (binutils #11539).
  Mechanism: rustc already passes `--gc-sections` to GNU ld for windows-gnu
  executables (`GccLinker::gc_sections` in
  `rustc_codegen_ssa/src/back/linker.rs`), but without function sections each
  CGU is one monolithic `.text`, so ld has per-CGU granularity at best.
- **Status:** the flip, previously only in `stash@{0}`, is now committed on
  the branch (`./x check compiler/rustc_target` passes). `stash@{0}` is now
  redundant (its tracked diff was only the flip — despite the message, no
  backtrace bump was in it); safe to `git stash drop` after a look.
  `stash@{1}` (old `create_final_unwinding` WIP) and `stash@{2}` (old master
  WIP) also look like relics. The unrelated commits the branch used to carry
  were rehomed: `target-cpu-categories.md` now lives on `claude-dev`; the
  "minor doc improvement" commit already exists on `minor_edits`/`master`.
  Old branch tip `fc4293febfa` (reflog) if anything was missed.
- **Validation (done 2026-08-06, static only):** cross-built from macOS with
  Homebrew mingw-w64 (GCC 16.1.0, **binutils 2.46.1**). Setup: bootstrap.toml
  gained a `[target.x86_64-pc-windows-gnu]` cc/ar/linker section (kept);
  build: `./x build library --target aarch64-apple-darwin,x86_64-pc-windows-gnu`
  (58s — only rustc_target + deps rebuilt). Toolchain `rust-win-gnu-fs` →
  `build/host/stage1-win-gnu-fs` snapshot. Harness in
  `win-gnu-fs-validation/` (this branch): A = branch default (fs+gc),
  B = branch + `-Wl,--no-gc-sections`, C = rustup nightly baseline.
  **Results (hello.rs, `-O`, fully stripped):** A 815,104 B 870,912
  C 877,056 bytes → **7.1% smaller than baseline**; `.text` 616,272 vs
  651,536. All links succeed; gc collected 700 real dead std functions
  (gimli/object internals, `Condvar::notify_*`, …).
  **Correctness:** SEH function table intact — every collected function was
  pdata-less; all kept panic/unwind-path functions have valid entries; no
  dangling `.pdata`.
  **Key limitation found:** GNU ld keeps the whole `.pdata` table and each
  entry's reloc roots its function (no `.eh_frame`-style pruning for PE;
  non-COMDAT `.pdata$x` isn't associative), so gc can only collect functions
  *without* unwind info — 534 dead-but-kept `std::process`/`net`/`SystemTime`
  functions carry pdata. That caps the win at ~6–7%, not Linux-style wins.
- **rust-lld experiment (2026-08-07):** linked the same artifacts with
  rust-lld's MinGW driver (LLD 22.1.8 from the nightly dist; Homebrew's gcc
  has `--with-ld` hardwired, so a replay driver
  `scratchpad/lld-shim/lldgcc.py` captures the `gcc -###` collect2 line,
  strips `-plugin*`, and re-executes it with `rust-lld -flavor gnu`).
  Results (hello.rs, fully stripped):
  | linker + std | fullstrip | .text | #pdata funcs |
  |---|---|---|---|
  | GNU ld + fs (gc) | 815,104 | 616,272 | 1720 |
  | **lld + fs (gc)** | **276,992** | **213,984** | **471** |
  | lld + nightly std (gc) | 878,080 | 651,632 | 1717 |
  **The flip is the prerequisite for lld's win**: on COFF,
  `function_sections` emits each function as a COMDAT, and lld's gc
  collects dead COMDATs *with* their associative `.pdata$`/`.xdata$`
  (correct unwind pruning — the machinery GNU ld lacks). fs+lld =
  **68% smaller** hello vs today's default; lld+monolithic std = no win.
  lld also never collects regular (non-COMDAT) sections, so linkme-style
  section magic is **safe under lld by construction** (all elements +
  dupcheck survive, patched or not; drectve `/INCLUDE` moot). Note: lld
  truncates PE section names to 8 bytes (`.linkme_PLUGINS` → `.linkme_`) —
  harmless (linkme reads via marker symbols), but section-name-based
  inspection must account for it.
- **Plain-exe linkme regression test (unpatched linkme 0.3.37, cargo bin,
  elements in bin + dep crate):** today's world (nightly + GNU ld, rustc
  passes `--gc-sections` for windows-gnu exes) **already silently loses
  the bin crate's elements** — slice len 1 of 3, no diagnostics. The fs
  flip makes it total (0 of 3, dupcheck gone). lld keeps all 3 with either
  std. So linkme on windows-gnu is broken *today*; the flip changes
  silent-partial to deterministic-empty; lld (or the .jcr patch) fixes it.
- **Upstream decision (2026-08-07): worth proposing — as a two-step
  story.** (1) The flip itself: removes the 2014 `FIXME(#13846)` (binutils
  bug long fixed), aligns windows-gnu with every other major target
  (msvc/linux already default `function_sections: true`), gives ~7% with
  GNU ld, no link/unwind-table regressions found; tier-1 CI would provide
  the missing runtime validation. (2) Its real payoff is enabling a later
  rust-lld default for windows-gnu (rust-lld already ships): fs+lld =
  ~68% smaller binaries *and* fixes the `#[used]`-section-magic ecosystem
  (linkme et al., silently broken today). PR must disclose the GNU-ld
  linkme interaction (partial→total loss) and point at the crate-side fix
  (`linkme-gnu-gc-anchor.patch`); i686-pc-windows-gnu shares the base spec
  and is untested locally — flag for CI. Remaining before filing: run a
  windows-gnu CI/wine runtime pass.
- **Original motivation (recovered 2026-08-06):** `linkme` distributed
  slices failing in **staticlib outputs on windows-gnu** (the R/Rtools
  ecosystem: R packages link Rust staticlibs into package DLLs with the
  MinGW toolchain). Repro + matrix in
  `win-gnu-fs-validation/linkme-test/` (elements P1–P4 = `0xAAAA0001..4`,
  P4 registered in a crate nothing references). Findings (binutils 2.46.1):
  1. **Member-pull loss (always, no gc needed):** an element in an archive
     member with no inbound symbol reference (P4) silently never links —
     exe and DLL alike. Fix: `--whole-archive` or a symbol reference.
  2. **`--gc-sections` loss:** stock rustc keeps only some elements
     (erratic — P1 survived, P2/P3 dropped); with the function_sections
     flip **all** elements are collected. `--whole-archive` does NOT help.
  3. **Root cause:** `#[used]` is a link-time no-op on windows-gnu — rustc/
     LLVM emit **no `.drectve` `/INCLUDE`** for MinGW (microtest: even a
     `pub #[no_mangle] #[used]` static in a custom section is gc'd), and
     COFF has no `SHF_GNU_RETAIN` equivalent for GNU ld.
  So the fs flip does **not** fix the linkme motivation — it makes the gc
  case strictly worse. **Two validated fixes (2026-08-06):**
  1. **User-side linker script:** `KEEP(*(SORT_BY_NAME(.linkme_*)))` etc.
     inside `SECTIONS { … } INSERT AFTER .text;`, passed as
     `-Wl,-T,keep-linkme.ld` (must be `-T`; implicit-script form fails, and
     `INSERT AFTER .rdata` fails — `.text` works). Both the per-slice and
     the generic wildcard script are committed
     (`win-gnu-fs-validation/linkme-test/keep-linkme*.ld`). With
     `--whole-archive` + the script, all 4 elements survive gc in exe & DLL.
  2. **Crate-side linkme patch (candidate upstream PR):** each element (and
     the declaration's DUPCHECK) also emits, on
     `all(windows, target_env = "gnu")`, a **data-only anchor**: a pointer
     to it in the KEEP'd `.jcr` list — GC mark chain: `.jcr` (KEEP) →
     relocation → element section. `.jcr` is never walked on MinGW
     (`_Jv_RegisterClasses` is always null), so this is purely link-time —
     **no startup code**, preserving linkme's compile-time-only contract
     (a first `.ctors`-based version was rejected for exactly that reason:
     ctors are runtime registration, linkme is compile-time). Cost per
     element: one 8-byte pointer. Validated: patched linkme 0.3.37 keeps
     all elements + dupcheck under `--gc-sections` with NO special link
     flags (exe & DLL, both toolchains). Dead-end note for the same goal:
     GNU ld ignores drectve `/INCLUDE`, and `#[used(linker)]` emits
     nothing for MinGW. Patch:
     `win-gnu-fs-validation/linkme-test/linkme-gnu-gc-anchor.patch`
     (against linkme-impl 0.3.37 `src/{element,declaration}.rs`; apply via
     registry copy + `[patch.crates-io]`).
  3. **Member-pull without `--whole-archive`: fat LTO.** `lto = "fat"` in
     the release profile merges all Rust crates into one archive member,
     so the C side's existing reference (e.g. `plugin_count`) pulls
     everything — including registration-only crates. `#[used]` retention
     holds at the compiler level through LTO. Validated: patch + fat LTO =
     **all 4 elements + dupcheck present in every configuration** (exe &
     DLL, gc on/off, both toolchains) with zero special linker flags.
     (Thin LTO likely insufficient — keeps per-module objects.)
  **Recommended stack for R/Rtools packages:** patched linkme + `lto =
  "fat"`; no Makevars linker gymnastics needed.
  Dead ends tested: GNU ld does **not** honor `.drectve` `/INCLUDE` (nor
  `-include:`) — "corrupt .drectve" warning, symbol still stripped — so
  the MSVC retention mechanism cannot be ported; a drectve-emitting trick
  only helps with lld-MinGW (untested). Member-pull (P4) is fixable only
  by `--whole-archive`/symbol references on every platform. Runtime
  behavior still needs wine/Windows CI (static section analysis only).

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
