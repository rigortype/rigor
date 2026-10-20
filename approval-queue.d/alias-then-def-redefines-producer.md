# Record ScopeIndexer#settle_alias_slot in producers.yml as a reasoned producer

- **PR:** [#2225](https://github.com/rigortype/rigor/pull/2225)
- **Issue:** [#2006](https://github.com/rigortype/rigor/issues/2006)
- **Class:** gate-row
- **Precedent:** [#2003](https://github.com/rigortype/rigor/pull/2003)
- **Decided:** 2026-10-21

## Background

The source-order alias pass moved the per-name slot write out of the grandfathered `apply_alias_def_nodes` into `settle_alias_slot`, to keep the method under the RuboCop complexity limits. `spec/rigor/declaration_facts/producers_spec.rb` flags each new method that writes a discovery table.

## Options and trade-offs

- Inline the write back into `apply_alias_def_nodes`. That needs no new row, but takes the method past the AbcSize limit.
- Add a reasoned row (taken), as #2003 did for `supersede_def_nodes`. The grandfathered count does not move.

## Decision

The row states that the method writes only the walk's own def-node slot under the owner the alias map computed, through `follow_slot_writer`, and decides no declaration context.

## To undo

Inline the method back into `apply_alias_def_nodes` and delete the row.
