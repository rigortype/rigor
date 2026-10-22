# Make the --verify-incremental edit replay an opt-in count that empties each sampled file and reduces it to its skeleton

- **PR:** [#2272](https://github.com/rigortype/rigor/pull/2272)
- **Issue:** [#1967](https://github.com/rigortype/rigor/issues/1967)
- **Class:** open-choice
- **Precedent:** [#146](https://github.com/rigortype/rigor/issues/146)
- **Decided:** 2026-10-22

## Background

The issue offered two ways forward for item 1. One was to document that `--verify-incremental` cannot see a missing invalidation edge. The other was to extend it to replay an edit. It did not say what edit to replay, how many files to sample, or whether CI should pay for it.

## Options and trade-offs

- Document the limit only. This is free, but CI keeps proving nothing about edges.
- Replay an edit on disk. This mutates the user's tree in a verification command, so it was not considered.
- Replay through an editor buffer, the way editor mode option B (#146) rechecks an unsaved edit, against a full run of the same buffered tree (taken). Each replay costs one recheck and one full analysis.
- Emptying the file alone (round 1) replays the removal of everything the file defines, which is the stale-output shape of #1964's mutants and #2158. Removing every declaration fires class-level keys that re-check the readers anyway, though, so a missing finer edge goes unseen: review found #2163's `refinement:` and #2161's `visibility:` mutants passing.
- Emptying the file and also reducing it to its `class` / `module` skeleton (taken). The skeleton keeps the declarations, so only the finer edges can re-check a reader. #2163's mutant now fails on it. This costs one more recheck and one more full analysis per sampled file.
- Replaying an addition would need a baseline with the file emptied, and a buffered baseline analyses the buffer alone.

## Decision

The replay is implemented as `--verify-incremental-edits=N`, which implies `--verify-incremental` and defaults to 0, and the limit is documented. The `make check-incremental` CI target is not changed. Each sampled file costs about 55–60 s on `lib` (two edits, each a recheck plus a full analysis), against the gate's ~74 s for both targets today, and the sample size for CI belongs to the maintainer. A run in which every replay declined fails rather than reports OK. The precedent is option B's buffer recheck, which the replay reuses rather than re-implementing.

## To undo

To enable it in CI, add `--verify-incremental-edits=N` to the `check-incremental` lines in the `Makefile`. To remove the option, delete it from `check_command.rb`, along with `IncrementalSession#replay_edit` and its spec. Nothing else depends on it.
