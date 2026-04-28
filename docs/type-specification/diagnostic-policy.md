# Diagnostic Policy

Rigor SHOULD prefer precise diagnostics over silent widening. This document defines the diagnostic identifier taxonomy, display rules, and the suppression-marker grammar.

The cutoff identifiers used by inference budgets live in the `static.*` family (see [inference-budgets.md](inference-budgets.md)). The display rules for negative facts and difference types are in [type-operators.md](type-operators.md). The display rule for `Dynamic[T]` is here.

## Diagnostic guidelines

- Using `void` as a value is a primary diagnostic; downstream recovery uses `top` and SHOULD avoid duplicate cascade reports for the same expression.
- Calling a method on `top` without proof is a diagnostic.
- Calling a method on raw `untyped` is allowed but SHOULD be traceable to an unchecked boundary.
- Calling a method on `Dynamic[T]` MAY use the static facet `T`, but diagnostics SHOULD be able to explain that the proof depended on a dynamic-origin value.
- Strict dynamic modes MAY report dynamic-to-precise assignments, arguments, returns, and generic-slot leaks such as `Array[Dynamic[top]]`.
- Strict static modes MAY additionally report method calls or branch proofs whose safety depends on dynamic-origin facts rather than checked static facts.
- A branch narrowed by a negative fact SHOULD display that fact when it is useful, for example `String - ""` or `~"foo"`.
- Diagnostics SHOULD prefer explicit domain-bearing displays such as `String - "foo"` when a bare `~"foo"` would be ambiguous.
- Writing through a read-only shape entry is a diagnostic when Rigor has that fact.
- Passing unexpected keys to a closed keyword or options-hash shape is a diagnostic.
- Invalid or contradictory `RBS::Extended` annotations are diagnostics.
- Method implementations are checked against accepted signature contracts regardless of source: inline `#:`, `# @rbs`, rbs-inline parameter annotations, generated stubs, and external `.rbs` declarations all have the same implementation-side force.
- When inference stops because of recursion, operator ambiguity, dynamic dispatch, or budget exhaustion, Rigor MUST report the cutoff and SHOULD suggest a boundary contract rather than pretending the inferred type is precise.
- When an explicit nominal parameter type rejects a call but the method body only requires a smaller inferred capability role, Rigor MAY suggest generalizing the public signature to an interface rather than adding an ad hoc union.
- Diagnostics that involve plugin, generated, or `RBS::Extended` facts SHOULD carry stable identifiers. Public identifiers SHOULD use prefixes that make the source family clear, such as `plugin.<plugin-id>.<name>`, `rbs_extended.<name>`, or `generated.<provider>.<name>`, while internal diagnostic metadata MAY retain richer provenance.
- Losing precision during RBS export SHOULD be reportable when users request explanation or strict export mode.

## Identifier taxonomy

Diagnostic identifiers are hierarchical so plugin authors, RBS metadata, and user suppression markers can address them without colliding with internal numbering. Identifiers are stable within a major version. New diagnostics MAY be added under any prefix; renames or removals require a deprecation window.

| Prefix | Use |
|---|---|
| `dynamic.*` | `untyped` and `Dynamic[T]` boundary crossings, unchecked generic leaks, and method calls whose proof depends on dynamic origin |
| `static.*` | Static checks that stop short of a proof, including incomplete-inference cutoffs |
| `flow.*` | Control-flow narrowing failures, equality and predicate refinement issues, fact-stability violations |
| `compat.*` | RBS, rbs-inline, and Steep-compatible signature compatibility |
| `rbs_extended.*` | `RBS::Extended` payload validity, version compatibility, and conflict reports |
| `plugin.<plugin-id>.*` | Plugin-contributed diagnostics |
| `generated.<provider>.*` | Generated-signature provider diagnostics |
| `hint.*` | Style and refactor suggestions, gated by configuration (for example `hint.role-generalization.*`) |

## `Dynamic[T]` display rules

`Dynamic[T]` provenance is rendered by the diagnostic prefix family rather than by branch:

- Diagnostics outside the `dynamic.*` family render the narrowed static facet `T` with a small `from untyped` provenance note. The narrowed facet is what the user can reason about; the wrapped form would only add noise to messages that are not about the dynamic boundary itself.
- Diagnostics in `dynamic.*`, and explanations requested through `rigor explain` or `--explain`, show the full `Dynamic[T]` form, because that is exactly the information they exist to surface.
- Internal traces, cache keys, and plugin `Scope` queries always retain the full `Dynamic[T]` form regardless of how the message renders. Plugins that need the dynamic facet to compose a higher-tier diagnostic do not need to reconstruct it.

## Suppression markers

Rigor MUST recognize three families of suppression markers so the analyzer can interoperate with existing ecosystems while keeping a clean Rigor-native form.

### Steep-style markers

Steep-style markers such as `# steep:ignore` are recognized by default. Only line-scoped Steep markers are accepted, and Rigor maps them to its own diagnostic suppression. Nothing in Steep's marker grammar is reinterpreted as Rigor configuration.

### Sorbet- and RuboCop-style markers (opt-in)

Sorbet-style file-level markers (`# typed:`) and RuboCop-style suppression comments (`# rubocop:disable`, `# rubocop:enable`) are opt-in. Projects enable them with `compat.sorbet_ignore` and `compat.rubocop_disable` switches in `.rigor.yml`. Sorbet's typed-mode policy and RuboCop's lint scope are not the same as Rigor's diagnostic suppression, so defaulting them on would conflate concerns.

### Rigor-native markers

Rigor-native markers use a Ruby comment grammar that mirrors PHPStan's annotation feel without inventing application-side type DSL.

- **Line form**: `# rigor:ignore[<diagnostic.id>]`
- **Block form**: `# rigor:ignore-start[<diagnostic.id>]` paired with `# rigor:ignore-end`

The diagnostic identifier list uses the prefixes above.

### Validity rules

- A marker that names an unknown diagnostic identifier MUST produce a warning so dead suppressions surface during refactoring.
- A marker without an identifier list MUST be a diagnostic by default; strict mode MUST reject it entirely.
