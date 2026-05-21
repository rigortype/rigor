# Current Work — Resume Bookmark

A transient bookmark for the next implementer: the immediate next-session entry point plus engine-internal items not fully captured elsewhere. The **normative** contracts live in [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md) and [`docs/adr/4-type-inference-engine.md`](adr/4-type-inference-engine.md); the forward-looking commitment envelope (release strategy + full backlog) lives in [`docs/ROADMAP.md`](ROADMAP.md); the released-version record is [`CHANGELOG.md`](../CHANGELOG.md). If this file disagrees with any of those, the spec / ADR / roadmap binds and this file is out of date.

## Status

**v0.1.8 released (2026-05-21).** Recap in `CHANGELOG.md` § `[0.1.8]` — the Mastodon-survey false-positive-reduction cycle: ADR-15 fork-based worker pool (the active `workers > 0` backend), ADR-23 `rigor triage` (slices 1+2+4), ADR-24 implicit-self method-call resolution (slices 1+2+3 + included/prepended-module resolution), the explicit-receiver private-method resolution fix, and survey-driven plugin fixes (`rigor-activerecord` v0.2.0, `rigor-activesupport-core-ext`).

The release-line plan is recorded in [`docs/ROADMAP.md`](ROADMAP.md) § "Release strategy — the road to v0.2.0":

- **v0.1.9** — the last preview cut, a near-complete (準完成版) release.
- **v0.2.0** — the first evaluation release: publicly announced, intended for real-product trial deployment (not a formal / GA version).
- **v0.2.x** — the evaluation line; the goal is to bring every planned feature to high completion **except the Ractor concurrency track** (parked behind the fork pool / ADR-15 § OQ1).

## Next entry — v0.1.9 (last preview cut)

v0.1.9 closes the preview-track commitments so v0.2.0 starts the evaluation line from a near-complete base. Two committed deliverables:

1. **External-user SKILL trio** ([ADR-22 § WD8](adr/22-baseline-and-project-onboarding.md)) — three SKILLs aimed at Rigor newcomers running `gem install rigortype` against their own projects, under the top-level `skills/` tree (agentskills.io portable conventions, public CLI surface only):
   - `skills/rigor-project-init/` — **LANDED.** First-time onboarding: Gemfile / Gemfile.lock walk → propose a plugin set matching the detected stack → **adoption-mode choice** (acknowledge / baseline vs. strict) → write `.rigor.dist.yml` → run `rigor triage --format json` → (acknowledge mode) write `.rigor-baseline.yml` + the `baseline:` config line → surface concentrated rules as likely real bugs → offer the two escalation paths (project plugin / Rigor issue). SKILL.md + three `references/` modules.
   - `skills/rigor-baseline-reduce/` — ongoing-quality: walk `.rigor-baseline.yml` rule-by-rule in priority order → sample sites → classify each (real bug / stylistic-safe / FP) → apply fix / `# rigor:disable` / open a Rigor issue → refresh the baseline.
   - `skills/rigor-plugin-author/` — the external-author variant of the plugin-authoring workflow (distinct from the `.claude/skills/rigor-plugin-author/` contributor SKILL): authoring a standalone `rigor-foo` gem against the published `rigortype` API surface.
2. **ADR-22 baseline slice 5** — `rigor baseline regenerate` plus the `--baseline-strict` CI gate.

`rigor triage` slice 3 (SKILL integration — `rigor-project-init` phase 7 and `rigor-baseline-reduce` phase 1 call `rigor triage --format json` instead of ad-hoc LLM counting; [ADR-23 WD5](adr/23-diagnostic-triage-command.md)) lands as part of the SKILL-trio work, since it depends on those SKILLs existing. The `rigor-project-init` half is done; the `rigor-baseline-reduce` half lands with that SKILL.

The v0.1.7 / v0.1.8 cycles were the lead-up — collecting real-project error data so the SKILL trio's plugin / severity / baseline-rule defaults rest on empirical evidence.

## Open engineering items

Engine-internal items the next implementer benefits from seeing directly. The full demand-driven backlog (editor mode, LSP capabilities, dry-rb continuations, ADR-10/13/16 follow-ups, performance levers) lives in [`docs/ROADMAP.md`](ROADMAP.md) § "Future cycles" and is, under the new plan, the v0.2.x completion target. This section holds only items with engine-internal detail not captured there.

### ADR-24 — implicit-self method-call resolution, remaining

Slices 1+2+3 plus included/prepended-module resolution LANDED in v0.1.8; the ADR-24 ancestor chain (WD1) is complete (same-class + top-level + superclass chain + included modules, cross-file). Remaining:

- **Slice 4** — gated `undefined-method` / arity diagnostics on resolved closed-class self-calls. Its own FP-evaluation gate ([ADR-24 WD4](adr/24-self-method-call-resolution.md)) — a large new false-positive surface on metaprogramming-dense code, so v1 was deliberately precision-additive only.
- **Non-`Bot` general adoption inside class bodies** — v0.1.8 adopts a resolved self-call return type inside a class body ONLY when it is `Bot` (an always-diverging guard helper). Unconditional adoption of precise non-`Bot` returns regressed `rigor check lib` by 16 diagnostics (pre-existing callee-return-inference imprecisions surfacing downstream); this follow-up needs callee-return inference precise enough that adopting precise types does not surface those imprecisions.

### ADR-23 — `rigor triage` slice 4 plugin recognisers

The structured-`Diagnostic`-fields half of slice 4 landed in v0.1.8 (`receiver_type` / `method_name` on `Analysis::Diagnostic`, populated by `call.undefined-method`; the catalogue reads them with message parsing as fallback). Remaining: a `Plugin` hook letting plugins contribute their own recognisers (deferred). Slice 3 (SKILL integration) is folded into the v0.1.9 SKILL-trio work above.

### Flow-folding — loop-mutation tracking (gaps G1 / G2)

`rigor check lib` surfaces 3 `flow.always-truthy-condition` warnings of the shape `arr = [seed]; while …; arr << x; end; if arr.size == N` — `Inference::Narrowing` does not reflect a loop body's `<<` / `push` mutation into the size / empty narrowing. Sites: [`hkt_body_parser.rb:140`](../lib/rigor/inference/hkt_body_parser.rb), `:307`, [`hkt_registry.rb:212`](../lib/rigor/inference/hkt_registry.rb). The Mastodon Cluster 4 triage ([`docs/notes/20260521-mastodon-cluster4-flow-folding-triage.md`](notes/20260521-mastodon-cluster4-flow-folding-triage.md)) adds 3 more `loop` / `retry` warnings of this exact shape (gap **G1**) plus sibling gap **G2** — an ivar's type is taken from its literal writes and is not invalidated by an intervening method call / in-place `<<` / read-before-write `nil`. Both live under `docs/type-specification/control-flow-analysis.md` § "mutation effects"; a medium engine change, queued. The 3 self-check warnings are `:warning` (not `:error`), so `rigor check lib` stays clean for release purposes.

### Stdlib RBS coverage-gap pattern

When an upstream `ruby/rbs` RBS gap is surfaced by a single internal Rigor call site, prefer **(a')** an in-source `# rigor:disable` directive + load the library; when it surfaces across multiple call sites or in user-facing code, escalate to **(b)** a focused RBS overlay under Rigor's own `sig/`, or **(c)** an upstream `ruby/rbs` fix. The `references/rbs` branch `widen-strscan-resolv-stdlib-sigs` (widens `StringScanner#[]`, `Resolv#initialize`) is staged for an upstream PR — branch push + `ruby/rbs` PR creation are the user's task.

### Smaller queued items

- **Sig-gen `update_existing`** does not collapse sibling parent / child class blocks — `merge_class` resolves each candidate's `class_name` independently, so flat-sibling layouts stay flat. Re-flowing an existing file into the nested layout is out of scope; workaround is to delete the target sig file and regenerate from scratch.
- **`Hash === expr` case-equality narrowing** (`open3.rb:226` shape) — still open.
- **In-memory `Analysis::Runner.run_source(source:, path:, …)` entry point** — bypasses the per-call tmpdir + chdir in `RunnerHelpers#analyze`; ~5 % spec-suite win plus a clean public API for embedders (LSP / editor mode). Demand-driven.

## Reading order for a returning implementer

The next session's default goal is the v0.1.9 SKILL trio + ADR-22 baseline slice 5. Read in this order:

1. [`docs/ROADMAP.md`](ROADMAP.md) § "Release strategy — the road to v0.2.0" — the v0.1.9 / v0.2.0 / v0.2.x plan and what gates each.
2. [`docs/adr/22-baseline-and-project-onboarding.md`](adr/22-baseline-and-project-onboarding.md) — WD8 + the two onboarding-SKILL sketches; the baseline mechanism (slice 5 is the remaining CLI work).
3. [`docs/adr/23-diagnostic-triage-command.md`](adr/23-diagnostic-triage-command.md) — `rigor triage`; WD5 / slice 3 is the triage ↔ SKILL data-layer contract.
4. `CHANGELOG.md` § `[0.1.8]` — what just shipped.
5. [`.claude/skills/rigor-plugin-author/SKILL.md`](../.claude/skills/rigor-plugin-author/SKILL.md) — the contributor SKILL; the template for the external-author `skills/rigor-plugin-author/` variant.
6. [`docs/internal-spec/public-api.md`](internal-spec/public-api.md) — the public-vs-internal stability boundary. v0.2.0 stabilises the plugin-contract surface for external `rigor-*` gems, so cross-reference `spec/rigor/public_api_drift_spec.rb` before extending any pinned namespace.
7. [`docs/adr/2-extension-api.md`](adr/2-extension-api.md) — the plugin contract v0.2.0 must stabilise.
