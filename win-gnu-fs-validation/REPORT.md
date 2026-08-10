# Windows-GNU `function_sections` — contribution report

*Status: wrapped 2026-08-07. Branch ready; filing gated only on a Windows
runtime pass (CI or wine). Everything here was measured in this checkout;
reproduction tools are committed alongside this file.*

## Executive summary

Flipping `function_sections: false → true` in the windows-gnu target base is
a 6-line change (plus comment) that:

- gives **−7%** binary size with the GNU ld toolchain rustc uses today
  (capped by a structural GNU-ld limitation, analyzed below), and
- is the **prerequisite** for rust-lld's PE garbage collection, which
  delivers **−68%** on the same test and prunes unwind tables correctly.

Verdict: **worth contributing**, framed as step 1 of a two-step story whose
payoff is a later rust-lld default for windows-gnu. The PR must disclose an
interaction with `#[used]`-section-magic crates (linkme) — which are
**already silently broken on windows-gnu today** — and point at the
crate-side fix developed here.

## The change

Branch `enable-windows-gnu-function-sections`, single commit `cb3226e7f1f`,
one file: `compiler/rustc_target/src/spec/base/windows_gnu.rs` (lines 83–88
on the branch):

```diff
-        // FIXME(#13846) this should be enabled for windows
-        function_sections: false,
+        // Historically disabled because GNU ld could not gc-sections PE/COFF
+        // at all (#13846, binutils PR 11539); long since fixed. Enabling this
+        // lets --gc-sections (which rustc already passes for executables)
+        // drop dead functions, and lets lld also prune the associated
+        // .pdata/.xdata unwind info.
+        function_sections: true,
```

Context:

- `TargetOptions` defaults to `function_sections: true`
  (`compiler/rustc_target/src/spec/mod.rs:2881`). Only four bases override
  it: `windows_gnu`, `aix`, `cygwin`, `apple` (apple uses `-dead_strip`
  instead). windows-msvc and linux already run with it on.
- rustc **already passes `--gc-sections`** to GNU-flavored linkers for
  non-dylib outputs (`GccLinker::gc_sections`,
  `compiler/rustc_codegen_ssa/src/back/linker.rs:668–694`) — today it just
  has nothing sub-object to collect on windows-gnu.
- rustc ties `fdata_sections` to `ffunction_sections`
  (`rustc_codegen_llvm/src/back/write.rs`), so the flip also enables
  per-data-item sections.
- On COFF, "function sections" means each function is emitted as a
  **COMDAT** section (`.text$<mangled-name>`), with unwind info in
  COMDAT-associative `.pdata$x`/`.xdata$x` sections.

## Measured yield

Test setup: `hello.rs`/`medium.rs` at `-O`, target `x86_64-pc-windows-gnu`,
cross-linked from macOS with Homebrew mingw-w64 (GCC 16.1.0, **binutils
2.46.1**) and rust-lld (LLD 22.1.8 from the nightly dist). "fullstrip" =
`x86_64-w64-mingw32-strip` (removes COFF symtab + DWARF). #funcs =
`.pdata` size / 12 (one RUNTIME_FUNCTION per unwind-carrying function).

### GNU ld (the linker rustc drives today)

| hello.rs | fullstrip | `.text` | `.pdata` | #funcs |
|---|---|---|---|---|
| A: flip + `--gc-sections` | 815,104 | 616,272 | 20,640 | 1720 |
| B: flip + `--no-gc-sections` | 870,912 | 658,896 | 20,640 | 1720 |
| C: nightly baseline (gc passed, ineffective) | 877,056 | 651,536 | 20,604 | 1717 |

**A vs C = −7.1%.** All links clean; no unwind-table inconsistencies: every
function gc removed (700 symbols, ~42.6 KB — gimli/object backtrace
internals, `Condvar::notify_*`, `core::str` helpers…) was pdata-less, and
all kept panic-path functions have valid `.pdata` entries.

**Why only 7%:** GNU ld must keep the whole `.pdata` table (the OS loader
consumes it), and each entry's relocation into its function *roots* that
function. There is no `.eh_frame`-style pruning for PE in GNU ld, and the
non-COMDAT `.pdata$x` sections in rlib objects aren't associative for it.
Verified directly: 549 obviously-dead symbols (`std::process`, `std::net`,
`SystemTime` machinery in a hello world) survive in A, 534 of them carrying
pdata. GNU ld can only ever collect unwind-info-free functions.

### rust-lld (MinGW driver)

| hello.rs | fullstrip | `.text` | #funcs |
|---|---|---|---|
| lld + flip, gc | **276,992** | **213,984** | **471** |
| lld + flip, no-gc | 894,464 | 658,848 | 1724 |
| lld + nightly std, gc | 878,080 | 651,632 | 1717 |

**−68% vs today's default.** lld's PE gc collects dead COMDATs *together
with* their associative `.pdata$`/`.xdata$` — correct unwind pruning by
construction. Row 3 is the key sequencing fact: against a monolithic std,
lld finds nothing to collect. **The flip is what unlocks lld's win.**

(medium.rs, GNU ld: A `.text` 638,992 / B 682,192 / C 674,832 — same ~6%
shape.)

## The linkme interaction (must be disclosed in the PR)

`#[used]` provides **no link-time retention on windows-gnu**: LLVM emits no
`.drectve /INCLUDE:` for MinGW objects (verified: no `.drectve` section at
all), GNU ld ignores such directives anyway (`Warning: corrupt .drectve`,
symbol still stripped — both `/INCLUDE:` and `-include:` spellings), and
COFF has no `SHF_GNU_RETAIN`. Consequences, measured with linkme 0.3.37
(elements P1 in a dep crate, P2/P3 in the main crate, P4 in a
never-referenced crate):

| configuration | P1 | P2 | P3 | P4 |
|---|---|---|---|---|
| **today**: plain cargo bin, nightly + GNU ld (rustc passes gc) | y | – | – | n/a |
| flipped: same + fs toolchain | – | – | – | n/a |
| staticlib→exe/DLL, external gc link, nightly | y | – | – | – |
| staticlib→exe/DLL, external gc link, fs | – | – | – | – |
| any of the above with rust-lld | y | y | y | y* |

\* P4 (unreferenced archive member) additionally needs `lto = "fat"` (one
merged member) or `--whole-archive` — plain static-archive semantics,
identical on MSVC.

Read the first row again: **linkme is broken on windows-gnu today** — a
release-mode binary keeps 1 of 3 elements, silently. The flip changes
silent-partial to deterministic-empty under GNU ld; rust-lld (which never
collects non-COMDAT sections) fixes it entirely.

### Fixes developed and validated

1. **Crate-side linkme patch — the right long-term fix**
   (`linkme-test/linkme-gnu-gc-anchor.patch`, 32 lines against linkme-impl
   0.3.37 `src/{element,declaration}.rs`; PR text in
   `linkme-test/linkme-pr-draft.md`): on windows-gnu each element (and the
   declaration's DUPCHECK) also emits an 8-byte **pointer in the KEEP'd
   `.jcr` list** → GC mark chain `.jcr (KEEP) → relocation → element`.
   `.jcr` is data and never walked on MinGW (`_Jv_RegisterClasses` is a
   null weak), so this is purely link-time — **no startup code**, honoring
   linkme's compile-time contract. (A first `.ctors`-based version was
   rejected for exactly that reason: ctors are runtime registration.)
   Inert under lld/MSVC. Validated green across the whole matrix.
2. **User-side linker script** (`linkme-test/keep-linkme*.ld`):
   `KEEP(*(SORT_BY_NAME(.linkme_*)))` in `SECTIONS { … } INSERT AFTER
   .text;` passed as `-Wl,-T,keep-linkme.ld` (must be `-T`; `.rdata` anchor
   fails). Works without touching linkme.
3. **`lto = "fat"`** replaces `--whole-archive` for the member-pull case.

Recommended stack for R/Rtools packages (Rust staticlib into package DLL):
patched linkme + `lto = "fat"` — no Makevars linker gymnastics.

## Considerations checklist for the rustc PR

- **Runtime validation gap (the filing gate):** all local verification is
  static section/symbol analysis — no wine on this machine. A tier-1
  windows-gnu CI run (or one wine pass of the panic/unwind suite) closes it.
- **i686-pc-windows-gnu** shares the base spec; untested locally.
- **linkme-class crates:** disclose the partial→total change under GNU ld
  and link the crate-side fix. Arguably an argument *for* determinism.
- **Old binutils in the wild:** users' own MinGW toolchains vary; binutils
  ≥ 2.36-era handles PE gc-sections. rustc's bundled self-contained mingw
  binutils version should be confirmed in the PR.
- **COFF section-count limits:** huge CGUs may need bigobj; LLVM emits it
  on demand, but ancient consumer tools could object.
- **Link time:** more sections to process; unmeasured here, expected minor.
- **lld truncates PE output section names to 8 bytes** (`.linkme_PLUGINS` →
  `.linkme_`) — harmless at runtime, but tooling that greps section names
  must know.
- Object-size growth in rlibs (more section headers): not measured;
  bounded and conventional on every other target.

## Reproduction

- Toolchain: branch @ `cb3226e7f1f`;
  `./x build library --target aarch64-apple-darwin,x86_64-pc-windows-gnu`
  (58 s incremental), snapshot to `build/host/stage1-win-gnu-fs`, rustup
  link `rust-win-gnu-fs`. `bootstrap.toml` needs the
  `[target.x86_64-pc-windows-gnu]` cc/ar/linker block (present in this
  checkout). Prereq: `brew install mingw-w64`.
- Size matrix: `validate.sh` (this directory).
- lld links: `lldgcc.py` + `ld.lld` shim (this directory) — replays the
  `gcc -###` collect2 line against `rust-lld -flavor gnu`, needed because
  Homebrew's gcc hardwires `--with-ld`.
- linkme matrix: `linkme-test/` workspace (crates, `main.c`, `dllwrap.c`,
  KEEP scripts, patch, PR draft). Apply the patch to a registry copy of
  linkme-impl 0.3.37 and wire `[patch.crates-io]`.

## Next actions (when picked up again)

1. File the **linkme PR** (draft ready) — independent of rustc, fixes
   today's breakage.
2. Get a **Windows runtime pass** (CI or wine) for the flip branch, then
   file the rustc PR with this report's data.
3. Open the **rust-lld-for-windows-gnu** conversation citing the 68%
   number and the section-magic safety property.
