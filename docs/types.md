# Rigor Type System — Quick Guide

Rigor is an inference-first static analyzer for Ruby. Its type language is a **strict superset of RBS**: every RBS type round-trips losslessly through Rigor's internal representation, and every Rigor-inferred type erases conservatively back to ordinary RBS.

This file is the one-page entry point. The full normative specification lives in [`docs/type-specification/`](type-specification/README.md). Design rationale and rejected/deferred options live in [`docs/adr/1-types.md`](adr/1-types.md).

## Concept

- **No inline DSL.** Application Ruby code stays free of Rigor-only annotation syntax. RBS, rbs-inline, and Steep-compatible annotations are accepted as type sources.
- **Lossless RBS in, conservative RBS out.** Internal precision (literal sets, refinements, shapes, dynamic-origin provenance) MAY exceed what RBS can spell. On export, Rigor erases to ordinary RBS that is never narrower than what was proved.
- **Three-valued certainty.** Type, reflection, and member queries return `yes`, `no`, or `maybe`. `maybe` does not narrow as if `yes` and does not produce the opposite-edge fact as if `no`.
- **Two relations, kept separate.** Subtyping (`A <: B`, value-set inclusion) and gradual consistency (`consistent(A, B)`, dynamic-boundary compatibility) are not unified. `untyped` is the dynamic type, distinct from `top`.

## Main features

| Feature | Where to read more |
| --- | --- |
| `Dynamic[T]` algebra and gradual-typing provenance | [value-lattice.md](type-specification/value-lattice.md), [special-types.md](type-specification/special-types.md) |
| Edge-aware control-flow narrowing inside compound conditions | [control-flow-analysis.md](type-specification/control-flow-analysis.md) |
| Negative facts, difference types, complement display contract | [type-operators.md](type-specification/type-operators.md) |
| Structural duck typing through RBS interfaces and inferred object shapes | [structural-interfaces-and-object-shapes.md](type-specification/structural-interfaces-and-object-shapes.md) |
| Capability roles (`_RewindableStream`, `_ClosableStream`, …) for IO-like compatibility | [structural-interfaces-and-object-shapes.md](type-specification/structural-interfaces-and-object-shapes.md) |
| Refinements (`non-empty-string`, `positive-int`, hash-shape extra-key policy, …) | [imported-built-in-types.md](type-specification/imported-built-in-types.md), [rigor-extensions.md](type-specification/rigor-extensions.md) |
| `RBS::Extended` annotations (`%a{rigor:v1:…}` for predicates, assertions, conformance) | [rbs-extended.md](type-specification/rbs-extended.md) |
| Inference budgets and boundary contracts for recursion / operator ambiguity | [inference-budgets.md](type-specification/inference-budgets.md) |
| Diagnostic identifier taxonomy and suppression markers | [diagnostic-policy.md](type-specification/diagnostic-policy.md) |
| Conservative RBS erasure and hash-shape erasure algorithm | [rbs-erasure.md](type-specification/rbs-erasure.md) |

## Quick reading paths

- **Just want the mental model?** Read [overview.md](type-specification/overview.md), [value-lattice.md](type-specification/value-lattice.md), and [special-types.md](type-specification/special-types.md) in that order.
- **Implementing inference?** Add [control-flow-analysis.md](type-specification/control-flow-analysis.md), [normalization.md](type-specification/normalization.md), [inference-budgets.md](type-specification/inference-budgets.md), and the analyzer-internal contracts in [`docs/internal-spec/`](internal-spec/README.md) — start with [implementation-expectations.md](internal-spec/implementation-expectations.md) and [internal-type-api.md](internal-spec/internal-type-api.md).
- **Writing RBS or `RBS::Extended` payloads?** Read [rbs-compatible-types.md](type-specification/rbs-compatible-types.md) and [rbs-extended.md](type-specification/rbs-extended.md), then [rbs-erasure.md](type-specification/rbs-erasure.md) to see how they round-trip.
- **Reviewing or extending the diagnostic surface?** Read [diagnostic-policy.md](type-specification/diagnostic-policy.md) alongside [type-operators.md](type-specification/type-operators.md).

## Specification index

The full reading order, conventions (RFC 2119 keywords, RBS-first compatibility hierarchy), and one-line description of each topical document live in [`docs/type-specification/README.md`](type-specification/README.md).

For analyzer-internal contracts that complement the type specification (engine-surface, type-object public API), see [`docs/internal-spec/README.md`](internal-spec/README.md).

## Related documents

- [`README.md`](../README.md) — project overview and CLI entry point
- [`AGENTS.md`](../AGENTS.md) — development workflow for this repository
- [`docs/adr/0-concept.md`](adr/0-concept.md) — Rigor's high-level concept ADR
- [`docs/adr/1-types.md`](adr/1-types.md) — type-model ADR (design rationale, options considered, rejected/deferred items, open questions)
- [`docs/adr/2-extension-api.md`](adr/2-extension-api.md) — plugin extension API ADR
- [`docs/adr/3-type-representation.md`](adr/3-type-representation.md) — internal type representation ADR (design rationale and open questions)
- [`docs/internal-spec/README.md`](internal-spec/README.md) — analyzer-internal contracts (engine surface, type-object public API)
