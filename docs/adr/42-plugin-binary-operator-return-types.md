# ADR-42 — Plugin-contributed binary-operator return types (coerce-direction)

Status: **Proposed, 2026-06-03.** Records the design space for letting a
plugin contribute the result type of a Ruby binary operation when the
plugin-owned type is the **right-hand (coerced) operand** — the one case a
PHPStan-parity audit of Rigor's type algebra found genuinely unsupported.
Nothing here is implemented yet; this ADR exists to capture the decision and
its rejected alternatives so the work is demand-gated rather than
speculative.

Grounding:
[`docs/notes/20260603-phpstan-type-algebra-comparison.md`](../notes/20260603-phpstan-type-algebra-comparison.md)
(the full PHPStan ↔ Rigor type-algebra comparison and the code spike that
narrowed the gap to the coerce direction). Related:
[`docs/notes/20260519-oss-library-survey.md`](../notes/20260519-oss-library-survey.md)
(the BigDecimal-coerce false-positive that motivates the demand).

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

Demand is real, not hypothetical: the BigDecimal-coerce false positive
already surfaced in the OSS survey, and the canonical motivating libraries
(`BigDecimal`, units/`Money`, vectors) all rely on `coerce` for
`builtin <op> custom`.

## Decision

**Proposed.** Add an engine dispatch path so that, for a binary-operator
`CallNode` whose **receiver type is a core built-in** but whose **argument
type is a plugin-owned `Nominal`**, the owning plugin is consulted for the
result type before RBS widening. The plugin-facing shape is one of the
working decisions below; **WD-A is the leading candidate**. Implementation is
gated on at least one real bundled consumer (BigDecimal or `examples/`
units) landing in the same change set, per the false-positive-discipline and
demand-driven norms.

### Working decisions (shape of the hook)

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
  offset facade):** demand-driven facade additions in the ADR-37 lineage; a
  separate ADR if/when a real plugin needs them.
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
