# ADR-67 — Parameter type inference (the M3 frontier): call-site and in-body, precision-additive only

Status: **Proposed — demand-gated.** Re-opens the algorithm-corpora survey's
"M3 — untyped-param → whole-method Dynamic: **EXCUSED, do not pursue**" verdict on
new **protection-coverage** evidence. Method / ctor parameters default to `untyped`
today (the gradual entry point); the pilot shows a param flowing into an ivar or
receiver is the **dominant remaining protection hole on real apps**. The reconciliation
with the robustness principle is the whole decision: inference may **sharpen downstream
precision** but **never tighten a diagnostic at the parameter boundary**.

Grounding: the algorithm-corpora survey
([`docs/notes/20260612-algorithm-corpora-survey.md`](../notes/20260612-algorithm-corpora-survey.md)
M3 row — excused on *precision* grounds: leaf sort/number scripts have no call sites and
a signature-less param IS the gradual entry point); the 2026-06-16 protection-uplift pilot
([`docs/design/20260616-act-on-coverage-skill.md`](../design/20260616-act-on-coverage-skill.md)
— M3 is the top `add_a_type_here` on faraday/haml/parser, the hand-typed `compile(node)` /
`@template = template` wins); and the TypeProf-internals prior-art survey
([`docs/notes/20260531-typeprof-internals-survey.md`](../notes/20260531-typeprof-internals-survey.md)
— a param's type as "the union of every actual-argument type across all call sites").

## Context

A method / ctor parameter with no RBS signature types `untyped` (the gradual entry
point; `method_dispatcher.rb` "the key parameter is left `untyped` — the default"). Block
parameters are inferred from dispatch, but **`def` parameters are not inferred** from call
sites or in-body usage. So `def initialize(line); @line = line; end` makes `@line`
`Dynamic`, and every `@line.<method>` downstream is unprotected — distinct from
[ADR-58](58-ivar-field-typing.md), whose ivar typing is *already realized* for
concrete-write fields but cannot touch a **param-sourced** ivar (confirmed: a
concrete-write `@line = Line.new` reads `Line` and protects; a param-sourced `@line = line`
reads `Dynamic`).

The algorithm survey **excused M3** because its corpus was leaf scripts with no call sites
— there was no inference *seed*. The protection pilot changes the cost/benefit: on real
applications the call sites exist (faraday's `Connection`/`Options`, haml's compiler chain),
M3 is the #1 remaining unprotected cluster, and protection coverage is the lens that values
closing it. The standing tension is [ADR-5](5-robustness-principle.md): parameters are kept
**lenient** by decision (strict returns, lenient params), so any param typing must not turn
a wrong-typed caller into a diagnostic.

## Decision

Infer parameter types from two sources, staged, under one load-bearing criterion.

> **Criterion (reconciliation with robustness):** an inferred parameter type is
> **precision-additive only**. It sharpens *downstream* inference — the ivar the param is
> stored in, the receiver it becomes, the protection metric, constant folding — but is
> **never** consulted to reject a caller's argument. The parameter boundary stays lenient
> (ADR-5): a call passing an unexpected type is not a diagnostic. An RBS-*declared* param
> always wins over an inferred one. Inference feeds protection/folding, not param-boundary
> diagnostics.

This is what separates the proposal from a "typed parameters" regime and is why it can
proceed without breaching the robustness principle.

## Working decisions

- **WD1 — precision-additive-only contract (the robustness floor; non-negotiable).** An
  inferred param type carries "inferred, not declared" provenance and can never escalate to
  a param-boundary `argument-type-mismatch` / arity firing (the [ADR-58](58-ivar-field-typing.md)
  WD1 provenance-bit pattern, reused). It only flows into downstream typing. Without this,
  the feature is an ADR-5 violation; with it, it is pure precision.
- **WD2 — in-body usage lower bound (cheapest; helps even leaf scripts).** From the param's
  calls in the method body (`arr.delete_at`, `arr.length`), derive a **structural lower
  bound** (responds-to set / interface) and let it drive protection on `arr.<method>`. No
  call sites needed, so it helps the leaf-script corpus the survey excused — but yields a
  duck/structural bound, not a nominal type.
- **WD3 — call-site union (TypeProf-style; the real lever for apps).** A param's inferred
  type = the union of resolved call-site argument types (needs ≥1 resolved call site). This
  is the piece that closes the faraday/haml `ctor-param → ivar → receiver` chain. It is
  whole-program-ish and in tension with Rigor's per-file model
  ([ADR-46](46-incremental-dependency-graph.md)), so it is **budget-gated**, not default-on,
  and unsound under unseen call sites / dynamic dispatch → falls back to `untyped` (no false
  narrowing).
- **WD4 — soundness fallbacks.** Unseen call sites, `send`/dynamic dispatch, and
  metaprogrammed callers contribute nothing (the param stays `untyped`); a single dynamic
  caller does not widen an otherwise-precise inference into a false narrowing. The inferred
  type is an over-approximation only where the call-site set is closed.
- **WD5 — budget + termination.** The call-site union is a worklist fixpoint; cap it under
  [ADR-41](41-inference-budget-design.md) and reuse the run-scoped return memo infrastructure
  ([ADR-57](57-self-call-return-adoption.md)) so the whole-program pass does not re-type
  callees unboundedly. WD2 (in-body) is local and cheap; WD3 (call-site) is the cost driver.

## Rejected / deferred alternatives

| Alternative | Verdict |
| --- | --- |
| Treat an inferred param as **declared** (fire on wrong-typed callers) | **Rejected** — breaches ADR-5 (parameters are lenient by decision); the criterion forbids it. |
| Keep the survey's "M3 EXCUSED, do not pursue" | **Superseded for the protection lens** — excused on *precision* (leaf scripts, no call sites); the protection pilot + real apps with call sites re-open it. |
| Full TypeProf whole-program abstract interpreter as the default | **Deferred** — Rigor is per-file/incremental (ADR-46); the call-site pass is budget-gated (WD3/WD5), not a default whole-program worklist. |
| Infer params before [ADR-58](58-ivar-field-typing.md) precision exists | **N/A — already met** — ADR-58's concrete-write ivar typing is realized, so an inferred param feeding `@x = param` immediately sharpens the read. |

## Re-evaluation triggers

Demand-gated. Proceed when **either**: (a) [ADR-63](63-type-protection-coverage.md)
protection-coverage keeps surfacing M3 as the top `add_a_type_here` across user projects
(the pilot is the first such signal); or (b) [ADR-46](46-incremental-dependency-graph.md)
incremental analysis makes the WD3 call-site pass affordable inside the per-file model.
WD2 (in-body lower bound) may proceed independently and earlier — it is local and FP-safe.

## Consequences

- **Positive** — closes the dominant remaining protection hole on real applications;
  automates the pilot's single biggest hand-win (param / param-sourced-ivar typing);
  precision-additive by the criterion, so zero new diagnostics.
- **Negative** — WD3 is whole-program-ish, in tension with the per-file model (hence
  budget-gated); WD2 yields only a structural bound. The criterion (no param-boundary
  firing) means the inference buys *protection*, not *more bugs caught at the boundary* —
  by design.
- **Carry-over** — WD2 is the cheap first step (helps even leaf scripts, no call sites);
  WD3 is the app-scale lever but carries the incrementality/cost question.

## Relationship to other ADRs

- **ADR-5** — the reconciliation criterion is its direct application: params stay lenient,
  so inference feeds precision, never boundary diagnostics.
- **ADR-58** — the sibling. Ivar field typing is done; **param-sourced** ivars are *this*
  ADR's job — the explicit M3 frontier ADR-58 scoped out as gradual.
- **ADR-46** — the WD3 call-site pass's affordability depends on the incremental story.
- **ADR-41 / ADR-57** — budget/termination and the run-scoped memo infra WD5 reuses.
- **ADR-63** — the protection pilot that re-opened the excused M3 bucket.
