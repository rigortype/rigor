# ADR-62 — Mutation-testing the analyzer (false-negative / teeth measurement)

Status: **Accepted — harness + first fixes landed 2026-06-13; the methodology and its
adjudication discipline are in force; the remaining backlog is demand-gated.** A dev-only
mutation harness (`tool/mutation/`) breaks analyzed code in type-visible ways and reads
*surviving* mutants as false-negative candidates — the dual of Rigor's anti-false-positive
discipline. A `lib/rigor` sweep produced a ranked backlog; two fixes have landed from it
(union-receiver undefined-method teeth; RBS class-alias resolution), one candidate was
adjudicated as *deliberate silence* and deferred, and the rest is recorded below.

Grounding: [`docs/notes/20260613-mutation-teeth-harness.md`](../notes/20260613-mutation-teeth-harness.md)
(mechanism, the sweep tables, per-cluster triage).

## Context

Rigor's entire development discipline is **anti-false-positive**: "the program works"
outranks a worst-case static reading ([`feedback_false_positive_discipline`]), and the
corpus byte-identical gates measure *did we change behaviour*. Nothing systematically
measured the **dual axis** — *do we have teeth at all*: where does breaking the code fail
to make Rigor complain (false negatives / blind spots)? "Teeth verified" appears
anecdotally across ADR-43 / ADR-24 but was never a measured, regression-trackable
quantity. This is the gap; the pre-freeze window (post-v0.1.19) is when it is worth
closing, because the diagnostic *vocabulary* is about to be frozen (ADR-50) and we want
evidence that the rules behind it bite.

## Decision

Adopt **mutation-testing of the analyzer** as the standing practice for measuring
false negatives: inject a type-visible mutation into a clean file, re-run the analysis on
the mutated bytes, and treat a *surviving* mutant (no new diagnostic) as a false-negative
candidate. Two criteria govern how the output is read — they are the reusable rules, not
the tooling:

- **Criterion A — a survivor is signal only where Rigor holds a concrete type.** A type
  checker sees only a subset of bugs, so most mutations are type-invariant *equivalent
  mutants* and their survival is **correct** (FP discipline working). The raw kill-rate is
  therefore noise; the **type-aware anchor filter** (mutate only where the receiver whose
  contract the mutation could violate types non-`Dynamic`) is what makes the metric mean
  anything. This is load-bearing, not cosmetic — and it is why the harness is in-process
  (only an in-process tool can ask the engine for its own `type_of`).
- **Criterion B — adjudicate, don't assume.** A survivor is a *candidate*, not a bug. Each
  is adjudicated against the spec / existing decisions; some are **deliberate silence**
  (the N3 `T | nil` case below). A fix lands only when it adds teeth where soundness is
  **total** and `make verify` stays clean (no new firing across lib + plugins). This is
  the same adjudicate-per-class protocol ADR-57 used.

## Working decisions

- **WD1 — build our own, Prism-native, in-process; `mbj/mutant` rejected.** A meaningful
  metric needs type-aware site selection (Criterion A), which requires the engine's own
  `type_of` — only an in-process tool can do that. `mutant` is also whitequark-`parser`
  based (Rigor is Prism; harmless only at the source-text boundary), its process model
  fights the warm in-process loop, and its operator set is tuned for behavioural test
  suites (mostly type-invariant → noise for a type checker). The mutator splices source by
  Prism byte offsets — no unparser; the analyzer re-parses. `tool/mutation/mutate.rb`.
- **WD2 — the warm loop makes corpus-scale sweeps tractable.** `LanguageServer::ProjectContext`
  builds the RBS environment + whole-project `ProjectScan` once; each mutant reuses them
  via `Runner.new(environment:, prebuilt:)` + `#run_source` (in-memory overlay). `prebuilt:`
  forces `run_result_cacheable?` false, so the run-result cache — which digests the *disk*
  file — is bypassed and a mutant is never served a stale clean hit. ~400 ms cold, then
  ~6–12 ms/mutant.
- **WD3 — sweep-as-backlog.** `mutate.rb sweep <paths…>` runs a corpus over one warm
  session and clusters survivors by `(operator, receiver type)`, count-ranked; `--json`
  emits the same for an agent (ADR-61 flavour), closing a self-improving loop
  (sweep → agent fixes → re-measure-kill). Default operators exclude `arity_extra`
  (appending an arg to a variadic/optional method is an equivalent mutant — noise); the
  filter treats a union with any `Dynamic`/`Top`/`Bot` arm as non-concrete.
- **WD4 — dev-only, off the ADR-50 frozen surface.** The harness is not a CLI command and
  contributes no diagnostic contract. It drives engine work; it is not shipped.
- **WD5 — landed fixes (evidence the loop works).**
  - *Union-receiver undefined-method teeth.* `call.undefined-method` now fires on a union
    receiver when the method is absent on **every** non-nil arm (`A | B` responds to `m`
    iff both do). FP-safe by construction: `union_undefined_method_diagnostic`
    (`check_rules.rb`) reuses the permissive `method_present_anywhere?` (any Dynamic /
    unknown / source-declared arm ⇒ "present" ⇒ no fire) plus an arm guard that bails on
    any open (ADR-26) / synthesized / singleton / module-mixin arm. Pure non-nil unions
    only.
  - *RBS class-alias resolution.* `class Mutex = Thread::Mutex` lived only in
    `class_alias_decls`, so `class_known?` reported it but the definition builder (guarding
    on `class_decls`) could not enumerate its methods — leaving every alias class
    known-but-methodless. `RbsLoader#canonical_module_name` normalises an alias to its
    target before the guard, fixing dispatch *and* the existence check on `Mutex` and any
    `X = Y`.

## Rejected / deferred alternatives

| Alternative | Verdict |
| --- | --- |
| `mbj/mutant` as the engine | **Rejected** — type-aware site selection needs in-process `type_of`; parser mismatch + process-model + behavioural-suite operators (WD1). |
| `arity_extra` in the default operator set | **Dropped to opt-in** — most Ruby methods accept an extra arg (splat/optional), so it is an equivalent-mutant noise factory; a signature-arity guard would make it default-worthy (follow-up). |
| Fire on **nilable** unions (`String?`) | **Studied + REJECTED — N3 silence kept.** The N3 decision (`safe_navigation_undefined_method_spec.rb`) intentionally keeps `T \| nil` silent. A bundled-arm-narrowed candidate was run across 13 projects (ActiveSupport-heavy + plain): **zero genuine nilable-union firings** (~0 teeth gain) while the self-check surfaced a real loss-of-specificity FP (`plugin_class : Class` holds a `Plugin` subclass with `.manifest`). ~0 benefit + FP-proneness + the cost of overriding a deliberate decision ⇒ not worth it. The study still hardened the *shipped* slice-1 with two FP guards it harvested: a generic-`Class`/`Module` arm guard, and a **distinct-class guard** (fire only on a genuinely multi-class union, not a `Hash[K1] \| Hash[K2]` shape join — which fixed a real external slice-1 FP on mail's `compose_codepoints`). |
| `argument-type-mismatch` low-teeth cluster | **Deferred** — mixed: `h[nil]` is correct (any key) but `Integer#>=(nil)` is a real miss; needs per-site adjudication, not a blanket fix. |
| `Type::*` carriers' missing method RBS (self-dogfood) | **Deferred** — sig-coverage work; improves self-check teeth, no user-facing urgency. |
| Broad-fuzz mode (crash / hang / soundness detection) | **Landed — clean.** `mutate.rb fuzz <paths…>` runs the warm loop with aggressive un-filtered mutation (every operator, every site) and reports mutants that make the analyzer crash (`internal analyzer error:` — the Runner's own rescue), hang (per-mutant timeout), or — with `--repeat` — return non-deterministic diagnostics (which would break the cache's byte-identical contract). The soundness check is *non-determinism* (run twice, compare), not "remove/flip a baseline diagnostic" (ill-defined for arbitrary mutation). First run: 2,706 mutants over all of `lib/rigor`, **zero crashes / hangs** — the analyzer is robust against arbitrary type-visible mutation of its own tree. |
| User-facing "type-protection coverage" report | **Proposed / demand-gated** — a `coverage`-command sibling that reports, per file/method, the fraction of type-relevant mutations Rigor kills ("where adding a type buys real protection"). Must be framed as effectiveness / where-to-add-a-type, **never** raw survival (the Criterion-A trap would otherwise frighten working code). Mature the internal tool + operator set + perf story first. |

## Consequences

- **Positive** — teeth become a measured, regression-trackable quantity; the sweep
  *generates* a ranked engine backlog instead of relying on hand-found gaps; the `--json`
  path makes it an agent-actionable self-improving loop; two real false negatives are
  already closed, each `make verify`-clean.
- **Negative** — interpretation burden: the raw kill-% misleads (inflated by arity noise,
  deflated by the argument channel), so the practice depends on the filter + adjudication
  discipline being applied. The sweep is CI-time, not interactive. The harness is dev
  maintenance surface (encoding, mutant validity, operator coverage).
- **Carry-over** — the backlog rows above are the demand-gated queue; the grounding note
  is the living tracker.

## Relationship to other ADRs

- **Dual of the FP discipline.** Complements the corpus byte-identical gates ("did we
  change behaviour") and is the false-negative sibling of the `rigor-regression-sweep`
  skill (which tracks false-positive / surfaced-diagnostic drift).
- **ADR-23 / ADR-61** — the `--json` backlog reuses the structured, agent-consumable
  shape those ADRs established.
- **ADR-26** — the union teeth rule's arm guard honours open-receiver surfaces.
- **ADR-57** — same adjudicate-per-class discipline (Criterion B).
- **ADR-50** — the harness sits deliberately off the frozen public surface (WD4).
- **ADR-43 / ADR-24** — make the "teeth verified" claims those ADRs assert anecdotally
  into a measurable quantity.
