# Narrowing

A carrier describes a value at one program point. **Narrowing**
describes how the carrier changes when control flow passes
through a predicate. This chapter walks through every form of
narrowing Rigor recognises today.

The mental model: each predicate produces two scopes — one
for the truthy edge and one for the falsey edge. Inside each
edge, the variable's carrier is sharpened to whatever the
predicate proved. If the predicate is unrecognised, both
edges share the entry scope unchanged.

## Truthiness narrowing

The simplest form. `if x` separates "x is truthy" from "x is
`false` or `nil`":

```ruby
def shout(name)
  if name
    # name: String — `false | nil` removed by truthy edge
    name.upcase
  else
    # name: Constant<false> | Constant<nil>
    "(no name)"
  end
end
```

This form is what makes `if value` so common in Ruby useful at
lint time: inside the `if` body, Rigor knows `value` is
non-nil.

## `nil?` and the inverse

```ruby
def length(s)
  return 0 if s.nil?
  # s: Nominal[String] (the nil component of String? is gone)
  s.length
end
```

`s.nil?` narrows the truthy edge to `Constant<nil>` and the
falsey edge to "everything else" — typically the original
type with `nil` removed.

## `is_a?`, `kind_of?`, `instance_of?`

These three all narrow on the class hierarchy:

```ruby
def kind(x)
  if x.is_a?(Integer)
    # x: Integer
    x + 1
  elsif x.is_a?(String)
    # x: String
    x.length
  end
end
```

Subclass relationships are honoured: `is_a?(Numeric)` accepts
`Integer` and `Float` and narrows accordingly. `instance_of?`
is stricter — only the exact class — and Rigor narrows
correspondingly.

The falsey edge subtracts the matched class:

```ruby
x = some_call_that_returns_integer_or_string
unless x.is_a?(Integer)
  # x: String — Integer subtracted
  x.upcase
end
```

## Equality with literal values

Rigor narrows `==` and `!=` against trusted literal values:

```ruby
state = some_call_returning_a_symbol
if state == :ready
  # state: Constant<:ready>
  send_request
elsif state == :pending
  # state: Constant<:pending>
  retry_in(5)
end
```

This is most useful when `state` is itself a union of
constants (`Constant<:ready> | Constant<:pending> |
Constant<:failed>`). Each branch peels one member off, and
Rigor can prove the final `else` is one of the remaining
constants — not "any Symbol."

## `case` / `when`

`case x; when …` is narrowing-syntax sugar over equality and
class checks. Each `when` branch sees `x` narrowed to the
matched member:

```ruby
case n
when 0      then :zero        # Constant<0>
when 1..9   then :small       # int<1, 9>
when 10     then :ten         # Constant<10>
else             :large       # everything else
end
```

The result type unions the per-branch results. When the input
is a finite literal union, Rigor proves the `else` branch is
unreachable when every member is matched.

`case x; in pattern` (one-line pattern matching) narrows the
same way for the patterns Rigor understands — class checks,
literal equality, array / hash structural patterns.

## Boolean composition (`&&`, `||`, `!`)

```ruby
def safe_size(s)
  if s && !s.empty?
    # s: non-empty-string
    s.size
  end
end
```

`&&` chains left-to-right narrowing: the right-hand operand
is evaluated under the truthy edge of the left. `||` chains
the falsey edge. `!` swaps the two edges.

This composes with everything else:

```ruby
if x.is_a?(Integer) && x > 0
  # x: positive-int
end
```

The `is_a?` narrowed `x` to `Integer`, then the integer
comparison narrowed it further to `int<1, max>`.

## Integer comparisons

`<`, `<=`, `>`, `>=`, plus `Integer#zero?` / `#positive?` /
`#negative?` / `#nonzero?` / `Comparable#between?`, all narrow
integer ranges:

```ruby
def safe_index(arr, n)
  return :empty if arr.empty?
  return :out_of_range if n < 0 || n >= arr.size
  # n: int<0, arr.size - 1>  (in practice: int<0, max>
  # tightened against `n >= arr.size`)
  arr.fetch(n)
end
```

Range comparisons compose with literals:

```ruby
n = some_input
if n.between?(1, 9)
  # n: int<1, 9>
end
```

## Predicate methods on refinements

Rigor recognises a small set of "type-carrier predicate
methods" — methods whose return type is `bool` and whose
truthy / falsey edges narrow the receiver:

| Method | Narrows the receiver to |
| --- | --- |
| `String#empty?` | `Constant<"">` (truthy) / `non-empty-string` (falsey) |
| `Array#empty?` | `Constant<[]>` (truthy) / `non-empty-array[T]` (falsey) |
| `Hash#empty?` | `Constant<{}>` (truthy) / `non-empty-hash[K,V]` (falsey) |
| `Integer#zero?` | `Constant<0>` (truthy) / `non-zero-int` (falsey) |
| `Integer#positive?` | `positive-int` (truthy) / `non-positive-int` (falsey) |
| `Integer#negative?` | `negative-int` (truthy) / `non-negative-int` (falsey) |

Compose these as you would expect:

```ruby
def first_word(s)
  return "" if s.empty?
  # s: non-empty-string
  s.split.first    # at runtime always returns String,
                   # never nil — and Rigor knows it
end
```

## Named-capture regex narrowing (`if /(?<x>...)/ =~ str`)

When a regex with named captures matches in the predicate
position of `if` / `unless`, the captured locals are bound to
`String | nil` after the match, and narrowed to `String` in
the truthy branch:

```ruby
def parse_date(s)
  if /(?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2})/ =~ s
    # year, month, day: String  (narrowed from String | nil)
    "#{year}/#{month}/#{day}"
  else
    "no match"
  end
end
```

(In a future release the truthy edge will narrow further to
specific refinement carriers — `\d{4}` would produce
`decimal-int-string`. Tracked under
[`docs/MILESTONES.md`](../MILESTONES.md) § "v0.1.1 — Planned".)

## `!=` and `unless`

Both are mechanical mirrors of their non-negated forms.
`unless x` is `if !x` for narrowing purposes; `x != y` is
`!(x == y)`. Rigor swaps the two edges.

## Local rebinding flips the narrowing

A narrowing fact is **scope-local**. The moment you reassign
the variable, the fact resets:

```ruby
def example(s)
  return if s.nil?
  # s: String

  s = some_other_call    # s rebound — narrowing dropped
  s.upcase               # s: String? again, depending on
                         # the call's return type
end
```

This is why the engine's narrowing facts are bound to a
specific scope, not a specific variable name. Rebinding is
detected; mutation through method calls is not (Rigor does
not chase mutation).

## What's not narrowed (yet)

A few forms you might expect that Rigor does **not** narrow
today:

- `respond_to?(:method_name)` — proving "this object responds
  to that method" requires a structural facet the engine does
  not yet expose.
- `frozen?` and other mutation guards — Rigor does not track
  mutability as a narrowing fact yet.
- Open-ended class-comparison via `===` against arbitrary
  user-defined `case_eq` — only Class / Module / Range /
  Regexp are recognised.
- Method-chain receivers in `self`-targeted directives
  (`get_user.admin?`) — there is no scope binding to narrow
  against. Local, instance-variable, explicit-`self`, and
  implicit-self receivers are all supported (v0.1.1 Track 1
  slice 3).

When narrowing is not recognised, both edges share the entry
scope unchanged — Rigor stays conservative rather than
making a wrong call.

## Reading a narrowing trace

When you want to see what Rigor narrowed at a point:

```ruby
def foo(x)
  if x.is_a?(Integer)
    dump_type(x)     # emits an info diagnostic at this line
  end
end
```

`dump_type(...)` is the introspection helper. It is a no-op
at runtime (lives in the `Kernel` extension Rigor's test
harness uses) and emits a `dump.type` diagnostic naming the
inferred type. Use it during debugging to confirm a narrowing
fired.

`assert_type(value, "expected-string")` is the stricter
sibling: it emits a diagnostic when the inferred type does
NOT match the string. It is what the handbook examples use to
pin behaviour.

## What's next

Chapter 4 covers the structural carriers — `Tuple` and
`HashShape` — which behave a lot like a per-element
narrowing of `Array` and `Hash`.
