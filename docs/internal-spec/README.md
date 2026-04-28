# Rigor Internal Specification

## Status

Draft. This directory is the authoritative specification of Rigor's analyzer-internal contracts: the engine-surface that downstream features depend on and the public type-object model that plugins, rules, and CLI components consume.

The documents under `docs/internal-spec/` describe what the analyzer **is** internally — the immutable shapes, public method surfaces, identity rules, normalization routing, and stability guarantees that engine and plugin code MUST follow. Type-language *semantics* (RBS interop, value lattice, narrowing rules, normalization rules, erasure rules, diagnostic identifiers) live in [`docs/type-specification/`](../type-specification/README.md) and bind whenever a description here would conflict with type-language behavior.

Design rationale, the decision history, options that were rejected or deferred, and open questions live in `docs/adr/` (in particular `docs/adr/3-type-representation.md` for the type-object model). When the specification and an ADR appear to disagree on what the analyzer does, **the specification binds** and the ADR should be amended.

## Conventions

The keywords MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY in this specification are to be interpreted as described in [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) and [RFC 8174](https://www.rfc-editor.org/rfc/rfc8174).

Ruby identifiers (`Rigor::Type`, `Rigor::Trinary`, `Rigor::Type::Combinator`, …) are placeholder names used in this specification. They MAY be renamed during implementation as long as the contract they describe is preserved. Type expressions in examples follow the conventions of [`docs/type-specification/`](../type-specification/README.md).

## Relationship to other documents

- [`docs/type-specification/`](../type-specification/README.md) defines what the type language **means**. This directory defines what the analyzer **exposes** to satisfy that meaning.
- [`docs/adr/1-types.md`](../adr/1-types.md) records the rationale behind the type model. The type spec binds the resulting behavior; this directory binds the resulting internal contracts.
- [`docs/adr/2-extension-api.md`](../adr/2-extension-api.md) records the extension-API decisions. A subset of those contracts (Type queries, Scope queries, capability-role conformance) is normative here; the ADR remains the rationale.
- [`docs/adr/3-type-representation.md`](../adr/3-type-representation.md) records the rationale and open questions for the internal type representation. The decisions that have stabilized are normative in [`internal-type-api.md`](internal-type-api.md).
- [`docs/adr/4-type-inference-engine.md`](../adr/4-type-inference-engine.md) records the rationale, slice roadmap, and tentative answers to ADR-3's open questions for the type-inference engine. The decisions that have stabilized are normative in [`inference-engine.md`](inference-engine.md).

## Reading order

| Document | Scope |
| --- | --- |
| [implementation-expectations.md](implementation-expectations.md) | Engine surface — `Scope`, fact store, effect model, capability-role inference, normalization, RBS-erasure routing, public stability rules. |
| [internal-type-api.md](internal-type-api.md) | Type-object public contract — method surface, identity and equality, immutability, normalization routing through factories, diagnostics-display routing. |
| [inference-engine.md](inference-engine.md) | `Rigor::Scope#type_of(node)` query — purity, immutable Scope discipline, fail-soft `Dynamic[Top]` policy, environment-loading boundaries. |

This list is expected to grow as further internal contracts (reflection layer, fact store schema, cache and invalidation rules, plugin lifecycle internals) stabilize.
