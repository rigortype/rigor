# A repeated --tmp-file or --instead-of is a usage error, not a second buffer

- **PR:** [#2658](https://github.com/rigortype/rigor/pull/2658)
- **Issue:** [#2233](https://github.com/rigortype/rigor/issues/2233)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-11-03

## Background

Issue #2233 part 2: two `--tmp-file` / `--instead-of` pairs on one command kept only the last. The first buffer's
file was then reported as `no such file or directory (skipped)`, with nothing saying its pair had been dropped. The
issue allowed either honouring every pair or rejecting the repeat with a usage error, and left the choice open.

## Options and trade-offs

- Honour every pair. The buffer binding is singular today (`Analysis::BufferBinding`, one per run) and the runner, the
  incremental session, the LSP path and `type-of` all take one. Several buffers would need the binding to become a
  list through every one of them: a runner-level change with its own cache and invalidation questions, far beyond this
  issue.
- Reject the repeat with a usage error (exit 64) naming the repeated flag. Small, loud, and it stops the silent drop.
  It removes a capability no caller has, since no caller passes two pairs and the editor integrations send one buffer.
- Last-wins, documented. This is what the scalar flags do (`--baseline`, `--format`), but it is the same silent drop.
- Precedent in the CLI is mixed: flags declared "(repeatable)" accumulate (`--observe`, `--entry-point`), and the
  scalar flags keep the last value without a word. `--tmp-file` is not declared repeatable, so it took the rejection.

## Decision

Reject a repeated `--tmp-file` or `--instead-of` with a usage error. Multi-buffer editor mode is a larger design
question and would need an issue of its own before it is built. The rejection is the loud option that stops the
silent drop without committing to a runner-level change.

## To undo

Honouring several pairs would replace the usage error with a list-valued binding threaded through `Runner`,
`IncrementalSession`, `type-of` and the LSP. Anything that now relies on the exit-64 message (the new spec in
`spec/rigor/cli/check_command_spec.rb`, the manual's editor-mode notes) changes with it.
