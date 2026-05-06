# Tuples and hash shapes

[← Narrowing](03-narrowing.md) · Next: [Methods and blocks →](05-methods-and-blocks.md)

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

## What's next

Chapter 5 covers the function side: how Rigor types method
parameters and return values, how block parameters are bound
through Enumerable iteration, and how arity / parameter-type
mismatches surface as `call.*` diagnostics.

[← Narrowing](03-narrowing.md) · Next: [Methods and blocks →](05-methods-and-blocks.md)
