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

## v0.0.4 — Next Preview (planned)

Theme: **finish the refinement carrier system and broaden built-in coverage**. The OQ3 second-half slice plus the next wave of CRuby class imports.

Planned surfaces:

- **`Type::Refined` carrier (OQ3 predicate-subset half).** Predicate-defined refinements (`lowercase-string`, `uppercase-string`, `numeric-string`, `decimal-int-string`, `octal-int-string`, `hex-int-string`). Predicate registry, plugin extension surface (ADR-2), canonical-name registry entries, fold rules per predicate.
- **Parameterised refinement tokeniser.** Read `non-empty-array[Integer]`, `int<5, 10>`, `non-empty-hash[Symbol, Integer]` from `RBS::Extended` annotations.
- **`rigor:v1:param:` and `rigor:v1:assert:` directives.** The annotation parser already accepts the syntax surface; v0.0.4 adds the dispatcher tier wiring symmetric to the `return:` route landed in v0.0.3.
- **Built-in catalog imports for the next wave of core classes.** Hash, Range, Set, Enumerable, Comparable, Time, Date, DateTime. The procedure is recorded in [`.codex/skills/rigor-builtin-import/SKILL.md`](../.codex/skills/rigor-builtin-import/SKILL.md) — each new class follows the same nine-stage flow.
- **Enumerable-aware block-parameter typing.** A single tier that knows `each` / `map` / `select` / `reduce` / `each_with_index` etc. yield element types over Array / Hash / Range / Set / IO line iteration. Today's iterator dispatch is Integer-only and hardcoded; v0.0.4 generalises through the new mechanism.
- **`type-of` CLI canonical-name display.** Confirm `bundle exec exe/rigor type-of …` renders refinement-bearing types in their kebab-case spelling (`non-empty-string`, not `String - ""`).

Stretch surfaces (land if cheap, defer if expensive):

- Pathname / URI delegation rules so `Pathname#exist?` etc routes through `File.exist?` projections.
- `String#%` format-string parsing for catalog-aware fold over `Constant<String>` template + `Constant<…>` values.
- `numeric-string` recogniser that classifies `String#match?(/\A\d+\z/)` as a `Refined[String, :numeric]` narrowing.

## v0.1.0 — Long Horizon (architecture commitments deferred)

Theme: **infrastructure**. The earlier comment in this thread reserved v0.1.0 for the cross-cutting machinery that should not be retro-fitted later:

- **Caches.** A persistent on-disk cache for parsed RBS environments, scope indexes, and catalog data so warm runs are fast.
- **Plugin API (ADR-2).** The capability-role / fact-contribution / mutation-summary surface plugin authors will attach to.

These are explicitly out of scope for v0.0.x. The pre-v0.1.0 work is the type-language and inference-engine surface that the plugin API has to be designed against.
