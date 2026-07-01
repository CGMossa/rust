---
name: bless
description: Run a rust-lang/rust compiletest suite (usually tests/ui) and update the committed expected output (.stderr/.stdout) with --bless. Use when a compiler change altered diagnostics and UI tests now fail, or when the user says "bless", "update the expected test output", or "regenerate stderr".
---

# Bless compiler test output

UI/compiletest tests compare rustc's actual output against committed
`.stderr`/`.stdout` files. When a change intentionally alters diagnostics, those
files must be regenerated ("blessed"). A blessed file is only correct if the new
output is what you *meant* to produce — always review the diff.

## Procedure

1. **Scope the run.** Bless the narrowest path that covers the change, never the
   whole suite blindly:
   - one file: `./x test tests/ui/path/to/test.rs --bless`
   - one dir: `./x test tests/ui/some-feature --bless`
   - filter: `./x test tests/ui --test-args <substring> --bless`

   Pick the stage the way normal testing does: compiler changes → default
   (stage1); pure `library/` changes → add `--stage 0`.

2. **Run it** and let it rewrite the expected files.

3. **Review the diff** (`git diff -- tests/`). Confirm every changed line is an
   intended consequence of the code change — new/removed diagnostics, span
   shifts, reworded messages. If something changed that you did *not* intend,
   the code is wrong, not the test; stop and fix the code.

4. **Re-run without `--bless`** to confirm the suite is green:
   `./x test tests/ui/path/... `.

## Notes

- Results are cached; if a change isn't picked up, add `--force-rerun`.
- `tidy` is different — for it use `./x test tidy --bless`.
- If output depends on host details (paths, backtraces), use compiletest
  normalization directives (`//@ normalize-stderr: ...`) rather than blessing
  machine-specific text. See `tests/ui.md` / `tests/directives.md` in the
  rustc-dev-guide (`src/doc/rustc-dev-guide/src/`).
