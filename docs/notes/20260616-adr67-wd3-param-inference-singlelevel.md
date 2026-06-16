# ADR-67 WD3 + WD5 — call-site parameter inference (implementation + measurement)

2026-06-16. Landed the [ADR-67](../adr/67-parameter-type-inference.md) substrate
(WD1 + WD3 single-level, then WD5 capped fixpoint) and measured it. This note records the
architecture, the measured deltas, and — load-bearing — *why the two cited corpora barely
move* and what the one remaining follow-up is. Do not re-litigate the cited-corpora
finding; it is measured.

## What landed

- **`Inference::ParameterInferenceCollector`** — a project-wide pass that types each
  call's positional arguments in their lexical scope (via a discovery-seeded
  `ScopeIndexer.index`) and records, per user-defined method `[class, method, kind]`, the
  **union of resolved call-site argument types**. Keyed by the qualified class name (not
  AST identity), so collection and consumption — which parse different trees — agree.
- **WD5 capped fixpoint** — `collect` iterates (cap `DEFAULT_ROUNDS` = 3, `BodyFixpoint`
  convention, early-stop on table equality), re-seeding each round with the prior round's
  `param_inferred_types`. Because the *same* consumption path (`build_method_entry_scope`
  consulting the table) types parameter reads, an argument that reads a parameter resolves
  to that parameter's current inferred type → one hop of propagation per round. Parses are
  cached across rounds; only re-indexing repeats. Not true-convergent (the table can
  oscillate when a newly resolved receiver surfaces a fresh untyped-argument call site) —
  the cap bounds it and the metric tolerates the approximation. Round 1 alone is the
  single-level pass.
- **`param_inferred_types` side-table** on `Scope::DiscoveryIndex` (+ a `Scope` reader),
  following the `data_member_layouts` / `struct_member_layouts` template.
- **Consumption** in `StatementEvaluator#build_method_entry_scope`: an undeclared
  (`untyped`) parameter is seeded with its inferred type; an RBS-declared parameter wins.
- **Wiring**: `coverage --protection` only. The collector runs over the scanned paths and
  seeds *only* the parameter table into the scan scope (no cross-file discovery), so every
  site that does not gain an inferred parameter is classified byte-identically to the
  un-inferred baseline. The `check` walk never seeds the table, so its diagnostics are
  byte-identical (`make verify` green).

## WD1 (no parameter-boundary firing) holds by construction

An inferred type lives *only* as a method-body local. The boundary diagnostics
(`call.argument-type-mismatch`, arity) fire only on RBS-declared methods
(`rbs_class_known?` + an RBS `lookup_method`), and an inferred-parameter method has no RBS
sig — so the boundary rules skip it regardless of the table. The explicit "inferred, not
declared" provenance *mark* (ADR-58 WD1 pattern) is required only to guard *in-body*
diagnostics once the inference feeds the `check` walk; it lands with that follow-up.

## Soundness (WD4)

The union is a sound over-approximation only over *resolved, concrete* call sites. Any
`Dynamic` / `Top` / `Bot` argument — the fixpoint case (an argument that is itself an
untyped parameter), or a `send` / dynamic-dispatch caller — **poisons** the parameter,
which then contributes nothing (stays `untyped`). Splat / keyword / block-pass calls,
non-simple parameter shapes, and arity mismatches are skipped. A literal argument widens
to its nominal (`Constant<"x">` → `String`) — a parameter is not a pinned literal.
`MAX_CALL_SITE_TYPES` caps the union (ADR-41 budget guard).

## Measured (`coverage --protection`, `lib`)

| Project | Baseline | Single-level (round 1) | Capped fixpoint (cap 3) | Δ vs baseline |
| --- | --- | --- | --- | --- |
| faraday | 227 / 1066 (0.2129) | 250 (0.2345) | 256 / 1066 (0.2402) | +29 (+6 from the fixpoint) |
| haml | 512 / 1606 (0.3188) | 611 (0.3804) | 617 / 1606 (0.3842) | +105 (+6 from the fixpoint) |

haml's `compile(node)`-style compiler chain (methods called with constructed AST nodes —
concrete arguments) is the sweet spot. The fixpoint adds the param→param chains on top
(+6 each here). `coverage --protection lib` on haml runs in ~3 s incl. shell startup.

## Why the cited corpora don't move — even with the fixpoint

The 2026-06-16 verification cited parser `numeric.loc` and faraday `env[:method]` as the
M3 headline. Neither moves, even with the WD5 fixpoint:

- **parser `unary_num(unary_t, numeric)`** — every call site is in generated `.y` grammar
  files (`@builder.unary_num(val[0], val[1])`), which Rigor does not analyse, and `val[*]`
  is an untyped value-stack read regardless. No analysed Ruby call site → no inference, at
  any round.
- **faraday `match(env)`** — its one call site is `stubs.match(env)` inside `def call(env)`,
  so the argument `env` is `call`'s parameter; the fixpoint can only type it if `call(env)`
  itself gets a typed `env`, but `call`'s entry is reached by dynamic middleware dispatch
  (no analysed call site) → its `env` stays untyped → the chain never seeds.

The only path that reaches these is feeding the inference into the **`check` walk** (so
the *whole program's* downstream typing improves), not the protection scan — and that is
the deferred follow-up below.

## Remaining follow-up (deferred, budget-gated)

**`check`-walk wiring.** Make the `check` walk consume `param_inferred_types` (today only
the protection scan does). Requires running collection before the main walk (a cost the
ADR budget-gates — likely an opt-in / incremental-backed) **and** the WD1 in-body
provenance mark + the diagnostic guards, so a sound-but-newly-concrete parameter receiver
cannot manufacture an in-body false positive. Note the *value* is murkier than it looks:
with the WD1 suppression mark the inferred type adds *folding* precision but is designed
**not** to fire new in-body diagnostics, so the `check` benefit is indirect (better
downstream typing) and could even be net-negative if it surfaces downstream FPs. Gate:
zero new diagnostics across the standing `rigor-survey` corpora. Per the ADR's own
budget-gating, deferral may remain the right call until a concrete demand appears.
