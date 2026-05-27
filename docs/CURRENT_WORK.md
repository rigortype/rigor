# Current Work — Resume Bookmark

A transient bookmark for the next implementer: the immediate next-session entry point plus engine-internal items not fully captured elsewhere. The **normative** contracts live in [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md) and [`docs/adr/4-type-inference-engine.md`](adr/4-type-inference-engine.md); the forward-looking commitment envelope (release strategy + full backlog) lives in [`docs/ROADMAP.md`](ROADMAP.md); the released-version record is [`CHANGELOG.md`](../CHANGELOG.md). If this file disagrees with any of those, the spec / ADR / roadmap binds and this file is out of date.

## Status

**v0.1.11 released (2026-05-27).** Version bumped, CHANGELOG sealed, `make verify` passes. **`bundle exec rake release` has not yet been run** — publication to RubyGems requires explicit authorisation.

`[Unreleased]` carries one post-v0.1.11 slice (2026-05-27): **`rigor plugins` activation-readiness command** — the Mastodon investigation surfaced a silent-failure surface where running `rigor check` with the wrong cwd or Gemfile context leaves configured plugins inert, so the false positives that follow get attributed to "missing types" rather than to a config gap (the original 1271-error Mastodon run came from rigor's own `.rigor.dist.yml` being used instead of mastodon's, not from any genuine engine miss). Shape: per-plugin status row (loaded / load-error) plus every manifest-declared extension surface (`signature_paths:` with per-directory `.rbs` count, `open_receivers:`, `owns_receivers:`, `produces:`, `consumes:`, macro-substrate counts, `protocol_contracts:`, `source_rbs_synthesizer:`, `type_node_resolvers:`, HKT registration counts). `--format json` for tooling, `--strict` exits 1 on any load error (CI gate shape). Companion changes: `rigor init` now prints a "Next steps" hint pointing at `rigor plugins`; `rigor-project-init` SKILL Phase 4 ([`skills/rigor-project-init/references/02-configure.md`](../skills/rigor-project-init/references/02-configure.md) § "Verify plugin activation") gained a verification sub-step with a load-error → cause → fix table.

v0.1.11 recaps two back-to-back patch cycles of real-world trial work:

- **v0.1.10** (2026-05-27) — `rigor mcp --transport stdio` (ADR-33, seven read-only tools); `rigor sig-gen --params=observed` attr_reader inference; `rigor coverage` precision gate; `rigor check --treat-all-as-inline-rbs`; `rigor-rbs-inline` plugin (ADR-32); browser playground (ADR-29 slices 1–4); `rigor annotate` return-type annotation; ADR-28 path-scoped protocol contracts + `rigor-hanami`; constant folding (Date/DateTime/Time, Math, String/Integer/Float mid-priority, Hash shape handlers); `return if @ivar.nil?` ivar-guard narrowing fix.
- **v0.1.11** (2026-05-27) — Plugin bundling into `rigortype` gem; portable baseline paths; `rigor-rails-routes` **five false-positive sources eliminated** (grounded in kaigionrails conference-app + Mastodon trials): `new_`/`edit_` prefix order, anonymous-`get` route registration, `scope as:` prefix + arity, `draw(:name)` partial loading, `concern` body no-op, trailing options-hash +1 arity rule; `rigor-rails-i18n` lazy translation keys in controllers; Rails quickstart manual ([`docs/manual/14-rails-quickstart.md`](manual/14-rails-quickstart.md)).

The release-line plan is in [`docs/ROADMAP.md`](ROADMAP.md) § "Release strategy — the road to v0.2.0". v0.1.9 was the designated "last preview cut" but the trail work extended the preview line to v0.1.10 / v0.1.11; v0.2.0 remains the next named milestone (first evaluation / publicly-announced release).

## Mastodon trial — outcome summary (2026-05-27)

`/Users/megurine/repo/ruby/mastodon` is fully configured:

- `.rigor.dist.yml` written (all relevant Rails plugins active, `severity_profile: lenient`)
- `.rigor-baseline.yml` generated — 1258 buckets covering 2496 diagnostics
- `rigor check` exits clean with the baseline active

Starting from 590 errors pre-fixes, the v0.1.11 routes improvements brought the error count to 301 (zero `wrong-arity`). Remaining 217 `unknown-helper` diagnostics are structural (devise_for, concern-injected routes) and cleanly in the baseline.

Genuine bugs surfaced: `instances.domain` unknown column ×3, `NotificationMailer` action misuse ×2, missing view template ×1, missing i18n key ×1, Pundit info ×2. These are in the baseline at threshold 0 and will surface again when any file that contains them is edited.

The OSS sweep CI job (`.github/workflows/oss-sweep.yml`) will need its stored thresholds refreshed after the v0.1.11 publish so the weekly gate reflects the new diagnostic count.

## Open engineering items

Engine-internal items the next implementer benefits from seeing directly. The full demand-driven backlog (editor mode, LSP capabilities, dry-rb continuations, ADR-10/13/16 follow-ups, performance levers) lives in [`docs/ROADMAP.md`](ROADMAP.md) § "Future cycles" and is, under the new plan, the v0.2.x completion target. This section holds only items with engine-internal detail not captured there.

### ADR-24 — implicit-self method-call resolution, remaining

- **Slice 4** — gated `undefined-method` / arity diagnostics on resolved closed-class self-calls. Its own FP-evaluation gate ([ADR-24 WD4](adr/24-self-method-call-resolution.md)) — a large new false-positive surface on metaprogramming-dense code, so v1 was deliberately precision-additive only.
- **Non-`Bot` general adoption inside class bodies** — resolved self-call return type is adopted ONLY when it is `Bot`. Unconditional adoption of precise non-`Bot` returns regressed `rigor check lib` by 16 diagnostics (pre-existing callee-return-inference imprecisions surfacing downstream); this follow-up needs callee-return inference precise enough that adopting precise types does not surface those imprecisions.

### ADR-23 — `rigor triage` slice 4 plugin recognisers

Remaining: a `Plugin` hook letting plugins contribute their own recognisers (deferred). (`receiver_type` / `method_name` structured fields on `Analysis::Diagnostic` shipped in v0.1.8; the SKILL integration shipped with the v0.1.9 trio.)

### Flow-folding — loop-mutation tracking (gaps G1 / G2)

`rigor check lib` surfaces 3 `flow.always-truthy-condition` warnings of the shape `arr = [seed]; while …; arr << x; end; if arr.size == N` — `Inference::Narrowing` does not reflect a loop body's `<<` / `push` mutation into the size / empty narrowing. Sites: [`hkt_body_parser.rb:140`](../lib/rigor/inference/hkt_body_parser.rb), `:307`, [`hkt_registry.rb:212`](../lib/rigor/inference/hkt_registry.rb). The Mastodon Cluster 4 triage ([`docs/notes/20260521-mastodon-cluster4-flow-folding-triage.md`](notes/20260521-mastodon-cluster4-flow-folding-triage.md)) adds 3 more `loop` / `retry` warnings of this exact shape (gap **G1**) plus sibling gap **G2** — an ivar's type is taken from its literal writes and is not invalidated by an intervening method call / in-place `<<` / read-before-write `nil`. Both live under `docs/type-specification/control-flow-analysis.md` § "mutation effects"; a medium engine change, queued. The 3 self-check warnings are `:warning` (not `:error`), so `rigor check lib` stays clean for release purposes.

### Stdlib RBS coverage-gap pattern

When an upstream `ruby/rbs` RBS gap is surfaced by a single internal Rigor call site, prefer **(a')** an in-source `# rigor:disable` directive + load the library; when it surfaces across multiple call sites or in user-facing code, escalate to **(b)** a focused RBS overlay under Rigor's own `sig/`, or **(c)** an upstream `ruby/rbs` fix. The `references/rbs` branch `widen-strscan-resolv-stdlib-sigs` (widens `StringScanner#[]`, `Resolv#initialize`) is staged for an upstream PR — branch push + `ruby/rbs` PR creation are the user's task.

### Mastodon cross-version sweep — FP findings (2026-05-23)

The v3.5.19→v4.5.10 cross-version regression sweep ([`docs/notes/20260523-mastodon-v4.5-regression-sweep-v0.1.9.md`](notes/20260523-mastodon-v4.5-regression-sweep-v0.1.9.md) § "What is increasing") isolated four engine-side false-positive / misinference clusters. Two are already tracked; two are new:

1. **`StringScanner#[]` Symbol overload** (FP, 3 sites in `signature_parser.rb`) — `scanner[:key]` (a Ruby 3.x named-capture Symbol arg) trips `call.argument-type-mismatch` because Rigor's RBS has only `(Integer) -> String?`. **Already covered** by the "Stdlib RBS coverage-gap pattern" item above — the `references/rbs` branch `widen-strscan-resolv-stdlib-sigs` widens exactly this. The sweep is empirical confirmation; close it when the upstream RBS PR lands.
2. **AR `scope`-body method resolution** (misinference, NEW) — inside `scope :x, -> { select(...).group(:uri) }` the lambda's `self` is the model class, but `select` resolves to `Enumerable#select` (→ `Array[String]`) instead of `ActiveRecord::Querying#select` (→ a relation), so a chained `.group` reads as `undefined-method`. The empirical case for **ADR-26** (`ActiveRecord::Relation` typing); also note the model class-side query surface is the `rigor-activerecord` plugin's job. No new ADR needed — fold into ADR-26 slicing.
3. **Ivar nil-guard / ivar-write typing** (misinference, **FIXED 2026-05-26**) — `@ivar.method` after `return if @ivar.nil?` no longer reports `undefined-method … for nil` when the ivar is seeded `Constant[nil]`. Root cause: `live_branch_for_if` short-circuited when `@ivar.nil?` folded to `Constant[true]`, returning the un-narrowed `post_pred` scope as continuation and bypassing the `branch_terminates?` falsey-scope narrowing. Fixed in `statement_evaluator.rb` `eval_if` / `eval_unless` (commit `36d6b1f`). The case where the ivar's non-nil assignment is in a parent class (invisible to the per-file accumulator) is still a miss — addressed once the parent-class accumulator crosses the project-file boundary (ADR-24 slice 2 / cross-file class registry). Remaining: ivar-write-inference via G2 (see "Flow-folding" item below).
4. **Flow-folding over-claim** (FP, 3 `flow.always-truthy-condition` sites) — **already tracked** by the "Flow-folding — loop-mutation tracking (gaps G1 / G2)" item above + the cluster-4 triage note. The sweep confirms the cluster persists across the v3.5→v4.5 line.

### Smaller queued items

- **Sig-gen `update_existing`** does not collapse sibling parent / child class blocks — `merge_class` resolves each candidate's `class_name` independently, so flat-sibling layouts stay flat. Re-flowing an existing file into the nested layout is out of scope; workaround is to delete the target sig file and regenerate from scratch.
- **`Hash === expr` case-equality narrowing** (`open3.rb:226` shape) — still open.
- **In-memory `Analysis::Runner.run_source(source:, path:, …)` entry point** — bypasses the per-call tmpdir + chdir in `RunnerHelpers#analyze`; ~5 % spec-suite win plus a clean public API for embedders (LSP / editor mode). Demand-driven.
- **Sig-gen remaining gaps after `--params=observed`** — `attr_reader` with ivars set from non-`initialize` sources (DB reads, config, side effects) still produce `:untyped_return`; fix is a hand-written sig annotation. Deep chains on untyped receivers → `rbs collection install` or ADR-10 `source_inference:`. Dynamic methods (`define_method`, DSL macros) → project plugin (escalation path A in the SKILL). These are documented in `skills/rigor-project-init/references/04-sig-uplift.md` § "Step 5-d" and are the natural next action after `--params=observed` still leaves gaps.

### Type-coverage uplift — line status (2026-05-23)

Phases 1–4 landed (String / Integer / Float / Comparable / Math / HashShape / Date / DateTime / Time). Remaining items, all **release undetermined**:

- **Struct / Data value folding** — deferred ADR-worthy feature (needs two new carriers). See `docs/ROADMAP.md` § "Future cycles" → "Type-language / engine" and [`docs/notes/20260523-struct-encoding-coverage.md`](notes/20260523-struct-encoding-coverage.md). `Encoding` value folding recorded in the same audit as a *permanent exclusion*.
- **`MathFolding` result refinements** — the 28-function fold is value-precise; attaching range refinements to the results (`Math.exp` → `positive-float`, `Math.sqrt` / `hypot` → `non-negative-float`) is the demand-driven follow-up ([`docs/notes/20260522-stdlib-deterministic-module-coverage.md`](notes/20260522-stdlib-deterministic-module-coverage.md) § 1).
- **Hash `rassoc` shape handler** — the one open low-priority Hash handler ([`docs/notes/20260522-hash-method-coverage.md`](notes/20260522-hash-method-coverage.md)); value → `[k, v]` reverse lookup, foldable when every value is a `Constant`. Demand-driven.

## Reading order for a returning implementer

**`[Unreleased]` is empty. v0.1.11 is code-complete; `bundle exec rake release` is the next action (requires explicit user authorisation).** Read in this order:

1. `CHANGELOG.md` § `[0.1.11]` and `[0.1.10]` — full recap of the last two patch cycles.
2. [`docs/ROADMAP.md`](ROADMAP.md) § "Release strategy — the road to v0.2.0" — what gates the next named milestone.
3. [`docs/manual/14-rails-quickstart.md`](manual/14-rails-quickstart.md) — the new Rails onboarding guide; reflects the kaigionrails + Mastodon trial findings.
4. [`docs/adr/22-baseline-and-project-onboarding.md`](adr/22-baseline-and-project-onboarding.md) — baseline mechanism + SKILL trio (WD8); the `rigor-project-init` / `rigor-baseline-reduce` / `rigor-plugin-author` external-user SKILLs under `skills/` all landed.
5. [`docs/adr/23-diagnostic-triage-command.md`](adr/23-diagnostic-triage-command.md) — `rigor triage`; WD5 / slice 3 (SKILL data-layer contract) landed; slice 4 plugin-contributed recognisers deferred.
6. [`docs/internal-spec/public-api.md`](internal-spec/public-api.md) — the public-vs-internal stability boundary. v0.2.0 stabilises the plugin-contract surface for external `rigor-*` gems, so cross-reference `spec/rigor/public_api_drift_spec.rb` before extending any pinned namespace.
7. [`docs/adr/2-extension-api.md`](adr/2-extension-api.md) — the plugin contract v0.2.0 must stabilise.
