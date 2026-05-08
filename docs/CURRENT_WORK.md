# Current Work — Inference Engine Checkpoint

This is a transient bookmark used to break a long implementation thread into reviewable chunks. The **normative** contracts and slice roadmap remain in [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md) and [`docs/adr/4-type-inference-engine.md`](adr/4-type-inference-engine.md). The release-by-release commitment envelope lives in [`docs/MILESTONES.md`](MILESTONES.md). If this file disagrees with any of those, the spec / ADR / milestone binds and this file is out of date.

## Status

**v0.1.0 version-bumped on `master` (commit `6170832`); release pending.** All six plugin-contract slices and the v0.1.0-polish work landed (six worked plugin examples, the nine-chapter end-user handbook, the named-capture narrowing fix, the `;`-prefixed block-local nil shadow fix). The seventh plugin example (`rigor-activerecord`) landed during the polish window. Per the no-autonomous-version-bump rule in [`AGENTS.md`](../AGENTS.md), `bundle exec rake release` waits for explicit user authorisation. The slice-by-slice recap is in `CHANGELOG.md`'s `[0.1.0]` section and the v0.1.0 row of [`docs/MILESTONES.md`](MILESTONES.md).

**v0.1.2 in progress.** Track 1 (example plugin return-type migration) landed on `master` for four of the seven worked plugins — `rigor-lisp-eval`, `rigor-pattern`, `rigor-units`, `rigor-activerecord` now contribute call-site return types via `#flow_contribution_for`. The diagnostic trace stays — both channels run from the same interpretation. The other three (`rigor-deprecations`, `rigor-statesman`, `rigor-routes`) remain diagnostic-only by design (no return-type fit / RBS-expressible). Spec helper extension (`signature_paths:` keyword on `run_plugin`) landed alongside so narrowing assertions can provide minimal sigs for `call.undefined-method` to fire on user-defined classes. Slice list in [`docs/MILESTONES.md`](MILESTONES.md) § "v0.1.2 — Planned".

**v0.1.1 complete.** All four tracks landed unreleased on the work branch:

- **Track 1 slice 1** — regex pattern → refinement-name recogniser.
- **Track 1 slice 2** — `String#to_i` / `#to_int` (2a) and `Kernel#Integer(s)` (2b) on `decimal-int-string` / `numeric-string` → `non-negative-int`.
- **Track 1 slice 3** — full `self`-narrowing in `predicate-if-*` / `assert-if-*` / `assert` (LocalVariable / InstanceVariable / SelfNode / implicit-self receiver shapes).
- **Track 1 slice 4** — `String#start_with?` / `#end_with?` / `#include?` flow facts (FactStore-based; no new carrier).
- **Track 1 slice 5** — `literal-string` preservation through `#strip` family (5a), `Integer#to_s` precision on non-negative `IntegerRange` (5b), `#center` / `#ljust` / `#rjust` literal-bearing lift (5c). `Numeric#to_s` intentionally retracted (no clean carrier for `Float` / signed `Integer` outputs).
- **Track 2 (ADR-9 cross-plugin API + return-type contributions)** — slices 1 → 5 (`Plugin::FactStore`, `Services#fact_store`, `#prepare(services)` hook + Runner invocation, `manifest(produces:/consumes:)`, topological sort + missing-producer detection) + slice 7 (`Plugin::Base#flow_contribution_for` hook + dispatcher tier ahead of `RbsDispatch`). Tier 2 Rails plugins are unblocked.
- **Track 3** — slice 8 (helpers, prior commit `ce64bb6`), slice 9 (per-demo cache isolation under `tmp/` + CLI fix to honour `cache.path` from `.rigor.yml`), slice 10 (examples re-included in RuboCop with documented relaxations).
- **Track 4** — fully drained: item 11 (three `lib/` sig drifts closed), item 12 (`node_locator_spec.rb:82` stale), item 13 (prelude `composed` bodies reclassified `unknown` → `dispatch`).

Configuration audit (also during this batch): closed the `target_ruby` phantom-setting wiring gap (now passed to `Prism.parse_file(version:)` at all three parse sites), and added a runtime audit-guard spec block so future `.rigor.yml` settings can't go phantom silently.

Working state: 2195 RSpec examples / 0 failures, RuboCop 264 files / 0 offenses, `bundle exec exe/rigor check lib` reports `No diagnostics`. **v0.1.1 is ready for `bundle exec rake release` once the user authorises it.** Full slice list in [`docs/MILESTONES.md`](MILESTONES.md) § "v0.1.1 — Planned".

## Where the Work Resumes

### Rails ecosystem plugins (parallel running track)

The Rails plugin family — `rigor-rails-routes`, `rigor-rails-i18n`, `rigor-actionpack`, `rigor-actionmailer`, `rigor-activejob`, plus `rigor-activerecord` extensions — is being authored in parallel with v0.1.x core work. The full plan is in [`docs/design/20260508-rails-plugins-roadmap.md`](design/20260508-rails-plugins-roadmap.md). Tier 1 plugins (current API, no analyser-side change required) are unblocked and authoring can start immediately, **one plugin per session**, staged in `examples/rigor-<id>/` and extracted via `git subtree split` once the contract is stable. Tier 2 (`rigor-actionpack` Phase 1, `rigor-factorybot`) blocks on [ADR-9 — Cross-plugin API](adr/9-cross-plugin-api.md), which is v0.1.1 Track 2.

### v0.1.2 entry path

Read [`docs/MILESTONES.md`](MILESTONES.md) § "v0.1.2 — Planned" for the slice list. Recommended entry order:

- v0.1.2 Track 1 (four of seven example plugins migrated to `#flow_contribution_for`) is on `master`. v0.1.1 also remains version-bumped on `master` and ready for `bundle exec rake release` once the user authorises both cuts together (or sequentially, per [`.codex/skills/rigor-release-prep/SKILL.md`](../.codex/skills/rigor-release-prep/SKILL.md)).
- The Rails plugin parallel running track is unblocked — Tier 2 (`rigor-actionpack` Phase 1, `rigor-factorybot`) can now author against the cross-plugin API. Tier 1 plugins (`rigor-rails-routes`, `rigor-rails-i18n`, `rigor-actionmailer`, `rigor-activejob`) were unblocked from v0.1.0.
- Out-of-scope items deferred from v0.1.1 (interface-strictness on overload selection, new `flow.*` / `def.*` rule families, `Data.define` initializer dispatch, `Plugin::IoBoundary#open_url`, DX tooling, LSP daemon, etc.) carry forward to v0.1.3+.

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
