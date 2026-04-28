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

The `node` argument MUST be either a `Prism::Node` or a `Rigor::AST::Node` (a synthetic node from the *Virtual Nodes* family below). Implementations MAY accept additional Prism node families when added by upstream Prism, and additional `Rigor::AST::Node` subtypes when registered through the engine, but MUST treat unrecognised concrete classes within either family under the fail-soft policy below rather than raising.

## Immutable Scope Discipline

`Rigor::Scope` instances MUST be immutable. They MUST be `freeze`d at the end of construction. Mutation through any public or internal method is a contract violation, including through accessors that expose internal containers.

State changes MUST be expressed as new scopes returned from explicit transition methods. The minimum set is:

- `Rigor::Scope.empty(environment:)` — constructs a scope with no local bindings, attached to a `Rigor::Environment`.
- `Rigor::Scope#with_local(name, type)` — returns a new scope identical to the receiver except that `name` is bound to `type`.
- `Rigor::Scope#local(name)` — returns the bound `Rigor::Type` or `nil` if `name` is not bound.
- `Rigor::Scope#join(other)` — returns a new scope at a control-flow merge point. Implementations MUST require the two scopes to share the same `Environment`. The joined scope MUST be bound to every name that BOTH receivers bind; for each such name the joined type MUST be `Type::Combinator.union(self.local(name), other.local(name))`. Names bound in only one receiver MUST be dropped from the joined scope; nil-injection of half-bound names is the responsibility of the statement-level evaluator (see Slice 3 in [`docs/adr/4-type-inference-engine.md`](../adr/4-type-inference-engine.md)), not of `#join`.

`Rigor::Scope` MUST share underlying data structurally where useful. Two scopes that share a parent and differ in one binding MAY share the storage of all other bindings; this is an implementation detail and not part of the contract.

`Rigor::Scope#environment` MUST return the same `Rigor::Environment` instance that constructed the scope. The environment is treated as immutable from the scope's perspective for the duration of a query.

## Fail-Soft Policy

When the typer encounters a node it does not yet recognise — either a Prism node whose class the engine has not yet wired in or a `Rigor::AST::Node` of an unknown kind — `Scope#type_of(node)` MUST return `Rigor::Type::Combinator.dynamic(Rigor::Type::Combinator.top)`, the canonical `Dynamic[Top]` representation of "untyped, unchecked".

The fail-soft path MUST satisfy:

- It MUST NOT raise. Callers MAY rely on `Scope#type_of` for any expression node Prism produces and for any synthetic node that includes `Rigor::AST::Node`.
- It MUST preserve the dynamic-origin algebra in [`value-lattice.md`](../type-specification/value-lattice.md). Downstream queries against the returned type MUST observe the same gradual-typing rules that any other `Dynamic[T]` would.
- It MUST be observable to instrumentation through the *Fallback Tracer* contract below.

When a slice introduces support for a node kind, the fail-soft path for that kind MUST be removed in the same slice. The typer MUST NOT keep a fallback that masks an incorrectly-typed node.

### Fallback Tracer

`Rigor::Scope#type_of` MUST accept an optional `tracer:` keyword argument. When `tracer` is `nil` (the default), the engine MUST behave as if no tracer were attached: no events MUST be recorded and no allocations beyond those needed to produce the return value MUST be made on the fallback path.

When `tracer` is non-`nil`, every fail-soft fallback (both Prism and synthetic) MUST be recorded into the tracer through a single method call:

```ruby
tracer.record_fallback(event)
```

`event` MUST be a `Rigor::Inference::Fallback` value object with the following structurally-equal fields:

- `node_class` — the Ruby `Class` of the node that triggered the fallback (e.g. `Prism::CallNode`, `Rigor::AST::SomeFutureNode`).
- `location` — the Prism source location object for real Prism nodes, or `nil` for synthetic nodes that do not expose a location.
- `family` — the symbol `:prism` for real Prism nodes and `:virtual` for nodes that include `Rigor::AST::Node`.
- `inner_type` — the `Rigor::Type` returned to the caller. This is `Dynamic[Top]` today; later slices MAY enrich the inner type while keeping the fallback observable.

The tracer protocol exposed by `Rigor::Inference::FallbackTracer` MUST satisfy:

- `record_fallback(event)` MUST accept any `Rigor::Inference::Fallback` and reject other arguments.
- `events` MUST return a frozen, ordered snapshot of recorded events.
- `empty?` and `size` MUST report the current number of recorded events.
- `each` MUST iterate the recorded events in insertion order; the tracer MUST `include Enumerable`.

The tracer is the ONLY mutable state observable from `Scope#type_of`; it MUST NOT change the return value of `type_of` and MUST NOT be exposed through `Rigor::Scope` accessors. Implementations MAY add additional `record_*` methods (for example a richer `record_dispatch_miss` once the Slice 2 dispatcher gains tiers, or `record_budget_cutoff` in Slice 6) so multiple event families share a single tracer; new methods MUST follow the immutable-event-value-object pattern above.

## Virtual Nodes

The engine MUST accept a synthetic AST family in addition to Prism nodes. Synthetic nodes are Ruby objects that include the documentation-only marker module `Rigor::AST::Node` and expose whatever node-specific data the engine needs to translate them into a `Rigor::Type`. They make it possible to ask `Scope#type_of` "what would the analyzer infer if a value of type T appeared here?" without constructing a real Prism expression.

Synthetic nodes MUST satisfy:

- They MUST be immutable. `Rigor::AST::Node` MUST be `freeze`d at construction.
- They MUST support structural equality. Two synthetic nodes that hold structurally equivalent data MUST compare equal under `==` and `eql?` and MUST share the same `hash`.
- They MUST be composable with real Prism children when the synthetic node has an inner-AST position. The engine MUST NOT require all transitive children to be synthetic.
- They MUST NOT carry analyzer state or fact-store entries. Any such state lives on `Rigor::Scope` or in the engine's environment, not on the node.

`Scope#type_of(virtual_node)` is dispatched through the same fail-soft contract as Prism nodes: an unrecognised concrete class within `Rigor::AST::Node` MUST return `Dynamic[Top]` rather than raise.

### `Rigor::AST::TypeNode`

The minimum synthetic node family that this specification binds is `Rigor::AST::TypeNode`. It MUST exist, MUST include `Rigor::AST::Node`, MUST be constructible from a single `Rigor::Type`, and MUST satisfy:

- `Rigor::Scope#type_of(Rigor::AST::TypeNode.new(t))` MUST return a `Rigor::Type` that compares structurally equal to `t` for any non-`nil` `t`.
- The engine MUST NOT modify, normalise, annotate, or wrap the inner type. Round-trip through `TypeNode` is observably the identity.
- `TypeNode` MUST NOT be wrapped in `Dynamic[T]`, refinements, or any other carrier as a side effect of `Scope#type_of`.

Additional synthetic node kinds (call expressions, container literals, narrowing wrappers) are added by later slices and are non-normative until promoted. New kinds MUST follow the immutability, structural-equality, and composability rules above.

## Method Dispatch Boundary

Method dispatch (the rule that determines the result type of a call expression given a receiver type and argument types) MUST NOT live on `Rigor::Type` instances. Type classes remain thin value objects per [`internal-type-api.md`](internal-type-api.md): they hold structural data and answer capability questions, but they do not carry method-summary tables or operator handlers.

Slice 2 introduces `Rigor::Inference::MethodDispatcher` as a separate engine surface, originally planned for Slice 3 but pulled forward after the `rigor type-scan` dogfood signal showed `Prism::CallNode` and `Prism::ArgumentsNode` were the largest single source of unrecognised expressions. The Slice 2 dispatcher ships only a constant-folding tier; Slice 4 layers RBS-backed lookups behind it (see [`docs/adr/4-type-inference-engine.md`](../adr/4-type-inference-engine.md)).

The dispatcher's public signature is:

```ruby
Rigor::Inference::MethodDispatcher.dispatch(
  receiver_type:,        # Rigor::Type or nil (implicit self; unsupported in Slice 2)
  method_name:,          # Symbol
  arg_types:,            # Array<Rigor::Type>
  block_type: nil,       # reserved
  environment: nil       # Rigor::Environment; required for RBS-backed dispatch
) #=> Rigor::Type, or nil when no rule matches
```

A `nil` return value is the deliberate "no rule" signal. Callers MUST own the fail-soft fallback (`ExpressionTyper` records a `FallbackTracer` event and returns `Dynamic[Top]`); the dispatcher itself MUST NOT touch the tracer or raise on unrecognised inputs.

The dispatcher MUST consult tiers in this order: the constant-folding tier (Slice 2), the RBS-backed dispatch tier (Slice 4), and — once those land — the plugin-supplied method extensions defined by ADR-2. The first tier that returns a non-`nil` `Rigor::Type` wins; subsequent tiers MUST NOT be consulted on a hit. The dispatcher MUST take its input as a uniform call-shape that may carry either Prism child nodes or synthetic `Rigor::AST::Node` arguments (by way of the *Virtual Nodes* contract above), so synthesised expressions and real expressions share a single dispatch path.

The RBS-backed tier MUST resolve receiver types to a `(class_name, kind)` pair where `kind` is `:instance` or `:singleton`:

- `Type::Constant[v]` resolves to `(v.class.name, :instance)`.
- `Type::Nominal[name]` resolves to `(name, :instance)`.
- `Type::Singleton[name]` (Slice 4 phase 2b) resolves to `(name, :singleton)`. The dispatcher MUST consult `RbsLoader#singleton_method` rather than `instance_method` for this kind, so `Foo.bar` correctly looks up the class methods of `Foo`.
- `Type::Dynamic[T]` recurses into `T`'s static facet using the same rules.
- `Type::Top` and `Type::Bot` produce no descriptor; the dispatcher MUST return `nil`.

`Union` receivers MUST dispatch each member individually — when every member resolves, the per-member return types are unioned and that union is returned; when any member returns `nil`, the whole dispatch MUST return `nil`. Mixing instance and singleton members within a single union MUST NOT be a special case; each member is dispatched against its own descriptor. When the resolved RBS method has multiple overloads, the first overload's return type wins; argument-driven overload selection is deferred to Slice 4 phase 2c.

`Rigor::Inference::RbsTypeTranslator.translate(rbs_type, self_type:, instance_type:)` is the only normative path from `RBS::Types::*` to `Rigor::Type`. It MUST be deterministic, MUST NOT raise on any well-formed RBS type, and MUST follow the mapping documented in [`docs/adr/4-type-inference-engine.md`](../adr/4-type-inference-engine.md). The two substitution keywords are independent:

- `Bases::Self` MUST be substituted by `self_type:`. For instance dispatch this is `Nominal[C]`; for singleton dispatch it is `Singleton[C]`.
- `Bases::Instance` MUST be substituted by `instance_type:`. The dispatcher passes `Nominal[C]` regardless of dispatch kind so that `def self.create: () -> instance` resolves to `Nominal[C]` even when the receiver is `Singleton[C]`.
- Either keyword MAY be omitted; the corresponding RBS token then degrades to `Dynamic[Top]`.

Future slices that refine the mapping (generics, intersection, interfaces, alias resolution) MUST keep the existing entries' outputs unchanged on the gradual-typing axis: any tightening of precision MUST be a non-breaking change to subtyping queries against the result type.

When the receiver of a call is a `Rigor::Type::Dynamic` and no positive dispatcher tier matches, `ExpressionTyper#call_type_for` MUST return `Dynamic[Top]` *silently*, without recording a `FallbackTracer` event. This is a recognised semantic outcome — the value-lattice algebra in [`value-lattice.md`](../type-specification/value-lattice.md) requires Dynamic to propagate through opaque method calls — and not a fail-soft compromise. Receivers that are not Dynamic still trigger the standard fail-soft fallback (with a tracer event) when no rule resolves.

This split is normative: implementations MUST NOT define operator-method-aware subclasses of any `Rigor::Type` form (for example, a hypothetical `Rigor::Type::IntegerType` carrying `+`/`*` rules). Operator semantics MUST be expressed as method-handler entries that the dispatcher consults; specialising the type class for built-in arithmetic is rejected to keep the type lattice and method semantics independently extensible.

## Local Variables

Local variable read nodes (`Prism::LocalVariableReadNode`) MUST be looked up in the receiver scope. A bound name MUST return the bound `Rigor::Type`. An unbound name MUST fail soft to `Dynamic[Top]` per the rule above; `Scope#type_of` MUST NOT raise on unbound locals.

Local variable write nodes (`Prism::LocalVariableWriteNode` and the targets that imply it) MUST be typed as the type of their value expression. Binding the result back into the scope is the responsibility of the statement-level evaluator (see Slice 3 in [`docs/adr/4-type-inference-engine.md`](../adr/4-type-inference-engine.md)); `Scope#type_of` itself MUST NOT mutate the scope.

## Environment Surface

`Rigor::Environment` is the engine's view of the type universe outside the current scope: nominal classes, RBS definitions, plugin-supplied facts (Slice 6+), and any other module-level information. The minimum public surface that Slice 1 binds is:

- `Rigor::Environment#class_registry` — returns a `Rigor::Environment::ClassRegistry` that can resolve a Ruby `Class` or `Module` object to a `Rigor::Type::Nominal`.
- `Rigor::Environment::ClassRegistry#nominal_for(class_object)` — returns the registered `Rigor::Type::Nominal` for a registered class, or raises if the class is not registered.
- `Rigor::Environment::ClassRegistry#registered?(class_object)` — returns `true` or `false` for whether the class is registered.
- `Rigor::Environment::ClassRegistry#nominal_for_name(name)` — returns the registered `Rigor::Type::Nominal` for a Symbol/String class name, or `nil` when the name is unknown.

Slice 4 introduces:

- `Rigor::Environment#rbs_loader` — returns the `Rigor::Environment::RbsLoader` attached to the environment, or `nil` for an "RBS-blind" environment (test fixture).
- `Rigor::Environment::RbsLoader#class_known?(name)` — returns `true` when the RBS environment defines a class or module by that name; nil-safe and string/symbol tolerant.
- `Rigor::Environment::RbsLoader#instance_method(class_name:, method_name:)` — returns the resolved `RBS::Definition::Method` for the given instance method, or `nil` when the class or method is unknown. Inherited methods MUST be visible through this call (the loader uses `RBS::DefinitionBuilder#build_instance` which walks the ancestor chain).
- `Rigor::Environment::RbsLoader#singleton_method(class_name:, method_name:)` — Slice 4 phase 2b. Returns the resolved `RBS::Definition::Method` for the given *class method*, or `nil` when the class or method is unknown. Inherited class methods MUST be visible (e.g. `Class#new`, `Module#name`); the loader uses `RBS::DefinitionBuilder#build_singleton`. The instance and singleton namespaces MUST be disjoint — for example `Module#instance_methods` resolves on the singleton side and is silently absent on the instance side.
- `Rigor::Environment::RbsLoader.new(libraries:, signature_paths:)` — Slice 4 phase 2a. Lets callers extend the loader past RBS core: `libraries` is an array of stdlib library names accepted by `RBS::EnvironmentLoader#add(library:, version:)`; `signature_paths` is an array of `Pathname`-or-`String` directories of additional `.rbs` files. Unknown library names MUST fail-soft (the loader skips them via `RBS::EnvironmentLoader#has_library?`); non-existent signature paths MUST be silently dropped at build time. `RbsLoader#libraries` and `#signature_paths` expose the configured values for round-trip and observability.
- `Rigor::Environment#nominal_for_name(name)` — consults the class registry first, then the RBS loader (when present); returns the `Rigor::Type::Nominal` for the first hit, or `nil` when no hit. This is the construction helper for "an *instance* of class `name`".
- `Rigor::Environment#singleton_for_name(name)` — Slice 4 phase 2b. Returns the `Rigor::Type::Singleton` for the constant's class object, or `nil` when no class with `name` is known to either the registry or the RBS loader. This is the canonical entry point for typing `Prism::ConstantReadNode`/`Prism::ConstantPathNode`; `ExpressionTyper` MUST route through it so the result is the class object's type, not the instance type.
- `Rigor::Environment#class_known?(name)` — Slice 4 phase 2b. Convenience predicate that returns `true` when the registry or the RBS loader knows `name`. Useful for callers that need a presence check without materialising a carrier.
- `Rigor::Environment.for_project(root:, libraries:, signature_paths:)` — Slice 4 phase 2a. Factory that builds a project-aware Environment. Auto-detects `<root>/sig` as the default signature path when `signature_paths` is `nil` and the directory exists; uses an empty list otherwise. Callers MAY override the auto-detection by passing an explicit `signature_paths` array (including `[]` to disable). The factory MUST return a fresh Environment instance — it MUST NOT memoize or share with `Environment.default`, because project-aware loaders depend on the caller's working directory and configuration.

Slice 6 introduces fact-store access. The methods added in later slices MUST NOT change the Slice 1 surface.

The class registry MUST always recognise the following Ruby classes: `Integer`, `Float`, `String`, `Symbol`, `NilClass`, `TrueClass`, `FalseClass`, `Object`, `BasicObject`. Implementations MAY extend this list as long as the listed classes remain present.

The default `Rigor::Environment.default` MUST attach a default `RbsLoader` covering RBS core (no opt-in libraries, no signature paths). Constructing `Rigor::Environment.new` (no kwargs) MUST produce an RBS-blind environment so test fixtures can assert engine behaviour without paying RBS startup cost. The `for_project` factory is the canonical entry point for production CLI commands and any other call site that needs the local `sig/` tree.

## Determinism and Caching

`Scope#type_of` results MUST be deterministic for a given `(scope, node)` pair. Caching MAY be used and MAY be keyed on identity (`equal?`) or on structural equality (`==`); caching MUST NOT change observable behavior, only performance.

Two scopes that compare structurally equal MUST produce structurally equal results from `Scope#type_of` for the same node, even if the scopes are not the same Ruby object.

## Stability and Versioning

The contracts in this document are stable within a major version. The following are additionally stable:

- The `Scope#type_of` shape (input types, return type, purity, optional `tracer:` keyword).
- The `Scope.empty(environment:)` constructor signature.
- The `Scope#join(other)` semantics: same-environment requirement, intersection of bound names, union of types.
- The fail-soft policy and its `Dynamic[Top]` return value.
- The Fallback Tracer protocol (`record_fallback`, `events`, `empty?`, `size`, `each`) and the `Rigor::Inference::Fallback` value object.
- The minimum class-registry surface listed above.
- The `Rigor::AST::Node` marker module and the existence of `Rigor::AST::TypeNode` with the round-trip behaviour above.
- The method-dispatch boundary: method-summary tables MUST NOT live on `Rigor::Type` instances.

The following are explicitly out of the stability contract until later slices promote them:

- The exact catalogue of Prism nodes recognised by `ExpressionTyper`.
- The internal layout of `Rigor::Scope` and its caching strategy.
- The fact-store schema (Slice 6+) and the RBS-loader cache shape (Slice 4+).
- The capability and projection surfaces on `Rigor::Type`, which depend on the resolution of ADR-3's open questions.

## Related Documents

- [`docs/internal-spec/internal-type-api.md`](internal-type-api.md) — type-object public contract consumed by the typer.
- [`docs/internal-spec/implementation-expectations.md`](implementation-expectations.md) — engine-surface contract that surrounds the typer (Scope joins, fact store, effect model, capability-role inference).
- [`docs/adr/4-type-inference-engine.md`](../adr/4-type-inference-engine.md) — design rationale, slice roadmap, tentative answers to ADR-3's open questions.
- [`docs/adr/3-type-representation.md`](../adr/3-type-representation.md) — type-object representation and the open questions whose tentative answers ADR-4 commits.
- [`docs/type-specification/relations-and-certainty.md`](../type-specification/relations-and-certainty.md) — subtyping, gradual consistency, trinary semantics.
- [`docs/type-specification/value-lattice.md`](../type-specification/value-lattice.md) — `Dynamic[T]` algebra used by the fail-soft path.
- [`docs/type-specification/control-flow-analysis.md`](../type-specification/control-flow-analysis.md) — Slice 6 narrowing target.
