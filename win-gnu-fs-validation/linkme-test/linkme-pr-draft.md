# PR draft: keep distributed slice elements alive under GNU ld's --gc-sections on windows-gnu

*Target: dtolnay/linkme. Patch: `linkme-gnu-gc-anchor.patch` (impl/src/{element,declaration}.rs).*

## Problem

On `*-pc-windows-gnu`, linking with `-Wl,--gc-sections` silently corrupts
distributed slices: element `.linkme_*$b` sections are collected, leaving the
slice empty or — worse — partially populated. The declaration's dupcheck entry
(`.linkm2_*$b`) is also collected, silently disabling duplicate detection.

This hits real projects because staticlib outputs are linked by an external
GNU toolchain (MinGW / R's Rtools), where `--gc-sections` is a common
size-reduction flag the Rust build never sees.

It is not limited to staticlibs: **plain cargo-built windows-gnu binaries are
affected today**, because rustc itself passes `--gc-sections` to GNU ld for
executables. A release-mode bin crate with three elements (two in the bin,
one in a dep) links with a slice of length **1** — the bin crate's own
elements are silently collected (verified with rustc 1.99 nightly, GNU ld
2.46.1). Linking the same program with rust-lld's MinGW driver keeps all
three (lld's gc only collects COMDATs, so these sections are safe there by
construction).

Root cause: `#[used]` has **no link-level retention semantics on windows-gnu**.

- LLVM emits no `.drectve /INCLUDE:` directive for `llvm.used` on MinGW
  targets (verified: objects contain no `.drectve` section at all).
- GNU ld would ignore it anyway: a hand-written `.drectve` with
  `/INCLUDE:sym` or `-include:sym` produces
  `Warning: corrupt .drectve at end of def file` and the symbol's section is
  still collected (binutils 2.46.1).
- COFF has no `SHF_GNU_RETAIN` equivalent.

So there is no attribute-level fix available; the section must be rooted by a
reference from something the linker keeps.

## Fix

For `cfg(all(target_os = "windows", target_env = "gnu"))`, each element (and
the declaration's `DUPCHECK`) additionally emits a **data-only anchor**: a
pointer to the static, placed in the `.jcr` list, which GNU ld's built-in PE
linker script marks with `KEEP(*(.jcr))`. The GC mark chain becomes:

```
.jcr input section (KEEP)  --relocation-->  element's .linkme_*$b
```

Why `.jcr` and not `.ctors` (also KEEP'd): `.ctors` entries are *executed* at
startup, which would turn linkme into runtime registration and add
per-element startup cost — against linkme's compile-time-only contract. The
`.jcr` (Java class registration) list is data, and is never walked on MinGW:
the CRT guards it behind the weak `_Jv_RegisterClasses`, which has been null
since libgcj's removal. The anchor is therefore pure link-time metadata.

Cost: one pointer (8 bytes on x86_64) per element, windows-gnu only. In the
final image the anchors land in `.rdata` (no extra output section). On
linkers that don't use the GNU default script (lld-link, rust-lld MinGW
driver) the anchors are inert bytes.

## Validation

Repro workspace: slice + 1 element in crate A, 2 elements + `extern "C"`
accessors in a staticlib crate, 1 element in a never-referenced crate;
linked into an exe and a DLL with `x86_64-w64-mingw32-gcc` (GCC 16.1.0,
binutils 2.46.1), section contents verified with objdump.

| configuration | before | after |
|---|---|---|
| exe/DLL, `--gc-sections` | empty or partial slice, dupcheck lost | all pulled-member elements + dupcheck intact |
| exe/DLL, no gc | works | works (unchanged) |
| with `-Zfunction-sections`-style per-data sections | **all** elements lost under gc | all intact |

Out of scope: elements in archive members that nothing references are never
loaded by the linker (standard static-archive semantics, identical on MSVC).
`lto = "fat"` on the Rust side (single merged member) or `--whole-archive`
remains the answer for registration-only crates.

Limitation: validated by static section analysis (macOS cross toolchain, no
wine); a Windows CI runtime pass is the remaining confirmation.
