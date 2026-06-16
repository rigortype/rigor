# ADR-67 WD3 — single-level call-site parameter inference (implementation + measurement)

2026-06-16. Landed the [ADR-67](../adr/67-parameter-type-inference.md) substrate
(WD1 + WD3, single-level) and measured it. This note records the architecture, the
measured deltas, and — load-bearing — *why the two cited corpora barely move* and what
the follow-ups are. Do not re-litigate the cited-corpora finding; it is measured.

## What landed

- **`Inference::ParameterInferenceCollector`** — a project-wide pass that types each
  call's positional arguments in their lexical scope (via a discovery-seeded
  `ScopeIndexer.index`) and records, per user-defined method `[class, method, kind]`, the
  **union of resolved call-site argument types**. Keyed by the qualified class name (not
  AST identity), so collection and consumption — which parse different trees — agree.
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

| Project | Baseline | WD3 | Δ sites | Δ ratio |
| --- | --- | --- | --- | --- |
| faraday | 227 / 1066 (0.2129) | 250 / 1066 (0.2345) | +23 | +2.16 pp |
| haml | 512 / 1606 (0.3188) | 611 / 1606 (0.3804) | +99 | +6.16 pp |

haml's `compile(node)`-style compiler chain (methods called with constructed AST nodes —
concrete arguments) is the single-level sweet spot. faraday moves less.

## Why the cited corpora (mostly) don't move — the single-level ceiling

The 2026-06-16 verification cited parser `numeric.loc` and faraday `env[:method]` as the
M3 headline. Single-level WD3 does **not** move either:

- **parser `unary_num(unary_t, numeric)`** — every call site is in generated `.y` grammar
  files (`@builder.unary_num(val[0], val[1])`), which Rigor does not analyse, and `val[*]`
  is an untyped value-stack read regardless. No analysed Ruby call site → no inference.
- **faraday `match(env)`** — its one call site is `stubs.match(env)` inside `def call(env)`,
  so the argument `env` is *itself* an untyped parameter → poisoned. And `call(env)`'s own
  entry is reached by dynamic middleware dispatch, so even the fixpoint cannot seed its root.

Both are **fixpoint-gated**: the argument is another untyped parameter, and only the
whole-program worklist (WD5) types it. faraday's root is dynamic-dispatch-gated beyond
even that.

## Follow-ups (deferred, both budget-gated)

1. **WD5 — whole-program worklist fixpoint.** Iterate the collection until parameter
   types converge (cap per ADR-41, reuse the ADR-57 run-scoped return memo). This is what
   moves the cited param-passed-to-param chains. The metric-completing slice.
2. **`check`-walk wiring.** Make the `check` walk consume the table (today only the
   protection scan does). Requires running collection before the main walk (a cost the ADR
   budget-gates) **and** the WD1 in-body provenance mark + the diagnostic guards (so a
   sound-but-newly-concrete parameter receiver cannot manufacture an in-body false
   positive). Gate: zero new diagnostics across the standing corpora.
