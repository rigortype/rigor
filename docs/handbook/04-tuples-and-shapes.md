# Tuples and hash shapes

`Tuple` and `HashShape` are how Rigor gives precise types to
heterogeneous arrays and known-key hashes. They look a lot like
Ruby's `Array` and `Hash` from the outside (and erase to those
nominal types when crossing an RBS boundary), but inside Rigor
they carry the per-position / per-key types that ordinary
`Array[T]` / `Hash[K, V]` would lose.

## Tuples — heterogeneous arrays

When the analyzer can prove the layout of an array literal, it
produces `Tuple[…]` rather than `Array[T]`:

```ruby
arr = [1, "two", :three]
# Tuple[Constant<1>, Constant<"two">, Constant<:three>]
```

The most common ways tuples appear in real code:

```ruby
# Multiple-assignment destructuring is per-position.
first, second, third = [10, 20, 30]
assert_type(first,  "Constant<10>")
assert_type(second, "Constant<20>")
assert_type(third,  "Constant<30>")

# divmod returns a 2-tuple.
quotient, remainder = 17.divmod(5)
assert_type(quotient,  "Constant<3>")
assert_type(remainder, "Constant<2>")

# Each-with-index yields a 2-tuple.
%w[a b c].each_with_index do |elt, idx|
  assert_type(elt, "Constant<\"a\"> | Constant<\"b\"> | Constant<\"c\">")
  assert_type(idx, "non-negative-int")
end
```

Indexed access into a tuple stays per-position:

```ruby
arr = [1, "two", :three]
arr[0]   # Constant<1>
arr[1]   # Constant<"two">
arr[-1]  # Constant<:three>
arr[5]   # Constant<nil> — out of bounds
```

Slicing with `[start, length]` or `[range]` produces a tuple
of the matching elements:

```ruby
arr = [10, 20, 30, 40, 50]
arr[1..3]    # Tuple[Constant<20>, Constant<30>, Constant<40>]
arr[2, 2]    # Tuple[Constant<30>, Constant<40>]
```

## Tuples through `map`, `select`, and friends

When you call an Enumerable method on a tuple, Rigor evaluates
the block once per element with the per-position type
substituted, then unions the results:

```ruby
arr = [1, 2, 3]
doubled = arr.map { |n| n * 2 }
# Tuple[Constant<2>, Constant<4>, Constant<6>]

mixed = [1, "two", :three]
strings = mixed.map { |x| x.to_s }
# Tuple[Constant<"1">, Constant<"two">, Constant<"three">]
```

`select` and `filter_map` widen to `Array[Element]` because
the resulting size depends on the predicate, not the
positions. `find` returns the union of the elements (or `nil`
when no element matches statically).

## Tuples widen — when and why

A `Tuple` widens to `Array[T]` when its size grows past the
configurable union budget, when an unknown-shape array is
concatenated to it, or when it crosses an RBS-declared
parameter typed as `Array[T]`. The widening is deterministic
and documented in
[`docs/type-specification/inference-budgets.md`](../type-specification/inference-budgets.md).

Widening is safe — `Array[T]` is a strictly less precise view
of the same value — but you lose the per-position information.
If you find yourself writing code where `[a, b, c]` should
type-check precisely but does not, look for a method
in the chain that takes `Array[T]` rather than a tuple, or a
`+` / `concat` against a wider array.

## Hash shapes — known-key hashes

The hash analogue is `HashShape`:

```ruby
user = { name: "Alice", age: 30, admin: false }
# HashShape{name: Constant<"Alice">, age: Constant<30>, admin: Constant<false>}

assert_type(user[:name],  "Constant<\"Alice\">")
assert_type(user[:age],   "Constant<30>")
assert_type(user[:admin], "Constant<false>")
```

Hash shapes have a few extra dimensions over tuples:

- **Required vs optional keys.** Was the key written
  unconditionally in the literal, or merged in conditionally?
- **Open vs closed.** Can the value carry extra keys beyond
  the listed ones?
- **Read-only entries.** Has Rigor seen a write to the key, or
  only reads?

Rigor tracks all three but exposes them mostly through the
narrowing rules — most users do not need to think about them
directly.

## Hash shapes through method calls

```ruby
config = { host: "example.com", port: 8080 }
# HashShape{host: Constant<"example.com">, port: Constant<8080>}

config.fetch(:host)        # Constant<"example.com">
config.fetch(:host, "x")   # Constant<"example.com"> (default unused)
config[:port]              # Constant<8080>
config.key?(:host)         # Constant<true>  — proven
config.empty?              # Constant<false> — proven
config.size                # Constant<2>
```

## Keyword-argument hashes

When you call a method with keyword arguments, the implicit
hash shape is what Rigor types-checks against:

```ruby
def connect(host:, port: 80)
  # ...
end

connect(host: "example.com")            # OK (port defaults)
connect(host: "example.com", port: 80)  # OK
connect(host: "example.com", port: "8080")  # warning when
                                            #  port: Integer
                                            #  is required
```

Hash shapes flow through `**` splat and double-splat
operations, so `connect(**opts)` where `opts` is a known
shape narrows correctly.

## Splat composition

Splatting one tuple into another preserves the per-position
information when the splat is at a fixed position:

```ruby
head = [1, 2]
tail = [3, 4]
arr = [*head, *tail]
# Tuple[Constant<1>, Constant<2>, Constant<3>, Constant<4>]

with_middle = [*head, "X", *tail]
# Tuple[Constant<1>, Constant<2>, Constant<"X">,
#       Constant<3>, Constant<4>]
```

Same for double-splat into hash shapes:

```ruby
defaults = { port: 80, ssl: false }
overrides = { port: 443, ssl: true }
final = { **defaults, **overrides }
# HashShape{port: Constant<443>, ssl: Constant<true>}
# (the override wins per Ruby semantics)
```

## Pattern matching destructuring

`case x in [a, b, c]` narrows `a` / `b` / `c` per-position
exactly like multiple-assignment:

```ruby
case [10, 20, 30]
in [first, _, third]
  assert_type(first, "Constant<10>")
  assert_type(third, "Constant<30>")
end
```

Hash patterns work the same way:

```ruby
case { name: "Alice", age: 30 }
in { name:, age: }
  assert_type(name, "Constant<\"Alice\">")
  assert_type(age,  "Constant<30>")
end
```

`AlternationPatternNode` (`Integer | String => x`) produces a
union for the captured local — see
[Chapter 3](03-narrowing.md) for the underlying narrowing
rule.

## When the layout is not provable

If even one element of an array literal has a non-Constant,
non-tuple-shaped type, Rigor falls back to `Array[T]` where
`T` is the union of element types — still useful, just not
per-position:

```ruby
arr = [1, ARGV.first]
# Array[Constant<1> | String?]
```

The same goes for hashes whose keys are not provably symbol /
string literals — Rigor produces `Hash[K, V]` rather than
`HashShape`.

## Deriving new shapes — `pick_of` / `omit_of` / `partial_of` / `required_of` / `readonly_of`

When you have a `HashShape` (or a `Tuple`) and want a derived
shape that keeps some fields, drops others, or flips the
required-ness, Rigor exposes five **shape-projection type
functions** on `Type::Combinator`. They mirror TypeScript's
`Pick` / `Omit` / `Partial` / `Required` / `Readonly` utility
types but are first-class Rigor operations — not a TS bolt-on.
Each preserves the source's existing classification (required /
optional / read-only / extra-keys policy) on the entries it
keeps.

| Projection | What it does | TypeScript analogue |
| --- | --- | --- |
| `pick_of[T, K]` | Keep only the entries whose key is in the literal-key union `K`. On `Tuple`, `K` is an integer-index union. | `Pick<T, K>` |
| `omit_of[T, K]` | Drop the entries whose key is in `K`; keep the rest. | `Omit<T, K>` |
| `partial_of[T]` | Flip every required entry to optional. **Does not** widen value types to `nil` — Rigor distinguishes "key absent" from "key present with `nil` value". | `Partial<T>` |
| `required_of[T]` | Inverse of `partial_of`. Every optional entry becomes required. | `Required<T>` |
| `readonly_of[T]` | Mark every entry as read-only in the current view. Does NOT prove the underlying object is frozen — it is a view-level marker. | `Readonly<T>` |

These show up in two surfaces:

### As `RBS::Extended` directive payloads

The projection name is part of the directive grammar — the
parser accepts Symbol / String literals and `|`-unions inside
the type-arg position, so you can author the key set inline:

```rbs
class UserView
  # The runtime returns the full user hash; the view exposes
  # only :name and :email to its caller. The directive narrows
  # the return-side HashShape to those two entries.
  %a{rigor:v1:return: pick_of[UserHash, :name | :email]}
  def public_attrs: () -> ::Hash[::Symbol, ::String]
end
```

Inside an analysed file, the call site's result type is the
projected HashShape rather than the raw `Hash[Symbol, String]`
the underlying RBS sig advertises.

### Through the opt-in TypeScript-utility-types plugin

If you prefer the TS spellings (`Pick<T, K>` etc.) in
directives, opt into the
[`rigor-typescript-utility-types`](../../examples/rigor-typescript-utility-types/)
plugin. The plugin registers a `Plugin::TypeNodeResolver` that
translates each TS name onto the canonical projection:

```yaml
# .rigor.yml
plugins:
  - gem: rigor-typescript-utility-types
```

```rbs
%a{rigor:v1:return: Pick[UserHash, "name" | "email"]}
```

The plugin chain resolves `Pick[…]` to `pick_of[…]` before the
analyzer sees it — the inferred result is identical to the
direct `pick_of` spelling. The plugin is purely a naming
convenience.

### Lossy projection

The projections fire only on carriers that preserve shape
information (`HashShape` and, for `pick_of` / `omit_of`,
`Tuple`). Applying them to a plain `Hash[K, V]` or any other
non-shape input is **lossy** — the projection silently
degrades to the input type and Rigor records a
[`dynamic.shape.lossy-projection`](../type-specification/diagnostic-policy.md)
`:info` diagnostic so you can audit the call site.

```rbs
class C
  # `User` here is `Nominal[User]`, not a HashShape, so the
  # projection cannot narrow anything. The directive is
  # accepted but `:info` records the lossy degrade.
  %a{rigor:v1:return: pick_of[User, :name]}
  def render: () -> ::User
end
```

The fix is usually to author a `HashShape` carrier (or use
`Data.define` / a `Struct`) instead of a bare `Nominal`.

## What's next

Chapter 5 covers the function side: how Rigor types method
parameters and return values, how block parameters are bound
through Enumerable iteration, and how arity / parameter-type
mismatches surface as `call.*` diagnostics.
