# Rigor Type Specification

## Status

Draft. This directory is the authoritative specification of the Rigor type model.

The documents under `docs/type-specification/` describe what the analyzer does. They define type normalization, narrowing, erasure, signature handling, diagnostic identifiers, inference budgets, and the surfaces exposed to plugins and `RBS::Extended` annotations.

Design rationale, the decision history, options that were rejected or deferred, and open questions live in `docs/adr/1-types.md` (and `docs/adr/2-*` for plugin extension API decisions). When the specification and an ADR appear to disagree on what the analyzer does, **the specification binds** and the ADR should be amended.

This specification covers the long-term type model. It is normative for the eventual analyzer behavior. The first user-visible release (v1) ships a deliberately scoped slice of the surface; sections that distinguish v1 from v1.1 mark the difference inline.

## Conventions

The keywords MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY in this specification are to be interpreted as described in [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) and [RFC 8174](https://www.rfc-editor.org/rfc/rfc8174).

Type expressions are written in RBS syntax where RBS can spell them, and in Rigor's internal notation otherwise. Internal notation that is not part of RBS surface syntax (for example `Dynamic[T]`, `T - U`, `~T`, `key_of[T]`) is identified explicitly the first time it appears in each document.

## Compatibility hierarchy

- **RBS** and **rbs-inline** are first-order norms for type syntax and inline annotation compatibility.
- **Steep 2.0** behavior is the second-order norm for how existing annotations are interpreted when prose specifications leave behavior open.
- **TypeScript**, **PHPStan**, and **Python typing** are design references used to find missing concepts and practical analyzer features. They are not syntax compatibility targets.

When the three sources differ, the resolution order is:

1. RBS prose specification wins.
2. rbs-inline documentation wins for inline-syntax questions that the RBS prose does not address.
3. Steep 2.0 behavior wins only when neither RBS prose nor rbs-inline documentation specifies the behavior.

Where Steep diverges from a higher-priority source, Rigor follows the higher-priority source and the divergence is documented. Such cases are called out individually in the relevant section so users migrating from Steep see the difference instead of discovering it through a diagnostic.

## Reading order

The documents are organized so foundational definitions come first and specific surfaces build on them.

| Document | Scope |
| --- | --- |
| [overview.md](overview.md) | Core principle (RBS superset), design priorities, scope of the specification. |
| [relations-and-certainty.md](relations-and-certainty.md) | Subtyping (`<:`) and gradual consistency (`consistent`), trinary certainty (`yes`/`no`/`maybe`). |
| [value-lattice.md](value-lattice.md) | Value lattice, lattice identities, and the `Dynamic[T]` algebra. |
| [special-types.md](special-types.md) | `top`, `bot`, `untyped`/`Dynamic[T]`, `void`, `nil`/`NilClass`, `bool`/`boolish`. |
| [rbs-compatible-types.md](rbs-compatible-types.md) | The set of RBS forms Rigor accepts and how each is interpreted. |
| [rigor-extensions.md](rigor-extensions.md) | Refinements and other internal-only forms Rigor infers beyond RBS. |
| [imported-built-in-types.md](imported-built-in-types.md) | Reserved built-in refinement names (`non-empty-string`, `positive-int`, …) and naming rules. |
| [type-operators.md](type-operators.md) | `~T`, `T - U`, `key_of[T]`, indexed access, and the diagnostic display contract. |
| [structural-interfaces-and-object-shapes.md](structural-interfaces-and-object-shapes.md) | RBS interfaces, inferred object shapes, capability roles, method-shape entries. |
| [control-flow-analysis.md](control-flow-analysis.md) | Edge-aware narrowing, equality semantics, fact stability, mutation effects, pre-plugin surface. |
| [rbs-extended.md](rbs-extended.md) | `%a{rigor:v1:…}` annotations, predicate/assertion grammar, explicit conformance, flow-effect bundles. |
| [normalization.md](normalization.md) | Deterministic normalization rules. |
| [rbs-erasure.md](rbs-erasure.md) | Conservative erasure to RBS, including the hash-shape erasure algorithm. |
| [inference-budgets.md](inference-budgets.md) | Budget table, configuration, and boundary-contract behavior. |
| [diagnostic-policy.md](diagnostic-policy.md) | Diagnostic identifier taxonomy, `Dynamic[T]` display rules, suppression markers. |
| [implementation-expectations.md](implementation-expectations.md) | The engine-surface contract that downstream features depend on. |

## Relationship to the existing draft (`docs/types.md`)

`docs/types.md` is the historical single-file draft of this specification. Where the two disagree, the documents in this directory bind. Future edits should update the topical files here and remove drift from the legacy draft.
