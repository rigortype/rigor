# Builder#lists_unnamed? is listed in producers.yml as a consumer, not a producer

- **PR:** [#2994](https://github.com/rigortype/rigor/issues/2994)
- **Issue:** [#2994](https://github.com/rigortype/rigor/issues/2994)
- **Class:** gate-row
- **Precedent:** [#1735](https://github.com/rigortype/rigor/pull/1735)
- **Decided:** 2026-11-09

## Background

The fix gives a class object the `:include_hook` open mark when the class, or a module it includes, lists `"?"` on its
unpositioned `:include` side. `spec/rigor/declaration_facts/producers_spec.rb` flags any method that spells a mixin
side, so the new helper `Scope::ResolutionChain::Builder#lists_unnamed?` needs a row.

## Options and trade-offs

- List it as a consumer, as #1735 listed `compute_instance` and `extend_hook_taint`, which read the same table.
- Inline the read into `hook_extensions`, which is listed already. That moves the code to dodge the gate.

## Decision

List it as a consumer. It reads `unpositioned_mixins` and writes no table, like its listed neighbours.

## To undo

Delete the row when the helper goes.
