# `rigor coverage` skips a missing path beside files it can measure, as `rigor check` does, instead of stopping with exit 64

- **PR:** [#2662](https://github.com/rigortype/rigor/pull/2662)
- **Issue:** [#2206](https://github.com/rigortype/rigor/issues/2206)
- **Class:** open-choice
- **Precedent:** [#2204](https://github.com/rigortype/rigor/pull/2204)
- **Decided:** 2026-11-03

## Background

Issue #2206 asked that `rigor coverage` and the MCP `rigor_coverage` tool word a missing path the way `rigor check` does, by routing it through `Analysis::PathExpansion.diagnostics`. Before this PR, `coverage` stopped at the first path that was neither a directory nor a file, printed `coverage: not a file or directory: X`, and exited 64. `check` and `sig-gen` already grade such a path by `any_files`: a warning, `(skipped)`, when other paths yield files, and an error when nothing does. Routing `coverage` through `diagnostics` therefore changes the exit status for a mixed run as well as the wording. The issue did not say which to keep.

## Options and trade-offs

- **Keep exit 64 for any missing path.** Only the wording changes. A typo in a long path list still aborts the whole measurement, and the coverage and check behaviour stay different.
- **Align with `check`: warn and skip beside files, error only when nothing is left.** A mixed run now measures the valid files and exits by the measurement, not 64. Costs: a typo beside valid paths no longer stops the run, so a CI gate that relied on the abort will pass. The MCP `isError` still follows the exit code, so a `rigor_coverage` call with some valid paths is no longer `isError: true`.

## Decision

Align with `check`, including the non-Ruby case: an existing file that is not `.rb`, named explicitly, is no longer measured. Alone it exits 64; beside other files it is skipped with a warning. `coverage` used to measure any existing file it was given. The issue asked for `coverage` to route through the same helper `check` uses, and that helper grades the mixed case as a warning. Keeping exit 64 would need a special case in `coverage` only, and that is the drift the issue set out to remove. The precedent is #2204, which made `check` and `sig-gen` report missing paths through `PathExpansion.diagnostics` and fixed the warn-and-skip grade for them. It fits the wording and the grade closely. It does not cover the exit status of `coverage` itself, which is why this is a decision and not a rule taken from the precedent.

## To undo

In `lib/rigor/cli/command.rb`, `collect_paths_reporting` should return nil whenever `bad` is non-empty, as the old `collect_paths` did, instead of grading by `any_files`. For the non-Ruby case, `collect_paths_reporting` should also accept an existing file that is not `.rb` as the old code did, by adding it to the returned list. Then restore the `coverage` example that expects a mixed run to exit 0 and warn, and the MCP note in `docs/manual/10-mcp-server.md`. Nothing else depends on the grade: `check` and `sig-gen` read `PathExpansion.diagnostics` directly and do not change.
