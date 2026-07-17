# Diagnostic Policy

Rigor SHOULD prefer precise diagnostics over silent widening. This document defines the diagnostic identifier taxonomy, display rules, and the suppression-marker grammar.

The `static.*` family splits into use-site guards (`static.value-use.*`) and incomplete-inference cutoffs (`static.incomplete-inference.*`) per [ADR-100](../adr/100-static-diagnostic-family-and-void-origins.md); its first implemented identifier is `static.value-use.void` (an author-declared `-> void` return used in value context), shipped behind the `use-of-void-value` bleeding-edge feature. The budget-cutoff identifiers are still reserved (see [inference-budgets.md](inference-budgets.md)) and **not yet wired**. The display rules for negative facts and difference types are in [type-operators.md](type-operators.md). The display rule for `Dynamic[T]` is here.

## Diagnostic guidelines

> **Status.** These guidelines state the intended policy for each situation, not a claim that
> every one is implemented. A guideline whose diagnostic would live in a family marked
> **Reserved** in the taxonomy below (`compat.*`, `hint.*`, `generated.*`), or in the
> `static.incomplete-inference.*` budget half, describes intent. The `void`-value guard is now
> implemented for the direct author-declared case ([special-types.md](special-types.md) § `void`;
> [ADR-100](../adr/100-static-diagnostic-family-and-void-origins.md)), behind `bleeding_edge:`. See
> [ADR-92](../adr/92-normative-status-fidelity.md).

- Using `void` as a value is a primary diagnostic (`static.value-use.void`, opt-in behind the `use-of-void-value` bleeding-edge feature); downstream recovery uses `top` and SHOULD avoid duplicate cascade reports for the same expression.
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

A family row carries a **bolded status marker containing the phrase "as of this writing"** when it
does not resolve to a diagnostic the engine emits today — the same idiom
[inference-budgets.md](inference-budgets.md) uses for the unwired `budgets:` surface. Two such
statuses occur: **Reserved** names an identifier space that is claimed but carries no
implemented diagnostic, and **Not a diagnostic family** names identifiers that exist but reach the
user through another surface. Reserving the space *is* a decision — it keeps
the family free of colliding claims — but it is not a statement that the diagnostics exist.
Per [ADR-92](../adr/92-normative-status-fidelity.md), a family listed here without a
Reserved marker MUST have at least one implemented identifier; `spec/docs/manual_drift_spec.rb`
enforces this table against the engine's emitted vocabulary.

| Prefix | Use |
|---|---|
| `dynamic.*` | `untyped` and `Dynamic[T]` boundary crossings, unchecked generic leaks, and method calls whose proof depends on dynamic origin. Includes `dynamic.dependency-source.*` (e.g. `gem-not-found`) for the opt-in gem-source-inference path per [ADR-10](../adr/10-dependency-source-inference.md) (analyzer contract: [`docs/internal-spec/dependency-source-inference.md`](../internal-spec/dependency-source-inference.md)). |
| `static.*` | Static checks that stopped short of a proof, split by *which way* they fell short ([ADR-100](../adr/100-static-diagnostic-family-and-void-origins.md)). **`static.value-use.*`** — a value that demands proof reached a use position: `static.value-use.void` (implemented, see the row below) and `static.value-use.top` (the unguarded-`top`-call half, [special-types.md](special-types.md) § `top`; no implementation and no ADR yet). **`static.incomplete-inference.*`** — inference gave up and widened: the budget-cutoff identifiers (`.recursion`, `.union-size`, …) tracked by [ADR-41](../adr/41-inference-budget-design.md) (Proposed) / [#158](https://github.com/rigortype/rigor/issues/158) and marked at their source in [inference-budgets.md](inference-budgets.md) § "Budget table", authored `:info`, remain deferred with no implemented id. |
| `static.value-use.void` | An author-declared `-> void` return used in value context (an assignment right-hand side, a call receiver, or a call argument): the value the author said not to rely on was recovered to `top` and used. Direct-dispatch case only ([ADR-100](../adr/100-static-diagnostic-family-and-void-origins.md) WD2; the transitive / ancestor-fallback case is deferred WD4). Authored `:warning`, resolved `:off` by every profile and promoted to `:warning` only by the `use-of-void-value` bleeding-edge feature — a new required diagnostic is an [ADR-50](../adr/50-release-engineering-and-stability-strategy.md) WD1 compatibility change. |
| `flow.*` | Control-flow narrowing failures, equality and predicate refinement issues, fact-stability violations |
| `compat.*` | **Reserved — no implemented identifiers as of this writing.** RBS, rbs-inline, and Steep-compatible signature compatibility. A founding-era reservation ([ADR-1](../adr/1-types.md)); the shipped signature-compatibility rules live under `def.override-*` ([ADR-35](../adr/35-override-signature-compatibility.md)) instead. |
| `call.*` | Method-call-site diagnostics: `call.undefined-method` (the method is not defined on the receiver's statically known class), `call.self-undefined-method` (an implicit-self call resolves to no method on a confidently-closed standalone class, [ADR-24](../adr/24-self-method-call-resolution.md) slice 4 — consumes the engine's own resolution miss, gated to a standalone project class with a complete in-file method surface, ships `:off` pending an external corpus FP gate), `call.unresolved-toplevel` (a top-level implicit-self call resolves against no same-file `def`, `pre_eval:` patch, or `Kernel` / `Object` method, [ADR-34](../adr/34-toplevel-unresolved-self-call-default.md)), `call.wrong-arity` (the positional-argument count matches no signature), `call.argument-type-mismatch` (an argument provably violates the parameter contract), and `call.possible-nil-receiver` (the receiver is `T \| nil` and the method is not defined on `NilClass`). |
| `def.*` | Method-definition diagnostics. Includes the override signature-compatibility family `def.override-visibility-reduced` / `def.override-return-widened` / `def.override-param-narrowed` ([ADR-35](../adr/35-override-signature-compatibility.md)), which verify an override against the signature it inherits from a project-defined ancestor. They fire only when both the override and the shadowed ancestor carry an author-supplied signature (inference-only either side stays silent) and map severity through `severity_profile:`; the Liskov reasoning is in [robustness-principle.md](robustness-principle.md). |
| `rbs_extended.*` | `RBS::Extended` payload validity, version compatibility, and conflict reports. Includes `rbs_extended.unsatisfied-conformance` ([rbs-extended.md](rbs-extended.md) § "Explicit conformance directive"): a class carrying `%a{rigor:v1:conforms-to _Interface}` either is missing a method the named structural interface requires (presence) or provides one whose RBS signature is not a behavioural subtype of the interface's (covariant return / contravariant params). The signature tier is FP-safe because both sides are authored RBS (the ADR-35 both-sides-authored construction) and compares only single-method-type, non-`Dynamic` positions, so it never frightens a class that already satisfies the interface. Authored `:warning` (`:error` under `strict`); the directive is opt-in, so the diagnostic is never unsolicited. An unresolvable interface name surfaces as `dynamic.rbs-extended.unresolved` `:info` instead. |
| `rbs.coverage.*` | RBS environment coverage / well-formedness telemetry. `rbs.coverage.missing-gem` reports locked gems with no available RBS; `rbs.coverage.synthesized-namespace` reports project `signature_paths:` RBS that declares qualified names (`class Foo::Bar`) without the enclosing namespace — invalid upstream (`rbs validate` rejects it), which Rigor synthesizes a `module` for so the signatures still resolve. Both authored `:info`. `rbs.coverage.quarantined-signature` reports a `signature_paths:` `.rbs` that does not parse and was therefore SKIPPED: the rest of the environment still loads, but the types that file declared are absent, so the run is *quieter* rather than cleaner. Authored `:warning` (a broken sig set must not silently pass, but neither may an upgrade turn a green build red); the `reject-unparseable-signatures` bleeding-edge feature promotes it to `:error`, which is the intended default at a future major. `rbs.coverage.environment-build-failed` is its twin one tier louder in consequence: a `signature_paths:` entry that parses fine but redeclares a constant or class Rigor's bundled RBS already ships (`RBS::DuplicatedDeclarationError` at resolve) collapses the *whole* RBS environment to nil, so every type-of query reads `Dynamic[top]` and most diagnostics stop firing — the run is *empty* rather than clean. The diagnostic names the conflicting signature files (lifted off the raised error's declarations). Authored `:warning` for the same reason as its twin — the conflict is typically between the user's `sig/` and Rigor's *own* bundled RBS, so an `:error` default would let a Rigor release turn a green build red with no user change — and the same `reject-unparseable-signatures` bleeding-edge feature promotes it to `:error`. |
| `plugin.<plugin-id>.*` | Plugin-contributed diagnostics |
| `generated.<provider>.*` | **Reserved — no implemented identifiers as of this writing.** Generated-signature provider diagnostics; a founding-era reservation ([ADR-1](../adr/1-types.md) / [ADR-2](../adr/2-extension-api.md)). |
| `hint.*` | **Reserved — no implemented identifiers as of this writing.** Style and refactor suggestions, gated by configuration. [ADR-1](../adr/1-types.md) § "Capability roles" defines `hint.role-generalization.*` behind a `style.suggest_role_generalization` switch; neither the family nor that configuration key is implemented. |
| `sig.*` | **Not a diagnostic family as of this writing** — these identifiers are surfaced through `rigor sig-gen`'s JSON output, not the diagnostic stream (see the end of this row). RBS signature-generator telemetry per [ADR-14](../adr/14-rbs-sig-generation.md). Reserves `sig.generated.new-file` / `sig.generated.new-method` / `sig.generated.tighter-return` (per-method classifications the `rigor sig-gen` command emits when it produces RBS) and `sig.skipped.complex-shape` / `sig.skipped.user-authored` / `sig.skipped.untyped-return` / `sig.skipped.unrenderable-rbs` (per-method reasons the generator declined to emit; the last is a Rigor rendering defect — the generated line does not parse as RBS, so it is dropped rather than emitted, since an unparseable `.rbs` is quarantined whole by the consumer). The slice-1 MVP surfaces these identifiers through the command's JSON output rather than the diagnostic stream; later slices wire them as `:info` diagnostics when the `--write` path lands. |

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

- An unknown or empty marker keeps its documented matching behaviour (an unrecognised token is kept verbatim; a token-less marker suppresses nothing), but it is no longer silent: a marker token that resolves to no known identifier — not a canonical rule id, legacy alias, `all`, family wildcard, known non-catalogue engine id, or a dotted id under a known non-check family (including any `plugin.`-prefixed token, which is never flagged) — fires `suppression.unknown-rule`, and a marker listing no rules at all fires `suppression.empty` (both `:warning` in every profile). Validation happens before suppression filtering, so both diagnostics are themselves suppressible like any other rule; a comment that merely mentions the marker followed by non-token text remains an ordinary comment.
