# rigor-mangrove

Sharpens [Mangrove](https://github.com/) `Result` / `Option`
unwrap-family return types from `untyped` to the concrete
type-argument carried at the call site, and synthesises the
subclasses an `Enum`'s `variants do … end` DSL generates at runtime
so they resolve statically. It layers on top of
[`rigor-sorbet`](rigor-sorbet.md) (which ingests Mangrove's `sig` /
RBI surface); this plugin adds the two precision steps sig-level
types can't reach. No runtime dependency.

It ships bundled in `rigortype`. Activate it under `plugins:`
(alongside `rigor-sorbet`, which supplies the carrier types):

```yaml
plugins:
  - rigor-sorbet
  - rigor-mangrove
```

## What it infers — no diagnostics, no config

The plugin emits no diagnostics of its own and has no
configuration. It contributes types in two places; the engine's
ordinary method-existence check then catches typos on the
now-known types.

**Unwrap-family return types.** When the receiver is a Mangrove
carrier carrying a type argument, the unwrap return narrows to that
argument:

```ruby
# token : Result::Ok[String, StandardError]
session.token.unwrap!.uppercaze   # error: undefined method `uppercaze' for String
```

**Enum variant synthesis (ADR-36 Slice A).** The `variants` DSL
emits nested subclasses at runtime; the plugin synthesises them
statically — the variant constant resolves, `.new` dispatches, and
a typed `#inner` reader returns the declared payload type:

```ruby
class Shape
  extend Mangrove::Enum
  variants do
    variant Circle, Float
  end
end

Shape::Circle.new(1.5).inner.floor                # ok — Float
Shape::Circle.new(1.5).inner.no_such_float_method # error: undefined for Float
```

## Limitations

- **No generic inference from constructors.** `Result::Ok.new("x")`
  yields a carrier with no type argument, so unwrap there
  contributes nothing (a conservative no-op, never a false
  positive).
- **Downcast narrowing keeps no type args (ADR-36 Slice B,
  deferred).** Narrowing a parent generic to a variant via `is_a?`
  doesn't yet carry the type arguments through the inheritance edge.
- **Non-constant payload shapes degrade.** A variant whose payload
  is a shape hash (`{ name: String }`) falls back to `Dynamic[Top]`.

## Plugin internals

The carrier-generic instantiation, the `NestedClassTemplate`
variant synthesis, and the relationship to `rigor-sorbet` are in
the [plugin's README](../../../plugins/rigor-mangrove/README.md);
the synthesis tier is [ADR-36](../../adr/36-mangrove-enum-nested-class-emission.md).
To write a plugin, see [`examples/`](../../../examples/README.md)
and the [`rigor-plugin-author`](../08-skills.md) skill.
