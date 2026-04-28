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

- A literal array `[1, 2, 3]` needs a documented answer — Slice 5 makes it a `Tuple` of `Constant` rather than a constant-array shape carrying raw values, so the `Tuple` class is structural and the `Constant` class is pointwise.
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

Rigor introduces this in Slice 1 strengthening rather than waiting for the dispatcher slices. The contract lives in [`docs/internal-spec/inference-engine.md`](../internal-spec/inference-engine.md) under *Virtual Nodes*. The minimum shipped surface is `Rigor::AST::Node` (a marker module) and `Rigor::AST::TypeNode`. Additional synthetic kinds (call expressions, container literals, narrowing wrappers) land alongside the slices that actually consume them.

### Rejected option: specialising type classes for operator-method dispatch

A plausible alternative is to specialise `Rigor::Type` for Ruby built-ins that have operator methods — `Rigor::Type::IntegerType` knowing arithmetic, `Rigor::Type::StringType` knowing concatenation, and so on — so that `1 + 2` dispatches by asking the receiver type to evaluate the call. This option is **rejected**. The reasoning:

- It would require either inheritance between type classes (forbidden by ADR-3) or an open-ended duck-type contract on every type form for "evaluate `:+` with these args", which contradicts the thin-value-object rule in [`internal-type-api.md`](../internal-spec/internal-type-api.md).
- PHPStan's own design separates the same concerns. `Type::Type` answers capability and projection queries; method dispatch goes through `MethodReflection` and the `*ReturnTypeExtension` plugin points. Subclasses such as `ConstantStringType extends StringType` exist for *representation* specialisation, not for method-dispatch specialisation.
- The Rigor extension API in ADR-2 expects plugin authors to add or override built-in method behaviour (framework knowledge, gem-specific idioms). Concentrating that surface on type classes makes it harder to extend without subclassing the engine.

The chosen design instead routes method dispatch through `Rigor::Inference::MethodDispatcher` (introduced as a constant-folding stub in Slice 2 and extended with RBS lookups in Slice 4) with a layered lookup: the constant-folding rule book, then the RBS environment, then a built-in operator/method table, then ADR-2 plugin extensions. Type classes stay thin, the dispatcher's input is uniform across real and synthetic nodes (via the Virtual Nodes contract above), and operator semantics are pluggable.

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
- `Rigor::Environment` public entry that wraps the registry (RBS loader is added in Slice 4).
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

### Slice 2 — Method Dispatch (constant-folding stub)

The roadmap originally placed `Locals, Joins, and Statements` here and `Method Dispatch (RBS-backed)` after it. The order was reshuffled when the `rigor type-scan lib` dogfood loop landed: roughly 28 % of all unrecognised expressions in this very codebase were `Prism::CallNode` and `Prism::ArgumentsNode`, dwarfing the value-add of any other Slice 2 candidate. Locals/joins still ship next, just as Slice 3.

Adds:

- `Rigor::Inference::MethodDispatcher` (entry module) and `Rigor::Inference::MethodDispatcher::ConstantFolding` (rule book) with `dispatch(receiver_type:, method_name:, arg_types:, block_type:)`. The dispatcher returns a `Rigor::Type` when it can fold the call and `nil` for "no rule" so the typer owns the fail-soft fallback.
- Constant-folding rule book covering binary numeric (`+ - * / % < <= > >= == != <=>`), string (`+ * == != < <= > >= <=>`, with a `STRING_FOLD_BYTE_LIMIT` cap to avoid run-away outputs), symbol (`== != <=> < <= > >=`), boolean (`& | ^ == !=`) and nil (`==, !=`) operators on `Rigor::Type::Constant` receivers with `Constant` arguments. Anything outside the whitelist returns `nil`; runtime exceptions during folding are rescued and downgraded to `nil` as well.
- `ExpressionTyper` recognises `Prism::CallNode` (routes through the dispatcher; falls back to `Dynamic[Top]` for any miss) and `Prism::ArgumentsNode` (treated as a non-value position so the coverage scanner stops flagging it; the CallNode handler reads its children directly).
- `ExpressionTyper#type_of` is rewritten as a `PRISM_DISPATCH` hash so the recognised-node catalogue can grow in future slices without re-tripping cyclomatic-complexity budgets.
- **Strengthening round** broadens the catalogue past arithmetic. The dispatch hash now also covers:
  - `Prism::ConstantReadNode` and `Prism::ConstantPathNode` resolved via `Rigor::Environment::ClassRegistry#nominal_for_name`. The registry's hardcoded list grows from the Slice-1 nine to ~35 core classes (`Array`, `Hash`, `Range`, `Regexp`, `Proc`, `Method`, `Module`, `Class`, `Numeric`, `Comparable`, `Enumerable`, the standard `Exception` lattice, plus `IO`, `File`, `Dir`, `Encoding`); unregistered names still fail soft to `Dynamic[Top]` and emit a fallback event.
  - Container literals: `Prism::HashNode`/`Prism::KeywordHashNode` as `Nominal[Hash]`, `Prism::InterpolatedStringNode` as `Nominal[String]`, `Prism::InterpolatedSymbolNode` as `Nominal[Symbol]`, `Prism::EmbeddedStatementsNode` propagating its body type.
  - Definition expressions: `Prism::DefNode` as `Constant[:method_name]`, `Prism::ClassNode`/`Prism::ModuleNode`/`Prism::SingletonClassNode` propagating their body type (or `Constant[nil]` when empty), `Prism::AliasMethodNode`/`Prism::AliasGlobalVariableNode`/`Prism::UndefNode` as `Constant[nil]`.
  - Variable assignments share a single `type_of_assignment_write` handler that types every `*WriteNode` (constant / instance / class / global / local, plus the `*OperatorWriteNode`, `*OrWriteNode`, `*AndWriteNode`, `IndexOperatorWriteNode`/`IndexOrWriteNode`/`IndexAndWriteNode`, and `MultiWriteNode` flavours) as the type of their `.value` rvalue.
  - "I acknowledge but do not narrow yet" positions are silently typed as `Dynamic[Top]` (no fallback event): `Prism::SelfNode`, the read-side `*VariableReadNode` family, `Prism::BlockNode`, `Prism::ForwardingSuperNode`, plus the genuinely non-value positions (`ArgumentsNode`, `ParametersNode` and every parameter sub-kind, `BlockParametersNode`, `BlockArgumentNode`, `AssocNode`, `AssocSplatNode`, `SplatNode`, `LocalVariableTargetNode`, `EmbeddedVariableNode`, `ImplicitRestNode`, `ForwardingParameterNode`, `NoKeywordsParameterNode`).
- Coverage uplift on `rigor type-scan lib`: from 48.0 % unrecognised after the constant-folding stub down to **26.1 %**. The remaining unrecognised mass is dominated by the Slice 3 control-flow nodes (`IfNode`, `UnlessNode`, `WhenNode`, `ElseNode`, `CaseNode`, `AndNode`, `OrNode`, `BeginNode`, `RescueNode`, `ReturnNode`, `BreakNode`, `NextNode`, `YieldNode`) and by user-defined constants/calls that wait on Slice 4's RBS-backed dispatcher.

### Slice 3 — Locals, Joins, and Statements

Slice 3 lands in two phases.

**Phase 1 (this slice ships first):** every control-flow expression is typed via `ExpressionTyper` in the receiver scope, so no node class in this family stays unrecognised. Both branches of `IfNode`/`UnlessNode`, every `WhenNode`/`InNode` body of `CaseNode`/`CaseMatchNode`, and the body / rescue chain / else clause of `BeginNode` are typed and unioned. `AndNode`/`OrNode` union their operands (no truthy/falsy narrowing yet, that lands in Slice 6). `RescueModifierNode` (`expr rescue fallback`) is the same union. `WhileNode`/`UntilNode` type as `Constant[nil]`. `ReturnNode`/`BreakNode`/`NextNode`/`RetryNode`/`RedoNode` type as `Bot`, which absorbs cleanly under union so a jumping branch is silently dropped from the surrounding control-flow's value (`if c; return; else; 7; end` correctly types as `Constant[7]`). `YieldNode`/`SuperNode`/`ForNode`/`DefinedNode`/`MatchPredicateNode`/`MatchRequiredNode`/`MatchWriteNode` are silently typed as `Dynamic[Top]` until later slices add their semantics. `LambdaNode`/`RangeNode`/`RegularExpressionNode`/`InterpolatedRegularExpressionNode` round out the literal carriers as `Nominal[Proc]`/`Nominal[Range]`/`Nominal[Regexp]`. `Rigor::Scope#join(other)` ships now as the structural-union join used by Phase 2; it intersects the bound names and runs each pair through `Type::Combinator.union`.

**Phase 2 (this sub-phase ships with this commit) — StatementEvaluator (locals propagate across statements).** Introduces `Rigor::Inference::StatementEvaluator#evaluate(node) -> [Rigor::Type, Rigor::Scope]` and threads `Scope#join` through every statement-level construct so locals bound on one branch flow to a unioned binding after the merge point. The class is the Ruby-side complement of the (still pure) `Scope#type_of`: every public call returns a fresh `[type, scope']` pair without mutating the receiver scope. Components added or extended:

1. `Rigor::Inference::StatementEvaluator` is the new entry point. Construction takes the entry `scope:` plus an optional `tracer:`; `evaluate(node)` dispatches on a frozen `HANDLERS = { Prism::*Node => :handler_method }` table and falls back to `[scope.type_of(node, tracer:), scope]` for nodes the catalogue does not specialise (so unrecognised statement-y nodes MUST NOT raise — the Slice 1 fail-soft policy stays intact at the statement level too).
2. The Slice 3 phase 2 catalogue is `StatementsNode`/`ProgramNode` (sequential threading), `LocalVariableWriteNode` (binds the rvalue's type via `Scope#with_local`), `IfNode`/`UnlessNode`/`ElseNode` (predicate then branch+merge), `CaseNode`/`CaseMatchNode`/`WhenNode`/`InNode` (N-ary branch+merge), `BeginNode`/`RescueNode`/`EnsureNode` (body + rescue chain + ensure layered on the joined exit scope), `WhileNode`/`UntilNode` (condition + body, post-scope joins zero-iterations and N-iterations), `AndNode`/`OrNode` (LHS always runs, RHS sometimes runs; result is the union, post-scope is join-with-nil-injection), and `ParenthesesNode` (threads scope through the inner expression so `(x = 1; x + 2)` binds `x` and produces `Constant[3]`).
3. The branch-merge implementation injects `Constant[nil]` for half-bound names before delegating to `Scope#join`. This satisfies the contract that `Scope#join` documents as "the responsibility of the statement-level evaluator": `if cond; x = 1; end; x` now types as `Constant[1] | Constant[nil]`, `case kind; when 1 then x = 1; when 2 then x = 2; y = 9; end` types `x: Constant[1] | Constant[2] | Constant[nil]` and `y: Constant[9] | Constant[nil]`. N-ary merges reduce by repeated pairwise join-with-nil-injection; the reduce order does not affect the result.
4. `Rigor::Scope#evaluate(node, tracer: nil)` ships as the public delegate so callers do not have to instantiate `StatementEvaluator` themselves. The receiver scope is treated as the entry scope; the return value is the same `[type, scope']` pair the evaluator produces.

Concrete uplift: `x = 1; y = x + 2; y` now types as `Constant[3]` with `x: Constant[1]`, `y: Constant[3]` in the post-scope (constant folding flows through bound locals); `xs = [1, 2, 3]; xs.first` types as `Constant[1] | Constant[2] | Constant[3]` (the Slice 5 phase 1 dispatch path resolves through the bound local); `h = {a: 1, b: 2}; h.fetch(:a)` types as `Constant[1] | Constant[2]`.

Boundary: Slice 3 phase 2 does NOT thread scope through arbitrary expression interiors (`foo(x = 1)` and `[1, x = 2]` still drop `x` from the post-scope) and does NOT bind method-definition parameters (a `DefNode` body is opaque to the evaluator). Both are deliberate Phase 2 simplifications; the StatementEvaluator surface above is stable and future commits can grow the catalogue without breaking it.

**CLI integration (this commit also ships):** the CLI commands `rigor type-of` and `rigor type-scan` now consume `Scope#evaluate` indirectly through a new `Rigor::Inference::ScopeIndexer.index(root, default_scope:)` helper. The indexer wires an `on_enter:` callback onto a fresh `StatementEvaluator`, walks the program once, and returns an identity-comparing `Hash{Prism::Node => Rigor::Scope}` whose lookup yields the entry scope visible at every node — propagating the parent's scope down to expression-interior children that the evaluator does not visit. The CLI commands then run `index[node].type_of(node, tracer:)` per probe so locals bound earlier in the file flow into the scope used to type later nodes. The indexer runs its internal evaluator tracer-free; CLI callers attach their tracer only to the post-index `type_of` probe, avoiding double-recorded fallback events.

Adds:

5. `Rigor::Inference::StatementEvaluator#initialize(on_enter:)` keyword (defaults to `nil`). When non-`nil`, the callable is invoked once at the start of every `evaluate(node)` call with `(node, scope)`, and is threaded through every recursive `sub_eval`. The contract is bound in [`docs/internal-spec/inference-engine.md`](../internal-spec/inference-engine.md) under "Statement-Level Evaluation".
6. `Rigor::Inference::ScopeIndexer` module with the `index` factory and the `propagate` DFS walker that fills in scope entries for unvisited expression-interior nodes.
7. `Rigor::CLI::TypeOfCommand` and `Rigor::Inference::CoverageScanner#scan` route their per-node `type_of` calls through the indexer's lookup.

Concrete behavioral uplift (verified through CLI smoke probes):

- `x = 1; y = x + 2; y` typed at line 3 col 1 (the `y` read) returns `Constant[3]`; typed at line 2 col 5 (the `x` read inside the rvalue) returns `Constant[1]`. Pre-integration, both probes returned `Dynamic[Top]`.
- `xs = [1, 2, 3]; result = xs.first; result` typed at line 3 returns `Constant[1] | Constant[2] | Constant[3]` (Tuple-aware dispatch flows through the bound local). Pre-integration, the `result` probe returned `Dynamic[Top]` because `xs` was not visible.

`type-scan lib` coverage moves from 13.71 % to 13.70 % unrecognised — within noise; lib/ is dominated by user-defined `ConstantReadNode`/`ConstantPathNode` references and `CallNode`s against user-typed receivers (whose RBS is not registered) plus method bodies whose locals are method parameters (which the StatementEvaluator does not bind). The integration's value is real and measurable on code with top-level local-variable patterns; the dogfood sample lib/ does not exercise that pattern frequently. The CLI behavioral uplift above is the observable proof; future work that lands per-method scope-building (`DefNode` parameter binding) and per-block scope-building (`BlockNode` parameter binding) is what will move the type-scan needle on this codebase further.

Originally-anticipated coverage uplift on the Slice 3 boundary itself was already realised in Phase 1 (26.1 % → 22.3 % unrecognised); the unrecognised mass after Slice 4 / Slice 5 phase 1 (13.5 %) is dominated by user-defined `ConstantReadNode`/`ConstantPathNode` references and `CallNode`s against user-typed receivers, both of which wait on later RBS-loading and project-aware work rather than on local-variable propagation.

### Slice 4 — Method Dispatch (RBS-backed)

Layers an RBS-backed dispatch tier behind the Slice 2 constant-folding rule book. Slice 4 lands in two phases.

**Phase 1 (this slice ships first):** the engine consults RBS *core* signatures for receiver-class method dispatch and constant-name resolution. Argument-driven overload selection, generics instantiation, intersection and interface types, and stdlib/gem RBS loading are deferred to Phase 2. The first overload of every method wins, which already covers `Integer#succ`, `Integer#to_s`, `String#upcase`, `Array#length`, `1.zero?`, and the long tail of "method exists on a known class, return type is a single concrete class instance" cases.

Adds:

- `Rigor::Environment::RbsLoader` wraps `RBS::EnvironmentLoader.new` (core only) plus a lazily built `RBS::DefinitionBuilder`. The default loader is a frozen, process-shared singleton with monotonic per-class definition caches; the heavy `RBS::Environment` is built on first method/class query so test runs that never hit RBS pay no startup cost.
- `Rigor::Inference::RbsTypeTranslator` translates `RBS::Types::*` to `Rigor::Type` through a hash-based dispatch table. Generics arguments are dropped (`Array[Integer]` → `Nominal[Array]`), `Optional[T]` becomes `Union[T, Constant[nil]]`, `bool` becomes `Union[Constant[true], Constant[false]]`, `self`/`instance` substitute the `self_type:` keyword when supplied (the receiver class) and degrade to `Dynamic[Top]` otherwise. `Alias`, `Intersection`, `Variable`, and `Interface` degrade to `Dynamic[Top]`.
- `Rigor::Inference::MethodDispatcher::RbsDispatch` resolves `(receiver, method_name)` to an RBS instance method. Receiver-class names are derived from `Constant` (via `value.class.name`), `Nominal` (`class_name`), and `Dynamic` (recursing into `static_facet`); `Top`, `Bot`, and other receivers return `nil`. `Union` receivers dispatch each member in turn — when every member resolves, the results are unioned; if any member misses, the whole dispatch returns `nil`.
- `MethodDispatcher.dispatch` accepts an `environment:` keyword and chains `ConstantFolding` → `RbsDispatch`. Constant folding still wins when applicable, so `1 + 2` keeps its `Constant[3]` precision; only the calls the folder cannot prove fall through to RBS.
- `Rigor::Environment#nominal_for_name(name)` consults the static class registry first, then asks `RbsLoader#class_known?` and synthesises a `Nominal` for the name. `ExpressionTyper#type_of_constant_read` and `type_of_constant_path` use this combined lookup, so `Encoding::Converter` and other RBS-only core constants resolve without bloating the hardcoded registry.
- `ExpressionTyper#call_type_for` adds a *Dynamic-origin propagation* tier after the dispatcher: when the receiver is `Dynamic[T]` and no positive rule resolved, the result silently degrades to `Dynamic[Top]` without firing the fallback tracer. This is a recognised semantic outcome (Dynamic infects), not a fail-soft compromise; documented under *Method Dispatch Boundary* in [`inference-engine.md`](../internal-spec/inference-engine.md).

Coverage uplift on `rigor type-scan lib`: from 22.3 % unrecognised after Slice 3 phase 1 down to **15.1 %** after Slice 4 phase 1. The `CallNode` unrecognised rate drops from 82.8 % to 38.5 %; the remaining unrecognised mass is dominated by user-defined `ConstantReadNode`/`ConstantPathNode` (Rigor's own `Rigor::*` types are not in core RBS) and by `CallNode` against `Nominal[<user type>]` receivers. Slice 4 phase 2 (project-RBS loading and stdlib registration) and Slice 5 (generics, overloads, shape inference) chip away at both buckets.

**Phase 2 (broken into sub-phases, each ships independently):**

- **Phase 2a — Project + stdlib RBS loading.** `Rigor::Environment::RbsLoader#initialize` accepts `libraries:` (an array of stdlib library names like `"pathname"`/`"json"`) and `signature_paths:` (an array of directories containing user `.rbs` files). The default loader (`RbsLoader.default`) stays core-only so the fast path is unchanged, but a new `Rigor::Environment.for_project(root:, libraries:, signature_paths:)` factory builds an Environment that auto-detects `<root>/sig` and loads any stdlib opt-ins. Unknown stdlib names fail-soft via `RBS::EnvironmentLoader#has_library?` (so a stale `.rigor.yml` MUST NOT crash the analyzer); non-existent signature paths are silently filtered. The CLI `type-of` and `type-scan` commands now build their scope through `Environment.for_project` so probes and scans against a project pick up the local `sig/` tree without explicit configuration. Coverage uplift on `rigor type-scan lib`: 14.9 % → 14.4 % (the small delta reflects that Rigor's own `sig/rigor.rbs` is still a stub; the infrastructure is now ready for the sig to grow). The dominant remaining mass — `Prism::CallNode` against user-typed receivers — needs Phase 2b to land class-method dispatch before it can move.
- **Phase 2b — Class-method (singleton-scope) dispatch (this sub-phase ships with this commit).** Adds a singleton-class type carrier `Rigor::Type::Singleton[name]` whose inhabitants are the *class object* `Foo` itself, not instances of `Foo`. `Singleton[Foo]` and `Nominal[Foo]` share `class_name` but compare structurally distinct, so the type model now distinguishes the two values cleanly. The wiring lands in five places:
    1. `Rigor::Type::Combinator.singleton_of(class_or_name)` is the public construction helper, alongside the existing `nominal_of`.
    2. `Rigor::Environment::RbsLoader#singleton_definition(class_name)` and `#singleton_method(class_name:, method_name:)` cache RBS singleton-class definitions (built via `RBS::DefinitionBuilder#build_singleton`). They are namespace-disjoint from the instance-side helpers — `Module#instance_methods`, for example, resolves on the singleton side and is silently absent on the instance side, matching Ruby's runtime semantics.
    3. `Rigor::Inference::RbsTypeTranslator.translate` accepts an `instance_type:` keyword. `Bases::Self` substitutes `self_type:` (which is `Singleton[C]` for a class-method body and `Nominal[C]` for an instance-method body); `Bases::Instance` always substitutes the matching `Nominal[C]`. `singleton(::Foo)` itself translates directly to `Singleton[Foo]` instead of degrading to `Nominal[Class]`.
    4. `Rigor::Inference::MethodDispatcher::RbsDispatch` learns to detect `Singleton` receivers, route them through `singleton_method` instead of `instance_method`, and pass the right `self_type`/`instance_type` pair to the translator. Union receivers continue to dispatch member-by-member; mixing instance and singleton members in one union is supported automatically.
    5. `Rigor::Environment#singleton_for_name` mirrors `nominal_for_name` and produces the carrier for the constant. `ExpressionTyper#type_of_constant_read` and `type_of_constant_path` now use it, so the expression `Integer` types as `Singleton[Integer]` and `Integer.sqrt(4)` correctly resolves through the singleton-method tier to `Nominal[Integer]`. `Foo.new` resolves through `Class#new` for any registered class. Unrecognised class methods on a known class still fall back to `Dynamic[Top]` and emit a fallback event. Coverage uplift on `rigor type-scan lib`: 14.4 % → **13.9 %** unrecognised; the `CallNode` unrecognised rate drops from 38.5 % to 36.7 % as previously-erroneous "instance lookup on a class object" calls are now answered correctly.
- **Phase 2c — Argument-typed overload selection (this sub-phase ships with this commit).** Adds `Rigor::Type#accepts(other, mode:)` on every concrete type, returning a `Rigor::Type::AcceptsResult` value object (Trinary + mode + reasons), and threads it through the RBS-backed dispatcher so different overloads of the same method can be selected based on the caller's actual argument types. Components added:
    1. `Rigor::Type::AcceptsResult` is the dual of the future `SubtypeResult`. It carries the trinary answer, the boundary `mode` (`:gradual` ships now; `:strict` is reserved), and an ordered, frozen `reasons` array. Predicates `yes?`/`no?`/`maybe?` delegate to the carried Trinary, and `with_reason` produces an immutable copy with one extra reason appended.
    2. Each concrete `Rigor::Type` form (`Top`, `Bot`, `Dynamic`, `Nominal`, `Singleton`, `Constant`, `Union`) gains `accepts(other, mode: :gradual)` that delegates to the new `Rigor::Inference::Acceptance` module. The shared module hosts the case-analysis so type instances stay thin (per ADR-3) while satisfying the public API contract in [`internal-type-api.md`](../internal-spec/internal-type-api.md).
    3. The acceptance algebra. Top accepts everything; Bot accepts only Bot; Dynamic[T] in gradual mode accepts every concrete type (and Dynamic on either side also short-circuits to yes); Nominal[C] accepts Nominal[D]/Constant[v] when D <= C / v.is_a?(klass(C)) using Ruby's actual class hierarchy via `Object.const_get` (yielding `maybe` when the class cannot be loaded); Singleton[C] accepts only another singleton of a subclass; Constant[v] accepts only a structurally equal Constant[v']; Union dispatches per-member with the natural OR/AND on the two sides.
    4. `Rigor::Inference::MethodDispatcher::OverloadSelector` consumes a `RBS::Definition::Method` plus the actual `arg_types`, filters method-types by positional arity (required, optional, rest, trailing), skips overloads whose required keywords cannot be satisfied by the keyword-less call shape, and then picks the first overload whose every (param, arg) pair returns `yes` or `maybe` from `accepts`. When no overload matches, the selector falls back to `method_types.first` so the fail-soft contract from phase 1/2b is preserved.
    5. `RbsDispatch.dispatch_one` consults the selector instead of always picking `method_types.first`, threading the chosen overload's return type through `RbsTypeTranslator.translate(... self_type:, instance_type:)`.
    Concrete uplift: `[1, 2, 3].first` (no args) and `[1, 2, 3].first(2)` (one Integer arg) now return distinct types (`Dynamic[Top]` vs `Nominal[Array]`) where phase 2b returned the first overload's `Elem` for both. `Array.new(3)` and `Integer#+` with mismatched arg classes (e.g., `1 + 1.5` after constant folding can't help) similarly select the right RBS overload. Coverage on `rigor type-scan lib`: 13.9% → **13.6%** unrecognised; `Prism::CallNode` 36.7% → 35.8%. The translator's `Bases::Class`-degradation path is now the dominant remaining `CallNode` fallback source — that work moves with Phase 2d.
- **Phase 2d — Generics instantiation (this sub-phase ships with this commit).** Carries type arguments on `Rigor::Type::Nominal` and threads them through every layer of the engine so `Array[Integer]#first` substitutes `Elem` and returns `Integer` instead of degrading to `Dynamic[Top]`. Components added or extended:
    1. `Rigor::Type::Nominal` now carries an ordered, frozen `type_args` array. The empty array is the "raw" form (`Nominal["Array"]`); a non-empty array represents an applied generic (`Nominal["Array", [Nominal["Integer"]]]`). Structural equality and `hash` consult `type_args`; `describe`/`erase_to_rbs` render the args as `Array[Integer]`. Two raw and applied carriers for the same class are distinct values, so the lattice does not silently coerce one into the other.
    2. `Rigor::Type::Combinator.nominal_of(class_or_name, type_args: [])` is the public construction helper; the keyword stays out of the way for callers that do not yet carry generics.
    3. `Rigor::Inference::Acceptance.accepts_nominal` recurses element-wise on `type_args` (covariant; declared variance lands in Slice 5+). When either side is raw the helper short-circuits leniently — raw-self accepts any instantiation (`yes`), raw-other on an applied self yields `maybe` — so phase-2c call sites that did not yet learn about generics keep working. Arity mismatches collapse to `no`.
    4. `Rigor::Inference::RbsTypeTranslator.translate(..., type_vars: {})` accepts a substitution map keyed by the RBS variable's `name` symbol. `RBS::Types::Variable` consults the map and returns the bound `Rigor::Type` when present; unbound variables degrade to `Dynamic[Top]` so uninstantiated generics keep their fail-soft behavior. `RBS::Types::ClassInstance` now translates its `args` recursively, so `Array[Integer]` round-trips into `Nominal["Array", [Nominal["Integer"]]]` and nested generics stay intact.
    5. `Rigor::Environment::RbsLoader#class_type_param_names(class_name)` returns the class's declared type-parameter symbols (`[:Elem]` for `Array`, `[:K, :V]` for `Hash`), reading from the instance definition because singleton methods like `Array.new` parameterize over the same `Elem`.
    6. `Rigor::Inference::MethodDispatcher::RbsDispatch` zips the receiver's `type_args` against the class's `type_param_names` to build a substitution map, then threads that map through both `OverloadSelector.select(..., type_vars:)` and the final `RbsTypeTranslator.translate(..., type_vars:)`. Arity mismatches and raw receivers leave the map empty so free variables degrade as before.
    7. `Rigor::Inference::ExpressionTyper#array_type_for` now constructs `Nominal[Array, [Element]]` from the union of the literal's element types; `type_of_hash` does the same with both K and V. Empty literals stay raw to avoid manufacturing `Bot` evidence the analyzer does not have.
    Concrete uplift: `[1, 2, 3].first` resolves to `Constant[1] | Constant[2] | Constant[3]` (the union of the literal's elements) instead of `Dynamic[Top]`; `[1, 2, 3].first(2)` returns `Array[Constant[1] | Constant[2] | Constant[3]]`; `{a: 1, b: 2}.fetch(:a)` returns `Constant[1] | Constant[2]`. Coverage on `rigor type-scan lib`: 13.6% → **13.4%** unrecognised; `Prism::CallNode` 35.8% → 35.3%. The lift is smaller than 2c's because the gain is in *precision* of resolved calls, not in the count of resolved calls — the residual `CallNode` mass is now dominated by user-defined receivers (`Rigor::*` types) and by call sites whose argument types are themselves Dynamic.

All four sub-phases keep the fail-soft `Dynamic[Top]` policy intact, so a partial migration never breaks the engine surface.

### Slice 5 — Shape Inference

Slice 5 lands in two phases. The roadmap originally lumped `Tuple`, `HashShape`, and `Record` together; the Slice 5 phase 1 commit ships the two literal-driven carriers (`Tuple`, `HashShape`) and defers `Record` (the inferred *object* shape, see [`structural-interfaces-and-object-shapes.md`](../type-specification/structural-interfaces-and-object-shapes.md)) to phase 2 because object-shape evidence is not literal-driven and lands alongside capability-role inference.

**Phase 1 (this sub-phase ships with this commit) — Tuple + HashShape carriers and the literal upgrades.** Components added:

1. `Rigor::Type::Tuple` carries an ordered, frozen array of `Rigor::Type` element values. Inhabitants are exactly the Ruby `Array` instances whose length matches `elements.size` and whose element at position `i` inhabits `elements[i]`. `describe`/`erase_to_rbs` render `[A, B, C]`; equality and `hash` are structural over `elements`. The empty Tuple `Tuple[]` is a valid value-object even though `array_type_for` keeps `[]` as raw `Nominal[Array]` (no element evidence to lock the arity).
2. `Rigor::Type::HashShape` carries an ordered, frozen `(Symbol|String) -> Rigor::Type` map. `describe` renders `{ a: T }` for symbol keys and `{ "k": T }` for string keys; `erase_to_rbs` produces the RBS record syntax for symbol-keyed shapes and degrades to bare `Hash` for empty or string-keyed shapes (RBS records cannot carry string keys). Equality follows Ruby's `Hash#==` (order-independent over keys); insertion order is preserved for rendering. Required-key, optional-key, and closed-extra-key policies (the Rigor extensions in [`rigor-extensions.md`](../type-specification/rigor-extensions.md)) are deferred to phase 2.
3. `Rigor::Type::Combinator.tuple_of(*elements)` and `Combinator.hash_shape_of(pairs)` are the public factories. `tuple_of()` produces the empty Tuple; `hash_shape_of({})` produces the empty HashShape.
4. `Rigor::Inference::Acceptance` learns two new routes. `Tuple[A1..An].accepts(Tuple[B1..Bn])` performs covariant element-wise comparison after an arity check; non-Tuple `other` is rejected because the analyzer cannot prove arity from a generic nominal alone. `HashShape{k: T,...}.accepts(HashShape{...})` is depth-covariant on shared keys and width-permissive (extra keys on the right side are allowed); a missing required key is rejected. The converse routes — `Nominal[Array, [E]].accepts(Tuple[*])` and `Nominal[Hash, [K, V]].accepts(HashShape{...})` — project the shape to the underlying nominal and re-enter the existing generic-acceptance pipeline.
5. `Rigor::Inference::RbsTypeTranslator.translate_tuple` and `translate_record` map `RBS::Types::Tuple` and `RBS::Types::Record` to the new shape carriers (instead of erasing them to `Nominal[Array]` / `Nominal[Hash]` as in phase 2d). Element/value types are translated recursively under the caller's `self_type`/`instance_type`/`type_vars` context, so generics inside tuples/records are preserved.
6. `Rigor::Inference::MethodDispatcher::RbsDispatch.receiver_descriptor` projects shape-carrying receivers onto their underlying nominal so the existing generic-typed dispatch pipeline reuses without duplication: `Tuple[Integer, String]` dispatches as `Array[Integer | String]`, and `HashShape{a: Integer}` dispatches as `Hash[Symbol, Integer]`. Tuple-aware refinements (e.g., `tuple[0]` returning the precise member, destructuring assignment) are deferred to phase 2; they will run as a higher-priority dispatch tier above `RbsDispatch`.
7. `Rigor::Inference::ExpressionTyper#array_type_for` upgrades non-empty array literals to `Tuple` when every element is a non-splat value; literals containing splats keep the Slice 4 phase 2d `Nominal[Array, [union]]` path so `[*xs, 1]` still produces an inferable element type. `type_of_hash` upgrades hash literals to `HashShape` when every entry is an `AssocNode` whose key is a static `SymbolNode` or `StringNode` literal; entries with dynamic keys, double-splats, or duplicate keys fall through to the generic `Hash[K, V]` form.

Concrete uplift: `[1, 2, 3]` types as `Tuple[Constant[1], Constant[2], Constant[3]]` (was `Nominal[Array, [Constant[1] | Constant[2] | Constant[3]]]`); `{ a: 1, b: 2 }` types as `HashShape{a: Constant[1], b: Constant[2]}` (was `Nominal[Hash, [Symbol-union, Integer-union]]`). Method dispatch through the carriers preserves the same return-type precision via projection: `[1, 2, 3].first(2)` still resolves to `Array[Constant[1] | Constant[2] | Constant[3]]`, `{ a: 1 }.fetch(:a)` still substitutes V into the union of values. Coverage on `rigor type-scan lib`: 13.4% → **13.5%** unrecognised; the small wobble reflects the new lib files (Tuple/HashShape carriers) contributing their own constant references rather than any precision regression.

**Phase 2 (deferred to a follow-up commit):** introduces the inferred object shape (`Record`), tuple-aware method dispatch (`tuple[0]`, `tuple.first` returning the precise member, destructuring assignment), and the Rigor-extension hash-shape policies (required/optional/closed-extra-key, read-only entries) per [`rigor-extensions.md`](../type-specification/rigor-extensions.md).

### Slice 6 — Narrowing (Minimal CFA)

Adds `Rigor::Analysis::FactStore` (value facts and nil facts only), edge-aware truthy/falsey narrowing on `IfNode`, and the conventional narrowing predicates (`nil?`, `kind_of?`, `is_a?`, literal `==`).

### Slice 7 — Refinements (Minimal)

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

Slice 2 adds `lib/rigor/inference/method_dispatcher.rb` and `lib/rigor/inference/method_dispatcher/constant_folding.rb`. Slice 4 adds `lib/rigor/environment/rbs_loader.rb` and the RBS-backed dispatch tier inside `MethodDispatcher`. Slice 6 adds `lib/rigor/analysis/fact_store.rb`. The `lib/rigor/analysis/` directory keeps holding diagnostic and runner code; the inference engine is a separate concern under `lib/rigor/inference/`.

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
- **RBS environment startup cost.** RBS loading is deferred to Slice 4; Slice 1 ships with a hardcoded registry and Slice 2 only relies on constant-folding rules. The Slice 4 loader is wrapped to allow caching across runs and tests.
- **Fail-soft `Dynamic[Top]` masking regressions.** From Slice 1 onward, the typer optionally records a `Diagnostic::Trace` when it falls back to `Dynamic[Top]`. The trace is opt-in to avoid noise, but is plumbed so later slices can detect coverage regressions.
- **Scope ergonomics.** Returning `[Type, Scope']` from `evaluate(node, scope)` (Slice 3) is verbose. We accept the verbosity in exchange for explicit immutability. Helper builders (`scope.evaluate(node) { |type| ... }`) MAY be added once two or three call sites exist.

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
- [`docs/type-specification/control-flow-analysis.md`](../type-specification/control-flow-analysis.md) — Scope/CFA target for Slice 6.

External (PHPStan source code, not part of Rigor's submodules):

- [`phpstan/phpstan-src` `src/Analyser/Scope.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Analyser/Scope.php).
- [`phpstan/phpstan-src` `src/Analyser/MutatingScope.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Analyser/MutatingScope.php).
- [`phpstan/phpstan-src` `src/Analyser/NodeScopeResolver.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Analyser/NodeScopeResolver.php).
