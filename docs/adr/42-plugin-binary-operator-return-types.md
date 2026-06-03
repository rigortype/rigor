# ADR-42 — Plugin-contributed binary-operator return types (coerce-direction)

Status: **Proposed (low priority, demand-gated), 2026-06-03.** Records the
design space for letting a plugin contribute the result type of a Ruby binary
operation when the plugin-owned type is the **right-hand (coerced) operand** —
the one case a PHPStan-parity audit of Rigor's type algebra found genuinely
unsupported. **A 2026-06-03 demand re-evaluation — backed by an integration
spec — lowered this ADR's priority** (see "Demand re-evaluation" below): the
self/left case already works via `dynamic_return`, and the coerce direction
produces only a **narrow false positive** (the `scalar <op> custom` minority
pattern, where `1 + money` types left-biased as `Integer`). The cheapest fix
is an engine mitigation (WD-D, type that case as `Dynamic` — no plugin hook);
precision is best served by the ADR-20 lightweight-HKT / RBS route that
`examples/rigor-units` already points to. Nothing here is implemented; this ADR
captures the decision and its rejected alternatives so the work stays
demand-gated, and **prefers WD-D / the HKT route over a new operator hook
unless a real consumer proves otherwise**.

Grounding:
[`docs/notes/20260603-phpstan-type-algebra-comparison.md`](../notes/20260603-phpstan-type-algebra-comparison.md)
(the full PHPStan ↔ Rigor type-algebra comparison, the code spike that
narrowed the gap to the coerce direction, and the §3/§5 demand re-evaluation).

## Context

### The parity question and what the spike settled

A comparison of PHPStan's plugin-facing type algebra (`TypeCombinator`,
`TypeUtils`, the `Type` interface, and especially
`OperatorTypeSpecifyingExtension`) against Rigor established that the two are
at parity on union / intersection / difference, gradual `accepts`, capability
predicates, constant extraction, constant-scalar arithmetic, `IntegerRange`
abstract arithmetic, and union cartesian folding (the note's §2–§3). The one
PHPStan feature with no Rigor analogue is the **plugin binary-operator hook**.

A 2026-06-03 code spike (note §3 G1) then showed the gap is *narrower than it
looks*. In Prism, `a + b` is a `Prism::CallNode` with `name: :+`; it flows
through the ordinary call path
([`expression_typer.rb:1233`](../../lib/rigor/inference/expression_typer.rb))
into `MethodDispatcher.dispatch`, whose tier order is **`ConstantFolding` →
`try_plugin_contribution` (`dynamic_return`) → RBS**
([`method_dispatcher.rb:74-97`](../../lib/rigor/inference/method_dispatcher.rb)).
A plugin-owned receiver is a `Nominal[Custom]`, which `ConstantFolding`
declines, so dispatch reaches the plugin tier; `dynamic_return_type` gates on
the **receiver class only** and never on the method name
([`base.rb:382`](../../lib/rigor/plugin/base.rb)). Therefore a plugin can
**already** specify a binary-operator result type today:

```ruby
dynamic_return receivers: ["Money"] do |call_node, scope|
  next nil unless %i[+ - * /].include?(call_node.name)
  services.type.nominal_of("Money")  # Money <op> anything → Money, etc.
end
```

This covers every operation where the plugin-owned type is the **left /
receiver** operand — i.e. `money + n`, `money * 2`, `vec | other`,
`path / "sub"`. PHPStan's `OperatorTypeSpecifyingExtension` is matched by
existing contract here; the only outstanding work for that case is
documentation and ergonomics (the note's G1a/G1b — handled outside this ADR).

### The residual gap: the coerce direction

Ruby dispatches `a + b` on `a`. When the **left** operand is a built-in
numeric (`Integer`, `Float`, `Rational`, `BigDecimal`) and the **right**
operand is a plugin-owned type, the receiver is the built-in, and Ruby's
runtime resolves the operation through `b.coerce(a)`. Rigor has no path for a
plugin to intervene here:

- `dynamic_return receivers: ["Integer"]` would require the plugin to
  **own** `Integer`, which collides with the core numeric model and is
  disallowed.
- `ConstantFolding` handles `Integer + Integer` but declines once an operand
  is a `Nominal[Custom]`, falling through to RBS, which projects the built-in
  signature (`Integer#+ : (Numeric) -> Numeric` etc.) and yields a widened —
  often wrong — type for `1 + money`.

PHPStan does not have this asymmetry: `isOperatorSupported($left, $right)` is
**bidirectional** — the extension is consulted regardless of which operand
carries the interesting type. That bidirectionality is the structural
capability Rigor lacks.

### Demand re-evaluation (2026-06-03)

An evidence pass — backed by the integration spec
[`spec/integration/plugin_operator_dynamic_return_spec.rb`](../../spec/integration/plugin_operator_dynamic_return_spec.rb)
— corrected the over-statements that had distorted this gap's priority. The
spec confirms the self/left case works and pins the coerce-direction
behaviour exactly:

- **The self/left case already works (no new hook needed).** A
  `dynamic_return receivers: ["Money"]` rule fires for `:+`/`:-`/`:*`/`:/` and
  the contributed type becomes the result of `Money <op> Money`. Confirmed
  green for all four operators.
- **The coerce direction is NOT silent fail-soft — and carries a narrow
  false-positive surface.** The first draft claimed `1 + money` falls through
  to `Dynamic[top]` with no diagnostic. The spec disproves that: `1 + money`
  dispatches on `Integer`, the `Money` rule cannot fire, and the result types
  **left-biased as `Integer`** (not `Dynamic`). Downstream method resolution
  then runs against `Integer`, so `(1 + money).some_money_method` is flagged
  `undefined-method` for `Integer` **even though it works at runtime via
  `money.coerce(1)`** — a genuine, if narrow, false positive (it needs the
  minority `scalar <op> custom` form *and* a custom method on the result).
  This is a stronger motivator than "precision only," though still narrow.
- **The BigDecimal-coerce survey item is not evidence for this ADR.** That
  false positive (`docs/notes/20260519-oss-library-survey.md`) was an
  *overload-ordering* problem — stdlib `bigdecimal` reopening `Integer#+` at
  the front of the overload list — already fixed by the ReceiverAffinity
  pre-sort (`acc9882`,
  [`receiver_affinity.rb`](../../lib/rigor/inference/method_dispatcher/receiver_affinity.rb)).
  Unrelated to plugin-contributed coerce-direction types.
- **The cheapest fix is an engine mitigation, not this hook.** Because the FP
  comes from the left-bias returning `Integer` for a non-`Numeric` argument,
  typing that result as `Dynamic` instead (WD-D below) removes the false
  positive with **no plugin surface at all**. Precision (the actual coerced
  type) is then a separate, ADR-20-shaped concern;
  [`examples/rigor-units/README.md`](../../examples/rigor-units/README.md)
  itself points to lightweight-HKT / RBS type functions (`def *: [T] (T) ->
  ...`) as the declarative answer, which a new operator hook would compete
  with.

Net: the residual demand is the **minority `scalar <op> custom` pattern**
(`2 * distance`, `0.5 * mass`, `1 + money`). It can produce a narrow false
positive (best addressed by WD-D, no hook) and otherwise costs precision (best
addressed by ADR-20). The canonical motivating libraries
(`BigDecimal`, units/`Money`, vectors) rely on `coerce` for
`builtin <op> custom`, so the pattern exists — it is the *value of a dedicated
operator hook* that is
modest, not the pattern's existence.

## Decision

**Proposed, low priority.** If and when the coerce-direction gap is closed,
add an engine dispatch path so that, for a binary-operator `CallNode` whose
**receiver type is a core built-in** but whose **argument type is a
plugin-owned `Nominal`**, the owning plugin is consulted for the result type
before RBS widening. The plugin-facing shape is one of the working decisions
below. **Implementation is gated on (a) at least one real bundled consumer
(BigDecimal or `examples/` units) and (b) a finding that the ADR-20 HKT / RBS
route below cannot serve that consumer** — per the false-positive-discipline
and demand-driven norms. Given the re-evaluation, the default expectation is
that this ADR stays Proposed indefinitely and the HKT route is tried first.

### Working decisions (shape of the hook)

- **WD-0 (preferred default) — solve it via ADR-20 lightweight HKT + RBS type
  functions, not a new hook.** Let the consuming library express coerce-aware
  operator results as RBS type functions (the `examples/rigor-units` README's
  own stated direction), so `builtin <op> custom` is resolved by the existing
  RBS/HKT tiers without any new plugin extension point. Only fall back to
  WD-A/WD-B if a concrete consumer cannot be expressed this way.

- **WD-D (cheapest false-positive mitigation, no hook) — type
  `builtin <op> non-Numeric` as `Dynamic` instead of left-biased.** The narrow
  FP (above) exists only because `1 + money` currently resolves to `Integer`
  when the argument matches no `Integer#+` overload. Making that case fail soft
  to `Dynamic` removes the false positive entirely without any plugin surface,
  at the cost of *precision* (the result is `Dynamic`, not the coerced type).
  This is the recommended first step if the FP is ever observed in real code;
  WD-0/WD-A then layer precision back on top only where a consumer needs it.

- **WD-A (leading, if a hook is needed) — bidirectional narrow extension `operator_return`.** A
  new ADR-37-style segregated protocol:

  ```ruby
  operator_return operators: %i[+ - * /], operands: ["BigDecimal"] do |op, left, right, scope|
    # called when EITHER left or right is an owned `operands:` type;
    # return a Rigor::Type or nil to decline
  end
  ```

  The engine invokes it from a new tier sitting between `ConstantFolding` and
  RBS, on any operand match — matching PHPStan's
  `isOperatorSupported(left, right)` / `specifyType(...)` bidirectionality.
  Subsumes the existing left-receiver case too, so plugins have one idiom for
  operators instead of hand-rolling `dynamic_return` name checks (folds in
  G1b ergonomics). Cost: a new public extension point (registry plumbing,
  segregation tests).

- **WD-B — engine bridge over existing `dynamic_return`.** Keep the contract
  as-is; add an engine pre-check: when a binary-operator receiver is a
  built-in numeric and an argument is a plugin-owned `Nominal`, offer the
  same call to that owning plugin's `dynamic_return` block with the
  receiver/argument roles discoverable from `call_node`. No new DSL surface;
  reuses the receiver-ownership registry. Cost: `dynamic_return`'s
  receiver-gate semantics get a coerce-direction exception that authors must
  understand (the block fires even though `call_node.receiver` is not the
  owned type).

- **WD-C — model `coerce` directly.** Type `b.coerce(a)` as a `Tuple` and let
  the existing operator fold run on the coerced pair. Most faithful to Ruby
  semantics but the heaviest: requires `coerce` return-shape modelling for
  every participating library and a fold that re-enters on the coerced tuple.
  Deferred — disproportionate for the demand.

### Out of scope (recorded, not decided here)

- **G1a/G1b (left-receiver operators):** already supported via
  `dynamic_return`; needs only docs (`docs/manual/`, an `examples/rigor-units`
  operator case) and an optional thin sugar. CHANGELOG-level, no ADR.
- **G2/G3/G5 (plugin type-algebra facade — `to_*` coercion, `generalize`,
  offset facade): evaluated 2026-06-03, declined for now** (evidence in the
  note's §3). None has a consumer:
  - **G2 (`to_*` coercion)** — *declined.* Ruby casts are method calls
    (`x.to_i`, `Integer(x)`) already resolved by dispatch; truthiness is
    handled by engine narrowing extensible via `type_specifier`. No type→type
    coercion facade is wanted.
  - **G3 (`generalize`)** — *declined as a plugin facade.* Intentional
    precision loss belongs to the ADR-41 inference-budget machinery, not a
    plugin surface. Folded there if ever.
  - **G5 (offset facade)** — *deferred, conditional.* The cleanest future
    extension (plugin-defined containers computing element-access types), but
    zero current consumers — `ShapeDispatch` is a closed Tuple/HashShape tier
    by design. Revisit only when a plugin ships a custom container type.
- **G4 (null convenience combinators — `remove_null` / `add_null`):** pure DX
  on `Type::Combinator`, CHANGELOG-level.

## Consequences

- **False-positive discipline first.** The motivating case is an existing
  *narrow false positive* on working code: `1 + money` types left-biased as
  `Integer` (spec-confirmed), so a custom method on the result is flagged
  `undefined-method` despite working via `coerce`. The FP-safe first step is
  WD-D (type that case as `Dynamic`), which only ever *relaxes* — it removes a
  diagnostic, never adds one. Any precision layer (WD-0/WD-A) must likewise
  only *tighten or correct* the result, never frighten working coerce-based
  code. This aligns with the project's top-tier "the program works" value.
- **Demand-gated.** No engine work lands without a real consumer in the same
  change set; until then this ADR stays Proposed and the comparison note is
  the operative record.
- **Parity is mostly already met.** With G1a/G1b documented, Rigor matches
  PHPStan's `OperatorTypeSpecifyingExtension` for the common (self/left)
  case; this ADR closes the one remaining asymmetry (coerce direction).
- **Lineage.** Builds on ADR-2 (extension API), ADR-37 (interface
  segregation — WD-A is a new segregated protocol), and ADR-39 (plugins
  acting on their target library). Engine tier ordering interacts with the
  `ConstantFolding` → plugin → RBS sequence in
  [`method_dispatcher.rb`](../../lib/rigor/inference/method_dispatcher.rb).
