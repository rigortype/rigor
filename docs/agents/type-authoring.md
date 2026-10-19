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

## Spelling a refinement

When designing the spelling of a new refinement, and the set it denotes is one a Ruby literal's own
predicate already accepts, spell it with that literal and define it by that predicate:
`Integer[1..10]` and `Float[0.0...1.0]` by `Range#cover?`, not PHPStan's `int<1, 10>`
([ADR-1](../adr/1-types.md), [ADR-109](../adr/109-ruby-native-range-notation.md)).
Before importing a PHPStan, TypeScript or Python spelling, check whether Ruby has a literal for the set
and whether ADR-1's rejected alternatives already ruled on it. The imported `int<min, max>` shipped five
days after ADR-1 rejected it and stood for four months: it could not round-trip (`int<0, max>` printed
but did not parse) or extend to `Float` (`min` reads as `Float::MIN`). When a docs sweep finds the spec
and the code disagreeing, check which side ADR-1 took before siding with the code. A display string a
user may copy into a `%a{rigor:v1:…}` payload must parse back.

## Tighten the gate with the fix

The pattern to copy is the alba maintainer's Steep ratchet
([`03b37e7`](https://github.com/okuramasafumi/alba/commit/03b37e75ee12b9a28e00341143449778bf2241d0),
[`5883637`](https://github.com/okuramasafumi/alba/commit/5883637),
[`bf06036`](https://github.com/okuramasafumi/alba/commit/bf06036)). The `Module#name` thread in
[alba#576](https://github.com/okuramasafumi/alba/pull/576) shows two traps that sit next to it.

- **Remove a downgrade in the commit that makes the code pass it.** alba's Steepfile listed six
  diagnostics at `:information`. `03b37e7` removed `BlockTypeMismatch` and fixed what it exposed; the other
  two commits removed `UnexpectedSuper` and `UnexpectedKeywordArgument` outright, because nothing was left
  to fix. One diagnostic per commit, three left. Do not add a downgrade to land a change, and do not drop
  one without fixing the sites it was hiding.
- **Fix the signature before the call site.** `03b37e7` gave blocks their `[self: …]` types and named each
  proc contract once (`metadata_proc`, `instance_proc?` in place of a bare `Proc?`, `converter` and
  `check`). Only three source lines kept a `# steep:ignore`, each on the one expression the signature
  cannot express, and a type assertion moved to the line that introduces the value.
- **Do not widen a signature to fit the checker.** In alba#576 `_ClassContext#name` stayed `-> String`
  although an anonymous class returns `nil`: the change was signature-only, and `String?` made Steep reject
  `nesting`, which does not narrow a second `name` call (`n = name` would). The maintainer's answer was to
  keep the type honest and change the code. A signature-only scope is a reason to stop and say so, not to
  state a wider type.
- **A core `-> String` with `%a{implicitly-returns-nil}` hides a nil from every checker.** The nil that
  raises in alba is elsewhere: `resource_name` calls `self.class.name.end_with?`, and `self.class` is
  declared `Class`, whose core `name` is `-> String` plus that annotation, so `Alba.serialize(obj) {
  root_key!; … }` raises `NoMethodError` and neither Steep nor Rigor reports it. `RbsDispatch` reads past
  the annotation on purpose ([inference-engine.md](../internal-spec/inference-engine.md), "nil-free for a
  lookup that can miss"). Guard such a call in code and check the producing call sites; do not rely on the
  type.
