# The two names of `K = Struct.new("Named", …)` share one method chain through an envelope entry, not a copied table

- **PR:** [#2990](https://github.com/rigortype/rigor/pull/2990)
- **Issue:** [#2979](https://github.com/rigortype/rigor/issues/2979)
- **Class:** open-choice
- **Precedent:** [#2977](https://github.com/rigortype/rigor/pull/2977)
- **Decided:** 2026-11-09

## Background

The brief settled that `K` and `Struct::Named` should be aliases for method existence, not copies of each other's
methods. The engine has no constant-alias mechanism for method tables: `B = A` changes a constant's type, and
nothing makes two class names share a method table. So two things were left open: where the alias is recorded,
and how far the chain follows it.

## Options and trade-offs

- A new `DiscoveryIndex` member holding the pairs. This is the cleanest data model. But every copy, merge,
  member-class and incremental path would have to learn it, which is a large change for one construct.
- An envelope-bucket entry `[ENVELOPE_SAME_CLASS_KIND, other]` on each name. This follows the
  `[ENVELOPE_HOOK_EXTEND_KIND, name]` entry from #2975: it already travels through cross-file merging and
  incremental mark diffing (once it is listed in `Incremental::ENTRY_MARK_KINDS`). It costs one key scan of a
  class's bucket per chain linearisation.
- Making each reader retry under the other name. Every chain reader would need the change, and the override,
  arity and constant readers would disagree with the method walks.

How far the chain follows it:

- Only the two names' entries at its head.
- The two names' entries plus both names' mixin edges. This was chosen, because `include M` under either name is
  the class's.

## Decision

The envelope entry. `ResolutionChain::Builder` heads either name's chain with both names' entries, folds in both
names' prepends, includes and extends, and keeps the superclass edge of the name asked about. The binding is direct
only: two `Struct.new("Same", …)` writes are not bound to each other. The A/B shows +0.13% allocations.

## To undo

Drop `record_struct_same_class` from `ScopeIndexer`, `same_class` from `ResolutionChain::Builder` (restoring
`compute_instance` and `compute_singleton` to the single-name form), `ENVELOPE_SAME_CLASS_KIND` from `DiscoveryIndex`
and `Incremental::ENTRY_MARK_KINDS`, and the #2979 sentence in `docs/internal-spec/inference-engine.md`. The specs
in `spec/integration/struct_named_same_class_spec.rb`, `spec/rigor/analysis/struct_same_class_incremental_spec.rb`
and the #2979 rows of `rails_routes_plugin_spec.rb` would then report again.
