# Current Work — Inference Engine Checkpoint

This is a transient bookmark used to break a long implementation thread into reviewable chunks. The **normative** contracts and slice roadmap remain in [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md) and [`docs/adr/4-type-inference-engine.md`](adr/4-type-inference-engine.md). The release-by-release commitment envelope lives in [`docs/MILESTONES.md`](MILESTONES.md). If this file disagrees with any of those, the spec / ADR / milestone binds and this file is out of date.

## Status

**v0.1.2 released.** All v0.1.2 tracks landed and the version cut. Slice-by-slice recap in `CHANGELOG.md` § `[0.1.2]` and `docs/MILESTONES.md` § "v0.1.2 — Planned".

**v0.1.3 in progress.** Theme: **deliver [ADR-10 — Opt-in dependency-source inference](adr/10-dependency-source-inference.md) end-to-end.** ADR-10 was authored alongside v0.1.2 and queued for v0.1.3+; v0.1.3 starts implementing it. Five slices (config plumbing → walker + dispatcher tier → cache descriptor → per-gem budget → docs) per the ADR's "Implementation slicing" section.

- **Slice 1 (Configuration plumbing)** — landed unreleased. New `Configuration::Dependencies` value object + `Entry(gem:, mode:, roots:)` frozen Data. `.rigor.yml` gains a `dependencies.source_inference[]` section. JSON schema + parser tests + integration tests through `Configuration.load`. CHANGELOG entry under `[Unreleased]`.
- **Slice 2a (Gem resolver + Runner wiring)** — landed unreleased. `Analysis::DependencySourceInference::GemResolver.resolve` maps an entry to `Resolved` / `Unresolvable`; `Builder.build` partitions, returning a frozen `Index`. `Analysis::Runner` builds the index once per run (closing the slice-1 phantom-setting gap) and surfaces unresolvable gems as `dynamic.dependency-source.gem-not-found` `:warning` diagnostics. The walker-and-dispatcher work was internally split off as **slice 2b** so this commit stays reviewable.
- **Slice 2b-i (Walker + Index method catalog)** — landed unreleased. `Walker.walk(gem_dir:, roots:)` parses each opt-in gem's `*.rb` files and returns a flat `Hash{[class_name, method_name] => :instance | :singleton}` catalog. ADR-10 § "Hard exclusions" enforced at root granularity: `spec/` / `test/` / `bin/` are filtered before any filesystem walk and cannot be overridden by the user. `Builder.build` aggregates per-gem catalogs into `Index#method_catalog`; `Index#contribution_for(class_name:, method_name:)` answers from the table.
- **Slice 2b-ii (dispatcher tier)** — landed unreleased. New tier in `Inference::MethodDispatcher.dispatch` between `RbsDispatch.try_dispatch` and `try_user_class_fallback`: returns `Type::Combinator.untyped` (Dynamic[top]) when the receiver's class + method name match an `Index` entry. `Environment.for_project` / `Environment.new` accept `dependency_source_index:`; `Environment#dependency_source_index` accessor pinned via drift snapshot + `sig/rigor/environment.rbs`. **Slice 2 envelope done**.
- **Slice 3 (Cache descriptor + per-gem-version invalidation)** — landed unreleased. `Cache::Descriptor::DependencyEntry(gem_name:, gem_version:, mode:)` value object + new `dependencies:` slot on `Cache::Descriptor`; `compose_by_key` over `gem_name` raises `Conflict` on disagreeing version / mode; canonical-hash slot order is `configs / dependencies / files / gems / plugins`; `SCHEMA_VERSION` bumped to 2 so stale-shape entries get wiped at first run. New `DependencySourceInference::Index#cache_descriptor` lifts every `Resolved` row into a `DependencyEntry` and returns a frozen descriptor populated with the `dependencies:` slot — the primitive future cache producers compose with their own descriptors so a `bundle update` on a listed gem invalidates exactly that gem's slice. Unresolvable entries contribute nothing (no version to key on); resolved-but-disabled entries are filtered upstream by `Builder`.
- **Slices 4–5** queued (per-gem budget pool + `dynamic.dependency-source.budget-exceeded`; documentation update).

**v0.1.0 → v0.1.2 released.** Slice-by-slice recaps in `CHANGELOG.md` (§ `[0.1.0]`, `[0.1.1]`, `[0.1.2]`) and `docs/MILESTONES.md` (§ "v0.1.0 — Released", "v0.1.1 — Planned" entries marked complete, "v0.1.2 — Planned" entries marked complete). The `target_ruby` phantom-setting fix and the runtime audit-guard spec block under [`spec/rigor/analysis/runner_spec.rb`](../spec/rigor/analysis/runner_spec.rb) "configuration wiring at runtime (audit guard)" landed during the v0.1.1 batch and remain in force.

## Where the Work Resumes

### v0.1.3 entry path

Read [ADR-10](adr/10-dependency-source-inference.md) § "Implementation slicing" for the binding slice list. With Slices 1, 2a, 2b-i, 2b-ii, and 3 landed, recommended entry order for the next session:
- **Slice 4** — per-gem budget pool + `dynamic.dependency-source.budget-exceeded` diagnostic. New `dependencies.budget_per_gem` config entry; range 0.25× – 4× of the project budget. The slice 3 cache descriptor primitive (`Index#cache_descriptor`) is in place; the budget producer that consumes it gets wired here.
- **Slice 5** — documentation update. New `docs/internal-spec/dependency-source-inference.md` normative doc; cross-link from `inference-budgets.md`, `special-types.md`, `diagnostic-policy.md`.

The ADR's open questions (per-receiver plugin veto, `mode: full` retention, cache size cap, configurable tier ordering) are revisited at the slice 4 boundary.

### Rails ecosystem plugins (parallel running track)

The Rails plugin family — `rigor-rails-routes`, `rigor-rails-i18n`, `rigor-actionpack`, `rigor-actionmailer`, `rigor-activejob`, plus `rigor-activerecord` extensions — continues in parallel with v0.1.x core work. The full plan is in [`docs/design/20260508-rails-plugins-roadmap.md`](design/20260508-rails-plugins-roadmap.md). Tier 1 unblocked from v0.1.0; Tier 2 unblocked from v0.1.1's cross-plugin API. Authoring proceeds **one plugin per session**, staged in `examples/rigor-<id>/` and extracted via `git subtree split` once the contract is stable.

## Open Engineering Items

Persistent items that have come up across v0.0.x slices and that the next implementer benefits from seeing without re-reading the full thread. Items already absorbed into v0.1.1 are referenced through MILESTONES rather than restated here.

1. ~~**C-body classifier indirect mutators.**~~ Closed in v0.1.2 — the extractor's seed now also matches `_modify` / `_modifiable`-named helpers whose body issues a frozen-check (`str_modifiable`, `rb_struct_modify`, `range_modify`, `rb_class_modify_check`, …). Catalog regen flips `String#replace` / `String#initialize_copy` / several String bang methods / `Range#initialize` / `Range#initialize_copy` to `mutates_self`. A transitive-closure-on-first-arg-formal-param approach was explored and reverted — over-classification on functions where the first arg is a formal yet the helper doesn't actually mutate it. Per-class blocklists still absorb the remaining cases (Time / Set helpers).

(Items previously listed here — `node_locator_spec.rb:82` and `numeric.yml` `Integer#ceildiv` — are now [v0.1.1 Track 4 maintenance](MILESTONES.md#v011--planned).)

## Reading Order for a Returning Implementer

The default goal is "ship v0.1.0, then start v0.1.1." With v0.1.0 version-bumped on `master`, the working assumption for the next session is "implement a v0.1.1 slice." Read in this order:

1. `CHANGELOG.md` `[Unreleased]` section — accumulates v0.1.1 work as it lands.
2. [`docs/MILESTONES.md`](MILESTONES.md) — the four-track v0.1.1 slice list under "v0.1.1 — Planned".
3. [`docs/adr/9-cross-plugin-api.md`](adr/9-cross-plugin-api.md) — binding design for Track 2; six implementation slices.
4. [`docs/design/20260508-rails-plugins-roadmap.md`](design/20260508-rails-plugins-roadmap.md) — Rails plugin family ordering, dependency graph, subtree-split readiness checklist.
5. [`.codex/skills/rigor-plugin-author/SKILL.md`](../.codex/skills/rigor-plugin-author/SKILL.md) — agent-facing playbook for authoring a new plugin (used for every Rails plugin session).
6. [`docs/internal-spec/public-api.md`](internal-spec/public-api.md) — public-vs-internal stability boundary. Cross-reference `spec/rigor/public_api_drift_spec.rb` before extending any pinned namespace.
7. [`examples/README.md`](../examples/README.md) — comparison table over the seven worked plugin examples; recommended reading order for new authors.
8. [`docs/adr/2-extension-api.md`](adr/2-extension-api.md) and [`docs/adr/7-v0.1.0-slice-decisions.md`](adr/7-v0.1.0-slice-decisions.md) — the binding design and per-slice working decisions for the v0.1.0 plugin contract that v0.1.1 builds on.
9. [`docs/adr/3-type-representation.md`](adr/3-type-representation.md) Working Decisions — OQ1 / OQ2 / OQ3 outcomes still bind the type-object public surface plugins consume.

After those, the implementation surface for v0.1.1 is locatable from grep over `lib/rigor/inference/narrowing.rb`, `lib/rigor/flow_contribution*.rb`, `lib/rigor/plugin/`, `lib/rigor/cache/`, `lib/rigor/rbs_extended/`, and `lib/rigor/analysis/`.
