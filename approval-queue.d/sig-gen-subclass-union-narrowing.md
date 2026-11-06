# sig-gen's literal guard no longer counts a literal member that the declaration itself spells

- **PR:** [#2934](https://github.com/rigortype/rigor/pull/2934)
- **Issue:** [#2914](https://github.com/rigortype/rigor/issues/2914)
- **Class:** open-choice
- **Precedent:** [ADR-14](../docs/adr/14-rbs-sig-generation.md)
- **Decided:** 2026-11-07

## Background

#2914 asked sig-gen to propose `Prism::DefNode?` over the declared `::Prism::Node?` for `Rigor::Plugin::NodeContext#enclosing_def`. The issue named one guard as the cause, `Generator#loses_declared_union_member?`, and the PR teaches it that a member narrowed to a subclass is not a lost member. A second guard also declined the proposal: `Generator#pins_literal_over_declaration?` (#837, ADR-14 clause 3). That guard refuses any proposal with an RBS-literal member, and the `nil` in `Prism::DefNode | nil` erases to the literal `nil`. Until that guard changed, no narrowing of a nil-able declaration could be proposed, and the issue did not cover this second guard.

## Options and trade-offs

- Exempt any literal that the declaration itself spells as a member. #837 refuses to pin a literal over a declared abstraction, and a literal the author already wrote abstracts nothing. A literal the declaration does not spell is still refused.
- Exempt `nil` alone. This is narrower in wording, but `true`, `false`, a Symbol or a String that the declaration spells is equally not pinned *over* it, so it would hard-code one value without a reason.
- Leave the literal guard alone. Then #2914 cannot be fixed, the provenance pin stays at 1, and every nil-able narrowing stays declined.

## Decision

Exempt a literal member that the declaration spells, and amend ADR-14 clause 3 (set by [#837](https://github.com/rigortype/rigor/issues/837)) to match. The coordinator confirmed this reading of #837. The spec row "still declines a literal the declaration does not spell next to the nil it does" pins the boundary: `String?` against a body proving `"a" | nil` still declines.

## To undo

Restore `pins_literal_over_declaration?(inferred)` to refuse every literal member, and revert the ADR-14 clause-3 sentence and the dated paragraph. `sig/rigor/plugin/node_context.rbs`'s `enclosing_def` then needs its `::Prism::Node?` declaration back, and its provenance pin goes back to 1.
