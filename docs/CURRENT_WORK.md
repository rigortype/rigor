# Current Work — Resume Bookmark

A transient bookmark for the next implementer: the immediate next-session entry point plus engine-internal items not fully captured elsewhere. The **normative** contracts live in [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md) and [`docs/adr/4-type-inference-engine.md`](adr/4-type-inference-engine.md); the forward-looking commitment envelope (release strategy + full backlog) lives in [`docs/ROADMAP.md`](ROADMAP.md); the released-version record is [`CHANGELOG.md`](../CHANGELOG.md). If this file disagrees with any of those, the spec / ADR / roadmap binds and this file is out of date.

## Status

**v0.1.8 released (2026-05-21).** Recap in `CHANGELOG.md` § `[0.1.8]` — the Mastodon-survey false-positive-reduction cycle: ADR-15 fork-based worker pool (the active `workers > 0` backend), ADR-23 `rigor triage` (slices 1+2+4), ADR-24 implicit-self method-call resolution (slices 1+2+3 + included/prepended-module resolution), the explicit-receiver private-method resolution fix, and survey-driven plugin fixes (`rigor-activerecord` v0.2.0, `rigor-activesupport-core-ext`).

The release-line plan is recorded in [`docs/ROADMAP.md`](ROADMAP.md) § "Release strategy — the road to v0.2.0":

- **v0.1.9** — the last preview cut, a near-complete (準完成版) release.
- **v0.2.0** — the first evaluation release: publicly announced, intended for real-product trial deployment (not a formal / GA version).
- **v0.2.x** — the evaluation line; the goal is to bring every planned feature to high completion **except the Ractor concurrency track** (parked behind the fork pool / ADR-15 § OQ1).

## Next entry — v0.1.9 (last preview cut)

v0.1.9 closes the preview-track commitments so v0.2.0 starts the evaluation line from a near-complete base. All committed deliverables plus two additional improvements have **LANDED** on `master` (`[Unreleased]` in `CHANGELOG.md`); v0.1.9 is ready to cut once the version bump is authorised.

1. **External-user SKILL trio** ([ADR-22 § WD8](adr/22-baseline-and-project-onboarding.md)) — **complete, updated.** Three SKILLs aimed at Rigor newcomers running `gem install rigortype` against their own projects, under the top-level `skills/` tree (agentskills.io portable conventions, `waza check` spec-compliant, public CLI surface only):
   - `skills/rigor-project-init/` — first-time onboarding: Gemfile / Gemfile.lock walk → propose a plugin set → **adoption-mode choice** (acknowledge / baseline vs. strict) → write `.rigor.dist.yml` → **[new] generate initial RBS sigs + `--params=observed` attr_reader precision uplift** → run `rigor triage --format json` → (acknowledge mode) write `.rigor-baseline.yml` + the `baseline:` config line → surface likely real bugs → offer the two escalation paths (project plugin / Rigor issue). SKILL.md + **four** `references/` modules (added `04-sig-uplift.md` covering Phase 5; triage / baseline / bugs now phases 6–8).
   - `skills/rigor-baseline-reduce/` — ongoing-quality: prioritise with the `rigor triage` hints + `rigor baseline dump` → walk `.rigor-baseline.yml` rule-by-rule → sample sites → classify (real bug / stylistic-safe / FP) → fix / `# rigor:disable` / open a Rigor issue → `rigor baseline drift` + `regenerate`. SKILL.md + two `references/` modules.
   - `skills/rigor-plugin-author/` — external-author variant of the plugin-authoring workflow (distinct from the `.claude/skills/rigor-plugin-author/` contributor SKILL): authoring a `rigor-`-prefixed gem or project-private plugin against the published `rigortype` API; threads the pre-1.0-contract caveat. SKILL.md + three `references/` modules.
2. **ADR-22 baseline slice 5** — **complete.** `rigor baseline regenerate` (unconditional rewrite) + the `rigor check --baseline-strict` CI gate (fails on any drift, including deficit drift). The `rigor baseline {generate, regenerate, dump, drift, prune}` family is now whole.
3. **Sig-gen `--params=observed` attr_reader inference** — **LANDED** (commit `f2aa8de`). `rigor sig-gen --params=observed --write` now resolves `attr_reader` / `attr_writer` / `attr_accessor` methods whose `@ivar` is assigned from an `initialize` parameter. Previously `ScopeIndexer` evaluated `@name = name` in a blank scope (parameter resolves to `Dynamic[top]` → ivar stays `untyped` → method skipped as `:untyped_return`). Fix lives entirely in `Generator` to keep `inference/` and `sig_gen/` decoupled: `build_observed_ivar_map` / `collect_init_ivar_obs` / `ivar_obs_from_initialize` / `build_ivar_obs_type_map` / `collect_param_obs_types`. Observation-driven fallback in `ivar_type_lookup` activates only when scope-inferred type is nil or `Dynamic[top]`. Zero overhead on non-observed runs (`@observations.empty?` guard). Important empirical finding from the bootstrap measurement experiment: iterative `sig-gen --write` → re-measure does NOT improve `untyped` returns (written `@name: untyped` → next pass sees `equivalent` → type stays untyped); the fix must come from the observation infrastructure, which this commit provides.
4. **TypeProf compatibility spec** — **LANDED** (commit `90e4a5a`). `spec/rigor/sig_gen/typeprof_compat_spec.rb` asserts Rigor covers ≥ all methods TypeProf recognises and returns a type at least as specific for every shared method. Four fixtures from the upstream TypeProf scenario corpus. Key insight encoded: TypeProf uses nominal class names for literals (String, Integer); Rigor emits RBS literal types ("hello", 42) which are more specific.

`rigor triage` slice 3 (SKILL integration — [ADR-23 WD5](adr/23-diagnostic-triage-command.md)) landed with the trio: `rigor-project-init` Phase 6 (was Phase 5 before the sig-uplift insertion) and `rigor-baseline-reduce` Phase 1 both consume `rigor triage --format json` instead of ad-hoc LLM counting. ADR-23's only remaining carry-over is the deferred plugin-contributed-recogniser hook (slice 4 second half).

The v0.1.7 / v0.1.8 cycles were the lead-up — collecting real-project error data so the SKILL trio's plugin / severity / baseline-rule defaults rest on empirical evidence.

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
3. **Ivar nil-guard / ivar-write typing** (misinference, NEW) — `@ivar.method` *after* `return if @ivar.nil?` still reports `undefined-method … for nil`: the guard does not narrow the ivar and the ivar's non-`nil` assignment is invisible to inference, so the type collapses to `nil`. Same family as flow-folding gap **G2** (ivar type taken from literal writes, not refreshed). Needs an ivar-narrowing + ivar-write-inference fix; scope against the G2 work below.
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

The v0.1.9 SKILL trio + ADR-22 baseline slice 5 + sig-gen attr_reader observation inference have all landed on `master`. The **immediate next task** is updating `CHANGELOG.md § [Unreleased]` to record the sig-gen improvement and TypeProf compat spec, then cutting the v0.1.9 version bump (when authorised). Read in this order:

1. [`docs/ROADMAP.md`](ROADMAP.md) § "Release strategy — the road to v0.2.0" — the v0.1.9 / v0.2.0 / v0.2.x plan and what gates each.
2. `CHANGELOG.md` § `[Unreleased]` — **needs two new entries for this session's work** before the v0.1.9 bump: (a) sig-gen `--params=observed` attr_reader / attr_writer / attr_accessor inference from `initialize` observations; (b) TypeProf compatibility spec + the `rigor-project-init` SKILL Phase 5 sig precision uplift.
3. [`docs/adr/22-baseline-and-project-onboarding.md`](adr/22-baseline-and-project-onboarding.md) — WD8 + the two onboarding-SKILL sketches; the baseline mechanism.
4. [`docs/adr/23-diagnostic-triage-command.md`](adr/23-diagnostic-triage-command.md) — `rigor triage`; WD5 / slice 3 is the triage ↔ SKILL data-layer contract. Note: the `rigor-project-init` SKILL now has `rigor triage` at Phase 6 (was Phase 5 before the sig-uplift insertion in `04-sig-uplift.md`).
5. [`.claude/skills/rigor-plugin-author/SKILL.md`](../.claude/skills/rigor-plugin-author/SKILL.md) — the contributor SKILL; the template for the external-author `skills/rigor-plugin-author/` variant.
6. [`docs/internal-spec/public-api.md`](internal-spec/public-api.md) — the public-vs-internal stability boundary. v0.2.0 stabilises the plugin-contract surface for external `rigor-*` gems, so cross-reference `spec/rigor/public_api_drift_spec.rb` before extending any pinned namespace.
7. [`docs/adr/2-extension-api.md`](adr/2-extension-api.md) — the plugin contract v0.2.0 must stabilise.
