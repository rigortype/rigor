# Rigor Roadmap

Forward-looking commitments: what's actively in flight, what's
planned next, what's deliberately out of scope.

This file is **planning material**, not a release log. For the
"what shipped" record, see [`CHANGELOG.md`](../CHANGELOG.md)
(active `0.1.x` cycle) and
[`docs/CHANGELOG-0.0.x.md`](CHANGELOG-0.0.x.md) (archived `0.0.x`).

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

## v0.1.5 — accumulating on `master` (release pending)

Theme: **kick off the [ADR-15](adr/15-ractor-concurrency.md) Ractor migration end-to-end, bank the spec-suite performance wins (6× wall-clock), close the v0.1.3 / v0.1.4 deferred-queue ecosystem items, and prove out the analyzer against fourteen real-world Rails / Ruby projects — driving production-rigor improvements (built-in vendored gem RBS, target-project Bundler awareness, several engine fixes).**

Every committed v0.1.5 track is purely additive (no behaviour change for existing CLI consumers); the Ractor work is staged so each phase is independently revert-able.

Banked so far on `master`:

### ADR-15 Ractor migration — phases 1–4c + 4b.x all landed

- **Phase 1** (value-object shareability audit). Every `Rigor::Type::*` / `Rigor::TypeNode::*` / `Cache::Descriptor` / `FactStore` / `FlowContribution` is `Ractor.shareable?` at construction. Regression guard at [`spec/rigor/ractor_readiness_spec.rb`](../spec/rigor/ractor_readiness_spec.rb).
- **Phase 2a** (`Rigor::Configuration` deep-freeze). `Configuration.new(...)` is `Ractor.shareable?` at construction time.
- **Phase 2b** (`Environment::Reflection` extracted). Frozen RBS-query facade; not Ractor.shareable? (transitive RBS::Location is C-extension state) — the Phase 4 worker pool sidesteps this by having each worker build its OWN Reflection from the shared `Cache::Store`.
- **Phase 3a** (`Plugin::Blueprint` + `Registry.materialize`). Frozen `Ractor.shareable?` blueprint carrier + per-Ractor materialisation factory; plugin INSTANCES intentionally stay non-shareable.
- **Phase 4a** (`Analysis::WorkerSession`). Per-worker substrate consuming only `Ractor.shareable?` inputs and building its OWN plugin registry / dependency-source index / environment / reporters internally.
- **Phase 4b** (`Runner#analyze_files_in_pool`). Actual Ractor pool wiring around WorkerSession. Three message kinds (`[:prepare, …]` / `[:file, path, …]` / `[:done, …]`); diagnostic order preserved via per-path result Hash + original-order re-flow. Equivalence + plugin replay + prepare-dedup proven by [`spec/rigor/analysis/runner_pool_spec.rb`](../spec/rigor/analysis/runner_pool_spec.rb).
- **Phase 4b.x** (worker-side env-build stability + module-shareability). Four follow-ups against real-world projects fixed the remaining `Ractor::IsolationError` sources: `NumericCatalog#@catalog`, `Type::Refined::CANONICAL_NAMES`, `Builtins::RegexRefinement::RULES`, `MethodDispatcher::ShapeDispatch::REFINED_STRING_PROJECTIONS`, plus `MethodDispatcher::CONSTANT_CONSTRUCTORS` (proc values). `RbsLoader#prewarm` (new) drives every cached RBS producer on the main Ractor before pool spawn so workers serve from the Marshal blob.
- **Phase 4c** (CLI / env / config opt-in surfaces). `rigor check --workers=N` > `RIGOR_RACTOR_WORKERS` > `.rigor.yml` `parallel.workers:` > `0`. Sequential remains the documented default.

**Pool ≡ sequential proven on 14 real-world projects** (Redmine, Discourse, Mastodon, GitLab FOSS, Forem, Solidus, Chatwoot, Canvas LMS, OpenProject, Loomio, Publify, Diaspora, Dependabot Core, tDiary Core — total 31,840 files swept). Pool wall-clock crossover with sequential sits around 1.3–1.8 K files; GitLab FOSS (11.1 K files) shows pool=8 at 1.64× sequential.

### Real-world Rails / Ruby survey + production-rigor improvements

Three rounds of project sweeps (recorded in [`docs/notes/20260515-real-world-rails-survey.md`](notes/20260515-real-world-rails-survey.md)) drove eight engine / packaging improvements:

- **O1** (`examples/rigor-activesupport-core-ext/`) — opt-in RBS bundle for the top ~50 ActiveSupport `core_ext` selectors. Combined v1 + v2 impact across the 14 survey projects: total diagnostics 12,502 → 3,071 (−75%), `call.undefined-method` 10,589 → 1,426 (−87%).
- **O5** (`ac14c45`) — `Hash[K, V] <: Enumerable[[K, V]]` parametrized-ancestor projection in `Inference::Acceptance`.
- **O6** (`4698437`) — `MethodDispatcher::CONSTANT_CONSTRUCTORS` deep-share. Pool ≡ sequential on GitLab FOSS after fix (was 2,983 vs 2,982).
- **O7** (`3c4a7ff`) — `RbsLoader#env` memoises failure. Adding a single conflicting sig (e.g., gem-shipped `prism/sig/prism.rbs` whose `Prism::VERSION` clashes with rigor's bundled stdlib RBS) pre-fix caused per-file env rebuilds (390× for 1 controller, ~35 s wall). Post-fix: 0.15 s for 5 controllers (~550× speedup) with a single user-facing warning naming the offending file.
- **Vendored gem RBS** (`f9b94d2`) — `data/vendored_gem_sigs/<gem>/` ships RBS for six native-extension gems by default: `pg` / `mysql2` / `nokogiri` / `bcrypt` / `redis` / `idn-ruby`. Four come from `ruby/gem_rbs_collection` (MIT-vendored with `LICENSE.upstream`); two (`pg`, `idn-ruby`) are minimal hand-written stubs (MPL-2.0). Out-of-the-box RBS classes available: 1,134 → 1,273 (+139). Mastodon's `bundle install` blocker (libidn) is moot for static analysis.
- **O4 MVP** (`95b923f`) — `bundler.bundle_path` / `bundler.auto_detect` config keys. New `BundleSigDiscovery` module walks the target project's bundler install root and auto-feeds gem-shipped `sig/` directories into `signature_paths:`. Auto-detect reads `.bundle/config`'s `BUNDLE_PATH:` then falls back to `vendor/bundle/`. `SKIPPED_GEMS_BY_DEFAULT` set excludes gems already covered by `DEFAULT_LIBRARIES` + `data/vendored_gem_sigs/` so the prism-class conflict O7 surfaced doesn't recur. Verified on Mastodon: RBS classes 1,178 → 2,136 (+958) from 7 non-skipped gem sigs. Layer 3 (`Gemfile.lock` parse + `gem_rbs_collection` version matching) remains queued.
- **Engine narrowing** — assignment-in-condition (`if cond && (var = expr)`) now narrows the bound local; on Redmine alone, `call.possible-nil-receiver` 69 → 23 (−46 FPs).
- **rigor-activesupport-core-ext v2 (`compact_blank` / `exclude?` / `index_with` / `Hash.from_xml` / DateTime calculations)** from the round-2 (Forem / Solidus / Chatwoot / Canvas LMS / OpenProject) survey extension.

### Other v0.1.5 work landed

- **Spec-suite performance** — `Cache::Store` thread-safe + in-process memo + `parallel_tests` runner; suite wall-clock 162s → 27s on a 12-core dev machine (~6×).
- **`rigor check --stats` (default ON)** — end-of-run summary on stderr (check targets / type universe / gem source-walk / process).
- **`rigor-activerecord` extensions** — associations / enums / scopes / validations / callbacks all recorded on `ModelIndex::Entry`; `Model.where(enum_col: :unknown)` surfaces `unknown-enum-value`; `belongs_to` / `has_one` contribute `Nominal[Target] | nil` via `flow_contribution_for`.
- **`Method#curry` precision** through `Type::BoundMethod` (Open Engineering Item #5, Option A).
- **`rigor-activestorage` (Tier 3E)** — `has_one_attached :avatar` / `has_many_attached :photos` macro recognition + return-type narrowing via `flow_contribution_for`. Twentieth worked plugin under `examples/`.

### Pool / sequential equivalence cross-project summary

| Project | Files | Seq warm | Pool warm | Diagnostics (baseline → with O1 v2 → with vendored RBS) |
| --- | ---: | ---: | ---: | --- |
| Redmine | 347 | 2.82s | 3.70s (`w=4`) | 389 → 157 → 157 |
| Mastodon | 1,302 | 3.31s | 3.98s (`w=4`) | 521 → 124 → 124 |
| Forem | 1,250 | 4.31s | 4.60s (`w=4`) | 691 → 146 → 149 |
| Discourse | 1,804 | 7.46s | **5.82s** | 1,439 → 423 → 429 |
| Solidus | 1,914 | 7.36s | **4.91s** | 528 → 42 → 42 |
| Canvas LMS | 3,248 | 17.32s | **11.16s** | 3,296 → 1,496 → 1,506 |
| OpenProject | 6,817 | 18.84s | **10.24s** | 2,356 → 175 → 176 |
| GitLab FOSS | 11,130 | 25.27s | **15.43s** (`w=8`) | 2,982 → 489 → 491 |

(See survey notes for the remaining six smaller projects — Loomio, Publify, Diaspora, Chatwoot, Dependabot Core, tDiary Core.)

### Open items consolidated (post-survey)

| ID | Status | Item |
| --- | --- | --- |
| O1 | landed (MVP, v2) | `examples/rigor-activesupport-core-ext/` opt-in RBS bundle. |
| O2 | queued — ADR proposed | Macro-template / heredoc-Ruby expansion. tDiary's `instance_eval` plugin pattern is the motivating real-world case. Design now pinned in [ADR-16](adr/16-macro-expansion.md) (four-tier substrate); grounding survey at [`docs/notes/20260515-macro-expansion-library-survey.md`](notes/20260515-macro-expansion-library-survey.md). |
| O3 | not-an-issue | Early-exit narrowing (`next if x.nil?` / `return if x.nil?`) already works; survey residuals are mostly Object#blank?/present?/try which O1 covers. |
| O4 | layers 1+2 landed | Bundler awareness. Layer 3 (`Gemfile.lock` parse + `gem_rbs_collection` matching) queued. |
| O5 | landed (`ac14c45`) | `Hash[K, V] <: Enumerable[[K, V]]` projection. |
| O6 | landed (`4698437`) | Pool / seq precision divergence (CONSTANT_CONSTRUCTORS). |
| O7 | landed (`3c4a7ff`) | RBS env-build failure-memo (per-file slowdown on duplicate-decl). |

### Out of scope for v0.1.5

- **O2** (macro template / heredoc-Ruby expansion) — large design, deferred.
- **O4 Layer 3** (Gemfile.lock + gem_rbs_collection version matching) — queued for v0.1.6+ (no committed milestone).
- **`rigor-graphql`** (Tier 3 plugin) — author when there is concrete user demand.
- **dry-rb ecosystem plugins** — ADR-12 packaging decision pending.

## Future cycles (not committed to a specific release)

Items that have surfaced across v0.1.x work and that the next implementer benefits from seeing without re-reading the full thread.

### Type-language / engine
- **O2 — macro-template + heredoc-Ruby expansion.** Two related shapes: `.rb` files that are actually ERB-style code-generator templates (Rails generator output), and `class_eval <<~RUBY` heredoc-embedded Ruby. Both need parser-boundary changes that aren't a single-slice job. tDiary Core's `instance_eval`'d plugin files are the concrete motivating case (35 FP / file on legacy plugins). Design pinned in [ADR-16](adr/16-macro-expansion.md): four-tier substrate (block-as-method / trait-inlining-registry / heredoc-template / external-file) plus Concern re-targeting walker extension. Grounding survey at [`docs/notes/20260515-macro-expansion-library-survey.md`](notes/20260515-macro-expansion-library-survey.md). Implementation slicing authorised, no committed milestone.
- **Lightweight HKT (higher-kinded types) in DSL signatures.** Replace `untyped` boundaries with type-level `eval` per the `docs/type-specification/rigor-extensions.md` conditional / indexed-access rows. First reference site is the rigor-lisp-eval demo. Exploratory, no committed milestone.
- **`rigor:v1:conforms-to` directive.** Originally queued for v0.1.1's "Out of scope"; still open. Lets a method param accept any value satisfying a named structural interface.
- **LRU eviction for `Cache::Store`.** Per [ADR-6](adr/6-cache-persistence-backend.md), the persistent cache is sharded "no eviction" by design. Long-lived clones with config / dependency churn accumulate stale slots that only `make cache-clean` releases. LRU is queued, not committed.

### Plugins / ecosystem
- **`rigor-graphql`** — last remaining Tier 3 plugin. GraphQL schema DSL parsing is non-trivial; author when there is concrete user demand.
- **dry-rb adapter plugins** — packaging strategy (single gem vs family vs mid-grain bundles) needs an explicit ADR-12 decision before any individual plugin can be authored. Survey under [`docs/design/20260509-dry-plugins-roadmap.md`](design/20260509-dry-plugins-roadmap.md).
- **ADR-10 — per-call return-type precision from gem source.** Walker currently catalogs only `(class_name, method_name) → kind` triples. Inferring per-method return types from gem source (so `mode: :full` could contribute richer than `Dynamic[Top]`) is a larger walker enhancement deferred until concrete user demand surfaces.
- **`rigor-sorbet` follow-ups beyond per-call-site sigil gating** — landed in v0.1.4. No outstanding queue items.

### Performance / scalability
- **O4 Layer 3 — `Gemfile.lock` parse + `gem_rbs_collection` version matching.** Sits on top of v0.1.5's `BundleSigDiscovery` MVP. The MVP's auto-skip list (`SKIPPED_GEMS_BY_DEFAULT`) becomes a versioned resolution table; rigor consumes `Bundler::LockfileParser` output + queries `ruby/gem_rbs_collection` for the best-matching version. Unblocked by O7's failure-memo (conflicts now warn rather than hang).
- **Fork-based file-level parallelism for `rigor check`.** Stackprof of warm `rigor check lib` shows ~50% inference, ~22% `Marshal.load`, ~17% GC. The Phase 4b Ractor path is the v0.1.5 parallelism story; a fork-based path remains a parallel (non-exclusive) option for hosts where Ractors are unavailable or where COW sharing of pre-warmed `Environment` blobs would beat per-Ractor env build.
- **In-memory `Analysis::Runner.run_source` entry point (test-only).** The `RunnerHelpers#analyze` test helper materialises a tmpdir per call. At ~25-50ms per call × hundreds of runner-spec calls, an in-memory entry point could shave ~5% sequential / ~3% parallel from the suite. Not worth doing standalone, but a natural complement if test-suite expansion continues.

### Sig-gen (ADR-14)
- **`update_existing` does not yet collapse sibling parent / child class blocks.** Gap (c)'s tree-builder fix lives in `Writer#render_new_file` (the create-new path). When updating an existing target file, `merge_class` resolves each candidate's `class_name` independently — flat-sibling layouts stay flat. Re-flowing an existing file into the nested layout would require parsing the existing decl tree and rewriting it, which is out of scope for a follow-up fix. Users who want the canonical nested layout regenerate from scratch (delete the target sig file and rerun).

### Open research questions queued in ADRs
- **ADR-15 § OQ1** — per-Ractor `Cache::Store`-shared facade. Today each worker builds its own RBS env from cache; OQ1 explores sharing the in-memory env across workers via a shareable facade. Would lower the pool wall-clock crossover with sequential (currently around 1.3–1.8 K files).
- **ADR-13 § "Open questions"** — extending the shape-projection surface beyond the five core functions (`pick_of` / `omit_of` / `partial_of` / `required_of` / `readonly_of`). Authoritative when adding new mapped-type vocabulary.

## Rails ecosystem plugins (running track, parallel to v0.1.x core work)

The full roadmap is in [`docs/design/20260508-rails-plugins-roadmap.md`](design/20260508-rails-plugins-roadmap.md). Summary of the running track:

**Already landed (released through v0.1.4 / accumulating on `master` for v0.1.5):**

- **Tier 1**: [`rigor-rails-routes`](../examples/rigor-rails-routes/) (publishes `:helper_table`), [`rigor-rails-i18n`](../examples/rigor-rails-i18n/), [`rigor-actionmailer`](../examples/rigor-actionmailer/), [`rigor-activejob`](../examples/rigor-activejob/).
- **Tier 2**: [`rigor-activerecord`](../examples/rigor-activerecord/) (publishes `:model_index`; associations / enums / scopes / validations / callbacks all landed in v0.1.5); [`rigor-actionpack`](../examples/rigor-actionpack/) (4 phases: routes / filters / renders / strong-params); [`rigor-factorybot`](../examples/rigor-factorybot/) (Phase 1 (a) + (c)).
- **Tier 3**: [`rigor-pundit`](../examples/rigor-pundit/), [`rigor-sidekiq`](../examples/rigor-sidekiq/), [`rigor-rspec`](../examples/rigor-rspec/), [`rigor-actioncable`](../examples/rigor-actioncable/), [`rigor-activestorage`](../examples/rigor-activestorage/) (landed v0.1.5).
- **Opt-in non-plugin bundles**: [`rigor-activesupport-core-ext`](../examples/rigor-activesupport-core-ext/) (v0.1.5; opt-in RBS bundle for top ~50 AS core_ext selectors). [`rigor-typescript-utility-types`](../examples/rigor-typescript-utility-types/) (ADR-13 slice 6).

**Pending Tier 3 (specialised, author when there is concrete user demand):**

- `rigor-graphql`.

Each plugin is staged in `examples/rigor-<id>/` per the [`rigor-plugin-author`](../.codex/skills/rigor-plugin-author/SKILL.md) SKILL discipline and extracted via `git subtree split` once its contract is stable. The eventual `rigor-rails` meta-gem will declare the Tier 1+2 plugins as gem dependencies so a single Gemfile line opts the user into the whole stack.

[ADR-9](adr/9-cross-plugin-api.md) (cross-plugin API) landed in v0.1.4 via the `:helper_table` (rails-routes → actionpack) and `:model_index` (activerecord → actionpack + factorybot) publish-and-consume cycles. Slicing per ADR-9 § "Implementation slicing" allows partial landings.
