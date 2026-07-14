# ADR-80 — Rename the `type_specifier` plugin hook to `narrowing_facts`

Status: **Accepted, 2026-06-26; completed in 0.3.0.** The plugin-author DSL verb `type_specifier`
was renamed to `narrowing_facts`, survived as a warning-emitting alias through 0.2.x, and is
**removed in 0.3.0** (it now raises `NoMethodError` at class-definition time). The bundled
minitest / sorbet / rspec plugins are migrated. The **carry-over this ADR deferred was decided at
that removal, in favour of full consistency** — see the 0.3.0 addendum below.

Grounding: the 2026-06-26 rigor-rs port feedback (item 5 — the name misleads), cross-checked
against the contract freeze in [ADR-60](60-pre-freeze-plugin-contract-consolidation.md) and the
v1.0 vocabulary freeze in [ADR-50](50-release-engineering-and-stability-strategy.md) WD1.

## Context

`type_specifier` (the ADR-37 slice-2 hook) reads as a parallel to its sibling
{`dynamic_return`} — but `dynamic_return` returns a **type** while `type_specifier` returns
**post-return narrowing facts** (the predicate/assertion edges a call establishes, e.g.
`assert_kind_of(String, x)` ⇒ `x` narrows to `String`). The name invites exactly the wrong
mental model; the rigor-rs port author (who must mirror the contract, its ADR-0027) was misled
by it, and the internal storage is already truer (`post_return_facts`).

[ADR-60](60-pre-freeze-plugin-contract-consolidation.md) recorded a keep-verdict here, but it
defended the **`dynamic_return` / `type_specifier` split** (two hooks, not one) — its rejected
alternative was *merging* them. It did **not** defend the *name*. The name is therefore an open
question, and [ADR-50](50-release-engineering-and-stability-strategy.md) freezes the plugin
vocabulary at v1.0: pre-1.0, pre-adoption (third-party usage is zero) is the lowest-cost moment
to fix it, and the only one before the misname becomes permanent.

## Decision

Rename the hook to **`narrowing_facts`**. Criterion — the reusable rule:

> **A public DSL verb names what the author declares.** This hook declares narrowing *facts*,
> so it is named for facts — not by false parallel to a sibling that returns a type. Renames
> that serve clarity are paid pre-1.0, pre-adoption, where back-compat cost is lowest; after
> the v1.0 freeze the name is permanent.

- `narrowing_facts(methods:) { |call_node, scope| facts | nil }` is the canonical hook.
- `type_specifier` remains as a **deprecating alias**: it emits a one-time-per-plugin stderr
  warning and delegates to `narrowing_facts`. **Removed in 0.3.0** (`plugin/base.rb`).
- **Scope is the author-facing verb only.** The engine-facing reader `type_specifiers`, the
  consumer `#type_specifier_facts`, and the `rigor plugins --capabilities` JSON field
  `type_specifier_methods` are **not** renamed here: the first two are internal API a plugin
  author never writes, and the JSON field is a separately-frozen CLI-output surface (ADR-50)
  whose rename is a distinct decision. They are revisited when the alias is removed in 0.3.0.

## Rejected / deferred

- **Keep `type_specifier`** — rejected: the v1.0 freeze would make the misname permanent; the
  fix is free now and impossible later.
- **Rename the internals + capability JSON in this slice** — deferred: scope creep across a
  second frozen surface (CLI output); the author-facing verb is the misleading one. Revisit at
  the 0.3.0 alias removal.
- **Merge `narrowing_facts` into `dynamic_return`** — rejected (already, by ADR-60): the split
  is principled (return-type vs facts, dispatcher vs statement-evaluator, different gate
  shapes); a merged DSL forks internally on a discriminator and buys only a rename.

## Consequences

- **Positive:** the verb now says what it does; the bundled plugins read clearly; the rigor-rs
  mirror can adopt the truer name instead of cementing the old one across two implementations.
- **Negative:** a one-minor deprecation window with a live alias + warning; a second internal
  rename is left pending for 0.3.0 (tracked here).
- **Carry-over:** 0.3.0 removes the alias and revisits the internal reader / capability-JSON
  names for consistency — resolved below.

## Addendum (0.3.0) — the carry-over, decided

The alias removal landed with the deprecation-clearance batch, and the deferred names were
renamed **in full** rather than left behind:

| Surface | Was | Now |
| --- | --- | --- |
| Class-level reader | `type_specifiers` | `narrowing_facts_rules` |
| Engine-invoked consumer | `#type_specifier_facts(call_node:, scope:)` | `#narrowing_facts_for(call_node:, scope:)` |
| `rigor plugins --capabilities` JSON key | `type_specifier_methods` | `narrowing_facts_methods` |

The Decision's scope limit rested on two claims. The first — the internals are API a plugin
author never writes — is true but does not argue for *keeping* a name the ADR calls misleading;
the drift-pinned reader is read by anyone extending the engine, and leaving it on the old name
preserves the wrong mental model at the place the contract is implemented. The second — the JSON
key is a separately-frozen surface whose rename is a distinct decision — is exactly why it had
to be settled *here*: the key freezes as public vocabulary at v1.0 ([ADR-50](50-release-engineering-and-stability-strategy.md)
WD1), and 0.3.0 is a minor that may break, so this was the last window in which the correction
was free. Deferring again would have frozen the misname in the one surface an outside consumer
actually reads.

Cost: a consumer of `rigor plugins --capabilities` must read the new key (the value's shape is
unchanged). That cost is paid once, by a small, enumerable audience, before 1.0 — the same
trade this ADR made for the verb itself.

## Relationship to other ADRs

- **ADR-37** — introduced the hook (slice 2); this renames it.
- **ADR-60** — kept the *split*; this refines the *name* the keep-verdict did not cover.
- **ADR-50** — the v1.0 freeze window this lands inside; the alias-then-remove is the pre-1.0
  BC discipline.
- **rigor-rs ADR-0027** (sibling Rust port) — mirrors this contract; should track the rename.
