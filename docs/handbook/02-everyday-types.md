# Everyday types

This is the most important chapter. Once you have a feel for
the carriers below, the rest of the handbook is just rules
operating on them.

## Why "type" is too coarse a word

A vanilla static checker answers "what *class* is this
object?" Rigor answers a narrower question: "what *subset of
values* can this expression actually produce?"

```ruby
n = 1 + 2
```

A vanilla checker says: `n: Integer`. Rigor says:
`n: Constant<3>`. Both are correct; Rigor's is much more
useful.

```ruby
n = ARGV.size
```

A vanilla checker says: `n: Integer`. Rigor says:
`n: int<0, max>` (a non-negative integer — `Array#size` cannot
return a negative count).

The reason this matters: most diagnostics Rigor wants to fire
need the narrower fact. "Integer" is not enough to prove
`n / 0` always raises; `Constant<0>` is. "Array" is not enough
to prove `arr.first.upcase` is safe; `non-empty-array[String]`
is.

So: every value at every program point is described by a
**carrier**. Carriers can be wide (`Integer`, `Dynamic[Top]`)
or narrow (`Constant<3>`, `non-empty-string`). The rest of
this chapter is the carrier zoo.

## Nominal types — the familiar starting point

The simplest carrier is the one you already know:
`Nominal[ClassName]`. It says "this is an instance of that
class" with no additional information.

```ruby
n = ARGV.first         # Nominal[String] | Constant<nil>
                       # (RBS says `String?`, which is
                       # String | nil)
```

`Nominal[Integer]`, `Nominal[String]`, `Nominal[Symbol]`,
`Nominal[Hash[K, V]]` — exactly what you expect. The display
form drops the `Nominal[]` wrapper for readability:
`Integer`, `String`, `Hash[String, Integer]`.

Rigor reads nominal types from RBS. When you write
`def foo(s) -> ::String`, the call site's result is
`Nominal[String]`. When the receiver class has a richer
catalogue (built-in `String`, `Array`, `Integer`, …), Rigor
often produces something narrower than nominal — see below.

## Constants — single Ruby values

`Type::Constant` is Rigor's "I know exactly which value this
is" carrier. It wraps one Ruby literal:

```ruby
n = 42
assert_type(n, "Constant<42>")

s = "hello"
assert_type(s, "Constant<\"hello\">")

sym = :foo
assert_type(sym, "Constant<:foo>")

t = true
assert_type(t, "Constant<true>")
```

Rigor folds arithmetic and string composition aggressively
when every operand is a Constant:

```ruby
two = 1 + 1               # Constant<2>
ten = 5 * 2               # Constant<10>
hi  = "Hello, " + "world" # Constant<"Hello, world">
sym = "foo".to_sym        # Constant<:foo>
```

Folding extends to a long list of "pure" methods on Numeric,
String, Symbol, Array, and Hash. The list is not in this
handbook (it would fill several pages); see
[`docs/types.md`](../types.md) and the per-class catalogues
under
[`data/builtins/ruby_core/`](../../data/builtins/ruby_core/).

When folding is **not** safe (because a method has side
effects, depends on the environment, or is not in a
catalogued built-in class), Rigor declines and you get a
nominal carrier or `Dynamic[Top]`.

## Integer ranges — bounded intervals

Some integer-valued expressions produce a known range without
producing a single literal value. Rigor describes those with
`Type::IntegerRange`, displayed as `int<min, max>`:

```ruby
n = ARGV.size               # int<0, max>
m = n + 1                   # int<1, max>
double = n * 2              # int<0, max>  — multiplication preserves the floor
```

`max` here means "positive infinity" — the upper bound is
unbounded.

A handful of common ranges have shorter names:

| Spelling | Meaning |
| --- | --- |
| `positive-int` | `int<1, max>` |
| `non-negative-int` | `int<0, max>` |
| `negative-int` | `int<min, -1>` |
| `non-positive-int` | `int<min, 0>` |

`Array#size`, `Array#length`, `Hash#size`, `String#size`, …
all carry `non-negative-int`. `Array#count` does too. Adding
`1` to a `non-negative-int` produces a `positive-int`. Adding
`-1` produces an unconstrained `Integer` (it could go below
zero).

## Refinements — values restricted by a predicate

Some types are not "this nominal class minus / plus a literal
value" but "this nominal class restricted by a predicate."
Rigor uses the carrier `Type::Refined` for these, displayed
with a kebab-case name. The catalogue:

| Refinement | Means |
| --- | --- |
| `non-empty-string` | `String` whose `#empty?` is provably `false` |
| `lowercase-string` | `String` equal to its `#downcase` |
| `uppercase-string` | `String` equal to its `#upcase` |
| `numeric-string` | `String` parseable as a number |
| `decimal-int-string` | `String` parseable as a decimal integer |
| `octal-int-string` | leading `0o` / octal digits |
| `hex-int-string` | leading `0x` / hex digits |
| `literal-string` | `String` provably composed from literals |
| `non-empty-lowercase-string` | both at once |
| `non-empty-uppercase-string` | both at once |
| `non-empty-literal-string` | both at once |

Most of these carriers come into being one of two ways:

1. **Through narrowing** — `if s.empty?` gives `s` the type
   `non-empty-string` in the false branch (see
   [Chapter 3](03-narrowing.md)).
2. **Through `RBS::Extended` annotations** — a method's RBS
   sig says `String`, but the author knows the runtime
   always returns non-empty, so they tag
   `%a{rigor:v1:return: non-empty-string}` (see
   [Chapter 7](07-rbs-and-extended.md)).

Refinements **erase** to their base nominal class for RBS
interop. A method whose signature says `-> String` keeps
that contract — Rigor only adds a tighter view inside its
own analysis.

The negation form `~T` denotes the complement: `~lowercase-string`
is "a String that has at least one non-lowercase character."
A small number of refinements have a hand-paired complement
(`lowercase-string` ↔ `non-lowercase-string`) which Rigor
prefers when it can; the rest fall back to a generic
`Difference` form.

## Difference — a base minus a single value

`non-empty-string` could equivalently be spelled
`String - ""`. Rigor uses `Type::Difference` for this kind of
carrier:

| Carrier | Equivalent |
| --- | --- |
| `non-empty-string` | `String - ""` |
| `non-zero-int` | `Integer - 0` |
| `non-empty-array[T]` | `Array[T] - []` |
| `non-empty-hash[K, V]` | `Hash[K, V] - {}` |

You will see them most often in narrowing:

```ruby
n = some_integer_call
if n.zero?
  # n: Constant<0>
else
  assert_type(n, "non-zero-int")  # narrowed by !.zero?
end
```

## `Dynamic[Top]` — the gradual carrier

Sometimes Rigor cannot prove anything tighter than "this
could be any Ruby value." That is `Dynamic[Top]`, often
shortened to `untyped` for the RBS-erased view.

```ruby
def foo(x)
  x.bar           # x: Dynamic[Top] — no calling-side info
end
```

`Dynamic[T]` (with a non-Top inner) is the more specific
gradual form: "we do not have a static contract for this
value, but the static facet behaves like `T`." It pops up
when an RBS-declared `untyped` boundary meets a class Rigor
already knows something about.

A diagnostic NEVER fires on a `Dynamic[Top]` receiver. That is
the no-false-positives stance — Rigor stays silent rather
than reporting on values it cannot characterise.

## Tuples and hash shapes — heterogeneous structures

`[1, "two", :three]` is more specific than "an Array of mixed
elements." Rigor describes it with `Type::Tuple`:

```ruby
arr = [1, "two", :three]
# Tuple[Constant<1>, Constant<"two">, Constant<:three>]

first, second, third = arr
assert_type(first,  "Constant<1>")
assert_type(second, "Constant<\"two\">")
assert_type(third,  "Constant<:three>")
```

Same for hashes with literal keys:

```ruby
h = { name: "Alice", age: 30 }
# HashShape{name: Constant<"Alice">, age: Constant<30>}

assert_type(h[:name], "Constant<\"Alice\">")
```

Tuples and hash shapes erase to `Array[…]` and `Hash[K, V]`
when crossing an RBS boundary. Inside Rigor they carry the
full per-position / per-key type information so destructuring
and slot access stay precise.

Chapter 4 covers tuples and hash shapes in depth.

## Unions — "one of these"

When a value can be one of finitely many types, Rigor uses
`Type::Union`:

```ruby
label = case n
        when 0      then :zero
        when 1..9   then :small
        else             :large
        end
# Constant<:zero> | Constant<:small> | Constant<:large>
```

A union of constants is the closest Ruby gets to a sum type or
discriminated union. Rigor takes them seriously: switching on
a literal-union value with `case` produces a precise narrowing
(see [Chapter 3](03-narrowing.md)).

There are limits — Rigor does not extend a union past a
configurable size budget. Beyond that, it widens to the union
of the members' nominal bases. This keeps the analyzer fast
and predictable on degenerate input.

## A worked example

Putting it together:

```ruby
def classify(n)
  if n.zero?
    :zero
  elsif n.positive?
    :positive
  else
    :negative
  end
end

result = classify(some_integer_input)
assert_type(result, "Constant<:zero> | Constant<:positive> | Constant<:negative>")
```

A vanilla type-checker would call `result: Symbol`. Rigor
narrows to the exact 3-element union. If you later write

```ruby
case result
when :positive then "+"
when :negative then "-"
when :zero     then "0"
end
```

Rigor proves the `case` is exhaustive — every union member
matches some `when` — and the result is
`Constant<"+"> | Constant<"-"> | Constant<"0">`.

## What's next

Chapter 3 (narrowing) is the engine that takes these carriers
and changes them as control flow passes — `if` / `case` /
`is_a?` / `nil?`. That is where the value-lattice carriers
above start paying for themselves.
