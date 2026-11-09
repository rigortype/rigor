# A concern's block inside another concern is read on both the outer concern's edge and the final includer's

- **PR:** [#2999](https://github.com/rigortype/rigor/pull/2999)
- **Issue:** [#2992](https://github.com/rigortype/rigor/issues/2992)
- **Class:** open-choice
- **Precedent:** [#2989](https://github.com/rigortype/rigor/pull/2989)
- **Decided:** 2026-11-09

## Background

Issue #2992 asks `call.undefined-method` to read a concern's `included do … end` / `prepended do … end` block in every
direct includer and to follow concern dependencies. ActiveSupport treats a concern included into another concern
after the outer concern's `extend ActiveSupport::Concern` as a dependency. Its block then runs in the outer concern's
final includer, on that includer's edge (`prepend Outer` runs the dependency's `prepended` block). A concern included
ahead of the `extend`, or in a reopening that loads first, is an ordinary include. Its block runs in the outer concern
itself, on the edge the outer concern gave it. The discovery tables keep neither the statement order nor the load
order, so the issue left open which edge to read.

## Options and trade-offs

- Read only the final includer's edge, as for a dependency. This is exact for the usual layout, but it reports correct
  code that includes the concern ahead of the `extend` and is then prepended (witnessed: `Kq.new.q` answers `:q`).
- Read only the outer concern's own edge. This reports a dependency whose `prepended` block runs because the final
  includer prepends the outer concern (witnessed: `Kx.new.x` answers `:x`).
- Read both, and let either answer. No false positive in either layout. It loses the report where the two edges
  cross and only the unread world's block defines the name.

## Decision

The third option. False positives outrank lost reports, and #2989 already reads a concern's blocks as a union for
withholding. The lost report is a Known limit on the PR, with a reporting-turned-silent row in the spec.

## To undo

Recording each `include`'s position against the module's `extend ActiveSupport::Concern` would let
`CheckRules#hook_block_macro_defines?` skip the outer concern's own edge for a deferred dependency. That would mean
rejecting concern-from-concern members in `own_mixin_edges` for that read. The `Ky` row in
`spec/integration/concern_class_methods_undefined_method_spec.rb` would then flip back to reporting.
