# mir-lens: the inlined-calculation lens

This branch (`mir-lens-for-science`) is rust-lang/rust plus two things:

- **A compiler patch** that adds `-Zinline-mir-history-depth-limit` and
  `-Zinline-mir-top-down-depth-limit`. The same commit lives alone on
  `inline-mir-depth-limit-flags`.
- **This directory**, which holds the lens tooling.

The lens shows the *composed* floating-point computation of a Rust program.
It flattens every call into its caller using forced MIR inlining, then
pretty-prints the result with loops kept as loops. Accuracy hazards that sit
across function boundaries become visible: cancellation in stopping
criteria, divide-then-rescale round trips, and values recomputed from
rounded intermediates.

| File | What it is |
| --- | --- |
| `mir_lens.py` | The pretty-printer. Python 3, standard library only. |
| `mir-lens-intro.typ` | A motivating introduction. Render it with `typst compile mir-lens-intro.typ`. |
| `numerical-accuracy-lens.md` | Design notes, the proof of concept, and scale tests on real crates. |

## 1. Build the toolchain (once)

You need rustup, git, python3, curl and a C compiler. On macOS that means the
Xcode Command Line Tools. The build also needs 30 GB+ of free disk, 8 GB+ of
RAM, and roughly 30–60 minutes.

```bash
git clone --filter=blob:none --single-branch --branch mir-lens-for-science \
  https://github.com/CGMossa/rust.git rust-mir-lens
cd rust-mir-lens
cat > bootstrap.toml <<'EOF'
change-id = "ignore"
profile = "library"        # CI LLVM, no debug assertions
[build]
docs = false
[rust]
download-rustc = false     # compiler/ is patched, so build rustc locally
EOF
./x build library
```

Don't use `--depth 1`. Bootstrap walks the history to find which CI LLVM to
download, and a depth-1 clone fails with `could not find commit hash for
downloading LLVM`. Avoid `profile = "compiler"`: its debug assertions make
the resulting rustc slow.

## 2. Snapshot it and register it with rustup

```bash
SNAP=~/rust-toolchains/mir-lens-$(date +%F)
mkdir -p ~/rust-toolchains
cp -Rc build/host/stage1 "$SNAP"                 # Linux: cp -a --reflink=auto
rustup toolchain link rust-mir-lens "$SNAP"
rustc +rust-mir-lens -Z help | grep inline-mir   # must list both depth-limit flags
```

Take a snapshot rather than linking `build/host/stage1` directly, because the
next `./x build` changes that directory. Keep the snapshot outside `build/`,
since `./x clean` deletes everything under `build/host/` except LLVM.

The snapshot has no `cargo`. rustup borrows one from the first installed of
nightly, beta and stable, in that order; your default toolchain doesn't
matter. To pick a specific cargo yourself, run
`RUSTC="$(rustup which --toolchain rust-mir-lens rustc)" cargo …`.

## 3. Run the lens

Never lens a whole application. Make a small wrapper crate that depends on
the library under review, with one thin `pub fn` per computation of interest.
Run this from the wrapper crate's directory:

```bash
RUSTFLAGS="-Zcross-crate-inline-threshold=always" \
  cargo +rust-mir-lens rustc --release -- \
  -Zmir-opt-level=2 -Zinline-mir=yes \
  -Zinline-mir-threshold=100000 -Zinline-mir-hint-threshold=100000 \
  -Zinline-mir-history-depth-limit=64 -Zinline-mir-top-down-depth-limit=100000 \
  -Zinline-mir-preserve-debug=yes \
  --emit=mir="$PWD/lens.mir"
```

What the flags do:

- `RUSTFLAGS` applies to every crate, so dependencies encode MIR that can be
  inlined.
- The flags after `--` apply only to the wrapper crate.
- `history-depth-limit=64` is the sweet spot. Much larger values can blow
  up compile times on generic-heavy crates.
- `--emit=mir=<absolute path>` writes exactly one file, whatever your cargo
  version or target dir.

Cargo skips the compile when nothing changed, so `touch src/lib.rs` before
re-running. To keep the wrappers inside the reviewed repo, add an
`examples/mir_lens.rs` with `[[example]] name = "mir_lens"` and
`crate-type = ["lib"]`, then add `--example mir_lens`. Don't use a
feature-gated module for this, because then the inliner chews through the
whole library.

To check that inlining happened, run `grep -c inlined lens.mir`, which should
be large. The surviving calls, from
`grep -oE '= [A-Za-z_][^(]*\(' lens.mir | sort | uniq -c`, should be only
intrinsics, arithmetic and panic paths.

## 4. Read it

```bash
python3 mir-lens/mir_lens.py lens.mir --fn <name>                 # one function
python3 mir-lens/mir_lens.py lens.mir --fn <name> --fp-core       # float dataflow + loops
python3 mir-lens/mir_lens.py lens.mir --fn <name> --fp-core --scope <callee>
python3 mir-lens/mir_lens.py lens.mir --fn <name> --fp-core --floor libm
```

- `--scope X` slices to everything inlined from `X`, plus whatever consumes
  its results.
- `--floor X` collapses `X`'s internals into one `⟨X: N stmts elided⟩` line.

Here is a Newton square root spread across eight small functions in a
dependency crate. The stopping test compares two nearly equal values:

```
fn w_sqrt(a: f64) -> f64
  bb0:
    x = a   ← newton_sqrt
    goto bb1
  bb1 (loop head):
    _3 = x   ← newton_sqrt
    RET = (_3 + (a / _3)) * 0.5
    goto bb4
  bb3:
    x = RET   ← newton_sqrt
    goto bb1 [loop back-edge]
  bb4:
    switch fabs(RET - x) <= 9.9999999999999998E-13 -> 0: bb3, otherwise: bb2
```

## Updating

This branch gets rebased onto upstream, so reset your clone instead of
pulling it:

```bash
git fetch origin && git reset --hard origin/mir-lens-for-science
./x build library
```

Then snapshot into a new `$SNAP` and run `rustup toolchain link` again.
Linking an existing name re-points it.

`rustup toolchain uninstall rust-mir-lens` removes only the link; the
snapshot directory stays.
