# Overview

## Core principle

Rigor's type language is a strict superset of RBS.

The RBS→Rigor direction is **lossless**: every RBS type has a representation in Rigor that round-trips back to the same RBS type. Internal precision-bearing wrappers such as `Dynamic[T]` (see [special-types.md](special-types.md)) are reversible at the boundary so the round-trip is exact rather than approximate.

The Rigor→RBS direction is **not** lossless. Every Rigor-inferred type MUST have an RBS erasure so Rigor can export an approximation as ordinary RBS, but erasure MAY collapse refinements, literal unions, shapes, and dynamic-origin provenance. Erasure MUST NOT produce a narrower type than Rigor proved; it MAY produce a wider one.

Rigor uses RBS as the interoperability surface and a richer internal type model for inference, control-flow analysis, and diagnostics.

## Source-of-truth boundaries

Rigor borrows ideas from PHPStan, TypeScript, and Python's typing specification, but the borrowed ideas remain Ruby-shaped:

- RBS classes and modules stay nominal.
- RBS interfaces and Rigor object shapes provide structural duck typing (see [structural-interfaces-and-object-shapes.md](structural-interfaces-and-object-shapes.md)).
- Ruby truthiness means only `false` and `nil` are falsey.
- Ruby equality, case equality, `respond_to?`, `method_missing`, singleton methods, and module inclusion are runtime behaviors that MUST be modeled through Ruby semantics, RBS signatures, or plugin facts rather than copied from another language.
- Application Ruby code stays free of Rigor-only annotation syntax. Existing RBS-, rbs-inline-, and Steep-compatible annotations are accepted as type sources, not treated as Rigor-specific syntax.

## Design priorities

This specification is organized around the ideal type model, not the first implementation milestone. The priorities, in order, are:

1. Preserve every RBS type and every RBS export rule.
2. Keep Ruby runtime behavior as the source of truth for narrowing and member availability.
3. Make gradual loss of precision explicit through `untyped` provenance.
4. Treat control-flow facts as scope transitions at expression edges, not only as block-level branch labels.
5. Support Ruby duck typing through structural interfaces and object shapes without making all class compatibility structural.
6. Let plugins and `RBS::Extended` contribute facts, effects, and dynamic reflection while the analyzer keeps ownership of scope application and normalization.

## Release scope

This specification describes the long-term type model. The first user-visible release (v1) ships a deliberately scoped slice. The boundary is:

- The full specification — fact-stability buckets, capability-role catalog, mutation summary set, `Dynamic[T]` algebra, type operators, the `RBS::Extended` schema — is normative. Internal data structures MAY be present in v1 even when the user-visible narrowing surface does not yet exploit them.
- The v1 narrowing surface is the subset of derivation rules that are turned on for end users in the first release.
- v1.1 is the next user-visible release. It expands the narrowing surface using rules that the data structures already support. Each v1.1 surface ships behind a feature flag so v1 behavior is preserved.

The detailed v1 versus v1.1 boundaries appear in the relevant topical sections, including [control-flow-analysis.md](control-flow-analysis.md), [structural-interfaces-and-object-shapes.md](structural-interfaces-and-object-shapes.md), and [rbs-extended.md](rbs-extended.md).

## Compatibility hierarchy

The compatibility hierarchy is:

- RBS and rbs-inline are first-order norms for type syntax and inline annotation compatibility.
- Steep 2.0 behavior is the second-order norm for how existing annotations are interpreted when prose specifications leave behavior open.
- TypeScript, PHPStan, and Python typing are design references, not syntax compatibility targets.

When the three sources differ, Rigor follows the resolution order documented in [README.md](README.md).

Inline annotation handling: Rigor MUST be 100% compatible with RBS and rbs-inline syntax, and SHOULD follow Steep 2.0 behavior for inline annotation interpretation and precedence. Existing rbs-inline and Steep-compatible annotations are official type sources. Rigor MUST NOT rewrite them, MUST NOT warn solely because they are complex, and MUST NOT require `# rbs_inline: enabled` to begin parsing them. Only the rbs-inline configuration directives such as `# rbs_inline: enabled` and `# rbs_inline: disabled` are interpreted; the rbs-inline annotation comments themselves (for example `#: String`, `# @rbs`, parameter annotations) are always parsed and used whenever present.

Standalone `.rbs` files and generated stubs remain the preferred place for complete type definitions. Inline annotations are nevertheless real contracts when present. They are not merely hints. Implementation-side checking is independent of where the contract came from: a return type written as `#: void`, a method type written with `# @rbs`, parameter types written in rbs-inline style, a generated stub, and an external `.rbs` declaration all constrain the implementation in the same way.

## Style guidance for inline annotations

Style guidance is only about whether authors should write a type in `.rb` source. It does not change validity:

- `#: void` and `#: bot` are strongly recommended when they express intent and create useful inference boundaries.
- Short returns such as `#: bool`, `#: String`, or `#: User` are neutral; authors MAY write them when they make intent clearer.
- Complex inline types — unions, generics, records, and nested method types — are valid RBS/rbs-inline input and MUST be accepted. Rigor's style guidance prefers moving them to `.rbs` or generated stubs, but Rigor MUST NOT report diagnostics merely for using them.
