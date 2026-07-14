# Rigor Roadmap

Forward-looking commitments: what's actively in flight, what's
planned next, what's deliberately out of scope.

This file is **planning material**, not a release log. For the
"what shipped" record, see [`CHANGELOG.md`](../CHANGELOG.md)
(active `0.2.x` cycle) and the archives
[`docs/CHANGELOG-0.1.x.md`](CHANGELOG-0.1.x.md) (`0.1.x`) and
[`docs/CHANGELOG-0.0.x.md`](CHANGELOG-0.0.x.md) (`0.0.x`).

When this file disagrees with an ADR or spec, the ADR / spec
binds and this file is out of date.

## Released milestones (pointers only)

Full release notes live in `CHANGELOG.md`; the planning envelopes
that shaped each cut are preserved in git history (see
`docs/MILESTONES.md` at the commit that renamed it to `ROADMAP.md`).

| Version | Released | Theme |
| --- | --- | --- |
| v0.0.3 — v0.0.9 | 2026-05-02 → 2026-05-05 | Type vocabulary, inference engine, persistent cache. See [`docs/CHANGELOG-0.0.x.md`](CHANGELOG-0.0.x.md). |
| v0.1.0 | 2026-05-07 | First plugin contract (six slices); seven worked examples. See `CHANGELOG.md` § `[0.1.0]`. |
| v0.1.1 | 2026-05-08 | Literal-string narrowing depth, cross-plugin API, plugin authoring DX. See `CHANGELOG.md` § `[0.1.1]`. |
| v0.1.2 | 2026-05-09 | Example plugin return-type migration, engine depth follow-up. See `CHANGELOG.md` § `[0.1.2]`. |
| v0.1.4 | 2026-05-14 | ADR-10 / ADR-11 / ADR-13 deferred queues, ADR-14 `rigor sig-gen` end-to-end, `Type::BoundMethod` carrier, eighteen worked plugin examples. (The v0.1.3 commitment envelope absorbed extra tracks before cut and shipped as v0.1.4.) See `CHANGELOG.md` § `[0.1.4]`. |
| v0.1.5 | 2026-05-16 | ADR-15 Ractor migration end-to-end (Phases 1–4c + 4b.x), real-world Rails survey (14 projects, 31,840 files) driving production improvements (vendored gem RBS, ActiveSupport core_ext opt-in bundle, Bundler-aware sig discovery), ADR-16 macro / DSL expansion substrate (closes O2 at the WD13 floor), O4 Layer 3 slices 1+2+3 (`Gemfile.lock` parse + `rbs_collection.lock.yaml` awareness + missing-gem `:info` diagnostic), DEFAULT_LIBRARIES stdlib coverage expansion (1,273 → 1,427 RBS classes), `is_a?(C)` lexical-nesting constant resolution, twenty-four worked plugin examples. See `CHANGELOG.md` § `[0.1.5]`. |
| v0.1.6 | 2026-05-19 | ADR-12 / ADR-17 / ADR-18 floors + worked consumers; editor mode v1 + Language Server v1/v2; ADR-20 Lightweight HKT; ecosystem plugins + the `rigor-rails` meta-gem scaffold. See `CHANGELOG.md` § `[0.1.6]`. |
| v0.1.7 | 2026-05-20 | ADR-22 baseline mechanism (slices 1+2) + project-onboarding groundwork; survey-driven plugin / engine false-positive fixes; Pillar 2 <del>"your specs are types"</del> slices 1+2+3 <ins>(the pillar framing was retired by [ADR-59](adr/59-spec-assertions-are-not-signatures.md) on 2026-06-12 — assertions never feed implementation signatures; the shipped slices themselves — matcher narrowing, `let`/`subject` binding, `:factory_index` — remain accurate and live)</ins>. See `CHANGELOG.md` § `[0.1.7]`. |
| v0.1.8 | 2026-05-21 | Mastodon-survey false-positive reduction: ADR-15 fork-based worker pool (the active `workers > 0` backend), ADR-23 `rigor triage` diagnostic-triage subcommand, ADR-24 implicit-self method-call resolution. See `CHANGELOG.md` § `[0.1.8]`. |
| v0.1.9 | 2026-05-23 | Designated "last preview cut": external-user SKILL trio (`rigor-project-init`, `rigor-baseline-reduce`, external-author `rigor-plugin-author` variant per [ADR-22 WD8](adr/22-baseline-and-project-onboarding.md)); ADR-22 baseline slice 5 (`rigor baseline regenerate` + `--baseline-strict` CI gate); empirical-defaults tightening across v0.1.7 / v0.1.8 survey data. See `CHANGELOG.md` § `[0.1.9]`. |
| v0.1.10 | 2026-05-27 | `rigor mcp --transport stdio` (ADR-33, seven read-only tools); `rigor sig-gen --params=observed` attr_reader inference; `rigor coverage` precision gate; `rigor check --treat-all-as-inline-rbs`; `rigor-rbs-inline` plugin (ADR-32); browser playground (ADR-29 slices 1–4); `rigor annotate` return-type annotation; ADR-28 path-scoped protocol contracts + `rigor-hanami`; constant folding (Date/DateTime/Time, Math, String/Integer/Float mid-priority, Hash shape handlers); `return if @ivar.nil?` ivar-guard narrowing fix. See `CHANGELOG.md` § `[0.1.10]`. |
| v0.1.11 | 2026-05-27 | Plugin bundling into `rigortype` gem; portable baseline paths; `rigor-rails-routes` five false-positive sources eliminated against kaigionrails conference-app + Mastodon trials (`new_`/`edit_` prefix order, anonymous-`get` routes, `scope as:` prefix + arity, `draw(:name)` partial loading, `concern` body no-op, trailing options-hash +1 arity rule); `rigor-rails-i18n` lazy translation keys in controllers; Rails quickstart manual. See `CHANGELOG.md` § `[0.1.11]`. |
| v0.1.12 | 2026-05-28 | OSS-realism cycle against Mastodon / Redmine / GitLab FOSS: Mastodon `app + lib` errors **789 → 6 (−99.2%)**, Redmine **163 → 79 (−51%)**, GitLab FOSS `app/{controllers,mailers,workers,services}` **~670 → ~140**. Six `flow.always-truthy / always-falsey` FP patterns closed (read-before-write nil, intervening method-call, retry edge, falsey-rvalue defensive init, polarity-aware guard, mutator widening). New narrowing primitives (`receiver[key] \|\|= default`, single-hop method-chain `is_a?`). `Class.new(Parent) { \|c\| ... }` and `Hash#each { \|k, v\| ... }` auto-splat typing. Comprehensive plugin expansion: `rigor-rails-routes` recognises devise_for / use_doorkeeper / mount / concern / with_options / member-collection-shorthand etc.; `rigor-actionpack` filter & render with nested-module qualification; `rigor-activerecord` migration exclusion / virtual-table models / Postgres array columns / scope-body resolution; `rigor-actionmailer` include-of-concerns; `rigor-rails-i18n` Rails-shipped key prefixes. New `rigor plugins` subcommand. See `CHANGELOG.md` § `[0.1.12]`. |
| v0.1.13 | 2026-05-29 | AI-assisted onboarding + single-file script analysis: new `rigor skill` subcommand (bundled Agent Skills discoverable from a `mise use gem:rigortype` install); `call.unresolved-toplevel` diagnostic ([ADR-34](adr/34-toplevel-unresolved-self-call-default.md)) + `pre_eval:` project monkey-patch pre-evaluation ([ADR-17](adr/17-monkey-patch-pre-evaluation.md)). See `CHANGELOG.md` § `[0.1.13]`. |
| v0.1.14 | 2026-05-29 | Machine-readable install guide (`docs/install.md`) for AI-agent-driven setup ([ADR-27](adr/27-tool-distribution-model.md)); fixes the `RBS::DuplicatedDeclarationError` that silently broke the environment after `rbs collection install`. See `CHANGELOG.md` § `[0.1.14]`. |
| v0.1.15 | 2026-05-29 | Liskov override-compatibility diagnostic family (`def.override-*`, [ADR-35](adr/35-override-signature-compatibility.md)); `rigor plugin` source-browsing command; sharper reporting + `rigor triage` recognisers + onboarding-skill routing for undefined-method diagnostics that are really uninstalled project monkey-patches or generated DSLs. See `CHANGELOG.md` § `[0.1.15]`. |
| v0.1.17 | 2026-06-06 | Internal-structure review + performance tuning. Incremental analysis (`rigor check --incremental`, ADR-46) + unchanged-project fast path (ADR-45) + large allocation reductions (ADR-44); Elixir-v1.20-inspired narrowing (`Array` non-empty, `Hash` key-presence) + `flow.unreachable-clause` (ADR-47); `rigor:v1:conforms-to` directive; `call.self-undefined-method` rule (shipped `:off`, ADR-24 slice 4); `Data.define` value folding (ADR-48). Also shipped (process / CI / docs, not in the user-facing notes): the release-engineering machinery for the road to v0.2.0 — ADR-49 (ADR-authoring rubric + `rigor-adr-author` skill + corpus audit), ADR-50 (release-engineering + stability strategy), the `release/x.y.z` branch + `release-gate.yml` + `make bench-perf` perf gate. See `CHANGELOG.md` § `[0.1.17]`. |
| v0.1.18 | 2026-06-11 | CI-environment support (ADR-51): six `rigor check --format` CI-native renderings (SARIF, GitHub Actions, GitLab Code Quality, Checkstyle, JUnit, TeamCity) + runtime CI auto-detection (WD7) + copy-paste CI setup templates + the bundled `rigor-ci-setup` skill. See `CHANGELOG.md` § `[0.1.18]`. |
| v0.1.19 | 2026-06-13 | Precision-and-trust cycle for procedural Ruby — and the **effective release candidate for v0.2.0** (final `0.1.x` preview cut). Method-call results flow through user-defined helpers (ADR-57) backed by recursive-return (ADR-55) and block/loop captured-mutation (ADR-56) precision; a large real-world false-positive batch on data-structure / parsing / networking code (ADR-58 + the CRuby-stdlib and 16-repo realistic-usecase sweeps); a run-scoped return memo removing a superlinear whole-`lib` slowdown the new inference would otherwise cost; pre-1.0 plugin-contract consolidation (ADR-60, with BC breaks); agent-friendly structured diagnostic fields (ADR-61); the ADR-50 WD1 compatibility surface doc + WD2 bleeding-edge opt-in foundation; and ADR-54 cache slimming (~33.7 MB → ~2 MB per project). See `CHANGELOG.md` § `[0.1.19]`. |
| v0.2.0 | 2026-06-17 | **First publicly-announced (general / evaluation) release** ([ADR-50](adr/50-release-engineering-and-stability-strategy.md)): publishes the enumerated compatibility surface ([`docs/compatibility.md`](compatibility.md)) as a minor-non-break trial toward the v1.0.0 freeze. Detection **"teeth"** + protection coverage — `call.undefined-method` / `call.argument-type-mismatch` now fire on union / refinement / multi-overload receivers (ADR-62 mutation harness, ADR-63 `coverage --protection`); wider constant folding; predefined-constant refinement; `Struct.new` value folding (ADR-48); `evidence_tier` + `documentation_url` diagnostic metadata (ADR-65). See `CHANGELOG.md` § `[0.2.0]`. |
| v0.2.1 | 2026-06-19 | **Second `0.2.x` evaluation cut** — detection + configuration polish. `Gemfile.lock`-gated ActiveSupport core-ext RBS overlay ([ADR-72](adr/72-gemfile-lock-gated-rbs-overlays.md)) resolving the v0.2.0 `evidence_tier` Rails false-positive feedback at its source (`3.minutes` and friends); `rigor check` config-resolves-to-nothing warnings (`config_warnings`); fused static∪dynamic protection map (`rigor coverage --protection --mutation --with-tests`, [ADR-70](adr/70-fused-protection-coverage.md)); more pure scalar/structural literal folds; fixes (bare-`off` severity crash, an escaping-block option-hash false positive, a gem-packaging bug that shipped installed gems without their bundled RBS data). First release landed via the new CI-gated release PR (`rigor-release-prep` update). See `CHANGELOG.md` § `[0.2.1]`. |
| v0.2.2 | 2026-06-21 | SKILL-driven onboarding UX ([ADR-73](adr/73-skill-driven-user-experience.md) / [ADR-74](adr/74-offline-doc-access-and-llms-txt.md)): `rigor docs` (offline gem-bundled docs), `rigor skill describe` (presence-only next-step recommender), the `rigor-next-steps` / `rigor-ask` skill family; a field-trial round of clearer diagnostics + config warnings; more pure folds; a leaner seed pass on definition-dense projects. See `CHANGELOG.md` § `[0.2.2]`. |
| v0.2.3 | 2026-06-21 | Focused `rigor triage` usability fix ([ADR-23 WD6](adr/23-diagnostic-triage-command.md)): the distribution / selectors / hotspot views now count only actionable diagnostics (`error` + `warning`), excluding the plugin-recognition-trace `info` that buried the genuine signal on Rails projects. See `CHANGELOG.md` § `[0.2.3]`. |
| v0.2.4 | 2026-06-22 | RBS version-range compatibility fix ([ADR-79](adr/79-rbs-version-range-over-pinned-determinism.md)): two crashes on RBS 3.x corrected so the full declared `rbs >= 3.0, < 5.0` range works, plus a CI matrix exercising the RBS-loading surface against 3.x and 4.x. See `CHANGELOG.md` § `[0.2.4]`. |
| v0.2.5 | 2026-06-24 | `rigor-rails-i18n` view-template lazy-key validation: `t('.title')` inside ERB / Haml / Slim expanded via the Rails virtual-path convention and checked against `config/locales/*.yml`. See `CHANGELOG.md` § `[0.2.5]`. |
| v0.2.6 | 2026-06-27 | Self-explanation + shape-aware inference. `rigor coverage --protection` labels each untyped hole with its `dynamic_origin` cause + `tractability` axis ([ADR-75](adr/75-dynamic-provenance.md)); new `rigor doctor` routes setup problems to their fix ([ADR-77](adr/77-doctor-and-upgrade-commands.md)); literal hashes / arrays keep their shape through `freeze` / `dup` / `clone` ([ADR-76](adr/76-effect-modeling-freeze-dup-shape-preservation.md) / [ADR-78](adr/78-reflexive-overfold-always-truthy.md)); the `type_specifier` plugin hook is renamed to `narrowing_facts` with a deprecated alias ([ADR-80](adr/80-narrowing-facts-rename.md)). See `CHANGELOG.md` § `[0.2.6]`. |
| v0.1.16 | 2026-06-03 | Plugin architecture overhaul and internal mechanism re-documentation. ADR-37/38/39/40 fully landed: all 14 bundled diagnostic-emitting plugins migrated onto `node_rule` (engine-owned walk, PHPStan-style); `dynamic_return` / `type_specifier` Slice 2; `rigor plugins --capabilities` AI-legible catalogue (Slice 3); `additional_initializers:` (ADR-38 def-form); `config_schema` declared defaults (ADR-40, 13 plugins migrated); `Source::Literals` grid complete + 10 plugins migrated; `Plugin::Inflector` over real `ActiveSupport::Inflector` + selectable isolation strategy (`process` default, `Plugin::Isolation`). ADR-43 RBS-complete ancestor resolution (`Plugin::Base` allow-list) + `make check-plugins` gate in `verify` + CI. Plugin contract structural guards: conformance spec, all-plugins-load spec, demos-run spec, external-plugin fixture (v0.2.0 gate 1 executable evidence). `Plugin::Base` + `Manifest` RBS surface completed. RBS robustness: synthesised namespaces + stub types for malformed/stale project `signature_paths:` sigs. `rigor-activerecord` missing-schema memoization fix (Redmine −86% memory, −51% wall time). Inference-budget survey + `RIGOR_BUDGET_TRACE` instrumentation. See `CHANGELOG.md` § `[0.1.16]`. |

## Release strategy — the road to v1.0.0

The `0.1.x` line was the **preview** line. **v0.2.0 (2026-06-17) opened the
`0.2.x` evaluation line** — the first publicly-announced version, meant for
trial deployment in real products and to solicit outside feedback;
**v0.2.6 (2026-06-27) is the latest cut** along that line (see the milestones
table). It is still not a formal / GA release; the road now points at
**v1.0.0**, the hard contract freeze.

| Line | Role |
| --- | --- |
| `0.1.x` | **Preview (closed).** v0.1.9 was the originally-designated "last preview cut", but trial work against Mastodon / Redmine / GitLab FOSS extended it through v0.1.19 with false-positive-reduction, onboarding, feature, architecture, and performance cycles. v0.1.19 (2026-06-13) was the final preview cut / effective RC. |
| `v0.2.0` | **First evaluation release (RELEASED 2026-06-17).** Publicly announced as the first version intended for real-product trial deployment; opens the evaluation period. See `CHANGELOG.md` § `[0.2.0]`. |
| `0.2.x` | **Evaluation line (current; v0.2.0 → v0.2.6 shipped).** Not yet a formal version; the goal is to bring every planned feature — **except the Ractor concurrency track** — to high completion / production quality, and to gather outside feedback. |
| `v1.0.0` | **Hard contract freeze (target).** The enumerated public surface ([`docs/compatibility.md`](compatibility.md)) becomes binding; a change invalidating a conforming user's config / plugin / suppression is major-version-only from here. |

### What the road to v0.2.0 settled (now complete)

The v0.2.0 gating conditions — all **met**:

- **External plugin contract stabilised + documented.** Executable evidence (external-plugin fixture + conformance / all-plugins-load / demos-run specs) landed v0.1.16; the documented stability commitment shipped v0.1.19 as [`docs/compatibility.md`](compatibility.md) (the [ADR-50](adr/50-release-engineering-and-stability-strategy.md) WD1 surface document) — it binds as a **trial** at v0.2.0 and freezes at v1.0.0.
- **Distribution model settled** as a single bundled `rigortype` gem ([ADR-31](adr/31-contribution-and-supply-chain-policy.md), commit `9769f5fa`) — the subtree-split / per-plugin-publish gate was *superseded*, leaving only the external third-party `rigor-*` path (the author's own repo, depending on `gem "rigortype"`).
- **Onboarding self-serve** via the SKILL trio + `docs/install.md` (v0.1.9 / v0.1.13 / v0.1.14), **upgraded in the `0.2.x` line by [ADR-73](adr/73-skill-driven-user-experience.md)** (landed 2026-06-20, unreleased): the `rigor-next-steps` entry point + a live `rigor skill describe` (presence-only probe → recommended next skill) over a 13-skill catalogue, distributed via vercel-labs/skills + the bundled gem, field-trial-hardened (conference-app + a 13-model OpenCode cross-vendor validation). Deferred follow-ups in § "Future cycles" below.
- **Release-engineering machinery** ([ADR-50](adr/50-release-engineering-and-stability-strategy.md), PHPStan-modelled): v0.2.0 is the release-engineering *trial* (the machinery + a minor-non-break pledge as rehearsal), v1.0.0 the *hard freeze*. The `release/x.y.z` branch + `release-gate.yml` + `make bench-perf` shipped v0.1.17; the perf baseline + Mastodon OSS-sweep thresholds are calibrated and the gate is required (both **recalibrated at the v0.2.0 cut** — `bench/baseline.json` + `data/oss-sweep/mastodon-thresholds.json`; see `docs/CURRENT_WORK.md`). The WD2 bleeding-edge opt-in foundation is wired (empty overlay; `bleeding_edge:` config + `rigor show-bleedingedge` + `rigor check --bleeding-edge[=ids]`).

**Released-version detail lives in `CHANGELOG.md`** (the milestones table above points to each `§`): v0.1.18 (CI-environment support, [ADR-51](adr/51-ci-diagnostic-output-formats.md) — six CI-native `--format` renderings + runtime CI auto-detection), v0.1.19 (precision-and-trust + the pre-freeze plugin-contract consolidation [ADR-60]), v0.2.0 (detection teeth [ADR-62] + protection coverage [ADR-63] + the compatibility-surface trial [ADR-50]).

**ADR-50 remaining (post-v0.2.0):** the support-line model (WD5 — latest + previous minor, → PHPStan `1.x`-default-branch post-1.0), a `rigor upgrade` migration command (WD7, deferred until a concrete BC gives it a target), and the first bleeding-edge `FEATURES` entry when a next-major discipline is queued (the overlay is empty today).

### v0.2.x — high-completion evaluation line

Across the `0.2.x` series the goal is to bring the planned
feature set to high completion / production quality. The
demand-driven backlog under § "Future cycles" below is, under
this plan, the **v0.2.x completion target** rather than an
open-ended queue — every item there is in scope for `0.2.x`
**except the Ractor concurrency track**.

**Ractor is deliberately excluded.** ADR-15's Ractor worker pool
was found unusable on Ruby 4.0.x (Ruby Bug #22075 plus a
deterministic `Ractor::IsolationError`); v0.1.8's fork-based pool
is the active backend. The Ractor pool stays parked behind
`RIGOR_POOL_BACKEND=ractor` and ADR-15 § OQ1; completing it is
NOT a `0.2.x` goal and waits on upstream CRuby fixes.

### The next cut — v0.3.0 (v0.2.9 shipped 2026-07-11)

The single-digit version policy made **v0.2.9 the last `0.2.x` cut**; its
successor `0.3.0` is the next release.

**v0.2.9 (shipped 2026-07-11) — a large-Rails type-coverage cut.** The planned
"type-inference strengthening" framing was superseded by the GitLab-scale
onboarding arc. It shipped `db/structure.sql` schema support, strong-parameters
chain typing, route-helper naming fidelity, cross-file module-facade resolution
([ADR-57](adr/57-self-call-return-adoption.md) WD3), external-gem missing-RBS
provenance labelling ([ADR-82](adr/82-dynamic-provenance-wiring.md) WD9), a
fork-parallel `coverage --protection` scan, persistent-cache upgrade / ABI
hardening, and the `rigor-playground` → `apps/` relocation. Full record:
`CHANGELOG.md` § `[0.2.9]`.

The FP-safe inference-precision candidates that did **not** make v0.2.9 —
deterministic builtin / stdlib folds (`rigor-type-coverage-uplift`), the
Elixir-v1.20 § 4-4 upper-bound length narrowing track (`tuple_size(x) < 3`,
needs a length-range carrier), [ADR-47](adr/47-narrowing-driven-clause-reachability.md)
WD3b deconstructing / value / variable `case`/`in` exhaustiveness, and the
bucket-3 default-widening diagnostics (survey P0, receiver-typing / nilability /
flow / override precision that already exists internally) — roll forward as
compatibility-safe candidates for v0.3.0 and later. Nothing about them is
`0.2.x`-specific: each ships `:off` / `:info` behind a stable id and promotes
into the default profile only through a green `rigor-survey` corpus diff per
[ADR-50](adr/50-release-engineering-and-stability-strategy.md), so a minor that
otherwise breaks (v0.3.0) can still carry them.

The M3 / member-shape arc ([ADR-67](adr/67-parameter-type-inference.md) `check`-walk
wiring → [ADR-68](adr/68-class-builder-folding.md) → [ADR-66](adr/66-discriminated-union-member-typing.md))
stays demand-gated: ADR-67 WD2 in-body inference was spiked and deferred
(the protection ceiling is a measured hard floor, see `docs/notes/20260706-adr67-wd2-in-body-inference-design-spike.md`),
and the `check`-walk wiring's value is murky.

**v0.3.0 — the deprecation-clearance + performance minor (the first cut that may
break).** Semver `0.x` permits a minor to break, and every hard deprecation was
scheduled with an alias/warning window through `0.2.x` for removal here:

1. **CLI verb subcommands removed** — `rigor docs list` / `path` and `rigor skill
   list` / `print` / `path` (the flags `--list` / `--path` / `--print` are
   canonical). `LEGACY_VERB_REMOVAL = "v0.3.0"` in `cli/docs_command.rb` +
   `cli/skill_command.rb`; see § "Scheduled CLI deprecations" below.
2. **`type_specifier` plugin hook removed** — the deprecated alias drops; the
   `narrowing_facts` verb is the only spelling ([ADR-80](adr/80-narrowing-facts-rename.md),
   `plugin/base.rb`). The alias removal is also when ADR-80's carry-over — the
   internal reader `type_specifiers` and the `rigor plugins --capabilities` JSON
   `type_specifier_methods` key — is revisited (a distinct rename decision).
3. **`parallel_tests` dependency dropped** — `binpacker` is the primary test
   runner (PR #27); remove the gem dep + the `test-parallel` / `spec_parallel`
   target.

Alongside the removals, **as much performance optimization as ships cleanly**:

1. **[ADR-46](adr/46-incremental-dependency-graph.md) incremental analysis** —
   the headline lever: per-file incremental via the cross-file dependency graph,
   soundness-gated by the mandatory `--verify-incremental` byte-identical
   cross-check (slice 1a landed off-by-default; maturing it toward
   default-capable is the perf headline).
2. **Other perf levers** (§ "Future cycles" → "other levers") — the O4 Layer 3
   `gem_rbs_collection` version-matching table, fork-based file parallelism, and
   a *scope-safe* run-scoped return memo (the naive cache is forbidden by
   [ADR-52](adr/52-compiled-plugin-contribution-dispatch.md) / [ADR-24](adr/24-self-method-call-resolution.md)
   WD5 on FP grounds, so it needs a design).

Removals must land with a `docs/compatibility.md` update and a `CHANGELOG.md`
migration note; recalibrate `bench/baseline.json` from CI-measured values as perf
work shifts allocations. The [ADR-50](adr/50-release-engineering-and-stability-strategy.md)
v1.0 hard freeze is still ahead — `0.3.0` is a normal `0.x` minor that clears the
deprecation backlog and banks perf, not the freeze.

### CLI deprecations — `docs` / `skill` verb subcommands → flags (REMOVED in v0.3.0)

`rigor docs` and `rigor skill` moved their discovery subcommands to
flags so the positional slot is unambiguously a doc / skill *name* (the
old `list` / `path` / `print` verbs shared that slot, able to shadow a
same-named page). Canonical forms now:

| Action | Canonical | Removed spelling (v0.3.0) |
| --- | --- | --- |
| docs index / list | `rigor docs` · `rigor docs --list [category]` | `rigor docs list` |
| docs path | `rigor docs --path <name>` | `rigor docs path <name>` |
| skill list | `rigor skill` · `rigor skill --list` | `rigor skill list` |
| skill print | `rigor skill <name>` · `rigor skill --print <name>` | `rigor skill print <name>` |
| skill path | `rigor skill --path <name>` | `rigor skill path <name>` |

`rigor docs` also gained category-qualified addressing
(`handbook/03-narrowing`) and now bundles the **handbook** alongside the
manual. `rigor skill describe` / `--describe` (and the top-level
`rigor describe`) are unchanged — `describe` is a no-argument action,
not a name-slot verb, so it is not deprecated.

The deprecated verb spellings warned on stderr through `0.2.x` and are
**removed in v0.3.0**: the positional slot is a name, so a removed verb
now resolves as an unknown doc / skill. The bundled generators and docs
only ever emitted the canonical forms, so the SKILL-driven UX is
unaffected by the removal. The flag vocabulary freezes
at v1.0 under [ADR-50](adr/50-release-engineering-and-stability-strategy.md)
WD1. Amends [ADR-74](adr/74-offline-doc-access-and-llms-txt.md) (docs
grammar + handbook bundling) and [ADR-73](adr/73-skill-driven-user-experience.md)
(skill grammar).

### Compatibility-safe strengthening backlog (0.2.x) — classified by BC risk

The [2026-06-22 compatibility-safe strengthening survey](notes/20260622-rigor-0.2.x-compatibility-safe-strengthening-survey.md)
catalogued where Rigor can get stronger during the `0.2.x` evaluation line
without violating the [`docs/compatibility.md`](compatibility.md) /
[ADR-50](adr/50-release-engineering-and-stability-strategy.md) discipline. The
survey's eleven opportunities + P0–P7 backlog are classified below by their
backwards-compatibility cost (the survey binds where this summary disagrees; it
chooses no implementation task and authorizes no version bump / baseline
migration / default severity promotion / commit). Several items **split** across
buckets — the precision-additive core is safe now, but a louder default or a new
discipline built on it is not.

**(1) No BC cost — implementable immediately** (Route A internal, or Route B
additive-default-off; the only gate is empirical false-positive risk, not a
formal API break):

- **Self-mutation / teeth batches** (survey §1, P1) — dev-only `tool/mutation/`, off the ADR-50 frozen surface; improves the analyzer's own oracle with zero public-surface change. Already a [Future cycles § Analyzer self-testing](#analyzer-self-testing--teeth-measurement--type-protection-coverage-adr-62--adr-63) track.
- **Deterministic builtin / stdlib precision — FP-safe folds** (survey §2, P3) — `MethodDispatcher.dispatch` folds on concrete receivers that reduce `Dynamic` without firing new diagnostics; decline folds routing through user-overridable `coerce`. (Folds that *widen a real diagnostic* are bucket 3.)
- **`Dynamic[T]` provenance labels** (survey §3, P2) — carry dynamic-origin cause facts internally, surface them additively through `coverage --protection` labels / `--format json` metadata; preserves `untyped = Dynamic[top]` relation semantics. The highest-value explanatory lever (turns a generic hole into a next action). (A strict-dynamic *policy* is bucket 2.)
- **Cache / incremental / perf** (survey §5) — non-contract internals; bump `Cache::Descriptor::SCHEMA_VERSION` / `Cache::Store::FORMAT_VERSION` (marker `4.2`) on any serialized-meaning change so stale entries *miss*, never mis-read; validate from deterministic allocation signals, not wall-time noise.
- **Configurable inference budgets, current-behavior defaults** (survey §6) — wire the spec [`budgets:`](type-specification/inference-budgets.md) table with defaults equal to today's hard-coded guards, exhaustion-as-explanation first (extend `RIGOR_BUDGET_TRACE`); name the new `.rigor.yml` keys deliberately (public vocabulary once documented), never leak internal fuel constants.
- **Additive CLI helpers** (survey §7, P5) — `rigor doctor` / `rigor upgrade` / `rigor skill describe --deep` reusing existing check/baseline/plugin evidence with no default-`check` change; design any JSON output as a stable contract from day one, keep deep probes opt-in. (`describe --deep` + coverage-tractability labels are already tracked under [SKILL-driven onboarding UX](#skill-driven-onboarding-ux-adr-73-landed-2026-06-20--deferred-follow-ups).)
- **Additive plugin precision** (survey §8, P6) — bundled-plugin recognizers, `config_schema` defaults, *optional* hooks; new recognizers must not turn positive recognition trace into default errors. (New public plugin *services* are bucket 2; required-hook changes are bucket 4.)
- **Structured diagnostic metadata** (survey §9) — more `evidence_tier`-shaped additive JSON fields (omit-when-nil, per `rule_catalog.rb`) so agents/CI branch on data not `message` prose; each new field ships with frozen documented semantics, never a presentation mirror.
- **Off / info-first new rules** (survey §10) — a new diagnostic shipping `:off` / `:info` with a stable id (`CheckRules::ALL_RULES`, aliases preserved) changes no default run; promote only after external-corpus FP sweeps. (A rule imposing a new *authoring discipline* is bucket 2.)

**(2) BC-bearing but shippable behind a `bleeding_edge:` card** (a new authoring
expectation, off by default, user `severity_overrides:` still winning; the
overlay `BleedingEdge::FEATURES` is empty today):

- **First `BleedingEdge::FEATURES` entry** (survey §11, P7) — a single data row behind the wired overlay; reserve it for a genuine next-major discipline with a stable id + migration note, never a dumping ground for ordinary precision fixes. Sets the style for every future feature id.
- **Strict-dynamic discipline** (survey §3 tail) — any policy that *fails* previously-clean code for an unexplained `Dynamic` value, built on the bucket-1 provenance facts.
- **New-discipline rules** (survey §10 tail) — a diagnostic that makes idiomatic Ruby fail by demanding a different authoring style ships via `bleeding_edge:`, not a silent default promotion.
- **New public plugin-service / read-side additions** (survey §8) — additive but a contract expansion: ships with matching RBS + an intentional `public_api_drift_spec.rb` update, designed against the v1.0 freeze.

**(3) BC-bearing, large semantic / engine work — separate-branch prep**
(needs an external-corpus false-positive sweep before it is trustworthy; `make
verify` alone is insufficient — P0):

- **Default-widening receiver-typing / nilability / flow / override diagnostics** (survey P0) — the precision exists internally, but promoting it into the default profile requires the Rails / ActiveSupport / DSL / monkey-patch / RBS-gap corpus sweep that Rigor's own code can't supply.
- **Precision folds that widen a real diagnostic** (survey §2 tail) — a sharper fold that flips a `Dynamic` receiver concrete can then fire `always-truthy` / possible-nil / undefined-method on working code (the liquid StringScanner / `||`-`&&` edge-narrowing precedents); gate on a corpus diff.
- **`freeze` / `dup` shape-carrier preservation** (survey §4 tail) — deferred until the known reflexive `always-truthy` interaction is resolved; conservative invalidation (the rest of §4) is bucket 1.
- **Baseline-format migration** (survey "artifact format" + Non-goals) — more user-visible than a cache bump; `Analysis::Baseline::CURRENT_VERSION` raises on mismatch by design, so a format change is public-surface work needing a migration path and guidance, on its own branch.

**(4) Forbidden under the compat discipline / not realistically doable in a
minor** (major-version-only; the survey's "compatibility traps to avoid"):

- **Incompatible `rigor:v1:` annotation grammar / semantics** — introduce a *new* version prefix; never reinterpret `v1:` meanings.
- **Changing `untyped = Dynamic[top]` semantics** — a relation-contract change; the §3 provenance work is explicitly required to preserve it.
- **Renaming a diagnostic id without a legacy alias** — a rename *plus* a `LEGACY_RULE_ALIASES` entry is compatible; the alias-less rename is the trap.
- **Making a plugin hook mandatory in a minor** — only optional hooks are additive; a required-hook change invalidates existing manifests.
- **Silently mis-reading a changed artifact schema** — schema changes must invalidate (raise / miss), never reinterpret stale bytes as the current format.

## Future cycles (not committed to a specific release)

Items that have surfaced across v0.1.x work and that the next implementer benefits from seeing without re-reading the full thread.

### Plugin contract — interface segregation + ergonomics (ADR-37/38/39/40) — SHIPPED v0.1.16

The pre-1.0 plugin-mechanism review ([`docs/design/20260601-plugin-mechanism-pre-1.0-review.md`](design/20260601-plugin-mechanism-pre-1.0-review.md)) drove a large interface-segregation effort — an AI-legible, per-interface-testable plugin contract where the engine owns the AST walk and gates each narrow extension declaratively (PHPStan-style), with the old fat hooks kept as deprecated escape valves. **It shipped in v0.1.16:** ADR-37/38/39/40 are Accepted, all 14 bundled walker plugins are migrated onto `node_rule`, and the boilerplate-reduction author-helper layer landed. Full detail in `CHANGELOG.md` § `[0.1.16]`; phased plan in [`docs/design/20260602-plugin-boilerplate-reduction-plan.md`](design/20260602-plugin-boilerplate-reduction-plan.md).

**Remaining (all non-gating, demand-driven ergonomics; each its own behaviour-preserving slice — verify each before landing):**

1. **`dynamic_return` generalisation** (optional `methods:` gate / dynamic-receiver predicate) — the path to migrating the escape-valve consumers (rspec `let`-binding, sorbet, activerecord, activestorage) off `flow_contribution_for`. The fat hook is the supported deprecated valve and those consumers work unchanged; this only widens the narrow surface.
2. **[ADR-38](adr/38-additional-initializers.md) block-form** `additional_initializers` (rspec `before`/`let` whose ivar writes live in a call block, not a `DefNode`) — needs the ivar write-collector to descend declared call blocks.
3. **Per-interface test harnesses** (`NodeRuleTest` / `DynamicReturnTest`) — deferred until a plugin author needs them.
4. **[ADR-39](adr/39-plugin-target-library-invocation.md) follow-ons** — slice 3 (static ingestion of `config/initializers/inflections.rb` for project-custom inflections; the default AS ruleset covers the common cases), maximal-fidelity exact-gem-version loading (a `process`/`ruby_box` worker pinned to the target's `Gemfile.lock`), routing the `rigor-rspec-rails` Rack catalogue through `Isolation`, and `ruby_box` re-enable once the upstream `Ruby::Box` VM segfault is fixed.
5. **`Source::Literals` adoption tail** — the assoc-key *name-match* idiom (`el.key.is_a?(SymbolNode) && el.key.unescaped == "x"`) is a key comparison, not a value extraction, so it sits outside the four-helper grid; a dedicated `symbol_named?(node, name)` helper could absorb it but is its own slice.

The escape-valve consumers (sorbet / activerecord / activestorage / rspec-let), the dry-rb/graphql pure-FactProvider plugins (nothing to migrate), and hanami/web (ADR-28 ProtocolContractChecker — a separate common-base axis) are **out of scope of the node_rule/Slice-2 migration** and stay as they are.

### Type-language / engine
- **Narrowing-driven clause reachability (ADR-47) — WD1 + WD2 + WD3a landed + WD4 swept (v0.1.17); WD3b remaining.** A new `flow.unreachable-clause` diagnostic for dead `case`/`when` clauses, inspired by Elixir v1.20's redundant-clause reporting (review note: [`docs/notes/20260604-elixir-v1.20-type-system-rigor-review.md`](notes/20260604-elixir-v1.20-type-system-rigor-review.md) § 4-2). The third member of the `if`/`unless` reachability family (`flow.unreachable-branch` literal-only + `flow.always-truthy-condition` inferred-constant), extended to `case` — which the engine already narrows: `eval_case_when_branches` threads a `falsey_scope` across `when` branches via `Narrowing.case_when_scopes`, so a clause is unreachable exactly when its computed `body_scope` narrows the subject to `bot` (per-clause disjointness) or its entry `falsey_scope` already carries a `bot` subject (prior-exhaustion) — the same disjointness signal Elixir's `dynamic()` *compatibility* test uses, in carrier algebra Rigor already has. **WD1 + WD2 landed** (`UnreachableClauseCollector` + `RULE_UNREACHABLE_CLAUSE`): `when String` / `when MyClass` over a `case <local>` whose narrowed subject is `Type::Bot`, reading the engine's own per-clause `body_scope` from `scope_index` (no divergence); FP envelope enforced (subject must narrow, never `Dynamic`/already-`Bot`, class/module-constant `when` only, skip loops/blocks); clean on Rigor's own `lib`/`plugins`/`examples`; ships `:info` in lenient/balanced and `:warning` in strict. WD2 added prior-exhaustion-vs-disjoint message precision (told apart by the entry `falsey_scope` the engine records on each clause's first condition node) and a dead-trailing-`else` check that exempts defensive `raise`/`fail`/`throw` guards. WD3a extended the rule to `case`/`in` for bare class patterns only (`in C` / `in C => x`, pure `is_a?`, narrowed soundly like `when C` via `Narrowing.case_when_scopes`); deconstructing/value/variable patterns stay conservative. WD4 swept 16 OSS corpora ([note](notes/20260605-adr47-unreachable-clause-corpus-sweep.md)) — zero firings, zero FP; a vacuous pass is not evidence for a louder default, so balanced stays `:info` (strict `:warning`), promotion waits for a real firing. **Remaining:** WD3b (deconstructing / value / variable-catch-all pattern exhaustiveness, the deferred [ADR-36](adr/36-mangrove-enum-nested-class-emission.md) `is_a?` neighbour — do NOT infer ad hoc; priority lowered by the zero-firing sweep). Reuses `flow.always-truthy-condition`'s false-positive envelope verbatim and collects at evaluation time so the rule and body-typing read identical narrowing. Soundness-via-strong-arrows recorded for contrast, not adopted (Rigor stays deliberately unsound under [ADR-5](adr/5-robustness-principle.md)). See [ADR-47](adr/47-narrowing-driven-clause-reachability.md).
- **Elixir-inspired narrowing extensions (from the v1.20 review note § 4) — LANDED (v0.1.17).** Two control-flow narrowing additions spun from [`…-elixir-v1.20-type-system-rigor-review.md`](notes/20260604-elixir-v1.20-type-system-rigor-review.md): (a) § 4-3 **Hash key-presence** (`is_map_key` analogue) — a `h.key?(:foo)` / `has_key?` guard (literal key) refines an optional hash-shape key to present on the true branch, so `h[:foo]` reads `T` not `T | nil`, and **drops the key on the false branch** (§ 4-3 false-edge key-*absence*, landed 2026-06-05) so `h[:foo]` reads `nil` when the key is proven absent — a required key leaves the false edge opaque (dead), an unknown key is already nil (`Narrowing#{analyse_key_presence_predicate,narrow_hash_key_absent,remove_hash_key}`); (b) § 4-4 **Array non-empty** (`tuple_size` analogue) — a bare `arr.empty?` (false edge) / `any?` (true edge) / `none?` (false edge) refines `Array[T]` → `non-empty-array[T]`, so `arr.size`/`length`/`count` read `positive-int` (`Narrowing#analyse_array_emptiness_predicate`, reusing the existing `non-empty-array` refinement + empty-removal projection). Both narrow only concrete shapes (never `Dynamic`), are FP-safe (narrowing-only, no new diagnostics), and were verified via `dump.type` round-trips. **Remaining (demand-driven):** § 4-4 upper-bound length tracking (`tuple_size(x) < 3`, needs a length-range carrier); § 4-5 post-guard `Dynamic`→`C` strengthening was assessed FP-risky (undefined-method in guarded bodies vs the gradual guarantee) and **not adopted**.
- **O2 — macro-template / heredoc-Ruby expansion (ADR-16).** Remaining demand-driven items: **slice 5b** (Tier D engine integration — narrows top-level `self_type` and pre-binds `bound_ivars` for matched external files) and **full ADR-13 resolver-chain wiring** for the synthetic-method tier (routes parameterised forms `Array[String]` / `Hash[K, V]` and plugin-supplied utility-type names through the resolver chain). Grounding survey at [`docs/notes/20260515-macro-expansion-library-survey.md`](notes/20260515-macro-expansion-library-survey.md).
- **Lightweight HKT (ADR-20).** Core carrier + parser + conditional grammar + major `METHOD_RETURN_OVERRIDES` (`JSON.parse`, `YAML`, `Psych`, `CSV`) all landed; handbook chapter 12 shipped. Remaining (demand-driven): Slice 4 (`dry-monads` `Result[T, E]` / `Maybe[T]`, needs ADR-3 amendment), Slice 5 (sugar `type` alias), pattern-binding extraction in `rigor-lisp-eval`, additional `METHOD_RETURN_OVERRIDES`. See [ADR-20](adr/20-lightweight-hkt.md).
- **`rigor:v1:conforms-to` directive — LANDED (v0.1.17).** The class- / module-level explicit-conformance directive ([rbs-extended.md](type-specification/rbs-extended.md) § "Explicit conformance directive"): a declaration in `signature_paths:` RBS asserts it satisfies a named structural interface as a checked design assertion, verified independent of any call site. Checks two conservative tiers — **presence** (definitively-absent required methods) and **signature compatibility** (covariant return / contravariant params on provided methods, FP-safe because both interface and class are authored RBS, the ADR-35 both-sides-authored construction; single-method-type only, `Dynamic[Top]` positions skipped) — both surfacing `rbs_extended.unsatisfied-conformance` (`:warning` / `:error` under strict); an unresolvable interface name degrades to `dynamic.rbs-extended.unresolved` `:info`. Interface names resolve relative to the declaring class's namespace (Ruby constant-lookup style: `conforms-to _Foo` inside `Bar::Baz` tries `Bar::Baz::_Foo` / `Bar::_Foo` / `_Foo`). **Remaining (demand-driven):** arity / keyword-requiredness divergence in the signature check (positional-type comparison only, mirroring ADR-35 WD4).
- **LRU eviction for `Cache::Store`.** Per [ADR-6](adr/6-cache-persistence-backend.md), the persistent cache is sharded "no eviction" by design. Long-lived clones with config / dependency churn accumulate stale slots that only `make cache-clean` releases. LRU is queued, not committed.
- **Project-side monkey-patch pre-evaluation (ADR-17).** `pre_eval:` config is live. Remaining demand-driven follow-ups: slice 3b (per-file cache descriptor), slice 5 (full-project 2-pass discovery), slice 6 (plugin-API hook).
- **Override signature compatibility (ADR-35) — slices 1–4 LANDED.** The `def.override-*` rule family enforcing the Liskov signature rule across an authored class/module hierarchy: `def.override-visibility-reduced` (visibility public → protected/private), `def.override-return-widened` (return covariance), `def.override-param-narrowed` (parameter contravariance). Each fires only on a proven (`:no`) violation, gated to both-sides-authored signatures (the visibility rule: both-sides-*observable* — visibility is source-expressed independent of RBS) and mapped through `severity_profile:` (`lenient → off`, `balanced → :warning`, `strict → :error`; additive, lenient projects unaffected). Slice 4 (Mastodon-corpus FP verification) found and fixed a cross-file-visibility false-positive cluster (160 → 35; residual are true reductions surfaced only under `strict`) and kept the conservative mapping — write-up at [`docs/notes/20260529-adr35-mastodon-fp-verification.md`](notes/20260529-adr35-mastodon-fp-verification.md). **Remaining (demand-driven, implementation timing undetermined):** **slice 5** (parent-authored + child-*inferred* covariance — check a child's inferred return against an authored parent return; higher value, higher FP, gated on inferred-return precision); the WD9 tier-1 generic-instantiation-aware comparison (a *precision* uplift, not an FP-safety requirement — unbound generics already degrade to `Dynamic[Top]`); RBS-only-ancestor reach for the type rules; and singleton (`def self.`) method coverage. See [ADR-35](adr/35-override-signature-compatibility.md).
- **ADR-13 resolver-chain wiring for the synthetic-method tier (ADR-16 follow-up).** ADR-13's `Plugin::TypeNodeResolver` chain is wired for `%a{rigor:v1:…}` payloads but NOT for substrate manifest `returns:` strings. Routing the synthetic-method tier through the chain unlocks utility-type-shaped Tier C returns (`Array[String]`, `Hash[K, V]`, `Pick<T, K>`). Deferred to demand from utility-type-shaped substrate consumers. (Note: per-call-site return-type lookup via cross-plugin facts shipped in v0.1.6 via [ADR-18](adr/18-substrate-per-call-site-return-type.md); the ADR-13 wiring above is the orthogonal "parameterised-form parser" extension.)
- **Struct / Data value folding — `Data.define` LANDED ([ADR-48](adr/48-data-struct-value-folding.md), slices 1–4, v0.1.17).** Precise member-access folding (`Point = Data.define(:x, :y); Point.new(1, 2).x` → `Constant[1]`) needs **two new carriers** — a member-class carrier (`Type::DataClass`, ordered member-name list) and a class-tagged member-instance carrier (`Type::DataInstance`, HashShape-shaped but nominal) — plus a `DataFolding` dispatch tier and a cross-file `Scope#data_member_layouts` side-table the scope indexer populates. Shipped for all three definition forms (constant-assigned / `class X < Data.define(...)` subclass / bare local), both positional + keyword construction, and the `to_h`/`deconstruct`/`deconstruct_keys`/`members`/`with` projections; precision-additive only (degrades to the class nominal on a block / non-literal members / arity mismatch — no diagnostic, no FP surface). Grounding audit: [`docs/notes/20260523-struct-encoding-coverage.md`](notes/20260523-struct-encoding-coverage.md). **Remaining (demand-driven):** bare-local block-form parity (`c = Data.define(:x) do … end` — no resolvable class name for the slice-4 reader-redefinition guard, conservative bail) and the **`Struct` follow-up** — its own slice with the mutation-soundness story (a `Struct` instance is mutable: setters / `[]=` invalidate the member map; the side-table records `Data.define` only, deliberately excluding `Struct.new`). `Encoding` value folding is recorded in the same audit as a *permanent exclusion* — a `Constant[Encoding]` carrier could only fold a vanishingly small surface (`.name` / `.dummy?`), real programs use `Encoding` as an opaque tag, and the carrier-zoo cost is not repaid; `Nominal[Encoding]` stays the answer.
- **Coverage-aware diagnostic posture (future concept — not yet designed).** Idea: modulate diagnostic *posture* by spec / test coverage — analyse optimistically where code is exercised by tests, stay conservative (or escalate attention) where it is not. This would operationalise the [`overview.md`](type-specification/overview.md) § "False-positive discipline" value (a running, test-covered program is evidence of its own correctness) by making "working" machine-readable and *localised*: a coverage map becomes a new fact source that modulates diagnostic severity post-inference, near `severity_profile` in the WD6 pipeline — type inference itself unchanged. Distinct from the former Pillar 2 track (<del>specs → type facts</del> <ins>spec-body narrowing only — assertions never feed implementation signatures, per [ADR-59](adr/59-spec-assertions-are-not-signatures.md)</ins>); this is coverage → confidence. **Concerns to resolve before this is designable:** (1) *coverage ≠ correctness* — "executed" is not "the type-relevant edge case was exercised and asserted", so an optimistic posture on covered code can suppress a real bug that a test runs but never asserts on; line coverage is especially weak, branch coverage better but still partial. (2) The two halves are **asymmetric in risk** — "uncovered → escalate" only re-prioritises and suppresses nothing (safe, pure upside), while "covered → suppress" carries the false-reassurance risk; a first slice should likely be the uncovered half only. (3) The coverage artefact (SimpleCov `.resultset.json` / the `Coverage` stdlib module) is an external fact source needing provenance + staleness handling, fail-soft when absent or stale. (4) Possible synergy with the [ADR-22](adr/22-baseline-and-project-onboarding.md) baseline — coverage could rank which baseline buckets are "untested, therefore review-worthy first". No ADR, no slice, no committed milestone — recorded here as a direction.

### Analyzer self-testing — teeth measurement + type-protection coverage (ADR-62 / ADR-63)

The dual of the false-positive discipline: systematically measuring **false negatives** (does breaking the code make Rigor bite) and surfacing that to users. Grounding: [`docs/notes/20260613-mutation-teeth-harness.md`](notes/20260613-mutation-teeth-harness.md).

- **[ADR-62](adr/62-mutation-testing-teeth-measurement.md) mutation-teeth harness — LANDED (dev-only, off the ADR-50 frozen surface).** `tool/mutation/` injects type-visible mutations and reads *surviving* mutants as false-negative candidates; the in-process type-aware filter makes the metric meaningful (raw kill-rate is noise — most mutations are correct equivalent mutants); `mutate.rb sweep` clusters survivors by `(operator, receiver type)` into a ranked backlog (`--json` for an agent), `mutate.rb fuzz` is the robustness sibling (crash / hang / non-determinism — a 2,706-mutant `lib/rigor` run was clean). **Three engine teeth fixes landed from it:** union-receiver undefined-method (fires when every non-nil arm is certainly absent, with generic-metaclass + distinct-class FP guards harvested from the nilable study), RBS class-alias resolution (`Mutex = Thread::Mutex` and any `X = Y`), and refinement-receiver dispatch (`non-negative-int` / `non-empty-string` now resolve to their base class). A cumulative re-sweep moved `lib/rigor` teeth 61.7 % → 71.4 %, survivors −29 %. **Studied + rejected:** nilable-union teeth — a 13-project corpus FP study (ActiveSupport-heavy + plain) found ~zero firings plus a real loss-of-specificity FP, so the deliberate N3 `T | nil` silence is kept. **Demand-gated:** `Type::*` self-dogfood RBS (the residual top cluster is the ADR-24 `call.self-undefined-method` rule, which ships `:off`), broad-fuzz expansion, an `arity_extra` fixed-arity guard.
- **[ADR-63](adr/63-type-protection-coverage.md) type-protection coverage — Tier 1 + Tier 2 LANDED.** `rigor coverage --protection` (Tier 1, the static proxy): one `type_of` pass scoring each dispatch site by whether its receiver types to a concrete class ("can Rigor catch a wrong call here"), reported as a protected ratio + a ranked "add a type here" list (the methods most often called on an untyped receiver) + the least-protected files, reusing the existing `--threshold` gate and `--format json`. A sound upper bound on real protection. **Tier 2 (mutation-based effectiveness) LANDED 2026-06-14:** `rigor coverage --protection --mutation`, a per-file *actual* kill rate, opt-in and git-changed-files-scoped (explicit paths widen). It productizes a narrow subset of the ADR-62 harness into `lib/rigor/protection/` (`Mutator` + `MutationScanner` — the warm loop + type-aware filter + kill criterion); the dev sweep / fuzz / clustering stay dev-only per ADR-62 WD4 (a scoped refinement, not a reversal) and `tool/mutation/mutate.rb` reuses the lib `Mutator`. `--threshold` gates on the effectiveness ratio; `--format json` carries `{mode, killed, survived, effectiveness_ratio, files, add_a_type_here}`. Framing rule (load-bearing, ADR-62 Criterion A): always effectiveness / where-to-add-a-type, never raw mutation survival. **Demand-gated:** an optional per-file mutation cap (the scanner already accepts a seeded `limit:`), and an ADR-46-incremental-backed cheaper whole-project run.
- **Self-mutation testing of `lib/rigor` itself (Product C) — harness LANDED (dev-only, off the frozen surface); cold-method backlog drained.** Turns the ADR-62/69/70 machinery *inward*: mutate Rigor's own implementation and kill with either the self-check (type axis, the `DiagnosticOracle`) or Rigor's own RSpec suite (test axis, the `TestSuiteOracle`); a survivor of both is an implementation hole. `tool/mutation/self_mutate.rb` is a thin driver over `Protection::{MutationScanner,TestSuiteOracle}` adding only the Product-C-specific pieces — an **in-bundle** test runner (the shipped oracle strips Bundler's env, right for a *foreign* Gemfile, wrong for Rigor's own suite), convention spec selection, disk-restore safety, and a `--coverage-gap` whole-tree mode that classifies type-survivors against a one-shot suite line-coverage index (`spec_helper`'s opt-in `COVERAGE_JSON` dump) so the cheap high-confidence tier needs **zero** rspec runs. Grounding + living tracker: [`docs/notes/20260618-self-mutation-testing-plan.md`](notes/20260618-self-mutation-testing-plan.md). **Methodology lesson (load-bearing):** the coverage-gap count must be de-noised by **method coldness** — Ruby line-coverage credits a multi-line expression to its first line, so a bare "line ∉ covered set" check false-flags the continuation lines of covered expressions; a hole counts only inside an *entirely-uncovered `def`*, and class-body/constant sites are excluded (data, not logic). That funnel took the raw whole-tree count 1969 → 214 → 22. **Outcome:** all 310 `lib/rigor` files swept — the only cold-method holes were `cli/mcp_command` and `trinary` (both closed); **the unit suite is method-level complete**. The remaining `needs-verification` tier (type-survivors on *covered* lines — covered ≠ asserted) is worked **per file** via the fused mode (most survivors are equivalent mutants — message/inspect text — or covered-by-a-broader-spec). **2026-06-21: the effectiveness sweep matured into a mechanical, repeatable workflow** — batch ~8 candidate files (60–300 LOC, with a spec, not yet measured) → read the survivor list → adjudicate genuine-vs-floor → write targeted tests (private helpers via `.send`) → re-run the harness per file → commit spec-only (rspec + rubocop suffice; `make check`/`check-plugins` analyse `lib`/`plugins`, not `spec`). **~28 files** closed to their equivalent-mutant floor across seven batches (the scanners, the HKT cluster, the LSP providers, `mcp/server`, the dependency-source-inference and CLI-command files, …); the **per-batch record + kill-technique catalogue** lives in the living tracker. **Two operating policies (load-bearing):** (1) the harness's test axis runs ONLY the convention-mapped *unit* spec, never integration/CLI-dispatcher specs, so `cli/*_command` orchestration reports large counts that are predominantly *integration-blindness* — triage against the dispatcher specs and add a unit test only for a command's untested *default* mode, not its message/help tail; (2) never run the fused harness concurrently with `make verify` (or another harness invocation) — each does a cold env+scan and they starve each other. **Six reusable killing techniques** are recorded for the next implementer: absent-key tests for `fetch(_, default)` defaults; path-specific message text to separate two paths sharing a structured field; exact-`eq` (not `include`) on a built array/argv to pin each element source; line-count (not substring) for a `join("\n")` whose nil-separator mutant still concatenates; multibyte fixtures to bite `bytesize`-vs-length; `.send` for private helpers. **Demand-gated / next:** continue batching the ~50 still-unmeasured 60–300 LOC files, then the >300 LOC engine tier; `overload_selector`'s 2 all-block-overload residuals (need a fabricated method-type); semantic operators (the current set is runnable but diagnostic-shaped); a `{line → specs}` per-spec index to replace convention selection; an independent (mise / clean-HEAD) subprocess type oracle for the broad-fuzz/robustness variant; a diff-scoped advisory CI job (ADR-71's incremental wedge, justified on Rigor's own repo).

### Plugins / ecosystem

Governance: [ADR-31](adr/31-contribution-and-supply-chain-policy.md) is the project-wide contribution and supply-chain policy. It organises contribution by **change magnitude**: minor focused changes (bug fixes, doc improvements, typo fixes, scoped refactors, tests, bug fixes to existing bundled plugins) are welcomed as direct PRs against any path; sweeping changes (architectural rewrites, code-style sweeps, new analyser features, new bundled plugins, ADR / spec retractions) go through issue-first proposal with `Co-authored-by:` attribution on the team-authored implementation. Plugin-specific worked paths under WD2–WD5: (1) **third-party `rigor-<gem>` gem** in the author's own repo depending on `gem "rigortype"` (ADR-31 WD4 — Larger Work under [MPL §3.3](../LICENSE), fully supported, default expectation); (2) **promotion-for-bundling via issue** with `Co-authored-by:` attribution when the wrapped gem reaches community-recognition (ADR-31 WD2, criterion intentionally vague per WD3); engine / spec / refactor proposals follow the same WD2 issue-driven shape minus the WD3 adoption-evidence requirement. Subtree merge of a proven third-party plugin is reserved as an optional path (ADR-31 WD5) — not a path third-party authors should plan around.

- **`rigor-graphql`** — Future slices (demand-driven): resolver-method type-check, `<Type>.array` / `<Type>!` chain forms, string-form `field :foo, "User"` diagnostic, `Schema.execute(...)` result typing.
- **dry-rb adapter plugins ([ADR-12](adr/12-dry-rb-packaging.md)).** **Remaining**: `rigor-dry-schema` slice 2+ surface beyond `each` (typed `result.to_h` synthesis via ADR-16 Tier C / per-row diagnostics; demand-driven), `rigor-dry-validation` slice 2 (params-block typing via `:dry_schema_table` consumption) + slice 3 (`json { ... }` parity); `rigor-dry-monads` (still needs `Result[T, E]` / `Maybe[T]` carrier decision — see slicing plan). Foundation survey under [`docs/design/20260509-dry-plugins-roadmap.md`](design/20260509-dry-plugins-roadmap.md).
- **ADR-10 — per-call return-type precision from gem source.** Walker currently catalogs only `(class_name, method_name) → kind` triples. Inferring per-method return types from gem source (so `mode: :full` could contribute richer than `Dynamic[Top]`) is a larger walker enhancement deferred until concrete user demand surfaces.
- **Plugin-contributed RBS signatures.** [ADR-25](adr/25-plugin-contributed-rbs.md) proposed (2026-05-21): an optional `signature_paths:` `Manifest` field lets a plugin gem contribute RBS directories, resolved by `Plugin::Loader` and merged into the RBS environment. Closes the gap that today forces an RBS-only bundle gem (`rigor-activesupport-core-ext`) to be hand-wired via a non-portable `signature_paths:` path. Three slices (manifest field + loader resolution + environment merge → convert `rigor-activesupport-core-ext` to a trivial plugin → `rigor-project-init` SKILL follow-through); additive to the pre-1.0 plugin contract, safe within v0.1.x. Companion follow-up (separate, smaller): extend `Environment::BundleSigDiscovery` auto-detection beyond the `vendor/bundle` / `.bundle/config` layouts to the default `bundle install` gem path.
- **ADR-28 path-scoped protocol contracts — open ecosystem item.** `rigor-actioncable` `#receive(data)` parameter-type provision: a contract with `method_name: :receive, param_types: [{index: 0, type_name: "Hash"}]` would type `data` as `Hash` inside every channel's receive body. Demand-driven.
- **Inline-RBS comment ingestion ([ADR-32](adr/32-rbs-inline-comment-ingestion.md)) — LANDED.** All three slices + the WD10 CLI carry-over shipped in the v0.1.x cycle: slice 1 (engine hook + bundled `rigor-rbs-inline` plugin) + slice 2 (per-file cache keyed on `(content SHA, plugin id + version + config_hash)` + env-cache invalidation + `source-rbs-synthesis-failed` info diagnostic via the new `Plugin::SourceRbsSynthesisReporter`) + slice 3 (plugin README + handbook chapter 7 § "Inline RBS in Ruby source") + the `rigor check --treat-all-as-inline-rbs` CLI flag for single-file ad-hoc CI use. WD9 top-level-`def` caveat verified against rbs-inline 0.14.0 (no output for bare top-level defs; class-wrap to engage). Remaining demand-driven follow-ups: LSP incremental flow integration around the new `source_rbs_synthesizer:` hook (queued under the ADR-19 LSP roadmap). See `CHANGELOG.md` § `[0.1.10]` for the full list of public-API drift surfaces.
- **`rigor-ffi` plugin family ([ADR-30](adr/30-rigor-ffi-plugin-shape.md)).** Core `rigor-ffi` covers the `ffi` gem's common machinery (`extend FFI::Library`, `attach_function`, `callback`, `typedef`, `enum`, `bitmask`, `FFI::Struct`/`Union`/`AutoPointer`/`MemoryPointer`/`Pointer`/`Function`/`Buffer`) and — because tenderlove's `ffx` gem ships a strict subset of the same DSL — also serves ffx-targeted projects for free, plus a new `ffx.unsupported-*` diagnostic family that surfaces declarations ffx will refuse at gem-install time. Per-library sub-plugins (`rigor-rbnacl`, `rigor-ethon`, `rigor-ffi-rzmq`, `rigor-sassc`) contribute DSL recognizers, option-catalog → setter generation, and high-level API RBS refinements. WD9: implementation justified by zero non-user overhead (sub-plugins activate only on resolved-dependency match) rather than direct demand, which is weak across all four worked consumers (sassc-ruby is EOL, typhoeus/ethon and rbnacl are specialized, ffi-rzmq is niche). WD10: for a "vanilla" FFI gem (literal `attach_function` + thin Ruby wrapper class) core suffices and no plugin is needed — just declare the dependency. A new SKILL [`.claude/skills/rigor-ffi-plugin-author/SKILL.md`](../.claude/skills/rigor-ffi-plugin-author/SKILL.md) walks authors through a coverage assessment first (designed to *talk users out of authoring* when core suffices) and then routes the remaining cases through the project-wide [ADR-31](adr/31-contribution-and-supply-chain-policy.md) contribution policy. FFI-specific add: pin the wrapped gem's version range in the plugin's gemspec (orphan-plugin risk is the plugin author's responsibility per ADR-31 WD4). Six slices sketched: core MVP → `rigor-sassc` (experience-building) → `rigor-ethon` → `rigor-rbnacl` + the `Plugin::FFI::BindingRecognizer` extension point → ffx target detection + diagnostics → `rigor-ffi-rzmq` (gated on ADR-10 per-call return-type precision). Grounding survey: [`docs/notes/20260525-ffi-library-survey.md`](notes/20260525-ffi-library-survey.md). Sibling `rigor-fiddle` plugin (Fiddle's DSL diverges enough to warrant separate authoring) is explicitly out of scope of ADR-30. No slice scheduled.

### Editor / IDE integration
- **LSP — Ractor pool for parallel multi-buffer publishes.** Slice 8 in the LSP design doc enumerated TWO concerns: debouncing (landed) AND Ractor pool integration. The pool half stays demand-driven — requires refactoring `Analysis::Runner` to accept a pre-built persistent `Environment` so workers can be pre-warmed once at LSP `initialize` and reused across publishes. ProjectContext (slice 7) already gives publish + hover the warm-Environment win via the read-only `Cache::Store`; the dispatch-side parallelism (multi-buffer publish across cores) is the remaining lever. Demand-driven.
- **LSP — `textDocument/definition`** (slice 9 in the design doc, deferred). Needs a `Reflection`-side symbol index keyed on `FILE:LINE`. Demand-driven.
- **LSP — incremental `didChange` sync** (slice 10 in the design doc, deferred). Currently the server advertises `TextDocumentSyncKind::Full = 1` so each keystroke resends the whole buffer. Incremental (`TextDocumentSyncKind::Incremental = 2`) requires UTF-16 offset bookkeeping + per-edit application. Bandwidth is local stdio so the cost is in the parse, not the wire; demand-driven.
- **LSP — extended capabilities still queued** (post-v2 + post-follow-ups + post-polish): `textDocument/codeAction`, `textDocument/rename`, `textDocument/semanticTokens`, `textDocument/inlayHint`, `textDocument/definition` (slice 9 from LSP v1 design — needs Reflection symbol index), incremental `didChange` sync (slice 10 from LSP v1 design — UTF-16 offset bookkeeping), Ractor pool dispatch for parallel multi-buffer publishes (slice 8 second half from LSP v1 design — Runner refactor), multi-root workspaces, TCP / Unix-socket transport, snippet expansion, bare-name (implicit-self) completion, symbol completion, `ParameterInformation` offset-tuple labels for in-signature highlighting, `completionItem/resolve` deferred-payload, plugin-side completion contributions.
- **Editor mode option B — per-file diagnostic cache.** Today's editor mode ships option A (single-file scope): only the buffer produces per-file diagnostics. Upgrading to option B (PHPStan-shape: whole-project analysis with one substituted file, "only edited file + dependents reanalysed") needs a per-file diagnostic cache keyed on `(file digest, project Environment digest)` — **this is exactly the ADR-46 incremental track** (`dependents` index + per-file cache + `--verify-incremental`); option B becomes the editor-side consumer of it once ADR-46 slice 2 lands. ADR-45's `Cache::Store#fetch_or_validate` is the record-and-validate primitive; ADR-17 slice 3b's per-file cache descriptor is the older lever. Design: [`docs/design/20260516-editor-mode.md`](design/20260516-editor-mode.md) § "Scope choice". Demand-driven.
- **CLI editor mode — disk-backed `ProjectScan` snapshot cache.** Implementation pathway documented in [`docs/design/20260518-cli-disk-snapshot-cache.md`](design/20260518-cli-disk-snapshot-cache.md). Targets `rigor check --tmp-file=X --instead-of=Y` shell-out path: persists the project's pre-pass outputs (scanners + dep-source index + plugin-published facts) to `.rigor/cache/` keyed on `(config + plugin manifest + project file mtime+size + pre_eval mtime+size)` so warm CLI invocations skip pre-passes. Expected wins: -200ms (small project) to >-1.3s (large monorepo with substrate plugins) per CLI call. New invariants: `Plugin::FactStore` snapshot API, plugin-fact Marshal-friendliness. Five phases (Marshalable scan / key derivation / cache producer / Runner integration / FactStore snapshot API). Demand-driven; the LSP path already covers most editor cases at ≤5ms / publish, so this slice picks up when a concrete CLI shell-out editor extension reports the ~1s wall as a UX problem.
- **Editor mode — project-context snapshot cache for pre-pass reuse.** LANDED for the LSP path (v0.1.6, CHANGELOG § `[0.1.6]` § Added). New `Rigor::Analysis::ProjectScan` value object + `Runner#prepare_project_scan` builder + `Runner.new(prebuilt:)` adoption path; the LSP's `ProjectContext` lazy-builds the snapshot and drops it on `invalidate!`. CLI editor mode (`rigor check --tmp-file`) does NOT yet consume the snapshot because each invocation is a fresh process — a disk-backed snapshot cache keyed on `(plugin-manifest digest, project file mtime + size list)` would let one-shot CLI invocations skip the pre-passes too. Demand-driven; the LSP-side win is the typical editor consumer.
- **Editor mode — `--also=path,path` caller-declared dependents.** Editor extension currently has to issue N single-file invocations to refresh dependents. A single invocation with `--also` would batch them. Trivial CLI extension; design notes in `docs/design/20260516-editor-mode.md`. Demand-driven.
- **Multi-buffer editor mode** (`--buffer A=B --buffer C=D`). The LSP v1 supersedes this for most use cases (LSP `BufferTable` already holds N buffers); remains relevant for non-LSP batch tooling. Demand-driven.

### SKILL-driven onboarding UX (ADR-73, landed 2026-06-20 — deferred follow-ups)

The onboarding-UX upgrade shipped on master (unreleased): `rigor skill describe` + the `rigor-next-steps` entry point + a 13-skill catalogue + vercel-labs/skills distribution, plus six field-trial-driven UX fixes (`CHANGELOG.md` § `[Unreleased]`; resume detail + the field-trial notes in `docs/CURRENT_WORK.md`). Two follow-ups stayed deferred ([ADR-73](adr/73-skill-driven-user-experience.md) § "Field-trial follow-ups", open decisions):

- **`rigor skill describe --deep` — check-aware headline.** Make the *headline* recommendation reflect what `rigor check` would find (errors → `baseline-reduce`, a monkey-patch cluster → `monkeypatch-resolve`, `RBS 0` / config-error → `doctor`), preserving WD2's pure presence-only default behind an opt-in flag. Needs a shared "run check → `Analysis::Result`" helper extracted from `CheckCommand#build_check_runner`. **Marginal value is modest** — the landed agent-prompt routing already has the agent refine from `check` findings it runs anyway — so demand-gated.
- **Coverage-tractability labels.** Classify the `coverage --protection` "add a type here" holes by generic-type-param / external-gem / framework-DSL so users don't chase ones hand-RBS cannot close. Needs **`Dynamic`-provenance tracking** (`Inference::ProtectionScanner` knows a receiver is `Dynamic`, not *why*); plausibly its own ADR (touches the `Dynamic[T]` carrier). Demand-gated.

### Performance / scalability — caching + incremental analysis (ADR-44 / 45 / 46, SHIPPED v0.1.17)

The v0.1.17 perf cycle. Shipped detail is in `CHANGELOG.md` § `[0.1.17]`; engine-internal resume detail is in `docs/CURRENT_WORK.md`. Listed here for the forward-looking *remaining* (demand-gated) levers per ADR.

- **[ADR-44](adr/44-dispatch-allocation-churn.md) — per-dispatch / per-narrow allocation churn (LANDED).** `rigor check` is allocation-bound (profiles: [`docs/notes/20260604-mastodon-allocation-profile.md`](notes/20260604-mastodon-allocation-profile.md), [`…-gitlab-plugin-contribution-allocation.md`](notes/20260604-gitlab-plugin-contribution-allocation.md)). Body-scope `with_*` chain collapse + allocation hygiene. Mutable pooled `Scope` / `CallContext` rejected (re-entrancy → FP); `ProjectScope` regrouping downgraded (object-shape benchmark: cuts size not count). **Remaining (demand-gated):** the `ProjectScope` memory-footprint regrouping if a heap-pressure case appears; symbol-level `CallContext` specialisation.
- **[ADR-45](adr/45-unchanged-project-fast-path.md) — unchanged-project fast path (LANDED).** Record-and-validate whole-run diagnostic cache. Coarse: any analyzed-file change → full re-run. **CI caveat:** on a code change the cache saves <1 s on a ~113 s GitLab run (measured), so persisting `.rigor/cache` in CI is near-pointless; the win is local dev / editor / same-SHA re-runs. ADR-46 is the CI lever.
- **[ADR-46](adr/46-incremental-dependency-graph.md) — incremental analysis via a cross-file dependency graph (COMPLETE body tier, LANDED).** `rigor check --incremental` re-analyzes only `ΔF ∪ dependents[ΔF]` and serves the rest from a fingerprinted cross-process disk snapshot; per-file deps recorded at the `Scope` accessor choke point → `dependents` index; soundness CI-gated by `--verify-incremental` (`make check-incremental`, byte-identical vs full). Measured ~6–9× on unchanged / leaf-edit runs. **Slices 3 + 4 landed, structural tier complete incl. file add/remove:** slice 4 (symbol granularity: `(file, symbol)` deps) and slice 3 (structural-tier negative-dependency tracking — closed two warm-session soundness gaps: a missed `helper()` served a stale `call.unresolved-toplevel` after a later definition, and a subclass served a stale missing `def.override-*` after its superclass was defined later; `top_level_def_for` + the override checker now record positive/negative edges and `#recheck` widens by appeared-symbol/class negative-dependents). **File add/remove is now incremental** — the snapshot fingerprint is keyed on the analysis roots (not the file list), so adding/deleting a file keeps the snapshot warm and `#recheck` reconciles the delta (added → analyse + re-check the consumers of its now-defined names; removed → evict + re-check its positive dependents), byte-identical to a full run. **Remaining (demand-gated):** return-type summaries to bound inferred-return fan-out. Pieces: `Analysis::{DependencyRecorder,Incremental,IncrementalSession}`, `Cache::IncrementalSnapshot`. See the ADR § "Staging" + `docs/CURRENT_WORK.md` § "Next-session entry point".

### Performance / scalability — compiled plugin contribution dispatch (ADR-52, COMPLETE — slices 1–6 landed 2026-06-10/11; all five legacy users migrated, hook deleted)

**[ADR-52](adr/52-compiled-plugin-contribution-dispatch.md)** — the structural successor to ADR-44's spot fixes on the plugin consumption path, grounded in the [2026-06-10 structural audit](notes/20260610-plugin-architecture-perf-audit.md). Criterion: every per-call / per-def / per-file / per-node plugin consultation is gated by a key the engine already holds, via a table compiled once per run at registry build; plugin code runs only on candidate hits. **COMPLETE — all six slices landed 2026-06-10/11**, each gated on byte-identical diagnostics over the Mastodon (6-plugin) / GitLab (11-plugin) corpora + stackprof deltas + `make bench-perf`: (1) compiled contribution table + engine call-site rewiring (no contract change); (2) static method-name-only `dynamic_return` (receiver-less) → `rigor-units` (audit correction: no production plugin fit the static gate — activesupport-core-ext ships no hook, sorbet's catalog is a run-time name set); (3) run-time **receiver-set** callable (lazy `instance_exec` memo, a safe over-approximation of the block filter) → `rigor-activestorage`; (4) run-time **method-name** set → lisp-eval / pattern, then `rigor-sorbet` (dependabot-core ~38× faster) and `rigor-activerecord` — **the receivers-gate "blocker" was resolved with no new gate form**, since the method-name callable never reads the receiver type — plus per-file `file_methods:` (slice 5a) → `rigor-rspec`; (5b) **`flow_contribution_for` deleted** (deliberate pre-1.0 BC break — load-time error + CHANGELOG migration note); (6) single engine-owned `Plugin::NodeRuleWalk` per file. The full slice-by-slice record (commit hashes, the resolved AR blocker, delegation lessons) lives in `docs/CURRENT_WORK.md` § "ADR-52". Demand-gated leftovers only: a node-major diagnostic re-sort (not taken — would break byte-identity) and the exact-membership-Set gate refinement if a profile ever shows the receiver-ancestry walk hot. The frozen table is Ractor-shareable (ADR-15 Phase 4); this completes the ADR-37 segregation arc.

### Performance / scalability — cache disk + warm-load slimming (ADR-54, SHIPPED 2026-06-10)

**[ADR-54](adr/54-cache-slimming.md)** — closed the cache-layer disk/load axis the ADR-44/45/46 cycle left untouched, grounded in the [2026-06-10 cache audit](notes/20260610-cache-disk-runtime-audit.md). Before: every project's `.rigor/cache` weighed ~32 MB (three RBS Marshal blobs; byte-identical across no-sig projects → >1 GB duplicated on a survey-corpus machine) and warm runs paid ~700 ms of `Marshal.load` to materialise them. Criterion: a cache tier earns its bytes only if it beats recomputation from the next-cheapest tier on the warm path. **All four WDs landed** (commits `5f53db09` / `0c671e04` / `d2465fe1` / `5ced88f1`): (1) the `rbs.instance_definitions` / `rbs.singleton_definitions` disk blobs retired — measured net-negative given the cached env (366 ms load vs 137 ms build-all; 23.4 MB/project); dispatch path lazy per-class on the existing per-process memos, the ADR-15 prewarm/Reflection consumers keep eager full tables built from the cached env; (2) every entry's value payload zlib-deflated behind a `Store::HEADER` format-byte bump (the env blob lands at 1.76 MB = 16 % of raw; old entries read as silent misses, no migration code); (3) `cache.max_bytes` defaults to 256 MB so `evict!` stops being a permanent no-op — the rigor repo's own cache had accumulated ~180 MB of orphans against a ~2 MB active set (explicit `null` restores unbounded); (4) `RbsDescriptor.build` memoised per loader. Landed envelope: ~33.7 MB → ~2 MB per project (−94 %); warm runs touching definitions save up to ~550 ms / 1.6 M allocs; cold runs shed the eager build-all + 23 MB write. Partially supersedes ADR-7 § Slice 6-D. Deferred/rejected: cross-project shared cache root (post-slimming duplication is ~1.7 MB × N — not worth a second root), `fresh?` mtime fast-path (soundness), zstd (new dependency). Gated per slice on diagnostics-identical self-check (`--no-cache`/cold/warm) + Mastodon-corpus runs.

### Performance / scalability — cache schema-marker ABI gate + compaction hardening ([PR #57](https://github.com/rigortype/rigor/pull/57), branch `cache/schema-marker-and-compaction-hardening`)

Hardening slice re-planned from the [2026-07-07 handover audit](notes/20260707-cache-mechanism-audit-sakana.md) and executed per the [2026-07-07 plan](notes/20260707-cache-hardening-plan.md) (all phases 1–6 landed): folds `Rigor::VERSION` into the cache's `schema_version.txt` marker (payload ABI gate), makes `ensure_schema_version!` boolean-returning so read-only stores (LSP / editor mode) degrade to memo-only on a stale-or-unreadable marker instead of trusting disk, unifies the write-failure rescue across `fetch_or_compute` / `fetch_or_validate` (`try_write_entry`), adds ensure-cleanup in `atomically_replace`, and runs `evict!`'s stale-temp-file cleanup + whole-project generation cap even under `max_bytes: nil`. **Remaining (demand-gated, low priority):**

- Replace the hardcoded `Store::GENERATION_CAP_BY_PRODUCER` allow-list with producer-declared `generation_cap:` metadata, so a new whole-project producer isn't silently left uncapped.
- Validate the `analysis.run-diagnostics` cap of 16 against real multi-invocation-path usage — a workflow that churns through many distinct path-sets could still accumulate live generations faster than the cap anticipates.

### Internal architecture — pre-1.0 re-examination (next work targets)

The [2026-06-10 lib/rigor architecture re-review](notes/20260610-lib-rigor-architecture-rereview.md)
re-checked the whole engine ahead of the release line on two axes — clarity of
role separation, and waste on hot call paths — and found the foundation sound
(acyclic layering, immutable-Scope discipline, unified dispatch tiers). What
remains is queued here as the next work targets, in four phases (full rationale
and `file:line` grounding in the note):

1. **Phase 1 — mechanical fixes. DONE (2026-06-11).**
   (a) the `rigor-sorbet` public-API boundary violation rewritten onto
   `Type#accepts` (`9946b3ea`); (b) the user-class-fallback `CallContext`
   rebuild derived from the entry context via `#with` (`495cdf5a`; the Tier-B
   promotion rebuild deliberately stays — no context reaches it, and threading
   one would cascade signatures for no behavioural gain); (c) `rigor check`
   extracted into `CLI::CheckCommand` (`d5b0e108`, cli.rb ~990 → ~320 lines).
   Follow-up flagged, not done: cli.rb keeps a few now-transitively-unused
   requires (behaviour-adjacent for embedders, separate slice).
2. **Phase 2 — [ADR-52](adr/52-compiled-plugin-contribution-dispatch.md)
   implementation: DONE (the ADR is complete, slices 1–6 landed 2026-06-10/11).
   The built-in-tier addendum is also DONE:** the eight stdlib singleton
   folders now sit behind a frozen class-name → folder table consulted only
   for `Singleton` receivers (mutually exclusive by construction — each
   folder's first check is `Singleton[<its one class>]` — so the collapse is
   observably identical; the table sits where the eight sat in the flat
   list). Non-singleton calls skip all eight no-op trials.
3. **Phase 3 — structural, behaviour-preserving. DONE (2026-06-11).**
   (a) `Analysis::Runner` decomposed into
   `runner/{pool_coordinator,project_pre_passes,diagnostic_aggregator,run_snapshots}`
   (~2000 → ~970-line orchestrator; reader-proc injection preserves read
   timing; also the footing for the queued LSP pre-built-Environment
   refactor). (b) Narrowing is now the sole owner of the certainty
   judgments — `predicate_certainty` / `class_pattern_certainty` /
   `value_pattern_certainty` derived from its own fragments; Typer and
   Evaluator are callers (the `&&`/`||` `constant_value_polarity` gate
   deliberately stays Constant-only — full-probe precision there would be
   a behaviour change, queued as demand-gated).
4. **Phase 4 — [ADR-53](adr/53-scope-discovery-index-separation.md):
   DONE (2026-06-13).** Track A done (A1 `031f161e` + A2 `063823e4`, 2026-06-10/11);
   Track B done (B1–B4 complete): B3 (`b85c51c6` + `4f1745aa` + `963a2947`) hosted
   all five built-in collectors on `CheckRules::RuleWalk`; B4 (`e614ebf3` + `2925d66a`)
   converged it with `Plugin::NodeRuleWalk` into **one walk per file total**;
   shadow-harness + byte-identical gated throughout, equivalence spec 191 examples.
   The full four-phase pre-1.0 architecture re-examination is complete.

### Performance / scalability — other levers
- **O4 Layer 3 — `Gemfile.lock` parse + `gem_rbs_collection` version matching.** Sits on top of v0.1.5's `BundleSigDiscovery` MVP. The MVP's auto-skip list (`SKIPPED_GEMS_BY_DEFAULT`) becomes a versioned resolution table; rigor consumes `Bundler::LockfileParser` output + queries `ruby/gem_rbs_collection` for the best-matching version. Unblocked by O7's failure-memo (conflicts now warn rather than hang).
- **Fork-based file-level parallelism for `rigor check`.** Stackprof of warm `rigor check lib` shows ~50% inference, ~22% `Marshal.load`, ~17% GC. The Phase 4b Ractor path is the v0.1.5 parallelism story; a fork-based path remains a parallel (non-exclusive) option for hosts where Ractors are unavailable or where COW sharing of pre-warmed `Environment` blobs would beat per-Ractor env build.
- **Spec-suite runtime breakdown (2026-05-17 investigation; partially landed).** `make verify` default switched to parallel rspec (commit `086e507`): wall time 217s → 60s (3.6× on 12-core). A follow-on cycle confirmed the real bottleneck was **per-call RBS env rebuild on every `analyze(sig: …)`**: `Cache::Store` keys the env on `(path, sha256)` per `RbsDescriptor::FileEntry`, so each call's unique `Dir.mktmpdir`-rooted sig path forced a fresh ~1.8 s env build. **Helper-side fix landed** (`spec/support/runner_helpers.rb`): content-keyed sig dir + shared workspace for source-only calls. `runner_spec.rb` 39.6s → **25.4s isolated (-36%)**, `make verify` parallel 65.6s → **52.6s (-20%)** on 12-core. The two originally-queued levers stay open with smaller remaining headroom:
  - **(a) Share `Environment` across examples in `runner_spec.rb`** via `before(:context)` or a `let_it_be`-shaped helper. Now that the cache-key fix has cleared the sig-related component of the per-call cost, the remaining win is the Environment construction itself for the ~80 % of examples that hit the source-only fast path. Plugin variance per-example still complicates the share. Demand-driven; the helper-side fix already absorbed most of the headroom.
  - **(b) In-memory `Analysis::Runner.run_source(source:, path:)` entry point — LANDED (v0.1.17).** Analyses a Ruby String in memory (no tmpdir / chdir) via an `@in_memory_sources` map honoured by `parse_source` + `accept_as_ruby_file?`; the bare `analyze(source)` spec helper routes through it, validating equivalence across the whole suite. **Perf note:** the hypothesised ~5% spec-suite win did NOT materialise (the shared-workspace path was already optimised); the real value is the clean embedder (LSP / editor) public API.
- ~~**In-memory `Analysis::Runner.run_source` entry point (public + test-only).**~~ LANDED — see (b) above.

### Sig-gen (ADR-14)
- **`--params=observed` attr_reader / attr_writer / attr_accessor inference from `initialize` observations — LANDED** (commit `f2aa8de`, v0.1.9 cycle). `rigor sig-gen --params=observed --write` now propagates observed call-site argument types through `@ivar = param` assignments in `def initialize`, so `attr_reader` / `attr_accessor` methods receive a concrete unioned return type instead of being skipped as `:untyped_return`. Implementation: `build_observed_ivar_map` → `collect_init_ivar_obs` → `ivar_obs_from_initialize` (+ `build_ivar_obs_type_map` / `collect_param_obs_types`). All new logic stays in `Generator`; `ScopeIndexer` is not touched. TypeProf compatibility spec added (`spec/rigor/sig_gen/typeprof_compat_spec.rb`) asserting Rigor covers ≥ all methods TypeProf recognises and returns a more specific type. The `rigor-project-init` SKILL Phase 5 (`skills/rigor-project-init/references/04-sig-uplift.md`) documents the end-user workflow.
- **`update_existing` does not yet collapse sibling parent / child class blocks.** Gap (c)'s tree-builder fix lives in `Writer#render_new_file` (the create-new path). When updating an existing target file, `merge_class` resolves each candidate's `class_name` independently — flat-sibling layouts stay flat. Re-flowing an existing file into the nested layout would require parsing the existing decl tree and rewriting it, which is out of scope for a follow-up fix. Users who want the canonical nested layout regenerate from scratch (delete the target sig file and rerun).
- **Remaining gaps after `--params=observed`** (demand-driven follow-ups): `attr_reader` with ivars set from non-`initialize` sources (DB reads, config, side effects) still fall through to `:untyped_return`; fix requires a hand-written sig or an RBS annotation. Deep chains on untyped receivers need `rbs collection install` / ADR-10. Dynamic methods (`define_method`, DSL macros) need a project plugin. Bootstrap convergence finding: iterative `sig-gen --write` alone does NOT improve untyped returns — `@name: untyped` written → second pass sees `equivalent` → type stays untyped; `--params=observed` is the correct lever.

### Browser playground (ADR-29)

A browser-based playground — CodeMirror 6 editor with real-time
diagnostics and annotate-style type comments — backed by a thin
Rack/Puma API on Fly.io and a static Cloudflare Pages frontend.
**Slices 1-4 LANDED in the v0.1.x cycle:** backend `/check`
endpoint with `Tempfile`-per-request isolation + 64 KB cap +
CORS preflight (slice 1); CodeMirror 6 editor with debounced
lint markers (slice 2); `/annotate-lines` toggle view (slice 3);
`/type-of` hover via CodeMirror's `hoverTooltip` extension
(slice 4). Slice 1's Fly.io deploy artefacts (`apps/rigor-playground/Dockerfile`
+ `apps/rigor-playground/fly.toml`) and slice 2's Cloudflare Pages
deploy config (`apps/rigor-playground/frontend/_headers` + `_redirects` +
README) ship as committable config; the actual `fly deploy` /
`wrangler pages deploy` steps require credentials and are not
part of any landed cycle. Slice 5 (ruby.wasm migration) stays
demand-driven, gated on three external conditions (official
Ruby 4.0 WASM build + `prism`/`rbs` WASM packages + Rigor test
suite passing under WASM).

The **ADR-29 WD4 amendment (2026-05-25)** is live: the backend
pre-loads `rigor-rbs-inline` with `require_magic_comment: false`
(per [ADR-32](adr/32-rbs-inline-comment-ingestion.md) WD10), so
a snippet with `# @rbs`-shaped comments is analysed as inline-
RBS from the first request — the seeded SAMPLE in `index.html`
showcases this against the ADR-32 ascdesc pattern. See
[ADR-29](adr/29-browser-playground.md).

### Open research questions queued in ADRs
- **ADR-15 § OQ1** — per-Ractor `Cache::Store`-shared facade. Today each worker builds its own RBS env from cache; OQ1 explores sharing the in-memory env across workers via a shareable facade. Would lower the pool wall-clock crossover with sequential (currently around 1.3–1.8 K files).
- **ADR-13 § "Open questions"** — extending the shape-projection surface beyond the five core functions (`pick_of` / `omit_of` / `partial_of` / `required_of` / `readonly_of`). Authoritative when adding new mapped-type vocabulary.

### Documentation — user-facing docs overhaul (COMPLETE)

The [`doc-coauthoring`](../.claude/skills/) user-friendliness pass over the user-facing docs is **done and pushed**: the handbook (all 19 files), the manual (all 14 chapters + per-plugin pages for all 30 bundled checker plugins — the "(ii)" split: consumer view in the published manual, developer/contract material in slimmed `plugins/<id>/README.md`s), and [`docs/types.md`](types.md), with chapter orientation + mini-TOCs, cold-read-verified anchors, and a batch of code-verified doc-accuracy fixes (recorded in `CHANGELOG.md` § `[0.1.16]` Fixed). The two plugin-*code* gaps it surfaced (`rigor-dry-validation` RBS-overlay wiring, `rigor-shoulda-matchers` double-prefixed rule ids) are fixed and in v0.1.16. The migration *method* is preserved in [`docs/notes/20260603-plugin-doc-migration-playbook.md`](notes/20260603-plugin-doc-migration-playbook.md) for future plugin additions.

### Documentation — user-facing docs review battery (queued)

A continuous quality gate for [`docs/manual/`](manual/README.md) and
[`docs/handbook/`](handbook/README.md), adapted from the multi-lens review
battery used for the chibirigor book. Design note:
[`docs/notes/20260610-user-docs-review-battery-design.md`](notes/20260610-user-docs-review-battery-design.md).

The key difference from the book battery: **this is software documentation, not
a book** — prose depth is not a virtue, and the battery's job is correctness and
necessary clarity, not narrative richness. The "reading balance" layer is
*inverted* (bloat detector, not depth booster). The largest structural addition is
a **mechanical L0 layer** — decisions about snippets and CLI surface are
deterministically verifiable, so a `spec/docs/` harness does the work that the
book battery delegates to a reproducibility reviewer.

Five layers, run in order (full cycle at milestones; individual layers on demand):

1. **L0 機械 — `spec/docs/` harness (permanent gate, not a lens).** Three
   checkers wired as `make docs-check`:
   - **Snippet execution:** extract ` ```ruby ` blocks from handbook chapters,
     run via `rigor check`, validate `assert_type` / `dump_type` claims against
     actual inference output. Direct analogue to chibirigor's scoring harness,
     but the subject is the docs themselves, not a reader's re-implementation.
   - **CLI/config drift:** cross-reference `docs/manual/02-cli-reference.md`
     flags + subcommands against the CLI option parser; `03-configuration.md`
     keys against the config schema; `04-diagnostics.md` /
     `08-understanding-errors.md` rule IDs against the rule registry.
   - **Link integrity:** relative links + ADR number references resolve to real
     targets.
   L0 runs in CI alongside `make verify`; the LLM battery runs only when L0 is
   green.

2. **L1 真 — semantic fidelity (LLM lens).** Claims that cannot be mechanically
   verified: cache invalidation conditions, diagnostic firing conditions, severity
   profile mappings. Handbook claims checked against the
   [spec corpus](type-specification/README.md) (spec binds); manual claims checked
   against implementation + actual CLI behaviour. Reviewer has read access to
   `lib/rigor/` and may run the CLI. The type-theory expert lens applies to
   `appendix-type-theory.md` and the cross-checker appendices only.

3. **L2 伝 — reader lenses (LLM lenses, parallel).** Three sub-lenses:
   - **Ruby-only reader** — handbook README's stated audience (Ruby programmer, no
     static-typing background assumed). Ported from chibirigor lens 8 verbatim,
     including the "do not over-simplify" constraint.
   - **Procedure reproduction** — manual chapters 01 and 14 (installation + Rails
     quickstart): can a reader complete the procedure from the text alone?
     Execution-mode lens.
   - **Appendix reader** — "Coming from X" appendices: sampled at the appendix
     that changed, read by a reader with that language background. All nine in a
     full cycle; changed ones only on a targeted pass.

4. **L3 簡 — bloat detector (LLM lens, inverted from the book battery).** Does
   NOT flag thin prose — that is L2's job. Flags only the *fat* direction:
   - Manual / handbook overlap (the README-declared split is the criterion).
   - Prose that a table or annotated code block would express more precisely.
   - handbook non-goal violations: content beyond "a few hours to read cover to
     cover," content that belongs in the spec corpus, plugin authoring guidance
     (belongs in `examples/`).

5. **L4 整 — English copyedit + convention compliance (LLM lens, always last).**
   Technical writing quality (AI-flavoured phrasing, passive-voice drift),
   the `interface` → *structural interface* / *RBS interface* naming rule
   (semi-mechanisable), `docs/manual` ↔ `docs/handbook` cross-reference hygiene.

**Output notes:** lens findings go to `docs/notes/YYYYMMDD-docs-review-<scope>.md`,
not into the doc directories themselves.

**Pending work, in priority order:**
1. **DONE** — the L0 harness ships as `spec/docs/` (`handbook_snippets_spec.rb`,
   `manual_drift_spec.rb`, `link_integrity_spec.rb`) with the `make docs-check`
   target, gated by the `test` suite (so `verify` + `ci.yml` run it). 2026-07-06
   added a fourth `manual_drift` axis: rule `documentation_url` anchor integrity
   (ADR-65 public URLs must resolve). Not yet covered mechanically: CLI *flag*
   drift (flags lack a clean registry — FP-prone; demand-gated).
2. **DONE (2026-07-06)** — `.claude/skills/rigor-docs-review/SKILL.md` freezes
   the five-layer battery (L0 mechanical gate → L1 fidelity → L2 reader lenses →
   L3 inverted bloat detector → L4 copyedit) as independent-context subagents,
   parallel-within / sequential-across, findings to `docs/notes/`.
3. **In progress** — first cycle. **L1 fidelity over the manual's operational
   chapters DONE (2026-07-06)** — three parallel reviewers vs the real CLI +
   implementation; 4 verified fixes landed (strict-profile "every rule is error"
   overstatement, a missing `dynamic_origin` cause `inferred_return_untyped`, the
   `--baseline-strict` any-drift semantics, and the non-built-in
   `rbs_extended.unsatisfied-conformance` `rigor explain`/`documentation_url`
   claim), ledger [`docs/notes/20260706-docs-review-fidelity.md`](notes/20260706-docs-review-fidelity.md).
   `02-cli` / `11-ci` came back clean — the predicted ADR-51 CI-format gap did not
   materialize. **Remaining:** L2 reader lenses, L3 bloat, L4 copyedit over the
   same chapters, then a handbook-vs-spec-corpus fidelity pass.

## Rails ecosystem plugins (running track, parallel to v0.1.x core work)

The full roadmap is in [`docs/design/20260508-rails-plugins-roadmap.md`](design/20260508-rails-plugins-roadmap.md). Summary of the running track:

**Already landed (released through v0.1.4 → v0.1.6):**

- **Tier 1**: [`rigor-rails-routes`](../plugins/rigor-rails-routes/) (`:helper_table`), [`rigor-rails-i18n`](../plugins/rigor-rails-i18n/), [`rigor-actionmailer`](../plugins/rigor-actionmailer/), [`rigor-activejob`](../plugins/rigor-activejob/).
- **Tier 2**: [`rigor-activerecord`](../plugins/rigor-activerecord/) (`:model_index`; associations / enums / scopes / validations / callbacks); [`rigor-actionpack`](../plugins/rigor-actionpack/) (routes / filters / renders / strong-params); [`rigor-factorybot`](../plugins/rigor-factorybot/) (Phase 1 (a)+(c)).
- **Tier 3**: [`rigor-pundit`](../plugins/rigor-pundit/), [`rigor-sidekiq`](../plugins/rigor-sidekiq/), [`rigor-rspec`](../plugins/rigor-rspec/) (Pillar 2 slices 1+2+3), [`rigor-actioncable`](../plugins/rigor-actioncable/), [`rigor-activestorage`](../plugins/rigor-activestorage/) (v0.1.5); [`rigor-graphql`](../plugins/rigor-graphql/) (v0.1.6 — Tier 3D, slices 1+2a–2d, four cross-plugin facts); [`rigor-minitest`](../plugins/rigor-minitest/), [`rigor-rspec-rails`](../plugins/rigor-rspec-rails/), [`rigor-shoulda-matchers`](../plugins/rigor-shoulda-matchers/) (v0.1.6).
- **Opt-in bundles**: [`rigor-activesupport-core-ext`](../plugins/rigor-activesupport-core-ext/) (opt-in RBS bundle); [`rigor-typescript-utility-types`](../plugins/rigor-typescript-utility-types/) (ADR-13 slice 6).
- **Meta-gem**: [`rigor-rails`](../plugins/rigor-rails/) (v0.1.6 scaffold; Tier 1+2 `add_dependency` declarations; `.rigor.yml` activation stays per-plugin).
- **ADR-16 substrate consumers (v0.1.5)**: [`rigor-sinatra`](../plugins/rigor-sinatra/) (Tier A), [`rigor-dry-struct`](../plugins/rigor-dry-struct/) (Tier C; v0.2.0 ADR-18 precision uplift), [`rigor-devise`](../plugins/rigor-devise/) (Tier B).
- **dry-rb foundation (v0.1.6)**: [`rigor-dry-types`](../plugins/rigor-dry-types/) (`:dry_type_aliases` — canonical + nested + user-authored compositions + transitive references); [`rigor-dry-schema`](../plugins/rigor-dry-schema/) (`:dry_schema_table` — recognition + `each` list slot); [`rigor-dry-validation`](../plugins/rigor-dry-validation/) (`:dry_validation_contracts` + RBS overlay for `Contract#call → Result`). `rigor-dry-struct` v0.2.0 consumes `:dry_type_aliases` via ADR-18 `returns_from_arg:`.

**Non-Rails ecosystem (landed v0.1.9):**

- [`rigor-hanami`](../plugins/rigor-hanami/) — ADR-28 provide-and-check for Hanami::Action. Protocol: `#handle(Hanami::Action::Request, Hanami::Action::Response) → void` in `app/actions/**/*.rb`. Configurable via `action_path:` for custom slice layouts.

**Pending Tier 3 (specialised, author when there is concrete user demand):**

- `rigor-graphql` slice 3+ (resolver-method type-check; `<Type>.array` / `<Type>!` chain forms beyond the bracket form; string-form `field :foo, "User"` diagnostic; `Schema.execute(...)` result typing).
- `rigor-dry-schema` slice 2+ (typed `result.to_h` synthesis via ADR-16 Tier C / per-row diagnostics), `rigor-dry-validation` slice 2+3 (params-block typing via `:dry_schema_table` consumption + `json` parity), `rigor-dry-monads` (needs ADR-3 amendment for `Result[T, E]` / `Maybe[T]` carrier — slicing options in [the slicing plan](design/20260517-dry-validation-slicing.md) § "Open observation").
- `rigor-actioncable` `#receive(data)` parameter-type provision enhancement (see ADR-28 ecosystem entry above; demand-driven).

Each plugin is staged in `plugins/rigor-<id>/` per the [`rigor-plugin-author`](../skills/rigor-plugin-author/SKILL.md) SKILL discipline and **ships inside the single bundled `rigortype` gem** — the distribution model settled on in [ADR-31](adr/31-contribution-and-supply-chain-policy.md) (single gem, per-plugin gemspecs dropped in commit `9769f5fa`). The earlier `git subtree split` + per-plugin-publish plan is **retired**; bundled plugins are not separately installable gems, and `git subtree merge` survives only as ADR-31 WD5's rare reserved option for absorbing a proven *third-party* plugin, not as the rigor-rails publication path. The `rigor-rails` meta-gem scaffold (v0.1.6) now serves as the activation-grouping template (its `add_dependency` declarations document the Tier 1+2 umbrella) rather than a separate-publish manifest.

[ADR-9](adr/9-cross-plugin-api.md) (cross-plugin API) landed in v0.1.1 (Track 2 — `Plugin::FactStore` + `prepare(services)` + `manifest(produces:/consumes:)` + topo-sorted loading + `#flow_contribution_for`, slices 1 → 5 + 7); the first publish-and-consume cycles (`:helper_table` rails-routes → actionpack, `:model_index` activerecord → actionpack + factorybot) were exercised end-to-end in v0.1.4. Slicing per ADR-9 § "Implementation slicing" allows partial landings.

[ADR-16](adr/16-macro-expansion.md) (macro / DSL expansion substrate) released in v0.1.5. Three worked consumers exercise the substrate end-to-end — `rigor-sinatra` (Tier A), `rigor-dry-struct` (Tier C), `rigor-devise` (Tier B). The substrate ships at the WD13 floor + precision promotion for the common cases (Tier B origin-module RBS dispatch, Tier C plain class-name `nominal_for_name`); Tier D engine integration + ADR-13 resolver-chain wiring for utility-type returns stay demand-driven.

[ADR-18](adr/18-substrate-per-call-site-return-type.md) (substrate per-call-site return-type DSL) released in v0.1.6. Adds `Plugin::Macro::HeredocTemplate::Emit#returns_from_arg` (+ `lookup_via:` cross-plugin fact channel); `rigor-dry-struct` v0.2.0 is the first worked consumer (resolves `attribute :city, Types::String` to `Nominal[String]` via `:dry_type_aliases` published by `rigor-dry-types`). Slice 4 (TraitRegistry parity) + chained-call argument extraction stay demand-driven.
