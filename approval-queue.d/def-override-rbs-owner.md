# Override rules name the ancestor that declares the method, and `-> void` over `-> nil` is not widening

- **PR:** [#3154](https://github.com/rigortype/rigor/pull/3154)
- **Issue:** [#3046](https://github.com/rigortype/rigor/issues/3046)
- **Class:** open-choice
- **Precedent:** [ADR-35](../docs/adr/35-override-signature-compatibility.md)
- **Decided:** 2026-11-13

## Background

`def.override-return-widened` reported `widened from nil to top (overrides ApplicationCable::Channel#subscribed)` on actioncable: `ChatChannel#subscribed: () -> void` overrides a hook the project class `ApplicationCable::Channel` does not define; the signature belongs to the RBS-only `ActionCable::Channel::Base`. The override walk asked each project ancestor for the RBS method it inherits, so a project class in between answered with the RBS-only signature. The issue left two questions open: whose signature the rules compare against, and whether `-> void` over `-> nil` counts as widening at all (it fired between two project classes too).

## Options and trade-offs

- Owner: keep naming the first project ancestor that inherits a signature (reports RBS-only contracts under a wrong owner, contrary to ADR-35's project-ancestor restriction); or name the ancestor whose own RBS declares the method and stay silent when that is RBS-only (loses findings against RBS-only contracts reached through a project class, which #130 owns).
- `void` over `nil`: keep reporting it (the worst-case reading: `void` is top); exempt any top-typed override return (also hides `-> top`, which is a real widening); or exempt only a declared `void` over a parent of exactly `nil` (both mean "no useful value", and callers cannot use a `void` return).

## Decision

The walk asks only an ancestor whose own RBS declares the method, in its body or through an interface it includes itself; an RBS-only owner leaves the rules silent, as for a direct RBS-only parent. This applies ADR-35's existing restriction and keeps an interface a project class includes answering as that class, as before. `-> void` over a parent return of exactly `nil` is exempt (a parent `-> NilClass` counts as `nil`), keyed on the declared `void` of every override arm; an ancestor that inherits the declaration from an RBS-only owner the project chain cannot see ends the walk silent rather than letting a farther project ancestor answer; `-> top` over `nil` and `void` over any non-nil return still fire. False positives outrank the worst-case reading (AGENTS.md, ADR-5). Both rules are stated in `docs/type-specification/diagnostic-policy.md`.

## To undo

Revert the `declared_by?` gate in `CheckRules#nearest_ancestor_method_def` (back to `!defined_on?(method_def, class_name)`) and the `void_over_nil?` early return in `override_return_widened_diagnostic`, the diagnostic-policy.md sentences, and the "#3046" examples in `spec/rigor/analysis/check_rules/override_and_return_type_spec.rb`. Nothing else depends on them.
