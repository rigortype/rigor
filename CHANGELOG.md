# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`Constant<String>` array-returning method lift.** `s.chars`, `s.bytes`, `s.lines`, `s.split` (no-arg), `s.split(separator)`, and `s.scan(pattern)` previously declined because Ruby's actual return is an `Array` and `foldable_constant_value?` rejects Array values. New `try_fold_string_array_unary` and `try_fold_string_array_binary` arms run the operation against the host string, then lift the resulting Array to a per-position `Tuple[Constant…]` when every element is a foldable scalar and the cardinality fits within `STRING_ARRAY_LIFT_LIMIT` (32 elements). Larger results decline so the RBS tier widens to `Array[String]` / `Array[Integer]`. The single-Constant binary path keeps firing for `String#tr` / `delete` / `squeeze` / `gsub` / `sub` etc. that already returned a single String.

- **`String#%` format-string fold over `Tuple` and `HashShape` arguments.** `Constant<String> % Tuple[Constant…]` and `Constant<String> % HashShape{…}` now run Ruby's actual `String#%` engine at fold time when every operand is statically known, producing a precise `Constant<String>` result. The single-Constant-argument case (e.g. `"hi %s" % "world"`) was already covered by the standard binary path; the new arm extends the fold to multi-argument templates (`"%d / %d" % [1, 2]` → `Constant<"1 / 2">`) and hash-style templates (`"%{name} is %{age}" % {name: "Alice", age: 30}` → `Constant<"Alice is 30">`). Malformed format specs raise at fold time and the dispatcher catches the exception so the call falls through to the RBS tier.

- **Tuple unary precision — eleven new no-arg / single-arg handlers in `MethodDispatcher::ShapeDispatch`.** `empty?` / `any?` (no-block, no-arg) / `all?` / `none?` fold to `Constant[bool]` per the tuple's arity and element truthiness; `include?(needle)` folds to a precise bool when the needle is a `Constant` and the tuple's elements are all `Constant`; `sum` folds to `Constant[total]` across numeric `Constant` elements; `min` / `max` fold to the comparable extreme; `sort` returns a per-position Tuple of sorted Constants; `reverse` returns a per-position Tuple in reversed order; `to_a` returns the receiver Tuple unchanged. Mixed / non-Constant element shapes decline so the RBS / `BlockFolding` tiers still answer them.

- **HashShape projections — `keys` / `values` / `count` / `empty?` / `any?`.** `MethodDispatcher::ShapeDispatch` gains five HashShape handlers that fire for closed shapes with no optional keys. `keys` folds to `Tuple[Constant<k>…]` (preserving declaration order so a downstream `tuple[i]` projection stays precise); `values` folds to `Tuple[V_1, …, V_n]`; `count` folds to `Constant[size]` (matching `size` / `length`); `empty?` and `any?` (no-arg, no-block forms) fold to `Constant[true]` / `Constant[false]` per the shape's emptiness. The block-form `any?` continues to flow through the v0.0.6 `BlockFolding` tier.

- **`T[K]` indexed-access type operator.** `Type::Combinator.indexed_access(type, key)` projects the type at index / key `K` from a structured `T` — `Tuple[A, B, C][Constant<i>]` returns the per-position element (out-of-range indices return `Top`); `HashShape{a: A, b: B}[Constant<:a>]` returns the entry type (missing keys return `Top`); `Nominal[Hash, [K, V]][_]` returns `V` and `Nominal[Array, [E]][_]` returns `E` (untyped if absent); `Constant<Range>[Constant<i>]` returns the indexed integer constant. Reachable from `RBS::Extended` directive payloads through trailing `[K]` segments after a parsed type, including chained `T[K1][K2]`. The parser's top-level entry now also accepts class-name-headed types directly, so `Hash[Symbol, Integer][Symbol]` parses to `Symbol` end-to-end.

- **Refinement-form `~Refined[base, predicate]` narrowing.** `narrow_not_refinement` no longer falls back to `current_type` unchanged when the negated refinement is a `Type::Refined` carrier. The new `complement_refined` arm walks the current type's union members; parts disjoint from the refinement's base survive, parts that exactly match the refinement drop, and parts that overlap the base contribute `Difference[part, refined]` so downstream narrowing knows the refinement subset is excluded. This gives `assert value is ~lowercase-string` directives an actual narrowing effect — `String` narrows to `Difference[String, lowercase-string]` rather than staying `String`. The De Morgan composition also tightens: `~(non-empty-string ∩ lowercase-string)` within `String` is now `Constant[""] | Difference[String, lowercase-string]` instead of widening to `Constant[""] | String`.

- **`Rational` / `Complex` literal lift.** `Prism::ImaginaryNode` (`1i`) and `Prism::RationalNode` (`1.5r`) now type as `Constant<Complex>` / `Constant<Rational>` via the existing `type_of_literal_value` route, and `Kernel#Rational(num, den)` / `Kernel#Complex(re, im)` calls fold to the same precise constants when every argument is a numeric Constant. `MethodDispatcher::ConstantFolding`'s `foldable_constant_value?` predicate is widened to accept `Rational` and `Complex` values (the `Type::Constant` carrier already accepted them via `SCALAR_CLASSES`), which unblocks the catalog-tier fold for every `Rational#…` / `Complex#…` `:leaf` / `:leaf_when_numeric` method on a constant receiver — e.g. `Rational(3, 4).numerator` folds to `Constant[3]`, `Rational(3, 4) + Rational(1, 2)` folds to `Constant<Rational(5, 4)>`, and `Complex(3, 4).abs` folds to `Constant[5.0]`.

- **`Constant<Range>` unary precision — `to_a` / `first` / `last` / `min` / `max` / `count` / `size` / `length`.** A new Range-specific arm in `MethodDispatcher::ConstantFolding#try_fold_unary_set` lifts `(1..3).to_a` to a per-position `Tuple[Constant[1], Constant[2], Constant[3]]` (capped at 16 elements; oversize ranges decline so the RBS tier widens), and folds the no-arg endpoint methods (`first` / `last` / `min` / `max`) and the cardinality methods (`count` / `size` / `length`) to precise `Constant<Integer>` values. The catalog tier was previously blocked on these because `to_a`'s Array result fails `foldable_constant_value?` and the endpoint / cardinality methods are catalog-classified `:block_dependent` for the optional-block forms — neither of which prevents folding the no-arg form on a finite integer range.

- **`int_mask[1, 2, 4]` / `int_mask_of[T]` type functions.** `Type::Combinator.int_mask(flags)` computes the bitwise-OR closure over a list of non-negative integer flags (returning a `Union[Constant<Integer>…]` for small closures and a covering `IntegerRange` once the closure exceeds `INT_MASK_UNION_LIMIT`); `Type::Combinator.int_mask_of(type)` extracts a finite integer literal set from a `Constant<Integer>` or `Union[Constant<Integer>…]` type and runs the same closure. Reachable through `RBS::Extended` directive payloads as `int_mask[1, 2, 4]` (integer-literal arguments are now accepted alongside types and class names) and `int_mask_of[T]`. Caps at `INT_MASK_FLAG_LIMIT = 6` flags so the 2^N closure cost stays bounded; declines on negative flags or non-integer arguments.

- **`key_of[T]` / `value_of[T]` type functions.** `Type::Combinator.key_of` and `value_of` project the type-level union of known keys (resp. values) for `HashShape`, `Tuple`, `Nominal[Hash, [K, V]]`, `Nominal[Array, [E]]`, and finite-bound `Constant<Range>`; other shapes (`Top`, `Dynamic`, untyped Nominals, `Union`, `Refined`, `Difference`, `Intersection`) project to `Top`. Both functions are reachable through the `RBS::Extended` directive payload parser as `key_of[…]` / `value_of[…]`, which now accepts `lower_snake` heads alongside `kebab-case` refinement names and lets nominal arguments carry their own type-args (`key_of[Hash[Symbol, Integer]]` parses to `Symbol`).

## [0.0.6] - 2026-05-05

The sixth preview. Theme: **fold block-taking Enumerable methods through the constant-folding tier** so iterator-shaped expressions over literal collections produce precise carriers instead of widening through RBS.

### Added

- **Block-shaped fold dispatch over constant-block predicates and filters.** Calls like `[1, 2, 3].select { false }`, `arr.all? { true }`, or `arr.any? { false }` collapse to the precise endpoint when the block's inferred return type is a Ruby-truthy or Ruby-falsey `Constant`. Filter methods (`select` / `filter` / `reject` / `take_while` / `drop_while`) fold to either the receiver or `Tuple[]`; predicate methods (`all?` / `any?` / `none?`) fold to `Constant[true]` / `Constant[false]` whenever the receiver-emptiness × block-truthiness combination is unconditional in Ruby's semantics, including the vacuous-truth empty-receiver cases. Receiver-emptiness is recognised against `Tuple`, `HashShape`, `Constant<Array|Hash|String|Range>`, and the imported `non-empty-array[T]` carrier (`Difference[Array, Tuple[]]`).
- **Per-position block re-evaluation over Tuple receivers** for `map` / `collect` / `filter_map` / `flat_map` / `find` / `detect` / `find_index` / `index`. The block body is type-checked once per Tuple position with the corresponding element bound to the block parameter, then assembled per-method:
  - `map` / `collect` produce `Tuple[U_1..U_n]`. `[1, 2, 3].map { |n| n.to_s }` resolves to `["1", "2", "3"]` instead of `Array["1" | "2" | "3"]`.
  - `filter_map` drops `Constant[nil]` / `Constant[false]` positions and concatenates the survivors into a Tuple.
  - `flat_map` concatenates per-position `Tuple` results, treating per-position `Constant` scalars as single-element contributions and declining on opaque carriers.
  - `find` / `detect` return the receiver element at the first truthy position (or `Constant[nil]` when every position is falsey).
  - `find_index` / `index` return the index of the first truthy position (or `Constant[nil]`). The value-search forms `index(value)` / `find_index(value)` decline so the RBS tier still owns those.
- **Per-position block fold over short `Constant<Range>` receivers** up to a cardinality cap of 8 elements. Each integer in the range re-types the block body once with the corresponding `Constant<Integer>` bound to the parameter, so `(1..3).map { |n| n.to_s }` resolves to `["1", "2", "3"]` and `(1..5).find { |n| n.even? }` resolves to `Constant[2]`. Larger ranges decline so the RBS tier widens, keeping block-typing cost bounded.
- **Branch elision for expression-position conditionals.** `if` / `unless` / ternary expressions whose predicate folds to a `Type::Constant` drop the unreachable branch and adopt the live branch's type. Statement-level branch elision was already present from v0.0.3; this slice covers expression-position uses (e.g. the right-hand side of an assignment, an argument expression, or a block body). Composes directly with the per-position fold, so `[1, 2, 3].filter_map { |n| n.even? ? n.to_s : nil }` resolves to `Tuple[Constant["2"]]`.
- **`&&` / `||` short-circuit elision on Constant-shaped left operands.** When the left operand of `&&` / `||` folds to a `Type::Constant`, the result type follows Ruby's actual short-circuit semantics: `Constant[truthy] && rhs` is the right operand's type, `Constant[falsey] && rhs` keeps the left, and the dual rule applies for `||`. Non-Constant left operands keep the previous union-of-both-operands behaviour.
- **`find { false }` / `detect { false }` / `find_index { false }` / `index { false }` / `count { … }` short-circuit folds.** The block-form falsey side of the find-family folds to `Constant[nil]`; `count { false }` folds to `Constant[0]`; `count { true }` folds to `Constant[size]` when the receiver pins a finite size (Tuple, HashShape, or `Constant<Range>` with finite integer endpoints). The value-search forms `index(value)` / `count(value)` carry a positional argument and decline so the RBS tier still answers them.
- **IntegerRange-aware ternary fold — `Comparable#between?` / `Comparable#clamp`.** The 2-arg `try_fold_ternary` path now accepts an `IntegerRange` receiver paired with two scalar `Constant<Integer>` args. `int<3, 7>.between?(0, 10)` folds to `Constant[true]`; `int<3, 7>.clamp(4, 6)` folds to `int<4, 6>` (collapsing to a `Constant` when the intersection pins a single point). When the bracket is fully disjoint from the range — every receiver value would snap to one bracket bound — the fold declines so the RBS tier widens rather than the dispatcher inventing the snap point.
- **Empty array literal carrier — `[]` resolves to `Tuple[]`.** The empty array literal previously typed as `Nominal[Array]`; v0.0.6 switches it to the empty `Tuple[]` carrier so the per-element block fold can concatenate cleanly across all-empty positions like `[1, 2, 3].flat_map { |_| [] }` (now folds to `Tuple[]`). Both carriers erase to plain `Array` on the RBS-interop path.
- **Pathname catalog import.** `data/builtins/ruby_core/pathname.yml` (102 instance methods, 2 singletons, 5 aliases) and the matching `Builtins::PATHNAME_CATALOG` join the catalog tier. Pathname is a thin wrapper that mostly delegates to `File` / `Dir` / `FileTest`, so the user-visible payoff is narrower than Numeric or String — the import buys receiver-class recognition for `Pathname.new(...)`, a defensive `:initialize_copy` blocklist entry, and catalog folding for the lone `:leaf` method (`<=>`).

### Fixed

- **`tool/extract_builtin_catalog.rb` rescue-on-def classifier crash.** `PreludeParser#analyse_body` previously raised `NoMethodError` on Ruby methods written with the rescue-on-def idiom (`def foo; …; rescue; …; end`) because Prism wraps the body in a `BeginNode` rather than a `StatementsNode`. The classifier now descends into the begin-block's `statements` for that case. The bug surfaced importing Pathname (whose prelude has `def initialize(path); @path = …; rescue TypeError; …; end`); every catalog regenerates cleanly under `make extract-builtin-catalogs`.

## [0.0.5] - 2026-05-03

### Added

- **Rational and Complex built-in catalog imports.** New
  loaders `RATIONAL_CATALOG` and `COMPLEX_CATALOG` join the
  `CATALOG_BY_CLASS` table; the corresponding YAMLs under
  `data/builtins/ruby_core/{rational,complex}.yml` are
  generated from `references/ruby/{rational,complex}.c` via
  `tool/extract_builtin_catalog.rb`. Both classes are fully
  immutable in Ruby, so the per-class `mutating_selectors`
  blocklists carry only the conventional defence-in-depth
  `:initialize_copy` entry. Rigor today has no
  `Constant<Rational>` / `Constant<Complex>` literal lift
  (`Prism::ImaginaryNode` and `Rational(...)` /
  `Complex(...)` Kernel-call folding stay deferred), so the
  catalog wiring is currently a defensive surface — every
  fixture assertion goes through the RBS-tier projection on a
  `Nominal[<class>]` receiver. The blocklist becomes
  load-bearing once a future slice teaches the typer to lift
  these literals into `Constant<…>`.
- **`Const = Data.define(*Symbol)` discovery.**
  `Inference::ScopeIndexer.record_declarations` now
  registers `Const` (qualified by the surrounding class /
  module path) as a discovered class whose constant resolves
  to `Singleton[<qualified-name>]`. Previously
  `Const.new(...)` returned the un-narrowed `Dynamic[top]`
  envelope; with the constant registered, `meta_new` resolves
  it to a fresh `Nominal[<qualified-name>]`, and member
  accessors flow through the user-class fallback without
  false-positives. Both the bare form `Data.define(:x, :y)`
  and the block-override form
  `Data.define(:x, :y) do; def initialize(x:, y:); …; end end`
  are recognised; non-symbol arguments and non-`Data`
  receivers are rejected. Worked example: `Target` and
  `Fact` in `lib/rigor/analysis/fact_store.rb` now type as
  `singleton(Rigor::Analysis::FactStore::Target)` and
  `singleton(Rigor::Analysis::FactStore::Fact)` respectively.
- **`Kernel#Array` precision tier
  (`MethodDispatcher::KernelDispatch`).** A new
  precision-tier dispatcher folds `Array(arg)` into a precise
  `Array[E]` whenever the argument's value-lattice shape lets
  us prove the element type. The rules mirror Ruby's coercion
  contract — `Array(nil) -> []`, an existing `Array[E]`
  preserves its element, a Tuple materialises to
  `Array[T1|T2|…]`, and a Union distributes element-wise and
  unifies. Opaque shapes (Top / Dynamic / Bot) fall through to
  the existing RBS-tier envelope. Worked example: in
  `lib/rigor/analysis/fact_store.rb#fact_targets`,
  `Array(fact.target)` over `fact.target: Target |
  Array[Target]` previously typed as `Array[Dynamic[top]]`;
  it now types as `Array[Target]`.
- **Branch-aware scope propagation for expression-position
  conditionals.** `Inference::ScopeIndexer.propagate` now
  special-cases `Prism::IfNode` and `Prism::UnlessNode`,
  threading the predicate's narrowed truthy / falsey scopes
  into the corresponding branch subtrees. Previously, when
  an `if` / `unless` sat in expression position (e.g. as a
  call argument or the RHS of an `[]=`), the indexer never
  routed it through `eval_if`'s narrowing path, so inner
  nodes inherited the un-narrowed entry scope and downstream
  rules (`possible-nil-receiver`, type-of probes) saw
  spurious `T | nil`. Worked example:
  `cache[k] = if x; x.foo; else; default; end` now sees `x`
  narrowed to its non-nil fragment inside the truthy branch,
  matching the behaviour for the statement-level form
  `if x; cache[k] = x.foo; else; cache[k] = default; end`.
  Specs at
  `spec/rigor/inference/scope_indexer_spec.rb#narrows IfNode
  branches when the conditional sits in expression position`
  (and the `UnlessNode` mirror) bind both shapes.
- **`RbsLoader#instance_definition` /
  `#singleton_definition` now declared as `untyped?`.** The
  earlier sig form (`untyped`) was a workaround for the
  truthy-narrowing gap above; with that gap closed, the sig
  can faithfully reflect the impl's `nil`-on-unknown-class
  return contract.
- **Two-argument constant-fold dispatch.**
  `MethodDispatcher::ConstantFolding#try_fold` previously
  switched on `args.size` and only handled the 0- and 1-arg
  shapes; 2-arg leaf methods like `Comparable#between?(min,
  max)`, the explicit-bounds form of `Comparable#clamp(min,
  max)`, and `Integer#pow(exp, mod)` all bailed to the
  RBS-widened tier. The dispatch now grows a `when 2` arm
  routed through `try_fold_ternary`, which folds the cartesian
  product of receiver × arg0 × arg1 when every operand is a
  `Constant` (or `Union[Constant…]`) and the catalog
  classifies the method `:leaf` / `:trivial`. The same
  `UNION_FOLD_INPUT_LIMIT` cap that gates the binary path
  guards the cartesian explosion. IntegerRange operands are
  reserved for a follow-up — any range receiver or arg short-
  circuits the ternary path so the RBS tier still answers.
  Worked examples: `5.between?(0, 10)` folds to
  `Constant[true]`, `100.clamp(0, 10)` folds to
  `Constant[10]`, `100.pow(50, 17)` folds to `Constant[4]`.
  Direct payoff for the just-landed include-aware lookup:
  `between?` was the canonical 2-arg method blocked by the
  arity gate. End-to-end fixture:
  `spec/integration/fixtures/two_arg_fold.rb`.
- **`tool/catalog_diff.rb` + `make catalog-diff`.** Prints the
  surface-level diff between two
  `data/builtins/ruby_core/<topic>.yml` snapshots — per-class
  additions / removals / purity changes / cfunc renames /
  arity changes. The motivating use is a `references/ruby`
  submodule bump where the full YAML diff is noisy because it
  interleaves prose comments, RBS pulls, and `defined_at` line
  numbers; this tool extracts the catalog-semantic deltas a
  reviewer has to look at. Default invocation:
  `make catalog-diff BEFORE=… AFTER=…`.
- **C-body classifier detects pure `rb_check_frozen` wrappers
  as mutators.** Per-class wrappers like `time_modify(time)` /
  `time_gmtime(time)` whose entire body is one or more
  `rb_check_frozen(...)` calls used to be classified `:leaf`
  even though they centralise the mutation gate of the
  receiver. `CBodyIndex#mutator_helpers` now returns the set
  of indexed cfuncs whose body matches the pure-frozen-check
  pattern, and `CBodyClassifier.classify` flips the `:mutate`
  effect on when a method calls one of those helpers. The
  pattern is intentionally narrow — naive transitive
  propagation over-flagged legitimate non-mutators like
  `Array#to_a`, so only bodies that consist solely of
  `rb_check_frozen` calls qualify. Re-extraction flips two
  Time methods (`#gmtime`, `#utc`, both bound to `time_gmtime`)
  from `:leaf` to `:mutates_self`; every other catalog
  regenerates byte-identically.
- **Include-aware module-catalog fallthrough activates the
  Comparable / Enumerable imports.**
  `MethodDispatcher::ConstantFolding#catalog_allows?` walks the
  receiver class's `Module#ancestors` and consults the
  imported module catalogs (`COMPARABLE_CATALOG`,
  `ENUMERABLE_CATALOG`) when the primary class catalog has no
  entry for the method. Resolution: primary class catalog
  first (its `rb_define_method` registration is authoritative
  even when the entry is classified `:dispatch`), module
  catalogs only when the primary has no entry. The user-visible
  payoff: methods that come purely from an `include Comparable`
  / `include Enumerable` mixin without a direct
  `rb_define_method` registration now fold. Worked example:
  `5.clamp(0..10)` folds to `Constant[5]`,
  `100.clamp(0..10)` folds to `Constant[10]`. `Comparable#between?`
  and Enumerable's block-shaped methods need the dispatch
  tier's two-arg / block-parameter paths and remain unfolded
  (tracked as a follow-up). End-to-end fixture:
  `spec/integration/fixtures/include_aware_clamp.rb`.
- **Comparable and Enumerable module catalog imports.** New
  `data/builtins/ruby_core/comparable.yml` and
  `enumerable.yml` generated by
  `tool/extract_builtin_catalog.rb` from `Init_Comparable`
  (compar.c) and `Init_Enumerable` (enum.c). Catalog stats:
  Comparable ships with 7 instance methods (the `<`/`<=`/`==`/
  `>=`/`>`/`between?`/`clamp` family); Enumerable ships with 58
  instance methods (47 `:block_dependent`, 9 `:leaf`, 2
  `:mutates_self`). The matching `Builtins::COMPARABLE_CATALOG`
  / `Builtins::ENUMERABLE_CATALOG` singletons are loaded at
  boot but NOT registered in
  `MethodDispatcher::ConstantFolding::CATALOG_BY_CLASS` because
  modules are not receiver classes the dispatcher routes
  through; the data is in place for a future include-aware
  lookup that walks the receiver's ancestor chain.
- **`tool/scaffold_builtin_catalog.rb --module`.** The scaffold
  script gains a module mode that skips the
  `CATALOG_BY_CLASS` row, the fixture stub, and the
  integration `describe` block — none of those make sense
  until include-aware dispatch ships. The loader file gets a
  module-aware banner; the require_relative is still inserted
  so the singleton is reachable. The associated extractor
  upgrade (`MODULE_DEFINE_RE`) recognises
  `rb_mFoo = rb_define_module("Foo");` registrations and
  records modules in the per-topic `classes` map with
  `parent: "Module"`. Two previously-dropped module
  registrations (`FileTest` in Init_File, `UnicodeNormalize`
  in Init_String) now surface as empty-bucket class entries
  in their respective YAMLs.
- **`~refinement` negation extends to IntegerRange and
  Intersection.** `Narrowing.narrow_not_refinement` previously
  only handled `Difference[base, Constant[v]]`; the algebra
  now covers two more carrier kinds:
  - `Type::IntegerRange[a, b]` — complement is the two open
    halves `int<min, a-1>` and `int<b+1, max>`, each
    intersected with the integer-domain parts of
    `current_type`. Non-integer parts of a Union receiver
    survive unchanged. `assert n is ~int<5, 10>` over
    `n: Integer` narrows to `int<11, max> | int<min, 4>`.
    End-to-end fixture:
    `spec/integration/fixtures/assert_negation_integer_range/`.
  - `Type::Intersection[M1, M2, …]` — De Morgan: `D \ (M1 ∩
    M2) = (D \ M1) ∪ (D \ M2)`. Each member's complement is
    computed independently and unioned; members the algebra
    cannot complement (Refined, non-Constant Difference)
    contribute `current_type` itself, so the union may widen.
    `~non-empty-lowercase-string` over `String` therefore
    yields `Constant[""] | Nominal[String]` rather than the
    tighter `Constant[""]` we'd get with predicate-aware
    complement. `Refined[base, predicate]` keeps its
    conservative `current_type` answer (predicate complements
    are not finite-carrier-expressible).
- **`~refinement` negation in `assert:` / `predicate-if-*:`
  directives.** The `<target> is <RHS>` right-hand side now
  accepts the `~T` negation prefix on the refinement arm in
  addition to the existing class-name arm. The narrowing tier
  introduces `Narrowing.narrow_not_refinement` for the
  Difference + Constant-removed shape: it walks the current
  type's union members, keeps each part disjoint from the
  refinement's base, and adds the removed-value Constant
  exactly once when any current member covers it.

  ```rbs
  class Validator
    %a{rigor:v1:assert value is ~non-empty-string}
    def assert_empty!: (::String value) -> void
  end
  ```

  After `v.assert_empty!(name)` over `name: String | nil`, the
  narrowed type is `Constant[""] | NilClass` — the only
  inhabitants of the original union that are NOT non-empty
  strings. Other refinement carriers (`Refined`, `Intersection`,
  `IntegerRange`, and `Difference` whose removed is not a
  Constant) return `current_type` unchanged for now;
  predicate-complement and bounded-range complement are
  follow-up slices. End-to-end fixture:
  `spec/integration/fixtures/assert_negation_refinement/`.
- **`group_by` / `partition` / `each_slice` / `each_cons`
  block-parameter projections (placeholder; future plugin).**
  RBS already binds these methods correctly for plain
  `Array[T]` / `Set[T]` / `Range[T]` receivers via generic
  substitution; the new IteratorDispatch arms exist so Tuple-
  and HashShape-shaped receivers reach the block body with the
  precise per-position element union (or `Tuple[K, V]` pair)
  rather than the projected `Array[union]` widening.
  `group_by` / `partition` yield a single element; `each_slice`
  and `each_cons` yield `Array[element]` (the slice-size
  argument is ignored at the dispatcher tier — a tighter
  Tuple-of-`n` carrier is reserved for the plugin tier). The
  scope is intentionally narrow — the longer-term direction is
  to move Enumerable-aware projections into a plugin tier
  modelled after PHPStan's extension API (ADR-2). The
  placeholder rules will be reimplemented and removed once the
  plugin surface ships. Self-asserting fixture:
  `spec/integration/fixtures/enumerable_collect.rb`.
- **Memo-typed Enumerable block-parameter projections.**
  `IteratorDispatch` covers `#each_with_object` (yields
  `(element, memo)` where the memo type follows the second
  argument's actual type) and `#inject` / `#reduce` (yields
  `(memo, element)`). The inject family handles three call
  shapes:
  - `inject(seed) { |memo, elem| … }` — `[seed_type, element_type]`.
  - `inject { |memo, elem| … }` — both block params bind to the
    receiver's element type (Ruby's first-element-as-memo
    semantics).
  - `inject(:+)` / `inject(seed, :+)` — Symbol-call forms have
    no block; the dispatcher recognises and declines.

  Self-asserting fixture: `spec/integration/fixtures/enumerable_memo.rb`.
- **Date / DateTime catalog import.** New `data/builtins/ruby_core/date.yml`
  generated from `Init_date_core` in
  `references/ruby/ext/date/date_core.c` plus the `lib/date.rb`
  prelude. Both classes land in a single topic — DateTime
  inherits from Date and the same Init function registers both,
  so `tool/extract_builtin_catalog.rb` carries one entry with two
  RBS bindings (`date.rbs`, `date_time.rbs`). Catalog stats:
  2 classes, 96 instance methods, 60 singleton methods,
  149 `:leaf` / 2 `:mutates_self` / 3 `:block_dependent`
  classifications. The blocklist in
  `lib/rigor/inference/builtins/date_catalog.rb` covers
  `:initialize_copy` (defensive symmetry with String / Array /
  Range / Set / Time) and Date's `#ifndef NDEBUG`-only `:fill`
  helper, plus a mirrored `:initialize_copy` entry for the
  DateTime side. `MethodDispatcher::ConstantFolding` routes
  `Date` and `DateTime` receivers through the new
  `DATE_CATALOG`; the DateTime row precedes Date in
  `CATALOG_BY_CLASS` so subclass receivers hit their dedicated
  entry first. Self-asserting fixture
  `spec/integration/fixtures/date_catalog/` exercises the
  Integer-typed reader surface (`#year` / `#month` / `#day` /
  `#wday` / `#hour` / `#min` / `#sec`), the boolean predicate
  surface (`#leap?` / `#julian?` / `#sunday?`), the String-typed
  formatters (`#to_s` / `#iso8601` / `#strftime`), and the
  navigation methods (`#next_day` / `#prev_day` / `#next_month` /
  `#prev_year` / `#succ` / `#>>` / `#<<`) that return brand-new
  Date objects rather than mutating the receiver. No
  `RBS::Extended rigor:v1:return:` overrides this slice — the
  reader surface is in the same situation as Time, where
  per-method ranges (`#month` ∈ `int<1, 12>`) would need a
  parameterised IntegerRange overlay that's out of scope.

### Fixed

- **Cross-line block comments in `tool/extract_builtin_catalog.rb`.**
  `CInitParser#join_continuations` walks the Init function body
  line by line and tracks paren depth to merge multi-line
  registration macros into a single logical line. The previous
  `strip_line_comments` helper only stripped `/* … */` runs that
  fit on one line, so multi-line rdoc blocks (very common above a
  `rb_define_class` call — `cDateTime = rb_define_class("DateTime", cDate);`
  in `date_core.c` is preceded by a 200-line `/* … */` block)
  contributed unbalanced parens to the depth counter and made the
  next code line merge into a comment buffer. The fix
  pre-strips block comments from the entire C source while
  preserving newlines so per-line indexing remains valid. Without
  the fix DateTime's class-registration line was silently dropped
  and the catalog only saw `Date`.

## [0.0.4] - 2026-05-02

The fourth preview. Theme: **finish the OQ3 refinement-carrier
strategy and broaden the RBS::Extended directive surface**.

The OQ3 carrier triple (`Type::Difference` from v0.0.3 plus the
new `Type::Refined` and `Type::Intersection`) is feature-complete
against the imported-built-in catalogue ([`docs/type-specification/imported-built-in-types.md`](docs/type-specification/imported-built-in-types.md)),
so authors can express the full set of refinement names from
`%a{rigor:v1:…}` annotations and the analyzer projects them
through method dispatch, acceptance, and the `argument-type-mismatch`
check rule symmetrically.

The `RBS::Extended` directive surface picks up `rigor:v1:param:`
(both at the call boundary and inside the method body via
`MethodParameterBinder`) and the existing `assert*` /
`predicate-if-*` family now accepts refinement payloads on the
right-hand side.

The built-in catalog import pipeline gains four more classes
(Hash / Range / Set / Time) plus a `tool/scaffold_builtin_catalog.rb`
script that automates the mechanical 70 % of each new import.

Test count: 1148 → 1250 examples (+102), RuboCop clean,
`bundle exec exe/rigor check lib` reports 0 diagnostics.

### Added

#### OQ3 refinement carriers

- **`Type::Refined` carrier (predicate-subset half).** Sibling
  of `Type::Difference`. Wraps `(base, predicate_id)` where
  `predicate_id` is a Symbol drawn from
  `Type::Refined::PREDICATES`. Construction goes through
  `Type::Combinator.refined(base, predicate_id)` and the
  per-name factories listed below. RBS erasure folds the carrier
  back to its base nominal. Gradual-mode acceptance mirrors the
  conservative `accepts_difference` policy — same-predicate
  `Refined` plus recognised `Constant` values get `:yes`, every
  other shape gets `:no`.
- **`Type::Intersection` carrier — composed refinement names.**
  Closes the OQ3 carrier strategy by adding the Intersection
  peer alongside `Union` / `Difference` / `Refined`. The carrier
  represents the meet of its members' value sets. Construction
  performs the deterministic normalisation in
  `docs/type-specification/value-lattice.md` —
  flatten / drop-Top / Bot-absorb / dedupe / sort / 0-1 collapse
  — so two equal intersections compare equal regardless of
  construction order. Acceptance is conjunctive on the LHS and
  disjunctive on the RHS, plus a top-level structural-equality
  short-circuit. `ShapeDispatch.dispatch_intersection` combines
  per-member projections through an IntegerRange meet when every
  result is bounded-integer, so `(non_empty_string ∩
  lowercase_string).size` resolves to `positive-int` rather than
  the looser `non-negative-int`.
- **Fourteen imported built-in refinement names.** All resolvable
  through `Builtins::ImportedRefinements` (and through the
  per-name factories on `Type::Combinator`):
  - **Point-removal** (already in v0.0.3): `non-empty-string`,
    `non-zero-int`, `non-empty-array[T]`, `non-empty-hash[K, V]`.
  - **IntegerRange aliases** (already in v0.0.3): `positive-int`,
    `non-negative-int`, `negative-int`, `non-positive-int`.
  - **Predicate** (new): `lowercase-string`, `uppercase-string`,
    `numeric-string`, `decimal-int-string`, `octal-int-string`,
    `hex-int-string`. The base-N int-string predicates are
    disjoint by design — `:octal_int` and `:hex_int` REQUIRE
    their conventional prefix (`0o` / `0O` / leading `0`;
    `0x` / `0X`), so a bare `"755"` is `decimal-int-string`,
    not `octal-int-string`.
  - **Composed Intersection** (new):
    `non-empty-lowercase-string`, `non-empty-uppercase-string`.
- **Catalog-tier projections over `Refined[String, …]`.**
  `String#downcase` / `String#upcase` fold per predicate:
  case-fold idempotence for `:lowercase` / `:uppercase` /
  `:numeric` and the three base-N int-string predicates, plus
  the lift `lowercase ↔ uppercase` for the cross calls. Size-tier
  projections still apply through the predicate carrier so
  `String#size` over a `Refined[String, *]` tightens to
  `non-negative-int`.
- **Self-asserting fixtures.** `predicate_refinement/`,
  `intersection_refinement/`, `parameterised_refinement/`, plus
  the existing `refinement_return_override/` from v0.0.3.

#### `RBS::Extended` directive surface

- **`rigor:v1:return:` accepts parameterised refinement payloads.**
  In addition to the bare-name shapes, the directive now accepts
  `non-empty-array[T]` / `non-empty-hash[K, V]` (type-arg payloads
  where `T` / `K` / `V` may be a kebab-case refinement name or a
  Capitalised RBS class name) and `int<min, max>` (bounded-integer
  range with signed integer literals). Parsing lives in a new
  `Builtins::ImportedRefinements::Parser` recursive-descent parser
  exposed through `ImportedRefinements.parse(payload)`. Failure is
  fail-soft — any parse miss returns nil and the directive site
  falls back to the RBS-declared type.
- **`rigor:v1:param: <name> [is] <refinement>` directive.**
  Symmetric to the `return:` route landed in v0.0.3 and
  feature-complete on both sides of the method boundary:
  - **Call-site half.** `OverloadSelector` and the
    `argument-type-mismatch` check rule consult
    `RbsExtended.param_type_override_map(method_def)` and prefer
    the override over the RBS-translated type so a too-wide call
    site is flagged.
  - **Body-side half.** `MethodParameterBinder` reads the same
    override map and replaces the RBS-translated parameter
    binding with the refinement, so projections through the
    carrier (e.g. `id.size` resolving to `positive-int` over a
    `non-empty-string` parameter) are observable inside the
    method body during inference.

  The optional `is` glue word matches the existing
  `assert` / `predicate-if-*` surface; authors MAY write
  `param: id non-empty-string` instead. End-to-end fixture:
  `spec/integration/fixtures/param_extended/`.
- **`rigor:v1:assert:` and `rigor:v1:predicate-if-*:` accept
  refinement payloads.** The `<target> is <RHS>` right-hand side
  now matches either a Capitalised class name (existing
  behaviour) or a kebab-case refinement payload. Both
  `AssertEffect` and `PredicateEffect` gain a `refinement_type`
  field; the narrowing tier substitutes the carrier when
  present, keeping the legacy `narrow_class` path for class-name
  directives. Refinement-form directives do not yet support
  `~T` negation — that would require a
  difference-against-refinement algebra and is reserved for a
  future slice.

#### CLI / display

- **CLI `type-of` confirms the kebab-case canonical-name
  contract.** New regression specs in `spec/rigor/cli_spec.rb`
  drive `bundle exec exe/rigor type-of` through the harness over
  both a `Difference`-backed refinement (`non-empty-string`) and
  `Refined`-backed refinements (`lowercase-string`,
  `numeric-string`), and assert that human-readable text and
  `--format=json` output both render the refinement in its
  kebab-case spelling while erasure folds back to the base
  nominal.

#### Built-in catalog imports

- **`Hash` joins the catalog-driven inference pipeline.**
  `data/builtins/ruby_core/hash.yml` is generated from
  `references/ruby/hash.c`. `Builtins::HASH_CATALOG` consumes
  it; the constant-fold dispatcher routes Hash receivers
  through it. Pure readers (`size` / `[]` / `include?` /
  `dig` / `invert` / `compact` / …) clear the catalog tier;
  block-yielding helpers that the C-body classifier mis-flags
  as `:leaf` (`each` / `select` / `transform_values` / `merge`,
  …) are blocklisted.
- **`Range` joins the catalog-driven inference pipeline.**
  `data/builtins/ruby_core/range.yml` covers 30 instance
  methods. Methods that fold today on a `(begin..end)` literal
  include `#begin`, `#end`, `#size`, `#exclude_end?`,
  `#include?`, `#cover?`, `#member?`. The block-iterating
  surface (`#each`, `#step`, `#first`, `#min`, `#max`,
  `#minmax`, `#count`) classifies as `block_dependent` and is
  blocked by the foldable-purity check. The Range slice also
  taught `tool/extract_builtin_catalog.rb` to recognise
  `rb_struct_define_without_accessor` so future struct-defined
  topics become drop-in additions.
- **`Set` joins the catalog-driven inference pipeline.**
  `data/builtins/ruby_core/set.yml` is generated from
  `Init_Set` in `references/ruby/set.c` (Set was rewritten in
  C and folded into CRuby for Ruby 3.2+). Per-class blocklist
  drops false-positive `:leaf` classifications for the
  indirect mutators (`initialize_copy`, `compare_by_identity`,
  `reset`), the block-yielding helpers (`each`, `classify`,
  `divide`), and `disjoint?`.
- **`Time` joins the catalog-driven inference pipeline.**
  `data/builtins/ruby_core/time.yml` is generated from
  `Init_Time` in `references/ruby/time.c` plus the
  `references/ruby/timev.rb` prelude (compiled into
  `timev.rbinc` and `#include`d at the bottom of `time.c`); the
  prelude path carries `Time.now` / `Time.at` / `Time.new` into
  the singleton-method bucket. The catalog records 58 instance
  methods (48 `:leaf`, 8 `:dispatch`, 3 `:mutates_self`, 3
  `:unknown`), 4 singleton methods, and the
  `iso8601` ↔ `xmlschema` alias. Per-class blocklist catches
  `localtime` / `gmtime` / `utc` (all call `time_modify(time)` to
  mark the receiver mutable but the C-body classifier mis-flags
  them `:leaf`).

#### Enumerable-aware projections

- **`#each_with_index` block-parameter typing.**
  `IteratorDispatch` generalises beyond Integer iteration to
  project the element type per receiver shape (Array / Set /
  Range nominals, Tuple, HashShape, Hash nominal,
  Constant<Array>, Constant<Range>) and tightens the index slot
  to `non-negative-int` over the RBS-declared `Integer`.
  Self-asserting fixture: `spec/integration/fixtures/each_with_index.rb`.

#### Tooling

- **`tool/scaffold_builtin_catalog.rb`.** Automates the
  mechanical 70 % of a new built-in catalog import: writes the
  TOPICS entry, the optional `BASE_CLASS_VARS` row, the loader
  file with a TODO blocklist marker, the `CATALOG_BY_CLASS` row
  + `require_relative`, the integration fixture stub, and the
  describe block. Manual follow-ups (blocklist curation,
  fixture body, CHANGELOG bullet) are printed as a checklist on
  exit. `--dry-run` previews the planned edits;
  `--init-fn` / `--rbs` / `--rb-prelude` override defaults for
  upstream layouts that diverge. Documented as Stage 0 of the
  `rigor-builtin-import` skill.

### Changed

- **`MethodDispatcher::ConstantFolding#catalog_for` is table-
  driven.** A `CATALOG_BY_CLASS` array of
  `(receiver_class, [catalog, class_name])` pairs replaces the
  growing `case` statement. Adding a class catalog is now a
  one-line addition rather than another `when` arm, and the
  dispatcher's cyclomatic complexity stays bounded as the
  catalogue grows.

### Fixed

- **`accepts_nominal` projects refinement carriers to base.** A
  Nominal accepting a `Difference` or `Refined` previously fell
  through to `:no` because `accepts_nominal`'s case statement had
  no branch for refinement kinds. The carrier's value set is
  contained in its base nominal's, so projecting to `other.base`
  and re-running acceptance is sound — a latent bug surfaced
  while wiring the Intersection conjunction.
- **`provably_disjoint_from_removed?` for nested Difference.**
  `Difference[A, R].accepts(Difference[B, R])` previously
  required the inner difference's BASE to be provably disjoint
  from `R`, which never holds (a Nominal base contains the
  removed value by construction). Same-`removed` now suffices
  because the disjointness is exhibited at the inner difference
  layer.

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

[Unreleased]: https://github.com/rigortype/rigor/compare/v0.0.6...HEAD
[0.0.6]: https://github.com/rigortype/rigor/compare/v0.0.5...v0.0.6
[0.0.5]: https://github.com/rigortype/rigor/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/rigortype/rigor/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/rigortype/rigor/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/rigortype/rigor/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/rigortype/rigor/releases/tag/v0.0.1
