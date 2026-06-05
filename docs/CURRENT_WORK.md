# Current Work — Resume Bookmark

A transient bookmark for the next implementer: the immediate next-session entry point plus engine-internal items not fully captured elsewhere. The **normative** contracts live in [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md) and [`docs/adr/4-type-inference-engine.md`](adr/4-type-inference-engine.md); the forward-looking commitment envelope (release strategy + full backlog) lives in [`docs/ROADMAP.md`](ROADMAP.md); the released-version record is [`CHANGELOG.md`](../CHANGELOG.md). If this file disagrees with any of those, the spec / ADR / roadmap binds and this file is out of date.

## Status

**v0.1.17 released (2026-06-06).** The focus is the road to v0.2.0, with one more themed preview cut planned first — **v0.1.18 (CI-environment support)** (see [`ROADMAP.md`](ROADMAP.md) § "v0.1.18 — CI-environment support").

The v0.1.17 cycle (internal-structure review + performance tuning) shipped: incremental analysis (`rigor check --incremental`, [ADR-46](adr/46-incremental-dependency-graph.md)), the unchanged-project fast path ([ADR-45](adr/45-unchanged-project-fast-path.md)), large allocation reductions ([ADR-44](adr/44-dispatch-allocation-churn.md)), Elixir-v1.20-inspired narrowing (`Array` non-empty + `Hash` key-presence) + `flow.unreachable-clause` ([ADR-47](adr/47-narrowing-driven-clause-reachability.md)), the `rigor:v1:conforms-to` directive, the `call.self-undefined-method` rule (shipped `:off`, [ADR-24](adr/24-self-method-call-resolution.md) slice 4), and `Data.define` value folding ([ADR-48](adr/48-data-struct-value-folding.md)). Full record in `CHANGELOG.md` § `[0.1.17]`; do not re-summarise it here.

v0.1.17 also landed the **release-engineering machinery for the road to v0.2.0** (deliberately *not* in the user-facing CHANGELOG — it is process / CI / docs): [ADR-49](adr/49-adr-authoring-guidelines.md) (an ADR-authoring rubric + the `rigor-adr-author` skill + the corpus audit note [`docs/notes/20260605-adr-corpus-rubric-audit.md`](notes/20260605-adr-corpus-rubric-audit.md)); **[ADR-50](adr/50-release-engineering-and-stability-strategy.md)** (the release-engineering + stability strategy, v0.2.0→v1.0.0, PHPStan-modelled); the `release/x.y.z` branch workflow + `release-gate.yml` (advisory) + the `make bench-perf` perf gate; and the `rigor-release-prep` skill's branch + release-summary conventions. **v0.1.17 was the first release cut on this machinery** — which validated it end-to-end (the release gate caught a real config-crash bug, the `source_inference: false` crash, mid-cut; fixed in the same release).

Headline realism numbers (measured at the v0.1.12 OSS-realism cut; still current — later cuts added onboarding / `def.override-*` / the plugin-contract suite / perf rather than new full surveys):

| Project | Scope | Before | After | Delta |
|---|---|---:|---:|---:|
| Mastodon | `app + lib` | 789 | 6 | **−99.2%** |
| Redmine | full plugin set | 163 | 79 | −51% |
| GitLab FOSS | `app/{controllers,mailers,workers,services}` | ~670 | ~140 | ~−79% |

The 6 remaining Mastodon errors are unrelated to engine precision: 5 nil-receiver in test fixtures + 1 upstream `ruby/rbs` `Resolv::DNS#getresources` typeclass-narrowing gap (see [`docs/notes/20260528-rbs-upstream-pr-resolv-typeclass.md`](notes/20260528-rbs-upstream-pr-resolv-typeclass.md)).

## Next-session entry point

> **The focus is the road to v0.2.0, governed by [ADR-50](adr/50-release-engineering-and-stability-strategy.md).** The machinery shipped in v0.1.17; what remains is **calibrating + hardening it**, the ADR-50 staged implementation, and the standing engine backlog. `make verify` is clean.
>
> **(A) Release engineering + CI — operationalise ADR-50, and ship v0.1.18 CI-environment support (the headline tracks):**
> 0. **v0.1.18 — CI-environment support** (planned themed cut before v0.2.0; full surface in [`ROADMAP.md`](ROADMAP.md) § "v0.1.18 — CI-environment support"): the copy-paste CI setup templates ADR-27 § WD3 left queued (`.github/workflows/rigor.yml` + a `.gitlab-ci.yml` equivalent + a generic recipe) and CI-native diagnostic output (GitHub Actions workflow commands / SARIF / GitLab Code Quality). Output formats are a public-contract surface under ADR-50 WD1 → likely an ADR-27 amendment or a new ADR; decide format priority (SARIF as the cross-platform target) when the cycle opens.
> 1. **Calibrate the perf gate.** `bench/baseline.json` ships **uncalibrated** (so `make bench-perf` / the release gate pass and emit a suggestion). Commit a CI-measured Linux baseline — from a `release-gate.yml` `bench-baseline-*` artifact, or `make bench-perf` on Linux — as `{ "calibrated": true, "targets": {…} }`, then harden `release-gate.yml` from advisory → required. (ADR-50 WD4/WD6.)
> 2. **Calibrate the OSS sweep.** `data/oss-sweep/mastodon-thresholds.json` is uncalibrated (`max_diagnostics: 999999`). The `source_inference: false` crash that had kept the weekly sweep red is **fixed (v0.1.17)**, so the sweep now runs — refresh thresholds against the ~6 Mastodon baseline (delete + recalibrate, or commit the workflow artifact).
> 3. **ADR-50 staged implementation** (each its own slice; ADR-50 stays Proposed → ratified at v1.0.0): the **bleeding-edge overlay** + `rigor show-bleedingedge` diff command + granular `bleeding_edge:` config (WD2); the **enumerated public-surface document** (WD1, drafted at v0.2.0); the **support-line model** (latest + previous minor pre-1.0 → PHPStan `1.x`-default-branch post-1.0, WD5); a **`rigor upgrade`** migration-assist command (WD7, deferred until the first concrete BC gives it a target).
> 4. **v0.2.0 cut** — the one substantive gate is the documented stability commitment for the external plugin contract; **ADR-50 now provides that policy** (the gate-1 executable evidence landed v0.1.16). See [`docs/ROADMAP.md`](ROADMAP.md) § "Release strategy".
>
> **(B) External-corpus-gated — needs `~/repo/ruby/rigor-survey/`, cannot complete in this repo:**
> 5. **ADR-24 slice 4 — corpus FP gate + gate widening.** `call.self-undefined-method` ships `:off`, FP-clean on Rigor's own `lib`. Run the WD4 FP eval before flipping any profile on, then widen the standalone-only gate to superclass / include chains (record ancestor-chain-resolution-completeness at the recorder — the "collect, don't recompute" route). See § "ADR-24" below.
> 6. **`rigor check --incremental` CI-gate extension** — extend the `--verify-incremental` CI gate to the Mastodon + GitLab survey trees.
>
> **(C) In-repo engine backlog (demand-driven, each ADR-scoped):**
> 7. **[ADR-48](adr/48-data-struct-value-folding.md) `Struct` follow-up** (its own slice with the mutation-soundness story — setters / `[]=` invalidate the instance member map; the side-table records `Data.define` only) + bare-local block-form parity (`c = Data.define(:x) do … end` — no resolvable class name for the slice-4 reader-redefinition guard, conservative bail). `Data.define` shipped (slices 1–4).
> 8. **[ADR-47](adr/47-narrowing-driven-clause-reachability.md) WD3b** — deconstructing / value / variable-catch-all pattern exhaustiveness (the deferred [ADR-36](adr/36-mangrove-enum-nested-class-emission.md) `is_a?` neighbour; do NOT infer ad hoc; priority lowered by the zero-firing WD4 sweep).
> 9. **`MathFolding` float sign refinements** — **spec-contested, NOT a quick win.** `Math.exp → positive-float` etc. need float sign refinements (`positive-float` / `non-negative-float`), which [`imported-built-in-types.md`](type-specification/imported-built-in-types.md) **deliberately excludes** (refinements are intentionally `Integer`-only; float sign / literal narrowing is "refused by default" on `NaN` / signed-zero / coercion grounds — the spec-blessed door is a future `finite-float` / non-`NaN` proof). And `Math.exp(Float::NAN) → NaN` makes it outright unsound without a non-`NaN` precondition. ADR-worthy + a spec amendment first; demand-gated.
>
> **Do NOT** restart ADR-24 slice 4 via the check-rules route (reverted 2026-06-05, 135 FPs — see below); the evaluation-time recorder is the landed route. **Do NOT** extract the `Runner#initialize` ivar pre-seeds into a helper (hides them from the engine's own flow analysis → self-check FP; see "Gotchas").

### Reference reading

1. [`docs/ROADMAP.md`](ROADMAP.md) § "Release strategy — the road to v0.2.0" — what gates v0.2.0 (now governed by ADR-50).
2. [`docs/adr/50-release-engineering-and-stability-strategy.md`](adr/50-release-engineering-and-stability-strategy.md) — the v0.2.0→v1.0.0 release/QA contract (compatibility surface, diagnostic non-contract + bleeding-edge, perf gate, support line, graduation cadence).
3. [`CHANGELOG.md`](../CHANGELOG.md) § `[0.1.17]` — the shipped perf/incremental/diagnostics cycle; § `[0.1.16]` for the plugin-contract suite + ADR-43; § `[0.1.12]` for the OSS-realism cycle.
4. [`docs/internal-spec/public-api.md`](internal-spec/public-api.md) — the public-vs-internal stability boundary (ADR-50 WD1 enumerates it); cross-reference `spec/rigor/public_api_drift_spec.rb` before extending any pinned namespace.

## Gotchas (load-bearing, learned the hard way)

- **ADR-46** — do NOT extract the `Runner#initialize` ivar pre-seeds (`@class_decl_paths_snapshot = {}` etc.) into a helper; moving them out of the constructor hides them from the engine's OWN flow analysis and `make check` self-flags `snapshot.size` as a nil-receiver false positive. Keep them inline (the constructor carries an `AbcSize` disable).
- **ADR-45** — `@collect_stats` is true by default (can't gate the cache on it; a hit returns nil stats); a lazy `@io_boundary ||=` on a frozen plugin → `FrozenError` (use `instance_variable_get`); a cache write / serialize failure is swallowed (never breaks a run).
- **ADR-24** — a check-rules *reimplementation* of self-call resolution diverges from the engine's real one (which already handles `module_function` / `Data.define` accessors / mixins for precision) → 135 FPs (reverted). The landed route is the evaluation-time `SelfCallResolutionRecorder` ("collect, don't recompute").
- **bench-perf** — the Make target is `bench-perf`, not `bench` (the bare name collides with the `bench/` data directory; the file keeps its no-`.PHONY` convention). `bench/baseline.json` ships uncalibrated → first run writes `bench/baseline.updated.json` (gitignored) and passes.

## Open engineering items

Engine-internal items the next implementer benefits from seeing directly. The full demand-driven backlog lives in [`docs/ROADMAP.md`](ROADMAP.md) § "Future cycles".

### ADR-24 — implicit-self method-call resolution, remaining

- **Slice 4 (recorder + `call.self-undefined-method` rule, shipped `:off`) — LANDED v0.1.17.** **Remaining (needs external corpus):** the WD4 FP eval before flipping a profile on, then widening the standalone-only gate to superclass / include chains (record ancestor-chain-resolution-completeness at the recorder). **Arity diagnostics** on resolved closed-class self-calls were NOT part of slice 4 (undefined-method only) — a later extension once the rule proves out.
- **Non-`Bot` general adoption inside class bodies** — a resolved self-call return type is adopted ONLY when it is `Bot`. Unconditional adoption of precise non-`Bot` returns regressed `rigor check lib` by 16 diagnostics (pre-existing callee-return-inference imprecisions surfacing downstream); this follow-up needs callee-return inference precise enough that adopting precise types does not surface those imprecisions.

### AR scope-body lambda `self`

`scope :x, -> { select(...).group(...) }` inside an instance lambda still needs the lambda's `self` rebound to the model class. v0.1.12 closed implicit-self class-side resolution for ordinary method bodies; lambda bodies remain (ADR-26 territory). Empirical case in [`docs/notes/20260523-mastodon-v4.5-regression-sweep-v0.1.9.md`](notes/20260523-mastodon-v4.5-regression-sweep-v0.1.9.md) § "What is increasing" item 2.

### ADR-23 — `rigor triage` slice 4 plugin recognisers

Remaining: a `Plugin` hook letting plugins contribute their own recognisers (deferred). (Structured `receiver_type` / `method_name` fields + the SKILL integration shipped in the v0.1.8 / v0.1.9 cycle.)

### Inference budgets — spec table unwired (Layer 1 doc hygiene DONE)

The spec's configurable `budgets:` table ([`docs/type-specification/inference-budgets.md`](type-specification/inference-budgets.md)) is normative-for-v1 but **not wired** — the only operative cutoffs are three hard-coded silent guards (recursion re-entry ≈ depth 1, ancestor walk 100, HKT fuel 64) plus ADR-10 `budget_per_gem`. **Layer 2 resolved, and it was not a budget:** the large-app cost cliff was a 4.2 M-retained-String leak in `rigor-activerecord` (fixed v0.1.16), and `union_size` was refuted as uncorrelated with memory. Budget wiring is **demand-deferred** — no corpus project demonstrates a budget-shaped cost; if one does, re-run the 2a distribution probe first ([ADR-41 WD3](adr/41-inference-budget-design.md)). The `RIGOR_BUDGET_TRACE` / `RIGOR_HEAP_PROFILE` / `RIGOR_HEAP_TRACE` probes are reusable.

### Stdlib RBS coverage-gap pattern + the staged upstream PR

When an upstream `ruby/rbs` gap is surfaced by a single internal call site, prefer **(a')** an in-source `# rigor:disable` + load the library; across multiple call sites or user-facing code, escalate to **(b)** a focused RBS overlay under Rigor's own `sig/`, or **(c)** an upstream `ruby/rbs` fix. The `references/rbs` branch `widen-strscan-resolv-stdlib-sigs` (widens `StringScanner#[]`, `Resolv#initialize`) is staged — **branch push + `ruby/rbs` PR creation are the user's task.**

### Sig-gen (ADR-14) remaining gaps

`attr_reader` with ivars set from non-`initialize` sources (DB reads, config, side effects) still produce `:untyped_return` → hand-written sig. Deep chains on untyped receivers → `rbs collection install` / ADR-10 `source_inference:`. Dynamic methods (`define_method`, DSL macros) → project plugin. `update_existing` does not collapse sibling parent/child class blocks (workaround: delete the target sig + regenerate). Documented in `skills/rigor-project-init/references/04-sig-uplift.md`.

### ADR-49 corpus economy follow-up (optional)

The 2026-06-05 corpus audit found over-information is the corpus's one systematic drift; ADR-22's SKILL-sketch bloat was trimmed (v0.1.17). ADR-1 / ADR-16 are the remaining length outliers, but their length is "defensible" (high-stakes) per the audit and extraction would split foundational rationale — assessed **not worth it**, recorded for completeness, not queued.
