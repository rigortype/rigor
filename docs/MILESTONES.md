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

Stretch surfaces (carried forward unchanged):

- Pathname / URI delegation rules so `Pathname#exist?` etc routes through `File.exist?` projections.
- `String#%` format-string parsing for catalog-aware fold over `Constant<String>` template + `Constant<…>` values.
- `numeric-string` recogniser that classifies `String#match?(/\A\d+\z/)` as a `Refined[String, :numeric]` narrowing.

## v0.1.0 — Long Horizon (architecture commitments deferred)

Theme: **infrastructure**. The earlier comment in this thread reserved v0.1.0 for the cross-cutting machinery that should not be retro-fitted later:

- **Caches.** A persistent on-disk cache for parsed RBS environments, scope indexes, and catalog data so warm runs are fast.
- **Plugin API (ADR-2).** The capability-role / fact-contribution / mutation-summary surface plugin authors will attach to.

These are explicitly out of scope for v0.0.x. The pre-v0.1.0 work is the type-language and inference-engine surface that the plugin API has to be designed against.
