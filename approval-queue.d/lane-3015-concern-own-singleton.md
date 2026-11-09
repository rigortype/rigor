# A concern block's def self.x leaves the concern's own tables only in a body that extends Concern itself

- **PR:** [#3025](https://github.com/rigortype/rigor/pull/3025)
- **Issue:** [#3015](https://github.com/rigortype/rigor/issues/3015)
- **Class:** open-choice
- **Precedent:** [#2989](https://github.com/rigortype/rigor/pull/2989)
- **Decided:** 2026-11-09

## Background

Issue #3015 asks that a `def self.x` in a concern's `included` / `prepended` / `class_methods` block stop being
recorded as the concern's own singleton method, while a non-ActiveSupport `included` DSL keeps it on the module.
Whether a module is a concern is a property of all its bodies together (#3005 reads a reopening without the
`extend` through a gated hook), but the def, singleton-def and visibility walks run one file at a time and file the
`def` as they meet it. The issue did not say which bodies the removal applies to.

## Options and trade-offs

- Remove the attribution only in a body that runs `extend ActiveSupport::Concern` itself. Each walk decides from the
  body in hand. A reopening's block without the `extend` keeps filing the `def` on the module, so the module's own
  class side still answers it there, and sig-gen still writes it there. No module whose `included` is its own DSL
  loses a `def`.
- Remove it in every body and restore it at read time for a module no body declares a concern. Every reader of the
  three tables (typing, the singleton chain, visibility, sig-gen, the incremental def index) would need the check.
- Remove it in every body. A non-ActiveSupport `included` that `instance_eval`s its block on the module (Ruby
  answers the `def` on the module) would lose the `def`, which the issue rules out.

## Decision

The first option. #2989 (#2986) read a `class_methods` block only in a body that ran the `extend` before #2997
widened it with a gate. The reopening case is listed as a known limit in the PR.

## To undo

Drop `ScopeIndexer#concern_hook_blocks`' body gate (or the `HookBlockSpans` marks) and the sig-gen
`mark_hook_blocks` gate together.
