# Record ScopeIndexer#record_definer_name_row as a justified declaration producer

- **PR:** [#2263](https://github.com/rigortype/rigor/pull/2263)
- **Issue:** [#2184](https://github.com/rigortype/rigor/issues/2184)
- **Class:** gate-row
- **Precedent:** [#2161](https://github.com/rigortype/rigor/issues/2161)
- **Decided:** 2026-10-21

## Background

The #2184 fix adds a deferred-range row for each literal-named `define_method` / `define_singleton_method` call, so the by-name callee reader sees a body no def table holds. The new method reads a call node in the declaration walk, so the ADR-119 producer tripwire (`spec/rigor/declaration_facts/producers_spec.rb`) failed until `producers.yml` recorded it with a reason.

## Options and trade-offs

- **Record the method with a reason (taken).** The method decides no owner, side or nesting; it writes the name literal's offsets and the name, with nil owner and side.
- **Inline the code into the grandfathered `walk_deferred_ranges`.** The tripwire would stay quiet, but the code would take a shape chosen to evade the gate, which the lane contract rules out.

## Decision

Recorded, as #2161 recorded `ScopeIndexer#add_module_function_entries`, another reader of finished deferred-range rows added beside the grandfathered walk.

## To undo

Remove the `record_definer_name_row` line from `spec/rigor/declaration_facts/producers.yml` together with the method.
