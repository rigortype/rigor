# ADR-42 — Plugin-contributed binary-operator return types (coerce-direction)

Status: **Proposed (low priority, demand-gated), 2026-06-03.** Records the
design space for letting a plugin contribute the result type of a Ruby binary
operation when the plugin-owned type is the **right-hand (coerced) operand** —
the one case a PHPStan-parity audit of Rigor's type algebra found genuinely
unsupported. **A 2026-06-03 demand re-evaluation lowered this ADR's priority**
(see "Demand re-evaluation" below): the gap is *not* a false-positive — the
current behaviour is harmless fail-soft — so it buys precision, not safety,
and the more idiomatic fix is the ADR-20 lightweight-HKT / RBS-type-function
route that `examples/rigor-units` already points to. Nothing here is
implemented; this ADR captures the decision and its rejected alternatives so
the work stays demand-gated rather than speculative, and **prefers the HKT
route over a new operator hook unless a real consumer proves otherwise**.

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

An evidence pass after the initial draft corrected two over-statements that
had inflated this gap's priority:

- **The current behaviour is harmless, not a false positive.** When the
  receiver is a built-in and the argument is a plugin-owned `Nominal`,
  dispatch falls through to `Dynamic[top]` with **no diagnostic** (fail-soft).
  Downstream calls on that `Dynamic` also fail soft. So the gap costs
  *precision* (and completeness of a plugin's *own* checks — a false
  *negative* in e.g. dimensional-safety), never a false positive on working
  code. Against Rigor's top-tier "the program works" value, that is a weak
  motivator.
- **The BigDecimal-coerce survey item is not evidence for this ADR.** That
  false positive (`docs/notes/20260519-oss-library-survey.md`) was an
  *overload-ordering* problem — stdlib `bigdecimal` reopening `Integer#+` at
  the front of the overload list — and it was **already fixed** by the
  ReceiverAffinity pre-sort (`acc9882`,
  [`receiver_affinity.rb`](../../lib/rigor/inference/method_dispatcher/receiver_affinity.rb)).
  It is unrelated to plugin-contributed coerce-direction types.
- **The idiomatic fix may be ADR-20, not a new hook.**
  [`examples/rigor-units/README.md`](../../examples/rigor-units/README.md)
  itself documents that the declarative answer to operator typing is a
  lightweight-HKT / RBS type function (`def *: [T] (T) -> ...`), not a runtime
  dispatch table. A new operator extension point would overlap with that
  direction and risk a competing mechanism.

Net: the residual demand is the **minority `scalar <op> custom` pattern**
(`2 * distance`, `0.5 * mass`), where a precise type would let a units/Money
plugin keep checking dimensional safety. Real but narrow, precision-only, and
plausibly subsumed by ADR-20. The canonical motivating libraries
(`BigDecimal`, units/`Money`, vectors) rely on `coerce` for
`builtin <op> custom`, so the pattern exists — it is the *value* that is
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

- **WD-A (leading) — bidirectional narrow extension `operator_return`.** A
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

- **False-positive discipline first.** The motivating cases are existing
  *false positives / over-widenings* on working code (`1 + money` typed too
  loosely), not missing strictness. Any implementation must only ever
  *tighten or correct* the coerce-direction result, never introduce a new
  diagnostic that frightens working coerce-based code. This bounds the risk
  and aligns with the project's top-tier "the program works" value.
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
