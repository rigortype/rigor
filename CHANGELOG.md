# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

In-progress v0.0.4 surfaces. Two themes so far:

1. **OQ3 predicate-subset refinements.** `Type::Refined` carrier
   plus the first six imported built-in predicate names, end-to-end
   with `RBS::Extended`'s `rigor:v1:return:` directive, the
   acceptance tier, and the case-fold projection pair.
2. **Hash / Range / Set built-in catalog imports.** Three more core
   classes feed the constant-fold dispatcher; the extractor learned
   to recognise struct-defined registrations along the way.

### Added

#### `Type::Refined` carrier and the predicate catalogue

- **`Type::Refined` carrier (OQ3 predicate-subset half).** Sibling
  of `Type::Difference`, wraps `(base, predicate_id)` where
  `predicate_id` is a Symbol drawn from `Type::Refined::PREDICATES`.
  Construction goes through `Type::Combinator.refined(base,
  predicate_id)` and the per-name factories listed below. RBS
  erasure folds the carrier back to its base nominal so the
  round-trip to ordinary RBS is unaffected.
- **Six imported built-in predicate refinements.** `lowercase-string`,
  `uppercase-string`, `numeric-string`, `decimal-int-string`,
  `octal-int-string`, and `hex-int-string` ship with the carrier.
  `:numeric` matches plain decimal integer or fraction strings;
  `:decimal_int` matches one or more decimal digits with an optional
  leading sign; `:octal_int` and `:hex_int` REQUIRE their
  conventional prefix (`0o` / `0O` / leading `0`; `0x` / `0X`),
  so they are disjoint from `:decimal_int` — a bare `"755"` is a
  decimal-int-string, not an octal-int-string. Each name is
  resolvable through `Type::Combinator.<name>_string` and through
  `Builtins::ImportedRefinements`.
- **`Builtins::ImportedRefinements` knows the predicate-subset
  shapes.** All six kebab-case names resolve through the same
  registry the point-removal half uses, so `RBS::Extended`'s
  `rigor:v1:return: lowercase-string` directive tightens a method's
  RBS-declared `String` return to the precise refinement at every
  call site.
- **Catalog-tier projections over a `Refined[String, …]` receiver.**
  `String#downcase` / `String#upcase` fold per predicate:
  case-fold idempotence for `:lowercase` / `:uppercase` /
  `:numeric` and the three base-N int-string predicates, plus the
  lift `lowercase ↔ uppercase` for the cross calls. Size-tier
  projections still apply through the predicate carrier so
  `String#size` / `String#length` over a `Refined[String, *]`
  tightens to `non-negative-int`.
- **Acceptance rule for `Refined`.** Gradual mode mirrors the
  conservative `accepts_difference` policy: a `Refined[base, p]`
  accepts another `Refined` with the same predicate, a `Constant`
  whose value the predicate's recogniser accepts, and rejects
  every other shape. Each branch projects through to the right
  base type before consulting the predicate, so the inner base
  acceptance call sees Nominal-vs-Nominal (or Constant) instead of
  hitting `accepts_nominal`'s default `else` arm.
- **`spec/integration/fixtures/predicate_refinement/`.** Self-
  asserting fixture mirroring `refinement_return_override/`,
  proving the kebab-case display, the `RBS::Extended return:`
  override route, and the case-fold projection pair end-to-end
  for all six predicates.

#### Built-in catalog imports

- **`Hash` joins the catalog-driven inference pipeline.** A new
  `data/builtins/ruby_core/hash.yml` is generated from
  `references/ruby/hash.c` by `tool/extract_builtin_catalog.rb`
  and consumed by `Builtins::HASH_CATALOG`, which the constant-
  fold dispatcher now consults for `Hash` receivers. Pure readers
  (`size` / `length` / `[]` / `include?` / `dig` / `invert` /
  `compact` / `<=` / `<` / `>=` / `>` / …) clear the catalog
  tier; block-yielding leaves the C-body classifier marked
  `:leaf` despite dispatching through `rb_hash_foreach` (`each` /
  `each_pair` / `each_key` / `each_value` / `select` / `filter` /
  `reject` / `transform_values` / `merge`) are blocklisted so a
  `Constant<Hash>` carrier cannot fold through them. Self-
  asserting fixture: `spec/integration/fixtures/hash_catalog.rb`.
- **`Range` joins the catalog-driven inference pipeline.**
  `Init_Range` is extracted into `data/builtins/ruby_core/range.yml`
  (30 instance methods); `Builtins::RANGE_CATALOG` consumes it and
  the constant-fold dispatcher routes `Constant<Range>` receivers
  through it. Methods that fold today on a `(begin..end)` literal
  include `#begin`, `#end`, `#size`, `#exclude_end?`, `#include?`,
  `#cover?`, and `#member?`. `#==`, `#eql?`, `#last`, and
  `#bsearch` stay catalog-classified `dispatch` because their C
  bodies route through user-redefinable `==` / `<=>`. The
  block-iterating surface (`#each`, `#step`, `#first`, `#min`,
  `#max`, `#minmax`, `#count`) classifies as `block_dependent`
  and is blocked by the foldable-purity check; `#reverse_each` and
  `#%` are blocklisted explicitly because the C-body classifier
  mis-flags them as `:leaf`. `Range#size` on a `Nominal[Range]`
  receiver continues to tighten to `non-negative-int` via
  `SIZE_RETURNING_NOMINALS`.
- **`Set` joins the catalog-driven inference pipeline.** A new
  `data/builtins/ruby_core/set.yml` is generated from `Init_Set`
  in `references/ruby/set.c` (Set was rewritten in C and folded
  into CRuby for Ruby 3.2+, so the catalog reads the same way as
  String / Array). `MethodDispatcher::ConstantFolding#catalog_for`
  now routes `Set` receivers through `Builtins::SET_CATALOG`.
  The per-class blocklist drops false-positive `:leaf`
  classifications for the indirect mutators (`initialize_copy`,
  `compare_by_identity`, `reset`), the block-yielding helpers
  (`each`, `classify`, `divide`), and `disjoint?` (which
  delegates through `set_i_intersect`'s user-redefinable
  dispatch path). `Set#size` / `#length` / `#count` keep
  tightening through the existing `SIZE_RETURNING_NOMINALS`
  projection.
- **`tool/extract_builtin_catalog.rb` recognises
  `rb_struct_define_without_accessor`.** The init-region scanner
  now joins multi-line statements before regex matching, and a
  new `STRUCT_DEFINE_RE` registers the host class. Range was the
  motivating case; future struct-defined topics (e.g. Process
  status objects) become drop-in additions.

- **CLI `type-of` confirms the kebab-case canonical-name
  contract.** New regression specs in
  `spec/rigor/cli_spec.rb` invoke `bundle exec exe/rigor type-of`
  through the harness over both a `Difference`-backed refinement
  (`non-empty-string`) and a `Refined`-backed refinement
  (`lowercase-string`, `numeric-string`), and assert that
  human-readable text and `--format=json` output both render the
  refinement in its kebab-case spelling while erasure folds back
  to the base nominal. No production code changes were needed —
  the renderer already routes through `Type#describe` and
  `erase_to_rbs` — but the regression coverage now binds the
  contract.

### Changed

- **`MethodDispatcher::ConstantFolding#catalog_for` is table-
  driven.** A `CATALOG_BY_CLASS` array of
  `(receiver_class, [catalog, class_name])` pairs replaces the
  growing `case` statement. Adding a class catalog is now a
  one-line addition rather than another `when` arm, and the
  dispatcher's cyclomatic complexity stays bounded as the
  catalogue grows.

## [0.0.3] - 2026-05-02

The third preview. v0.0.3 makes the inference engine "see literal
values where it can prove them" across a far wider surface than
v0.0.2: aggressive constant folding (unary + binary + Union[Constant]
cartesian + integer-range arithmetic + Tuple-shaped divmod), a
PHPStan-style imported-built-in refinement carrier
(`non-empty-string`, `positive-int`, `non-zero-int`,
`non-empty-array[T]`, `non-empty-hash[K, V]`, `negative-int`,
`non-positive-int`, `non-negative-int`), an extracted built-in
method catalog driving the fold dispatcher (Numeric / String /
Symbol / Array / IO / File auto-extracted from CRuby), iterator-
block-parameter typing, scope-level integer-range narrowing,
case/when range narrowing, an `always-raises` diagnostic for
provable Integer division-by-zero, and end-to-end opt-in of the
new refinement carrier through `RBS::Extended`'s new
`rigor:v1:return:` directive.

The robustness principle (Postel's law for types — strict on
returns, lenient on parameters) is now a normative section of the
type specification with ADR-5 as the design rationale.

### Added

- **Aggressive constant folding through user methods.**
  `Rigor::Inference::MethodDispatcher::ConstantFolding` invokes
  the real Ruby method on `Constant` receivers and arguments
  whenever the method is in a curated allow-list, the operation
  cannot raise on the receiver's domain, and the result is a
  scalar that round-trips through `Type::Combinator.constant_of`.
  Combined with inter-procedural inference (v0.0.2 #5):

  ```ruby
  class Parity
    def is_odd(n) = n.odd?
  end
  Parity.new.is_odd(3)   # was `false | true` in v0.0.2
                         # is now `Constant[true]`
  ```

- **Cartesian fold over `Union[Constant…]`.** Binary arithmetic
  and comparison fold pairwise across Union receivers and
  arguments, deduplicate, and rebuild a precise `Union[Constant…]`
  result. Bounded by `UNION_FOLD_INPUT_LIMIT = 32` and
  `UNION_FOLD_OUTPUT_LIMIT = 8`; when the output cap is exceeded
  for an Integer-only result set, the analyzer gracefully widens
  to the bounding `IntegerRange[min, max]` instead of giving up.

- **`Type::IntegerRange` carrier and range arithmetic.** PHPStan-
  style `int<min, max>` family with named aliases `positive-int`
  (`1..`), `non-negative-int` (`0..`), `negative-int` (`..-1`),
  `non-positive-int` (`..0`), and `int<a, b>`. Erases to
  `Integer` in RBS. Binary `+`, `-`, `*`, `/`, `%` and unary
  `succ` / `pred` / `abs` / `-@` / `even?` / `odd?` /
  `bit_length` / `zero?` / `positive?` / `negative?` all fold
  precisely. Single-point intersections (`int<5, 5>`) collapse
  to `Constant[5]`.

- **Scope-level range narrowing through comparisons and
  predicates.** `if x > 0 ... end` narrows `x` to `positive-int`
  on the truthy edge, `non-positive-int` on the falsey edge.
  Same for `<`, `<=`, `>=`, the reversed forms (`0 < x`),
  `x.positive?` / `x.negative?` / `x.zero?` / `x.nonzero?`, and
  `x.between?(a, b)`. The narrowing intersects with an existing
  `IntegerRange` bound when one is already in scope.

- **`case/when` integer-range narrowing.** `case n when 1..10
  then …` narrows `n` to `int<1, 10>` inside the body;
  `when 1...10` narrows to `int<1, 9>` (exclusive end);
  `when (100..)` narrows to `int<100, max>`; `when (..-1)`
  narrows to `negative-int`; `when 0` narrows to `Constant[0]`.

- **Iterator block-parameter typing.** `5.times { |i| … }` types
  `i` as `int<0, 4>`; `1.times { |i| … }` collapses to
  `Constant[0]`; `3.upto(7) { |i| … }` and `7.downto(3)
  { |i| … }` both type `i` as `int<3, 7>`. Wider Integer
  receivers (`Nominal[Integer]`, `positive-int`) fall back to
  `non-negative-int`.

- **Branch elision on provably-truthy/falsey predicates.**
  `if 4.even? ; :even ; else ; :odd ; end` resolves to
  `Constant[:even]` only — the dead branch is skipped — when
  the predicate's narrow_truthy / narrow_falsey collapses one
  side to `Bot`. `Constant[true]` / `Constant[false]` /
  `Nominal[Integer]` (always truthy) all qualify; `Union[true,
  false]` keeps both branches active as before.

- **`Tuple`-shaped `Integer#divmod` / `Float#divmod` folds.**
  `5.divmod(3)` lifts to `Tuple[Constant[1], Constant[2]]` so
  multi-target destructuring threads the per-slot type into
  locals (`q, r = 11.divmod(4)` binds `q: 2`, `r: 3`).
  Float / mixed Integer-Float divmod produces a mixed
  `Tuple[Constant<Integer>, Constant<Float>]`.

- **Built-in method catalog extraction pipeline.**
  `tool/extract_builtin_catalog.rb` parses CRuby's
  `Init_<Topic>` blocks (Numeric / Integer / Float / String /
  Symbol / Array / IO / File), classifies each cfunc body
  statically (leaf / leaf-when-numeric / dispatch /
  block-dependent / mutates-self / raises / unknown), and
  joins the result with the matching `references/rbs/core/*.rbs`
  signatures. Output lives at `data/builtins/ruby_core/<topic>.yml`
  (regenerated via `make extract-builtin-catalogs`). Generated
  YAML ships with the gem.

  `Rigor::Inference::Builtins::NumericCatalog` /
  `STRING_CATALOG` / `ARRAY_CATALOG` consume the catalogs at
  runtime and gate the constant-fold dispatcher on
  per-method purity. Per-class blocklists guard against
  classifier false positives (the C-body regex does not
  follow indirect mutators like `rb_str_replace` →
  `str_modifiable`); bang-suffixed selectors are universally
  blocked.

  Folds unlocked in v0.0.3 include: `Integer#**`, `&`, `|`,
  `^`, `<<`, `>>`, `===`, `div`, `fdiv`, `modulo`,
  `remainder`, `pow`; `Float#**`; `String#[]`, `include?`,
  `start_with?`, `end_with?`, `index`, `count`, `inspect`;
  `Symbol#length`, `empty?`, `casecmp?`.

- **`Type::IntegerRange` returns from container `#size` /
  `#length` / `#bytesize`.** `Nominal[Array]#size`,
  `Nominal[String]#length`, `Nominal[Hash]#size`,
  `Nominal[Set]#size`, `Nominal[Range]#size` now return
  `non_negative_int` instead of the RBS-declared `Integer`.
  Composes with the comparison-narrowing tier so `if
  arr.size > 0` narrows the local to `positive-int` and
  `arr.size - 1` evaluates as `non-negative-int`.

- **`File` path-manipulation folding (opt-in).**
  `File.basename`, `#dirname`, `#extname`, `#join`,
  `#split`, `#absolute_path?` over `Constant<String>`
  arguments fold to a precise `Constant` (or
  `Tuple[Constant, Constant]` for `split`) when
  `fold_platform_specific_paths: true` is set in
  `.rigor.yml`. Default mode is platform-agnostic — these
  methods read `File::SEPARATOR` / `ALT_SEPARATOR` and would
  otherwise bake the analyzer-host's platform into the
  inferred type — so the RBS tier answers with
  `Nominal[String]` / `Tuple[String, String]` / `bool`.
  Single-platform projects opt in for the precision payoff;
  cross-platform projects keep the safe envelope.

- **`Type::Difference` carrier (OQ3 point-removal half).**
  `Difference[base, removed]` represents `base` minus a
  finite removed value set, the structural primitive every
  imported-built-in refinement of the "non-empty / non-zero /
  non-empty-array / non-empty-hash" family uses. Acceptance
  is conservative: only `Constant` and same-removed
  `Difference` candidates can be proved disjoint from the
  removed set, so `Difference[String, ""].accepts(Nominal[String])`
  correctly returns `no` (the wider Nominal could be `""`).
  `MethodDispatcher::ShapeDispatch` projects the
  empty-removal case directly: `nes.size` →
  `positive-int`, `nes.empty?` → `Constant[false]`,
  `nzi.zero?` → `Constant[false]`. Erases to the base
  nominal in RBS.

- **`Rigor::Builtins::ImportedRefinements` registry.** Maps
  every imported-built-in kebab-case name
  (`non-empty-string`, `non-zero-int`, `non-empty-array`,
  `non-empty-hash`, `positive-int`, `non-negative-int`,
  `negative-int`, `non-positive-int`) to its Rigor type
  carrier. Single integration point for `RBS::Extended` and
  for future tokeniser slices.

- **`rigor:v1:return:` `RBS::Extended` directive.** Overrides
  a method's RBS-declared return type with one of the
  imported-built-in refinements. Annotation in the sig
  file:

  ```rbs
  class User
    %a{rigor:v1:return: non-empty-string}
    def name: () -> String

    %a{rigor:v1:return: positive-int}
    def age: () -> Integer
  end
  ```

  At call sites the override propagates: `User.new.name.size`
  is `positive-int`, `User.new.name.empty?` is
  `Constant[false]`, `User.new.age.zero?` is
  `Constant[false]`. The RBS erasure stays at the base
  nominal so the round-trip to ordinary RBS is unaffected.
  Unknown refinement names degrade to the RBS-declared
  return (silent miss, no crash).

- **`always-raises` diagnostic rule.** `5 / 0`, `5 % 0`,
  `5.div(0)`, `5.modulo(0)`, `5.divmod(0)`, and
  `rand(100) / 0` all surface as `:error` diagnostics under
  rule `always-raises` ("always raises ZeroDivisionError").
  Float arithmetic (`5.0 / 0` returns `Infinity`) and
  `Integer#fdiv(0)` stay silent. Suppressible per-line via
  `# rigor:disable always-raises`.

- **Implicit-self calls prefer in-source `def` over RBS dispatch.**
  When `node.receiver` is nil (true implicit self) and the
  file has a same-named top-level `def` (or DSL-block-nested
  `def`, e.g. inside `RSpec.describe ... do ... end`), the
  engine routes through inter-procedural inference on that
  body before consulting the receiver class's RBS. When the
  local def's parameter shape is too complex for the binder
  (kwargs / optionals / rest), the engine returns
  `Dynamic[Top]` instead of falling through to (incorrect)
  RBS dispatch.

- **RSpec matcher narrowing.** The engine recognises a
  small catalogue of RSpec matcher patterns as
  assert-shaped narrows on the local passed to
  `expect(...)`. `expect(x).not_to be_nil` /
  `expect(x).to_not be_nil` drop `NilClass` from `x`'s
  type; `expect(x).to be_a(C)` / `be_kind_of(C)` narrow `x`
  to `C` (subtype-permitting); `be_an_instance_of(C)` /
  `be_instance_of(C)` narrow exactly. Pattern matching is
  purely AST-shape — no RBS for RSpec is required.

- **`fold_platform_specific_paths` configuration option.**
  Boolean in `.rigor.yml`, default `false`. Enables File
  path-manipulation folds (see above) for projects that
  target a single platform.

- **Robustness principle (Postel's law) for types.** New
  ADR ([`docs/adr/5-robustness-principle.md`](docs/adr/5-robustness-principle.md))
  and normative spec section
  ([`docs/type-specification/robustness-principle.md`](docs/type-specification/robustness-principle.md))
  document the asymmetric authorship rule: Rigor-authored
  return types should be as strict as can be proved;
  Rigor-authored parameter types should be as permissive as
  the body's correct behaviour permits. Hand-written RBS
  authorship binds; the principle directs Rigor's defaults
  only.

- **ADR-3 working decisions.** OQ1 (Constant scalar shape):
  Option C (hybrid). OQ2 (Trinary-returning predicate
  naming): Option A (drop the `?`). OQ3 (refinement carrier
  strategy): Option C (two-tier hybrid — `Difference` for
  point-removal, `Refined` for predicate-subset; the latter
  ships in v0.0.4).

### Fixed

- `Rigor::Analysis::CheckRules` `arity_eligible?` /
  `argument_check_eligible?` no longer raise when the RBS
  function is `RBS::Types::UntypedFunction` (e.g. `(?) ->`
  or certain stdlib variadic sigs). Both predicates now
  return `false` for untyped functions — the conservative
  outcome — instead of crashing the file's analysis.

- `ConstantFolding`'s union fold no longer silently drops
  members for which the method is unsupported. The previous
  behaviour folded `Union[Constant[String], Constant[nil]].nil?`
  to `Constant[true]` because `String#nil?` was not in
  `STRING_UNARY` and the partial fold dropped the String
  pair. The fold now requires every receiver's method to be
  in the allow set; partial coverage bails to RBS instead
  of producing a wrong answer.

## [0.0.2] - 2026-05-01

The second preview. v0.0.2 closes the must-have envelope around the
v0.0.1 pipeline: a richer `RBS::Extended` directive surface
(`assert` / `assert-if-true` / `assert-if-false`, `~T` negation,
`target: self`), inter-procedural inference for user-defined
methods, an `argument-type-mismatch` rule, per-rule diagnostic
suppression (project-level + in-source comments),
configuration passthrough for stdlib libraries and signature
paths, and a `--explain` mode that surfaces fail-soft fallback
events.

### Added

- **`rigor check --explain` mode.** Surfaces fail-soft inference
  fallbacks as `:info` diagnostics so users can see where the
  engine degraded to `Dynamic[Top]`. Driven by
  `Rigor::Inference::CoverageScanner` so each event is attributable
  to the leaf node that triggered it (pass-through wrappers like
  `ProgramNode` / `StatementsNode` / `ParenthesesNode` are not
  double-counted). Each diagnostic carries `rule: "fallback"`,
  `severity: :info`, and a short message naming the node class
  and the type the engine fell back to. Info diagnostics do not
  fail the run.

- **`.rigor.yml` `libraries:` and `signature_paths:` keys.** The
  configuration layer now passes through to
  `Rigor::Environment.for_project`:
  - `libraries:` lists stdlib libraries to load on top of
    `Environment::DEFAULT_LIBRARIES` (e.g. `["csv", "set"]`). Each
    entry must be a name accepted by
    `RBS::EnvironmentLoader#has_library?`; unknown libraries
    fail-soft.
  - `signature_paths:` is an explicit list of `sig/`-style
    directories. Leaving the key unset (or `null`) preserves the
    auto-detect-`<root>/sig` default; `[]` disables project-RBS
    loading entirely.

  Wired through `rigor check`, `rigor type-of`, and `rigor type-scan`
  (the latter two gain a `--config=PATH` option matching `check`).

- **Per-rule diagnostic suppression.** Two mechanisms compose:
  - **Project-level**: `.rigor.yml`'s new `disable:` key
    accepts a list of `rigor check` rule identifiers
    (`undefined-method`, `wrong-arity`,
    `argument-type-mismatch`, `possible-nil-receiver`,
    `dump-type`, `assert-type`); matching diagnostics are
    silenced project-wide.
  - **In-source**: `# rigor:disable <rule>` (or
    `<rule1>, <rule2>`) at the end of an offending line
    silences per-line. `# rigor:disable all` suppresses
    every rule on that line.

  `Rigor::Analysis::Diagnostic` gains a `rule:` field
  carrying the source rule's stable identifier. Parse
  errors / path errors / internal analyzer errors leave
  `rule` as `nil` and stay unsuppressible.

- **Inter-procedural inference for user-defined methods.**
  When a call's receiver is `Nominal[T]` for a user-defined
  class without an RBS sig and the method has been
  discovered as an instance `def`, the engine re-types the
  method's body at the call site with the call's argument
  types bound to the parameters and returns the body's
  last-expression type. The `user_methods.rb` integration
  fixture now resolves `Parity.new.is_odd(3)` to
  `false | true` (was `Dynamic[top]` in v0.0.1) without
  requiring an RBS sig.

  First iteration accepts only the simplest parameter shape
  (required positionals, no optionals / rest / keywords /
  block params); receiver must be `Nominal` (not Singleton);
  recursion is guarded by a per-thread inference stack so
  mutually recursive helpers fall back to `Dynamic[Top]`
  rather than infinite-looping.

- `rigor check` ships an **argument-type-mismatch** rule. For
  every explicit-receiver `Prism::CallNode` whose method has
  exactly one RBS overload (no `rest_positionals`, no
  required keywords, no trailing positionals), the rule
  routes each positional argument's inferred type through
  `Rigor::Inference::Acceptance.accepts(parameter, argument,
  mode: :gradual)` and emits an `:error` for the first
  argument the parameter does not accept. Argument or
  parameter types known only as `Dynamic` skip the check
  (the call cannot be statically refuted). The receiver
  must be `Nominal` / `Singleton` / `Constant`; user-class
  fallback / shape carriers behave as in the wrong-arity
  rule. The rule respects RBS even when the user has both a
  `def` and a sig: the sig is the authoritative parameter
  contract.

- `Rigor::Inference::Acceptance` now treats `Singleton[T]`
  as a subtype of `Module`, `Class`, `Object`, and
  `BasicObject`. Without this rule a method whose parameter
  is typed `Class | Module` (e.g. `Object#is_a?`,
  `Module#define_method`) rejected every singleton receiver,
  producing systemic false positives across both `lib/` and
  `spec/`.

- `RBS::Extended` `target: self` directives now actually
  narrow the receiver local on the matching edge (was: parser
  accepted but engine discarded). Covers all three rule
  shapes:
  - `predicate-if-true self is LoggedInUser` /
    `predicate-if-false self is User` — narrows the receiver
    local on the truthy / falsey edge of an `if` / `unless`
    predicate.
  - `assert-if-true self is AdminUser` — same shape, applied
    when the call is observed as a truthy predicate.
  - `assert self is RegisteredUser` — narrows the receiver
    local unconditionally at the post-call scope.

  Narrowing only fires when the call's receiver is a
  `Prism::LocalVariableReadNode` (the engine's narrowing
  surface) AND the receiver type is statically known
  (Nominal / Singleton / Constant — required for the engine
  to even resolve which class's method carries the
  annotation).

- `RBS::Extended` recognises **negation** in predicate / assert
  directives via the `~ClassName` syntax:
  - `predicate-if-true value is ~NilClass` narrows `value`
    AWAY from `NilClass` on the truthy edge.
  - `assert value is ~NilClass` narrows `value` AWAY from
    `NilClass` in the post-call scope.

  `Rigor::RbsExtended::PredicateEffect#negative?` and
  `AssertEffect#negative?` are new boolean predicates; the
  parser sets them when the directive's type literal starts
  with `~`. The engine routes negative effects through
  `Narrowing.narrow_not_class` instead of `narrow_class` so
  the union loses the named class on the active edge.

- `RBS::Extended` recognises three additional directives:
  - `rigor:v1:assert <target> is <Class>` — refines the
    matching argument's local in the post-call scope
    unconditionally. Wires through
    `StatementEvaluator#eval_call`.
  - `rigor:v1:assert-if-true <target> is <Class>` — refines
    the argument when the call is observed as a truthy
    predicate (e.g. `if call_node`). Wires through
    `Narrowing.predicate_scopes` alongside `predicate-if-*`.
  - `rigor:v1:assert-if-false <target> is <Class>` —
    symmetric for falsey.

  The three directives complement `predicate-if-true` /
  `predicate-if-false` — together they cover the
  `must_be_string!` / `validate!` / `valid_string?` /
  `integer?` patterns common in Ruby. `Rigor::RbsExtended::AssertEffect`
  is the new data class returned by
  `RbsExtended.read_assert_effects(method_def)`.

- `Rigor::Environment::DEFAULT_LIBRARIES` now includes
  `tmpdir`, `stringio`, `forwardable`, `digest`, and
  `securerandom`. Common stdlib calls
  (`Dir.mktmpdir`, `StringIO.new`, `Forwardable#def_delegator`,
  `Digest::SHA256.hexdigest`, `SecureRandom.hex`) resolve
  through their RBS sigs without the user having to enumerate
  the libraries themselves.

### Changed

- `Rigor::Analysis::CheckRules` `dump_type` / `assert_type`
  rules are suppressed when the call site's `self_type` is
  `Rigor` or `Rigor::Testing`. The reflexive
  `Testing.dump_type(value)` / `Testing.assert_type(...)` calls
  inside Rigor's own stub no longer surface diagnostics on
  `rigor check lib`.

## [0.0.1] - 2026-05-01

The first preview release. Rigor can be pointed at a real Ruby
project, infer types end-to-end through a flow-sensitive scope,
and emit diagnostics for a small but practical rule catalogue.

The gem is published to RubyGems as **`rigortype`** (the
`rigor` name was already taken). The Ruby module name remains
`Rigor`, so user code uses `require "rigor"` and references
`Rigor::Scope`, `Rigor::Testing`, etc. — only the
`gem install` / `Gemfile` line uses `rigortype`.

### Added

- **`rigor check` end-to-end pipeline.** Parses Ruby through
  Prism, builds a per-node scope index, and runs a three-rule
  catalogue against it:
  - undefined method on a typed receiver,
  - wrong number of positional arguments,
  - possible nil receiver (with safe-navigation and
    early-return narrowing exclusions).
  False positives on reopened classes, `define_method`-defined
  methods, constant-decl-aliased classes (`YAML` → `Psych`),
  and dynamic / unknown receivers are suppressed.
- **`rigor type-of FILE:LINE:COL`** — probes the inferred
  type at any source position.
- **`rigor type-scan PATH...`** — coverage report over a tree.
- **`rigor init`** — writes a header-commented `.rigor.yml`.
- **Type model.** `Top`, `Bot`, `Dynamic[T]`, `Constant[v]`,
  `Nominal[Class, type_args]`, `Singleton[Class]`,
  `Union[A, B, ...]`, `Tuple[T1, ..., Tn]`, and `HashShape`
  carriers with required / optional / read-only key
  policies. `Trinary` (`yes`/`no`/`maybe`) and
  `AcceptsResult`.
- **Inference engine.** Local, instance, class, and global
  variable bindings tracked through `Rigor::Scope`.
  Cross-method ivar / cvar accumulators populated by a
  `ScopeIndexer` pre-pass; program-wide globals.
- **Compound writes** (`||=`, `&&=`, `+=`, `-=`, `*=`, ...)
  thread through scope for every variable kind, with
  operator dispatch via `MethodDispatcher`.
- **`self` typing.** Class- and method-body boundaries inject
  `Singleton[T]` / `Nominal[T]`; implicit-self call dispatch
  routes through the enclosing class's RBS.
- **Lexical constant lookup.** Project sig, RBS-core, common
  stdlib bundle (pathname, optparse, json, yaml, fileutils,
  tempfile, uri, logger, date, prism, rbs), in-source class
  discovery, and in-source constant value tracking.
- **Predicate narrowing.** Truthiness, `nil?`, `is_a?` /
  `kind_of?` / `instance_of?`, finite-literal equality,
  case-equality (`===`) for Class / Module / Range / Regexp,
  and `case` / `when` integration.
- **Block parameter binding** including destructuring
  (`|(a, b), c|`) and numbered parameters (`_1`, `_2`, ...).
  Block-return-type uplift through generic methods so
  `[1, 2, 3].map { |n| n.to_s }` resolves to `Array[String]`.
- **Closure escape analysis.** A core-and-stdlib catalogue of
  block-accepting methods is classified as `:non_escaping`
  (Array#each / map / select / ...), `:escaping`
  (Module#define_method, Thread.new, Proc.new, ...), or
  `:unknown`. Escaping calls drop narrowed types of captured
  outer locals the block can rebind and record a
  `closure_escape` fact in the FactStore.
- **`RBS::Extended` predicate effects.** Methods whose RBS
  signature carries `%a{rigor:v1:predicate-if-true target is T}`
  / `predicate-if-false` annotations narrow the matching
  argument on the corresponding edge.
- **PHPStan-style typing helpers.** `Rigor::Testing.dump_type`
  surfaces the inferred type as an `:info` diagnostic;
  `Rigor::Testing.assert_type("expected", value)` errors when
  the inferred type's short description does not match. Use
  in fixtures to make them self-asserting.
- **Self-asserting integration suite.** Fixture-driven
  examples under `spec/integration/fixtures/` covering
  parity / case-when / compound writes / is_a? narrowing /
  Tuple and HashShape access / Array#map block-return uplift
  / early-return narrowing / RBS::Extended predicates /
  user-defined method dispatch.

### Known limitations (deferred to v0.0.2)

- Inter-procedural inference for user-defined methods. A
  helper like `def is_odd(n) = n.odd?` types correctly inside
  the def, but the caller observes `Dynamic[top]` until an
  RBS sig is supplied. The `spec/integration/fixtures/user_methods*`
  pair pins both shapes (no sig vs project sig).
- `RBS::Extended` ships only the predicate-effect surface.
  `assert` / `assert-if-true` / `assert-if-false`, negation
  (`~T`), self-targeted narrowing, intersection / union
  refinements, `param` / `return` / `conforms-to` directives
  are deferred.
- No persistent cache — every `rigor check` run re-parses
  and re-types the project.
- No plugin contribution layer past the bundled
  `RBS::Extended` reader.
- Per-rule severity is hard-coded to `:error` (with `:info`
  reserved for `dump_type`); per-rule configuration and
  suppression comments are deferred.

[Unreleased]: https://github.com/rigortype/rigor/compare/v0.0.3...HEAD
[0.0.3]: https://github.com/rigortype/rigor/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/rigortype/rigor/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/rigortype/rigor/releases/tag/v0.0.1
