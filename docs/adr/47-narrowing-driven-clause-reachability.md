# ADR-47 — Narrowing-driven clause reachability (`flow.unreachable-clause`)

Status: **Accepted — WD1 implemented. Extends Rigor's two existing `if`/`unless` reachability rules to `case`/`when` clauses, using the narrowing the flow engine already computes. Inspired by Elixir v1.20's redundant-`case`-clause reporting; scoped to stay inside Rigor's false-positive envelope.**

**WD1 landed (v0.1.17).** `flow.unreachable-clause` fires when a `case <local>` clause's class/module-constant condition (`when String` / `when MyClass`) narrows the subject to `Type::Bot` — read back from `scope_index` (the evaluator's own per-clause `body_scope`), so the rule and the body typing cannot diverge. The single `body_scope == bot` signal covers both shapes the design names (per-clause disjointness AND prior-exhaustion) since an exhausted entry scope narrows to `bot` too. FP envelope enforced: subject must be a narrowing local, never `Dynamic` (gradual guarantee) nor already-`Bot` (dead code), class/module-constant conditions only (`when nil` / ranges / regexps / expressions excluded), clauses inside loops/blocks skipped. Per **WD4**, it ships at `:info` in lenient + balanced (the default) and `:warning` only in strict, pending the regression-corpus FP gate before any balanced→`:warning` promotion; clean (zero firings) on Rigor's own `lib` + `plugins` + `examples`. **Remaining:** WD2 message precision (distinguish prior-exhaustion in the diagnostic text + flag a dead trailing `else`), WD3 (`in`/pattern clauses, gated behind `InNode` exhaustiveness), WD4 (the Mastodon/GitLab/Redmine corpus triage to promote to `:warning`).

## Motivation

The Elixir v1.20 type system (see
[`docs/notes/20260604-elixir-v1.20-type-system-rigor-review.md`](../notes/20260604-elixir-v1.20-type-system-rigor-review.md))
refines the scrutinee type across `case` clauses and **reports clauses
that can never match as dead code** — a high-signal, low-false-positive
diagnostic class, because a clause the type proves unreachable is almost
always a real logic error (stale `when`, mis-ordered clauses, a type that
moved out from under a branch).

Rigor already does the hard half of this work. What it is missing is the
diagnostic on top of it, and only for `case` — `if`/`unless` are already
covered.

## What exists today

Two reachability rules, both restricted to `IfNode` / `UnlessNode`:

1. **`flow.unreachable-branch`** (v0.1.2) — fires only when the predicate
   is a **syntactic literal** (`if false`, `expr if true`, …). Points at
   the dead branch. Deliberately literal-only to avoid the inferred-
   constant false positives named in
   [`check_rules.rb:1013`](../../lib/rigor/analysis/check_rules.rb).
2. **`flow.always-truthy-condition`** — the inferred-constant counterpart.
   Fires when a non-literal predicate folds to `Type::Constant`, with a
   conservative envelope: skip predicates **inside a loop / block**
   (mutation tracking is incomplete) and skip **defensive predicate
   calls** (`nil?` / `empty?` / `zero?` / `respond_to?` / …), where
   strict-on-returns RBS routinely disagrees with a real runtime check
   (`Module#name -> String` vs. anonymous-class `nil`). See
   [`always_truthy_condition_collector.rb`](../../lib/rigor/analysis/check_rules/always_truthy_condition_collector.rb).

The flow engine **already narrows `case`**. `eval_case_when_branches`
([`statement_evaluator.rb:527`](../../lib/rigor/inference/statement_evaluator.rb))
threads a `falsey_scope` accumulator across `when` branches, and
`Narrowing.case_when_scopes`
([`narrowing.rb:338`](../../lib/rigor/inference/narrowing.rb)) returns, for
each branch, a `body_scope` (subject narrowed by the clause's truthy edge)
and a `falsey_scope` (subject narrowed by the conjunction of every prior
clause's negation). So at every `when` we already compute the subject's
type *given that no earlier clause matched* — which is exactly the fact a
reachability diagnostic needs.

Two gaps:

- **No `case` clause ever produces a reachability diagnostic.** The
  narrowing is consumed only to type branch bodies.
- **`in` (pattern-match) branches do not track exhaustiveness.**
  `branch_body_and_falsey_scopes`
  ([`statement_evaluator.rb:542`](../../lib/rigor/inference/statement_evaluator.rb))
  leaves `falsey_scope` unchanged for `InNode` ("conservative: no
  exhaustiveness tracking yet").

## The disjointness signal

A `when C` clause is unreachable when the subject's type — under the
`falsey_scope` entering that clause — is **disjoint** from `C`'s match
type. That is exactly Elixir's `dynamic()` *compatibility* test
("violation only when accepted and supplied types are disjoint"), and
Rigor already has the carrier algebra to express it.

The substrate gives the signal for free: narrowing the entry
`falsey_scope` by clause `C`'s truthy edge yields a `body_scope` whose
subject local is **`bot`** (empty intersection) precisely when `C` cannot
match. No new disjointness predicate is required — a `bot` subject local
in the computed `body_scope` *is* the unreachability proof. Two shapes
fall out:

1. **Per-clause disjointness** — subject type ∧ clause type = `bot`
   (e.g. subject narrowed to `Integer`, a later `when String`).
2. **Prior-exhaustion** — the `falsey_scope` entering the clause already
   carries a `bot` subject (every earlier clause, unioned, covered the
   subject type), so this clause and all after it are dead.

## Design

### New rule: `flow.unreachable-clause`

- **Fires on:** a `WhenNode` (and, gated, an `InNode`) inside a `CaseNode`
  / `CaseMatchNode` whose computed `body_scope` narrows the subject local
  to `bot`, OR whose entry `falsey_scope` already carries a `bot` subject.
- **Points at:** the dead clause's `statements` (the body that never
  runs), mirroring `flow.unreachable-branch`'s "squiggle on the dead
  code" placement. Skip clauses with empty bodies (no useful location),
  same as the literal rule.
- **Severity:** `warning`, matching its two `flow.*` siblings. Wire into
  all three tiers of
  [`severity_profile.rb`](../../lib/rigor/configuration/severity_profile.rb)
  (`info` / `warning` / `error`) alongside `flow.unreachable-branch`.
- **Suppression:** `# rigor:disable unreachable-clause` on the dead-clause
  line, registered in
  [`rule_catalog.rb`](../../lib/rigor/analysis/rule_catalog.rb).

### Mechanism

The narrowing is already computed in `eval_case_when_branches`; the rule
needs the per-branch `(body_scope, falsey_scope)` pair surfaced to the
diagnostic pass. Prefer **collecting at evaluation time** (a collector
analogous to `AlwaysTruthyConditionCollector`, fed the subject + narrowed
scopes) over recomputing narrowing in `check_rules`, so the rule and the
body-typing read identical narrowing and cannot diverge.

### False-positive envelope (inherited, non-negotiable)

Reuse `flow.always-truthy-condition`'s envelope verbatim — this rule is
the same risk class:

- **Subject must narrow.** `case_when_scopes` already bails to the entry
  scope unless the subject is a `LocalVariableReadNode` with a known type
  ([`narrowing.rb:364`](../../lib/rigor/inference/narrowing.rb)). No
  narrowing ⇒ no firing. This alone excludes most risky shapes.
- **Skip inside loops / blocks** — same mutation-tracking gap.
- **Skip defensive-shaped subjects / clauses** — don't fault a `when nil`
  guarding against an RBS-strict return the engine believes can't be nil.
- **Require a concrete narrowed carrier** — fire on `Nominal` / `Constant`
  / `Tuple` / disjoint unions; never on `Dynamic[T]` or an unresolved
  shape. Disjointness against `Dynamic` is never provable, so it never
  fires there — the gradual guarantee holds.

## Work-decision slices

- **WD1 — `when` disjointness (per-clause).** The narrow, high-value core:
  `when C` whose `body_scope` subject is `bot`. Literal-class `when` first
  (`when String` / `when MyClass`), the shape `case_when_scopes` already
  recognises.
- **WD2 — prior-exhaustion.** Flag a `when` (and trailing `else`) made
  dead by the union of earlier clauses. Needs the `falsey_scope` `bot`
  check; same accumulator, no new narrowing.
- **WD3 — `in` clauses (gated).** Extend only after
  `branch_body_and_falsey_scopes` learns pattern-exhaustiveness for
  `InNode`. Deferred behind that work; pattern disjointness is a larger,
  separate precision project (the deferred ADR-36 `is_a?` exhaustiveness
  is the neighbour). Do **not** ship WD3 by inferring exhaustiveness ad
  hoc.
- **WD4 — corpus FP gate.** Before default-on, run the rule across the
  regression corpus (Mastodon / GitLab / Redmine per
  [`reference_survey_external_projects`]) at `--no-cache` and triage every
  hit to zero net false positives, exactly as ADR-43 gated `check-plugins`.
  Ship `info` (or behind a flag) until that gate is green.

## Rejected / deferred alternatives

- **Recompute narrowing in `check_rules`** (don't reuse the engine's
  scopes) — rejected: two narrowing paths drift, and divergence here is a
  false positive, the cardinal sin
  ([`feedback_false_positive_discipline`]). Collect at evaluation time.
- **Fire on `Dynamic[T]` subjects** — rejected: disjointness is never
  provable under gradual `Dynamic`, so a fire there is unsound *and* a
  false positive. This is the boundary Elixir's *compatibility* rule draws
  too.
- **Full pattern-match exhaustiveness for `in`** — deferred to its own
  work (WD3 + ADR-36 neighbour). Out of scope here.
- **Soundness via Elixir-style strong arrows** — not pursued. Rigor is
  deliberately unsound under the robustness principle
  ([ADR-5](5-robustness-principle.md)); this rule reports only the
  *provable* `bot` case and stays inside that envelope. Recorded for
  contrast, not adopted.

## Grounding

- [`docs/notes/20260604-elixir-v1.20-type-system-rigor-review.md`](../notes/20260604-elixir-v1.20-type-system-rigor-review.md) — the source comparison (§4-2).
- [`docs/type-specification/control-flow-analysis.md`](../type-specification/control-flow-analysis.md) — narrowing / fact-stability contract this rule reads.
- [`docs/type-specification/diagnostic-policy.md`](../type-specification/diagnostic-policy.md) — `flow.*` taxonomy + severity resolution.
- [ADR-36](36-mangrove-enum-nested-class-emission.md) — the deferred `is_a?` exhaustiveness work WD3 depends on.
