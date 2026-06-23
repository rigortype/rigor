# ADR-75 — `Dynamic[T]` provenance and explanation

Status: **Proposed — 2026-06-24.** `Dynamic[T]` is already the correct
carrier for a value drawn from an unchecked source, but the engine does
not record *why* a value became dynamic. This ADR adds a precision-additive
**provenance** side-channel — a small fixed set of dynamic-origin causes
carried alongside (not inside) the carrier and surfaced additively through
`coverage --protection` labels and `--format json` metadata — so a user
(or an agent) can tell a tractable hole (install RBS, enable a plugin)
from an intractable one (a framework DSL boundary), without changing the
`untyped = Dynamic[top]` relation semantics. Nothing here fires a
diagnostic or feeds severity.

Grounding: the [2026-06-22 compatibility-safe strengthening survey](../notes/20260622-rigor-0.2.x-compatibility-safe-strengthening-survey.md)
§3 / P2 (the highest-value *explanatory* lever) and the [ADR-73](73-skill-driven-user-experience.md)
field-trial follow-up "coverage-tractability labels", which named
`Dynamic`-provenance tracking as its blocking prerequisite and flagged it
as "plausibly its own ADR (touches the `Dynamic[T]` carrier)."

## Context

`rigor coverage --protection` ([ADR-63](63-type-protection-coverage.md))
scores each dispatch site by whether its receiver types to a concrete
(non-`Dynamic`) class — "can Rigor catch a wrong call here" — and reports
a ranked "add a type here" list. The list is honest but blunt:
`Inference::ProtectionScanner`'s `Site` carries the receiver *description*,
yet the engine knows only that the receiver is `Dynamic`, **not why it
became one** (`protection_scanner.rb:73`, `when Type::Dynamic, Type::Top
then false`). A user chasing the list cannot tell which holes a hand-written
RBS could close (an external gem with no `.rbs`) from which it cannot (a
value crossing a framework DSL / macro boundary, an analyzer budget
cutoff, an explicit `untyped` contract).

The `Dynamic` carrier itself is deliberately thin: `dynamic.rb` holds a
single `static_facet`, is frozen, and uses `value_fields :static_facet`
value-semantics so two `Dynamic[String]` values are `==` and dedup in
unions and the cache. That equality is load-bearing, which constrains how
provenance may be attached (WD1).

There is already partial origin signal in the engine —
`Inference::FallbackTracer` and `Inference::BudgetTrace` record some
fallback/cutoff events — but it is diagnostic-trace plumbing, not a
queryable per-value origin consumed by the protection surface.

## Decision

A dynamic value's **provenance** is one of a small, fixed, documented
cause set; the engine records it as a side fact at the point a `Dynamic`
is introduced, and surfaces it additively. The cause set (v1):

| cause id | meaning |
| --- | --- |
| `external-gem-without-rbs` | receiver/return from a gem with no resolvable RBS (the `RbsCoverageReport :missing` class) |
| `framework-dsl-boundary` | value produced across a macro / DSL expansion ([ADR-16](16-macro-expansion.md)) or plugin-declared dynamic return |
| `analyzer-budget-cutoff` | a budget / fuel guard widened to `Dynamic` ([ADR-41](41-inference-budget-design.md), `BudgetTrace`) |
| `explicit-untyped` | the value's type is an authored `untyped` contract |
| `unsupported-syntax` | an inference fallback on a construct the engine does not model |

### WD1 — Provenance is a side-channel fact, never a field on the carrier

Provenance is **not** added to `Type::Dynamic`. Adding a field would break
the `value_fields :static_facet` equality that makes `Dynamic[T]` dedup in
unions and cache keys — two values that are the same type but reached
dynamism by different routes must remain `==`, and the lattice must not
fork by origin. Instead provenance lives in a parallel origin map keyed on
the introduction site (the `FallbackTracer` choke point generalised into a
queryable per-site `dynamic_origin`), read by `ProtectionScanner` when it
classifies a site. This keeps the carrier, the lattice, and the cache
untouched.

### WD2 — Surface additively, structured-not-string

Provenance is exposed only as **additive** output, per [ADR-61](61-agent-friendly-diagnostic-statistics.md):

- `coverage --protection` annotates each "add a type here" hole with its
  cause and a tractability hint (RBS-closeable vs DSL/boundary), and
- `coverage --protection --format json` carries a `dynamic_origin` field
  per site (omit-when-nil), so an agent branches on the datum rather than
  parsing a label string.

No existing field, ratio, or rule id changes; message text stays
presentation.

### WD3 — Preserve `Dynamic[T]` relation semantics

Provenance never participates in subtyping, gradual consistency,
normalization, or erasure. `untyped = Dynamic[top]` is unchanged
(`special-types.md`, `value-lattice.md` bind); provenance is metadata
*about* a dynamic value, not part of *what it is*. A `Dynamic` with a known
cause and one with `nil` cause relate identically.

### WD4 — Relationship to a future strict-dynamic discipline

Provenance is the **evidence base** a later strict-dynamic policy (fail on
an unexplained `Dynamic` value) would consult, but that enforcement is a
new authoring discipline and belongs behind the `bleeding_edge:` overlay
([ADR-50](50-release-engineering-and-stability-strategy.md); the first such
discipline is its own ADR, gated on this one). This ADR ships explanation
only — it adds no obligation and breaks no clean run.

## Rejected / deferred alternatives

- **Add a `provenance:` field to `Type::Dynamic`.** Breaks the
  `value_fields` equality that dedups `Dynamic[T]` in unions and cache
  keys, and forks the value lattice by origin — a soundness and
  cache-correctness hazard for a purely explanatory datum. Rejected; the
  side-channel map (WD1) gives the same information with none of it.
- **Make provenance a hard, default-on diagnostic** ("this value is
  dynamic because…"). Violates the false-positive discipline — a dynamic
  value is not an error, and most are correct. Any enforcement is
  deferred to `bleeding_edge:` (WD4).
- **Infer provenance lazily at report time** by re-deriving why a receiver
  is dynamic. Re-runs inference reasoning at the wrong layer and can
  disagree with the engine's actual fallback path; recording at the
  introduction site (WD1) is the single source of truth.

## Consequences

- **Positive:** turns a generic "dynamic receiver" hole into a next
  action (install RBS / enable a plugin / report an analyzer gap),
  unblocking the ADR-73 coverage-tractability-labels follow-up and
  sharpening `rigor-next-steps` / a future `rigor doctor` routing; gives
  an eventual strict-dynamic discipline a measured evidence base.
- **Negative:** a new structured `dynamic_origin` field becomes public
  vocabulary once exposed (frozen at v1.0 under ADR-50 WD1), so the cause
  ids must be chosen deliberately; the origin map adds a small per-run
  side table at the `FallbackTracer` choke point.
- **Carry-over:** the cause set is intentionally coarse for v1; finer
  causes (which budget, which DSL) are demand-gated additions to the same
  field.

## Relationship to other ADRs

- [ADR-63](63-type-protection-coverage.md) — consumes provenance to label
  protection holes by tractability.
- [ADR-61](61-agent-friendly-diagnostic-statistics.md) — the
  structured-not-string rule this surfaces under.
- [ADR-50](50-release-engineering-and-stability-strategy.md) — a
  strict-dynamic discipline built on provenance ships via `bleeding_edge:`.
- [ADR-41](41-inference-budget-design.md) — budget cutoffs are one
  provenance cause.
