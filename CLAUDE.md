# Working on rust-lang/rust

This is the main Rust repo: the compiler (`compiler/`), standard library
(`library/`), tools + docs (`src/`), and the test suites (`tests/`). It's one
giant cargo workspace, but **you almost never invoke `cargo` directly** — the
build system is `./x` (a wrapper over `x.py`). Use `cargo` only inside
standalone tools (e.g. `src/tools/rust-analyzer`) that say so.

The full contributor manual is in-tree at `src/doc/rustc-dev-guide/src/`
(the [rustc-dev-guide]). This file is the distilled operating cheat-sheet.

[rustc-dev-guide]: https://rustc-dev-guide.rust-lang.org/

## The `./x` build system

`./x <subcommand> [paths] [flags]`. Path suffixes are accepted, so
`./x build std` == `./x build library/std`, and `./x test tidy` works.

| Command | Use |
| --- | --- |
| `./x check` | Fast "does it compile?" — no codegen. First thing to run after edits. |
| `./x build <path>` | Build a component (e.g. `./x build library`, `./x build rustc`). |
| `./x test <path>` | Run a test suite (see Testing). |
| `./x fmt` | Format everything (uses the pinned rustfmt). |
| `./x doc <path> --open` | Build & open docs. |
| `./x clean` | Nuke `build/` **without** rebuilding LLVM (prefer over `rm -rf build`). |

### Stages (the thing that trips everyone up)

Bootstrap is staged: **stage0** = the downloaded beta compiler; **stage1** =
built by stage0 (this is what you normally test with); **stage2** = built by
stage1 (what CI ships, rarely needed locally).

- Compiler changes → `./x build` / `./x test` default to producing/using stage1.
- **std/library changes → run with `--stage 0`** for the fast path
  (`./x test --stage 0 library/std`). Stage 1 std requires building a stage1
  compiler first.
- `./x test` with **no path builds stage1 and runs the *entire* suite** (tests/,
  library/, compiler/, tools/) — minutes-to-hours. Never do this to check one
  thing; always pass a path.

### Fast iteration

- `./x check` on save is usually all you need while refactoring.
- `--keep-stage-std=1` reuses the existing std build to skip its rebuild
  (`./x build library --keep-stage-std=1`). If you get weird ICEs, drop the flag
  and rebuild — it's a deliberate cache bypass.
- `--incremental` (or `[rust] incremental=true` in `bootstrap.toml`) speeds up
  rebuilds at the cost of disk.
- Narrow tests with a path and/or `--test-args <substring>`.

## This checkout's config

`bootstrap.toml` here sets `profile = "library"`, `rust.download-rustc =
"if-unchanged"`, `build.submodules = false`, `build.docs = false`. Implications:

- **`download-rustc`**: if you *haven't* touched `compiler/`, bootstrap downloads
  a prebuilt compiler instead of building rustc — big time save for std/tool work.
- **Known caveat**: `./x test library/std` is broken while `download-rustc` is
  active (rust#142505). Workaround: `./x test library/std --set
  rust.download-rustc=false` (this forces a stage1 compiler build).
- `submodules = false` → you manage submodule checkouts yourself (see below).

## Repo layout

- `compiler/` — ~75 `rustc_*` crates. Entry: `rustc` (binary) → `rustc_driver` →
  `rustc_interface` → everything. `rustc_middle` holds the central data
  structures; `rustc_span`/`rustc_data_structures`/`rustc_errors` are the
  low-level foundations. `cargo tree -p rustc_driver` shows the real graph.
- `library/` — `core`, `alloc`, `std`, `proc_macro`, `test`, plus runtime bits
  (`backtrace`, `unwind`, `panic_*`, `rtstartup`). Several are submodules.
- `tests/` — compiler test suites (see Testing). Not cargo tests.
- `src/` — `rustdoc`, `bootstrap` (the build system itself), `tools/` (clippy,
  miri, rustfmt, rust-analyzer, cargo, …), and `doc/` (the books & dev-guide).
- `compiler/rustc_target/src/spec/` — target definitions (e.g. the
  `windows_gnu` base this branch edits).

## Testing

Test suites live under `tests/`; the big one is `tests/ui`. Run a subset:

```bash
./x test tests/ui                        # whole UI suite
./x test tests/ui/panics                 # one subdir
./x test tests/ui/panics/foo.rs          # one file
./x test tests/ui --test-args issue-1234 # filter by substring
./x test --stage 0 library/std           # std unit/integration tests
./x test tidy                            # style/lint checks (fast, run before pushing)
```

- UI tests compare compiler output against committed `.stderr`/`.stdout` files.
  When your change alters diagnostics, **regenerate them with `--bless`**:
  `./x test tests/ui/... --bless`, then review the diff — a blessed file is only
  correct if the new output is what you intended. (See the `/bless` skill.)
- Results are cached; passing tests are skipped. Use `--force-rerun` if a change
  isn't picked up.
- `tidy` failures block CI. `./x test tidy --bless` fixes the auto-fixable ones.

## Using the compiler you built

```bash
rustup toolchain link stage1 build/host/stage1
rustc +stage1 -vV     # version ends in -dev → it's your local build
cargo +stage1 build   # borrows cargo from your nightly/beta toolchain
```

The linked toolchain updates whenever you re-run `./x build`/`./x test`.

## Submodules vs subtrees

- **Submodules** (e.g. `library/backtrace`, `src/tools/cargo`, `src/llvm-project`
  — see `.gitmodules`): changes belong in the *upstream* repo, not here. A dirty
  submodule shows in `git status` as a commit-hash change; **don't stage a
  submodule bump** unless you deliberately mean to update the pin. Reset with
  `git -C library/backtrace checkout -- .` or
  `git submodule update --init library/backtrace`.
- **Subtrees** (e.g. clippy, rustfmt, miri, rust-analyzer): edited in-tree, but
  prefer a PR to the subtree's own repo when the change doesn't need to land with
  a compiler change. `src/tools/rust-analyzer/CLAUDE.md` has its own guidance.

## Contribution norms

- PRs target `main`; keep history rebased (no merge commits — CI flags them).
- CI runs against current `main`, not your base — only rebase when you hit
  conflicts or a maintainer asks.
- **Disclose AI assistance** in commit messages / PR descriptions. Undisclosed
  AI-assisted contributions may be rejected outright.
- `@rustbot` and `@bors` drive review/merge; `./x test tidy` must pass.
