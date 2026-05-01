# Current Work — Inference Engine Checkpoint

This document captures the state of the inference engine work-in-progress on
`impl/scope-type-of`. It is a transient bookmark used to break a long
implementation thread into reviewable chunks; the **normative** contracts and
slice roadmap remain in
[`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md)
and [`docs/adr/4-type-inference-engine.md`](adr/4-type-inference-engine.md). If
this file disagrees with either of those, the spec/ADR binds and this file is
out of date.

## Branch and Commit Trail

Branch: `impl/scope-type-of`. Slice landings (oldest → newest):

| Slice / Phase | Commit | One-line |
| --- | --- | --- |
| ADR + spec scaffold | `c0761cb` | ADR-4 and `inference-engine.md` introducing `Scope#type_of` |
| Slice 1 | `45b5a8b` | Literal typer with `Scope#type_of` |
| Slice 1 follow-up | `0ded72b` | `Rigor::AST::TypeNode` virtual-node infra |
| Slice 1 follow-up | `1d20f4c` | `FallbackTracer` for fail-soft observability |
| CLI probe | `5d6ff9c` | `rigor type-of FILE:LINE:COL` |
| CLI probe | `08b9ee9` | `rigor type-scan PATH...` coverage report |
| Slice 2 | `fd9793c` | Method dispatcher with constant-folding rule book |
| Slice 2 follow-up | `91b6260` | Typer broadens to constants, containers, definitions, writes |
| Slice 3 phase 1 | `a19ec1f` | Control-flow typing and `Scope#join` |
| Slice 4 phase 1 | `996ab5c` | RBS-backed method dispatch (core only, first-overload-wins) |
| Slice 4 phase 2a | `820cabb` | Project + stdlib RBS loading |
| Slice 4 phase 2b | `3693e7e` | Class-method (singleton) dispatch + `Singleton[T]` |
| Slice 4 phase 2c | `a152d45` | `Type#accepts` + overload-selecting dispatch |
| Slice 4 phase 2d | `9a49b8a` | Generics instantiation through `Nominal#type_args` |
| Slice 5 phase 1 | `e4b76bd` | `Tuple` and `HashShape` carriers + literal upgrades |
| Slice 3 phase 2 | `aed00d0` | `StatementEvaluator` threading scope across statements |
| Slice 3 phase 2 (CLI) | `84f2b01` | `type-of` and `type-scan` route through `ScopeIndexer` |
| Slice 3 phase 2 (DefNode) | `fe2fe7e` | DefNode-aware scope builder (`MethodParameterBinder`) |
| Slice 6 phase 1 | `6807a94` | Truthiness and `nil?` narrowing on `IfNode`/`UnlessNode` (`Rigor::Inference::Narrowing`) |
| Slice 5 phase 2 sub 1 | `04d112a` | Shape-aware element dispatch (`Rigor::Inference::MethodDispatcher::ShapeDispatch`) |
| Slice 6 phase C sub 1 | `13d587f` | BlockNode parameter binding (`Rigor::Inference::BlockParameterBinder`) |
| Slice 6 phase 2 sub 1 | `37eb158` | Class-membership narrowing (`is_a?`/`kind_of?`/`instance_of?`) |
| Slice 5 phase 2 sub 2 | `e7d0692` | Destructuring + multi-arg `dig` + `Hash#values_at` (`MultiTargetBinder`) |
| Slice 6 phase C sub 2 | `58f88dc` | Destructuring blocks + numbered params + `block_type:` (`Array#map { ... }` → `Array[T]`) |
| Slice 6 phase 2 sub 2 | `6bc38de` | Equality narrowing + `Rigor::Analysis::FactStore` |
| Slice 5 phase 2 sub 3 | `d1c6ba2` | Range/start-length tuple slices + HashShape policies |
| Slice 6 phase C sub 3a | `22c0a77` | `ClosureEscapeAnalyzer` + non-escaping/escaping core catalogue (pure query, no wiring yet) |
| Slice 6 phase C sub 3b | `54c9dcc` | `StatementEvaluator#eval_call` records `dynamic_origin` `closure_escape` facts on `:escaping` / `:unknown` block calls |
| Slice 6 phase C sub 3c | `8008020` | Drop narrowed type of captured-outer locals the block can rebind on `:escaping` / `:unknown` block calls |
| Slice A pass 1 | `295b6ae` | Author Rigor-side RBS for Type/Trinary/Scope/Environment/Analysis::FactStore/Inference/Source/AST |
| Slice A-engine | `f022b1a` | `Scope#self_type` + class/def body injection + `SelfNode` & implicit-self call typing (lib/ unrecognised: 13.8 % → 11.1 %) |
| Slice A pass 2 | `8171c80` | Per-method RBS for StatementEvaluator/ExpressionTyper/BlockParameterBinder/FactStore/Narrowing/Environment private helpers (lib/ unrecognised: 11.1 % → 10.5 %) |
| Slice A constant-walk | `60336be` | Lexical constant lookup in ExpressionTyper using `scope.self_type` (lib/ unrecognised: 10.5 % → 6.2 %) |
| Slice A constant-value | `7d2777b` | `Environment#constant_for_name` + `RbsLoader#constant_type` for non-class RBS constant decls (lib/ unrecognised: 6.2 % → 6.0 %) |
| Slice A stdlib | `d0096fc` | `Environment::DEFAULT_LIBRARIES` (pathname/optparse/json/yaml/fileutils/tempfile/uri/logger/date/prism/rbs) loaded by default in `for_project` (lib/ unrecognised: 6.0 % → 3.8 %) |
| Slice 7 phase 1 | `740573a` | Method-local ivar/cvar/global type bindings on `Scope`; `@x = 1; @x` reads as `Constant[1]` inside the same method |
| Slice A declarations | `8ec609e` | `Scope#declared_types` + `ScopeIndexer`-populated overrides for `module Foo` / `class Bar` headers (lib/ ConstantReadNode unrecognised: 7.0 % → 6.3 %) |
| Slice 7 phase 2 | `d1b424e` | Cross-method ivar tracking via class accumulator; `def init; @x = 1; end; def get; @x; end` resolves `@x` to `Constant[1]` |
| Slice 7 phase 3 | `970cf00` | Compound writes (`||=`, `&&=`, `+=`, ...) thread through scope for local/ivar/cvar/global with operator dispatch |
| Slice 7 phase 4 | `bbdac83` | Case-equality (`===`) narrowing for Class/Module receivers (is_a? isomorphism), Range literals (Numeric/String), Regexp literals (String) |
| Slice 7 phase 5 | `12898cd` | `Narrowing.case_when_scopes` + `eval_case` integration: each `when` body sees subject narrowed by the union of its conditions; the `else` sees the conjunction of falsey edges |
| Slice 7 phase 6 | `bdbdeac` | Cross-method cvar tracking + program-wide global accumulator (parallels Slice 7 phase 2 ivar accumulator) |
| Slice 7 phase 7 | `583a254` | `Scope#discovered_classes` populated by `ScopeIndexer`: references to user-defined classes resolve as `Singleton[T]` even without an RBS sig |
| Slice 7 phase 8 | `9237e36` | `rigor check` first preview: `Rigor::Analysis::CheckRules` flags "undefined method on typed receiver" + `Object#class` precise meta-introspection |
| Slice 7 phase 9 | `eea9bb6` | In-source constant value tracking via `Scope#in_source_constants`; `BUCKETS = [:a, :b]; BUCKETS.first` resolves to `:a` (lib/ ConstantReadNode 7.1 % → 0.8 %) |
| Slice 7 phase 10 | `b82e789` | Implicit-self defaults to `Object` + user-class ancestor fallback for Module/Kernel intrinsics; `attr_reader`/`require`/`private` etc. resolve (lib/ unrecognised 3.9 % → 3.2 %) |
| Slice 7 phase 11 | `fc1da90` | `rigor check` wrong-arity rule + Tuple/HashShape receiver projection in `CheckRules` |
| Slice 7 phase 12 | `fcb3820` | `Scope#discovered_methods` (def + define_method walk) suppresses check false positives on reopened classes |
| Slice 7 phase 13 | `db8eb2b` | First-preview README rewrite + commented `rigor init` template |
| Slice 7 phase 14 | `3c30082` | `rigor check` nil-receiver rule + early-return narrowing in `eval_if` / `eval_unless` |
| Slice 7 phase 15 | `e1f8172` | RBS::Extended predicate-effect reader + Narrowing integration (`rigor:v1:predicate-if-true/false`) |
| Slice 7 phase 16 | `03dbdb0` | First-preview polish: path-error diagnostics, summary line, Next Release plan |

## What is in Place Today

### Public CLI surface

- `rigor type-of FILE:LINE:COL` — probes `Scope#type_of` at a position and
  prints the recognised node class plus the inferred type and its RBS
  erasure. Routes through `ScopeIndexer` so locals bound earlier in the
  file flow into the probed scope.
- `rigor type-scan PATH...` — walks every Prism node in the given files and
  reports per-node-class coverage of `Scope#type_of`. Supports `--format=json`
  for tooling and `--threshold` for CI gating.
- `rigor check`, `rigor init`, `rigor version`, `rigor help` — pre-existing.

### Type model (carriers)

`Rigor::Type::*` ships:

- Lattice: `Top`, `Bot`, `Dynamic[T]`.
- Nominal: `Nominal[Class, type_args]`, `Singleton[Class]`.
- Literal: `Constant[v]`.
- Composite: `Union[A, B, ...]`.
- Shape (Slice 5): `Tuple[T1, ..., Tn]`, `HashShape[{ k1 => T1, ... }]`
  with required/optional/read-only key policy and open/closed extra-key
  policy.
- Trinary: `Rigor::Trinary` (`yes`/`no`/`maybe`).
- Acceptance result (Slice 4 phase 2c): `Rigor::Type::AcceptsResult`.

Combinator factories (`Rigor::Type::Combinator`) enforce deterministic
normalisation and are the only sanctioned way to construct types.

### Analysis facts

- `Rigor::Analysis::FactStore` — Slice 6 phase 2 sub-phase 2. Immutable
  fact bundle carried by each `Scope` snapshot. It defines target/fact
  value objects, the initial bucket vocabulary (`local_binding`,
  `captured_local`, `object_content`, `global_storage`, `dynamic_origin`,
  `relational`), target invalidation, and conservative joins that retain
  only facts present on both edges. `Scope#with_local` invalidates facts
  attached to the rebound local; equality predicates record either a
  `local_binding` fact (when the type narrows) or a `relational` fact
  (when the comparison is remembered but cannot safely narrow the value).

### Inference engine (`Rigor::Inference::*`)

- `ExpressionTyper` — pure dispatch from Prism nodes to types.
- `MethodDispatcher` — `ConstantFolding` (Slice 2) → `ShapeDispatch`
  (Slice 5 phase 2) → `RbsDispatch` (Slice 4) with `OverloadSelector`
  (phase 2c) and generics instantiation (phase 2d).
- `Acceptance` — shared `accepts(other, mode:)` logic across every type.
- `RbsTypeTranslator` — translates `RBS::Types::*` to `Rigor::Type`,
  including `Tuple`/`Record`/`Variable`.
- `FallbackTracer` + `Fallback` — fail-soft observability.
- `StatementEvaluator` — threads `[type, scope']` through statement-level
  control flow (`if`/`unless`/`case`/`begin`/`while`/`and`/`or`, locals,
  classes, modules, defs, singleton classes).
- `MethodParameterBinder` — translates a `DefNode`'s parameter list into a
  binding map driven by the surrounding class's RBS signature.
- `BlockParameterBinder` — Slice 6 phase C sub-phases 1 and 2
  symmetric counterpart for `Prism::BlockNode`. Consumes a
  per-position `expected_param_types:` array (supplied by
  `MethodDispatcher.expected_block_param_types`) and binds each
  named block parameter; rest / keyword-rest / `&blk` slots get
  conservative typed defaults. Sub-phase 2 expands the binder to
  destructure `MultiTargetNode` parameters (`|(a, b), c|`) through
  `MultiTargetBinder` and to bind `_1`/`_2`/... reads from
  `NumberedParametersNode`.
- `MultiTargetBinder` — Slice 5 phase 2 sub-phase 2 destructuring
  binder shared between `StatementEvaluator#eval_multi_write` and
  the future block-target path. Decomposes a `Type::Tuple`
  right-hand side element-wise (filling missing slots with
  `Constant[nil]`, binding the rest target as a `Tuple` of middle
  elements) and falls back to `Dynamic[Top]` per slot for non-Tuple
  carriers. Recurses into nested `MultiTargetNode` targets.
- `Narrowing` — Slice 6 phases 1 and 2.
  Exposes `narrow_truthy`/`narrow_falsey`/`narrow_nil`/`narrow_non_nil`
  type primitives, `narrow_class`/`narrow_not_class` (Slice 6 phase 2
  sub-phase 1), `narrow_equal`/`narrow_not_equal` (Slice 6 phase 2
  sub-phase 2), plus `predicate_scopes(node, scope)` which returns
  `[truthy_scope, falsey_scope]` for the recognised predicate
  catalogue (`LocalVariableReadNode`, `recv.nil?`, `!recv`,
  `recv.is_a?(C)`/`recv.kind_of?(C)`/`recv.instance_of?(C)`,
  `local == literal`/`literal == local` and the `!=` mirror,
  `ParenthesesNode`, `&&`/`||` composition). Class-membership shapes
  require a static constant argument and a local-read receiver; equality
  shapes require one local side and one trusted static literal side
  (`String`, `Symbol`, `Integer`, booleans, or `nil`; not `Float`).
  Anything else falls through to the no-narrowing branch.
- `ClosureEscapeAnalyzer` — Slice 6 phase C sub-phase 3a. Pure
  classification query
  `classify(receiver_type:, method_name:, environment:)` returning
  `:non_escaping`, `:escaping`, or `:unknown` for block-accepting
  calls. Ships a hardcoded RBS-blind catalogue of core iteration
  methods (Array/Hash/Range/Set/Integer/Enumerator/Object#tap/
  then/yield_self) as non-escaping and a small known-retainer set
  (`Module#define_method`, `Thread.new`/`start`/`fork`,
  `Fiber.new`, `Proc.new`) as escaping. Tuple→Array,
  HashShape→Hash, Constant→value-class. Sub-phase 3b wires it
  into `StatementEvaluator#eval_call`: `:escaping` and `:unknown`
  classifications attach a `dynamic_origin` `closure_escape`
  fact to the post-call scope (target
  `Target.new(kind: :closure, name: method)`, payload
  `{method_name:, classification:}`, `stability: :unstable`);
  `:non_escaping` leaves the fact_store untouched. Sub-phase 3c
  additionally drops the narrowed type of every captured outer
  local that the block body can rebind, replacing it with
  `Dynamic[Top]` through `Scope#with_local` (which also
  invalidates the local's `local_binding` facts). Captured
  outer locals are computed by walking `BlockNode#body` for
  `LocalVariableWriteNode`s whose name is in the call-site
  `Scope#locals` and is NOT introduced by the block (block
  parameters or `;`-prefixed block-locals). Read-only captures
  and parameter-shadowed names stay narrowed.
- `ScopeIndexer` — builds a per-node scope index for the CLI to consume.
- `CoverageScanner` — backs `type-scan`.

### Environment

- `Environment` — registry + RBS loader bundle.
- `Environment::ClassRegistry` — small whitelist of well-known core classes.
- `Environment::RbsLoader` — wraps `RBS::EnvironmentLoader`/`DefinitionBuilder`
  with project/stdlib loading and lazy memoisation. Supports
  `instance_method`, `singleton_method`, `class_type_param_names`, and
  `class_ordering` over `RBS::Definition#ancestors`.

### Source helpers

- `Source::NodeLocator` — `(line, column)` to deepest enclosing Prism node.
- `Source::NodeWalker` — DFS pre-order over every Prism node.

## Verification Status

- **RSpec**: 815 examples, 0 failures across the full Slice 7
  series (phases 1 → 7) and the Slice A series (pass 1 → stdlib
  → declarations).
- **RuboCop**: `make lint` is clean. `.rubocop.yml` excludes the whole
  `references/` tree so upstream submodules are not linted as Rigor
  product code.
- **`rigor type-scan lib`**: 4.2 % unrecognised after Slice 7
  phase 7, down from 13.8 % at the start of the Slice A series.
  ConstantPathNode 0.1 % (1/678); ConstantReadNode 7.1 %
  (90/1264); CallNode 22.5 % (875/3885). The remaining tail is
  dominated by Module-level intrinsics (`require_relative`,
  `raise`, `private`, `private_constant`, `module_function`,
  `freeze`) and parameter receivers whose static type is
  `Dynamic[Top]` until per-method RBS for the corresponding
  internal helpers is authored.
- **`rigor type-of` smoke probe (DefNode binder)**:
  `class Integer; def divmod(other); other; end; end` — `other` reads as
  `Float | Integer | Numeric | Rational` inside the body.
- **`rigor type-of` smoke probe (Slice 5 phase 2 shape dispatch)**:
  `xs = [10, 20, 30]; xs[0]` types as `Constant[10]`;
  `xs[-1]` types as `Constant[30]`; `xs.size` types as `Constant[3]`.
  `h = { name: "Alice", age: 30 }; h[:name]` types as `Constant["Alice"]`;
  `h.fetch(:age)` types as `Constant[30]`.
- **`rigor type-of` smoke probe (Slice 6 phase 1 narrowing)**:
  `xs = [1, 2, nil]; y = xs.first; result = if y.nil?; "got nil"; else; y; end; result`
  types `result` as `"got nil" | 1` (with shape-aware dispatch
  `xs.first` resolves to `Constant[1]`, narrowing then drops the
  `nil` contribution from the else branch).
- **`rigor type-of` smoke probe (Slice 6 phase C block binding)**:
  `xs = [1, 2, 3]; xs.each do |x|; y = x.succ; end` — `y` types as
  `Nominal[Integer]` inside the block (the block parameter `x` binds
  to the tuple element union and `Integer#succ` resolves through
  dispatch). Pre-binding `x` was unbound and `x.succ` fell through
  to `Dynamic[Top]`.
- **`rigor type-of` smoke probe (Slice 6 phase C sub-phase 2
  block-return-type uplift)**:
  `[1, 2, 3].map { |n| n.to_s }` types as `Array[String]` (was
  `Array[Dynamic[Top]]` projecting through `Array[Elem]`).
  `[1, 2, 3].map { _1 + 1 }` types as `Array[Integer]` — the
  numbered parameter binds to the projected element type, the
  block returns `Integer`, and the dispatcher resolves
  `Array#map`'s `U` to `Integer`. `pairs = [[1, "a"], [2, "b"]];
  pairs.map { |(i, _)| i }` still collapses to `Array[Dynamic[Top]]`
  because the block parameter slot is a `Union[Tuple, Tuple]`
  rather than a single `Tuple`; that case waits on the
  Union-aware destructuring follow-up.
- **`rigor type-of` smoke probe (Slice 5 phase 2 sub-phase 2
  destructuring + chain dig)**:
  `pair = [10, 20]; a, b = pair; sum = a + b` — `sum` types as
  `Constant[30]` (destructuring binds `a`/`b` element-wise from
  the tuple; `+` constant-folds across the precise members).
  `users = { addr: { zip: "00100" } }; users.dig(:addr, :zip)`
  types as `Constant["00100"]` (chain dig walks into the inner
  HashShape). `{ a: 1, b: "two" }.values_at(:a, :b)` types as
  `Tuple[Constant[1], Constant["two"]]`.
- **`rigor type-of` smoke probe (Slice 5 phase 2 sub-phase 3
  range/start-length slices + HashShape policies)**:
  `xs = [1, 2, 3]; xs[1, 2]` and `xs[1..]` both type as
  `Tuple[Constant[2], Constant[3]]`. Static nil slices such as
  `xs[4..5]` resolve to `Constant[nil]`. RBS records with optional
  fields now translate to closed `HashShape` values with optional
  keys, optional-key `[]`/`dig` reads include `nil`, and closed
  HashShape acceptance rejects extra/open sources.
- **`rigor type-of` smoke probe (Slice 6 phase 2 sub-phase 1
  class-membership narrowing)**:
  `def f(x); if x.is_a?(Integer); x; else; x; end; end` — the
  then-branch read of `x` (line 3 col 5) types as `Integer` (the
  `Dynamic[Top]` parameter narrows DOWN to the asked class on the
  truthy edge); the else-branch read (line 5 col 5) stays at
  `Dynamic[Top]` because the analyzer cannot prove the disjunction
  without a richer carrier. On a richer bound type
  (`Nominal[Numeric]` or `Union[Integer, String]`) the same
  predicate narrows precisely on both edges, which is exercised
  through the spec suite.
- **`rigor type-of` smoke probe (Slice 6 phase 2 sub-phase 2
  equality narrowing)**:
  `x = ["a", "b"].first; result = if x == "a"; x; else; x; end; result`
  narrows the then branch to `Constant["a"]` and the else branch to
  `Constant["b"]` when the receiver domain is a finite trusted
  literal union. `x == nil` similarly extracts `nil` from
  `Integer | nil`. `Dynamic[Top] == "a"` records a relational fact
  but keeps the local as `Dynamic[Top]`, honoring the rule that
  equality must not manufacture a positive literal domain from an
  unchecked receiver.

## Known Boundaries (Deliberate, Not Bugs)

These follow from the slice roadmap; each has a planned slice that lifts it.

1. **Expression-interior scope threading**: `foo(x = 1)` and `[1, x = 2]`
   do not propagate `x` to the post-scope. The StatementEvaluator does not
   recurse into call arguments or array/hash element interiors.
2. **Block parameter binding**: covered for the curated catalogue through
   Slice 6 phase C sub-phases 1 and 2
   (`Rigor::Inference::BlockParameterBinder`), driven by the receiving
   method's RBS block signature through
   `MethodDispatcher.expected_block_param_types`. Destructuring block
   targets (`|(a, b), c|`), numbered parameters (`_1`/`_2`), and the
   block-return-type-aware dispatch are in place. Union-aware destructuring
   for block parameters (for example a `Union[Tuple, Tuple]` slot) remains
   a follow-up.
3. **Equality trust boundaries**: equality predicates now narrow only
   on the deliberately small trusted surface from
   [`control-flow-analysis.md`](type-specification/control-flow-analysis.md):
   finite literal domains for `String`, `Symbol`, and `Integer`, plus
   singleton extraction for `nil`, `true`, and `false`. `Float`
   literals, broad nominal domains (`String`, `Integer`, ...),
   user-defined equality, `eql?`, `===`, and `Dynamic[Top]` comparisons
   stay relational-only until RBS/plugin-declared flow effects land.
4. **Shape narrowing on dispatch**: covered for the curated
   element-access catalogue (Slice 5 phase 2 sub-phase 1),
   destructuring assignment, multi-arg `dig` chains, `Hash#values_at`
   (Slice 5 phase 2 sub-phase 2), and tuple range/start-length `[]`
   plus HashShape required/optional/closed/read-only policies (Slice 5
   phase 2 sub-phase 3). Mutation methods, read-only write diagnostics,
   and typed extra-key bounds remain follow-ups for the effect model.
5. **RBS interface / alias degradation**: types like `int` and `_ToS`
   currently translate to `Dynamic[Top]`. Refining this would tighten
   parameter bindings for many core methods (`Array#first(n)`, etc.).
6. **No Rigor-authored RBS for itself**: `sig/rigor/**/*.rbs` is essentially
   empty. The dominant `ConstantReadNode`/`ConstantPathNode`/`CallNode`
   unrecognised mass on `type-scan lib` is calls and references against
   Rigor's own classes; writing those signatures would move the metric
   substantially.
7. **Cross-method ivar / cvar / global bindings**: Slice 7 phase 1
   binds writes within a single method body, so `@x = 1; @x` reads as
   `Constant[1]` inside the same method. Reads in other methods of
   the same class still observe `Dynamic[Top]`; an instance-level
   binding map keyed by `self_type`'s qualified class name is a
   follow-up slice.
8. **Method-call return-type narrowing on receiver shape**: covered for
   generics on `Nominal[T]`, not yet for narrowing through `Dynamic[T]`'s
   static facet beyond the Slice 4 phase 2c overload selection.

## Specs and Documentation Authoritative Pointers

- Public type semantics: [`docs/type-specification/`](type-specification/).
- Internal type-object contract: [`docs/internal-spec/internal-type-api.md`](internal-spec/internal-type-api.md).
- Inference engine contract: [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md).
- Decision records: [`docs/adr/`](adr/) (ADR-1 = type model, ADR-3 = type
  representation, ADR-4 = inference engine).

## First Preview Status

The branch has reached a **first preview**. The intent of the
preview is concrete: a user can point `rigor` at a real Ruby
project, get diagnostics back, and have the analyzer survive
the round-trip. It is NOT a complete static-typing solution;
the [Next Release](#next-release) section below names the
specific gaps a v0.0.2 preview must close.

Concrete preview deliverables:

- **`rigor check`** end-to-end pipeline: parse → scope index →
  three rule catalogue. Surfaces real diagnostics on real
  projects, exits 1 on any error, prints a one-line summary.
  Missing paths produce an explicit diagnostic instead of
  silently passing.
- **`rigor type-of`** + **`rigor type-scan`** for inspection
  and coverage probing.
- **`rigor init`** writes a header-commented `.rigor.yml`.
- Engine resolves the bulk of canonical Ruby surface: locals,
  ivars / cvars / globals (intra- and cross-method), `self`
  typing, lexical constant lookup, predicate narrowing
  (`is_a?` / `==` / `===` / `case`-`when`), block parameter
  binding, closure escape, Tuple / HashShape carriers, and
  `RBS::Extended` predicate effects (first-preview subset).
- 846 RSpec examples / 0 failures, RuboCop clean.
  `rigor type-scan lib` reports 3.2 % unrecognised on
  Rigor's own tree (down from 13.8 % at the start of the
  Slice A series).
- Smoke probe (representative Ruby project with typed bugs):
  `rigor check` flags exactly the planted wrong-arity and
  undefined-method bugs while ignoring legitimate calls
  (early-return guards, `attr_reader`-derived methods,
  `define_method` etc.).

## Known Limitations of the First Preview

- `rigor check` ships three rules: undefined method on typed
  receiver, wrong number of arguments, possible nil receiver.
  Other rule families (type-incompatible writes, unbound
  locals, unreachable branches, return-type mismatch) remain
  on the roadmap. Severity is hard-coded to `:error`; per-rule
  severity configuration is future work.
- The nil-receiver rule fires only on
  `Prism::LocalVariableReadNode` receivers; chained / method-
  call receivers are silently skipped because the engine cannot
  flow-narrow them yet.
- Per-method RBS for Rigor itself covers the heavy internal
  paths but does not enumerate every helper. New private
  helpers added in subsequent slices may briefly fall through
  to `Dynamic[Top]` until their RBS signature is added.
- Cross-method instance state precision: rvalue typing during
  the per-class ivar/cvar pre-pass has no local context, so
  `@x = some_local + 1` records `Dynamic[Top]`. Direct literal
  writes record their precise constant.
- `RBS::Extended` ships the predicate-effect surface only
  (`predicate-if-true` / `predicate-if-false`). `assert`,
  `assert-if-true`, `assert-if-false`, `param`, `return`,
  `conforms-to`, negation (`~T`), and intersection/union
  refinements are deferred to v0.0.2.
- No persistent cache. Every `rigor check` run re-parses and
  re-types the project. The configuration file already has a
  `cache.path` slot; the cache implementation is v0.0.2 work.
- No plugin contribution layer. Only the bundled `RBS::Extended`
  reader can contribute analyzer behavior past ordinary RBS.

## Next Release (v0.0.2)

Captured here so the first-preview surface stays focused. The
items are listed roughly by user-visible value, not by
implementation order.

### Engine + RBS::Extended

1. **`assert` / `assert-if-true` / `assert-if-false` directives**
   — extend `Rigor::RbsExtended` to recognise the assertion
   directives from `docs/type-specification/rbs-extended.md`,
   then wire them into `StatementEvaluator` so a method call
   refines its target after returning. Required for
   `must_be_string!` / `validate!` patterns.
2. **Negation in predicate / assert types (`~T`)** — extend
   the `RBS::Extended` parser and `Narrowing.narrow_class` /
   `Narrowing.narrow_not_class` so a directive like
   `predicate-if-true value is ~NilClass` produces the
   non-nil edge.
3. **`self`-targeted predicate effects actually narrow** —
   today the parser accepts `target: self` but the engine
   discards the effect. v0.0.2 should mutate the receiver
   scope's `self_type` on the matching edge.
4. **More `check` rules**: type-incompatible argument (uses
   `Acceptance`), return-type mismatch, unreachable
   branches, unused locals, redundant nil checks.
5. **Inter-procedural inference for user-defined methods** —
   pinned by `spec/integration/fixtures/user_methods.rb`. A
   class with `def is_odd(n) = n.odd?` currently surfaces as
   `Dynamic[top]` at the call site because the engine has no
   return-type inference for user methods (the body's
   `n.odd?` types correctly inside the def, but the type is
   not propagated to the caller). The companion
   `user_methods_with_sig/` fixture proves the dispatch path
   works once a sig is supplied; v0.0.2 should reuse the
   same dispatch but with engine-inferred return types so
   users do not need to author RBS for every helper.
   Approach: a per-method type cache populated by walking
   `Prism::DefNode` bodies in topological order (or with a
   fixed-point iteration for recursion).
6. **Per-rule severity + suppression**: project-level
   `.rigor.yml` rule toggles, in-source `# rigor:disable`
   comments, severity downgrade.

### CLI + workflow

7. **Persistent analysis cache** — wire the `cache.path`
   config slot through to a per-file analysis cache so
   subsequent `rigor check` runs only re-analyze changed
   files.
8. **Configuration: `libraries:` and `signature_paths:`
   passthrough** — `.rigor.yml` keys that reach
   `Environment.for_project` so users can extend the
   stdlib bundle without touching code.
9. **Plugin contribution layer** per ADR-2 — load
   user-supplied Ruby files that register additional
   `CheckRules` or RBS shim methods.
10. **Diagnostic publication of `FallbackTracer` events** —
    optional `--explain` mode surfacing where the engine
    degraded to `Dynamic[Top]`.

### Documentation + adoption

11. **Quickstart on a real Rails / sinatra-style app** —
    expanded README walkthrough including dependency RBS
    onboarding and recommended `paths:` / sig layout.
12. **`rigor check` rule reference** — per-rule docs with
    canonical examples, false-positive guidance, and the
    suppressing comment syntax.

## Future Roadmap (v0.0.3 and beyond)

Items captured here are not in the v0.0.2 commitment. They
get scheduled as an explicit version pick when the v0.0.2
surface ships.

### Aggressive constant folding through user methods

When a user-defined method's body is a single expression
whose all inputs are `Constant[v]` at the call site, the
result should fold to a `Constant` rather than the RBS-
declared widened type. Pinned by:

```ruby
class Parity
  def is_odd(n)
    n.odd?
  end
end

# Today (v0.0.2):
Parity.new.is_odd(3)   # => `false | true`
3.odd?                  # => `false | true`

# Wanted (v0.0.3+):
Parity.new.is_odd(3)   # => `Constant[true]`
3.odd?                  # => `Constant[true]`
```

Two prerequisites:

1. **Stdlib `pure` summary catalogue.** A whitelist of
   stdlib methods that the analyzer can evaluate at static
   time when every receiver / argument is `Constant`.
   `Integer#odd?` / `#even?`, `String#upcase` / `#downcase`
   on literal strings, `Array#first` / `#size` on literal
   tuples (the existing `ShapeDispatch` already handles
   the last category, so the framework is in place — what
   is missing is the per-method dispatch into MRI for
   pure scalar methods). `ConstantFolding` is the natural
   home; the catalogue would mirror its existing
   per-method whitelist.

2. **Constant propagation through user-method inference.**
   Slice 7 / v0.0.2 #5 already re-types the body with the
   call's argument `Constant`s bound to the parameters.
   Once #1 lands, the body's last expression
   (`n.odd?`) folds to `Constant[true]` automatically and
   the existing inter-procedural path returns the
   propagated `Constant`.

The work is gated on the stdlib pure-summary work because
constant folding at the engine level only fires when the
operation is on the curated whitelist. Without the
whitelist, `Constant[3].odd?` falls through to the RBS
return type `bool` which is the v0.0.2 ceiling.

This complements but does NOT subsume `RBS::Extended`'s
predicate / assert directives — those refine the *call
site*'s edges, not the call's *return value*. A future
slice could combine the two: a pure-summary catalogue
backed by user-supplied annotations
(`%a{rigor:v0.0.3:pure}`) so projects can opt their own
methods into the constant-folding path.
