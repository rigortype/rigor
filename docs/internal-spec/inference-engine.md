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

- `Rigor::Scope.empty(environment:)` — constructs a scope with no local bindings and an empty `Rigor::Analysis::FactStore`, attached to a `Rigor::Environment`.
- `Rigor::Scope#with_local(name, type)` — returns a new scope identical to the receiver except that `name` is bound to `type`. Rebinding a local MUST invalidate facts that target that local.
- `Rigor::Scope#local(name)` — returns the bound `Rigor::Type` or `nil` if `name` is not bound.
- `Rigor::Scope#fact_store` — returns the immutable `Rigor::Analysis::FactStore` attached to the snapshot.
- `Rigor::Scope#local_facts(name, bucket: nil)` / `Rigor::Scope#facts_for(target:, bucket: nil)` — return facts from the scope's `Rigor::Analysis::FactStore` without exposing bucket storage directly.
- `Rigor::Scope#with_fact(fact)` — returns a new scope with `fact` added to the fact store.
- `Rigor::Scope#join(other)` — returns a new scope at a control-flow merge point. Implementations MUST require the two scopes to share the same `Environment`. The joined scope MUST be bound to every name that BOTH receivers bind; for each such name the joined type MUST be `Type::Combinator.union(self.local(name), other.local(name))`. Names bound in only one receiver MUST be dropped from the joined scope; nil-injection of half-bound names is the responsibility of the statement-level evaluator (see Slice 3 in [`docs/adr/4-type-inference-engine.md`](../adr/4-type-inference-engine.md)), not of `#join`. The joined fact store MUST retain only facts present on both input edges.

`Rigor::Scope` MUST share underlying data structurally where useful. Two scopes that share a parent and differ in one binding MAY share the storage of all other bindings; this is an implementation detail and not part of the contract.

`Rigor::Scope#environment` MUST return the same `Rigor::Environment` instance that constructed the scope. The environment is treated as immutable from the scope's perspective for the duration of a query.

### FactStore (Slice 6 phase 2 sub-phase 2)

`Rigor::Analysis::FactStore` is the immutable fact bundle carried by each `Scope` snapshot. The first implementation is intentionally small but establishes the long-term bucket shape from [`control-flow-analysis.md`](../type-specification/control-flow-analysis.md):

- `Rigor::Analysis::FactStore.empty` MUST return an empty frozen store.
- `FactStore::Target.local(name)` identifies a local-binding target.
- `FactStore::Fact` MUST carry `bucket`, `target`, `predicate`, `payload`, `polarity`, and `stability`. The recognised buckets are `local_binding`, `captured_local`, `object_content`, `global_storage`, `dynamic_origin`, and `relational`.
- `FactStore#with_fact(fact)` MUST return a new store and deduplicate structurally equal facts.
- `FactStore#invalidate_target(target, buckets: nil)` MUST return a new store with facts mentioning `target` removed. When `buckets:` is provided, only facts in those buckets are removed.
- `FactStore#join(other)` MUST retain only structurally equal facts present in both stores.

The fact-store buckets are an internal optimisation boundary. `Scope` may expose fact queries and fact-adding transitions, but callers MUST NOT mutate bucket storage in place.

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
  block_type: nil,       # Rigor::Type or nil; the inferred return type of an
                         #   accompanying `do ... end` / `{ ... }` block.
                         #   Slice 6 phase C sub-phase 2: when non-nil, the
                         #   selector prefers a block-bearing overload and the
                         #   method-level type parameter that the block's
                         #   return type references is bound to `block_type`
                         #   so a return like `Array[U]` resolves to
                         #   `Array[block_type]`.
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

`Union` receivers MUST dispatch each member individually — when every member resolves, the per-member return types are unioned and that union is returned; when any member returns `nil`, the whole dispatch MUST return `nil`. Mixing instance and singleton members within a single union MUST NOT be a special case; each member is dispatched against its own descriptor.

When the resolved RBS method has multiple overloads, Slice 4 phase 2c selects one of them through `Rigor::Inference::MethodDispatcher::OverloadSelector`. The selector MUST:

- Filter overloads by positional arity. The actual `arg_types.size` MUST satisfy `required_positionals.size + trailing_positionals.size <= n` and either `rest_positionals` is present or `n <= required + optional + trailing`.
- Skip overloads whose `required_keywords` is non-empty. Slice 4 phase 2c does not thread keyword arguments through the call site, so a keyword-required overload is unreachable from the current call shape.
- Among the remaining overloads, MUST consult `param_type.accepts(arg_type, mode: :gradual)` for every (formal, actual) positional pair (rest positionals consume one declaration repeatedly). An overload matches when every pair returns `yes` or `maybe`.
- Pick the first matching overload in declaration order. When no overload matches, fall back to `method_types.first`. The fallback is the only normative deviation from "first match wins": it preserves the fail-soft contract of Slice 4 phase 1 / 2b for call sites whose actual argument types cannot be matched by any overload (because of `untyped`-degraded interfaces, generics, or callers we have not yet wired in).

Implementations MAY pre-translate parameter types per overload for performance, but MUST NOT cache results across `(class_name, method_name)` keys because `self_type` and `instance_type` substitution depends on the dispatch site.

`Rigor::Inference::RbsTypeTranslator.translate(rbs_type, self_type:, instance_type:, type_vars:)` is the only normative path from `RBS::Types::*` to `Rigor::Type`. It MUST be deterministic, MUST NOT raise on any well-formed RBS type, and MUST follow the mapping documented in [`docs/adr/4-type-inference-engine.md`](../adr/4-type-inference-engine.md). The substitution keywords are independent:

- `Bases::Self` MUST be substituted by `self_type:`. For instance dispatch this is `Nominal[C]`; for singleton dispatch it is `Singleton[C]`.
- `Bases::Instance` MUST be substituted by `instance_type:`. The dispatcher passes `Nominal[C]` regardless of dispatch kind so that `def self.create: () -> instance` resolves to `Nominal[C]` even when the receiver is `Singleton[C]`.
- `Variable` (Slice 4 phase 2d) MUST be substituted by `type_vars:`. The map is keyed by the RBS variable's `name` symbol (`:Elem`, `:K`, `:V`, ...). Bound variables MUST be replaced by the bound `Rigor::Type` value; unbound variables MUST degrade to `Dynamic[Top]`.
- `ClassInstance` MUST translate its `args` recursively through the same `translate` call so `::Array[Elem]` round-trips into `Nominal["Array", [type_vars[:Elem]]]`. Translators for sibling generic forms (`Tuple`, `Record`, `Proc`) follow the same recursion rule once they grow generic carriage in Slice 5+.
- Any keyword MAY be omitted; the corresponding RBS token then degrades to `Dynamic[Top]`. The `type_vars:` default MUST be the empty hash so the keyword does not influence non-generic calls.

Future slices that refine the mapping (intersection, interfaces, alias resolution) MUST keep the existing entries' outputs unchanged on the gradual-typing axis: any tightening of precision MUST be a non-breaking change to subtyping queries against the result type.

The Slice 4 phase 2d generic dispatch contract MUST also satisfy:

- `Rigor::Type::Nominal` MUST carry an ordered, frozen `type_args` array. The empty array MUST denote the "raw" form (`Array`) and any non-empty array MUST denote an applied generic (`Array[Integer]`). Two carriers MUST compare structurally equal only when both `class_name` AND `type_args` match.
- `Rigor::Environment::RbsLoader#class_type_param_names(class_name)` MUST return the class's declared type-parameter names as `Array<Symbol>`, drawing from the instance definition because singleton methods parameterize over the same names. It MUST return an empty array for non-generic classes and for unknown names (fail-soft).
- The dispatcher MUST build the `type_vars` map by zipping `class_type_param_names` against the receiver's `type_args`. Empty `type_args` (raw receivers and singletons) MUST yield an empty map so free variables degrade as before. Arity disagreement between params and args MUST yield an empty map; the dispatcher MUST NOT silently truncate or pad.
- The dispatcher MUST thread the same `type_vars` map through both the overload selector and the final return-type translation, so parameter types like `::Array[Elem]` substitute Elem before the accepts check rather than degrading to `Array[Dynamic[Top]]`.

The Slice 5 phase 1 shape-dispatch contract MUST also satisfy:

- `Rigor::Type::Tuple` and `Rigor::Type::HashShape` MUST be projected onto their underlying nominal carriers when used as dispatch receivers. `Tuple[T1..Tn]` projects to `Nominal["Array", [union(T1..Tn)]]` (raw `Array` for empty Tuples); `HashShape{k: T,...}` projects to `Nominal["Hash", [union(constant_keys), union(values)]]` (raw `Hash` for empty shapes). The projection MUST be confined to `RbsDispatch.receiver_descriptor`; the surface contract on the carriers themselves MUST stay value-object thin.
- `Rigor::Inference::Acceptance` MUST treat shape carriers symmetrically with their projected nominal:
  - A nominal `self` MUST accept a shape `other` by projecting the shape and recursing through the existing nominal-acceptance route, so `Nominal[Array, [Integer]].accepts(Tuple[Constant[1], Constant[2]])` is equivalent to `Nominal[Array, [Integer]].accepts(Nominal[Array, [union(Constant[1], Constant[2])]])` and yields the same result.
  - A `Tuple` `self` MUST require `Tuple` `other` of equal arity, and recurse element-wise (covariant). Mismatched arity MUST collapse to `no`. Non-Tuple `other` MUST be rejected because the analyzer cannot prove arity from a generic nominal alone.
  - A `HashShape` `self` MUST require every required key of `self` to be required in `other` (depth covariant on shared entries). Optional keys on `self` MAY be absent in `other`; when present, their values MUST satisfy the same depth check. A closed `self` MUST reject known extra keys and open-extra-key sources; an open `self` MAY accept wider shapes. Missing required keys MUST collapse to `no`. Non-HashShape `other` MUST be rejected; nominal-side projection lives on the `accepts_nominal` route, not on the HashShape route.
- `Rigor::Inference::RbsTypeTranslator` MUST map `RBS::Types::Tuple` and `RBS::Types::Record` to the dedicated shape carriers (NOT to `Nominal[Array]`/`Nominal[Hash]`). Element and field types MUST be translated recursively under the caller's `self_type:` / `instance_type:` / `type_vars:` context, so generics inside tuples and records survive the boundary. `Record` MUST translate required fields from `RBS::Types::Record#fields`, optional fields from `#optional_fields`, and mark the resulting `HashShape` as closed.
- `Rigor::Inference::ExpressionTyper` MUST upgrade non-empty array literals whose every element is a non-splat value to `Tuple` carriers; literals containing splats MUST keep the Slice 4 phase 2d `Nominal[Array, [union]]` form so `[*xs, 1]` still produces an inferable element type. `ExpressionTyper` MUST upgrade hash literals whose every entry is an `AssocNode` with a static `SymbolNode` or `StringNode` key (with a non-`nil` `value`/`unescaped`) to `HashShape` carriers; literals with `AssocSplatNode` entries, dynamic keys, or duplicate keys MUST fall through to the `Nominal[Hash, [K, V]]` form. Integer-endpoint `RangeNode` literals MUST be carried as `Constant[Range]` so shape dispatch can resolve tuple range slices; dynamic ranges MUST remain `Nominal[Range]`.

When the receiver of a call is a `Rigor::Type::Dynamic` and no positive dispatcher tier matches, `ExpressionTyper#call_type_for` MUST return `Dynamic[Top]` *silently*, without recording a `FallbackTracer` event. This is a recognised semantic outcome — the value-lattice algebra in [`value-lattice.md`](../type-specification/value-lattice.md) requires Dynamic to propagate through opaque method calls — and not a fail-soft compromise. Receivers that are not Dynamic still trigger the standard fail-soft fallback (with a tracer event) when no rule resolves.

The Slice 5 phase 2 shape-aware dispatch tier (`Rigor::Inference::MethodDispatcher::ShapeDispatch`) MUST run between the constant-folding tier and the RBS-backed tier so that `Tuple` and `HashShape` receivers resolve element-access methods to their precise per-position / per-key type rather than the projected `Array#[]` / `Hash#fetch` answer. The tier MUST handle the following catalogue, returning `nil` to defer to `RbsDispatch` when the call cannot be proved against the static shape:

- Tuple receivers: `first`, `last`, `size`/`length`/`count` (no-arg, no-block) MUST return the precise tuple element / `Constant[size]`. `[]` and `fetch` with a single `Constant[Integer]` argument MUST normalise negative indices by length and return the precise element when the index is in `[-size, size)`; out-of-range indices MUST defer (`nil`) so the projection answer applies for `fetch` (which would raise) and MUST resolve to `Constant[nil]` only when invoked through a chain step (see `dig` below). `[]` with `Constant[Range]` integer/nil endpoints and `[]` with two `Constant[Integer]` arguments MUST use Ruby `Array#[]` slice semantics and return a sliced `Tuple` or `Constant[nil]` for statically nil slices; `fetch` MUST NOT claim those forms. `dig` MUST recurse through the resolved member: a `Tuple`/`HashShape` member MUST re-dispatch into the catalogue with the remaining arguments; a `Constant[nil]` member MUST short-circuit the chain (Ruby's `Array#dig` does the same at runtime); other Constants and any non-shape carrier MUST defer so the projection answer applies. An out-of-range index that arises *during* a chain step MUST resolve to `Constant[nil]` because Ruby's `Array#dig` returns nil for out-of-range indices rather than raising.
- HashShape receivers: `size`/`length` (no-arg) MUST return `Constant[size]` only when the shape is closed and no known key is optional. `[]` and `fetch` with a single `Constant[Symbol|String]` argument MUST return the precise value when a required key is declared. Optional-key `[]`/`dig` MUST return `value | nil`, while optional-key `fetch` MUST defer because the key may be absent and Ruby would raise `KeyError`. Missing keys MUST resolve to `Constant[nil]` for `[]` (matching Ruby's runtime behaviour) and MUST defer for `fetch`. `dig` MUST follow the same chain semantics as Tuple `dig`: a single static key resolves to the precise value (or `Constant[nil]` for a missing key); a multi-key chain recurses with the resolved value as the new receiver. `values_at` with one or more `Constant[Symbol|String]` arguments MUST return a `Tuple` whose per-position values are the per-key values, with missing keys filled by `Constant[nil]`. Falls through (defers) when any argument is non-static or when the call has zero arguments.

The shape tier MUST NOT consult the RBS environment, MUST NOT raise on any input, and MUST NOT touch the fallback tracer; it is a pure refinement layered on the type carriers. Methods outside the catalogue, non-static keys/indices, non-integer ranges, and any `dig`/`values_at` call whose chain steps cannot be resolved statically MUST defer so the projection-based `RbsDispatch` answer applies.

This split is normative: implementations MUST NOT define operator-method-aware subclasses of any `Rigor::Type` form (for example, a hypothetical `Rigor::Type::IntegerType` carrying `+`/`*` rules). Operator semantics MUST be expressed as method-handler entries that the dispatcher consults; specialising the type class for built-in arithmetic is rejected to keep the type lattice and method semantics independently extensible.

## Local Variables

Local variable read nodes (`Prism::LocalVariableReadNode`) MUST be looked up in the receiver scope. A bound name MUST return the bound `Rigor::Type`. An unbound name MUST fail soft to `Dynamic[Top]` per the rule above; `Scope#type_of` MUST NOT raise on unbound locals.

Local variable write nodes (`Prism::LocalVariableWriteNode` and the targets that imply it) MUST be typed as the type of their value expression. Binding the result back into the scope is the responsibility of the statement-level evaluator (see Slice 3 in [`docs/adr/4-type-inference-engine.md`](../adr/4-type-inference-engine.md)); `Scope#type_of` itself MUST NOT mutate the scope.

## Statement-Level Evaluation

`Rigor::Scope#type_of` is a pure expression-level query and MUST NOT thread scope. The statement-level evaluator `Rigor::Inference::StatementEvaluator` (Slice 3 phase 2) sits next to it and provides the complementary scope-threading surface. Its public delegate on `Rigor::Scope` MUST exist:

```ruby
Rigor::Scope#evaluate(node, tracer: nil) #=> [Rigor::Type, Rigor::Scope]
```

The contract MUST satisfy:

- The first element of the returned pair MUST be the type that `node` produces, equivalent to what `Scope#type_of(node)` would return for a pure expression. The second element MUST be the scope observable AFTER `node` has run; for nodes that perform no scope effect this MUST be the receiver scope (compared with `==`, the receiver's identity MAY differ).
- The receiver scope MUST never be mutated. Internal recursion MUST allocate fresh `StatementEvaluator` instances for every forked scope so branches stay isolated and the equality of distinct branch outputs is observable.
- The `tracer:` keyword MUST be threaded into every nested `Scope#type_of` call so fail-soft fallbacks emitted while typing children of a statement-y node are recorded under the same tracer.
- An `evaluate` call against a node that the evaluator does not specialise MUST defer to `Scope#type_of(node, tracer:)` and MUST return the receiver scope unchanged. This preserves the Slice 1 fail-soft policy: an unrecognised statement-y node MUST NOT raise.

The catalogue of nodes that the evaluator MUST recognise in Slice 3 phase 2 is:

- `Prism::ProgramNode` and `Prism::StatementsNode` — sequential evaluation that threads scope through every child statement in declaration order. The body's value MUST be the type of the last statement (or `Constant[nil]` for an empty body); the post-scope MUST be the post-scope of the last statement.
- `Prism::LocalVariableWriteNode` — evaluates the rvalue under the entry scope and binds `name` to the resulting type via `Scope#with_local`. The pair's type MUST equal the rvalue type.
- `Prism::MultiWriteNode` (Slice 5 phase 2 sub-phase 2) — evaluates the right-hand side once under the entry scope, then walks the destructuring tree (`lefts` / `rest` / `rights`, with `rest` a `Prism::SplatNode` whose `expression` MAY be a `Prism::LocalVariableTargetNode`) and binds every named local through `Rigor::Inference::MultiTargetBinder`. The pair's type MUST equal the right-hand side's type (matching Ruby's `(a, b = [1, 2]) #=> [1, 2]` semantics). When the right-hand side is a `Type::Tuple`, per-slot bindings MUST be element-wise: missing front/back slots collapse to `Constant[nil]`, the rest slot binds to a `Type::Tuple` of the middle elements (`Tuple[]` when the source has no surplus). For non-Tuple right-hand sides every slot MUST bind to `Dynamic[Top]`. Nested `Prism::MultiTargetNode` targets MUST recurse through the same binder. Non-local targets (instance/class/global variables, constants, index/call targets, anonymous splat) MUST be silently skipped.
- `Prism::IfNode` and `Prism::UnlessNode` — evaluate the predicate first (its post-scope is shared by both branches), then evaluate each branch under the post-predicate scope. The result type MUST be the union of the two branch types; the post-scope MUST be the join-with-nil-injection of the two branch scopes (see below). A `nil` branch (no else / no then) MUST contribute `Constant[nil]` and the post-predicate scope.
- `Prism::ElseNode` — evaluates its body under the receiver scope, returning `[Constant[nil], scope]` for empty bodies.
- `Prism::CaseNode` and `Prism::CaseMatchNode` — evaluate the predicate first; every `WhenNode`/`InNode` body and the optional else-clause are evaluated independently under the post-predicate scope and merged with the same join-with-nil-injection rule generalised to N branches.
- `Prism::WhenNode` and `Prism::InNode` — evaluate their statements under the receiver scope; an empty body MUST be `[Constant[nil], scope]`.
- `Prism::BeginNode` — evaluate the primary path (body, then optional else-clause; the else-clause MUST replace the body's value while the body's scope effects still apply because the body did run before the else). Each `Prism::RescueNode` in the chain is an alternative exit path evaluated under the entry scope. The exit type MUST be the union of the primary and rescue exits; the exit scope MUST be the join-with-nil-injection of the primary and rescue scopes. When an `ensure_clause` is present, its scope effects MUST be layered on the joined exit scope, so locals bound exclusively in the ensure stay observable; the ensure's value MUST NOT contribute to the exit type.
- `Prism::WhileNode` and `Prism::UntilNode` — evaluate the predicate (its post-scope is observable in the body), then evaluate the body. The result type MUST be `Constant[nil]`. The post-scope MUST be the join-with-nil-injection of the post-predicate scope and the post-body scope, modelling "body might have run zero or more times".
- `Prism::AndNode` and `Prism::OrNode` — evaluate the LHS, then the RHS under the LHS's post-scope. The result type MUST be the union of the two operand types; the post-scope MUST be the join-with-nil-injection of the LHS and RHS post-scopes (modelling "LHS always ran; RHS only sometimes ran"). Slice 3 phase 2 does NOT narrow on the LHS's truthiness; that refinement is the job of Slice 6.
- `Prism::ParenthesesNode` — threads scope through the inner expression so `(x = 1; x + 2)` binds `x` and produces `Constant[3]`.
- `Prism::ClassNode` and `Prism::ModuleNode` — evaluate the body in a *fresh* scope (Ruby's class/module scope does NOT see the outer locals; it shares only the Environment). The body's value is the body's last statement (or `Constant[nil]` for an empty body); the post-scope MUST be the receiver scope unchanged because a class/module definition does not bind any local in its enclosing scope. The evaluator MUST push a new lexical class frame onto its `class_context` for the body's evaluation; nested `def`s consult the frame to resolve their RBS lookup. The frame's qualified name MUST be the rendered `constant_path` (e.g., `"Foo::Bar"` for `class Foo::Bar` and the join of every nested name for `class A; class B`).
- `Prism::SingletonClassNode` — same fresh-scope contract. When the singleton expression is `self`, the innermost lexical class frame MUST be flipped to `singleton: true` for the body's evaluation, so a `def foo` inside `class << self` resolves through `RbsLoader#singleton_method`. For non-`self` expressions the receiver class is not statically resolvable; the evaluator MUST keep the existing class context unchanged and accept that nested defs degrade to the `Dynamic[Top]` parameter default.
- `Prism::DefNode` — builds the method-entry scope by binding every named parameter through `Rigor::Inference::MethodParameterBinder` (see below) and evaluates the body under that scope. The pair's type MUST be `Constant[:method_name]` (matching Ruby's runtime behaviour of `def` evaluating to a Symbol) and the pair's scope MUST be the receiver scope unchanged (a `def` does not introduce a binding in its enclosing scope). The body MUST NOT see the outer scope's locals.

### Self typing (Slice A-engine)

`Rigor::Scope` carries an optional `self_type:` field, accessed through `Scope#self_type` and updated via `Scope#with_self_type(type)`. The field is `nil` for top-level scopes and is injected by the `StatementEvaluator` at the boundaries where Ruby gives `self` a definite identity:

- `Prism::ClassNode` / `Prism::ModuleNode` body: `self_type` MUST be `Singleton[<qualified-name>]` (because `self` inside the class body is the class object itself).
- `Prism::SingletonClassNode` body when the receiver is `self`: same as above (the body still runs with `self` = the enclosing class object), and the innermost class frame additionally flips to `singleton: true`.
- `Prism::DefNode` body: when the def is on the singleton side (`def self.foo` or any def lexically inside `class << self`) or the surrounding class frame is already singleton, `self_type` MUST be `Singleton[<qualified-name>]`. Otherwise (an ordinary instance def), `self_type` MUST be `Nominal[<qualified-name>]` with no type arguments. Top-level defs (no enclosing class) MUST leave `self_type` as `nil`.

`ExpressionTyper` consumes the field in two places:

- `Prism::SelfNode` MUST type as `scope.self_type` when set, or `Dynamic[Top]` when nil. This MUST NOT record a fallback event in either case.
- `Prism::CallNode` with `receiver: nil` (an implicit-self call such as `attr_reader_method`, `private_helper`, ...) MUST adopt `scope.self_type` as the receiver type for `MethodDispatcher.dispatch`. When `self_type` is nil, the receiver remains nil and the existing top-level fallback applies.

`Scope#==` and `Scope#hash` MUST include `self_type`. `Scope#join` MUST keep `self_type` when both sides agree and reset it to `nil` when they differ. `Scope#with_local`, `Scope#with_fact`, and `Scope#with_self_type` MUST all preserve the other two fields.

### Lexical constant lookup (Slice A constant-walk)

`ExpressionTyper#type_of_constant_read` and `#type_of_constant_path` MUST resolve a constant by walking the surrounding lexical class context, mirroring Ruby's runtime constant lookup rules at the granularity the analyzer can prove statically:

1. The qualified candidate `<class_path>::<name>` MUST be tried first, where `<class_path>` is the `class_name` of `Scope#self_type` when the latter is a `Type::Nominal` or `Type::Singleton`.
2. The candidate path MUST then be peeled one `::segment` at a time and re-tried (`<class_path>::<name>` → `<parent_path>::<name>` → ... → `<top>::<name>`).
3. The bare `<name>` MUST be tried last, preserving the pre-walk top-level behaviour.
4. The first candidate that resolves through `Environment#singleton_for_name` produces the result `Type::Singleton[<resolved>]`. If no candidate resolves, the engine MUST fall through to `fallback_for(node, family: :prism)` exactly as before.

Top-level scopes (no `self_type` set) MUST yield only the bare candidate so the pre-walk behaviour is observable for tests that do not configure a class context. The walk MUST NOT mutate the receiver scope, MUST NOT raise on names that fail to resolve, and MUST NOT traverse the singleton ancestry chain — that refinement (and constant-value lookup for non-class constants such as `BUCKETS: Array[Symbol]` declared on a class) is a future slice.

### Join with Nil-Injection

`Scope#join` drops names bound in only one receiver (per the [Immutable Scope Discipline](#immutable-scope-discipline) above). The statement-level evaluator's branch-merge MUST instead inject `Constant[nil]` for half-bound names so the joined scope sees them as `T | nil`:

- For names bound in `scope_a` but not `scope_b`: bind those names to `Constant[nil]` in `scope_b` before joining.
- For names bound in `scope_b` but not `scope_a`: bind those names to `Constant[nil]` in `scope_a` before joining.
- Then call `Scope#join` on the augmented scopes; the result MUST contain every name from either side, with the union including `Constant[nil]` for names bound in only one side.

This is the contract that the Slice 3 phase 1 [Immutable Scope Discipline](#immutable-scope-discipline) defers to the statement-level evaluator. N-ary branch merges (case/when, begin/rescue chain) reduce by repeated pairwise join-with-nil-injection; the reduce order does not affect the result because nil-injection commutes with union under `Scope#join`.

### Per-Node Scope Index

`Rigor::Inference::ScopeIndexer.index(root, default_scope:)` is the canonical surface that converts a Prism program subtree into a per-node scope lookup. It MUST satisfy:

- The return value MUST be an identity-comparing `Hash{Prism::Node => Rigor::Scope}`. Looking up a node not contained in `root`'s subtree MUST yield `default_scope` (the `Hash#default` slot).
- For every Prism node the StatementEvaluator visits during `evaluate(root)`, the indexer MUST record the entry scope observed at that visit. Visits are fired through the `on_enter:` callback the indexer wires onto a fresh evaluator (the StatementEvaluator therefore stays state-free; the indexer carries the table).
- For every Prism node in `root`'s subtree the StatementEvaluator does NOT visit (expression-interior children of nodes that the evaluator's default branch fell through on), the indexer MUST set the recorded scope to the nearest recorded ancestor's scope. The DFS pre-order propagation is a contract: a child MUST observe an entry scope at least as informative as its parent's, never weaker.
- The indexer MUST run its internal StatementEvaluator with `tracer: nil`. CLI callers that want fail-soft fallback events MUST attach their tracer only to the post-index `type_of` probe, so the events come exactly from the second pass and are not double-recorded by the indexer's own typing of the program tree.

The CLI commands `rigor type-of` and `rigor type-scan` MUST consult the index when typing nodes from a parsed file, so locals bound earlier in the program flow into the scope used to type later nodes. Both commands look up `index[node]` and then run `node_scope.type_of(node, tracer:)`. The contract above is what makes this composition correct.

### `Rigor::Inference::StatementEvaluator#initialize(on_enter:)`

The third constructor keyword on `StatementEvaluator` is the hook the ScopeIndexer drives. It MUST satisfy:

- `on_enter:` defaults to `nil`. When `nil`, no callback fires and the evaluator's behaviour MUST be observably identical to a slice 3 phase 2 evaluator constructed without the keyword.
- When non-`nil`, the callback MUST be called exactly once at the start of every `evaluate(node)` call, before the handler dispatch, with `(node, scope)` as the arguments — `node` is the Prism node being entered and `scope` is the entry scope (`@scope` at that recursion level).
- The callback MUST be threaded through every recursive `sub_eval` so that nested invocations on forked scopes still report their own entries.

### Method Parameter Binding

`Rigor::Inference::MethodParameterBinder.new(environment:, class_path:, singleton:)` is the canonical surface that builds the method-entry scope from a `DefNode`. It MUST satisfy:

- `bind(def_node)` MUST return an ordered `Hash{Symbol => Rigor::Type}` of parameter name to bound type, in the order the names appear in the def's parameter list.
- Anonymous parameters (`*` and `**` without an identifier) MUST be skipped silently because there is no local name to bind.
- When `class_path:` is `nil`, when the environment has no RBS loader, or when the resolved class/method is unknown to RBS, every parameter MUST default to `Dynamic[Top]`. The binder MUST NOT raise on RBS misses; the fail-soft contract from the Slice 1 fail-soft policy applies at the binding boundary too.
- When the RBS lookup succeeds, every parameter slot MUST be bound to the *union of the matching RBS parameter types across every overload that has that slot*. Overloads that omit the slot (e.g., `Array#first`'s `()` overload, vs the `(?int)` overload that the `n` parameter of `def first(n)` matches) MUST be skipped silently rather than contributing a `Dynamic[Top]` (so the binding is the most informative type the signature provides without having to know which overload the caller will pick).
- Positional slots (required, optional, rest, trailing) MUST be matched by *position* into the matching RBS positional list. Keyword slots (required, optional) MUST be matched by *name* across both the required and optional keyword maps so a `def foo(by:)` redefinition picks up an `?by:` keyword in the RBS overload (or vice versa).
- A `*rest` parameter's bound type MUST be `Nominal["Array", [T]]` where `T` is the translated rest element type. A `**kw_rest` parameter's bound type MUST be `Nominal["Hash", [Nominal["Symbol"], V]]` where `V` is the translated rest-keyword value type. The binder MUST NOT bind a rest parameter to a single element type — the local actually holds the array/hash.
- When `def_node.receiver` is a `Prism::SelfNode` OR `singleton:` is `true`, the binder MUST consult `RbsLoader#singleton_method` (the immediate enclosing lexical scope is a singleton class). Otherwise it MUST consult `RbsLoader#instance_method`. The translator's `self_type:` and `instance_type:` keywords MUST be set to `(Singleton[C], Nominal[C])` for the singleton route and `(Nominal[C], Nominal[C])` for the instance route.

### Multi-Target Binder (Slice 5 phase 2 sub-phase 2)

`Rigor::Inference::MultiTargetBinder` is the canonical surface for decomposing a tuple-shaped right-hand side type against a Prism multi-target tree. It is a pure module-function module (no state) and MUST satisfy:

- `MultiTargetBinder.bind(target_node, rhs_type)` — accepts either a `Prism::MultiWriteNode` (statement-level `a, b = rhs`) or a `Prism::MultiTargetNode` (nested `(a, b)` form). Returns an ordered `Hash{Symbol => Rigor::Type}` whose keys are the named locals bound by the destructuring, in declaration order.
- When `rhs_type` is a `Type::Tuple`, the binder MUST decompose the elements into the front (`lefts`), middle (`rest`), and back (`rights`) regions. Front targets at index `i` MUST bind to `tuple.elements[i]` or `Constant[nil]` when the index is past the tuple's bounds. The rest target (a `Prism::SplatNode` with a `LocalVariableTargetNode` expression) MUST bind to `Type::Tuple[*middle]` (with `middle` empty when the source has no surplus elements). Back targets MUST bind to the elements at the corresponding tail offsets (or `Constant[nil]` when out of bounds).
- When `rhs_type` is anything other than a `Type::Tuple`, every slot (fronts, rest, backs) MUST bind to `Type::Combinator.untyped` (`Dynamic[Top]`). The slice deliberately stays conservative on dynamic-arity right-hand sides until a richer carrier-receiver lattice lands.
- Nested `Prism::MultiTargetNode` targets MUST recurse with the slot's type as the new right-hand side. This lets `a, (b, c) = [1, [2, 3]]` bind `a -> 1`, `b -> 2`, `c -> 3` when both nesting levels are tuple-shaped.
- Non-local targets (`InstanceVariableTargetNode`, `ConstantTargetNode`, `IndexTargetNode`, `CallTargetNode`, `ConstantPathTargetNode`, `ImplicitRestNode`, anonymous splat without an expression, ...) MUST be silently skipped: they have no observable contribution to the local-variable scope the StatementEvaluator threads.
- The binder MUST NOT raise on any well-formed Prism input and MUST NOT mutate its arguments.

### Block Parameter Binding (Slice 6 phase C sub-phases 1 and 2)

`Rigor::Inference::BlockParameterBinder` is the canonical surface that builds the entry scope augmentation for a `Prism::BlockNode`. It MUST satisfy:

- `BlockParameterBinder.new(expected_param_types:)` accepts an ordered array of `Rigor::Type` values, one per positional block parameter as supplied by the receiving method's RBS signature. Indices the binder cannot fill from this array (the array is shorter than the parameter list, or the slot is a kind that is not driven by the array) MUST default to `Dynamic[Top]`.
- `bind(block_node)` MUST return an ordered `Hash{Symbol => Rigor::Type}` of parameter name to bound type, in declaration order. Anonymous parameters MUST be skipped silently. `Prism::MultiTargetNode` destructuring slots (the `|(a, b), c|` form) MUST be expanded through `Rigor::Inference::MultiTargetBinder` against the slot's expected type (Slice 6 phase C sub-phase 2): a `Type::Tuple` slot decomposes element-wise; any other carrier collapses every inner local to `Dynamic[Top]`. The inner targets are `Prism::RequiredParameterNode` instances (block-side encoding); `MultiTargetBinder` MUST treat them uniformly with `Prism::LocalVariableTargetNode` for binding purposes.
- A `*rest` parameter MUST be bound to `Nominal["Array", [Dynamic[Top]]]`. A `**kw_rest` parameter MUST be bound to `Nominal["Hash", [Nominal["Symbol"], Dynamic[Top]]]`. An explicit `&block` parameter MUST be bound to `Nominal[Proc]`. Keyword parameters (required and optional) MUST be bound to `Dynamic[Top]` because Slice 6 phase C sub-phase 1 does not introspect the receiving method's block keyword signature.
- `NumberedParametersNode` (the implicit-`_1` form) MUST yield bindings for `:_1`, `:_2`, ... up to `numbered_node.maximum`, each driven by the same per-position `expected_param_types:` array used for explicit parameters. Slots past the array's length MUST default to `Dynamic[Top]`. This is the Slice 6 phase C sub-phase 2 contract; the previous slice's "no-bindings" behaviour is superseded.
- The binder MUST NOT raise on any well-formed Prism block node and MUST NOT mutate its input.

`Rigor::Inference::MethodDispatcher.expected_block_param_types(receiver_type:, method_name:, arg_types:, environment:)` is the canonical query that supplies the binder's `expected_param_types:` array. It MUST satisfy:

- It MUST return an ordered `Array<Rigor::Type>` of the positional block parameters (`required_positionals` + `optional_positionals`) declared by the selected RBS overload. Block-only keyword parameters and rest forms MUST be excluded from the returned array; the binder handles those slots independently.
- It MUST select the overload through `OverloadSelector.select` with `block_required: true`, so a block-bearing call (`Array#each { ... }`) does not accidentally bind through the no-block overload (`Array#each() -> Enumerator`).
- It MUST consult the same shape/generic-substitution machinery that `RbsDispatch.try_dispatch` uses, so generic block parameters resolve through the receiver's `type_args` (a `Tuple[Constant[1], Constant[2]]` receiver makes `Array#each`'s `Elem` block parameter resolve to `Constant[1] | Constant[2]`).
- It MUST return an empty array when the environment, RBS loader, receiver descriptor, method definition, selected overload, or block clause is missing or untyped. The binder MUST treat the empty array as "no information" and default every parameter to `Dynamic[Top]`.
- For `Union` receivers it MUST take the per-member answers and return them only when every member yields the structurally equal block parameter list; otherwise it MUST return the empty array. Mixed-arity unions therefore degrade to `Dynamic[Top]` rather than producing a non-deterministic block binding.
- It MUST NOT raise on any well-formed input. Defensive `rescue StandardError` around RBS' `DefinitionBuilder` is permitted to keep the probe fail-soft.

`Rigor::Inference::StatementEvaluator` MUST consume both surfaces through a `Prism::CallNode` handler:

- The handler MUST evaluate the call expression as a pure value (delegating to `Scope#type_of` so the existing dispatch chain and shape tier still apply) and MUST return the receiver scope unchanged. Block effects MUST NOT leak into the post-call scope; locals bound exclusively inside a block MUST NOT be observable on the outer side of the call.
- When `node.block` is a `Prism::BlockNode`, the handler MUST build the block's entry scope by augmenting the *receiver's outer scope* with the bindings produced by `BlockParameterBinder.bind`. The block body inherits the outer scope's locals (Ruby's lexical scoping rule), with the block parameters layered on top.
- The handler MUST `sub_eval` the `BlockNode`, threading the block's entry scope through the body so the per-node scope index sees the parameter bindings. The block's `Prism::BlockNode` MUST itself have a handler that delegates to `sub_eval(body, scope)` so the body's statement chain is visited under the augmented scope.
- The handler's exception envelope MUST treat a probe failure as "no expected types"; the binder still runs and defaults every parameter to `Dynamic[Top]`.
- Block-aware result typing (Slice 6 phase C sub-phase 2) lives in `Rigor::Inference::ExpressionTyper#call_type_for`: when the call carries a `Prism::BlockNode`, the typer MUST build the same block-entry scope (`outer-scope + BlockParameterBinder.bind`), type the block's body under that scope, and pass the body's value type as `block_type:` into `MethodDispatcher.dispatch`. This is the exact mechanism that makes `[1, 2, 3].map { |n| n.to_s }` resolve to `Array[String]` from any call site (CLI `type-of`, ScopeIndexer, plain `Scope#type_of`) without requiring the StatementEvaluator to be in the loop. The StatementEvaluator's CallNode handler MUST stay aligned: it delegates to the same `Scope#type_of` for the result type and only re-evaluates the block body for the per-node scope index.

### Boundaries

Slice 3 phase 2 does NOT thread scope through the *interior* of arbitrary expressions: `foo(x = 1)` and `[1, x = 2]` do not propagate `x` to the post-scope, because the recursive descent stops at expression-level children that the evaluator's catalogue does not cover. This is a deliberate Phase 2 simplification; later slices may expand the catalogue to thread scope through call arguments and array/hash elements. Statement-y constructs at the top level (assignments, ifs, cases, begins, loops, parens) propagate as specified above.

Slice 3 phase 2 narrowly limits the *expressivity* of the parameter binding too: the binder picks the union across overloads at each slot, but does NOT yet refine the binding by argument-call-site type the way `MethodDispatcher::OverloadSelector` does for return types. RBS interface types (`int`, `_ToS`, ...) and aliases still degrade to `Dynamic[Top]` through the existing `RbsTypeTranslator` translator, so `def first(n)` redefinitions where the only overload's parameter is `int` MUST observably bind `n` to `Dynamic[Top]`. This matches the existing translator's gradual-typing posture.

## Narrowing (Slice 6 phases 1 and 2)

Slice 6 phase 1 adds the first edge-aware refinement surface to the engine. It is exposed through `Rigor::Inference::Narrowing`, a pure module consumed by `Rigor::Inference::StatementEvaluator` to refine the `then` and `else` scopes of `Prism::IfNode`/`Prism::UnlessNode` (and the RHS-entry scope of `Prism::AndNode`/`Prism::OrNode`). Slice 6 phase 2 extends the catalogue with class-membership predicates (`is_a?`, `kind_of?`, `instance_of?`) and trusted equality/inequality predicates while keeping the same consumption contract.

### Type-level narrowing primitives

The module MUST expose the following module functions, each producing a fresh `Rigor::Type` value and never mutating its input:

- `Narrowing.narrow_truthy(type)` — the truthy fragment of `type`. `Constant[v]` collapses to `Bot` when `v` is `nil` or `false` and is preserved otherwise; `Nominal[NilClass]`/`Nominal[FalseClass]` collapse to `Bot` and other `Nominal` carriers are preserved; `Union` recurses element-wise; `Top`, `Dynamic[T]`, `Bot`, `Singleton`, `Tuple`, and `HashShape` flow through unchanged.
- `Narrowing.narrow_falsey(type)` — the falsey fragment of `type`. `Constant[nil]`/`Constant[false]` and `Nominal[NilClass]`/`Nominal[FalseClass]` are preserved; other `Constant`/`Nominal` carriers collapse to `Bot`; `Union` recurses element-wise; `Singleton`/`Tuple`/`HashShape` collapse to `Bot` (their inhabitants are truthy); `Top`/`Dynamic[T]`/`Bot` flow through unchanged because the analyzer cannot prove the falsey side empty.
- `Narrowing.narrow_nil(type)` — the nil fragment of `type`. `Constant[nil]` and `Nominal[NilClass]` are preserved; non-nil `Constant`/`Nominal` carriers collapse to `Bot`; `Union` recurses element-wise; `Top`/`Dynamic[T]` MUST narrow to the canonical `Constant[nil]` so downstream dispatch resolves through `NilClass`; carriers that never inhabit nil (`Singleton`, `Tuple`, `HashShape`) collapse to `Bot`; `Bot` is its own nil fragment.
- `Narrowing.narrow_non_nil(type)` — the non-nil fragment of `type`. Mirror of `narrow_nil`: nil-only carriers collapse to `Bot` and non-nil carriers are preserved; `Top`/`Dynamic[T]`/`Singleton`/`Tuple`/`HashShape` flow through unchanged; `Union` recurses element-wise.
- `Narrowing.narrow_equal(type, literal)` (Slice 6 phase 2 sub-phase 2) — the equality fragment of `type` against a trusted `Type::Constant` literal. String, Symbol, and Integer literals MUST narrow only when `type` is already a finite trusted literal domain (`Constant` or a `Union` of trusted constants). Nil, true, and false are singleton values and MAY be extracted from mixed domains such as `Integer | nil`, but MUST NOT narrow `Dynamic[Top]` into the compared literal. Float literals MUST NOT narrow. Untrusted inputs return `type` unchanged.
- `Narrowing.narrow_not_equal(type, literal)` (Slice 6 phase 2 sub-phase 2) — the domain-relative complement of `narrow_equal`. It removes the compared literal from finite trusted literal domains and removes nil/true/false singleton members from mixed domains when present. It MUST NOT create an unbounded difference type for broad domains such as `String` or `Dynamic[Top]`.
- `Narrowing.narrow_class(type, class_name, exact: false, environment: Environment.default)` (Slice 6 phase 2 sub-phase 1) — the class-membership fragment of `type`. The `class_name` argument is the qualified name of the asked class as it appears in source (`"Integer"`, `"Foo::Bar"`); `exact: false` models `is_a?`/`kind_of?` (subclass-inclusive) and `exact: true` models `instance_of?` (exact). The carrier rules MUST be:
  - `Constant[v]` — preserved when `v.class` satisfies the predicate (subclass-or-equal of the asked class under `exact: false`; equal under `exact: true`); collapses to `Bot` otherwise.
  - `Nominal[C]` — when the bound `C` is the same as the asked class (or already its subclass under `exact: false`) it is preserved. When the asked class is a subclass of `C` under `exact: false` the type narrows DOWN to `Nominal[asked]` (e.g., `Nominal[Numeric]` under `is_a?(Integer)` becomes `Nominal[Integer]`). Disjoint hierarchies under `exact: false` and any non-equal class under `exact: true` collapse to `Bot`. When either class name does not resolve through the supplied analyzer `Environment`, the result MUST stay conservative and preserve the input type.
  - `Union` — recurses element-wise, dropping disjoint members.
  - `Tuple[*]`/`HashShape{*}` — projected uniformly through `"Array"`/`"Hash"` against the asked class.
  - `Singleton[C]` — projected uniformly through `"Class"` against the asked class (the inhabitants are class objects).
  - `Top`/`Dynamic[T]` — narrow to `Nominal[asked]` so downstream dispatch can resolve through the asked class.
  - `Bot` — preserved.
- `Narrowing.narrow_not_class(type, class_name, exact: false, environment: Environment.default)` (Slice 6 phase 2 sub-phase 1) — the falsey fragment of the same predicate. `Constant`/`Nominal`/`Union`/`Tuple`/`HashShape`/`Singleton` carriers that DO satisfy the predicate collapse to `Bot`; carriers that do NOT satisfy it are preserved unchanged (for `Nominal` this means `Nominal[Numeric]` under `!is_a?(Integer)` stays `Nominal[Numeric]`, since the analyzer cannot prove the disjunction without a richer carrier). `Top`/`Dynamic[T]`/`Bot` flow through unchanged.

These primitives MUST be deterministic and structurally pure: two calls with structurally-equal inputs produce structurally-equal outputs, and calling them never alters the input.

### Predicate-level narrowing

`Narrowing.predicate_scopes(node, scope)` MUST return an `[truthy_scope, falsey_scope]` pair. When `node` is `nil` or its shape is not in the recognised catalogue the pair MUST be `[scope, scope]` so the caller observes "no narrowing" without a special return value. The recognised Slice 6 phase 1 catalogue is:

- `Prism::ParenthesesNode` — recurse into the body when present.
- `Prism::StatementsNode` — analyse the last statement; earlier statements MAY have scope effects, but the StatementEvaluator has already produced the post-predicate scope before calling `Narrowing`, so the analyser does NOT thread additional effects.
- `Prism::LocalVariableReadNode` — when the local is bound in `scope`, narrow truthy → `narrow_truthy(local)` and falsey → `narrow_falsey(local)`. Unbound locals fall through to the no-narrowing fallback.
- `Prism::CallNode` — the catalogue covers four predicate shapes, all rejected silently when the call has a block or its receiver is `nil`:
  - `recv.nil?` (no positional/keyword argument): narrow the receiver-local through `narrow_nil`/`narrow_non_nil`.
  - unary `!recv` (`name == :!`, no positional/keyword argument): analyse `recv` and swap the resulting pair.
  - `recv.is_a?(C)` / `recv.kind_of?(C)` / `recv.instance_of?(C)` (Slice 6 phase 2 sub-phase 1): require the receiver to be a `Prism::LocalVariableReadNode` and the single argument to be a static constant reference (`Prism::ConstantReadNode` or `Prism::ConstantPathNode`). The qualified name MUST be rendered via the parent-walk `Foo::Bar` form. The truthy edge rebinds the local through `narrow_class(local, class_name, exact:, environment: scope.environment)` (`exact: true` only for `instance_of?`); the falsey edge rebinds through `narrow_not_class(local, class_name, exact:, environment: scope.environment)`. Anything else (a local-only argument, a method-call argument, multiple arguments) MUST fall through to the no-narrowing branch.
  - `local == literal` / `literal == local` and the `!=` mirror (Slice 6 phase 2 sub-phase 2): require one side to be a `Prism::LocalVariableReadNode` and the other side to be a static trusted literal (`String`, `Symbol`, `Integer`, `true`, `false`, or `nil`; not `Float`). The truthy edge of `==` rebinds the local through `narrow_equal`; the falsey edge rebinds through `narrow_not_equal`. `!=` swaps those edges. Each recognised equality predicate MUST also attach a `FactStore::Fact`: use the `local_binding` bucket when the local type changed, otherwise the `relational` bucket so broad or dynamic domains retain the relation without unsound positive narrowing.
- `Prism::AndNode` — `a && b` narrows the truthy edge with `b`'s truthy scope under `a`'s truthy scope; the falsey edge unions `a`'s falsey scope (b skipped) and `b`'s falsey scope (b ran but returned falsey) via `Scope#join`.
- `Prism::OrNode` — `a || b` narrows the truthy edge with `Scope#join` of `a`'s truthy scope and `b`'s truthy scope (under `a`'s falsey scope); the falsey edge is `b`'s falsey scope under `a`'s falsey scope.

The analyser MUST NOT raise on unrecognised predicate shapes, MUST NOT thread any tracer (predicate analysis is a pure query that consults already-typed scope information), and MUST NOT mutate the receiver scope.

### StatementEvaluator integration

`Rigor::Inference::StatementEvaluator` MUST consume the predicate analyser as follows:

- `Prism::IfNode` — after evaluating the predicate to obtain `post_pred`, call `Narrowing.predicate_scopes(node.predicate, post_pred)` to derive `(truthy_scope, falsey_scope)`. The `then` branch MUST be evaluated under `truthy_scope`; the `else` branch (or an absent else, which contributes `Constant[nil]` and the predicate's post-scope) MUST be evaluated under `falsey_scope`. The branch types are unioned and the post-scopes are merged through the existing nil-injection rule.
- `Prism::UnlessNode` — same shape as `IfNode`, but the `then` branch (which runs when the predicate is falsey) MUST be evaluated under `falsey_scope` and the `else` branch under `truthy_scope`.
- `Prism::AndNode`/`Prism::OrNode` — after evaluating the LHS to obtain `left_scope`, call `Narrowing.predicate_scopes(node.left, left_scope)`. The RHS MUST be evaluated under the LHS's truthy scope for `&&` and the LHS's falsey scope for `||`. The post-scope MUST still be the join-with-nil-injection of `left_scope` and the RHS's post-scope (modelling "RHS sometimes ran") so half-bound names from the RHS continue to nil-inject. The result type MUST be `union(narrow_falsey(left_type), right_type)` for `&&` and `union(narrow_truthy(left_type), right_type)` for `||`.

### Boundaries

Slice 6 phase 1 + phase 2 binds local-variable narrowing for truthiness, `nil?`, class-membership predicates, and trusted equality/inequality predicates. The following surfaces are deliberately deferred to a follow-up:

- Equality narrowing is intentionally narrow: it does not promote user-defined equality, `eql?`, `===`, Float literals, broad `String`/`Symbol`/`Integer` domains, or `Dynamic[Top]` into precise literal domains. Those comparisons may carry relational facts, but value narrowing waits for RBS/plugin-declared effects.
- Closure-captured locals are treated as ordinary locals at narrowing time. Slice 6 phase C sub-phase 3a introduces `Rigor::Inference::ClosureEscapeAnalyzer.classify(receiver_type:, method_name:, environment:)`, a pure query that returns `:non_escaping`, `:escaping`, or `:unknown` for a block-accepting call. Sub-phase 3a is RBS-blind: the analyzer ships a hardcoded catalogue covering core iteration methods (`Array`/`Hash`/`Range`/`Set`/`Enumerator`/`Enumerator::Lazy` Enumerable methods, `Hash#each_pair`/`each_key`/`each_value`/`transform_keys`/`transform_values`, `Range#step`, `Integer#times`/`upto`/`downto`, `Object#tap`/`then`/`yield_self`) as `:non_escaping` and a small set of known retainers (`Module#define_method`, `Class#define_method`, `Thread.new`/`start`/`fork`, `Fiber.new`, `Proc.new`) as `:escaping`. `Tuple` receivers project to `Array`, `HashShape` to `Hash`, and `Constant[v]` projects through the value's class. `Top`, `Dynamic[T]`, `Union`, and any uncatalogued `(class, method)` pair return `:unknown`. The analyzer MUST NOT mutate scope or raise on unrecognised inputs; consumers MUST treat `:unknown` as conservatively as `:escaping` for fact retention. The analyzer is a pure query in sub-phase 3a.
- Slice 6 phase C sub-phase 3b wires `ClosureEscapeAnalyzer` into `StatementEvaluator#eval_call`. When a `Prism::CallNode` carries a `Prism::BlockNode` and the analyzer classifies the call as `:escaping` or `:unknown`, the evaluator MUST attach a `FactStore::Fact` to the post-call scope with `bucket: :dynamic_origin`, `predicate: :closure_escape`, `target: Target.new(kind: :closure, name: <method symbol>)`, `payload: { method_name:, classification: }`, and `stability: :unstable`. A `:non_escaping` classification (or any block-less call) MUST leave the post-call `Scope#fact_store` unchanged. Sub-phase 3c additionally drops the narrowed type of every captured outer local that the block body can rebind, replacing it with `Dynamic[Top]` through `Scope#with_local` (which also invalidates the local's `local_binding` facts). The "captured outer local" set is computed by walking `BlockNode#body` for `Prism::LocalVariableWriteNode`s whose name (a) appears in `Scope#locals` of the call-site scope and (b) is NOT introduced by the block itself (block parameters from `BlockParameterBinder.bind`, plus the `;`-prefixed block-locals on `BlockParametersNode#locals`). Locals the block only reads MUST stay narrowed; writes to a name shadowed by a block parameter MUST NOT count. The conservative drop replaces the type with `Dynamic[Top]`; a future sub-phase MAY refine this to the union of the block's actual writes once block-body effect tracking is available.
- Instance-, class-, and global-variable narrowing remains out of scope; only `Prism::LocalVariableReadNode` is recognised by the analyser today.

These boundaries MUST NOT silently degrade Slice 6 phase 1 callers: predicates that fall outside the recognised catalogue MUST observe the entry scope on both edges, preserving the Slice 3 phase 2 behaviour.

## Environment Surface

`Rigor::Environment` is the engine's view of the type universe outside the current scope: nominal classes, RBS definitions, plugin-supplied facts (Slice 6+), and any other module-level information. The minimum public surface that Slice 1 binds is:

- `Rigor::Environment#class_registry` — returns a `Rigor::Environment::ClassRegistry` that can resolve a Ruby `Class` or `Module` object to a `Rigor::Type::Nominal`.
- `Rigor::Environment::ClassRegistry#nominal_for(class_object)` — returns the registered `Rigor::Type::Nominal` for a registered class, or raises if the class is not registered.
- `Rigor::Environment::ClassRegistry#registered?(class_object)` — returns `true` or `false` for whether the class is registered.
- `Rigor::Environment::ClassRegistry#nominal_for_name(name)` — returns the registered `Rigor::Type::Nominal` for a Symbol/String class name, or `nil` when the name is unknown.

Slice 4 introduces:

- `Rigor::Environment#rbs_loader` — returns the `Rigor::Environment::RbsLoader` attached to the environment, or `nil` for an "RBS-blind" environment (test fixture).
- `Rigor::Environment::RbsLoader#class_known?(name)` — returns `true` when the RBS environment defines a class or module by that name; nil-safe and string/symbol tolerant.
- `Rigor::Environment#class_ordering(lhs, rhs)` — Slice 6 phase 2 sub-phase 2. Returns `:equal`, `:subclass`, `:superclass`, `:disjoint`, or `:unknown` by consulting the static registry first and then the RBS loader. This is the class-membership narrower's hierarchy oracle; it MUST NOT rely on ad hoc `Object.const_get` at the predicate site.
- `Rigor::Environment::RbsLoader#class_ordering(lhs, rhs)` — returns the same ordering vocabulary by comparing `RBS::Definition#ancestors` for the two names. Unknown or malformed names return `:unknown`.
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
