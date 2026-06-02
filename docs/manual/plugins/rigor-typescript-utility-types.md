# rigor-typescript-utility-types

Maps the TypeScript-canonical utility-type spellings onto Rigor's own
shape-projection type functions, so a codebase migrating from
TypeScript / Sorbet RBI can write the familiar names inside
`RBS::Extended` annotations. It registers five
[ADR-13](../../adr/13-typenode-resolver-plugin.md) `TypeNodeResolver`s
— a pure translation layer; the shape *semantics* live in core, where
they have one spec-owned definition shared by every consumer.

It ships bundled in `rigortype`. Activate it under `plugins:`:

```yaml
plugins:
  - rigor-typescript-utility-types
```

> **Full guide.** The shape projections themselves — what each does,
> the lossy-projection rule, and the TypeScript→Rigor vocabulary table
> — are covered in the handbook:
> [chapter 4 — Tuples and hash shapes](../../handbook/04-tuples-and-shapes.md)
> § "Deriving new shapes" and the
> [TypeScript appendix](../../handbook/appendix-typescript.md). This page
> is the operational quick reference.

## What it resolves

| TypeScript spelling | Rigor core projection |
| --- | --- |
| `Pick<T, K>` | `pick_of[T, K]` |
| `Omit<T, K>` | `omit_of[T, K]` |
| `Partial<T>` | `partial_of[T]` |
| `Required<T>` | `required_of[T]` |
| `Readonly<T>` | `readonly_of[T]` |

```ruby
class Address
  # @rbs!
  #   %a{rigor:v1:return: Pick[Address::Shape, :name | :email]}
  def public_fields; end
end
```

Once the plugin is active, the `Pick[…]` head resolves through the full
resolution pass (built-ins → plugin chain → RBS Nominal fallback), so
the sub-arguments may use any of Rigor's existing type vocabulary.

## No configuration

The plugin has no configuration knobs — the resolver chain is
registered at class load.

## Limitations

- **Unmapped TS names degrade to `Nominal`.** `Parameters<F>`,
  `ReturnType<F>`, `InstanceType<C>`, `Awaited<P>`, the string-casing
  utilities (`Uppercase`/`Lowercase`/…), `ThisParameterType`, and
  `NoInfer` are not mapped — they have no Rigor analogue yet (or need a
  core operator that hasn't landed) and resolve as `Nominal[Name, […]]`.
- **Lossy on non-shape carriers.** A projection applied to a bare
  `Nominal[Hash, [K, V]]` (rather than a `HashShape` / `Tuple`) returns
  the input unchanged and records a `dynamic.shape.lossy-projection`
  `:info` diagnostic so you can audit the call site.

## Plugin internals

The five resolver classes, the recursive resolution mechanism, and the
ADR-13 `TypeNodeResolver` contract are in the
[plugin's README](../../../plugins/rigor-typescript-utility-types/README.md).
To write a plugin, see [`examples/`](../../../examples/README.md) and the
[`rigor-plugin-author`](../08-skills.md) skill.
