# ADR-76 — Effect modeling for `freeze` / `dup` / `clone` and shape-carrier preservation

Status: **Accepted — WD1 implemented 2026-06-24 (`2751bc78`); WD2
deferred.** Records a split decision on effect / mutation modeling. The
*conservative-invalidation* half — non-mutating calls preserve facts,
aliased-mutation calls invalidate them — is compatibility-safe internal
precision and **landed** as the WD1 slice: `MutationWidening` now treats
`freeze` / `dup` / `clone` / `itself` as pure self-returners
(`PURE_SELF_RETURNERS` + `pure_self_returner?`, early-returns in
`widen_after_call` / `widen_for_outer_receiver`) so they preserve the
receiver's facts instead of invalidating them, no diagnostic or vocabulary
change, self-check clean (the 12 reflexive `always-truthy` did **not**
reappear — the change stays in the invalidation path, not the dispatch
return-type tier). The *shape-carrier preservation through the pure
self-returners*
(`freeze` / `dup` / `clone` / `itself`) — which would close a real fold
gap — is **deferred to a separate branch** (bucket 3) until the reflexive
`flow.always-truthy-condition` interaction it triggers on Rigor's own
self-analysis is resolved at the root. This ADR fixes the scope and the
ordering so the precision fix is not re-attempted cold.

Grounding: the [2026-06-22 strengthening survey](../notes/20260622-rigor-0.2.x-compatibility-safe-strengthening-survey.md)
§4 and its "Compatibility traps to avoid" entry, and the
[2026-06-14 precision-foldgap recon note](../notes/20260614-precision-foldgap-recon.md)
§ "The one real fold gap (found, fix backed out)" — where the
shape-preserving fix was implemented, verified corpus-FP-safe (zero new
firings across 8 projects incl. mail), and then **backed out** because it
surfaced 12 reflexive `always-truthy` firings on Rigor's own
constant-folder.

## Context

Rigor's effect model decides, per call, whether a receiver's recorded
facts survive. Two failure directions exist, and the survey asks for both
to be tightened conservatively:

1. **Over-preservation** — a call that *does* mutate aliased state keeps a
   now-stale fact (a possible-nil / shape / always-truthy false reading).
   `Inference::MutationWidening` already closes the local-rebinding case
   for known in-place mutators (`<<`, `merge!`, …); container/alias
   content mutation is the harder remainder.
2. **Over-invalidation** — a call that *cannot* mutate the receiver drops
   a fact it should keep. The sharpest instance is the **pure
   self-returners**: `() -> self` methods routed through RBS resolve
   against the *nominal* class, so `{a: 1}.freeze` degrades `HashShape` →
   `Hash`, `[1,2,3].freeze` degrades `Tuple` → `Array`, and a subsequent
   `#[]` then types `Dynamic` (the `MESSAGES = {…}.freeze; MESSAGES[reason]`
   gap, `precision-foldgap-recon.md` §). The mutating self-returners
   (`<<`, `merge!`) genuinely change the shape and MUST stay degraded; the
   pure ones (`freeze`, `itself`, `dup`, `clone`) should not.

The recon note's fix — a tier returning the receiver type (preserving the
shape carrier) for those four pure methods — closed the gap and was
corpus-FP-safe. It was backed out for one reason: on Rigor's **own** code,
self-analysis folds `receiver.public_send(method_name)` to a constant, so
preserving the shape made `foldable_constant_value?(result)`
provably-truthy and fired 12 reflexive `flow.always-truthy-condition`
(an over-fold on a runtime-variable `public_send`). Per the project
discipline (fix the cause, never `# rigor:disable`), 12 disables are not
acceptable, and the real root — the reflexive over-fold inside the
`always-truthy` envelope — is a separate, larger change.

## Decision

### WD1 — Conservative invalidation lands now (bucket 1)

The effect model's invalidation rules are tightened toward
**conservative**: a call that cannot mutate its receiver preserves the
receiver's facts; a call that may mutate aliased or escaping state
invalidates them. This is non-contract `Inference::*` internal precision
that *reduces* false positives (stale `always-truthy` / nilability /
shape readings). It carries no new diagnostic and no new vocabulary, so it
ships incrementally per non-mutating method modelled — gated, like any
precision change that can widen a real diagnostic, on a `rigor-survey`
corpus false-positive diff before each default-affecting step (survey P0).

### WD2 — Shape preservation through the pure self-returners is gated (bucket 3)

Preserving the shape carrier (`HashShape` / `Tuple` / `String` literal
facet) across `freeze` / `dup` / `clone` / `itself` is the high-value half
but is **blocked** on the reflexive `always-truthy` interaction. It does
not land until that interaction is fixed at the root, which requires a
separate branch because it is a semantic change to the
`flow.always-truthy-condition` envelope — specifically, the engine must
stop treating a `public_send` / reflectively-folded constant as a
provably-truthy condition (the over-fold), independent of the
shape-preservation tier. Once that lands, the recon note's already-written,
corpus-FP-safe tier is re-applied.

The ordering is load-bearing: shipping the shape tier *before* the
reflexive fix re-introduces the 12 self-check firings, and the discipline
forbids suppressing them.

### WD3 — `freeze` / `dup` semantics on shape carriers

For the four pure self-returners on a shape-carrying receiver, the
intended result type is the **receiver type unchanged** (carrier
preserved), distinguished from the mutating self-returners which keep
today's nominal degradation. `dup` / `clone` additionally produce a fresh
unfrozen alias — but because Rigor's shape carriers are immutable values,
preserving the carrier across the copy is sound for reads; subsequent
*writes* to the copy go through the WD1 mutation path. This is precision
in the FP-safe direction (a preserved shape only ever resolves a fold that
degradation left `Dynamic`).

## Rejected / deferred alternatives

- **Ship the shape-preservation tier now and `# rigor:disable` the 12
  self-check firings.** Violates the project's fix-the-cause discipline;
  the disables would mask a genuine reflexive over-fold. Rejected — the
  reason WD2 is gated, not shipped.
- **Preserve shape carriers through `freeze` / `dup` unconditionally,
  including the reflexive case.** Unsound for the `public_send`-folded
  constant; manufactures the `always-truthy` false positives. Rejected.
- **Optimistic fact preservation as the default invalidation stance.**
  Over-preservation is the more dangerous direction (stale facts fire
  diagnostics on working code); WD1 chooses conservative invalidation
  per the false-positive discipline.

## Consequences

- **Positive:** WD1 reduces spurious `always-truthy` / nilability /
  receiver-shape firings now; WD2, when unblocked, closes the
  `freeze`d-literal fold gap (`MESSAGES[reason]` → the value union instead
  of `Dynamic`) corpus-FP-safe.
- **Negative:** the high-value half waits on a larger reflexive-`always-truthy`
  change on a separate branch; until then `{…}.freeze; h[k]` stays
  `Dynamic` (safe, unprotected).
- **Carry-over:** the reflexive over-fold fix is the actual prerequisite
  and is itself worth scoping (it may resolve other reflexive
  self-analysis artifacts); container/alias *content* mutation
  (over-preservation direction) remains the harder MutationWidening
  remainder.

## Relationship to other ADRs

- [ADR-56](56-block-captured-local-mutation.md) — block/loop captured
  mutation write-back; the same fact-invalidation discipline.
- [ADR-47](47-narrowing-driven-clause-reachability.md) /
  `flow.always-truthy-condition` — the envelope WD2's reflexive over-fold
  lives inside.
- [ADR-48](48-data-struct-value-folding.md) — the member-shape carriers
  (`HashShape` / `Tuple`) whose preservation across `freeze` / `dup` is at
  stake.
