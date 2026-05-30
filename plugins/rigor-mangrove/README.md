# rigor-mangrove (slice 1)

A precision plugin for the [Mangrove](https://github.com/kazzix14/mangrove)
functional toolkit (Result / Option carriers). It instantiates a
carrier's generic type-member at the **unwrap call site**, so
`result.unwrap!` / `result.unwrap_in(ctx)` / `option.unwrap_or(x)`
resolve to the carried value type instead of degrading to
`untyped`.

## This is NOT a type-source plugin

Mangrove is Sorbet-first: every carrier method carries an inline
`sig { ... }`, and the Enum DSL's dynamic variants are
materialised by a bundled Tapioca DSL compiler. So Mangrove's
*type source* is already covered by
[`rigor-sorbet`](../rigor-sorbet/README.md) (sig ingestion + RBI
walking). Install that to get the carrier signatures; install
**this** plugin on top to get the one thing sig ingestion
structurally cannot do — generic instantiation at the call site.

See the survey note
[`docs/notes/20260530-mangrove-library-survey.md`](../../docs/notes/20260530-mangrove-library-survey.md)
for the full reasoning and the two slices deferred to engine /
ADR work (`is_a?` exhaustive narrowing; the `variants do … end`
Enum DSL, tracked in [ADR-36](../../docs/adr/36-mangrove-enum-nested-class-emission.md)).

## What the plugin recognises

Mangrove's `Result` interface declares the unwrap family against
an abstract `type_member`:

```ruby
sig { abstract.returns(OkType) }
def unwrap!; end
```

When a method returns an applied generic — the realistic shape —
the receiver carries the instantiation:

```ruby
class Session
  # RBS / sig: token -> Mangrove::Result::Ok[String, StandardError]
end

Session.new.token            # => Mangrove::Result::Ok[String, StandardError]
Session.new.token.unwrap!    # without plugin: untyped
                             #    with plugin: String   ← type_args[0]
```

Resolving the `OkType` type-member to the receiver's first type
argument is generic instantiation, which neither `rigor-sorbet`
(it contributes the cataloged sig's return type verbatim) nor a
`def unwrap!: () -> untyped` stub performs. This plugin reads the
receiver's `type_args` and contributes `type_args[0]`.

### Recognised methods

| Carrier | Methods | Contributed return |
| --- | --- | --- |
| `Mangrove::Result` / `::Ok` / `::Err` | `unwrap!`, `unwrap_in`, `expect!`, `expect_with!`, `unwrap_or_raise!`, `unwrap_or_raise_with!`, `unwrap_or_raise_inner!` | `OkType` (`type_args[0]`) |
| `Mangrove::Option` / `::Some` / `::None` | `unwrap`, `unwrap!`, `unwrap_or`, `expect!`, `expect_with!` | `InnerType` (`type_args[0]`) |

## Demo

`demo/demo.rb` is clean — the unwrapped values dispatch against
the real `String` type:

```ruby
def demo(ctx)
  session = Session.new
  puts session.token.unwrap!.upcase
  puts session.token.unwrap_in(ctx).length
  puts session.cached_user.unwrap_or("guest").reverse
end
```

`demo/errors_demo.rb` typos a method on each unwrapped value;
`rigor check` reports exactly three errors **because** the
unwraps resolved to `String`:

```
errors_demo.rb:18:25: error: undefined method `uppercaze' for String
errors_demo.rb:22:32: error: undefined method `lenght' for String
errors_demo.rb:26:42: error: undefined method `revrse' for String
```

Drop `rigor-mangrove` from `demo/.rigor.yml` and all three go
silent — `untyped` swallows the typos. Run it:

```sh
cd demo
RUBYLIB="$PWD/../lib" bundle exec rigor check
```

## Enum variants (ADR-36)

Mangrove's `Enum` DSL declares an algebraic data type:

```ruby
class Shape
  extend Mangrove::Enum
  variants do
    variant Circle, Float
    variant Label, String
  end
end
```

At runtime each `variant <Const>, <Type>` row mints a nested subclass
(`Shape::Circle < Shape`) carrying `#inner : <Type>`, via
`const_missing` + `class_eval` — invisible to a static reader. This
plugin replays the contract statically through the
[ADR-36](../../docs/adr/36-mangrove-enum-nested-class-emission.md)
nested-class emission tier (`Macro::NestedClassTemplate`): the variant
constant resolves, `.new` dispatches, and `#inner` resolves to the
declared payload type.

```ruby
Shape::Circle.new(1.5).inner   # => Float   (not Dynamic[Top])
Shape::Label.new("hi").inner   # => String
```

So a typo on a variant payload is caught
(`Shape::Circle.new(1.5).inner.no_such_float_method` →
`undefined method 'no_such_float_method' for Float`), and variant
constants no longer read as `call.undefined-constant`. Slice A covers
constant resolution + `.new` + the typed `#inner` reader. `is_a?`
cross-variant exhaustive narrowing and non-constant payload shapes
(shape hashes) are deferred — see the ADR.

## Why it cannot frighten working code

The plugin only fires when the receiver already resolves to a
known Mangrove carrier carrying a non-empty `type_args`. It then
*sharpens* an existing `untyped` into a concrete type — it never
invents a receiver type and **emits no diagnostics of its own**.
On the bare-constructor shape (`Result::Ok.new("x")`), where the
engine produces a raw Nominal with no `type_args`, the plugin
no-ops rather than guessing. This respects Rigor's
false-positive discipline: any error you see came from the
engine checking a method against the now-known type, not from the
plugin.
