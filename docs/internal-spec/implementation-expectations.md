# Implementation Expectations

> **Status — two of § *Engine surface*'s nine bullets are target state, not shipped state (as of
> this writing).**
> **Inference budgets and incomplete-inference results**: no incomplete-inference result carrier
> exists in `lib/`, and the configurable `budgets:` surface is unwired — the marker is on
> [`inference-budgets.md`](../type-specification/inference-budgets.md), and the consuming
> `static.incomplete-inference.*` family is Reserved. What ships is a set of hard-coded recursion /
> fan-out guards plus ADR-10's per-gem budget, and the reason survives as a `DynamicOrigin` cause on
> the value (`ANALYZER_BUDGET_CUTOFF`) rather than as a result object.
> **Capability-role inference**: only its *explicit* half ships. `RbsExtended::ConformanceChecker`
> checks an author-written `conforms-to` directive against an RBS-defined interface; deriving a
> required role from a method body, caching per-method requirement summaries, and matching them
> against indexed named interfaces have **no implementation anywhere in `lib/`**. That deferral is
> already recorded in
> [`control-flow-analysis.md`](../type-specification/control-flow-analysis.md) § "capability-role
> *requirement inference* from method bodies"; this document stated the unshipped half in the present
> tense and now says so. Per [ADR-92](../adr/92-normative-status-fidelity.md) WD2 the intent is
> marked rather than deleted — both remain wanted.

The implementation MUST keep parsing, internal type representation, subtyping, consistency, normalization, scope transition, effect application, and RBS erasure as separate concepts. This separation keeps RBS compatibility stable while leaving room for inference-oriented internal precision.

This document is the engine-surface contract that downstream features depend on. Each surface listed here is referenced from elsewhere in the specification.

## Engine surface

The core type engine MUST expose:

- **Immutable `Scope` snapshots.** Joins, narrowing, and invalidation produce new snapshots through structural sharing rather than in-place mutation. See [control-flow-analysis.md](../type-specification/control-flow-analysis.md).
- **Edge-aware condition analysis** for truthy, falsey, normal, exceptional, and unreachable exits. See [control-flow-analysis.md](../type-specification/control-flow-analysis.md).
- **Inference budgets and incomplete-inference results** that preserve the reason inference stopped. See [inference-budgets.md](../type-specification/inference-budgets.md).
- **A fact store** that can represent value facts, negative facts, relational facts, member-existence facts, shape facts, dynamic-origin provenance, stability facts, escape facts, and captured-local write facts. See [control-flow-analysis.md](../type-specification/control-flow-analysis.md).
- **An effect model** for receiver and argument mutation, block call timing, closure escape, purity, and fact invalidation. See [control-flow-analysis.md](../type-specification/control-flow-analysis.md) and [rbs-extended.md](../type-specification/rbs-extended.md).
- **Capability-role inference** that can cache per-method requirement summaries, match them against indexed named interfaces when available, and keep anonymous shapes when matching is ambiguous or too expensive. See [structural-interfaces-and-object-shapes.md](../type-specification/structural-interfaces-and-object-shapes.md).
- **Normalization** for unions, intersections, complements, differences, and impossible refinements. See [normalization.md](../type-specification/normalization.md).
- **Semantic type queries for extensions** so plugin authors ask capability questions rather than inspecting concrete type classes. See [rbs-extended.md](../type-specification/rbs-extended.md).
- **Conservative RBS erasure** with optional loss-of-precision explanations. See [rbs-erasure.md](../type-specification/rbs-erasure.md).

## Why this structure

This structure is necessary for the ideal behavior described elsewhere in the specification:

- precise Ruby-shaped duck typing through structural interfaces and inferred object shapes;
- expression-level narrowing inside compound conditions;
- a plugin API that can add framework knowledge without taking ownership of the analyzer's control-flow state.

Without separating these concerns, RBS compatibility, internal precision, and plugin extensibility would compete for the same code paths. The separation lets each layer evolve independently while preserving the invariants documented in this specification.

## Public surface stability

The public surface of `Scope`, the type-query API exposed to plugins, and the diagnostic identifier prefixes (see [diagnostic-policy.md](../type-specification/diagnostic-policy.md)) are stable within a major version. Internal layouts — fact buckets, the indexed interface match table, capability-role caches — are implementation details that MAY evolve.

Plugins, refactor tools, and other consumers MUST use the public surface for their queries. They MUST NOT depend on internal data structures that the specification does not document as part of the public contract.
