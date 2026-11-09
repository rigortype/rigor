# Builder#lists_unnamed? and ScopeIndexer#unnamed_singleton_include? are listed in producers.yml as consumers, and MixinAccumulator#note's row goes

- **PR:** [#3011](https://github.com/rigortype/rigor/pull/3011)
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

Fix round 3 makes two more row changes. `ScopeIndexer#unnamed_singleton_include?` decides whether a
`singleton_class.include(*MODS)` lists the unnamed marker on the `:extend` side. It reads the call's name against
`INSTANCE_MIXIN_NAMES` and its arguments, and derives no declaration context, so it is listed as a consumer beside
`taint_unrecorded_mixin`. `MixinAccumulator#note` now passes `unnamed: true` for every incomplete call, so `extend M,
helper` lists `"?"` too. It no longer spells a mixin side, so the scanner no longer finds a producer there, and its
#2993 row is stale. The row is deleted under ADR-119 WD6's rule that the list holds exactly the producers the tree has, as
#1735 did for its rows.

## To undo

Delete a row when its helper goes. Restoring `side == :include` in `MixinAccumulator#note` brings its row back.
