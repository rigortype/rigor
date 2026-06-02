# rigor-typescript-utility-types

Maps the TypeScript-canonical utility-type spellings (`Pick`, `Omit`,
`Partial`, `Required`, `Readonly`) onto the Rigor-canonical
shape-projection type functions (`pick_of`, `omit_of`, `partial_of`,
`required_of`, `readonly_of`) introduced in
[ADR-13](../../docs/adr/13-typenode-resolver-plugin.md), via five
`Plugin::TypeNodeResolver`s. A pure translation layer — the shape
semantics live in core.

> **Using this plugin?** The user guide — the spelling table, activation,
> and limitations — lives in the manual at
> [docs/manual/plugins/rigor-typescript-utility-types.md](../../docs/manual/plugins/rigor-typescript-utility-types.md),
> and the shape projections themselves are covered in handbook chapter 4
> (§ "Deriving new shapes") + the TypeScript appendix. This README
> covers the plugin's internals.

## Why a plugin (not core)?

[`docs/type-specification/imported-built-in-types.md`](../../docs/type-specification/imported-built-in-types.md) §
"Deferred or rejected imports" deliberately keeps TS-canonical names out
of Rigor's core surface — Rigor is RBS-superset, not TypeScript-superset,
and importing the TS spellings into core would dilute that stance. The
shape **semantics** still belong in core (`pick_of[T, K]` has one
spec-owned definition shared by every consumer); this plugin is a pure
translation layer on top, opt-in so projects that never migrate from
TypeScript / Sorbet / Flow-style RBI don't see the spellings.

## How it works

1. The parser produces an AST: `Generic("Pick", [Identifier("Address"), Generic("Union", […])])`.
2. The built-in `PARAMETERISED_TYPE_BUILDERS` doesn't recognise `Pick`
   (uppercase head, not a core type function), so the resolver consults
   the plugin chain.
3. `Resolvers::Pick` matches the head, recursively resolves each
   sub-arg through the full pass, and calls `Type::Combinator.pick_of`.
4. The result is a Rigor `Type` carrier flowing through normal inference.

The recursive resolution at step 3 goes through
`scope.resolver.resolve(arg, scope)` — the **full** pass (built-ins →
chain → RBS), not just the plugin chain — so resolvers reuse Rigor's
existing vocabulary (`non-empty-string`, `Integer`, …) inside their
arguments without reimplementing name resolution. The chain registers by
class load; multiple plugins MAY register resolvers for the same head
(ADR-13 § "Conflict policy": first-non-nil wins, registration order).

## Deferred TypeScript utility names

NOT mapped today — they degrade to Rigor's RBS Nominal fallback (e.g.
`Parameters<F>` resolves as `Nominal[Parameters, [F]]`):

- `Parameters<F>` / `ReturnType<F>` / `ConstructorParameters<C>` — need
  a function-type projection operator (`params_of[F]`, `return_of[F]`)
  in core (ADR-13 § "Open questions").
- `InstanceType<C>` — needs `instance_type[C]` in core.
- `Awaited<P>` — Ruby has no Promise built-in.
- `Uppercase<S>` / `Lowercase<S>` / `Capitalize<S>` / `Uncapitalize<S>`
  — TypeScript's compile-time string casing has no Rigor analogue.
- `ThisParameterType<F>` / `OmitThisParameter<F>` — Sorbet's
  `T.self_type` territory, not a TS-utility-types concern.
- `NoInfer<T>` — TypeScript inference-control hint; not needed.

When core grows the prerequisite operators, the plugin gains the
corresponding rows in its next minor version.

## Lossy projection

Shape projection requires a structural carrier (`HashShape` or `Tuple`)
on the input. Applied to a bare `Nominal[Hash, [K, V]]` or any other
non-shape carrier, the projection returns the input unchanged and Rigor
records a `dynamic.shape.lossy-projection` `:info` diagnostic (wired in
ADR-13 slice 3b via the `RbsExtended::Reporter`), attributed to the
source annotation's location, so the lossy boundary is auditable.
