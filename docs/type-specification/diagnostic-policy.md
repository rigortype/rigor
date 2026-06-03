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
| `dynamic.*` | `untyped` and `Dynamic[T]` boundary crossings, unchecked generic leaks, and method calls whose proof depends on dynamic origin. Includes `dynamic.dependency-source.*` (e.g. `gem-not-found`) for the opt-in gem-source-inference path per [ADR-10](../adr/10-dependency-source-inference.md) (analyzer contract: [`docs/internal-spec/dependency-source-inference.md`](../internal-spec/dependency-source-inference.md)). |
| `static.*` | Static checks that stop short of a proof, including incomplete-inference cutoffs |
| `flow.*` | Control-flow narrowing failures, equality and predicate refinement issues, fact-stability violations |
| `compat.*` | RBS, rbs-inline, and Steep-compatible signature compatibility |
| `call.*` | Method-call-site diagnostics: `call.undefined-method` (the method is not defined on the receiver's statically known class), `call.unresolved-toplevel` (a top-level implicit-self call resolves against no same-file `def`, `pre_eval:` patch, or `Kernel` / `Object` method, [ADR-34](../adr/34-toplevel-unresolved-self-call-default.md)), `call.wrong-arity` (the positional-argument count matches no signature), `call.argument-type-mismatch` (an argument provably violates the parameter contract), and `call.possible-nil-receiver` (the receiver is `T \| nil` and the method is not defined on `NilClass`). |
| `def.*` | Method-definition diagnostics. Includes the override signature-compatibility family `def.override-visibility-reduced` / `def.override-return-widened` / `def.override-param-narrowed` ([ADR-35](../adr/35-override-signature-compatibility.md)), which verify an override against the signature it inherits from a project-defined ancestor. They fire only when both the override and the shadowed ancestor carry an author-supplied signature (inference-only either side stays silent) and map severity through `severity_profile:`; the Liskov reasoning is in [robustness-principle.md](robustness-principle.md). |
| `rbs_extended.*` | `RBS::Extended` payload validity, version compatibility, and conflict reports |
| `rbs.coverage.*` | RBS environment coverage / well-formedness telemetry. `rbs.coverage.missing-gem` reports locked gems with no available RBS; `rbs.coverage.synthesized-namespace` reports project `signature_paths:` RBS that declares qualified names (`class Foo::Bar`) without the enclosing namespace — invalid upstream (`rbs validate` rejects it), which Rigor synthesizes a `module` for so the signatures still resolve. Both authored `:info`. |
| `plugin.<plugin-id>.*` | Plugin-contributed diagnostics |
| `generated.<provider>.*` | Generated-signature provider diagnostics |
| `hint.*` | Style and refactor suggestions, gated by configuration (for example `hint.role-generalization.*`) |
| `sig.*` | RBS signature-generator telemetry per [ADR-14](../adr/14-rbs-sig-generation.md). Reserves `sig.generated.new-file` / `sig.generated.new-method` / `sig.generated.tighter-return` (per-method classifications the `rigor sig-gen` command emits when it produces RBS) and `sig.skipped.complex-shape` / `sig.skipped.user-authored` / `sig.skipped.untyped-return` (per-method reasons the generator declined to emit). The slice-1 MVP surfaces these identifiers through the command's JSON output rather than the diagnostic stream; later slices wire them as `:info` diagnostics when the `--write` path lands. |

## `Dynamic[T]` display rules

`Dynamic[T]` provenance is rendered by the diagnostic prefix family rather than by branch:

- Diagnostics outside the `dynamic.*` family render the narrowed static facet `T` with a small `from untyped` provenance note. The narrowed facet is what the user can reason about; the wrapped form would only add noise to messages that are not about the dynamic boundary itself.
- Diagnostics in `dynamic.*`, and explanations requested through `rigor explain` or `--explain`, show the full `Dynamic[T]` form, because that is exactly the information they exist to surface.
- Internal traces, cache keys, and plugin `Scope` queries always retain the full `Dynamic[T]` form regardless of how the message renders. Plugins that need the dynamic facet to compose a higher-tier diagnostic do not need to reconstruct it.

## Severity resolution

A rule emits each diagnostic with an *authored* severity (the rule's own default). Before the diagnostic reaches the result, the active severity profile and any per-rule overrides **re-stamp** that severity. In the suppression pipeline this sits between the inline markers and the baseline: inline `# rigor:disable` → **severity resolution** → project baseline ([ADR-22](../adr/22-baseline-and-project-onboarding.md)).

Two `.rigor.yml` keys drive it ([ADR-8](../adr/8-steep-inspired-improvements.md)):

- `severity_profile:` — one of `lenient` / `balanced` (default) / `strict`. Each profile is a per-rule table mapping a canonical rule id to a severity; the profiles trade breadth of `:error` for adoption-friendliness (`lenient` drops uncertain rules to `:warning`/`:off`, `strict` raises every rule to `:error`). A rule absent from the active profile's table keeps its authored severity.
- `severity_overrides:` — a `{ rule_id => severity }` map. A key is either an exact canonical rule id (`call.undefined-method`) or a **family wildcard** (`call`) matching every rule whose first dotted segment equals the key.

The resolved severity is one of `:error` / `:warning` / `:info` / `:off`; **`:off` drops the diagnostic entirely**. `Configuration::SeverityProfile.resolve` MUST apply this precedence (highest first):

1. A `nil` rule id keeps the authored severity (there is nothing to look up).
2. An exact `severity_overrides` entry for the rule id.
3. Otherwise a family-wildcard `severity_overrides` entry (the rule id's first segment).
4. Otherwise the active profile table's entry for the rule id.
5. Otherwise the authored severity.

An unknown `severity_profile:` value falls back to `balanced`. This resolution is what the `def.override-*` and `protocol_contracts:` ([ADR-28](../adr/28-path-scoped-protocol-contracts.md)) rules mean by "severity maps through `severity_profile:`": the rule emits at a fixed authored severity and the profile decides whether it surfaces as an error, a warning, or is suppressed.

## Suppression markers

Rigor recognizes an in-source comment grammar for suppressing specific diagnostics on a single line or across a whole file. The Rigor-native markers below are the shipped surface; recognizing other ecosystems' markers is a designed-but-unshipped compatibility extension.

### Rigor-native markers

Rigor-native markers use a Ruby comment grammar that mirrors PHPStan's annotation feel without inventing an application-side type DSL.

- **Line form**: `# rigor:disable <rule1>, <rule2>` — suppresses the listed rules on that physical line. `# rigor:disable all` suppresses every rule on the line.
- **File-level form** (v0.1.2): `# rigor:disable-file <rule1>, <rule2>` — suppresses the listed rules for every line in the file. `# rigor:disable-file all` suppresses every diagnostic in the file.

The rule list is comma- and/or whitespace-separated and uses the rule-ID prefixes above (`call.undefined-method`); the literal `all` keyword and short legacy aliases resolve through the same expansion `rigor explain` uses. There is no block-scoped (`start` / `end`) form.

Inline markers are applied before the configured `severity_profile:` and before the project baseline (ADR-22), which is the last suppression layer. See the User Manual § "Diagnostics" for the operational guide.

### Token resolution

A rule token — in a `# rigor:disable[-file]` marker or in the `.rigor.yml` `disable:` list — is **expanded to a set of canonical rule ids at parse time** (`resolve_rule_token`); the per-line / per-file suppression match is then an exact membership test of the diagnostic's canonical `rule` against that set. Four token shapes are recognised:

- `all` — the literal wildcard; suppresses every rule in scope. It is kept as the sentinel `all` rather than expanded to the rule list.
- A **legacy unprefixed alias** (`undefined-method`) — mapped to its single canonical id (`call.undefined-method`).
- A **family wildcard** — one of the diagnostic families `call` / `flow` / `assert` / `dump` / `def` — expands to every canonical id under `<family>.`.
- An **exact canonical id** (`call.undefined-method`) — kept as itself.

An unrecognised token is kept verbatim, so it only ever matches a diagnostic whose `rule` is literally that string (effectively a no-op — see _Validity rules_). A diagnostic whose `rule` is `nil` is never suppressed. Because family expansion happens at token time, the match itself never does prefix matching — it is always exact equality against the expanded canonical-id set.

### Ecosystem-compat markers (planned, not yet implemented)

Recognizing other ecosystems' markers — Steep's line-scoped `# steep:ignore`, and opt-in Sorbet `# typed:` / RuboCop `# rubocop:disable` via `.rigor.yml` `compat.*` switches — is a designed compatibility surface that has not shipped. Until it lands, only the Rigor-native markers above are honored, and a foreign marker is treated as an ordinary comment.

### Validity rules

- An unknown or empty marker is currently treated as an ordinary comment (silently ignored) rather than flagged. Warning on dead (unknown-rule) suppressions so they surface during refactoring is a planned refinement.
