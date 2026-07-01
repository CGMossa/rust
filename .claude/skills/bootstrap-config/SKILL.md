---
name: bootstrap-config
description: Pick and write a bootstrap.toml for rust-lang/rust tuned to what you're working on (std/library, compiler, codegen/LLVM, tools, or cross-compiling). Use when the user asks to set up, switch, or optimize their bootstrap.toml / build config, complains that builds are too slow, or starts working on a different part of the tree than their current config targets.
---

# Choosing a bootstrap.toml

`bootstrap.toml` (repo root) configures `./x`. `profile = "..."` pulls defaults
from `src/bootstrap/defaults/bootstrap.<profile>.toml`; anything you set in
`bootstrap.toml` overrides them. `./x setup` generates these interactively —
this skill is the copy-paste shortcut plus the reasoning.

**First, identify what the user is changing** (ask if unclear — it's the whole
decision): the standard library, the compiler, codegen/LLVM, a tool, or building
for another target. Then write the matching config below.

**The two knobs that dominate build time:**
- `rust.download-rustc` — `"if-unchanged"` downloads a prebuilt rustc so you skip
  building the compiler *unless* `compiler/` changed; `false` always builds it.
  Use `false` only when you're editing the compiler. ⚠️ `./x test library/std`
  is currently broken while this is active (rust#142505) — see notes.
- `llvm.download-ci-llvm` — `true` downloads prebuilt LLVM (default, saves ~hours).
  Set `"if-unchanged"` or `false` only if you modify `src/llvm-project`.

`change-id = "ignore"` silences "config schema changed" warnings — keep it.

---

## Scenario 1 — Standard library / `library/` work (current default here)

Editing `core`/`alloc`/`std` etc., not the compiler. Fastest std iteration.

```toml
change-id = "ignore"
profile = "library"

[build]
docs = false
submodules = false

[rust]
# "if-unchanged" = reuse prebuilt rustc while compiler/ is untouched (fast).
# Switch to false if `./x test library/std` misbehaves (rust#142505), which
# forces a stage1 compiler build.
download-rustc = "if-unchanged"
```

Run std tests with `./x test --stage 0 library/std`.

---

## Scenario 2 — Compiler work (no codegen/LLVM changes)

The common `rustc_*` case: types, diagnostics, MIR, resolution, etc. Turns on
debug assertions and `debug!`/`RUSTC_LOG` logging, downloads LLVM, builds rustc.

```toml
change-id = "ignore"
profile = "compiler"

[rust]
# You're changing the compiler, so it must be built (not downloaded).
download-rustc = false

[llvm]
# Not touching LLVM → grab the prebuilt one.
download-ci-llvm = true
```

The `compiler` profile already enables `debug-assertions`, `debug-logging`,
`incremental`, `compiler-docs`, and `line-tables-only` debuginfo. Iterate with
`./x check`; build/test with default stage1.

---

## Scenario 3 — Codegen or LLVM changes

Editing `src/llvm-project`, `rustc_codegen_llvm`, or `rustc_llvm`. LLVM must be
built locally, which is slow the first time.

```toml
change-id = "ignore"
profile = "compiler"

[rust]
download-rustc = false

[llvm]
# Rebuild LLVM only when src/llvm-project actually changes.
download-ci-llvm = "if-unchanged"
# Turn on if you need LLVM's own assertions while debugging codegen.
assertions = false
```

---

## Scenario 4 — Tools (clippy, rustfmt, miri, rustdoc, cargo)

Building on the compiler API without modifying the compiler. Downloads a
prebuilt rustc; tests run at stage 2 (stage 1 doesn't pass for these tools).

```toml
change-id = "ignore"
profile = "tools"

[llvm]
download-ci-llvm = true
```

The `tools` profile sets `download-rustc = "if-unchanged"`, `test-stage = 2`,
`doc-stage = 2`, and `tidy-extra-checks` for js/py/cpp/spellcheck.

---

## Scenario 5 — Cross-compiling / target-spec work

Building a compiler that targets another platform (e.g. the `windows_gnu` /
target-spec work). Layer `build.target` onto whichever base profile fits — use
`compiler` if you're editing target specs in `rustc_target`.

```toml
change-id = "ignore"
profile = "compiler"

[build]
# Always build support for these targets. Include the host explicitly if you
# want the built compiler to run proc-macros/build-scripts.
target = ["x86_64-unknown-linux-gnu", "x86_64-pc-windows-gnu"]

[rust]
download-rustc = false

[llvm]
download-ci-llvm = true

# Target-specific paths (musl, custom LLVM, etc.) go under [target.<tuple>]:
# [target.x86_64-pc-windows-gnu]
# llvm-config = "/path/to/llvm-config"
```

Then build with `./x build --target x86_64-pc-windows-gnu` and cross-compile via
`cargo +stage1 build --target x86_64-pc-windows-gnu`. Some targets need external
deps (e.g. musl) — see `bootstrap.example.toml` for per-target keys.

---

## Notes

- `bootstrap.example.toml` documents every option; `src/bootstrap/defaults/` has
  the profile presets.
- Config extensions: put reusable fragments in their own file and reference them
  with `include = ["cross.toml"]` (right-to-left override; parent wins).
- After LLVM-related config changes, run `./x clean --all` for them to take
  effect (won't rebuild LLVM itself).
- Overriding for one command instead of editing the file:
  `./x test library/std --set rust.download-rustc=false`.
