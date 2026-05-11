# Current Work — Inference Engine Checkpoint

This is a transient bookmark used to break a long implementation thread into reviewable chunks. The **normative** contracts and slice roadmap remain in [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md) and [`docs/adr/4-type-inference-engine.md`](adr/4-type-inference-engine.md). The release-by-release commitment envelope lives in [`docs/MILESTONES.md`](MILESTONES.md). If this file disagrees with any of those, the spec / ADR / milestone binds and this file is out of date.

## Status

**v0.1.2 released.** All v0.1.2 tracks landed and the version cut. Slice-by-slice recap in `CHANGELOG.md` § `[0.1.2]` and `docs/MILESTONES.md` § "v0.1.2 — Planned".

**v0.1.3 in progress, release pending.** Theme: **deliver [ADR-10](adr/10-dependency-source-inference.md) end-to-end, absorb ADR-11 / Rails plugin Phase work, and land ADR-13.** Five tracks closed; ADR-13 slice 3b landed on `master`. Only slice 7 (handbook TypeScript appendix update) is still deferred to v0.1.4:

- **ADR-10 fully implemented.** Five-slice envelope (config plumbing → walker + dispatcher tier → cache descriptor → per-gem budget → docs) plus four "Open questions" follow-ups (5a per-receiver plugin veto / 5b β budget semantics / 5d config-conflict diagnostic; 5c boundary-cross deferred behind `mode: full` distinct dispatch).
- **ADR-11 (rigor-sorbet) primary surface complete.** Slices 1–6 + 8 plus light follow-ups (`T.must_because`, `T.reveal_type`, `T.assert_type!`, `T.bind`, `enforce_sigil` per-file gating). Only per-call-site assertion gating remains.
- **PHPStan-style Type-Specifying Extensions substrate landed.** `Inference::StatementEvaluator#apply_plugin_assertions` wires plugin-side `truthy_facts` / `falsey_facts` / `post_return_facts` through the narrowing engine; closes ADR-7 § "Slice 4-A"'s plugin half.
- **Rails Tier 2 ecosystem complete.** `rigor-actionpack` (4 phases), `rigor-factorybot` (Phase 1 (a)+(c)), `rigor-activerecord` (publishes `:model_index` via ADR-9). First "publish-and-consume" cycle exercising ADR-9 end-to-end.
- **[ADR-13](adr/13-typenode-resolver-plugin.md) (plugin TypeNode resolver + TS-utility-type adapter) — slices 1–6 + 3b landed.** New `Rigor::Plugin::TypeNodeResolver` extension point with manifest hook + registry aggregation. Parser refactored from inline scan+resolve into "scan to AST" + sibling `Resolver` pass. Five Rigor-canonical shape-projection type functions on `Type::Combinator` (`pick_of` / `omit_of` / `partial_of` / `required_of` / `readonly_of`) — phase A on HashShape, phase B on Tuple, predicate `shape_projection_lossy?` consumed by slice 3b at projection-authoring sites. New opt-in `rigor-typescript-utility-types` plugin under `examples/` maps the TS spellings (`Pick`, `Omit`, `Partial`, `Required`, `Readonly`) onto the core functions. **Slice 3b** threads `name_scope:` / reporter through every analyzer-side `RbsExtended.read_*` call site (`Analysis::CheckRules`, `Inference::StatementEvaluator` / `Narrowing` / `MethodParameterBinder` / `MethodDispatcher::OverloadSelector` / `MethodDispatcher::RbsDispatch`), and wires two new `:info` diagnostic families: `dynamic.rbs-extended.unresolved` (whole-payload resolution failure) and `dynamic.shape.lossy-projection` (projection applied to a non-shape carrier).
- **handbook expansion.** Chapter 7 gains a `@phpstan-assert` correspondence table; chapter 10 (rigor-sorbet) covers all the new sorbet recognisers. TypeScript appendix update (slice 7 of ADR-13) remains the only deferred v0.1.4 item.

**Nineteen worked example plugins now land under `examples/`** (the eighteen pre-ADR-13 examples plus `rigor-typescript-utility-types`). See [`examples/README.md`](../examples/README.md) for the comparison table.

### ADR-13 slice-by-slice recap

1. ✅ **Slice 1** (`0c21632`) — `Rigor::TypeNode::Identifier` / `Generic` value objects. Drift snapshots pinned.
2. ✅ **Slice 2** (`5c1e94b`) — `Plugin::TypeNodeResolver` base class, `Plugin::Manifest#type_node_resolvers`, `Plugin::Registry#type_node_resolvers` aggregator.
3. ✅ **Slice 3** (`ec45a10`) — Parser refactor (AST + Resolver pass), `TypeNode::IntegerLiteral` / `IndexedAccess` / `NameScope` / `ResolverChain`. `ImportedRefinements.parse(payload, name_scope: nil)` with `nil` default preserving slice-2 behaviour.
4. ✅ **Slice 4** (`6ce544c`) — phase A: `Type::Combinator.pick_of` / `omit_of` / `partial_of` / `required_of` / `readonly_of` on HashShape. `PARAMETERISED_TYPE_BUILDERS` grows five rows.
5. ✅ **Slice 5** (`9249c67`) — phase B (Tuple); `shape_projection_lossy?(type)` predicate.
6. ✅ **Slice 6** (`4f00db6`) — `rigor-typescript-utility-types` plugin + Resolver scope-handle fix (`NameScope#resolver` now points at the full Resolver so plugin authors recursively resolve sub-args through built-ins + chain + RBS fallback).
7. ✅ **Slice 3b** — Caller-side threading from `RbsExtended` + reporter accumulator + two new `dynamic.*` diagnostics. `Rigor::RbsExtended::Reporter` is the per-run accumulator (`unresolved_payloads` / `lossy_projections`); `Environment` exposes `name_scope` (built from `plugin_registry.type_node_resolvers`) and `rbs_extended_reporter` for the threading. Every analyzer-surface `RbsExtended.read_*` call site passes `environment:`. Runner drains the reporter at end-of-run into `dynamic.rbs-extended.unresolved` and `dynamic.shape.lossy-projection` `:info` diagnostics.
8. ⏭ **Slice 7** (deferred) — handbook TypeScript appendix update.

**v0.1.0 → v0.1.2 released.** Slice-by-slice recaps in `CHANGELOG.md` (§ `[0.1.0]`, `[0.1.1]`, `[0.1.2]`) and `docs/MILESTONES.md`. The `target_ruby` phantom-setting fix and the runtime audit-guard spec block under [`spec/rigor/analysis/runner_spec.rb`](../spec/rigor/analysis/runner_spec.rb) "configuration wiring at runtime (audit guard)" landed during the v0.1.1 batch and remain in force.

## Where the Work Resumes

### v0.1.3 entry path

v0.1.3's four primary tracks are closed; ADR-13 slice 3b just landed on `master`. Only slice 7 is deferred to v0.1.4:

- **ADR-10**: Five-slice envelope + 5a / 5b / 5d open-question follow-ups all landed; 5c boundary-cross is deferred behind a `mode: full` distinct-dispatch prerequisite.
- **ADR-11 (rigor-sorbet)**: Slices 1–6 + 8 + light follow-ups all landed. Only per-call-site assertion gating remains.
- **Rails ecosystem (Tier 2)**: rigor-actionpack 4 phases + rigor-factorybot Phase 1 (a)+(c) all landed. ADR-9 cross-plugin chain proven end-to-end with `:helper_table` (rails-routes → actionpack) and `:model_index` (activerecord → actionpack + factorybot).
- **ADR-13**: Slices 1–6 + 3b landed (core machinery + opt-in plugin + caller-side diagnostic threading). Slice 7 (handbook TypeScript appendix update) is the only ADR-13 polish item deferred to v0.1.4.

The next session can:
1. **Cut a release** (`bundle exec rake release` per [`.codex/skills/rigor-release-prep/SKILL.md`](../.codex/skills/rigor-release-prep/SKILL.md), awaiting explicit user authorisation). v0.1.3 has accumulated substantial work and is shippable.
2. **Close the last ADR-13 polish item:**
   - **Slice 7 — handbook TypeScript appendix update.** [`docs/handbook/appendix-typescript.md`](handbook/appendix-typescript.md) lines 54-56 + 163 currently say "no Rigor analogue" for `Readonly` / `Partial` / `Required` / `Pick` / `Omit`. Update those rows to point at the opt-in `rigor-typescript-utility-types` plugin. Small commit; ~30 LoC.
3. **Continue with deferred queue items**:
   - `mode: full` distinct dispatch (unblocks ADR-10 5c boundary-cross).
   - Per-call-site assertion gating in rigor-sorbet.
   - Tier 3 ecosystem plugins still pending: `rigor-graphql`, `rigor-activestorage`.
   - rigor-activerecord extensions: associations, enums, scopes, validations, callbacks.
4. **New ecosystem work**: ADR-12 candidate plugins (dry-rb adapters per [`docs/design/20260509-dry-plugins-roadmap.md`](design/20260509-dry-plugins-roadmap.md)).

### Rails ecosystem plugins (parallel running track)

The Rails plugin family continues in parallel with v0.1.x core work. The full plan is in [`docs/design/20260508-rails-plugins-roadmap.md`](design/20260508-rails-plugins-roadmap.md). Authoring proceeds **one plugin per session**, staged in `examples/rigor-<id>/` and extracted via `git subtree split` once the contract is stable.

Already landed under `examples/` (unreleased on `master`):
- **Tier 1**: `rigor-rails-routes`, `rigor-rails-i18n`, `rigor-actionmailer`, `rigor-activejob`.
- **Tier 2**: `rigor-actionpack` (4 phases — route helpers, filter chains, render targets, strong parameters → AR column validation); `rigor-factorybot` (Phase 1 (a) self-contained validation + Phase 1 (c) AR column cross-check); `rigor-activerecord` (with `manifest(produces: [:model_index])` ADR-9 publication for downstream consumers).
- **Tier 3**: `rigor-pundit`, `rigor-sidekiq`, `rigor-rspec`, `rigor-actioncable`.

Pending Tier 3: `rigor-graphql`, `rigor-activestorage`. The `rigor-sorbet` plugin (ADR-11; slices 1–6 + 8 + light follow-ups landed) sits parallel to the Rails track. The `rigor-typescript-utility-types` plugin (ADR-13 slice 6) sits orthogonal to the Rails track — it extends the type-language vocabulary surface, not framework-specific call patterns. `rigor-activerecord` extensions (associations, enums, scopes, validations, callbacks) ship as 0.2.0+ minor bumps.

## Open Engineering Items

Persistent items that have come up across v0.0.x slices and that the next implementer benefits from seeing without re-reading the full thread. Items already absorbed into v0.1.1 are referenced through MILESTONES rather than restated here.

1. ~~**C-body classifier indirect mutators.**~~ Closed in v0.1.2 — the extractor's seed now also matches `_modify` / `_modifiable`-named helpers whose body issues a frozen-check (`str_modifiable`, `rb_struct_modify`, `range_modify`, `rb_class_modify_check`, …). Catalog regen flips `String#replace` / `String#initialize_copy` / several String bang methods / `Range#initialize` / `Range#initialize_copy` to `mutates_self`. A transitive-closure-on-first-arg-formal-param approach was explored and reverted — over-classification on functions where the first arg is a formal yet the helper doesn't actually mutate it. Per-class blocklists still absorb the remaining cases (Time / Set helpers).
2. **RBS::Extended grammar lacks Symbol / String literal tokens.** ADR-13 slice 6's integration spec works around this by invoking the plugin's resolvers directly with synthetic AST when it wants `Pick<HashShape, :a | :b>` semantics — the parser currently can't tokenize `:name` / `"name"` inside a type-arg position. End-to-end parsing of TypeScript-style key unions through `ImportedRefinements.parse` will work once the parser grows the corresponding tokens. Not blocking — `pick_of` / `omit_of` still produce useful results via plugin chains with non-literal `K` (they degrade to the source HashShape).

## Reading Order for a Returning Implementer

The default goal for the next session is "cut the v0.1.3 release" (substantial work accumulated, all ADR-13 implementation slices closed). If continuing implementation instead, the natural entry slice is ADR-13 slice 7 (handbook TypeScript appendix update) — pure docs, no code surface. Read in this order:

1. `CHANGELOG.md` `[Unreleased]` section — accumulates v0.1.3 work as it lands.
2. [`docs/MILESTONES.md`](MILESTONES.md) — release-by-release commitment envelope; v0.1.2 is the latest released milestone, v0.1.3 carries ADR-10 / ADR-11 / Rails Tier 2 / ADR-13.
3. [`docs/adr/13-typenode-resolver-plugin.md`](adr/13-typenode-resolver-plugin.md) — design rationale for the latest landed ADR; the seven-slice implementation plan and the open-questions section are the source of truth for slice 3b / 7.
4. [`docs/adr/10-dependency-source-inference.md`](adr/10-dependency-source-inference.md) + [`docs/internal-spec/dependency-source-inference.md`](internal-spec/dependency-source-inference.md) — design rationale and analyzer contract for v0.1.3's first track.
5. [`docs/adr/9-cross-plugin-api.md`](adr/9-cross-plugin-api.md) and [`docs/adr/11-sorbet-input-adapter.md`](adr/11-sorbet-input-adapter.md) — sibling ADRs landed in v0.1.x core.
6. [`docs/design/20260508-rails-plugins-roadmap.md`](design/20260508-rails-plugins-roadmap.md) — Rails plugin family ordering, dependency graph, subtree-split readiness checklist.
7. [`.codex/skills/rigor-plugin-author/SKILL.md`](../.codex/skills/rigor-plugin-author/SKILL.md) — agent-facing playbook for authoring a new plugin.
8. [`docs/internal-spec/public-api.md`](internal-spec/public-api.md) — public-vs-internal stability boundary. Cross-reference `spec/rigor/public_api_drift_spec.rb` before extending any pinned namespace.
9. [`examples/README.md`](../examples/README.md) — comparison table over the nineteen worked plugin examples; recommended reading order for new authors.
10. [`docs/adr/2-extension-api.md`](adr/2-extension-api.md) and [`docs/adr/7-v0.1.0-slice-decisions.md`](adr/7-v0.1.0-slice-decisions.md) — the binding design and per-slice working decisions for the v0.1.0 plugin contract that v0.1.x extends.
11. [`docs/adr/3-type-representation.md`](adr/3-type-representation.md) Working Decisions — OQ1 / OQ2 / OQ3 outcomes still bind the type-object public surface plugins consume.

After those, the implementation surface for slice 7 is locatable from grep over:
- `docs/handbook/appendix-typescript.md` for slice 7's prose update.

The slice-3b surface (`lib/rigor/rbs_extended.rb`, `lib/rigor/rbs_extended/reporter.rb`, `lib/rigor/builtins/imported_refinements.rb`, `lib/rigor/environment.rb`, `lib/rigor/analysis/runner.rb`) is now wired end-to-end — consult those when authoring follow-ups that need the reporter or the per-run `name_scope`.
