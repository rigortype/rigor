# Type authoring contract

Read this when a task writes or asserts a type, edits `.rbs`, adds an inline RBS annotation, or
describes a type in a comment, document, or review. It is conditional detail for the standing pointers
in `AGENTS.md`.

## Provenance

A type that Rigor did not produce or check is not written down. Learn it from Rigor —
`rigor type-of`, `rigor annotate`, or `rigor sig-gen --print` — never from surrounding code or an
existing comment.

Types live in `sig/`, in a checked inline `#:` / `# @rbs` annotation, or as inference. When `sig/`
declares the same member, the two must agree: the more precise of two consistent declarations binds, and
a contradiction is a `rbs.contradicting-signature` error. Add an inline annotation only when it says
something the name and code do not: `void` / `bot` intent, a non-nominal refinement such as
`:asc | :desc`, or a parameter contract. Repeating the nominal type Rigor already shows on a method is
noise.

## Comments

In `.rb` files, comments never carry types. YARD tags are typeless and use an em dash after the name:
`@param name — description`, `@raise ExceptionClass — description`, and `@return description`.

A comment explains what the code and signature do not: rationale, a constraint the type system cannot
express, the meaning of `nil`, an ADR or issue, a false-positive bound, or a declined alternative.
It does not restate a name, type, or signature. The gate is `spec/docs/type_shaped_comments_spec.rb`.

## RBS

Prefer `rigor sig-gen --print` / `--diff` over hand-written or AI-authored RBS. An inference gap is
signal about the engine, so propose the generated output first and hand-edit only after the user has
reviewed that alternative. Correcting existing `.rbs` is fine when the task authorizes it.

Outside this repository, the shipped `rigor-type-oracle` skill carries the same provenance rule where
the adopting project has installed it; otherwise treat AI-authored RBS according to that project's
contract.

The normative reasons are [ADR-107](../adr/107-checked-types-and-typeless-comments.md),
[ADR-108](../adr/108-type-provenance-for-agents.md), and
[ADR-14](../adr/14-rbs-sig-generation.md).
