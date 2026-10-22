# Make the --verify-incremental edit replay an opt-in count that empties each sampled file

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
- For the edit itself, emptying the file (taken) replays the removal of everything the file defines, which is the stale-output shape of #1964's mutants and #2158. Replaying an addition would need a baseline with the file emptied, and a buffered baseline analyses the buffer alone.

## Decision

The replay is implemented as `--verify-incremental-edits=N`, which implies `--verify-incremental` and defaults to 0, and the limit is documented. The `make check-incremental` CI target is not changed: running two extra analyses per sampled file over `lib` would multiply the gate's ~74 s, and the sample size for CI belongs to the maintainer. The precedent is option B's buffer recheck, which the replay reuses rather than re-implementing.

## To undo

To enable it in CI, add `--verify-incremental-edits=N` to the `check-incremental` lines in the `Makefile`. To remove the option, delete it from `check_command.rb`, along with `IncrementalSession#replay_edit` and its spec. Nothing else depends on it.
