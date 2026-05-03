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

## v0.0.5 — Next Preview (planned)

Theme: **continue catalog coverage and broaden the Enumerable-aware projections**. None of the items below are commitments yet; this is the active candidate pool for the next slice.

- More Enumerable methods. `#each_with_object`, `#inject` / `#reduce` (memo-typed), `#group_by` / `#partition` (returning shaped containers), IO line iteration.
- Refinement negation in `assert:` / `predicate-if-*:` directives. Refinement-form directives currently reject `~T` payloads; landing them needs a difference-against-refinement algebra.
- Date / DateTime catalog imports (stdlib gems under `references/ruby/ext/date/`).
- Comparable / Enumerable module imports — `tool/scaffold_builtin_catalog.rb` may grow a `--module` mode for these.
- C-body classifier upgrades — track indirect mutator helpers transitively so per-class blocklists shrink.
- `make catalog-diff` between two extractor runs.

Stretch surfaces (land if cheap, defer if expensive):

- Pathname / URI delegation rules so `Pathname#exist?` etc routes through `File.exist?` projections.
- `String#%` format-string parsing for catalog-aware fold over `Constant<String>` template + `Constant<…>` values.
- `numeric-string` recogniser that classifies `String#match?(/\A\d+\z/)` as a `Refined[String, :numeric]` narrowing.

### v0.0.5 progress checkpoint (work-in-progress, not yet released)

Snapshot of `[Unreleased]` accumulation as of the last checkpoint. The branch is 14 commits ahead of `origin/master`; `[0.0.5]` will only freeze when the version bump commit lands. The release-row of this table will be filled in at that point; until then, items below are landed-but-still-mutable surfaces:

- Comparable / Enumerable module catalog imports + the matching `tool/scaffold_builtin_catalog.rb --module` mode.
- C-body classifier — pure `rb_check_frozen` wrapper detection (Time#gmtime / Time#utc reclassified `:mutates_self`; every other catalog byte-identical).
- `tool/catalog_diff.rb` + `make catalog-diff` target.
- Date / DateTime catalog imports (separate slice, landed earlier in the v0.0.5 thread).
- `narrow_not_refinement` extended to IntegerRange + Intersection (De Morgan).
- Refinement negation in `assert` / `predicate-if-*` directives (refinement payloads now accept `~T` forms).
- Include-aware module-catalog fallthrough in `MethodDispatcher::ConstantFolding#catalog_allows?` — activates the Comparable / Enumerable imports.
- 2-argument fold dispatch (`try_fold_ternary`) — `Comparable#between?(min, max)`, `Comparable#clamp(min, max)`, `Integer#pow(exp, mod)` now fold through the catalog tier.

Open candidates remaining in the v0.0.5 pool (see [`docs/CURRENT_WORK.md`](CURRENT_WORK.md) for entry points):

- Predicate-complement narrowing for `Refined[base, predicate]` — the only branch of `narrow_not_refinement` still bailing.
- Block-shaped fold dispatch — block-parameter *typing* already works via `IteratorDispatch`; the open work is folding the block's *return* into a precise carrier (and IntegerRange operands on the now-landed 2-arg path).
- Further catalog imports — Rational, Complex, URI, Pathname (already partial), Kernel (rb_mKernel), ObjectSpace.
- C-body classifier — wider transitive mutator scan that does not over-flag legitimate non-mutators (the `Array#to_a` regression that gated the conservative v0.0.5 fix).

#### Cross-checker triage follow-ups (Steep 2.0 cross-check)

Identified by running Steep 2.0 (installed under `tool/steep/` as a separate Bundler — see [`docs/notes/20260503-steep-cross-check-triage.md`](notes/20260503-steep-cross-check-triage.md) for the full report). The mechanical sig / impl drift fixes have already landed (A-1 through A-5 in the triage); the items below are the **Rigor-detection-side** follow-ups, i.e. capabilities Rigor's analyzer should grow so that the same class of warning is caught natively without needing the Steep cross-check.

- **`Trinary` return-type contract on type-carrier predicate methods.** **Deferred — out of v0.0.x scope.** Every `Type::*` carrier exposes `top` / `bot` / `dynamic` returning `Trinary`. The 39-warning batch from the Steep cross-check landed because `sig/rigor/type.rbs` had drifted to declare those as returning the queried type itself. Rigor's own check did not flag this because the analyzer does not yet enforce explicit return-type signatures against method bodies. Closing the gap requires a new CheckRules rule family (`return-type-mismatch`), which [`docs/CURRENT_WORK.md`](CURRENT_WORK.md)'s "Out of v0.0.5 / v0.0.x scope" note explicitly defers until "the inference surface they depend on is sturdy" — same bucket as type-incompatible writes and unreachable branches. Tracked here so the design context is preserved; revisit alongside the broader CheckRules-rule-family work.
- ~~**`untyped?` truthy-narrowing.**~~ **Landed**. The original diagnosis ("`narrow_truthy` does not strip nil out of `untyped?`") was wrong — `Inference::Narrowing.narrow_truthy` already collapses `Union[Dynamic, Constant[nil]]` to `Dynamic` correctly. The actual gap was in `Inference::ScopeIndexer.propagate`: when an `IfNode` / `UnlessNode` sat in expression position (as a call argument or the RHS of an `[]=`), the indexer never ran `eval_if`'s narrowing path, so the truthy / falsey scopes never reached the inner subtree. Fixed by branch-aware propagation in `propagate` itself, which routes each branch through `Narrowing.predicate_scopes`. The `RbsLoader` instance/singleton-definition sigs are now declared as `untyped?` again.
- ~~**`Kernel#Array` union-distributing return shape.**~~ **Landed**. `MethodDispatcher::KernelDispatch` now folds `Array(arg)` into a precise `Array[E]` based on the argument's value-lattice shape (Nominal / Constant[nil] / Tuple / Union with element-wise distribution). The previously-flagged `lib/rigor/analysis/fact_store.rb#fact_targets` site over `Target | Array[Target]` now resolves to `Array[Target]` instead of the RBS envelope `Array[Dynamic[top]]`. Steep's own warning at the same site persists because Steep does not distribute Array() over unions; that is a Steep-side limitation Rigor's analyzer now closes natively.
- ~~**`Data.define` override-aware initializer dispatch.**~~ **Partially landed**. `Inference::ScopeIndexer.record_declarations` now recognises `Const = Data.define(*Symbol) [do ... end]` and registers `Const` (qualified by the surrounding path) as a discovered class. `Const.new(...)` resolves to `Nominal[<qualified>]` via `meta_new`, replacing the previous `Dynamic[top]` envelope. Member accessors fall through to the user-class fallback without false-positives. The override-aware initializer-signature path — using the block's `def initialize(...)` parameter list as the canonical sig for `Const.new` — is still open; today the auto-generated kw shape (members as required keywords) is what callers see through dispatch. Steep's own warnings on `lib/rigor/analysis/fact_store.rb` (Target / Fact) persist because Steep conflates the Data.define block scope with the outer FactStore scope; that gap is upstream.
- **Cross-checker runner integration.** Keep `make steep-check` as an out-of-band sibling check for now (not chained into `make verify`). Three of the four detection items above have landed; the remaining `return-type-mismatch` rule is deferred per CURRENT_WORK, so the Steep residual (today: 6 warnings, all in `fact_store.rb` and rooted in Steep-side limitations Rigor now closes natively) stays the steady-state floor for the cross-check.

## v0.1.0 — Long Horizon (architecture commitments deferred)

Theme: **infrastructure**. The earlier comment in this thread reserved v0.1.0 for the cross-cutting machinery that should not be retro-fitted later:

- **Caches.** A persistent on-disk cache for parsed RBS environments, scope indexes, and catalog data so warm runs are fast.
- **Plugin API (ADR-2).** The capability-role / fact-contribution / mutation-summary surface plugin authors will attach to.

These are explicitly out of scope for v0.0.x. The pre-v0.1.0 work is the type-language and inference-engine surface that the plugin API has to be designed against.
