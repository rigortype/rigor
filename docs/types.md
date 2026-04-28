# Rigor Type Specification (moved)

This document has moved to [`docs/type-specification/`](type-specification/README.md).

The type specification is now maintained as a set of topical Markdown files at the granularity of Python's typing specification. The new directory is the authoritative source for the analyzer's observable behavior. Any future edits SHOULD update the topical files there rather than this stub.

## Reading order

Start with [`docs/type-specification/README.md`](type-specification/README.md). It lists the documents in the recommended order and states the conventions (RFC 2119 keywords, RBS-first compatibility, the relationship to `docs/adr/1-types.md`).

Quick links to the most-referenced sections:

- [Overview and core principle](type-specification/overview.md)
- [Relations and certainty](type-specification/relations-and-certainty.md)
- [Value lattice](type-specification/value-lattice.md)
- [Special types: `top`, `bot`, `untyped`/`Dynamic[T]`, `void`, `nil`, `bool`](type-specification/special-types.md)
- [RBS-compatible types](type-specification/rbs-compatible-types.md)
- [Rigor extensions](type-specification/rigor-extensions.md)
- [Imported built-in types](type-specification/imported-built-in-types.md)
- [Type operators](type-specification/type-operators.md)
- [Structural interfaces, object shapes, and capability roles](type-specification/structural-interfaces-and-object-shapes.md)
- [Control-flow analysis](type-specification/control-flow-analysis.md)
- [`RBS::Extended` annotations](type-specification/rbs-extended.md)
- [Normalization](type-specification/normalization.md)
- [RBS erasure](type-specification/rbs-erasure.md)
- [Inference budgets](type-specification/inference-budgets.md)
- [Diagnostic policy](type-specification/diagnostic-policy.md)
- [Implementation expectations](type-specification/implementation-expectations.md)

## Why the move

The earlier single-file draft mixed many concerns (lattice, narrowing, erasure, diagnostics, budgets, …). Splitting it lets each topic be referenced and evolved independently, lets cross-references between the new files stay short, and makes the granularity comparable to other written-down typing specifications such as Python's `python/typing` repository.

Design rationale, options that were rejected or deferred, and open questions remain in [`docs/adr/1-types.md`](adr/1-types.md). When the specification and an ADR appear to disagree on what the analyzer does, the specification under `docs/type-specification/` binds.
