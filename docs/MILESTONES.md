# Release Milestones

Tracks the deliberately-scoped envelope around each preview release. Items inside a milestone are commitments; items outside it are deferred. The line between "in" and "out" is what makes each release shippable.

This file is informational, not normative. The binding contracts live in [`docs/adr/`](adr/) and [`docs/type-specification/`](type-specification/). When this file disagrees with an ADR or spec, the ADR / spec binds and this file is out of date.

## v0.0.3 — Released 2026-05-02

The third preview. Theme: **see literal values where the analyzer can prove them**, across a wide enough surface that real Ruby programs benefit without per-call-site annotation. See `CHANGELOG.md` for the full added/fixed list.

Major surfaces landed:

- Aggressive constant folding (unary + binary + Union[Constant…] cartesian + integer-range arithmetic + Tuple-shaped divmod).
- `Type::IntegerRange` carrier with the PHPStan-style `int<min, max>` family (`positive-int`, `negative-int`, `non-negative-int`, `non-positive-int`, `int<a, b>`).
- Built-in method catalog extraction pipeline (`tool/extract_builtin_catalog.rb`) covering Numeric / Integer / Float / String / Symbol / Array / IO / File. Generated YAML under `data/builtins/ruby_core/`. Catalog-driven dispatch with per-class mutator blocklists.
- Scope-level integer-range narrowing through `<` / `<=` / `>` / `>=` / `positive?` / `negative?` / `zero?` / `nonzero?` / `between?`.
- `case/when` integer-range and integer-literal narrowing.
- Iterator block-parameter typing for `times` / `upto` / `downto`.
- Branch elision on provably-truthy/falsey predicates.
- `Tuple`-shaped `Integer#divmod` / `Float#divmod` folds.
- `Type::Difference` carrier (point-removal half of OQ3); `non-empty-string`, `non-zero-int`, `non-empty-array[T]`, `non-empty-hash[K, V]` reachable through `RBS::Extended`'s new `rigor:v1:return:` directive.
- `always-raises` diagnostic for provable Integer division-by-zero.
- `File` path-manipulation folding gated behind `fold_platform_specific_paths` config (default off, platform-agnostic).
- ADR-5 (robustness principle) and the OQ1 / OQ2 / OQ3 working decisions in ADR-3.

## v0.0.4 — Released 2026-05-02

The fourth preview. Theme: **finish the OQ3 refinement-carrier strategy and broaden the RBS::Extended directive surface**. See `CHANGELOG.md`'s `[0.0.4]` section for the full added/changed/fixed list.

Major surfaces landed:

- `Type::Refined` carrier (OQ3 predicate-subset half) and `Type::Intersection` carrier (composed refinement names) — together with `Type::Difference` from v0.0.3, the OQ3 carrier triple is feature-complete.
- Fourteen imported built-in refinement names resolvable through `Builtins::ImportedRefinements`: the v0.0.3 point-removal four, the v0.0.3 IntegerRange-aliased four, the new predicate six (`lowercase-string`, `uppercase-string`, `numeric-string`, `decimal-int-string`, `octal-int-string`, `hex-int-string`), and the new composed two (`non-empty-lowercase-string`, `non-empty-uppercase-string`).
- `RBS::Extended` directive surface complete on both sides of the boundary: `rigor:v1:return:` (now accepts parameterised payloads), `rigor:v1:param:` (call-site argument-type-mismatch rule + body-side `MethodParameterBinder` narrowing), `rigor:v1:assert:` and `rigor:v1:predicate-if-*:` (now accept refinement payloads in addition to class names).
- Hash / Range / Set / Time built-in catalog imports through `tool/extract_builtin_catalog.rb`. `MethodDispatcher::ConstantFolding#catalog_for` is now table-driven (`CATALOG_BY_CLASS`) so further imports cost one row.
- Enumerable-aware `#each_with_index` block-parameter typing in `IteratorDispatch` — element type is projected per receiver shape, index slot tightens to `non-negative-int`.
- `tool/scaffold_builtin_catalog.rb` automates the mechanical 70 % of new built-in catalog imports (Stage 0 of the `rigor-builtin-import` skill).
- CLI `type-of` regression specs binding the kebab-case canonical-name display contract for refinement-bearing types in both human-readable and `--format=json` output.

## v0.0.5 — Released 2026-05-03

Theme: **continue catalog coverage, broaden the Enumerable-aware projections, and absorb the Steep cross-checker triage follow-ups**. See `CHANGELOG.md`'s `[0.0.5]` section for the full added/changed list.

Major surfaces landed:

- Comparable / Enumerable module catalog imports + `tool/scaffold_builtin_catalog.rb --module` mode.
- Date / DateTime catalog imports (stdlib gems under `references/ruby/ext/date/`).
- Rational and Complex catalog imports — landed via parallel worktree-isolated agents.
- Include-aware module-catalog fallthrough in `MethodDispatcher::ConstantFolding#catalog_allows?` activates the Comparable / Enumerable imports for direct (non-redefined) callers.
- 2-argument constant-fold dispatch (`try_fold_ternary`) folds `Comparable#between?(min, max)`, `Comparable#clamp(min, max)`, `Integer#pow(exp, mod)`.
- `narrow_not_refinement` extended to IntegerRange (paired-bound complement) and Intersection (De Morgan); refinement negation (`~T`) now accepted as the RHS of `assert` / `predicate-if-*` directives.
- C-body classifier — pure `rb_check_frozen` wrapper detection reclassifies `Time#gmtime` / `Time#utc` from `:leaf` to `:mutates_self`.
- `tool/catalog_diff.rb` + `make catalog-diff` target for surface-level diffs between two YAML snapshots.
- **Steep cross-checker scaffolding.** `tool/steep/` ships Steep 2.0 as an isolated sibling Bundler (`make steep-check`) for sig / impl drift detection. Triage report and category breakdown in [`docs/notes/20260503-steep-cross-check-triage.md`](notes/20260503-steep-cross-check-triage.md). The triage's mechanical fixes (A-1 through A-5: predicate sigs, IntegerRange narrowing, scope_indexer arity, env duplication, CLI kwarg defaults) all landed.
- **Branch-aware scope propagation for expression-position conditionals.** `Inference::ScopeIndexer.propagate` now routes IfNode / UnlessNode branches through `Narrowing.predicate_scopes`, fixing a class of false-positives where an `if` / `unless` buried inside a CallNode argument or `[]=` RHS never reached `eval_if`'s narrowing path.
- **`Kernel#Array` precision tier (`MethodDispatcher::KernelDispatch`).** Folds `Array(arg)` into a precise `Array[E]` whenever the argument's value-lattice shape lets us prove the element type. Distributes element-wise over unions and unifies.
- **`Const = Data.define(*Symbol)` discovery.** `Inference::ScopeIndexer.record_declarations` registers `Const` (qualified by the surrounding path) as a discovered class so `Const.new(...)` resolves to `Nominal[<qualified>]` via `meta_new`. Override-aware initializer-signature dispatch (using the block's `def initialize(...)` as the canonical sig) remains open as a follow-up.

Deferred from v0.0.5 (carried forward):

- Predicate-complement narrowing for `Refined[base, predicate]` — needs either a new mixed-case carrier or per-predicate paired-complement registry entries.
- Block-shaped fold dispatch — folding the block's *return* into a precise carrier on top of the existing `IteratorDispatch` block-parameter typing; IntegerRange operands on the 2-arg path are also still held back.
- Further catalog imports — URI and Kernel fall outside the standard import skill's premise (Kernel methods scatter across 20+ C files with no single Init function; URI is a pure-Ruby stdlib gem with no C surface). Both need a hand-rolled or custom-scaffold approach. Pathname (already partial) and ObjectSpace remain in the candidate pool.
- C-body classifier — wider transitive mutator scan that does not over-flag legitimate non-mutators (the `Array#to_a` regression that gated the conservative v0.0.5 fix).
- `Data.define` override-aware initializer dispatch — block-body `def initialize(...)` as the canonical sig for `Const.new` (today the auto-generated kw shape wins).
- `Trinary` return-type contract on type-carrier predicate methods — closing the strict-on-returns gap requires a new CheckRules rule family (`return-type-mismatch`), explicitly deferred by [`docs/CURRENT_WORK.md`](CURRENT_WORK.md) until the inference surface is sturdy enough to avoid false-positive churn.
- Cross-checker runner integration — `make steep-check` stays out-of-band; the Steep residual (6 warnings, all in `fact_store.rb` and rooted in Steep-side limitations Rigor closes natively) is the steady-state floor.

(Stretch surfaces carry forward into the v0.0.6 row below.)

## v0.0.6 — Released 2026-05-05

The sixth preview. Theme: **fold block-taking Enumerable methods through the constant-folding tier** so iterator-shaped expressions over literal collections produce precise carriers instead of widening through RBS. See `CHANGELOG.md`'s `[0.0.6]` section for the full added / fixed list.

Major surfaces landed:

- **`MethodDispatcher::BlockFolding` precision tier.** `dispatch_precise_tiers` consumes the existing `block_type:` and folds the constant-block side of `select` / `filter` / `reject` / `take_while` / `drop_while` / `all?` / `any?` / `none?` / `find` / `detect` / `find_index` / `index` / `count`. Filter methods collapse to either the receiver or `Tuple[]`; predicate methods produce `Constant[bool]` whenever the receiver-emptiness × block-truthiness combination is unconditional in Ruby's semantics; find-family methods fold to `Constant[nil]` on the falsey side and to `Constant[size]` / `Constant[0]` for `count`.
- **`ExpressionTyper#try_per_element_block_fold` over Tuple receivers** for `map` / `collect` / `filter_map` / `flat_map` / `find` / `detect` / `find_index` / `index`. The block body is type-checked once per Tuple position, then assembled per-method into a precise Tuple. Numbered parameters (`_1`) participate identically.
- **Per-element fold over short `Constant<Range>` receivers**, capped at 8 elements so `(1..3).map { |n| n.to_s }` resolves to `["1", "2", "3"]` without exploding for million-element ranges.
- **Branch elision for expression-position conditionals.** `if` / `unless` / ternary expressions whose predicate folds to a `Type::Constant` drop the unreachable branch. `&&` / `||` short-circuit on Constant-shaped left operands following Ruby's actual semantics. Composes through three layers so `[1, 2, 3].filter_map { |n| n.even? ? n.to_s : nil }` resolves to `Tuple[Constant["2"]]`.
- **IntegerRange-aware ternary fold.** The 2-arg `try_fold_ternary` path accepts `IntegerRange` receivers paired with scalar `Constant<Integer>` args for `Comparable#between?` / `Comparable#clamp`. `int<3, 7>.between?(0, 10)` folds to `Constant[true]`; `int<3, 7>.clamp(4, 6)` folds to `int<4, 6>`.
- **Empty array literal carrier — `[]` → `Tuple[]`.** Pins the literal's known arity so `:flat_map` can concatenate cleanly across all-empty per-position results.
- **Pathname catalog import** (102 instance methods, 2 singletons, 5 aliases) via `tool/scaffold_builtin_catalog.rb --init-fn InitVM_pathname`. Pathname is a thin wrapper that mostly delegates to File / Dir / FileTest, so the user-visible payoff is narrower than Numeric or String — the import buys receiver-class recognition, a defensive `:initialize_copy` blocklist entry, and `:leaf` folding for `<=>`.
- **Extractor BeginNode-bodied-`def` classifier fix.** `PreludeParser#analyse_body` previously raised on the rescue-on-def idiom (`def foo; …; rescue; …; end`). The classifier now descends into the begin-block's `statements`. Surfaced importing Pathname; every catalog regenerates cleanly under `make extract-builtin-catalogs`.

Deferred from v0.0.6 (carried forward):

- Predicate-complement narrowing for `Refined[base, predicate]` — still needs either a new mixed-case carrier or per-predicate paired-complement registry entries.
- C-body classifier wider transitive mutator scan that does not over-flag legitimate non-mutators.
- `Data.define` override-aware initializer dispatch — block-body `def initialize(...)` as the canonical sig for `Const.new`.
- `Trinary` return-type contract on type-carrier predicate methods — still deferred until the inference surface is sturdy enough to avoid false-positive churn.
- Cross-checker runner integration — `make steep-check` stays out-of-band.
- Further catalog imports — URI and Kernel still fall outside the standard import skill's premise. ObjectSpace is in the candidate pool but is a thin module (5 module functions defined under `Init_GC`); the user-visible payoff is small.
- `:flat_map` over `Nominal[Array[T]]` per-position results — largely subsumed by the existing RBS substitution; not worth a dedicated slice.

Stretch surfaces (carried forward unchanged):

- Pathname / URI delegation rules so `Pathname#exist?` etc routes through `File.exist?` projections.
- `String#%` format-string parsing for catalog-aware fold over `Constant<String>` template + `Constant<…>` values.
- `numeric-string` recogniser that classifies `String#match?(/\A\d+\z/)` as a `Refined[String, :numeric]` narrowing.

## v0.0.7 — Planned

Theme: **pre-plugin coverage push**. Close the gap between what the type-language and built-in-coverage specs already commit to and what the analyzer actually implements, so the plugin API designed against this surface in v0.1.0 has a complete substrate to attach to. Breadth-over-depth: many small fills, no architecture changes.

Planned surfaces (operational slice order):

1. **`key_of[T]` / `value_of[T]` type functions.** Listed in the "Initial type functions" table of [`imported-built-in-types.md`](type-specification/imported-built-in-types.md) but unimplemented. Project a `HashShape` / `Tuple` / `Hash[K, V]` into the type-level set of keys (resp. values). Parser registry entries plus projection rules.
2. **`int_mask[…]` / `int_mask_of[T]`.** Same shape — set of integers reachable by bitwise OR over a finite literal set.
3. **`Constant<Range>#to_a` / `#first` / `#last` / `#min` / `#max` precision.** `to_a` is catalog-classified `:leaf` but its Array result fails `foldable_constant_value?`; `first`/`last`/`min`/`max` are `:block_dependent` because of optional-block forms. Slice with a Range-specific no-arg allow list and an Array-result lift to `Tuple[…]` for `to_a`.
4. **`rigor:v1:conforms-to` directive.** Spec-defined in [`rbs-extended.md`](type-specification/rbs-extended.md) but the parser-and-checker has not landed. Add the parser entry plus a CheckRules rule that reports unsatisfied structural-interface conformance.
5. **`Constant<Rational>` / `Constant<Complex>` literal lift.** `Prism::ImaginaryNode` (`1i`) typing and `Rational(...)` / `Complex(...)` Kernel-call folding for the unary forms. The catalogs already exist; the typer side is unwired.
6. **Refinement-form `~T` negation in `assert` / `predicate-if-*`.** A narrow attempt at the difference-against-refinement algebra (Refined-only base; declines outside that envelope). Marked deferred in the v1 RBS::Extended spec, but the narrow case is achievable.

Deferred from v0.0.7 (carried forward) — see [`docs/CURRENT_WORK.md`](CURRENT_WORK.md) for rationale on each:

- `literal-string` / `non-empty-literal-string` (needs flow tracking).
- Predicate-complement narrowing for `Refined[base, predicate]` (needs mixed-case carriers or paired-complement registry).
- C-body classifier wider transitive mutator scan.
- `Data.define` override-aware initializer dispatch.
- ObjectSpace / URI catalog imports — thin or pure-Ruby; outside the standard import skill's premise.
- Pathname / URI delegation rules.
- `String#%` format-string parsing.
- `numeric-string` regex-pattern recogniser.
- `self`-narrowing in `predicate-if-*` (no `self`-narrowing surface in the engine yet).
- Caches, plugin API — reserved for v0.1.0.

## v0.1.0 — Long Horizon (architecture commitments deferred)

Theme: **infrastructure**. v0.1.0 reserves two cross-cutting machinery surfaces that should not be retro-fitted later:

- **Caches.** A persistent on-disk cache for parsed RBS environments, scope indexes, and catalog data so warm runs are fast.
- **Plugin API (ADR-2).** The capability-role / fact-contribution / mutation-summary surface plugin authors will attach to.

These are explicitly out of scope for v0.0.x. The pre-v0.1.0 work is the type-language and inference-engine surface that the plugin API has to be designed against; v0.0.3 → v0.0.7 closed the substrate gaps that ADR-2 would otherwise stumble on.

Pre-v0.1.0 surfaces that can land independently as v0.0.x dot releases (see [`docs/design/20260505-v0.1.0-readiness.md`](design/20260505-v0.1.0-readiness.md) for the full breakdown):

- **Public-API declaration of `Rigor::Scope`, `Rigor::Type`, `Rigor::Environment`** — namespace policy + drift tests. No new code, just contract declaration.
- **Reflection facade** — a unified `Rigor::Reflection` read-side over `ClassRegistry` + `RbsLoader` + `Builtins::*_CATALOG`. Highest-leverage pre-v0.1.0 slice; every plugin protocol that asks "what does class X look like?" needs this.
- **Cache slice taxonomy** — design doc fixing the `files` / `gems` / `plugins` / `configs` slot shapes, comparator semantics, and per-slice cache-key derivation. Prerequisite for the persistence layer.
- **Flow-contribution bundle struct** — a `Rigor::FlowContribution` with the eight ADR-2 slots (`return_type`, `truthy_facts`, `falsey_facts`, `post_return_facts`, `mutations`, `invalidations`, `exceptional`, `role_conformance`). Internal effect structs convert into bundles at the boundary.
- **Diagnostic provenance prefix** — `Diagnostic` gains a `source_family` field; formatter publishes `plugin.<id>.<rule>` style identifiers.

These do not block v0.0.x release cadence; they are the operational milestones that make v0.1.0 a finite assembly job rather than an open architectural exercise.
