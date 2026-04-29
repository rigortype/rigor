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
  will consume the fact to drop narrowed types of captured
  locals.
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

- **RSpec**: 752 examples, 0 failures (Slice 6 phase C sub-phase
  3b working tree; the +17 over `d1c6ba2`'s 730 are
  `closure_escape_analyzer_spec.rb` and the +5 over 3a are the
  3b "closure escape fact recording" group in
  `statement_evaluator_spec.rb`).
- **RuboCop**: `make lint` is clean. `.rubocop.yml` excludes the whole
  `references/` tree so upstream submodules are not linted as Rigor
  product code.
- **`rigor type-scan lib`**: ~13.8 % unrecognised. The block-return-type
  uplift mostly affects user code that calls `Array#map`/`select`/
  `flat_map` with literal blocks; `lib/` itself does not depend
  heavily on this pattern, so the lib-side coverage stays nearly flat.
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
7. **Untyped writes to ivars / cvars / globals**: `@x = 1` writes are
   typed but do not add a binding to a (nonexistent) ivar scope. Slice 7+.
8. **Method-call return-type narrowing on receiver shape**: covered for
   generics on `Nominal[T]`, not yet for narrowing through `Dynamic[T]`'s
   static facet beyond the Slice 4 phase 2c overload selection.

## Specs and Documentation Authoritative Pointers

- Public type semantics: [`docs/type-specification/`](type-specification/).
- Internal type-object contract: [`docs/internal-spec/internal-type-api.md`](internal-spec/internal-type-api.md).
- Inference engine contract: [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md).
- Decision records: [`docs/adr/`](adr/) (ADR-1 = type model, ADR-3 = type
  representation, ADR-4 = inference engine).

## Candidate Next Steps

Slice 5 phase 2 sub-phase 3 is now in the working tree, and Slice 6 phase 2
sub-phase 2 is committed as `6bc38de`. The remaining self-contained follow-up
order is **C → A**: closure-captured-local invalidation first, then Rigor-side
RBS authoring for the largest `type-scan lib` metric win.

### A. Author Rigor-side RBS for Rigor itself

Write `sig/rigor/**/*.rbs` for the public surface of `Rigor::Type::*`,
`Rigor::Trinary`, `Rigor::Inference::*`, `Rigor::Environment`, etc. The
project loader (Slice 4 phase 2a) already picks `sig/` up automatically.

- **type-scan impact**: high — every unrecognised
  `ConstantReadNode`/`ConstantPathNode`/`CallNode` against a `Rigor::*`
  receiver would resolve. Plausible to push `lib/` from 13.47 % to single
  digits.
- **engine impact**: low (no new code paths) but big precision wins for
  any future analysis on Rigor itself.
- **risk**: documentation-flavoured work, mostly mechanical.

### B. Completed in working tree — Slice 5 phase 2 sub-phase 3

Sub-phase 1 (already in) shipped `ShapeDispatch` for element access;
sub-phase 2 added destructuring assignment, multi-arg `dig` chains,
and `Hash#values_at`. Sub-phase 3 now extends `ShapeDispatch` to
recognise `tuple[start, length]` and `tuple[range]` (returning a
sliced `Tuple`), introduces the required/optional/closed-extra-key and
read-only HashShape policies per [`rigor-extensions.md`](type-specification/rigor-extensions.md),
and wires the policies through `Acceptance` so a closed shape rejects
extra/open sources.

- **type-scan impact**: small on `lib/`, medium on user code that
  slices arrays by range or uses the closed-extra-key policy.
- **engine impact**: landed in the working tree — adds slice handlers
  to `ShapeDispatch`, introduces policy fields on `HashShape`, and
  threads them through `Acceptance`.
- **remaining risk**: low; full-suite verification and lint are clean
  for the working tree.

### C. Slice 6 phase C sub-phase 3 — Closure-captured-local invalidation

Sub-phase 1 shipped block parameter binding driven by the receiving
method's RBS signature; sub-phase 2 added destructuring block
targets (`|(a, b), c|`), numbered-parameter binding (`_1`,
`_2`, ...), and the `block_type:` uplift so `Array#map { ... }`
resolves the method-level type variable from the block's return
type. Sub-phase 3 adds closure-captured-local invalidation: when a
block escapes its enclosing scope (passed to a method that retains
the closure, returned as a method value, ...) the analyzer MUST
drop the narrowed type of every captured local at the call boundary
so a subsequent read inside the closure observes the conservative
type rather than a stale narrowed binding.

Split into 3a → 3b → 3c:

- **3a (working tree)**: `Rigor::Inference::ClosureEscapeAnalyzer`
  pure classification with a hardcoded core-and-stdlib catalogue.
  Returns `:non_escaping`/`:escaping`/`:unknown`. Not wired into
  any consumer yet — landing the query first lets 3b/3c be
  reviewed as small, focused diffs.
- **3b**: Wire the analyzer into `StatementEvaluator#eval_call`
  and add a `FactStore` interaction that records the
  "escaped" capability fact in the `dynamic_origin` bucket.
- **3c**: At the call boundary for `:escaping` / `:unknown`
  outcomes, drop the narrowed type of every captured local that
  the block can rebind (collected via a block-body
  `LocalVariableWriteNode` walk) so subsequent reads after the
  call observe the conservative join.

- **type-scan impact**: small on `lib/`; medium on user code that
  relies on heavy block usage with locals captured from the
  enclosing method.
- **engine impact**: medium — needs a closure-escape detector and
  a fact-store interaction to record the invalidation.
- **risk**: medium; the invalidation must compose cleanly with the
  Slice 6 phase 2 sub-phase 2 equality narrowing.

### D. Completed in commit `6bc38de` — Slice 6 phase 2 sub-phase 2

Phase 2 sub-phase 2 is committed. It adds
trusted equality narrowing for finite literal sets per
[`docs/type-specification/control-flow-analysis.md`](type-specification/control-flow-analysis.md),
the formal `Rigor::Analysis::FactStore`, narrowing-aware `&&`/`||`
value types, and registry/RBS-loader-backed hierarchy lookup for
class-membership predicates.

- **type-scan impact**: small to medium (most narrowing happens on
  already-typed receivers; the unrecognised count is dominated by
  other things).
- **engine impact**: landed — predicate analysis now covers the
  trusted equality surface and `Scope` snapshots carry fact stores.
- **remaining risk**: closure-capture invalidation still needs its
  follow-up slice; equality itself remains intentionally narrow.

### Recommended ordering

After the Slice 5 phase 2 sub-phase 3 working-tree changes, the
remaining user-priority ordering is **C → A**. Closure-captured-local
invalidation is now unblocked by the FactStore. A — authoring
Rigor-side RBS for Rigor itself — remains the largest single lever for
the `type-scan lib` metric.
