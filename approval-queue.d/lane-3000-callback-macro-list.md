# The concern self-call walk stops at a named list of Rails callback macros, not at a callback-shaped name

- **PR:** (this lane's PR)
- **Issue:** [#3000](https://github.com/rigortype/rigor/issues/3000)
- **Class:** open-choice
- **Precedent:** `Effects::FrameworkUnits`' named callback lists; AGENTS.md "false positives outrank" rule
- **Decided:** 2026-11-09

## Background

#2999 kept the walk out of every receiverless `before_*` / `after_*` / `around_*` block. A project macro so named
that yields at once (`def self.after_foo = yield`) runs its block on the includer, so the walk missed a computed
definer there and reported `undefined method`.

## Options and trade-offs

- A list of the Rails callback macro names. It is syntactic, so it costs no resolution. A model callback a project
  declares with `define_model_callbacks :foo` (`after_foo`) is entered, which only loses a report.
- Stop unless a project method of that name resolves on the includer's singleton chain. The walk runs at index time,
  before any includer is known. It would also enter the existing `def self.after_save(&) = nil` row's block, which
  keeps the block and never runs it.

## Decision

The list (`ScopeIndexer::CALLBACK_MACROS`), read from Rails 8.1.3's ActiveModel, ActiveRecord, ActiveJob,
AbstractController, ActionMailer and ActionCable callback definitions. A name it misses is entered.

## To undo

Restore `CALLBACK_MACRO = /\A(?:before|after|around)_/` and its `match?` in `ScopeIndexer#self_call_block?`; the
`after_foo` / `around_load` rows then report again.
