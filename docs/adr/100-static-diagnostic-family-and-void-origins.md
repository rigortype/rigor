# ADR-100 — The `static.*` diagnostic family shape and the `void_origins` side-table

Status: **Accepted, 2026-07-18.** Fixes the *shape* of the reserved `static.*`
family so its first identifier does not box it in, and specifies the `void_origins`
side-table that the spec's mandated "use of void value" diagnostic needs. Nothing
is implemented yet: the direct-author-declared-`void` slice is the first
implementation and is `ready-for-agent` once this lands; the transitive case and
the `static.incomplete-inference.*` budget identifiers ([#158](https://github.com/rigortype/rigor/issues/158) / [ADR-41](41-inference-budget-design.md)) are deferred.

Grounding: [#162](https://github.com/rigortype/rigor/issues/162); [special-types.md](../type-specification/special-types.md) § `void` (the "use of void value" MUST); [diagnostic-policy.md](../type-specification/diagnostic-policy.md) § the `static.*` reservation; [ADR-92](92-normative-status-fidelity.md) (which resolved `void → top` and carried option (a) forward as unfinished design); [ADR-75](75-dynamic-provenance.md) (the provenance-as-side-channel precedent this mirrors).

## Context

[ADR-92](92-normative-status-fidelity.md) resolved `void` to widen to `top`
(`RBS::Types::Bases::Void => :translate_top`, `rbs_type_translator.rb`), measured
free on a 5-project corpus. That closes the *widening* half of
[special-types.md](../type-specification/special-types.md) § `void`. The other
half is still open and is normative: "In value context, a `void` result **MUST**
produce a primary 'use of void value' diagnostic and is materialized as `top` for
downstream recovery." Today `top` and `Dynamic[top]` are equally silent — which is
precisely why widening measured free — so the diagnostic does not exist.

Building it needs two pieces that do not exist, and the first forces a naming
decision under the v1.0 vocabulary freeze ([ADR-50](50-release-engineering-and-stability-strategy.md) WD1):

1. The **`static.*` diagnostic family**, reserved in
   [diagnostic-policy.md](../type-specification/diagnostic-policy.md) with **no
   implemented identifiers**. Its reservation text already names *two* duties —
   "static checks that stop short of a proof, **including incomplete-inference
   cutoffs**." Those are opposite failure modes: a value that cannot be used
   without proof reaches a use position (the void case, and later the
   unguarded-`top` case), versus inference itself giving up and widening (the
   budget/fuel cutoffs of [ADR-41](41-inference-budget-design.md) / [#158](https://github.com/rigortype/rigor/issues/158),
   authored `:info`). A flat `static.*` leaf space collides the moment #158 fans
   out per-budget, and the first id shipped would fix the family's shape
   permanently.

2. A **side-table** to carry *why* a `top` at a use site is a recovered `void`
   rather than an ordinary `top` — the spec's own recovery rule ("record that the
   value reached the position by recovery from `void`"). Per
   [ADR-75](75-dynamic-provenance.md), provenance is metadata *about* a value, not
   part of what the value *is*, so this is a side-channel, not a new carrier or a
   lattice fork.

## Decision

> **A `static.*` identifier names a static check that stopped short of a proof;
> the family splits by *which way* it fell short — a value that demands proof
> reached a use (`static.value-use.*`), or inference gave up and widened
> (`static.incomplete-inference.*`). The split is load-bearing because the two
> halves carry opposite default severities and a flat leaf space would collide
> them once the budget half fans out. Provenance for the void case rides a
> `void_origins` side-table modelled on `dynamic_origins`, never a carrier field.**

The criterion is reusable beyond `void`: the unguarded-`top`-call diagnostic
([special-types.md](../type-specification/special-types.md) § `top`) is a future
`static.value-use.top`, and every budget cutoff is a `static.incomplete-inference.*`
id — each new `static.*` id is placed by asking which of the two failure modes it
reports, not by inventing a sibling leaf.

## Working decisions

**WD1 — the two-sub-family split.** Reserve two sub-families under `static.`:

| sub-family | duty | ids | authored severity |
| --- | --- | --- | --- |
| `static.value-use.*` | a value that demands proof reached a use position | **`static.value-use.void`** (first, this ADR); `static.value-use.top` (reserved — the unguarded-`top` half, no ADR yet) | `:warning` |
| `static.incomplete-inference.*` | inference stopped proving and widened | reserved for [ADR-41](41-inference-budget-design.md) / [#158](https://github.com/rigortype/rigor/issues/158): `.recursion`, `.union-size`, … | `:info` |

Severity is per-id, re-stamped through `severity_profile:` at emission (the
pipeline already does this), so a `:warning` value-use id and `:info` cutoff ids
coexist without the family carrying a severity. The reservation text in
diagnostic-policy.md is updated to name both sub-families; the normative row for
`static.value-use.void` lands with its implementation slice.

**WD2 — `static.value-use.void`, direct case only, behind `bleeding_edge:`.** The
first slice fires only where an author *wrote* `-> void` and its result is used in
value context (`x = puts(...)`, `puts(...).foo`). An explicit `-> void` is the
strongest possible "do not rely on this return" signal, so this is the
FP-narrowest real bite — it cannot frighten legitimate `top` use, which is the
failure mode this project weighs heaviest ([AGENTS.md](../../AGENTS.md) §
Implementation Guidelines). It ships behind `bleeding_edge:` because a new required
diagnostic is a compatibility change under [ADR-50](50-release-engineering-and-stability-strategy.md) WD1;
[special-types.md](../type-specification/special-types.md) § `void` already records
this gating.

**WD3 — the `void_origins` side-table, mirroring `dynamic_origins`.** Interface,
by analogy to the shipped `dynamic_origins` (`scope.rb`):

- **Key:** the introduction-site AST node, identity-keyed (`{}.compare_by_identity`) — identical to `dynamic_origins`.
- **Value:** the resolved `-> void` origin site (the method/call whose `void` return was recovered), so the message can say *which* void reached the use — a small cause record, not a carrier field.
- **Populated by:** the return-typing tier, where `void → top` widens — a new `Scope#record_void_origin(node, origin)` beside the existing `record_dynamic_origin`.
- **Consumed by:** a new value-context check rule that fires `static.value-use.void` when a value in value context is present in `void_origins` — parallel to how the `dynamic.*` explanation reads `dynamic_origins` via `origin_lookup.rb`.
- **Flow-state hygiene:** excluded from `Scope#==` / `#hash` and threaded by reference through `#join` (`scope.rb` § advisory metadata), so it never forks a dedup or cache key — the same discipline [ADR-75](75-dynamic-provenance.md) established.

**WD4 — what is deferred, and why.** The **transitive case**
(`def bar; foo; end; a = bar`, where `bar`'s own signature declares nothing) is
strictly harder: today's per-body origin tables reset per method body and do not
carry provenance across a method-return summary, which is exactly what the
transitive case needs. It earns its own downstream slice. The
**`static.incomplete-inference.*` budget identifiers** stay blocked on
[ADR-41](41-inference-budget-design.md) leaving Proposed and its own demand-gated
measurement — this ADR only *reserves* their sub-family so the void id does not
have to anticipate them.

## Rejected / deferred alternatives

- **A flat `static.*` leaf space** (`static.void-use`, `static.recursion-budget`, …). Rejected: it collides use-site guards and inference cutoffs — opposite failure modes with opposite default severities — into one namespace, and the first id would set that flat shape before #158's budget ids arrive to reveal the conflict.
- **A `void` carrier / a lattice fork** (`void` distinct from `top` in the type object). Rejected: [ADR-92](92-normative-status-fidelity.md) already chose `void → top` and measured it free; per [ADR-75](75-dynamic-provenance.md) the "why" is metadata about the value, so a side-table answers it without a carrier the whole engine would have to learn.
- **Building the transitive case now.** Deferred (WD4): it needs return-summary provenance the engine does not carry, raising both the FP surface and the cost in one step.
- **Shipping the void diagnostic `:warning`-on by default (no `bleeding_edge:`).** Rejected: a new required diagnostic is an ADR-50 WD1 compatibility change; the gate is the discipline, and the direct case is already FP-narrow enough to promote once evidence accrues.

## Consequences

- Positive: the spec's `void`-use MUST becomes buildable without a carrier or a freeze-risking flat family; the first `static.*` id lands with the family shape settled, so #158's budget ids slot in without renaming.
- Negative / cost: a new diagnostic id enters the v1.0-frozen vocabulary — deliberate and bounded, but irreversible after the freeze; the `void_origins` side-table is a second advisory table Scope threads (like `dynamic_origins`), a small standing cost.
- Carry-over: `static.value-use.top` (the unguarded-`top` half) and the transitive void case remain reserved/deferred; the `static.incomplete-inference.*` ids wait on ADR-41.

## Relationship to other ADRs

- **ADR-92** — resolved `void → top` and explicitly carried option (a) (the distinct void diagnostic) forward as unfinished design; this ADR is that follow-on.
- **ADR-75** — the provenance-as-side-channel precedent; `void_origins` mirrors `dynamic_origins` in key, hygiene, and consumption.
- **ADR-41 / #158** — own the `static.incomplete-inference.*` half; this ADR reserves their sub-family and defers their ids.
- **ADR-50** — WD1 freezes the diagnostic vocabulary, which is why the family shape is decided here rather than grown ad hoc, and why the first id ships behind `bleeding_edge:`.
