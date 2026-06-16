# ADR-67 — Parameter type inference (the M3 frontier): call-site and in-body, precision-additive only

Status: **Accepted — WD1 + WD3 + WD5 (capped fixpoint) implemented 2026-06-16; the
`check`-walk wiring deferred (demand-gated).** Re-opens the algorithm-corpora
survey's "M3 — untyped-param → whole-method Dynamic: **EXCUSED, do not pursue**" verdict
on new **protection-coverage** evidence. Method / ctor parameters default to `untyped`
today (the gradual entry point); the pilot shows a param flowing into an ivar or
receiver is the **dominant remaining protection hole on real apps**. The reconciliation
with the robustness principle is the whole decision: inference may **sharpen downstream
precision** but **never tighten a diagnostic at the parameter boundary**.

The landed slice is the **substrate**: a call-site argument-union collector
(`Inference::ParameterInferenceCollector`) keyed by `[class, method, kind]`, a
`param_inferred_types` `DiscoveryIndex` side-table, and consumption in
`build_method_entry_scope` (an undeclared parameter is seeded with its inferred type;
an RBS-declared parameter wins). It runs as a **capped fixpoint** (WD5): each round
re-types the project with the previous round's inferred parameters seeded, so a parameter
passed *another* parameter is typed one hop further per round (cap 3, the `BodyFixpoint`
convention, early-stop on convergence; round 1 alone is the single-level pass). A call
site whose argument is a not-yet-typed parameter poisons the parameter *that round* (WD4),
and it may type in a later round once its own argument resolves. It is wired into
**`coverage --protection` only**: the `check` walk leaves the table empty, so its
diagnostics are byte-identical and WD1's "never fire at the parameter boundary" holds *by
construction* (an inferred type is a body local, never an RBS contract, and the boundary
rules consult RBS).

**Measured caveat (the 2026-06-16 verification, do not re-litigate):** the two ADRs cited
as the headline cases are *not* moved, even with the fixpoint. parser's `unary_num`
parameter is fed from generated `.y` value-stack code (`val[0]`, never analysed Ruby);
faraday's `match(env)` is called with `env`, itself a parameter of `call(env)` whose own
entry is reached by dynamic middleware dispatch (so the fixpoint never seeds its root).
The pass moves the metric where a user method is (transitively) called with concretely-typed
arguments. **Measured** (`coverage --protection`, `lib`): faraday 0.2129 → 0.2402 (+29
protected sites; +6 of them from the fixpoint over single-level), haml 0.3188 → 0.3842
(+105 sites; +6 from the fixpoint) — haml's `compile(node)`-style compiler chain (methods
called with constructed AST nodes) is the sweet spot, the cited `env` / `numeric` clusters
are not. The `check`-walk wiring (and with it the WD1 in-body provenance *mark*) is the
remaining follow-up, budget-gated per the cost discussion below.

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

- **WD1 — precision-additive-only contract (the robustness floor; non-negotiable).
  Implemented by construction (single-level slice).** An inferred param type can never
  escalate to a param-boundary `argument-type-mismatch` / arity firing. In the landed slice
  this holds *structurally*: the inferred type is stored only as a method-body local (via
  `build_method_entry_scope`), never injected into an RBS method definition, and the boundary
  rules fire only on RBS-declared methods — an inferred-parameter method has no RBS sig, so
  the boundary rules skip it. The explicit "inferred, not declared" provenance *mark* (the
  [ADR-58](58-ivar-field-typing.md) WD1 pattern, reused) is required only to guard *in-body*
  diagnostics once the inference feeds the `check` walk, and lands with that follow-up.
- **WD2 — in-body usage lower bound (cheapest; helps even leaf scripts).** From the param's
  calls in the method body (`arr.delete_at`, `arr.length`), derive a **structural lower
  bound** (responds-to set / interface) and let it drive protection on `arr.<method>`. No
  call sites needed, so it helps the leaf-script corpus the survey excused — but yields a
  duck/structural bound, not a nominal type.
- **WD3 — call-site union (TypeProf-style; the real lever for apps). Implemented.** A
  param's inferred type = the union of resolved call-site argument types (needs ≥1 resolved
  call site). `ParameterInferenceCollector` resolves a call to its user `def` via the
  cross-file discovery index, types the positional arguments, unions them per parameter, and
  skips non-simple parameter shapes / arity mismatches / splat calls. It is whole-program-ish
  and in tension with Rigor's per-file model ([ADR-46](46-incremental-dependency-graph.md)),
  so it runs only in the `coverage --protection` command (not the `check` walk) and is
  **budget-gated** (a per-parameter union cap, `MAX_CALL_SITE_TYPES`, and the WD5 round cap),
  and is unsound under unseen call sites / dynamic dispatch → falls back to `untyped` (no
  false narrowing).
- **WD4 — soundness fallbacks.** Unseen call sites, `send`/dynamic dispatch, and
  metaprogrammed callers contribute nothing (the param stays `untyped`); a single dynamic
  caller does not widen an otherwise-precise inference into a false narrowing. The inferred
  type is an over-approximation only where the call-site set is closed.
- **WD5 — budget + termination. Implemented (capped, not true-convergent).** The call-site
  union is a worklist fixpoint: each round re-types the project with the prior round's
  inferred parameters seeded (the same `param_inferred_types` consumption path the protection
  scan uses), propagating one hop per round. Capped at `DEFAULT_ROUNDS` (3, the
  [ADR-41](41-inference-budget-design.md) budget; the `BodyFixpoint` convention) with an
  early-stop on table equality — convergence is *not* required because the table can
  oscillate at the margin (a newly resolved receiver can surface a fresh untyped-argument
  call site), and the protection metric tolerates a bounded approximation. Parses are cached
  across rounds; only re-indexing repeats. The ADR-57 run-scoped return memo is the
  forward-looking reuse for the deferred `check`-walk wiring (where callee re-typing must not
  be unbounded); the protection-only pass does not need it.

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
