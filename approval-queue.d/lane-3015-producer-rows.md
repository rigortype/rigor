# Five new producers.yml rows for the concern block singleton reading

- **PR:** [#3025](https://github.com/rigortype/rigor/pull/3025)
- **Issue:** [#3015](https://github.com/rigortype/rigor/issues/3015)
- **Class:** gate-row
- **Precedent:** [#2989](https://github.com/rigortype/rigor/pull/2989)
- **Decided:** 2026-11-09

## Background

The declaration-producers tripwire (`spec/rigor/declaration_facts/producers.yml`, ADR-119 WD6) flags the methods
#3015 adds: `ScopeIndexer#concern_hook_blocks`, `#each_hook_block_singleton_class` and
`#singleton_body_visibility_call?`, and `SigGen::Generator#mark_hook_blocks`. The `record_hook_block_singleton_defs`
row gained a clause for the `class << self` defs it now files.

## Options and trade-offs

- Add the rows with their reasons. Each method reads a module body's shape and decides no owner or side.
- Inline the checks into already-listed producers so no row is needed. The code would take that shape only to
  satisfy the gate.

## Decision

The first option, as #2989 added rows for the concern recorders it introduced.

## To undo

Delete the rows together with the methods.
