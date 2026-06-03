# Current Work — Resume Bookmark

A transient bookmark for the next implementer: the immediate next-session entry point plus engine-internal items not fully captured elsewhere. The **normative** contracts live in [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md) and [`docs/adr/4-type-inference-engine.md`](adr/4-type-inference-engine.md); the forward-looking commitment envelope (release strategy + full backlog) lives in [`docs/ROADMAP.md`](ROADMAP.md); the released-version record is [`CHANGELOG.md`](../CHANGELOG.md). If this file disagrees with any of those, the spec / ADR / roadmap binds and this file is out of date.

## Status

**v0.1.15 released (2026-05-29). v0.1.16 prepared (2026-06-03) — version bumped + `CHANGELOG.md` § `[0.1.16]` sealed; `bundle exec rake release` is gated on explicit user authorisation and has not been run.**

v0.1.16 lands the full plugin-contract interface-segregation + ergonomics suite (ADR-37/38/39/40), ADR-43 RBS-complete ancestor resolution + the `make check-plugins` gate, the v0.2.0 gate-1 executable evidence (external-plugin fixture + conformance / all-plugins-load / demos-run guards), RBS-robustness synthesis for malformed project `signature_paths:`, and the `rigor-activerecord` missing-schema memoization fix (Redmine −86% memory). Full detail is in `CHANGELOG.md` § `[0.1.16]`; do not re-summarise it here.

Headline realism numbers (measured at the v0.1.12 OSS-realism cut; still current — later cuts added onboarding / `def.override-*` / the plugin-contract suite rather than new full surveys):

| Project | Scope | Before | After | Delta |
|---|---|---:|---:|---:|
| Mastodon | `app + lib` | 789 | 6 | **−99.2%** |
| Redmine | full plugin set | 163 | 79 | −51% |
| GitLab FOSS | `app/{controllers,mailers,workers,services}` | ~670 | ~140 | ~−79% |

The 6 remaining Mastodon errors are unrelated to engine precision: 5 nil-receiver in test fixtures + 1 upstream `ruby/rbs` `Resolv::DNS#getresources` typeclass-narrowing gap (see [`docs/notes/20260528-rbs-upstream-pr-resolv-typeclass.md`](notes/20260528-rbs-upstream-pr-resolv-typeclass.md)).

## Next-session entry point

`make verify` is clean. The plugin-contract effort is released in v0.1.16; the two strategic levers left before the v0.2.0 cut are:

1. **v0.2.0 gate 1 — the documented stability commitment for the external plugin contract.** The executable evidence (external-plugin fixture + conformance / load / demo guards, all in CI) landed in v0.1.16; what remains is the *documented* "won't break within 0.2.x" statement for the pinned plugin-contract namespaces (the drift spec already pins them). **This needs explicit planning, not another incremental slice.** See [`docs/ROADMAP.md`](ROADMAP.md) § "v0.2.0 — first evaluation release".
2. **v0.1.17 — internal-structure review + performance tuning** before the v0.2.0 cut: ADR-24 slice 4 (gated `undefined-method` on resolved closed-class self-calls), engine-internal precision uplifts surfaced by the v0.1.16 work, and perf follow-ups from the inference-budget survey / `RIGOR_BUDGET_TRACE`.

Everything else is demand-driven and lives in [`docs/ROADMAP.md`](ROADMAP.md) § "Future cycles" (plugin-contract ergonomics follow-ons, dry-rb continuations, LSP capabilities, performance levers) — pull from there when a concrete need surfaces.

### Reference reading

1. [`CHANGELOG.md`](../CHANGELOG.md) § `[0.1.16]` — the plugin-contract suite + ADR-43; § `[0.1.12]` for the OSS-realism cycle.
2. [`docs/ROADMAP.md`](ROADMAP.md) § "Release strategy — the road to v0.2.0" — what gates v0.2.0.
3. [`docs/internal-spec/public-api.md`](internal-spec/public-api.md) — the public-vs-internal stability boundary; cross-reference `spec/rigor/public_api_drift_spec.rb` before extending any pinned namespace.
4. [`docs/adr/2-extension-api.md`](adr/2-extension-api.md) — the plugin contract v0.2.0 must stabilise.

## Queued tracks

### Residual diagnostics

- **Mastodon `app + lib` residue = 6** — 5 are genuine nil-chain bugs in `spec/` fixtures (Mastodon-side, no Rigor work); 1 is the upstream `ruby/rbs` `Resolv::DNS#getresources` typeclass gap. The `references/rbs` branch `widen-strscan-resolv-stdlib-sigs` is staged — branch push + `ruby/rbs` PR creation are the user's task.
- **Redmine / GitLab FOSS residues** are larger surfaces; each warrants its own survey cycle if the user wants to chase those numbers down.

### Engine-internal (not survey-driven)

1. **ADR-24 slice 4** — gated `undefined-method` / arity diagnostics on resolved closed-class self-calls. See "ADR-24 — implicit-self method-call resolution, remaining" below.
2. **AR scope-body lambda `self`** — `scope :x, -> { select(...).group(...) }` inside an instance lambda still needs the lambda's `self` rebound to the model class. v0.1.12 closed implicit-self class-side resolution for ordinary method bodies; lambda bodies remain. Empirical case in [`docs/notes/20260523-mastodon-v4.5-regression-sweep-v0.1.9.md`](notes/20260523-mastodon-v4.5-regression-sweep-v0.1.9.md) § "What is increasing" item 2 / ADR-26 territory.

## Open engineering items

Engine-internal items the next implementer benefits from seeing directly. The full demand-driven backlog (editor mode, LSP capabilities, dry-rb continuations, ADR-10/13/16 follow-ups, performance levers, plugin-contract ergonomics follow-ons) lives in [`docs/ROADMAP.md`](ROADMAP.md) § "Future cycles" and is the v0.2.x completion target. This section holds only items with engine-internal detail not captured there.

### ADR-24 — implicit-self method-call resolution, remaining

- **Slice 4** — gated `undefined-method` / arity diagnostics on resolved closed-class self-calls. Its own FP-evaluation gate ([ADR-24 WD4](adr/24-self-method-call-resolution.md)) — a large new false-positive surface on metaprogramming-dense code, so v1 was deliberately precision-additive only.
- **Non-`Bot` general adoption inside class bodies** — resolved self-call return type is adopted ONLY when it is `Bot`. Unconditional adoption of precise non-`Bot` returns regressed `rigor check lib` by 16 diagnostics (pre-existing callee-return-inference imprecisions surfacing downstream); this follow-up needs callee-return inference precise enough that adopting precise types does not surface those imprecisions.

### ADR-23 — `rigor triage` slice 4 plugin recognisers

Remaining: a `Plugin` hook letting plugins contribute their own recognisers (deferred). (`receiver_type` / `method_name` structured fields on `Analysis::Diagnostic` shipped in v0.1.8; the SKILL integration shipped with the v0.1.9 trio.)

### Inference budgets — spec table is unwired; Layer 1 doc hygiene remains

The spec's configurable `budgets:` table ([`docs/type-specification/inference-budgets.md`](type-specification/inference-budgets.md)) is normative-for-v1 but **not wired** — the only operative cutoffs are three hard-coded silent guards (recursion re-entry ≈ depth 1, ancestor walk 100, HKT fuel 64) plus ADR-10 `budget_per_gem`. Survey + the `RIGOR_BUDGET_TRACE` / `RIGOR_HEAP_PROFILE` / `RIGOR_HEAP_TRACE` probes landed 2026-06-03 (note [`docs/notes/20260603-inference-budget-reality-survey.md`](notes/20260603-inference-budget-reality-survey.md)); the probes are reusable.

**Layer 2 resolved, and it was not a budget.** The large-app cost cliff was traced to 4.2 M retained Strings from one unmemoized failure in `rigor-activerecord` (`schema_table_or_nil` when `db/schema.rb` is missing) — fixed in v0.1.16 (Redmine 1518 MB / 173 s → 217 MB / 84 s). `union_size` was refuted as uncorrelated with memory. Budget wiring is now **demand-deferred** — no corpus project demonstrates a budget-shaped cost; if one ever does, re-run the 2a-style distribution probe first ([ADR-41 WD3](adr/41-inference-budget-design.md)).

**Layer 1 (demand-gated doc/spec hygiene, awaits ADR-41 acceptance):** fix the `docs/manual/03-configuration.md` `budget_per_gem` description (it says "time budget in ms, default 1000"; really a method-def **count**, default **5000**); reconcile `recursion_depth` (spec 5 vs the wired depth-1 termination guard — split "termination floor" from "precision-unroll depth"); add `ancestor_walk` (100) + `hkt_fuel` (64) rows to the documented table; author the missing user-facing budget explanation (placement TBD).

### Stdlib RBS coverage-gap pattern

When an upstream `ruby/rbs` RBS gap is surfaced by a single internal Rigor call site, prefer **(a')** an in-source `# rigor:disable` directive + load the library; when it surfaces across multiple call sites or in user-facing code, escalate to **(b)** a focused RBS overlay under Rigor's own `sig/`, or **(c)** an upstream `ruby/rbs` fix. The `references/rbs` branch `widen-strscan-resolv-stdlib-sigs` (widens `StringScanner#[]`, `Resolv#initialize`) is staged for an upstream PR — branch push + `ruby/rbs` PR creation are the user's task.

### Smaller queued items

- **Sig-gen `update_existing`** does not collapse sibling parent / child class blocks — `merge_class` resolves each candidate's `class_name` independently, so flat-sibling layouts stay flat. Re-flowing an existing file into the nested layout is out of scope; workaround is to delete the target sig file and regenerate from scratch.
- **`Hash === expr` case-equality narrowing** (`open3.rb:226` shape) — still open.
- **In-memory `Analysis::Runner.run_source(source:, path:, …)` entry point** — bypasses the per-call tmpdir + chdir in `RunnerHelpers#analyze`; ~5 % spec-suite win plus a clean public API for embedders (LSP / editor mode). Demand-driven.
- **Sig-gen remaining gaps after `--params=observed`** — `attr_reader` with ivars set from non-`initialize` sources (DB reads, config, side effects) still produce `:untyped_return`; fix is a hand-written sig annotation. Deep chains on untyped receivers → `rbs collection install` or ADR-10 `source_inference:`. Dynamic methods (`define_method`, DSL macros) → project plugin (escalation path A in the SKILL). Documented in `skills/rigor-project-init/references/04-sig-uplift.md` § "Step 5-d".

### Type-coverage uplift — line status (2026-05-23)

Phases 1–4 landed (String / Integer / Float / Comparable / Math / HashShape / Date / DateTime / Time). Remaining items, all **release undetermined** and tracked at full detail in [`docs/ROADMAP.md`](ROADMAP.md) § "Future cycles" → "Type-language / engine":

- **Struct / Data value folding** — ADR-worthy (needs two new carriers); `Data.define` is the likely better first target. `Encoding` value folding is a *permanent exclusion*.
- **`MathFolding` result refinements** — attaching range refinements (`Math.exp` → `positive-float`, `Math.sqrt` / `hypot` → `non-negative-float`) to the value-precise 28-function fold. Demand-driven.
- **Hash `rassoc` shape handler** — the one open low-priority Hash handler; value → `[k, v]` reverse lookup, foldable when every value is a `Constant`. Demand-driven.

## Post-release follow-ups

- **`data/oss-sweep/mastodon-thresholds.json`** — refresh the stored thresholds against the ~6 baseline so the weekly OSS sweep gate is calibrated (the current file is uncalibrated, `max_diagnostics: 999999`).
