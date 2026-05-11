# rigor-typescript-utility-types — example Rigor plugin

Reference example for **type-language vocabulary extension via
`Plugin::TypeNodeResolver`**. Maps the TypeScript-canonical
utility-type spellings onto the Rigor-canonical shape-projection
type functions introduced in [ADR-13](../../docs/adr/13-typenode-resolver-plugin.md).

The plugin ships **five resolvers**, one per supported TS
utility:

| TypeScript spelling | Rigor core call |
| --- | --- |
| `Pick<T, K>`     | `Type::Combinator.pick_of(T, K)` |
| `Omit<T, K>`     | `Type::Combinator.omit_of(T, K)` |
| `Partial<T>`     | `Type::Combinator.partial_of(T)` |
| `Required<T>`    | `Type::Combinator.required_of(T)` |
| `Readonly<T>`    | `Type::Combinator.readonly_of(T)` |

## Why a plugin?

[`docs/type-specification/imported-built-in-types.md`](../../docs/type-specification/imported-built-in-types.md) §
"Deferred or rejected imports" deliberately keeps TS-canonical
names out of Rigor's core surface — Rigor is RBS-superset, not
TypeScript-superset, and importing the TS spellings into core
would dilute that stance.

The shape **semantics** still belong in core: `pick_of[T, K]`
behaves identically across every consumer because there's one
spec-owned definition. This plugin is a pure translation layer
sitting on top.

## Why opt-in?

Adding the gem to the project's `.rigor.yml` is a deliberate
choice — projects that don't migrate from TypeScript / Sorbet /
Flow-style RBI never see the TS spellings. Once enabled, the
spellings appear inside `RBS::Extended` payloads:

```ruby
class Address
  # @rbs!
  #   %a{rigor:v1:return: Pick[Address::Shape, :name | :email]}
  def public_fields; end
end
```

## How it works

1. The parser produces an AST: `Generic("Pick", [Identifier("Address"), Generic("Union", […])])`.
2. The resolver's built-in `PARAMETERISED_TYPE_BUILDERS`
   doesn't recognise `Pick` (uppercase head, not a core type
   function).
3. The Resolver consults the plugin chain. `Resolvers::Pick`
   matches the head, recursively resolves each sub-arg through
   the full chain (built-in registry + chain + RBS Nominal
   fallback), and calls `Type::Combinator.pick_of` on the
   resolved types.
4. The result is a Rigor `Type` carrier that propagates
   through the normal inference pipeline.

Key insight: the recursive resolution at step 3 happens via
`scope.resolver.resolve(arg, scope)`. The `scope.resolver` is
the FULL pass (built-ins → chain → RBS), not just the chain
of plugins. This means resolvers can use Rigor's existing
vocabulary (`non-empty-string`, `Integer`, etc.) inside their
arguments without the plugin reimplementing name resolution.

## Deferred TypeScript utility names

The following TS utility types are NOT mapped today and
degrade to Rigor's RBS Nominal fallback (e.g. `Parameters<F>`
resolves as `Nominal[Parameters, [F]]`):

- `Parameters<F>`, `ReturnType<F>`, `ConstructorParameters<C>`
  — need a function-type projection operator (`params_of[F]`,
  `return_of[F]`) in core. Queued as a follow-up per ADR-13 § "Open questions".
- `InstanceType<C>` — needs `instance_type[C]` in core (mentioned
  in `imported-built-in-types.md` § "Deferred or rejected imports").
- `Awaited<P>` — Ruby has no Promise built-in; no Rigor analogue.
- `Uppercase<S>` / `Lowercase<S>` / `Capitalize<S>` / `Uncapitalize<S>`
  — TypeScript's compile-time string casing has no Rigor analogue.
- `ThisParameterType<F>` / `OmitThisParameter<F>` — Sorbet's
  `T.self_type` does the related work; not a TS-utility-types
  concern for Rigor.
- `NoInfer<T>` — TypeScript inference-control hint; Rigor's
  inference doesn't need it.

When core grows the prerequisite operators, the plugin gains
the corresponding rows in its next minor version.

## Lossy projection

Shape projection requires a structural carrier (`HashShape` or
`Tuple`) on the input. Applied to a bare `Nominal[Hash, [K, V]]`
or any other non-shape carrier, the projection returns the
input unchanged — `pick_of[Hash[K, V], K_subset]` evaluates to
`Hash[K, V]` with no narrowing.

The `dynamic.shape.lossy-projection` diagnostic that flags this
boundary lands when the caller-side diagnostic threading
arrives (ADR-13 slice 5b — deferred). For now, lossy
projection is silent.

## Configuration

```yaml
plugins:
  - gem: rigor-typescript-utility-types
```

No config keys — the resolver chain is registered by class
load. Multiple plugins MAY register resolvers for the same
head; ADR-13 § "Conflict policy" defines first-non-nil wins
in plugin-registration order.
