# Current Work — Inference Engine Checkpoint

This is a transient bookmark used to break a long implementation thread into reviewable chunks. The **normative** contracts and slice roadmap remain in [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md) and [`docs/adr/4-type-inference-engine.md`](adr/4-type-inference-engine.md). The forward-looking commitment envelope (active cycle + queued work) lives in [`docs/ROADMAP.md`](ROADMAP.md); the released-version record is `CHANGELOG.md`. If this file disagrees with any of those, the spec / ADR / roadmap binds and this file is out of date.

## Status

**v0.1.4 released (2026-05-14).** Slice-by-slice recap in `CHANGELOG.md` § `[0.1.4]`. The full v0.1.0 → v0.1.4 release log lives in `CHANGELOG.md`; the planning envelopes that shaped each cut are preserved in git history (see `docs/MILESTONES.md` at the commit that renamed it to `ROADMAP.md`).

**v0.1.5 accumulating on `master` (release pending).** Two interlocking themes:

1. **Ractor migration end-to-end + spec-suite performance wins.** ADR-15 Phases 1, 2a, 2b, 3a, 4a, 4b, 4b.x, 4c all landed; `Cache::Store` thread-safe + in-process memo + `parallel_tests` runner drops suite wall-clock 162s → 27s on a 12-core dev machine.
2. **Real-world Rails / Ruby survey + production-rigor improvements.** Fourteen projects swept across three rounds (Redmine / Discourse / Mastodon / GitLab FOSS / Forem / Solidus / Chatwoot / Canvas LMS / OpenProject / Loomio / Publify / Diaspora / Dependabot Core / tDiary Core — 31,840 files total). Survey + measurements + open-item inventory live in [`docs/notes/20260515-real-world-rails-survey.md`](notes/20260515-real-world-rails-survey.md). Eight engine / packaging improvements landed off the survey: `examples/rigor-activesupport-core-ext/` opt-in RBS bundle, `data/vendored_gem_sigs/` built-in RBS for six native-extension gems, `bundler.bundle_path` / `auto_detect` Bundler awareness, assignment-in-condition narrowing, four deep-shareability follow-ups for the Ractor pool, the `Hash[K, V] <:= Enumerable[[K, V]]` projection, the `CONSTANT_CONSTRUCTORS` Proc-share fix, and the `RbsLoader#env` failure-memo (~550× speedup on a conflicting `signature_paths:` entry).

The pool path is now production-ready: **pool ≡ sequential proven on all 14 survey projects** (zero `Ractor::IsolationError` across the 31,840 swept files); pool wall-clock crossover with sequential sits around 1.3–1.8 K files; GitLab FOSS (11.1 K files) shows pool=8 at 1.64× sequential.

Every committed v0.1.5 track is purely additive (no behaviour change for existing CLI consumers); the Ractor work is staged so each phase is independently revert-able.

## Where the Work Resumes

The default goal for the next session is **cut a v0.1.5 release**. The Ractor migration is feature-complete (Phases 1–4c + 4b.x), the v0.1.3 / v0.1.4 deferred ecosystem items are closed (`rigor-activestorage`, rigor-activerecord extensions, `Method#curry`), the real-world Rails survey produced shipped improvements (vendored gem RBS, ActiveSupport core_ext opt-in bundle, Bundler awareness layers 1+2), and four cliff-grade bugs are resolved (O5 / O6 / O7 plus the assignment-in-condition narrowing). `bundle exec rake release` per [`.codex/skills/rigor-release-prep/SKILL.md`](../.codex/skills/rigor-release-prep/SKILL.md) awaits explicit user authorisation.

If continuing implementation instead of releasing, the natural entries are:

1. **O4 Layer 3** — `Gemfile.lock` parse + `gem_rbs_collection` version matching, on top of the v0.1.5 Bundler-awareness MVP. Layer 1 (`bundler.bundle_path`) + Layer 2 (`.bundle/config` / `vendor/bundle` auto-detect) landed in `95b923f`; Layer 3 turns the auto-skip list (`SKIPPED_GEMS_BY_DEFAULT`) into a versioned resolution table sourced from `Gemfile.lock` + `gem_rbs_collection`.
2. **O2 — macro template / heredoc-Ruby expansion.** The tDiary Core round-3 sweep surfaced `instance_eval`'d plugin files (`misc/plugin/category-legacy.rb`) where the receiver class isn't visible from the `def` site (35 false-positives on `pp.month=` / `pp.year=`). Rails-generator `.rb`-as-ERB templates are the adjacent motivating case. Requires a parser-level design; no committed milestone yet.
3. **Per-call return-type precision from gem source** (ADR-10 walker enhancement). Carried over from v0.1.3 / v0.1.4. Walker currently catalogs only `(class_name, method_name) → kind`; richer per-method return types would let `mode: :full` contribute precise types rather than `Dynamic[top]`.
4. **`rigor-graphql`** (last Tier 3 ecosystem plugin). Author when there is concrete user demand.
5. **dry-rb adapter plugins** ([`docs/design/20260509-dry-plugins-roadmap.md`](design/20260509-dry-plugins-roadmap.md)) — packaging strategy (single gem vs family vs mid-grain bundles) needs an explicit ADR-12 decision first.

## Open Engineering Items

Persistent items the next implementer benefits from seeing without re-reading the full thread. Items already absorbed into a released milestone are referenced through `CHANGELOG.md` rather than restated.

### Survey-driven (v0.1.5 cycle)

The fourteen-project real-world Rails survey ran through three rounds during the v0.1.5 cycle. Items O1, O5, O6, O7 are closed (see `docs/ROADMAP.md` § "v0.1.5 — accumulating on master"); O4 layers 1+2 landed and Layer 3 stays queued; O2 stays queued; O3 turned out to be not-an-issue (the early-exit narrowing already worked — survey residuals were Object#blank? / present? / try, which O1's RBS bundle covers).

| ID | Status | Item |
| --- | --- | --- |
| O1 | landed (MVP, v2) | `examples/rigor-activesupport-core-ext/` opt-in RBS bundle for the top ~50 ActiveSupport `core_ext` selectors. v2 added `compact_blank` / `exclude?` / `index_with` / `Hash.from_xml` / `DateTime` calculations after the round-2 sweep. |
| O2 | queued | Macro-template / heredoc-Ruby expansion. tDiary's `instance_eval` plugin pattern is the concrete motivating case (35 FP / file on legacy plugins). Adjacent: Rails-generator `.rb`-as-ERB templates. |
| O3 | not-an-issue | Early-exit narrowing (`next if x.nil?` / `return if x.nil?`) already worked; survey residuals were `Object#blank?` / `#present?` / `#try`, which O1 covers. |
| O4 | layers 1+2 landed | Bundler awareness. `bundler.bundle_path` (explicit) + `bundler.auto_detect` (`.bundle/config` / `vendor/bundle/`) + `SKIPPED_GEMS_BY_DEFAULT` filter against rigor's `DEFAULT_LIBRARIES` + `data/vendored_gem_sigs/`. Layer 3 (`Gemfile.lock` parse + `gem_rbs_collection` version matching) queued. |
| O5 | landed (`ac14c45`) | `Hash[K, V] <:= Enumerable[[K, V]]` parametrized-ancestor projection in `Inference::Acceptance#accepts_nominal_from_nominal`. Hand-rolled mapping for Hash → Enumerable today; general RBS-driven `definition.ancestors[i].args` projection deferred. |
| O6 | landed (`4698437`) | `MethodDispatcher::CONSTANT_CONSTRUCTORS` deep-share (Proc values were not shareable under shallow `.freeze`). Pool ≡ sequential on GitLab FOSS after fix. |
| O7 | landed (`3c4a7ff`) | `RbsLoader#env` memoises failure. Pre-fix, a single conflicting `signature_paths:` entry rebuilt env per AST node (390× / file, ~35 s for one controller). Post-fix: 0.15 s for 5 controllers (~550× speedup) with a single user-facing warning naming the offending file. Unblocks O4 Layer 3 — gem-shipped sigs that conflict with stdlib RBS now degrade gracefully. |

### Pre-survey persistent items

1. **Sig-gen `update_existing` does not yet collapse sibling parent / child class blocks.** Gap (c)'s tree-builder fix lives in `Writer#render_new_file` (the create-new path). When updating an existing target file, `merge_class` still resolves each candidate's `class_name` independently — if both `Foo::Bar` and `Foo::Bar::Child` decls already exist as flat siblings, sig-gen leaves them flat. Re-flowing an existing file into the nested layout would require parsing the existing decl tree and rewriting it, which is out of scope for a follow-up fix. Users who want the canonical nested layout regenerate from scratch (delete the target sig file and rerun).
2. **In-memory `Analysis::Runner.run_source` entry point (test-only perf follow-up).** The `RunnerHelpers#analyze` test helper materialises a tmpdir per call (write source file, chdir, run, clean up). At ~25-50ms per call × hundreds of runner-spec calls, that's a real share of suite wall-clock that an in-memory entry point could eliminate. Sketch: add `Runner.run_source(source:, path: "code.rb", environment:, config:)` that bypasses path expansion and accepts a `{path => bytes}` virtual file table. The helper would call it for the `analyze(source: "...")` shape (no files / sig). Expected delta: ~5% sequential, ~3% parallel — not worth doing standalone, but a natural complement if test-suite expansion continues.
3. **Fork-based file-level parallelism for `rigor check`.** Stackprof of warm `rigor check lib` shows ~50% inference, ~22% `Marshal.load`, ~17% GC. The Phase 4b Ractor path handles the parallelism story for v0.1.5; a fork-based path remains a parallel (non-exclusive) option for hosts where Ractors are unavailable or where COW sharing of pre-warmed `Environment` blobs would beat per-Ractor env build. Implementation sketch: `Runner#run` forks workers per file-chunk, each writes diagnostics to a pipe, parent re-assembles in original path order.

## Reading Order for a Returning Implementer

The default goal for the next session is "cut the v0.1.5 release". Read in this order:

1. `CHANGELOG.md` `[Unreleased]` section — accumulates v0.1.5 work as it lands.
2. [`docs/notes/20260515-real-world-rails-survey.md`](notes/20260515-real-world-rails-survey.md) — fourteen-project real-world survey + open items + per-round measurements.
3. [`docs/ROADMAP.md`](ROADMAP.md) § "v0.1.5 — accumulating on master" — full v0.1.5 envelope (Ractor migration + survey + production-rigor improvements).
4. [`docs/adr/15-ractor-concurrency.md`](adr/15-ractor-concurrency.md) + [`docs/design/20260514-ractor-migration.md`](design/20260514-ractor-migration.md) — binding contract + staged plan for the Ractor migration.
5. [`docs/adr/10-dependency-source-inference.md`](adr/10-dependency-source-inference.md) — design rationale for the dependency-source inference tier; Layer 3 of O4 (Gemfile.lock + gem_rbs_collection matching) extends this surface.
6. [`docs/adr/9-cross-plugin-api.md`](adr/9-cross-plugin-api.md), [`docs/adr/11-sorbet-input-adapter.md`](adr/11-sorbet-input-adapter.md), [`docs/adr/13-typenode-resolver-plugin.md`](adr/13-typenode-resolver-plugin.md), [`docs/adr/14-rbs-sig-generation.md`](adr/14-rbs-sig-generation.md) — sibling ADRs landed in v0.1.x.
7. [`docs/design/20260508-rails-plugins-roadmap.md`](design/20260508-rails-plugins-roadmap.md) — Rails plugin family ordering, dependency graph, subtree-split readiness checklist.
8. [`.codex/skills/rigor-plugin-author/SKILL.md`](../.codex/skills/rigor-plugin-author/SKILL.md) — agent-facing playbook for authoring a new plugin.
9. [`docs/internal-spec/public-api.md`](internal-spec/public-api.md) — public-vs-internal stability boundary. Cross-reference `spec/rigor/public_api_drift_spec.rb` before extending any pinned namespace.
10. [`examples/README.md`](../examples/README.md) — comparison table over the twenty-one worked plugin / RBS-bundle examples; recommended reading order for new authors.
11. [`docs/adr/2-extension-api.md`](adr/2-extension-api.md) and [`docs/adr/7-v0.1.0-slice-decisions.md`](adr/7-v0.1.0-slice-decisions.md) — the binding design and per-slice working decisions for the v0.1.0 plugin contract that v0.1.x extends.
12. [`docs/adr/3-type-representation.md`](adr/3-type-representation.md) Working Decisions — OQ1 / OQ2 / OQ3 outcomes still bind the type-object public surface plugins consume.
13. [`data/vendored_gem_sigs/README.md`](../data/vendored_gem_sigs/README.md) — design rationale for the built-in native-extension RBS bundle (why default-on rather than opt-in, contrast with the ActiveSupport core-ext bundle).

The slice-3b surface (`lib/rigor/rbs_extended.rb`, `lib/rigor/rbs_extended/reporter.rb`, `lib/rigor/builtins/imported_refinements.rb`, `lib/rigor/environment.rb`, `lib/rigor/analysis/runner.rb`) is wired end-to-end — consult those when authoring follow-ups that need the reporter or the per-run `name_scope`. The v0.1.5 Bundler-awareness surface (`lib/rigor/environment/bundle_sig_discovery.rb`, `lib/rigor/configuration.rb` § "bundler", `lib/rigor/environment.rb` § `for_project`) is the entry point for O4 Layer 3 follow-up work.
