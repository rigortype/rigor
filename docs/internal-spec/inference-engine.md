# Inference Engine

This document specifies the public contract that the Rigor type-inference engine MUST satisfy: the `Rigor::Scope#type_of(node)` query, the immutable-Scope discipline, the fail-soft `Dynamic[Top]` policy, and the environment-loading boundaries that surround them. It is the engine-side counterpart of the type-language semantics in [`docs/type-specification/`](../type-specification/) and the type-object public API in [`internal-type-api.md`](internal-type-api.md).

The slice-by-slice growth plan and the rationale behind the tentative answers to ADR-3's open questions live in [`docs/adr/4-type-inference-engine.md`](../adr/4-type-inference-engine.md). When that ADR and this document disagree on observable Ruby behavior, this document binds.

## Scope

This document binds:

- The shape and stability of the `Rigor::Scope#type_of(node)` query.
- The immutable-Scope discipline that surrounds the query.
- The fail-soft policy for AST nodes the typer does not yet recognise.
- The environment-loading boundaries: which surface MUST be available, and which surface MAY change between slices.

This document does **not** bind:

- The internal data structure used by `Rigor::Scope` (so long as the public surface is preserved and immutability is observable).
- The visitor or pattern-match strategy used inside `Rigor::Inference::ExpressionTyper`.
- The exact catalogue of Prism nodes recognised in any particular slice; that catalogue is informational and tracked in [`docs/adr/4-type-inference-engine.md`](../adr/4-type-inference-engine.md).

## The `Scope#type_of(node)` Contract

`Rigor::Scope#type_of(node)` MUST be a pure query. It MUST NOT mutate the receiver scope or any object reachable from it, and it MUST NOT cause persistent state changes anywhere else in the analyzer. The same `(scope, node)` pair MUST produce structurally equal `Rigor::Type` results across calls within a single analyzer run.

The query MUST return a `Rigor::Type` per [`internal-type-api.md`](internal-type-api.md). It MUST NOT return `nil`, raise on unsupported nodes, or expose Prism objects in its return value.

The receiver MUST be a `Rigor::Scope` instance. Implementations MUST NOT accept a raw Hash or Array of bindings; the binding container is internal to `Rigor::Scope`.

The `node` argument MUST be a `Prism::Node`. Implementations MAY accept additional Prism node families when added by upstream Prism, but MUST treat unrecognised node kinds under the fail-soft policy below rather than raising.

## Immutable Scope Discipline

`Rigor::Scope` instances MUST be immutable. They MUST be `freeze`d at the end of construction. Mutation through any public or internal method is a contract violation, including through accessors that expose internal containers.

State changes MUST be expressed as new scopes returned from explicit transition methods. The minimum set is:

- `Rigor::Scope.empty(environment:)` — constructs a scope with no local bindings, attached to a `Rigor::Environment`.
- `Rigor::Scope#with_local(name, type)` — returns a new scope identical to the receiver except that `name` is bound to `type`.
- `Rigor::Scope#local(name)` — returns the bound `Rigor::Type` or `nil` if `name` is not bound.

`Rigor::Scope` MUST share underlying data structurally where useful. Two scopes that share a parent and differ in one binding MAY share the storage of all other bindings; this is an implementation detail and not part of the contract.

`Rigor::Scope#environment` MUST return the same `Rigor::Environment` instance that constructed the scope. The environment is treated as immutable from the scope's perspective for the duration of a query.

## Fail-Soft Policy

When the typer encounters a Prism node it does not yet recognise, `Scope#type_of(node)` MUST return `Rigor::Type::Combinator.dynamic(Rigor::Type::Combinator.top)` — the canonical `Dynamic[Top]` representation of "untyped, unchecked".

The fail-soft path MUST satisfy:

- It MUST NOT raise. Callers MAY rely on `Scope#type_of` for any expression node Prism produces.
- It MUST preserve the dynamic-origin algebra in [`value-lattice.md`](../type-specification/value-lattice.md). Downstream queries against the returned type MUST observe the same gradual-typing rules that any other `Dynamic[T]` would.
- It MUST be observable to instrumentation. Implementations MAY expose a side channel that records the encountered node kind so coverage regressions can be detected. The channel MUST NOT change the return value of `type_of`.

When a slice introduces support for a node kind, the fail-soft path for that kind MUST be removed in the same slice. The typer MUST NOT keep a fallback that masks an incorrectly-typed node.

## Local Variables

Local variable read nodes (`Prism::LocalVariableReadNode`) MUST be looked up in the receiver scope. A bound name MUST return the bound `Rigor::Type`. An unbound name MUST fail soft to `Dynamic[Top]` per the rule above; `Scope#type_of` MUST NOT raise on unbound locals.

Local variable write nodes (`Prism::LocalVariableWriteNode` and the targets that imply it) MUST be typed as the type of their value expression. Binding the result back into the scope is the responsibility of the statement-level evaluator (see Slice 2 in [`docs/adr/4-type-inference-engine.md`](../adr/4-type-inference-engine.md)); `Scope#type_of` itself MUST NOT mutate the scope.

## Environment Surface

`Rigor::Environment` is the engine's view of the type universe outside the current scope: nominal classes, RBS definitions (Slice 3+), plugin-supplied facts (Slice 5+), and any other module-level information. The minimum public surface that Slice 1 binds is:

- `Rigor::Environment#class_registry` — returns a `Rigor::Environment::ClassRegistry` that can resolve a Ruby `Class` or `Module` object to a `Rigor::Type::Nominal`.
- `Rigor::Environment::ClassRegistry#nominal_for(class_object)` — returns the registered `Rigor::Type::Nominal` for a registered class, or raises if the class is not registered.
- `Rigor::Environment::ClassRegistry#registered?(class_object)` — returns `true` or `false` for whether the class is registered.

Slice 3 introduces `Rigor::Environment#rbs_loader`. Slice 5 introduces fact-store access. The methods added in later slices MUST NOT change the Slice 1 surface.

The class registry MUST always recognise the following Ruby classes: `Integer`, `Float`, `String`, `Symbol`, `NilClass`, `TrueClass`, `FalseClass`, `Object`, `BasicObject`. Implementations MAY extend this list as long as the listed classes remain present.

## Determinism and Caching

`Scope#type_of` results MUST be deterministic for a given `(scope, node)` pair. Caching MAY be used and MAY be keyed on identity (`equal?`) or on structural equality (`==`); caching MUST NOT change observable behavior, only performance.

Two scopes that compare structurally equal MUST produce structurally equal results from `Scope#type_of` for the same node, even if the scopes are not the same Ruby object.

## Stability and Versioning

The contracts in this document are stable within a major version. The following are additionally stable:

- The `Scope#type_of` shape (input types, return type, purity).
- The `Scope.empty(environment:)` constructor signature.
- The fail-soft policy and its `Dynamic[Top]` return value.
- The minimum class-registry surface listed above.

The following are explicitly out of the stability contract until later slices promote them:

- The exact catalogue of Prism nodes recognised by `ExpressionTyper`.
- The internal layout of `Rigor::Scope` and its caching strategy.
- The fact-store schema (Slice 5+) and the RBS-loader cache shape (Slice 3+).
- The capability and projection surfaces on `Rigor::Type`, which depend on the resolution of ADR-3's open questions.

## Related Documents

- [`docs/internal-spec/internal-type-api.md`](internal-type-api.md) — type-object public contract consumed by the typer.
- [`docs/internal-spec/implementation-expectations.md`](implementation-expectations.md) — engine-surface contract that surrounds the typer (Scope joins, fact store, effect model, capability-role inference).
- [`docs/adr/4-type-inference-engine.md`](../adr/4-type-inference-engine.md) — design rationale, slice roadmap, tentative answers to ADR-3's open questions.
- [`docs/adr/3-type-representation.md`](../adr/3-type-representation.md) — type-object representation and the open questions whose tentative answers ADR-4 commits.
- [`docs/type-specification/relations-and-certainty.md`](../type-specification/relations-and-certainty.md) — subtyping, gradual consistency, trinary semantics.
- [`docs/type-specification/value-lattice.md`](../type-specification/value-lattice.md) — `Dynamic[T]` algebra used by the fail-soft path.
- [`docs/type-specification/control-flow-analysis.md`](../type-specification/control-flow-analysis.md) — Slice 5 narrowing target.
