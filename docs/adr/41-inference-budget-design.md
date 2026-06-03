# ADR-41 — Inference budget design (wiring, on-hit policy, measurement-gated defaults)

Status: **Proposed, 2026-06-03.** Records the target design for Rigor's
inference budgets after a survey established that the spec's `budgets:`
table is normative-for-v1 but largely **unwired**, and that the
categories that drive real cost on large apps are exactly the unwired
ones. Nothing here is implemented yet; the work is sequenced as Layer 1
(doc/spec hygiene) and Layer 2 (wire the load-bearing budgets) below.

Grounding:
[`docs/notes/20260603-inference-budget-reality-survey.md`](../notes/20260603-inference-budget-reality-survey.md)
(the Rigor measurement) and
[`docs/notes/20260603-inference-cutoff-prior-art.md`](../notes/20260603-inference-cutoff-prior-art.md)
(how six other checkers solve it). Normative spec:
[`docs/type-specification/inference-budgets.md`](../type-specification/inference-budgets.md).

## Context

### What the spec promises vs. what the engine does

[`inference-budgets.md`](../type-specification/inference-budgets.md)
defines a ten-row configurable `budgets:` table (`recursion_depth`,
`call_graph_width`, `operator_ambiguity`, `union_size`,
`structural_growth`, `interface_candidates`, `hash_erasure_keys`,
`hash_erasure_values`, `negative_fact_display`) plus a `static.*`
incomplete-inference diagnostic family. A 2026-06-03 survey found:

- **No `budgets:` key is parsed and no row is enforced.** The only
  operative cutoffs are three hard-coded, silent, non-configurable
  guards — the `(receiver, method)` recursion re-entry guard (effective
  depth 1 → `Dynamic[top]`), the 100-node ancestor-walk cap, and the
  ADR-20 HKT reducer's 64-step fuel — plus ADR-10's per-gem
  `budget_per_gem` (the one configurable budget, opt-in only).
- **The wired guards are orthogonal to the real cost cliff.** They fire
  on small recursive-descent parsers (haml 421, jbuilder 126 hits) and
  keep them fast; the slowest corpus project (Redmine: 331 files, 172 s,
  **1.5 GB**) fires the recursion guard only 71 times and sails past all
  three guards uncapped. The memory profile points straight at unbounded
  union / structural growth — the unwired `union_size` /
  `structural_growth` categories.
- **The manual mis-documents `budget_per_gem`** (claims "time budget in
  ms, default 1000"; it is a method-definition count, default 5000), and
  there is no user-facing explanation of budgets at all.

### What the prior-art survey established

Rigor is **camp (b)** — whole-program / deep inference without required
signatures (the recursion guard exists *because* of this) — with a
**camp-(a) escape hatch** (an RBS / inline-RBS / generated boundary
signature stops the deep inference). Among the six surveyed tools:

- **Sorbet / Steep / mypy** (camp a, or camp-a-for-returns) sidestep the
  problem: mandatory signatures at boundaries, local-only inference. No
  union-size / iteration budgets needed. mypy additionally *widens with
  join* to a common supertype, trading precision for a fast fixed point.
- **TypeScript / Pyright** (camp b) use dense **counting** budgets and
  mostly **error** on overflow (TS2589 / TS2590; Pyright
  `maxCodeComplexity`).
- **PHPStan / Psalm** (camp b) use **widening** of value-tracked types
  (array → general array at 256 keys, etc.), always silent. PHPStan's
  removal of a constant-scalar union cap caused **OOM regressions** —
  proof the caps are load-bearing.
- **TypeProf** (camp b, the closest analogue: whole-program, no required
  sigs) **widens to `untyped`** at `union_width_limit = 10` and
  `type_depth_limit = 5`, never errors, and made its fixpoint incremental
  in v2 so the budget is re-spent per-edit.

The decisive observations: (1) Rigor's design twins TypeProf, whose
`union_width_limit = 10` is **tighter** than Rigor's spec `union_size =
24`; (2) silent widening is mainstream but universally criticized for
opacity; (3) caps must exist but their *values* come from the observed
distribution, not a guess.

## Working Decision

### WD1 — Keep the camp-(b)-with-escape-hatch architecture; budgets are intrinsic, not a bolt-on

Rigor will continue to infer user-method returns deeply (no mandatory
signatures — that is the product). Therefore inference budgets are a
**permanent, intrinsic** part of the engine, not a temporary scaffold:
deep inference without budgets cannot terminate on real code. The
boundary contract (a return annotation / RBS / `sig-gen` stub) stays the
**first-class escape hatch** — the same role explicit return types play
in TypeScript and mandatory `sig`s play in Sorbet. A budget hit is
always resolvable by the user supplying a contract, never only by editing
a Rigor-only knob.

### WD2 — On-hit policy: **widen *and* diagnose** (the differentiator)

Every budget hit degrades to a conservative type (`Dynamic[top]` / the
declared bound / `untyped`) — **widening, like TypeProf / PHPStan / mypy,
never erroring like TypeScript.** This preserves the
false-positive-discipline value: a budget must never turn working code
into a reported error.

But Rigor will **also emit a `static.*` incomplete-inference diagnostic**
(`:info` by default) recording *which budget fired and where*. This is
the gap every surveyed widening tool leaves open — mypy's silent join to
`object`, Pyright's silent "pin", TypeProf's anonymous `untyped` — and
the one the spec already calls for. The product claim is: **widen like
TypeProf, but tell the user where inference stopped, like nobody else
does**, so a `Dynamic[top]` is never indistinguishable between "genuine
open surface" and "budget cutoff." `RIGOR_BUDGET_TRACE` (shipped
2026-06-03) is the aggregate-only debugging precursor; the per-site
`static.*` diagnostic is the real surface.

### WD3 — Defaults are **measurement-gated**, not guessed

For any budget whose value trades precision for tractability
(`union_size`, `structural_growth`, and any future value/shape cap), the
default MUST be chosen from an **observed distribution** on real
projects, not reasoned from first principles. Rationale: PHPStan's
OOM-on-removal and the FP-discipline value both show the cost of a wrong
cap is asymmetric — set it too low and a genuine `A | B | … | N` union
collapses to `top`, manufacturing a false positive or silently losing
checking. Procedure: instrument the actual join-arity and shape-member
growth distributions (the `BudgetTrace` approach, extended from counters
to histograms) on Redmine + Mastodon, then set the default at a
percentile of the observed tail that captures the pathological cases
without clipping legitimate ones. The spec's current 24 / 16 are
**placeholders pending this measurement**, and the prior-art anchors
(TypeProf 10 / 5) suggest the true values may be *lower* than 24.

### WD4 — Two budget styles, assigned per category

- **Termination guards stay counting + hard** (non-negotiable for
  correctness): recursion re-entry (the depth floor), ancestor-walk
  (100), HKT fuel (64). These cannot be disabled below their floor; a
  project cannot opt into non-termination.
- **Precision budgets are widening + configurable**: `union_size`,
  `structural_growth`, and the `hash_erasure_*` display caps generalize
  to a supertype and are user-tunable within a validated range (the spec
  already specifies ranges). This mirrors **Psalm's** model — the one
  surveyed tool that exposes precision budgets as documented settings —
  including a Psalm-style "tuning these changes precision, not
  correctness; surprises are not bugs" caveat.

### WD5 — `recursion_depth`: split termination floor from precision-unroll depth

The spec's `recursion_depth = 5` conflates two things the engine does
not. Redefine:

- a **termination floor** (hard, ≥1): the re-entry guard that prevents
  non-termination. Wired today at depth 1.
- an optional **precision-unroll depth** (default 1 = off): how many
  levels of a recursive method Rigor unrolls *to gain return precision*
  before widening. None of the surveyed camp-(b) tools unroll general
  recursion for precision (TypeProf widens to `any` at depth 5 with no
  precision claim), so unrolling is a **deferred, demand-driven**
  refinement, not part of the floor.

Align the documented `recursion_depth` default to the implemented reality
(1) and document the two meanings separately.

### WD6 — Complete the documented table

Add the two real-but-unlisted guards — `ancestor_walk` (100) and
`hkt_fuel` (64) — to the budget table so the documented set matches the
enforced set. Neither fired anywhere in the corpus, so the values are
generous; keep them hard-coded (not configurable) until a project shows
they bind.

## Evaluation verdict (2026-06-03)

Asked "maintain the current thresholds vs. search for better defaults vs.
can't even evaluate until the unwired mechanisms are wired" — the honest
answer is that this is **not one global choice; it partitions by budget
category**, and applying any single verdict to the whole table is wrong.

| budget group | wired? | verdict | why |
|---|---|---|---|
| termination guards (recursion depth-1, ancestor 100, HKT fuel 64) | yes | **maintain** | zero corpus evidence they misbehave: the recursion guard keeps parsers fast and is FP-safe (widens to `Dynamic[top]`), ancestor + fuel never fired. Tuning has no observed benefit. |
| `budget_per_gem` | yes | **maintain value, fix the doc** | the per-gem demo showed 5000 fully covers the tested gem (plateau at 5000 = 20000); the default is sound, only the manual is wrong. |
| **`union_size` / `structural_growth`** | **no** | **un-evaluable until measured** | nothing enforces them, so there is no observable effect to judge 24 / 16 against, and "searching for a better default" is searching over a disconnected knob. |
| `call_graph_width`, `overload_candidates`, `operator_ambiguity`, `interface_candidates` | no | defer | never bound any corpus project. |

**Dominant conclusion.** For the only budgets that matter to the problem
that motivated this work (the large-app cost cliff — Redmine 1.5 GB), the
"better-defaults" question is **currently unanswerable**, and maintaining
the status quo leaves the cliff unaddressed. So the gating action is
**neither threshold tuning nor status-quo acceptance** — it is the
read-only distribution measurement (Slice 2a): instrument the *actual*
join-arity and shape-growth distributions on Redmine / Mastodon **without
yet enforcing a cap**. That is the cheapest step that converts
"un-evaluable" into "evaluable", validates whether 24 is even in the
right range (the TypeProf prior is 10), and supplies the observed tail
that WD3 requires before any default is chosen. Picking a value before
2a would repeat PHPStan's cap-removal-OOM mistake in reverse.

**Caveat.** "Maintain" for the termination guards means "no evidence to
change", not "proven optimal": the recursion guard fired 421× on haml,
but whether those `Dynamic[top]` widenings cost real *precision / FPs*
was not measured (only firing *counts* were). If the guards are ever
revisited, that too needs a distribution-of-impact measurement, not a
guess — the same discipline as Layer 2.

## Slices

- **Layer 1 — doc/spec hygiene (cheap, high-confidence, no new
  measurement).**
  - Fix the `docs/manual/03-configuration.md` `budget_per_gem` bug (unit
    = method-def count, default 5000).
  - Reconcile `recursion_depth` per WD5 (default 1; split the two
    meanings).
  - Add `ancestor_walk` / `hkt_fuel` to the table (WD6).
  - Author the missing user-facing budget explanation (placement TBD —
    handbook appendix vs. manual section).
- **Layer 2 — wire the load-bearing budgets (consequential,
  measurement-gated).**
  - 2a. Extend `BudgetTrace` from counters to **distributions** (record
    join-arity and shape-member growth per site); run on Redmine +
    Mastodon to get the observed tails (WD3).
  - 2b. Wire `union_size` + `structural_growth` enforcement with
    widening + the `static.*` diagnostic (WD2), defaults chosen from 2a.
  - 2c. Make the precision budgets user-configurable under `budgets:`
    with range validation + the Psalm-style caveat (WD4).
- **Deferred:** the remaining unwired rows (`call_graph_width`,
  `overload_candidates`, `operator_ambiguity`, `interface_candidates`)
  never bound a corpus project; wire on demand. Precision-unroll depth
  (WD5) is demand-driven.

## Relationship to other ADRs

- **ADR-4 (inference engine)** and **ADR-5 (robustness principle)** —
  budgets are the operational form of "strict on returns, lenient on
  inputs, never frighten working code": at a budget, Rigor widens rather
  than reports. WD2's diagnose-don't-error is the ADR-5 reading.
- **ADR-10 (dependency-source inference)** — `budget_per_gem` is the one
  already-wired budget and the template for WD4's configurable + ranged +
  diagnostic-emitting model (`dynamic.dependency-source.budget-exceeded`
  is the existing precedent for the `static.*` surface WD2 generalizes).
- **ADR-20 (lightweight HKT)** — the reducer's fuel budget is one of the
  termination guards WD4/WD6 keep hard-coded.

## Rejected / deferred alternatives

- **Move Rigor to camp (a) (require signatures, infer locally).**
  Rejected: deep inference without mandatory annotations is the product
  (the [robustness principle](../type-specification/robustness-principle.md)
  / "works on unannotated Ruby" promise).
  Camp (a) would dissolve the budget problem but is a different tool
  (Sorbet / Steep already occupy it).
- **Error on budget hit (TypeScript model).** Rejected for the default
  path: erroring on a budget violates false-positive discipline on
  working code. The `static.*` diagnostic is `:info`, not an error.
- **Pick `union_size` / `structural_growth` defaults now by reasoning.**
  Deferred to measurement (WD3) — the PHPStan OOM-on-removal and the
  asymmetric cost of a wrong cap make a guessed value the higher risk.
- **Make every budget configurable.** Rejected: termination guards (WD4)
  must not be disable-able below their floor; only precision budgets are
  user-tunable.

## Consequences

- A clear, intrinsic role for budgets: permanent termination machinery
  for a deep-inference engine, with a user-resolvable escape hatch and a
  per-site diagnostic that no surveyed competitor provides.
- A concrete, low-risk Layer 1 (doc/spec corrections) that can land
  immediately, and a measurement-gated Layer 2 that resolves the actual
  large-app cost cliff without risking false positives.
- The documented budget table will finally match the enforced set, and
  `budget_per_gem` will be correctly described.
- Open question carried forward: the exact `union_size` /
  `structural_growth` defaults await the Layer 2a distribution
  measurement; the prior-art anchors (TypeProf 10 / 5) are the working
  priors.
