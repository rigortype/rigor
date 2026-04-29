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
| Slice 6 phase C sub 1 | `23a8332` | BlockNode parameter binding (`Rigor::Inference::BlockParameterBinder`) |

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
- Shape (Slice 5 phase 1): `Tuple[T1, ..., Tn]`, `HashShape[{ k1 => T1, ... }]`.
- Trinary: `Rigor::Trinary` (`yes`/`no`/`maybe`).
- Acceptance result (Slice 4 phase 2c): `Rigor::Type::AcceptsResult`.

Combinator factories (`Rigor::Type::Combinator`) enforce deterministic
normalisation and are the only sanctioned way to construct types.

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
- `BlockParameterBinder` — Slice 6 phase C sub-phase 1 symmetric
  counterpart for `Prism::BlockNode`. Consumes a per-position
  `expected_param_types:` array (supplied by
  `MethodDispatcher.expected_block_param_types`) and binds each
  named block parameter; rest / keyword-rest / `&blk` slots get
  conservative typed defaults.
- `Narrowing` — Slice 6 phase 1 truthiness and `nil?` narrowing.
  Exposes `narrow_truthy`/`narrow_falsey`/`narrow_nil`/`narrow_non_nil`
  type primitives plus `predicate_scopes(node, scope)` which returns
  `[truthy_scope, falsey_scope]` for the recognised predicate
  catalogue (`LocalVariableReadNode`, `recv.nil?`, `!recv`,
  `ParenthesesNode`, `&&`/`||` composition).
- `ScopeIndexer` — builds a per-node scope index for the CLI to consume.
- `CoverageScanner` — backs `type-scan`.

### Environment

- `Environment` — registry + RBS loader bundle.
- `Environment::ClassRegistry` — small whitelist of well-known core classes.
- `Environment::RbsLoader` — wraps `RBS::EnvironmentLoader`/`DefinitionBuilder`
  with project/stdlib loading and lazy memoisation. Supports
  `instance_method`, `singleton_method`, `class_type_param_names`.

### Source helpers

- `Source::NodeLocator` — `(line, column)` to deepest enclosing Prism node.
- `Source::NodeWalker` — DFS pre-order over every Prism node.

## Verification Status

- **RSpec**: 608 examples, 0 failures (as of the Slice 6 phase C sub-phase 1 work).
- **RuboCop**: pre-existing offences in `references/` submodules only;
  0 in Rigor product code.
- **`rigor type-scan lib`**: 13.5 % unrecognised (2 122 / 15 734 nodes).
  Top contributors:
  - `Prism::CallNode` 928 / 2 617 (35.5 %)
  - `Prism::ConstantReadNode` 711 / 958 (74.2 %)
  - `Prism::ConstantPathNode` 480 / 481 (99.8 %)
  - `Prism::MultiTargetNode` 3 / 3 (100.0 %)
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

## Known Boundaries (Deliberate, Not Bugs)

These follow from the slice roadmap; each has a planned slice that lifts it.

1. **Expression-interior scope threading**: `foo(x = 1)` and `[1, x = 2]`
   do not propagate `x` to the post-scope. The StatementEvaluator does not
   recurse into call arguments or array/hash element interiors.
2. **Block parameter binding**: covered for the curated catalogue in
   Slice 6 phase C sub-phase 1
   (`Rigor::Inference::BlockParameterBinder`), driven by the receiving
   method's RBS block signature through
   `MethodDispatcher.expected_block_param_types`. Destructuring block
   targets (`|(a, b), c|`), numbered parameters (`_1`/`_2`), and the
   block-return-type-aware dispatch (so `[1, 2, 3].map { |n| n.to_s }`
   types as `Array[String]`) are deferred to sub-phase 2.
3. **Class-membership and equality narrowing**: `is_a?`/`kind_of?`/
   `instance_of?` and equality predicates (`x == "literal"`,
   `x == nil`, ...) do not yet narrow. This is Slice 6 phase 2
   territory; phase 1 already covers truthiness and `nil?` narrowing
   on local bindings, plus the unary `!` inverter and short-circuit
   `&&`/`||` composition. Class- and equality-based narrowing follow
   the same `[truthy_scope, falsey_scope]` analyser shape.
4. **Shape narrowing on dispatch**: covered for the curated
   element-access catalogue in Slice 5 phase 2 sub-phase 1
   (`Tuple#[i]`, `tuple.first`/`last`, `tuple.size`, `HashShape#[k]`,
   `shape.fetch(:k)`, `shape.dig(:k)`). Destructuring assignment
   (`a, b = tuple`), multi-arg `dig`, range / start-length forms of
   `[]`, and the Rigor-extension hash-shape policies are still
   deferred to Slice 5 phase 2 sub-phase 2.
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

The picks below are ordered by my best estimate of how much they move the
overall analyzer forward. Each one is a self-contained, reviewable slice on
top of the current branch.

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

### B. Slice 5 phase 2 sub-phase 2 — Destructuring + shape extras

Sub-phase 1 (this commit) ships `ShapeDispatch` for the curated
element-access catalogue (`Tuple#[i]`, `tuple.first`/`last`,
`tuple.size`, `HashShape#[k]`, `shape.fetch(:k)`, `shape.dig(:k)`).
Sub-phase 2 wires `Prism::MultiWriteNode` into `StatementEvaluator`
so `a, b = tuple` binds each target to the matching tuple element
type, extends `ShapeDispatch` with multi-arg `dig`, range and
start-length forms of `[]`, and `Hash#values_at`, and starts the
Rigor-extension hash-shape policies (required/optional/closed-extra-key,
read-only entries) per [`rigor-extensions.md`](type-specification/rigor-extensions.md).

- **type-scan impact**: small on `lib/`, medium on user code that
  destructures or uses `dig`/`values_at`.
- **engine impact**: medium — adds a `MultiWriteNode` handler to
  `StatementEvaluator` and a small extension to `ShapeDispatch`.
- **risk**: low; the shape dispatch infrastructure and `Tuple`/`HashShape`
  carriers are in place.

### C. Slice 6 phase C sub-phase 2 — Destructuring blocks + block return type

Sub-phase 1 (this commit) ships block parameter binding for the
flat-positional / rest / keyword catalogue, driven by the receiving
method's RBS signature. Sub-phase 2:

- Walks `MultiTargetNode` block targets (`|(a, b), c|`) and binds each
  component element-wise from the expected parameter type (Tuple
  destructuring projects to per-position members).
- Wires numbered parameters (`_1`, `_2`, ...) so their reads see the
  same types as the implicit positional bindings.
- Threads the block's *return type* into `MethodDispatcher.dispatch`
  through the reserved `block_type:` keyword so
  `[1, 2, 3].map { |n| n.to_s }` types as `Array[String]` rather than
  the projected `Array[Elem]`.
- Adds closure-captured-local invalidation alongside the Slice 6
  phase 2 FactStore work.

- **type-scan impact**: small to medium — most blocks are flat
  positionals already covered by sub-phase 1; sub-phase 2 mostly
  improves the precision of receiver / Array / Enumerable-chained
  receivers.
- **engine impact**: medium — the block-return-type uplift is a
  cross-cut between `MethodDispatcher` and `StatementEvaluator`.
- **risk**: medium; closure invalidation needs careful interaction
  with the FactStore.

### D. Slice 6 phase 2 — Class-membership and equality narrowing

Phase 1 (this commit) ships truthiness and `nil?` narrowing. Phase 2
extends the predicate analyser with `is_a?`/`kind_of?`/`instance_of?`
class-membership predicates and trusted equality narrowing for finite
literal sets per [`docs/type-specification/control-flow-analysis.md`](type-specification/control-flow-analysis.md), plus the formal `Rigor::Analysis::FactStore`
that drives heap and relational facts. Phase 2 also lifts
`eval_and_or`'s value type from `union(left, right)` to a narrowing-
aware `union(narrow_falsey(left), right)` for `&&` (and the symmetric
form for `||`).

- **type-scan impact**: small to medium (most narrowing happens on
  already-typed receivers; the unrecognised count is dominated by
  other things).
- **engine impact**: medium — extends the predicate-analyser
  catalogue and adds the `FactStore` scaffolding.
- **risk**: medium; equality trust levels and closure-capture
  invalidation need careful handling per the control-flow-analysis
  spec.

### Recommended ordering

The user-priority ordering for this branch is **D → B → C → A**:
Slice 6 phase 1 (the truthiness/`nil` half of D), Slice 5 phase 2
sub-phase 1 (the dispatch half of B), and Slice 6 phase C
sub-phase 1 (the block-parameter half of C) are all already in.
The next candidates are sub-phase 2 of B (destructuring + shape
extras), sub-phase 2 of C (destructuring blocks + block return type),
and Slice 6 phase 2 (class-membership / equality narrowing + the
formal FactStore). A — authoring Rigor-side RBS for Rigor itself —
remains the largest single lever for the `type-scan lib` metric.
