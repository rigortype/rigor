# Current Work — Inference Engine Checkpoint

This is a transient bookmark used to break a long implementation thread into reviewable chunks. The **normative** contracts and slice roadmap remain in [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md) and [`docs/adr/4-type-inference-engine.md`](adr/4-type-inference-engine.md). The release-by-release commitment envelope lives in [`docs/MILESTONES.md`](MILESTONES.md). If this file disagrees with any of those, the spec / ADR / milestone binds and this file is out of date.

## Status

**v0.0.3 released 2026-05-02.** The branch is at a clean shipping state: 1148 RSpec examples / 0 failures, RuboCop clean, `bundle exec exe/rigor check lib exe bin` reports 0 diagnostics, `gem build rigortype.gemspec` produces `rigortype-0.0.3.gem` cleanly. `lib/rigor/version.rb`, `Gemfile.lock`, and `CHANGELOG.md`'s `[0.0.3]` heading agree on the release version.

The summary of what shipped in v0.0.3 is in `CHANGELOG.md`'s `[0.0.3] - 2026-05-02` section and the v0.0.3 row of [`docs/MILESTONES.md`](MILESTONES.md). Not duplicated here.

## Where the Work Resumes

The next preview is **v0.0.4**. The full planned surface is in [`docs/MILESTONES.md`](MILESTONES.md); the items below are the operational entry points for restarting work, not a re-statement of the milestone.

### Highest-leverage immediate slice

**`Type::Refined` carrier (OQ3 predicate-subset half).** The point-removal half (`Type::Difference`) shipped in v0.0.3; v0.0.4 needs the predicate-subset peer. The first refinement to land end-to-end is `lowercase-string` because:

- it stresses every part of the predicate-subset machinery (predicate registry, fold rules, canonical-name display) without needing a tokeniser for parameters,
- it has obvious projection rules (`String#downcase` over a `lowercase-string` receiver folds to `self`; `String#upcase` returns `uppercase-string`),
- the fixture (`spec/integration/fixtures/refinement_return_override/`) already demonstrates the `Difference` route end-to-end, so the new `Refined` route can mirror its structure.

ADR-3 OQ3 records the design; the implementation steps the slice should follow:

1. `lib/rigor/type/refined.rb` — sibling of `Difference`. Wraps `(base, predicate_id)` where `predicate_id` is a Symbol drawn from a registered predicate table. Erases to base.
2. `Builtins::ImportedRefinements` registry entries for `lowercase-string`, `uppercase-string`, `numeric-string`. The lookup returns `Refined[Nominal[String], :lowercase]` etc.
3. Catalog-tier projections in `MethodDispatcher::ShapeDispatch` (or a new `RefinedDispatch` module): `String#downcase` over `Refined[String, :lowercase]` → self; `String#upcase` over `Refined[String, :lowercase]` → `Refined[String, :uppercase]`.
4. `Acceptance.accepts_refined` — the conservative analogue of `accepts_difference`. Predicate-subset acceptance is hard in general; gradual mode should accept only `Refined` candidates with the same predicate, plus `Constant` candidates whose value satisfies the predicate at construction time (when the predicate has a runtime recogniser).
5. Self-asserting fixture under `spec/integration/fixtures/predicate_refinement/` paralleling `refinement_return_override/`.
6. Update [`.codex/skills/rigor-builtin-import/SKILL.md`](../.codex/skills/rigor-builtin-import/SKILL.md) section "When to introduce a new refinement carrier" with the now-decided predicate-subset case.

### Other v0.0.4 entry points (parallel-safe)

These are independent of the `Type::Refined` slice and can be picked up by a second contributor in parallel:

- **Hash / Range / Set catalog imports.** Each follows the nine-stage flow in [`.codex/skills/rigor-builtin-import/SKILL.md`](../.codex/skills/rigor-builtin-import/SKILL.md). `Init_Hash` is at `references/ruby/hash.c:7341`; `Init_Range` and `Init_Set` need to be located. Hash already has a generated YAML waiting for a runtime loader.
- **`rigor:v1:param:` / `rigor:v1:assert:` directive wiring.** The annotation grammar surface exists; the dispatcher tier needs the symmetric routes to the `return:` path landed in `lib/rigor/inference/method_dispatcher/rbs_dispatch.rb`.
- **Parameterised refinement tokeniser.** Read `non-empty-array[Integer]`, `int<5, 10>`, `non-empty-hash[Symbol, Integer]` from `RBS::Extended` annotations and resolve through `Builtins::ImportedRefinements` plus a small parser. Required before `:lowercase-string` opt-in is parameterised; not required for the `Type::Refined` carrier itself.
- **Enumerable-aware block-parameter typing.** Architecture sketch: a single dispatcher tier that knows `Enumerable` block-yield rules (Array/Hash/Range/Set/IO) and projects element types per receiver shape. Replaces the hardcoded Integer-only `IteratorDispatch` from v0.0.3.

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
