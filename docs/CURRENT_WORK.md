# Current Work — Inference Engine Checkpoint

This is a transient bookmark used to break a long implementation thread into reviewable chunks. The **normative** contracts and slice roadmap remain in [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md) and [`docs/adr/4-type-inference-engine.md`](adr/4-type-inference-engine.md). The release-by-release commitment envelope lives in [`docs/MILESTONES.md`](MILESTONES.md). If this file disagrees with any of those, the spec / ADR / milestone binds and this file is out of date.

## Status

**v0.1.2 released.** All v0.1.2 tracks landed and the version cut. Slice-by-slice recap in `CHANGELOG.md` § `[0.1.2]` and `docs/MILESTONES.md` § "v0.1.2 — Planned".

**v0.1.3 in progress.** Theme: **deliver [ADR-10 — Opt-in dependency-source inference](adr/10-dependency-source-inference.md) end-to-end and absorb ADR-11 / Rails plugin Phase work.** What landed since v0.1.2 release:

- **ADR-10 fully implemented.** Five-slice envelope (config plumbing → walker + dispatcher tier → cache descriptor → per-gem budget → docs) plus four "Open questions" follow-ups (5a per-receiver plugin veto / 5b β budget semantics / 5d config-conflict diagnostic; 5c boundary-cross documented as deferred behind `mode: full` distinct dispatch).
- **ADR-11 (rigor-sorbet) primary surface complete.** Slices 1–6 + 8 of the original plan, plus light follow-ups for `T.must_because`, `T.reveal_type`, `T.assert_type!`, `T.bind`, and `enforce_sigil` per-file gating. Only per-call-site assertion gating remains.
- **PHPStan-style Type-Specifying Extensions substrate landed.** `Inference::StatementEvaluator#apply_plugin_assertions` wires plugin-side `truthy_facts` / `falsey_facts` / `post_return_facts` through the narrowing engine; closes ADR-7 § "Slice 4-A"'s plugin half. Same substrate T.bind uses; PHPStan-style call-shape assertions are now authorable from a Rigor plugin without engine changes.
- **rigor-actionpack 4 phases complete.** Phase 4 (route helpers) + Phase 2 (filter chains) + Phase 3 (render targets) + Phase 1 (strong parameters → AR column validation). First Tier 2 plugin to ship the full Action Pack surface.
- **rigor-factorybot Tier 2 plugin** — Phase 1 (a) self-contained validation + Phase 1 (c) AR column cross-check via the `:model_index` ADR-9 fact.
- **rigor-activerecord ADR-9 publication.** New `manifest(produces: [:model_index])` + `prepare(services)` hook publishes the model index to the cross-plugin fact store. First "publish-and-consume" cycle exercising ADR-9 end-to-end with two consumers (rigor-actionpack Phase 1 + rigor-factorybot Phase 1 (c)).
- **handbook expansion.** Chapter 7 gains a `@phpstan-assert` correspondence table; chapter 10 (rigor-sorbet) covers all the new sorbet recognisers.

Eighteen worked example plugins now land under `examples/`. ADR-10's "Open questions" track is closed except for `mode: full` distinct dispatch (a prerequisite for the boundary-cross diagnostic). ADR-11's deferred items are limited to per-call-site assertion gating.

ADR-10 was authored alongside v0.1.2 and queued for v0.1.3+; v0.1.3 starts implementing it. Five slices (config plumbing → walker + dispatcher tier → cache descriptor → per-gem budget → docs) per the ADR's "Implementation slicing" section.

- **Slice 1 (Configuration plumbing)** — landed unreleased. New `Configuration::Dependencies` value object + `Entry(gem:, mode:, roots:)` frozen Data. `.rigor.yml` gains a `dependencies.source_inference[]` section. JSON schema + parser tests + integration tests through `Configuration.load`. CHANGELOG entry under `[Unreleased]`.
- **Slice 2a (Gem resolver + Runner wiring)** — landed unreleased. `Analysis::DependencySourceInference::GemResolver.resolve` maps an entry to `Resolved` / `Unresolvable`; `Builder.build` partitions, returning a frozen `Index`. `Analysis::Runner` builds the index once per run (closing the slice-1 phantom-setting gap) and surfaces unresolvable gems as `dynamic.dependency-source.gem-not-found` `:warning` diagnostics. The walker-and-dispatcher work was internally split off as **slice 2b** so this commit stays reviewable.
- **Slice 2b-i (Walker + Index method catalog)** — landed unreleased. `Walker.walk(gem_dir:, roots:)` parses each opt-in gem's `*.rb` files and returns a flat `Hash{[class_name, method_name] => :instance | :singleton}` catalog. ADR-10 § "Hard exclusions" enforced at root granularity: `spec/` / `test/` / `bin/` are filtered before any filesystem walk and cannot be overridden by the user. `Builder.build` aggregates per-gem catalogs into `Index#method_catalog`; `Index#contribution_for(class_name:, method_name:)` answers from the table.
- **Slice 2b-ii (dispatcher tier)** — landed unreleased. New tier in `Inference::MethodDispatcher.dispatch` between `RbsDispatch.try_dispatch` and `try_user_class_fallback`: returns `Type::Combinator.untyped` (Dynamic[top]) when the receiver's class + method name match an `Index` entry. `Environment.for_project` / `Environment.new` accept `dependency_source_index:`; `Environment#dependency_source_index` accessor pinned via drift snapshot + `sig/rigor/environment.rbs`. **Slice 2 envelope done**.
- **Slice 3 (Cache descriptor + per-gem-version invalidation)** — landed unreleased. `Cache::Descriptor::DependencyEntry(gem_name:, gem_version:, mode:)` value object + new `dependencies:` slot on `Cache::Descriptor`; `compose_by_key` over `gem_name` raises `Conflict` on disagreeing version / mode; canonical-hash slot order is `configs / dependencies / files / gems / plugins`; `SCHEMA_VERSION` bumped to 2 so stale-shape entries get wiped at first run. New `DependencySourceInference::Index#cache_descriptor` lifts every `Resolved` row into a `DependencyEntry` and returns a frozen descriptor populated with the `dependencies:` slot — the primitive future cache producers compose with their own descriptors so a `bundle update` on a listed gem invalidates exactly that gem's slice. Unresolvable entries contribute nothing (no version to key on); resolved-but-disabled entries are filtered upstream by `Builder`.
- **Slice 4 (per-gem budget pool)** — landed unreleased. New `dependencies.budget_per_gem` config entry (default `5000`, range `1250 .. 20000` per ADR-10 § "Budget interaction"). `Walker.walk` accepts a `budget:` keyword and returns `Walker::Outcome(catalog:, truncated:)`; harvesting stops at the cap and `truncated?` propagates to `Index#budget_exceeded`. `Analysis::Runner` emits one `dynamic.dependency-source.budget-exceeded` `:warning` per listed gem (per-gem dedupe, not per-call-site). Implements the (α) Walker-side cap from ADR-10 WD4; the richer (β) class-to-gem reverse index stays queued behind a concrete user need.
- **Slice 5 (documentation)** — landed unreleased. New normative spec at [`docs/internal-spec/dependency-source-inference.md`](internal-spec/dependency-source-inference.md) covering all five landed slices end-to-end (configuration, resolver + index, walker, dispatcher tier, cache slice, budget enforcement) plus the live + pending diagnostic family and the boundary contracts with ADR-2 / ADR-5 / ADR-9. `docs/internal-spec/README.md` reading-order table updated; cross-links in `special-types.md` / `inference-budgets.md` / `diagnostic-policy.md` upgraded from "ADR-10 only" to "ADR-10 (analyzer contract: dependency-source-inference.md)" so readers find the implementation contract one click away.
- **ADR-10 envelope complete + open-questions sweep.** The five implementation slices plus 5a (per-receiver plugin veto via `manifest(owns_receivers:)`), 5b (β budget semantics via `dependencies.budget_overrun_strategy: dependency_silence`), and 5d (`dynamic.dependency-source.config-conflict` :warning on `includes:`-chain mode disagreements). 5c (boundary-cross diagnostic) is documented as deferred behind a `mode: full` distinct-dispatch prerequisite — landing the diagnostic without that prerequisite would ship a rule that can never fire.

**v0.1.0 → v0.1.2 released.** Slice-by-slice recaps in `CHANGELOG.md` (§ `[0.1.0]`, `[0.1.1]`, `[0.1.2]`) and `docs/MILESTONES.md` (§ "v0.1.0 — Released", "v0.1.1 — Planned" entries marked complete, "v0.1.2 — Planned" entries marked complete). The `target_ruby` phantom-setting fix and the runtime audit-guard spec block under [`spec/rigor/analysis/runner_spec.rb`](../spec/rigor/analysis/runner_spec.rb) "configuration wiring at runtime (audit guard)" landed during the v0.1.1 batch and remain in force.

## Where the Work Resumes

### v0.1.3 entry path

v0.1.3's three primary tracks are closed:
- **ADR-10**: Five-slice envelope + 5a / 5b / 5d open-question follow-ups all landed; 5c boundary-cross is deferred behind a `mode: full` distinct-dispatch prerequisite.
- **ADR-11 (rigor-sorbet)**: Slices 1–6 + 8 + light follow-ups (`T.must_because`, `T.reveal_type`, `T.assert_type!`, `T.bind`, `enforce_sigil`) all landed. Only per-call-site assertion gating remains.
- **Rails ecosystem (Tier 2)**: rigor-actionpack 4 phases + rigor-factorybot Phase 1 (a)+(c) all landed. ADR-9 cross-plugin chain proven end-to-end with `:helper_table` (rails-routes → actionpack) and `:model_index` (activerecord → actionpack + factorybot).

The next session can:
1. **Cut a release** (`bundle exec rake release` per `.codex/skills/rigor-release-prep/SKILL.md`, awaiting explicit user authorisation). v0.1.3 has accumulated substantial work and is shippable.
2. **Continue with deferred queue items**:
   - `mode: full` distinct dispatch (unblocks ADR-10 5c boundary-cross).
   - Per-call-site assertion gating in rigor-sorbet (the last ADR-11 deferred item).
   - Tier 3 ecosystem plugins still pending: `rigor-graphql`, `rigor-activestorage`.
   - rigor-activerecord extensions: associations, enums, scopes, validations, callbacks (each shippable as a 0.2.0+ minor bump per the roadmap).
3. **New ecosystem work**: ADR-12 candidate plugins (dry-rb adapters per [`docs/design/20260509-dry-plugins-roadmap.md`](design/20260509-dry-plugins-roadmap.md)).

### Rails ecosystem plugins (parallel running track)

The Rails plugin family continues in parallel with v0.1.x core work. The full plan is in [`docs/design/20260508-rails-plugins-roadmap.md`](design/20260508-rails-plugins-roadmap.md). Authoring proceeds **one plugin per session**, staged in `examples/rigor-<id>/` and extracted via `git subtree split` once the contract is stable.

Already landed under `examples/` (unreleased on `master`):
- **Tier 1**: `rigor-rails-routes`, `rigor-rails-i18n`, `rigor-actionmailer`, `rigor-activejob`.
- **Tier 2**: `rigor-actionpack` (4 phases — route helpers, filter chains, render targets, strong parameters → AR column validation); `rigor-factorybot` (Phase 1 (a) self-contained validation + Phase 1 (c) AR column cross-check); `rigor-activerecord` (with `manifest(produces: [:model_index])` ADR-9 publication for downstream consumers).
- **Tier 3**: `rigor-pundit`, `rigor-sidekiq`, `rigor-rspec`, `rigor-actioncable`.

Pending Tier 3: `rigor-graphql`, `rigor-activestorage`. The `rigor-sorbet` plugin (ADR-11; slices 1–6 + 8 + light follow-ups landed) sits parallel to the Rails track. `rigor-activerecord` extensions (associations, enums, scopes, validations, callbacks) ship as 0.2.0+ minor bumps.

## Open Engineering Items

Persistent items that have come up across v0.0.x slices and that the next implementer benefits from seeing without re-reading the full thread. Items already absorbed into v0.1.1 are referenced through MILESTONES rather than restated here.

1. ~~**C-body classifier indirect mutators.**~~ Closed in v0.1.2 — the extractor's seed now also matches `_modify` / `_modifiable`-named helpers whose body issues a frozen-check (`str_modifiable`, `rb_struct_modify`, `range_modify`, `rb_class_modify_check`, …). Catalog regen flips `String#replace` / `String#initialize_copy` / several String bang methods / `Range#initialize` / `Range#initialize_copy` to `mutates_self`. A transitive-closure-on-first-arg-formal-param approach was explored and reverted — over-classification on functions where the first arg is a formal yet the helper doesn't actually mutate it. Per-class blocklists still absorb the remaining cases (Time / Set helpers).

(Items previously listed here — `node_locator_spec.rb:82` and `numeric.yml` `Integer#ceildiv` — are now [v0.1.1 Track 4 maintenance](MILESTONES.md#v011--planned).)

## Reading Order for a Returning Implementer

The default goal for the next session is "land Slice 4 of ADR-10 (per-gem budget pool)" once the open design judgments are resolved, OR "author the next ecosystem plugin in parallel." Read in this order:

1. `CHANGELOG.md` `[Unreleased]` section — accumulates v0.1.3 work as it lands.
2. [`docs/MILESTONES.md`](MILESTONES.md) — release-by-release commitment envelope; v0.1.2 is the latest released milestone, v0.1.3 carries the ADR-10 implementation.
3. [`docs/adr/10-dependency-source-inference.md`](adr/10-dependency-source-inference.md) + [`docs/internal-spec/dependency-source-inference.md`](internal-spec/dependency-source-inference.md) — design rationale and analyzer contract for v0.1.3's primary track.
4. [`docs/adr/9-cross-plugin-api.md`](adr/9-cross-plugin-api.md) and [`docs/adr/11-sorbet-input-adapter.md`](adr/11-sorbet-input-adapter.md) — sibling ADRs landed in v0.1.x core; Tier 2 Rails plugins depend on ADR-9 and the rigor-sorbet plugin draft tracks ADR-11.
5. [`docs/design/20260508-rails-plugins-roadmap.md`](design/20260508-rails-plugins-roadmap.md) — Rails plugin family ordering, dependency graph, subtree-split readiness checklist.
6. [`.codex/skills/rigor-plugin-author/SKILL.md`](../.codex/skills/rigor-plugin-author/SKILL.md) — agent-facing playbook for authoring a new plugin (used for every Rails / dry-rb / Sorbet plugin session).
7. [`docs/internal-spec/public-api.md`](internal-spec/public-api.md) — public-vs-internal stability boundary. Cross-reference `spec/rigor/public_api_drift_spec.rb` before extending any pinned namespace.
8. [`examples/README.md`](../examples/README.md) — comparison table over the sixteen worked plugin examples; recommended reading order for new authors.
9. [`docs/adr/2-extension-api.md`](adr/2-extension-api.md) and [`docs/adr/7-v0.1.0-slice-decisions.md`](adr/7-v0.1.0-slice-decisions.md) — the binding design and per-slice working decisions for the v0.1.0 plugin contract that v0.1.x extends.
10. [`docs/adr/3-type-representation.md`](adr/3-type-representation.md) Working Decisions — OQ1 / OQ2 / OQ3 outcomes still bind the type-object public surface plugins consume.

After those, the implementation surface for v0.1.3 is locatable from grep over `lib/rigor/analysis/dependency_source_inference/`, `lib/rigor/cache/`, `lib/rigor/inference/method_dispatcher.rb`, `lib/rigor/configuration*`, and `lib/rigor/plugin/` (for plugin-side work).
