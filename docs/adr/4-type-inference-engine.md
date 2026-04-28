# ADR-4: Type Inference Engine and the `Scope#type_of` Query

## Status

Draft.

ADR-4 records the design decisions that turn the static type model (ADR-1, ADR-3) into a working inference engine. The central concrete deliverable is the analyzer query that takes a Prism AST node and an immutable `Rigor::Scope`, and returns the `Rigor::Type` the expression is proven to produce at that program point. This is the Ruby/Rigor counterpart of PHPStan's `$scope->getType($node)` and is the query that every CLI rule, plugin, and refactor tool eventually calls.

ADR-4 does **not** redefine semantics — those live in [`docs/type-specification/`](../type-specification/) — and it does **not** redefine the type-object public contract — that lives in [`docs/internal-spec/internal-type-api.md`](../internal-spec/internal-type-api.md). ADR-4 fixes which Ruby modules implement the inference, in which order they land, and the tentative answers to the open questions in ADR-3 that are needed to start writing code.

The normative side of this ADR — the public contract of `Scope#type_of`, fail-soft policy, immutability discipline, and engine loading boundaries — is in [`docs/internal-spec/inference-engine.md`](../internal-spec/inference-engine.md). When this ADR and that document disagree on observable Ruby behavior, the spec binds and this ADR is updated to match.

## Context

Rigor today parses Ruby with Prism and reports parse-time diagnostics through the CLI. There is no type representation, no scope, and no inference. ADR-1 fixes the type-model semantics, ADR-3 fixes the type-object representation, and the two `docs/internal-spec/` documents fix the engine surface and the type-object public contract. The remaining decision is *how the analyzer turns AST into Type*, in what order, and with which seams.

PHPStan's `$scope->getType($node)` is the canonical reference. It is a pure function from `(Scope, Node)` to `Type` that consults the type-object catalogue, the class registry, the method dispatcher, and the control-flow facts the scope carries. Rigor adopts the same shape with Ruby-idiomatic naming.

## Reference Model: PHPStan `Scope::getType`

The analogous PHPStan surfaces are:

- [`src/Analyser/Scope.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Analyser/Scope.php) — `getType(Expr $node): Type`, immutable scope, structural variable bindings.
- [`src/Analyser/MutatingScope.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Analyser/MutatingScope.php) — the implementation strategy that flows new bindings through return-fresh-scope methods rather than in-place mutation.
- [`src/Analyser/NodeScopeResolver.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Analyser/NodeScopeResolver.php) — the visitor that drives statement-level scope propagation.

Rigor adopts the immutable-scope-plus-pure-typer split. We deliberately do **not** adopt:

- PHP's `parent::` reflection model — Ruby's class layout is different and the registry is RBS-driven.
- PHPStan's deep visitor inheritance — Rigor's typer dispatches on Prism nodes through pattern matching, consistent with the "no inheritance between type classes" rule from ADR-3.

## Tentative Answers to ADR-3 Open Questions

ADR-3 records two open questions whose answers are needed before any inference code can be written. ADR-4 commits **tentative** answers so the first vertical slice can land. The decisions promote to Working Decisions in ADR-3 only after Slice 1 has shipped and the choices have been exercised in real code.

### OQ1: Constant Scalar and Object Shape — tentative answer **Option C (Hybrid)**

A unified `Rigor::Type::Constant` carrier holds scalar literals (`Integer`, `Float`, `String`, `Symbol`, `Rational`, `Complex`, `true`, `false`, `nil`). Compound literal shapes (`Tuple`, `HashShape`, `Record`) get dedicated classes because their inner-type references and shape policies do not compress to a single Ruby value.

Rationale for choosing the hybrid for the slice:

- Scalar carriage stays compact and Ruby-idiomatic; one class covers nine literal kinds without a parallel hierarchy.
- Compound shapes keep the structural inspectability they need anyway.
- Refinement composition (`non-empty-string`, `positive-int`, hash-shape extra-key policy) splits cleanly along the same scalar/compound boundary in [`rigor-extensions.md`](../type-specification/rigor-extensions.md).

Risks (logged for the slice review):

- A literal array `[1, 2, 3]` needs a documented answer — Slice 4 makes it a `Tuple` of `Constant` rather than a constant-array shape carrying raw values, so the `Tuple` class is structural and the `Constant` class is pointwise.
- If refinement projections turn out to need per-class dispatch frequently, we revisit and migrate scalar carriage to per-class (`String::Constant`, `Integer::Constant`, …) before the slice promotes.

### OQ2: Trinary-Returning Predicate Naming — tentative answer **Option A (Drop the `?`)**

Capability and relational queries that return `Rigor::Trinary` use noun/verb names without the `?` suffix:

```ruby
type.string                # Rigor::Trinary
type.integer               # Rigor::Trinary
type.subtype_of(other)     # Rigor::Type::SubtypeResult
type.has_method(name)      # Rigor::Trinary
type.string.yes?           # bool, the only ?-suffixed surface
```

Rationale:

- The return type is encoded in the name shape: `?` MUST mean Boolean throughout Rigor, including `Rigor::Trinary#yes?`/`no?`/`maybe?`.
- Aligns with PHPStan's `isString()` style (which is also not Ruby `?`-style) and with Ruby's expectation that `?`-suffixed methods return `true`/`false`.
- Avoids the ambiguity that Option B would introduce (silently returning a non-boolean from a `?`-suffixed method).

Risks:

- Ruby readers may instinctively type `type.string?` and get a `NoMethodError`. We mitigate this by adding a clear class-level docstring and (in slice 1) a custom `method_missing` that suggests the dropped `?` form.

If Slice 1 review concludes Option C (dual API) is more usable, ADR-3 OQ2 is updated and the `?` sugar is added across the type surface in a single follow-up.

## Virtual Nodes and the Method-Dispatch Boundary

PHPStan exposes one feature that Rigor adopts early: `$scope->getType($node)` accepts both real parser nodes and *synthetic* nodes that embed a `Type` value directly. PHPStan's `TypeExpr` lets callers ask "what would `$scope->getType(new Add(new LNumber(1), new TypeExpr(new IntType())))` infer?" without constructing a fake AST. Plugins use the same shape to simulate refactors, narrow values, and probe method-return rules.

Rigor introduces this in Slice 1 strengthening rather than waiting for Slice 3. The contract lives in [`docs/internal-spec/inference-engine.md`](../internal-spec/inference-engine.md) under *Virtual Nodes*. The minimum shipped surface is `Rigor::AST::Node` (a marker module) and `Rigor::AST::TypeNode`. Additional synthetic kinds (call expressions, container literals, narrowing wrappers) land alongside the slices that actually consume them.

### Rejected option: specialising type classes for operator-method dispatch

A plausible alternative is to specialise `Rigor::Type` for Ruby built-ins that have operator methods — `Rigor::Type::IntegerType` knowing arithmetic, `Rigor::Type::StringType` knowing concatenation, and so on — so that `1 + 2` dispatches by asking the receiver type to evaluate the call. This option is **rejected**. The reasoning:

- It would require either inheritance between type classes (forbidden by ADR-3) or an open-ended duck-type contract on every type form for "evaluate `:+` with these args", which contradicts the thin-value-object rule in [`internal-type-api.md`](../internal-spec/internal-type-api.md).
- PHPStan's own design separates the same concerns. `Type::Type` answers capability and projection queries; method dispatch goes through `MethodReflection` and the `*ReturnTypeExtension` plugin points. Subclasses such as `ConstantStringType extends StringType` exist for *representation* specialisation, not for method-dispatch specialisation.
- The Rigor extension API in ADR-2 expects plugin authors to add or override built-in method behaviour (framework knowledge, gem-specific idioms). Concentrating that surface on type classes makes it harder to extend without subclassing the engine.

The chosen design instead routes method dispatch through `Rigor::Inference::MethodDispatcher` (introduced in Slice 3) with a layered lookup: the RBS environment, then a built-in operator/method table, then ADR-2 plugin extensions. Type classes stay thin, the dispatcher's input is uniform across real and synthetic nodes (via the Virtual Nodes contract above), and operator semantics are pluggable.

## Slice Roadmap

Each slice ships independently, keeps the previous slice green, and can be reverted without taking down the codebase.

### Slice 1 — Literal Typer (this slice)

Public deliverable: `Rigor::Scope#type_of(node)` returns the right type for literal expressions, local-variable reads, and shallow `Array` literals; everything else falls back to `Dynamic[Top]`. Slice 1 strengthening additionally lands the Virtual Nodes infrastructure described above so synthetic typed positions are usable from day one.

Code surface added:

- `Rigor::Trinary` with `yes`/`no`/`maybe` flyweights and `and`/`or`/`negate`.
- `Rigor::Type` documentation-only ducktype module.
- `Rigor::Type::Top`, `Bot`, `Dynamic`, `Nominal`, `Constant`, `Union`.
- `Rigor::Type::Combinator` factory: `union`, `dynamic`, `nominal_of`, `constant_of`.
- `Rigor::Environment::ClassRegistry` with hardcoded entries for `Integer`, `Float`, `String`, `Symbol`, `NilClass`, `TrueClass`, `FalseClass`, `Object`, `BasicObject`.
- `Rigor::Environment` public entry that wraps the registry (RBS loader is added in Slice 3).
- `Rigor::Scope.empty(environment:)`, `#with_local`, `#local`, `#type_of`.
- `Rigor::Inference::ExpressionTyper#type_of(node, scope)` for the supported nodes.
- `Rigor::AST::Node` marker module and `Rigor::AST::TypeNode` synthetic node, dispatched alongside Prism nodes by the typer.
- `Rigor::Inference::Fallback` value object and `Rigor::Inference::FallbackTracer` observer, threaded through `Scope#type_of(node, tracer: ...)`. Records every fail-soft fallback so coverage regressions are observable from Slice 1 onward; later slices add `record_dispatch_miss`, `record_budget_cutoff`, etc. on the same tracer.
- `Rigor::Source::NodeLocator` (under a new `Rigor::Source` namespace for source-text and AST positioning utilities) maps `(source, line, column)` or a byte offset to the deepest enclosing Prism node, and `Rigor::Source::NodeWalker` yields every Prism node in DFS pre-order.
- `Rigor::Inference::CoverageScanner` runs `Scope#type_of` over every walked node with a fresh `FallbackTracer`, classifying nodes as **directly unrecognized** when the first recorded event's `node_class` matches the visited node's class. This avoids double-counting pass-through wrappers (`ProgramNode`, `StatementsNode`, `ParenthesesNode`).
- A `rigor type-of FILE:LINE:COL` CLI subcommand wraps the locator and `Scope#type_of`. It prints the inferred type and RBS erasure (text or `--format=json`); `--trace` attaches a `FallbackTracer` and reports the recorded events. This is the first dogfood loop for the engine surface and the primary tool for inspecting fail-soft coverage on a single position.
- A `rigor type-scan PATH...` CLI subcommand wraps `CoverageScanner` for whole files and directories, aggregating per-class visit/unrecognized counts and surfacing a sample of fallback sites. `--threshold=RATIO` makes it CI-actionable: the command exits non-zero when the unrecognized ratio crosses the threshold, so coverage regressions break the build before they reach `rigor check`.

Prism nodes recognised in Slice 1:

`IntegerNode`, `FloatNode`, `StringNode`, `SymbolNode`, `TrueNode`, `FalseNode`, `NilNode`, `LocalVariableReadNode`, `LocalVariableWriteNode`, `LocalVariableTargetNode`, `ArrayNode` (shallow, requires no narrowing).

All other nodes return `Dynamic[Top]` from `type_of`. The contract for the fail-soft path is normative in [`docs/internal-spec/inference-engine.md`](../internal-spec/inference-engine.md).

### Slice 2 — Locals, Joins, and Statements

Adds:

- `BeginNode` / sequenced statements via an `Inference::StatementEvaluator#evaluate(node, scope) -> [Type, Scope']`.
- `IfNode`, `UnlessNode` — both branches typed and Scope-joined; **no narrowing yet**.
- `Rigor::Scope#join(other)` routed through `Type::Combinator.union`.

### Slice 3 — Method Dispatch (RBS-backed)

Adds:

- `Rigor::Environment::RbsLoader` wrapping the `rbs` gem.
- `Rigor::Type::SubtypeResult`, `AcceptsResult`.
- `Rigor::Inference::MethodDispatcher` consulting RBS definitions.
- `CallNode` recognised by `ExpressionTyper`.
- Argument acceptance via `accepts(other, mode:)`; failure paths still fail-soft to `Dynamic[Top]` so the slice does not block on diagnostic plumbing.

### Slice 4 — Shape Inference

Adds `Tuple`, `HashShape`, `Record`, the `ArrayNode → Tuple` upgrade when all elements are finite, and `HashNode` typing. Implements `erase_to_rbs` for hash shapes per [`rbs-erasure.md`](../type-specification/rbs-erasure.md).

### Slice 5 — Narrowing (Minimal CFA)

Adds `Rigor::Analysis::FactStore` (value facts and nil facts only), edge-aware truthy/falsey narrowing on `IfNode`, and the conventional narrowing predicates (`nil?`, `kind_of?`, `is_a?`, literal `==`).

### Slice 6 — Refinements (Minimal)

Adds `Rigor::Type::RefinedNominal` with `non-empty-string` and `positive-int` from [`imported-built-in-types.md`](../type-specification/imported-built-in-types.md).

## Module Sketch (post-Slice 1)

```
lib/rigor/
├─ trinary.rb
├─ type.rb                         # ducktype module
├─ type/
│  ├─ top.rb
│  ├─ bot.rb
│  ├─ dynamic.rb
│  ├─ nominal.rb
│  ├─ constant.rb
│  ├─ union.rb
│  └─ combinator.rb                # factory
├─ environment.rb                  # public entry
├─ environment/
│  └─ class_registry.rb            # Slice 1 hardcoded built-ins
├─ scope.rb                        # public Scope#type_of
└─ inference/
   └─ expression_typer.rb          # AST → Type
```

Slice 3 adds `lib/rigor/environment/rbs_loader.rb` and `lib/rigor/inference/method_dispatcher.rb`. Slice 5 adds `lib/rigor/analysis/fact_store.rb`. The `lib/rigor/analysis/` directory keeps holding diagnostic and runner code; the inference engine is a separate concern under `lib/rigor/inference/`.

## Public API (post-Slice 1)

```ruby
class Rigor::Scope
  def self.empty(environment:)
  def with_local(name, type)
  def local(name)            # Rigor::Type or nil
  def type_of(node)          # Rigor::Type
  def environment
end

module Rigor::Type::Combinator
  def self.union(*types)
  def self.dynamic(static_facet)
  def self.nominal_of(class_object)
  def self.constant_of(value)
end
```

The Slice 1 surface is consistent with the method-surface contract in [`internal-type-api.md`](../internal-spec/internal-type-api.md). Subsequent slices add to `Rigor::Type::Combinator` and to `Rigor::Inference::*` without changing `Scope#type_of`'s shape.

## Risks and Mitigations

- **Tentative OQ answers may flip later.** Production code paths route through `Type::Combinator`; direct type-class constructors are an internal-only escape hatch. CI lint guards `?`-suffixed methods against returning `Trinary`. Capability predicates added in Slice 1 are minimal so a rename is mechanical.
- **Prism API evolution.** The typer uses Ruby's pattern-matching (`case node in Prism::IntegerNode`) rather than visitor inheritance, so we do not extend Prism class hierarchies. Future Prism releases break the typer in a localised way.
- **RBS environment startup cost.** RBS loading is deferred to Slice 3; Slice 1 ships with a hardcoded registry. The Slice 3 loader is wrapped to allow caching across runs and tests.
- **Fail-soft `Dynamic[Top]` masking regressions.** From Slice 1 onward, the typer optionally records a `Diagnostic::Trace` when it falls back to `Dynamic[Top]`. The trace is opt-in to avoid noise, but is plumbed so later slices can detect coverage regressions.
- **Scope ergonomics.** Returning `[Type, Scope']` from `evaluate(node, scope)` (Slice 2) is verbose. We accept the verbosity in exchange for explicit immutability. Helper builders (`scope.evaluate(node) { |type| ... }`) MAY be added once two or three call sites exist.

## References

- [`docs/adr/1-types.md`](1-types.md) — type-model semantics.
- [`docs/adr/2-extension-api.md`](2-extension-api.md) — extension surface that consumes type values.
- [`docs/adr/3-type-representation.md`](3-type-representation.md) — type-object representation and OQ1/OQ2 rationale.
- [`docs/internal-spec/internal-type-api.md`](../internal-spec/internal-type-api.md) — type-object public contract.
- [`docs/internal-spec/implementation-expectations.md`](../internal-spec/implementation-expectations.md) — engine-surface contract.
- [`docs/internal-spec/inference-engine.md`](../internal-spec/inference-engine.md) — `Scope#type_of` public contract.
- [`docs/type-specification/relations-and-certainty.md`](../type-specification/relations-and-certainty.md) — subtyping, gradual consistency, trinary semantics.
- [`docs/type-specification/value-lattice.md`](../type-specification/value-lattice.md) — `Dynamic[T]` algebra.
- [`docs/type-specification/normalization.md`](../type-specification/normalization.md) — deterministic normalization rules.
- [`docs/type-specification/control-flow-analysis.md`](../type-specification/control-flow-analysis.md) — Scope/CFA target for Slice 5.

External (PHPStan source code, not part of Rigor's submodules):

- [`phpstan/phpstan-src` `src/Analyser/Scope.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Analyser/Scope.php).
- [`phpstan/phpstan-src` `src/Analyser/MutatingScope.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Analyser/MutatingScope.php).
- [`phpstan/phpstan-src` `src/Analyser/NodeScopeResolver.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Analyser/NodeScopeResolver.php).
