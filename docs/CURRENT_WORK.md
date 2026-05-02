# Current Work — Inference Engine Checkpoint

This is a transient bookmark used to break a long implementation thread into reviewable chunks. The **normative** contracts and slice roadmap remain in [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md) and [`docs/adr/4-type-inference-engine.md`](adr/4-type-inference-engine.md). The release-by-release commitment envelope lives in [`docs/MILESTONES.md`](MILESTONES.md). If this file disagrees with any of those, the spec / ADR / milestone binds and this file is out of date.

## Status

**v0.0.3 released 2026-05-02.** The branch is at a clean shipping state: 1148 RSpec examples / 0 failures, RuboCop clean, `bundle exec exe/rigor check lib exe bin` reports 0 diagnostics, `gem build rigortype.gemspec` produces `rigortype-0.0.3.gem` cleanly. `lib/rigor/version.rb`, `Gemfile.lock`, and `CHANGELOG.md`'s `[0.0.3]` heading agree on the release version.

The summary of what shipped in v0.0.3 is in `CHANGELOG.md`'s `[0.0.3] - 2026-05-02` section and the v0.0.3 row of [`docs/MILESTONES.md`](MILESTONES.md). Not duplicated here.

## Where the Work Resumes

The next preview is **v0.0.4**. The full planned surface is in [`docs/MILESTONES.md`](MILESTONES.md); the items below are the operational entry points for restarting work, not a re-statement of the milestone.

### Just-landed slices (v0.0.4 in-progress)

**1. `Type::Refined` carrier (OQ3 predicate-subset half) + six imported predicates.** The carrier is at [`lib/rigor/type/refined.rb`](../lib/rigor/type/refined.rb); per-name factories under `Type::Combinator` cover `lowercase_string`, `uppercase_string`, `numeric_string`, `decimal_int_string`, `octal_int_string`, `hex_int_string`, plus the raw `refined(base, predicate_id)`. `Builtins::ImportedRefinements` resolves all six kebab-case names from `RBS::Extended`'s `rigor:v1:return:` payload. Catalog-tier projections in [`lib/rigor/inference/method_dispatcher/shape_dispatch.rb`](../lib/rigor/inference/method_dispatcher/shape_dispatch.rb) handle the case-fold pair (idempotence for `:lowercase` / `:uppercase` / `:numeric` and the three base-N int-string predicates; the lift `lowercase ↔ uppercase` for the cross calls). `Inference::Acceptance.accepts_refined` is the conservative analogue of `accepts_difference`. Self-asserting fixture: [`spec/integration/fixtures/predicate_refinement/`](../spec/integration/fixtures/predicate_refinement/). The skill ([`.codex/skills/rigor-builtin-import/SKILL.md`](../.codex/skills/rigor-builtin-import/SKILL.md) "When to introduce a new refinement carrier") records the seven-step procedure for adding the next predicate.

**2. Hash / Range / Set / Time built-in catalog imports.** Four more core classes feed the constant-fold dispatcher: [`data/builtins/ruby_core/hash.yml`](../data/builtins/ruby_core/hash.yml) / [`range.yml`](../data/builtins/ruby_core/range.yml) / [`set.yml`](../data/builtins/ruby_core/set.yml) / [`time.yml`](../data/builtins/ruby_core/time.yml) are extracted from CRuby and consumed by `Builtins::HASH_CATALOG` / `RANGE_CATALOG` / `SET_CATALOG` / `TIME_CATALOG`. `MethodDispatcher::ConstantFolding#catalog_for` is now table-driven (`CATALOG_BY_CLASS`) so the dispatch surface scales sublinearly. The Range slice also taught `tool/extract_builtin_catalog.rb` to recognise `rb_struct_define_without_accessor`, unblocking future struct-defined topic imports. The Time slice consumes both `Init_Time` in `references/ruby/time.c` and the `references/ruby/timev.rb` prelude (the C side `#include`s `timev.rbinc`); the per-class blocklist catches `localtime` / `gmtime` / `utc` whose `time_modify` indirection mis-classifies them as `:leaf`. Self-asserting fixtures: `spec/integration/fixtures/hash_catalog.rb`, `range_catalog.rb`, `set_catalog.rb`, `time_catalog.rb`.

### Where the work resumes

The `A → G → C` thread from the working agreement is now fully landed:

- **A. Base-N int-string predicates** (`decimal-int-string` / `octal-int-string` / `hex-int-string`) → `Type::Refined::PREDICATES`, the `Combinator.<name>_string` factories, the registry, and the `predicate_refinement` integration fixture.
- **G. `type-of` CLI canonical-name display contract** → three regression specs in `spec/rigor/cli_spec.rb` confirming kebab-case display in both human-readable and `--format=json` output.
- **C. Parameterised refinement tokeniser** → `Builtins::ImportedRefinements::Parser` plus `parse(payload)`, wired through `RBS::Extended.parse_return_type_override`. Accepts `non-empty-array[Integer]`, `non-empty-hash[Symbol, Integer]`, `int<5, 10>`, and the recursive forms; fail-soft on every parse miss. End-to-end fixture: [`spec/integration/fixtures/parameterised_refinement/`](../spec/integration/fixtures/parameterised_refinement/).

### Just-landed: Type::Intersection (composed refinement names)

`Type::Intersection` is the OQ3 closing carrier — sibling of `Union` / `Difference` / `Refined`. Catalogued composites `non-empty-lowercase-string` and `non-empty-uppercase-string` resolve through the same `ImportedRefinements` registry the simpler shapes use; `accepts_intersection` is conjunctive on LHS, disjunctive on RHS, plus a top-level structural-equality short-circuit; `ShapeDispatch.dispatch_intersection` collects each member's projection and narrows IntegerRange results to the meet so size-tier projections preserve their tighter answer. End-to-end fixture: [`spec/integration/fixtures/intersection_refinement/`](../spec/integration/fixtures/intersection_refinement/).

### Just-landed: rigor:v1:assert: and predicate-if-* against refinement carriers

The `<target> is <RHS>` RHS now matches either a Capitalised class name (existing behaviour) or a kebab-case refinement payload via `Builtins::ImportedRefinements::Parser`. `AssertEffect` and `PredicateEffect` gain a `refinement_type` field; the narrowing tier substitutes the carrier when present. Refinement-form directives don't yet support `~T` negation (would need a difference-against-refinement algebra). Fixture: [`spec/integration/fixtures/assert_refinement/`](../spec/integration/fixtures/assert_refinement/).

### Just-landed: Enumerable-aware each_with_index block-parameter typing

`IteratorDispatch` generalises beyond Integer iteration: `#each_with_index` over Array/Set/Range/Tuple/HashShape/Hash/Constant<Range> receivers now yields `(element, non-negative-int)` instead of widening the index to plain `Integer`. Fixture: [`spec/integration/fixtures/each_with_index.rb`](../spec/integration/fixtures/each_with_index.rb).

### Just-landed: rigor:v1:param: directive (both halves)

Symmetric to the `rigor:v1:return:` route landed in v0.0.3 and now feature-complete on both sides of the method boundary:

- **Call-site half.** `OverloadSelector` and the `argument-type-mismatch` check rule consult `RbsExtended.param_type_override_map(method_def)` and prefer the override over the RBS-translated type when filtering candidates / emitting diagnostics.
- **Body-side half.** `MethodParameterBinder` reads the same override map and replaces the RBS-translated parameter binding with the refinement when one is present. Inside the body, projections through the carrier (e.g. `id.size` over a `non-empty-string` parameter resolving to `positive-int`) are observable during inference.

End-to-end fixture: [`spec/integration/fixtures/param_extended/`](../spec/integration/fixtures/param_extended/) — call-site `argument-type-mismatch` AND in-body `assert_type` checks both fire on a single `Normaliser#normalise(id)` definition.

### Other v0.0.4 entry points (parallel-safe)

- **More Enumerable methods.** `#each_with_index` lands above; `#each_with_object`, `#inject`/`#reduce` (memo-typed), and IO line iteration are the natural follow-ups when a concrete v0.0.x slice needs them.
- **Refinement negation in assert / predicate directives.** Refinement-form directives currently reject `~T` payloads. A future slice could land a difference-against-refinement algebra so `assert value is ~non-empty-string` means "value is `Constant[""]`".
- **Further built-in catalog imports** (Time / Date / DateTime / Comparable / Enumerable). Each follows the nine-stage flow in [`.codex/skills/rigor-builtin-import/SKILL.md`](../.codex/skills/rigor-builtin-import/SKILL.md). Comparable / Enumerable are modules and may need a different topic shape than the existing concrete-class imports.

### Out of v0.0.4 scope (intentional)

- Caches and the plugin API (ADR-2) are reserved for v0.1.0. See [`docs/MILESTONES.md`](MILESTONES.md).
- New CheckRules rule families beyond the v0.0.3 `always-raises` line. Type-incompatible writes, return-type mismatch, unreachable branches stay deferred until the inference surface they depend on is sturdy.

## Open Engineering Items

These are concrete items that have come up during v0.0.3 work and that the next implementer benefits from seeing without re-reading the full thread:

1. **`spec/rigor/source/node_locator_spec.rb:82`** — `String#index` returns `Integer | nil` followed by an unguarded `+ 1`. The `possible-nil-receiver` rule flags it correctly; the spec uses a load-bearing nil-or-throw idiom that is awkward to express. Either add a `# rigor:disable possible-nil-receiver` line or rewrite the spec to guard explicitly. Not a blocker — the analyzer is correct.

2. **C-body classifier indirect mutators.** The catalog extractor's regex does not follow `str_modifiable` / helper indirection; methods like `String#replace` land as `:leaf` even though they mutate. Per-class blocklists in `STRING_CATALOG` / `ARRAY_CATALOG` absorb the false positives. Long-term: the classifier should track the helpers transitively so blocklists shrink.

3. **`numeric.yml` `unknown` entries.** Two methods stay `unknown` after the v0.0.3 extraction:
   - `Numeric#clone` (cfunc `num_clone` aliases to `rb_immutable_obj_clone` in `object.c`, not in the indexed C files).
   - `Integer#ceildiv` (prelude body delegates to user-overridable `#div`, classified as `composed`).
   Adding `references/ruby/object.c` to the Numeric topic's `c_index_paths` resolves the first; the second is intrinsically `dispatch` once the prelude classifier learns to flag `composed` bodies that call user-overridable methods.

4. **Catalogue diff tooling.** Tracked in the `rigor-builtin-import` skill's "Future Optimisation Surface" section. A `make catalog-diff` between two extractor runs would catch CRuby submodule bumps shifting symbol names; today the only signal is per-method test breakage.

## Reading Order for a Returning Implementer

1. `git log --oneline master ^v0.0.2` — every v0.0.3 slice in commit order.
2. `CHANGELOG.md` `[0.0.3]` section — user-visible summary.
3. [`docs/MILESTONES.md`](MILESTONES.md) — what v0.0.4 commits to and what stays out.
4. [`docs/adr/3-type-representation.md`](adr/3-type-representation.md) Working Decisions — OQ1 / OQ2 / OQ3 outcomes.
5. [`docs/adr/5-robustness-principle.md`](adr/5-robustness-principle.md) — the asymmetric authorship rule that drives every catalog and refinement decision.
6. [`.codex/skills/rigor-builtin-import/SKILL.md`](../.codex/skills/rigor-builtin-import/SKILL.md) — the procedure for importing a new built-in class.

After those, the v0.0.3 implementation surface is locatable from grep over `lib/rigor/type/`, `lib/rigor/inference/`, `lib/rigor/inference/method_dispatcher/`, and `data/builtins/ruby_core/`.
