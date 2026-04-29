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

A unified `Rigor::Type::Constant` carrier holds scalar literals (`Integer`, `Float`, `String`, `Symbol`, `Rational`, `Complex`, `true`, `false`, `nil`) plus static integer-endpoint `Range` literals used by tuple slicing. Compound literal shapes (`Tuple`, `HashShape`, `Record`) get dedicated classes because their inner-type references and shape policies do not compress to a single Ruby value.

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

**Phase 1 (this slice ships first):** every control-flow expression is typed via `ExpressionTyper` in the receiver scope, so no node class in this family stays unrecognised. Both branches of `IfNode`/`UnlessNode`, every `WhenNode`/`InNode` body of `CaseNode`/`CaseMatchNode`, and the body / rescue chain / else clause of `BeginNode` are typed and unioned. `AndNode`/`OrNode` union their operands (no truthy/falsy narrowing yet, that lands in Slice 6). `RescueModifierNode` (`expr rescue fallback`) is the same union. `WhileNode`/`UntilNode` type as `Constant[nil]`. `ReturnNode`/`BreakNode`/`NextNode`/`RetryNode`/`RedoNode` type as `Bot`, which absorbs cleanly under union so a jumping branch is silently dropped from the surrounding control-flow's value (`if c; return; else; 7; end` correctly types as `Constant[7]`). `YieldNode`/`SuperNode`/`ForNode`/`DefinedNode`/`MatchPredicateNode`/`MatchRequiredNode`/`MatchWriteNode` are silently typed as `Dynamic[Top]` until later slices add their semantics. `LambdaNode`/`RangeNode`/`RegularExpressionNode`/`InterpolatedRegularExpressionNode` round out the literal carriers as `Nominal[Proc]`/static `Constant[Range]` or `Nominal[Range]`/`Nominal[Regexp]`. `Rigor::Scope#join(other)` ships now as the structural-union join used by Phase 2; it intersects the bound names and runs each pair through `Type::Combinator.union`.

**Phase 2 (this sub-phase ships with this commit) — StatementEvaluator (locals propagate across statements).** Introduces `Rigor::Inference::StatementEvaluator#evaluate(node) -> [Rigor::Type, Rigor::Scope]` and threads `Scope#join` through every statement-level construct so locals bound on one branch flow to a unioned binding after the merge point. The class is the Ruby-side complement of the (still pure) `Scope#type_of`: every public call returns a fresh `[type, scope']` pair without mutating the receiver scope. Components added or extended:

1. `Rigor::Inference::StatementEvaluator` is the new entry point. Construction takes the entry `scope:` plus an optional `tracer:`; `evaluate(node)` dispatches on a frozen `HANDLERS = { Prism::*Node => :handler_method }` table and falls back to `[scope.type_of(node, tracer:), scope]` for nodes the catalogue does not specialise (so unrecognised statement-y nodes MUST NOT raise — the Slice 1 fail-soft policy stays intact at the statement level too).
2. The Slice 3 phase 2 catalogue is `StatementsNode`/`ProgramNode` (sequential threading), `LocalVariableWriteNode` (binds the rvalue's type via `Scope#with_local`), `IfNode`/`UnlessNode`/`ElseNode` (predicate then branch+merge), `CaseNode`/`CaseMatchNode`/`WhenNode`/`InNode` (N-ary branch+merge), `BeginNode`/`RescueNode`/`EnsureNode` (body + rescue chain + ensure layered on the joined exit scope), `WhileNode`/`UntilNode` (condition + body, post-scope joins zero-iterations and N-iterations), `AndNode`/`OrNode` (LHS always runs, RHS sometimes runs; result is the union, post-scope is join-with-nil-injection), and `ParenthesesNode` (threads scope through the inner expression so `(x = 1; x + 2)` binds `x` and produces `Constant[3]`).
3. The branch-merge implementation injects `Constant[nil]` for half-bound names before delegating to `Scope#join`. This satisfies the contract that `Scope#join` documents as "the responsibility of the statement-level evaluator": `if cond; x = 1; end; x` now types as `Constant[1] | Constant[nil]`, `case kind; when 1 then x = 1; when 2 then x = 2; y = 9; end` types `x: Constant[1] | Constant[2] | Constant[nil]` and `y: Constant[9] | Constant[nil]`. N-ary merges reduce by repeated pairwise join-with-nil-injection; the reduce order does not affect the result.
4. `Rigor::Scope#evaluate(node, tracer: nil)` ships as the public delegate so callers do not have to instantiate `StatementEvaluator` themselves. The receiver scope is treated as the entry scope; the return value is the same `[type, scope']` pair the evaluator produces.

Concrete uplift: `x = 1; y = x + 2; y` now types as `Constant[3]` with `x: Constant[1]`, `y: Constant[3]` in the post-scope (constant folding flows through bound locals); `xs = [1, 2, 3]; xs.first` types as `Constant[1] | Constant[2] | Constant[3]` (the Slice 5 phase 1 dispatch path resolves through the bound local); `h = {a: 1, b: 2}; h.fetch(:a)` types as `Constant[1] | Constant[2]`.

Boundary: Slice 3 phase 2 does NOT thread scope through arbitrary expression interiors (`foo(x = 1)` and `[1, x = 2]` still drop `x` from the post-scope). The deliberate Phase 2 simplification keeps the StatementEvaluator surface stable while later slices grow the catalogue; the DefNode-aware scope builder (below) lifts the second boundary mentioned earlier so method bodies now see their own parameters.

**CLI integration (this commit also ships):** the CLI commands `rigor type-of` and `rigor type-scan` now consume `Scope#evaluate` indirectly through a new `Rigor::Inference::ScopeIndexer.index(root, default_scope:)` helper. The indexer wires an `on_enter:` callback onto a fresh `StatementEvaluator`, walks the program once, and returns an identity-comparing `Hash{Prism::Node => Rigor::Scope}` whose lookup yields the entry scope visible at every node — propagating the parent's scope down to expression-interior children that the evaluator does not visit. The CLI commands then run `index[node].type_of(node, tracer:)` per probe so locals bound earlier in the file flow into the scope used to type later nodes. The indexer runs its internal evaluator tracer-free; CLI callers attach their tracer only to the post-index `type_of` probe, avoiding double-recorded fallback events.

Adds:

5. `Rigor::Inference::StatementEvaluator#initialize(on_enter:)` keyword (defaults to `nil`). When non-`nil`, the callable is invoked once at the start of every `evaluate(node)` call with `(node, scope)`, and is threaded through every recursive `sub_eval`. The contract is bound in [`docs/internal-spec/inference-engine.md`](../internal-spec/inference-engine.md) under "Statement-Level Evaluation".
6. `Rigor::Inference::ScopeIndexer` module with the `index` factory and the `propagate` DFS walker that fills in scope entries for unvisited expression-interior nodes.
7. `Rigor::CLI::TypeOfCommand` and `Rigor::Inference::CoverageScanner#scan` route their per-node `type_of` calls through the indexer's lookup.

Concrete behavioral uplift (verified through CLI smoke probes):

- `x = 1; y = x + 2; y` typed at line 3 col 1 (the `y` read) returns `Constant[3]`; typed at line 2 col 5 (the `x` read inside the rvalue) returns `Constant[1]`. Pre-integration, both probes returned `Dynamic[Top]`.
- `xs = [1, 2, 3]; result = xs.first; result` typed at line 3 returns `Constant[1] | Constant[2] | Constant[3]` (Tuple-aware dispatch flows through the bound local). Pre-integration, the `result` probe returned `Dynamic[Top]` because `xs` was not visible.

`type-scan lib` coverage moves from 13.71 % to 13.70 % unrecognised — within noise; lib/ is dominated by user-defined `ConstantReadNode`/`ConstantPathNode` references and `CallNode`s against user-typed receivers (whose RBS is not registered) plus method bodies whose locals are method parameters (which the StatementEvaluator does not bind). The integration's value is real and measurable on code with top-level local-variable patterns; the dogfood sample lib/ does not exercise that pattern frequently. The CLI behavioral uplift above is the observable proof.

**DefNode-aware scope builder (this commit also ships):** the StatementEvaluator's catalogue now includes `Prism::ClassNode`, `Prism::ModuleNode`, `Prism::SingletonClassNode`, and `Prism::DefNode`. Class/module bodies and method bodies are evaluated under *fresh* scopes (Ruby's class scope and method scope do not see the outer locals), and the evaluator threads a small `class_context:` stack of `ClassFrame.new(name:, singleton:)` frames so nested `def`s know their lexical owner. The new `Rigor::Inference::MethodParameterBinder.new(environment:, class_path:, singleton:).bind(def_node)` translates the def's parameter list into a `name -> Rigor::Type` map, defaulting every name to `Dynamic[Top]` and overriding from the surrounding class's RBS signature when one is available. Parameter types are unioned across every overload that has the matching slot (so `Array#first(n)`'s `(int)` overload still binds `n` even though the parallel `()` overload omits it); positional slots are matched by position, keyword slots by name across both required and optional keyword maps; `*rest` and `**kw_rest` are wrapped as `Array[T]` and `Hash[Symbol, V]`. `def self.foo` and `def foo` inside `class << self` both route through `RbsLoader#singleton_method`. Components added or extended:
8. `Rigor::Inference::MethodParameterBinder` is the new public surface for "translate a def's parameter list into a binding map". Its contract is bound in [`docs/internal-spec/inference-engine.md`](../internal-spec/inference-engine.md) under "Method Parameter Binding".
9. `Rigor::Inference::StatementEvaluator` now defines `eval_def`, `eval_class_or_module`, and `eval_singleton_class` handlers and threads a `class_context:` stack through every `sub_eval`. The frame's qualified name is rendered from `Prism::ClassNode#constant_path` so `class A::B; class C` produces a `class_path` of `"A::B::C"` and `class << self` flips the innermost frame to singleton mode.

Concrete behavioral uplift (verified through CLI smoke probes):

- `class Integer; def divmod(other); other; end; end` now types the `other` read inside the body as `Float | Integer | Numeric | Rational` (the union across the four `Integer#divmod` RBS overloads). Pre-binder, the read returned `Dynamic[Top]`.
- `class Foo; def bar(x); x; end; end` (where `Foo` is unknown to RBS) types `x` as `Dynamic[Top]` rather than raising — the binder fail-soft contract holds.
- `def add(a, b); a + b; end` at top level (no class context) types both `a` and `b` as `Dynamic[Top]` — no RBS lookup is attempted because the binder needs an enclosing class.

`type-scan lib` coverage moves from 13.71 % to **13.45 %** unrecognised; `Prism::CallNode` 35.9 % → **34.7 %**. The improvement is concentrated in classes that genuinely override an RBS-known method (where parameters now carry type information) and is bounded above by the fact that most lib/rigor methods belong to classes Rigor does not yet author RBS for. `type-scan spec` moves from 31.4 % to **30.98 %** unrecognised on the same query.

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
2. `Rigor::Type::HashShape` carries an ordered, frozen `(Symbol|String) -> Rigor::Type` map plus required-key, optional-key, read-only, and open/closed extra-key policies (the Rigor extensions in [`rigor-extensions.md`](../type-specification/rigor-extensions.md)). `describe` renders `{ a: T }` for required symbol keys, `{ ?b: T }` for optional keys, `{ "k": T }` for string keys, and appends `...` for open shapes. Exact closed symbol-keyed shapes erase to RBS record syntax (including `{}` and optional fields); string-keyed shapes degrade to `Hash[K, V]`, and open shapes without typed extra bounds degrade to `Hash[top, top]`. Equality follows Ruby's `Hash#==` for entries and includes policy fields.
3. `Rigor::Type::Combinator.tuple_of(*elements)` and `Combinator.hash_shape_of(pairs, **options)` are the public factories. `tuple_of()` produces the empty Tuple; `hash_shape_of({})` produces the empty closed HashShape.
4. `Rigor::Inference::Acceptance` learns two new routes. `Tuple[A1..An].accepts(Tuple[B1..Bn])` performs covariant element-wise comparison after an arity check; non-Tuple `other` is rejected because the analyzer cannot prove arity from a generic nominal alone. `HashShape{k: T,...}.accepts(HashShape{...})` is depth-covariant on shared keys, requires every required key on the target to be required on the source, allows absent optional keys, and rejects extra/open sources when the target is closed. The converse routes — `Nominal[Array, [E]].accepts(Tuple[*])` and `Nominal[Hash, [K, V]].accepts(HashShape{...})` — project the shape to the underlying nominal and re-enter the existing generic-acceptance pipeline.
5. `Rigor::Inference::RbsTypeTranslator.translate_tuple` and `translate_record` map `RBS::Types::Tuple` and `RBS::Types::Record` to the new shape carriers (instead of erasing them to `Nominal[Array]` / `Nominal[Hash]` as in phase 2d). Element/value types are translated recursively under the caller's `self_type`/`instance_type`/`type_vars` context, so generics inside tuples/records are preserved. RBS record optional fields map to optional `HashShape` keys, and records are closed.
6. `Rigor::Inference::MethodDispatcher::RbsDispatch.receiver_descriptor` projects shape-carrying receivers onto their underlying nominal so the existing generic-typed dispatch pipeline reuses without duplication: `Tuple[Integer, String]` dispatches as `Array[Integer | String]`, and `HashShape{a: Integer}` dispatches as `Hash[Symbol, Integer]`. Tuple-aware refinements (e.g., `tuple[0]` returning the precise member, destructuring assignment) are deferred to phase 2; they will run as a higher-priority dispatch tier above `RbsDispatch`.
7. `Rigor::Inference::ExpressionTyper#array_type_for` upgrades non-empty array literals to `Tuple` when every element is a non-splat value; literals containing splats keep the Slice 4 phase 2d `Nominal[Array, [union]]` path so `[*xs, 1]` still produces an inferable element type. `type_of_hash` upgrades hash literals to `HashShape` when every entry is an `AssocNode` whose key is a static `SymbolNode` or `StringNode` literal; entries with dynamic keys, double-splats, or duplicate keys fall through to the generic `Hash[K, V]` form.

Concrete uplift: `[1, 2, 3]` types as `Tuple[Constant[1], Constant[2], Constant[3]]` (was `Nominal[Array, [Constant[1] | Constant[2] | Constant[3]]]`); `{ a: 1, b: 2 }` types as `HashShape{a: Constant[1], b: Constant[2]}` (was `Nominal[Hash, [Symbol-union, Integer-union]]`). Method dispatch through the carriers preserves the same return-type precision via projection: `[1, 2, 3].first(2)` still resolves to `Array[Constant[1] | Constant[2] | Constant[3]]`, `{ a: 1 }.fetch(:a)` still substitutes V into the union of values. Coverage on `rigor type-scan lib`: 13.4% → **13.5%** unrecognised; the small wobble reflects the new lib files (Tuple/HashShape carriers) contributing their own constant references rather than any precision regression.

**Phase 2 lands in sub-phases.** The carriers and projection-based dispatch shipped in phase 1 leave room for incremental precision uplifts.

**Phase 2 sub-phase 1 (this sub-phase ships with this commit) — Shape-aware element dispatch.** Adds `Rigor::Inference::MethodDispatcher::ShapeDispatch`, a new tier inserted between `ConstantFolding` and `RbsDispatch`. The contract is bound in [`docs/internal-spec/inference-engine.md`](../internal-spec/inference-engine.md) under "Method Dispatch Boundary"; the tier resolves element-access methods on `Tuple` and `HashShape` to their precise per-position/per-key type rather than the projected `Array#[]`/`Hash#fetch` answer. Components added:

1. `ShapeDispatch.try_dispatch(receiver:, method_name:, args:)` returns the precise element/value type or `nil` to defer to the next tier. The recognised Tuple catalogue is `first`/`last`/`size`/`length`/`count` (no-arg) plus `[]`/`fetch` with a single `Constant[Integer]` argument; the recognised HashShape catalogue is `size`/`length` (no-arg) plus `[]`/`fetch`/`dig` with a single `Constant[Symbol|String]` argument. Out-of-range indices, missing-key `fetch`, multi-arg `dig`, and non-static keys defer to `RbsDispatch` so the projection answer keeps applying.
2. `MethodDispatcher.dispatch` threads the new tier above `RbsDispatch`. The phase 1 projection still applies on misses: `tuple.map`, `shape.transform_values`, and other iteration calls keep their previous behaviour.
3. Negative tuple indices are normalised by length (`tuple[-1]` returns the last element). Missing-key resolution mirrors Ruby semantics: `shape[:missing]` and `shape.dig(:missing)` resolve to `Constant[nil]` while `shape.fetch(:missing)` defers because the runtime would raise `KeyError`.

Concrete behavioural uplift (verified through CLI smoke probes):

- `[1, 2, 3].first` types as `Constant[1]` (was `Constant[1] | Constant[2] | Constant[3]`).
- `[1, 2, 3][-1]` types as `Constant[3]`; `[1, 2, 3].size` types as `Constant[3]`.
- `{ name: "Alice", age: 30 }[:name]` types as `Constant["Alice"]` (was the projected value-union).
- `{ a: 1 }[:missing]` types as `Constant[nil]`; `{ a: 1 }.fetch(:missing)` keeps the projection answer.

Coverage on `rigor type-scan lib`: 13.8 % → **13.6 %** unrecognised; `Prism::CallNode` 35.7 % → 35.1 %. The lift is concentrated in code that constructs tuples and hash shapes locally; user-typed receivers (Rigor's own `Rigor::*` types) still wait on RBS authoring for further coverage. The previously-recorded uplift quotes for Slice 4 phase 2c/d (`[1, 2, 3].first` as a union, `{ a: 1, b: 2 }.fetch(:a)` as a value union) reflect that slice's commit-time behaviour and are superseded here: those expressions now resolve through `ShapeDispatch` to the precise first member / value.

**Phase 2 sub-phase 2 (this sub-phase ships with this commit) — Destructuring assignment, multi-arg `dig`, and `Hash#values_at`.** Components added:

1. `Rigor::Inference::MultiTargetBinder` is a pure module that decomposes a `Rigor::Type` value against a Prism multi-target tree (`MultiWriteNode` or `MultiTargetNode`) and returns a `name -> Rigor::Type` binding map. Tuple-shaped right-hand sides project element-wise: front targets read elements by index (filling missing slots with `Constant[nil]`), the rest target binds to a `Tuple` of the middle elements (`Tuple[]` when the source has no surplus), and back targets read tail elements at the corresponding offsets. Non-Tuple right-hand sides bind every slot to `Dynamic[Top]`. Nested `MultiTargetNode` targets recurse with the slot's type as the new right-hand side. Non-local targets (instance/class/global variables, constants, index/call targets, anonymous splat) are silently skipped because they have no observable contribution to the local-variable scope. The binder is the canonical surface shared between sub-phase 2 (statement-level destructuring) and Slice 6 phase C sub-phase 2 (block-parameter destructuring), so the bind rules MUST be authored once and consumed twice.
2. `Rigor::Inference::StatementEvaluator` adds a `Prism::MultiWriteNode` handler that evaluates the right-hand side once under the entry scope and folds the binder's bindings into the post-scope. The pair's type MUST equal the right-hand side's type (matching Ruby's `(a, b = [1, 2]) #=> [1, 2]` semantics).
3. `Rigor::Inference::MethodDispatcher::ShapeDispatch` grows three precise handlers: Tuple#`dig` (chain), HashShape#`dig` (chain), and HashShape#`values_at`. The chain semantics MUST be: each step looks up its key/index, then `chain_dig` continues with the resolved value as the new receiver — Tuple/HashShape members re-dispatch into the catalogue with the remaining args, a `Constant[nil]` member short-circuits the chain to `Constant[nil]` (Ruby's `Array#dig` and `Hash#dig` short-circuit on nil at runtime), and any other intermediate carrier defers so the projection answer applies. An out-of-range index that arises *during* a chain step MUST resolve to `Constant[nil]` because Ruby's `Array#dig` returns nil for out-of-range indices rather than raising. `values_at` returns a `Tuple` whose per-position values are the per-key values (`Constant[nil]` for missing keys); the catalogue defers when any argument is non-static. Range/start-length `[]` and the Rigor-extension hash-shape policies land in sub-phase 3.

Concrete behavioural uplift (verified through CLI smoke probes):

- `pair = [10, 20]; a, b = pair; sum = a + b` types `sum` as `Constant[30]`. Pre-binding `a` and `b` were unbound past the multi-write so `sum` collapsed to `Dynamic[Top]`.
- `users = { addr: { zip: "00100" } }; users.dig(:addr, :zip)` types as `Constant["00100"]`. Pre-binding the chain stepped through the projected `Hash[Symbol, Hash[...]]` answer and lost the literal value.
- `{ a: 1, b: "two" }.values_at(:a, :b)` types as `Tuple[Constant[1], Constant["two"]]` (was the projected `Array[Integer | String]`).
- `a, *r, c = [1, 2, 3, 4]` binds `a -> Constant[1]`, `r -> Tuple[Constant[2], Constant[3]]`, `c -> Constant[4]`.

The `Record` carrier (the inferred object shape, see [`structural-interfaces-and-object-shapes.md`](../type-specification/structural-interfaces-and-object-shapes.md)) lands alongside capability-role inference in a later slice; the literal-driven `HashShape` continues to cover the hash side until then.

**Phase 2 sub-phase 3 (this sub-phase ships with this commit) — Range and start-length forms of `[]`, plus the Rigor-extension hash-shape policies.** Components added:

1. `ExpressionTyper#type_of_range` now carries integer-endpoint range literals as `Constant[Range]`, preserving static bounds for `ShapeDispatch`. Dynamic ranges remain `Nominal[Range]`.
2. `ShapeDispatch` recognises `tuple[start, length]` and `tuple[range]` for `[]`, using Ruby `Array#[]` slice semantics. Statically successful slices return a sliced `Tuple`; statically nil slices return `Constant[nil]`; `fetch` does not claim those forms.
3. `HashShape` gains required/optional/read-only key sets and an open/closed extra-key policy. Exact closed symbol-keyed shapes erase to RBS records, including optional fields; open or string-keyed shapes erase to `Hash[K, V]`. Optional-key reads through `[]`/`dig` include `nil`, while optional-key `fetch` defers because the key may be absent.
4. `Acceptance` threads the policies through structural checks. A closed target rejects extra known keys and open sources; an open target preserves the old width-permissive behaviour. Required target keys must be required on the source, while optional target keys may be absent.

### Slice 6 — Narrowing (Minimal CFA)

Slice 6 lands in two phases. Phase 1 ships truthiness and `nil?` narrowing on `IfNode`/`UnlessNode` plus the corresponding RHS-entry narrowing on `AndNode`/`OrNode`; phase 2 adds class-membership predicates (`is_a?`, `kind_of?`, `instance_of?`), equality narrowing for finite literal sets, and the formal `Rigor::Analysis::FactStore` carriage that drives heap and relational facts in [`docs/type-specification/control-flow-analysis.md`](../type-specification/control-flow-analysis.md).

**Phase 1 (this sub-phase ships with this commit) — Truthiness and nil narrowing on local bindings.** Components added:

1. `Rigor::Inference::Narrowing` is a pure module exposing the type-level primitives (`narrow_truthy`, `narrow_falsey`, `narrow_nil`, `narrow_non_nil`) and the predicate-level analyser `predicate_scopes(node, scope) -> [truthy_scope, falsey_scope]`. The contract is bound in [`docs/internal-spec/inference-engine.md`](../internal-spec/inference-engine.md) under "Narrowing (Slice 6 phase 1)".
2. The Slice 6 phase 1 predicate catalogue is `LocalVariableReadNode` (truthy/falsey narrowing of the bound local), `CallNode` for `recv.nil?` and the unary `!recv` (only when the call carries no arguments or block), `ParenthesesNode`/`StatementsNode` (recurse into the body / last statement), and the short-circuiting `AndNode`/`OrNode` (compose sub-edges through `Scope#join`). Anything else falls through to "no narrowing" — both edges return the entry scope unchanged so the Slice 3 phase 2 behaviour is preserved on uncovered shapes.
3. `Rigor::Inference::StatementEvaluator` is now narrowing-aware. `eval_if` evaluates the `then` branch under the predicate's truthy scope and the `else` branch under the falsey scope; `eval_unless` swaps the two; `eval_and_or` enters the RHS under the LHS's truthy scope (`&&`) or the LHS's falsey scope (`||`). The half-bound nil-injection at branch merges is unchanged.

The acceptance algebra is delegated to `narrow_truthy`/`narrow_falsey` rather than per-class predicates so type instances stay thin (per ADR-3): `Constant` consults its scalar `value`, `Nominal` consults `class_name` against the `NilClass`/`FalseClass` shortlist, `Union` recurses element-wise, and `Top`/`Dynamic` flow through unchanged because the analyzer cannot express the difference type without a richer carrier yet.

Concrete behavioural uplift (verified through CLI smoke probes):

- `xs = [1, 2, nil]; y = xs.first; if y.nil?; "got nil"; else; y; end` types as `Constant["got nil"] | Constant[1] | Constant[2]`. Pre-narrowing the result included `Constant[nil]` because `y` was not refined in the else branch.
- `Union[Integer, nil].evaluate("if x; x.succ; end")` types `x.succ` against `Nominal[Integer]` (the dispatch resolves cleanly because the receiver is narrowed), where the un-narrowed dispatch could not prove `NilClass#succ` and would fall back.

Coverage on `rigor type-scan lib`: 13.45 % → **13.8 %** unrecognised. As ADR-4 anticipated for Slice 6, the small upward wobble reflects the new `lib/rigor/inference/narrowing.rb` file (its constant references contribute to the unrecognised bucket against `Rigor::*` types not yet covered by RBS) rather than a precision regression. The behavioural uplift is concentrated on already-typed values.

**Phase 2 sub-phase 1 (this sub-phase ships with this commit) — Class-membership narrowing.** Components added:

1. `Rigor::Inference::Narrowing` grows two type-level primitives, `narrow_class(type, class_name, exact: false)` and `narrow_not_class(type, class_name, exact: false)`. The truthy primitive walks the value lattice (`Constant`, `Nominal`, `Union`, `Tuple`, `HashShape`, `Singleton`, `Top`, `Dynamic`, `Bot`) and uses the host Ruby's class hierarchy via `Object.const_get` to compute one of `:equal`/`:subclass`/`:superclass`/`:disjoint`/`:unknown`. The `:superclass` case implements the practical narrowing win — `Nominal[Numeric]` under `is_a?(Integer)` becomes `Nominal[Integer]` rather than staying at the supertype. `:unknown` (a class the host Ruby has not loaded) preserves the input so the analyzer never asserts narrowing it cannot prove. The falsey mirror collapses matching carriers to `Bot` and preserves the rest, deliberately staying conservative on the supertype case where the analyzer cannot prove the disjunction without a richer carrier.
2. `Rigor::Inference::Narrowing.predicate_scopes` recognises three new `Prism::CallNode` shapes: `recv.is_a?(C)`, `recv.kind_of?(C)`, and `recv.instance_of?(C)`. The receiver MUST be a `Prism::LocalVariableReadNode` and the single argument MUST be a static constant reference (`Prism::ConstantReadNode` or `Prism::ConstantPathNode`); the qualified name is rendered through a parent-walk of the constant path. `is_a?`/`kind_of?` use `exact: false`, `instance_of?` uses `exact: true`. Anything else (a non-constant argument, a multi-argument call, a non-local receiver) falls through to "no narrowing" so the entry scope is observed unchanged on both edges.
3. The `StatementEvaluator` integration is unchanged: `eval_if`/`eval_unless`/`eval_and_or` already consume `predicate_scopes` and the new catalogue surfaces through the same `[truthy_scope, falsey_scope]` shape. The `unary !` analyser swaps the truthy/falsey edges of the recursive call, so `unless x.is_a?(Integer)` and `!x.is_a?(Integer)` reuse the same machinery without per-form code.
4. `docs/internal-spec/inference-engine.md` and the type-specification pointer in [`docs/type-specification/control-flow-analysis.md`](../type-specification/control-flow-analysis.md) MUST stay the binding contract for these narrowing primitives. The internal spec was refreshed in this commit to enumerate the new carrier rules and the new `Prism::CallNode` catalogue entries.

Concrete behavioural uplift (verified through CLI smoke probes):

- `Union[Integer, String].evaluate("if x.is_a?(Integer); x; else; x; end")` types each branch's `x` as `Nominal[Integer]` and `Nominal[String]` respectively. Pre-narrowing both branches saw the bare union.
- `Nominal[Numeric].evaluate("if x.is_a?(Integer); x; end")` types the then-branch's `x` as `Nominal[Integer]` (the `:superclass` ordering narrows the supertype DOWN to the asked class). Pre-narrowing the supertype was preserved, so `x.bit_length` would not dispatch.
- `unless x.is_a?(Integer); x; else; x; end` swaps the edges through the existing `eval_unless` handler, so `Union[Integer, String]` resolves the `unless` branch as `Nominal[String]` without per-form code.

Coverage on `rigor type-scan lib`: 13.8 % → **13.5 %** unrecognised, a small downward step that reflects the analyzer eliminating a few residual fail-soft fallbacks on `is_a?` calls in product code (the `MethodDispatcher.expected_block_param_types` query and the `Narrowing` analyser both contain `case node when ...` branches that previously fell out of the narrowing surface).

**Phase 2 sub-phase 2 (this sub-phase ships with this commit) — Equality narrowing + FactStore.** Components added:

1. `Rigor::Analysis::FactStore` is the immutable fact bundle carried by each `Scope` snapshot. It defines the initial bucket vocabulary (`local_binding`, `captured_local`, `object_content`, `global_storage`, `dynamic_origin`, `relational`), target/fact value objects, target invalidation, and conservative joins that retain only facts present on both incoming edges. `Scope#with_local` invalidates facts for the rebound local; `Scope#with_fact`, `Scope#local_facts`, and `Scope#facts_for` expose the narrow query surface without exposing mutable bucket storage.
2. `Rigor::Inference::Narrowing` grows `narrow_equal(type, literal)` and `narrow_not_equal(type, literal)`. String/Symbol/Integer literals narrow only inside already-finite trusted literal domains; nil/true/false singleton values can be extracted from mixed domains such as `Integer | nil`; Float literals and broad domains (`String`, `Dynamic[Top]`) do not gain fabricated literal precision.
3. `Narrowing.predicate_scopes` recognises `local == literal`, `literal == local`, and the `!=` mirror for trusted static literals. The equality edge rebinds the local through the new primitives and records a `FactStore::Fact`: `local_binding` when the type changed, `relational` when the comparison is remembered but not trusted enough to narrow the value type.
4. `StatementEvaluator#eval_and_or` now types `a && b` as `union(narrow_falsey(a), b)` and `a || b` as `union(narrow_truthy(a), b)`, matching Ruby's skipped-LHS value semantics while preserving the existing RHS-entry narrowing and nil-injected post-scope join.
5. Class-membership narrowing now uses `Environment#class_ordering`, which consults the static registry and then `RbsLoader#class_ordering` over `RBS::Definition#ancestors`. Predicate narrowing no longer performs ad hoc `Object.const_get`; RBS-only project classes can participate in hierarchy narrowing without being loaded by the analyzer host.

Closure-captured-local invalidation remains deferred to Slice 6 phase C sub-phase 3; this sub-phase gives it the FactStore target/invalidation surface it needs.

### Slice 6 phase C — BlockNode parameter binding

The DefNode-aware scope builder (Slice 3 phase 2 follow-up) bound method parameters from RBS. This slice ships its symmetric counterpart for `Prism::BlockNode`.

**Sub-phase 1 (this sub-phase ships with this commit) — Block parameter binding driven by the receiving method's RBS signature.** Components added:

1. `Rigor::Inference::BlockParameterBinder` is a thin value object: `BlockParameterBinder.new(expected_param_types: [...])` consumes a per-position `Rigor::Type` array and produces a `name -> Type` binding map by walking `Prism::BlockParametersNode#parameters`. Required, optional, and trailing positionals are matched by index against the expected array; rest (`*r`), keyword (`k:`/`k: 0`), keyword rest (`**kw`), and explicit block (`&blk`) slots get conservative typed defaults (`Array[Dynamic[Top]]`, `Dynamic[Top]`, `Hash[Symbol, Dynamic[Top]]`, `Nominal[Proc]` respectively). MultiTargetNode destructuring (`|(a, b), c|`) and numbered parameters (`_1`/`_2`) are deferred. The binder MUST NOT raise on any well-formed Prism block node.
2. `Rigor::Inference::MethodDispatcher.expected_block_param_types(receiver_type:, method_name:, arg_types:, environment:)` is the canonical query that supplies the binder's `expected_param_types:` array. Internally it uses `RbsDispatch.block_param_types`, which selects an overload through the existing `OverloadSelector` (extended with a `block_required: true` flag so a block-bearing call does not bind through a no-block overload), pulls the `RBS::Types::Block#type` Function, and translates its `required_positionals + optional_positionals` parameters into `Rigor::Type` values. Generic substitution flows through the same `type_vars` map the return-type tier uses, so an `Elem` block parameter on `Array#each` resolves through the receiver's `type_args`. Union receivers degrade to the empty array unless every member yields the structurally equal block parameter list.
3. `Rigor::Inference::StatementEvaluator` adds a `Prism::CallNode` handler. The handler:
   - Asks the existing `Scope#type_of` for the call's value type (so the constant-folding / shape / RBS dispatch chain still applies and `MethodDispatcher.dispatch` is the single source of truth for return types).
   - Probes `MethodDispatcher.expected_block_param_types` for the call's expected block parameter array.
   - Builds the block's entry scope by augmenting the *outer* scope with the binder's bindings (Ruby's lexical scoping rule: blocks see outer locals; block parameters layer on top).
   - Recurses into the `Prism::BlockNode` (which has its own handler that delegates to `sub_eval(body, scope)`) so the per-node scope index sees the parameter bindings.
   - Returns the receiver scope unchanged. Block effects therefore do not leak into the post-call scope; locals bound exclusively inside the block are intentionally invisible on the outside until the closure-capture rules in [`control-flow-analysis.md`](../type-specification/control-flow-analysis.md) land.

Concrete behavioural uplift (verified through CLI smoke probes):

- `xs = [1, 2, 3]; xs.each { |x| y = x.succ }` types `y` as `Nominal[Integer]` inside the block (the block parameter `x` is bound to the tuple element union and `Integer#succ` resolves through dispatch). Pre-binding, `x` was unbound and `x.succ` fell through to `Dynamic[Top]`.
- `[1, 2, 3].map { |n| n + 1 }`'s receiver `n` types as the same tuple element union; `n + 1` therefore resolves through the constant-folding tier on each element type.
- `foo { |x| x }` — when the receiving call has no RBS signature, the binder defaults `x` to `Dynamic[Top]`, matching the Slice 3 phase 2 fail-soft posture.

Coverage on `rigor type-scan lib`: 13.6 % → **13.5 %** unrecognised (2 122 / 15 734 nodes; total node count grew because blocks are now visited through the StatementEvaluator's per-node scope index). The metric is dominated by Rigor's own constant references, which only RBS authoring (Candidate A) will move further.

**Sub-phase 2 (this sub-phase ships with this commit) — Destructuring block parameters, numbered parameters, and block-return-type-aware dispatch.** Components added:

1. `Rigor::Inference::BlockParameterBinder#bind_required_param` recognises `Prism::MultiTargetNode` block targets (`|(a, b), c|`) and delegates each destructuring slot to `Rigor::Inference::MultiTargetBinder` against the slot's expected element type. A `Type::Tuple` slot decomposes element-wise; any other carrier collapses every inner local to `Dynamic[Top]`. The inner targets are `Prism::RequiredParameterNode` instances on the block side; `MultiTargetBinder` handles them uniformly with their `Prism::LocalVariableTargetNode` cousins because both carry the same `name:` field and the same observable semantics.
2. `Rigor::Inference::BlockParameterBinder#bind_numbered_parameters` consumes `Prism::NumberedParametersNode` and materialises bindings for `:_1` through `:_maximum` driven by the same per-position `expected_param_types:` array used for explicit parameters. `[1, 2, 3].map { _1 + 1 }` now binds `_1` to the receiver's projected element type, so the body's `_1 + 1` still consults the dispatcher with the precise integer carriers.
3. `Rigor::Inference::MethodDispatcher.dispatch` honours its long-reserved `block_type:` keyword: when non-nil, `RbsDispatch.try_dispatch` selects a block-bearing overload (via `OverloadSelector` with `block_required: true`) and binds the method-level type parameter that the selected overload's block return type references to `block_type` before translating the return type. The wiring is intentionally narrow — only an exact `Variable` block-return shape participates — so signatures whose block return is an `untyped` function or a more elaborate type (e.g., a tuple, a structural shape) keep their previous fallback. `Array#map[U] { (Elem) -> U } -> Array[U]` is the canonical case the slice unblocks.
4. `Rigor::Inference::ExpressionTyper#call_type_for` becomes the single block-aware dispatch surface: when the call carries a `Prism::BlockNode`, it builds the same block-entry scope the StatementEvaluator would (`outer-scope + BlockParameterBinder.bind`), types the block body, and passes the body's type as `block_type:` into `MethodDispatcher.dispatch`. This makes the result-type uplift visible from every call site (`Scope#type_of`, `ScopeIndexer`, CLI `rigor type-of` / `rigor type-scan`) without requiring the StatementEvaluator to be in the loop. The StatementEvaluator's CallNode handler stays aligned: it delegates to `Scope#type_of` for the result type and only re-evaluates the block body for the per-node scope index.

Concrete behavioural uplift (verified through CLI smoke probes):

- `[1, 2, 3].map { |n| n.to_s }` types as `Array[String]` (was `Array[Dynamic[Top]]` projecting through the `Array[Elem]` shape).
- `[1, 2, 3].map { _1 + 1 }` types as `Array[Integer]`. Pre-binding the numbered parameter, `_1` would resolve as an unbound local and the block body collapsed to `Dynamic[Top]`.
- `arr.each_with_object({}) { |x, acc| acc[x] = true }` keeps its existing projection answer (the block return type is not a method-level type variable, so the `block_type:` participation falls through cleanly).

Closure-captured-local invalidation lands alongside the Slice 6 phase 2 FactStore work; it is out of scope for this sub-phase.

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
