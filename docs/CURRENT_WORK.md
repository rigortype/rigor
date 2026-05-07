# Current Work — Inference Engine Checkpoint

This is a transient bookmark used to break a long implementation thread into reviewable chunks. The **normative** contracts and slice roadmap remain in [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md) and [`docs/adr/4-type-inference-engine.md`](adr/4-type-inference-engine.md). The release-by-release commitment envelope lives in [`docs/MILESTONES.md`](MILESTONES.md). If this file disagrees with any of those, the spec / ADR / milestone binds and this file is out of date.

## Status

**v0.1.0 version-bumped on `master` (commit `6170832`); release pending.** All six plugin-contract slices and the v0.1.0-polish work landed (six worked plugin examples, the nine-chapter end-user handbook, the named-capture narrowing fix, the `;`-prefixed block-local nil shadow fix). The seventh plugin example (`rigor-activerecord`) landed during the polish window. Per the no-autonomous-version-bump rule in [`AGENTS.md`](../AGENTS.md), `bundle exec rake release` waits for explicit user authorisation. The slice-by-slice recap is in `CHANGELOG.md`'s `[0.1.0]` section and the v0.1.0 row of [`docs/MILESTONES.md`](MILESTONES.md).

**v0.1.1 in flight.** Four parallel tracks scoped. Landed unreleased on the work branch:
- Track 1 slice 1 — regex pattern → refinement-name recogniser
- Track 1 slice 2 — `String#to_i` / `#to_int` (2a) and `Kernel#Integer(s)` (2b) on `decimal-int-string` / `numeric-string` → `non-negative-int`
- Track 1 slice 5 — `literal-string` preservation through `#strip`/`#lstrip`/`#rstrip`/`#chomp`/`#chop`/`#scrub` (5a), `Integer#to_s` precision on non-negative `IntegerRange` (5b), `#center`/`#ljust`/`#rjust` literal-bearing lift (5c)
- Track 3 slice 8 (helpers, prior commit `ce64bb6`) and slice 10 — examples re-included in RuboCop with documented relaxations
- Track 4 fully drained: item 11 (three `lib/` sig drifts closed), item 12 (`node_locator_spec.rb:82` stale; constant-folding already removes the diagnostic), item 13 (prelude `composed` bodies reclassified `unknown` → `dispatch`).

Working state: 2140 RSpec examples / 0 failures, RuboCop 262 files / 0 offenses, `bundle exec exe/rigor check lib` reports `No diagnostics`. Remaining v0.1.1: Track 1 slice 3 (`self`-narrowing in `predicate-if-*` — needs design investigation), slice 4 (`String#start_with?` / `#end_with?` / `#include?` — needs a new "starts-with" refinement carrier, design pending); Track 2 (cross-plugin API per [ADR-9](adr/9-cross-plugin-api.md) + return-type contributions); Track 3 slice 9 (demo cache directory handling — needs the `(a)` / `(b)` design call). Full slice list in [`docs/MILESTONES.md`](MILESTONES.md) § "v0.1.1 — Planned".

## Where the Work Resumes

### Rails ecosystem plugins (parallel running track)

The Rails plugin family — `rigor-rails-routes`, `rigor-rails-i18n`, `rigor-actionpack`, `rigor-actionmailer`, `rigor-activejob`, plus `rigor-activerecord` extensions — is being authored in parallel with v0.1.x core work. The full plan is in [`docs/design/20260508-rails-plugins-roadmap.md`](design/20260508-rails-plugins-roadmap.md). Tier 1 plugins (current API, no analyser-side change required) are unblocked and authoring can start immediately, **one plugin per session**, staged in `examples/rigor-<id>/` and extracted via `git subtree split` once the contract is stable. Tier 2 (`rigor-actionpack` Phase 1, `rigor-factorybot`) blocks on [ADR-9 — Cross-plugin API](adr/9-cross-plugin-api.md), which is v0.1.1 Track 2.

### v0.1.1 entry path

Read [`docs/MILESTONES.md`](MILESTONES.md) § "v0.1.1 — Planned" for the full slice list. Recommended entry order:

- **Track 1 slice 4** (`String#start_with?` / `#end_with?` / `#include?` against literal needles) needs a new refinement carrier (or a flow-fact form) to express "starts with X". Design pending.
- **Track 1 slice 3** (`self`-narrowing in `predicate-if-*` directives) needs investigation of how the existing `predicate-if-true: x is T` plumbing handles `self` as the target.
- **Track 2 ADR-9 slice 1** (`Plugin::FactStore` value object) is the smallest unblocking step for Tier 2 Rails plugins; six independently shippable slices in the ADR.
- **Track 3 slice 9** (demo cache directory handling) is queued behind a `(a)` / `(b)` design call.
- **Track 4 maintenance** is fully drained.

## Open Engineering Items

Persistent items that have come up across v0.0.x slices and that the next implementer benefits from seeing without re-reading the full thread. Items already absorbed into v0.1.1 are referenced through MILESTONES rather than restated here.

1. **C-body classifier indirect mutators.** The catalog extractor's regex does not follow `str_modifiable` / `time_modify` / similar helper indirection; methods like `String#replace`, `Time#localtime`, and `Set#reset` land as `:leaf` even though they mutate. The pure-`rb_check_frozen`-wrapper detection landed in v0.0.5 narrows the gap, but per-class blocklists in `STRING_CATALOG` / `TIME_CATALOG` / `SET_CATALOG` still absorb false positives the narrow regex misses. Long-term: the classifier should track the helpers transitively without over-flagging legitimate non-mutators (the `Array#to_a` regression that gated the v0.0.5 fix). Out of scope for v0.1.1; deferred until a concrete user-visible regression motivates it.

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
