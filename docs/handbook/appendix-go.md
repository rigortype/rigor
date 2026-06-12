# Appendix — Coming from Go

If your mental model of "types" was set by Go, this appendix
maps Rigor's vocabulary onto the concepts you already know. The
two have a real point of contact that surprises people: Go's
*implicitly satisfied* interface is exactly how Rigor's
structural typing works. The single most-misunderstood feature
in Rigor — "where do I declare that this class implements the
interface?" — is the one a Go programmer already understands by
reflex. You don't. You never did in Go either.

This is a translation table plus a discussion of where the two
diverge. Go is small, compiled, and deliberately spare —
no sum types, no inheritance, errors as values, zero values
everywhere. Rigor adds the things Go leaves out (unions,
refinements, literal types, nil-narrowing) and drops the things
Go needs as a compiled language (the build gate itself).

## The five-second pitch

| Question | Go | Rigor |
| --- | --- | --- |
| Interface membership | Implicit — have the methods, satisfy the interface | Implicit — same structural rule |
| When does the checker run? | At compile time; nothing runs until it passes | After the fact, on code that already runs |
| The "I don't know" type | `interface{}` / `any` | `Dynamic[Top]` — direct analogue |
| Where do annotations live? | In source; `:=` infers locals | In `.rbs` files; whole bodies inferred |
| Sum types | None — Go has no union types | First-class `T \| U` unions |
| Errors | Returned as values (`(T, error)`) | Raised; not tracked in the signature |

Go and Rigor share the structural-typing instinct and the
`any`-as-escape-hatch instinct. They part ways on the build
model — Go's checker is a gate the program passes before it
exists; Rigor's is an advisor over a program that already runs —
and on richness: Go is intentionally minimal where Rigor adds
unions, literal types, and refinements.

## Type vocabulary mapping

| Go | Rigor | Notes |
| --- | --- | --- |
| `int` / `int64` / `uint` | `Integer` | Ruby integers are arbitrary-precision; no width or signedness. |
| `float64` / `float32` | `Float` | `Numeric` is the common supertype. |
| `bool` | `bool` (`Constant<true> \| Constant<false>`) | Structurally a union of two constants. |
| `string` | `String` | |
| `byte` / `rune` | `Integer` | Ruby has no distinct byte/rune type. |
| `nil` | `nil` (`Constant<nil>`) | Go's typed-nil subtleties have no Ruby analogue — there is one `nil`. |
| `interface{}` / `any` | `Dynamic[Top]` | The "be silent here" carrier — a direct match. |
| `error` | (no type — Ruby raises) | See [Errors as values](#errors-as-values-vs-raising). |
| `[]T` (slice) | `Array[T]` | |
| `[N]T` (array) | `Tuple[…]` or `Array[T]` | A fixed-length literal gets a `Tuple`; otherwise `Array[T]`. |
| `map[K]V` | `Hash[K, V]` | |
| `struct{ X int; Y int }` | `Point = Data.define(:x, :y)` | See [Structs ↔ Data.define](#structs--datadefine). |
| `interface{ Draw() string }` | RBS `interface` (structural) | The direct analogue — see below. |
| `*T` (pointer, nil-able) | `T?` (i.e. `T \| nil`) | A nil-able pointer narrows like `T?`. |
| `iota` const group | `Constant<…>` union | Go's enum idiom; Rigor uses a union of constants or symbols. |
| `[T any]` (generics, 1.18+) | RBS `[T]` type parameter | |
| (no sum types) | `T \| U` | Go has no unions at all — a Rigor addition. |
| (no literal types) | `Constant<42>` / `Constant<"hi">` | Go has no literal types; a Rigor novelty. |

## Structural interfaces — the part you already know

This is the section that makes Go programmers feel at home. In
Go, a type satisfies an interface by *having its methods* — no
`implements` keyword, no declaration of intent:

```go
type Drawable interface { Draw() string }

type Button struct{ /* … */ }
func (b Button) Draw() string { return "[button]" }
// Button satisfies Drawable. You never said so.
```

Rigor's RBS `interface` works exactly this way:

```ruby
# An RBS structural interface
interface _Drawable
  def draw: () -> String
end
```

Any Ruby object that responds to `draw` returning a `String`
satisfies `_Drawable` — you never write `implements`, never
declare conformance. This is the **one** word in Rigor that
trips up readers arriving from Java or C#, where `interface`
means a *nominal* contract you must declare. For you it needs no
explanation: it is Go's interface, including the convention of
keeping interfaces small.

Rigor goes one step further than Go: it infers anonymous object
*shapes* and capability roles even when no interface is
declared at all — the equivalent of Go inferring `interface{
Draw() string }` from how you used a value. The
[structural-typing appendix](appendix-protocols-and-structural-typing.md)
is the canonical explainer.

## Narrowing — type switch / assertion

Go narrows an `interface{}` value through type assertions and
type switches. Rigor has direct analogues.

| Go | Rigor |
| --- | --- |
| `if x != nil` | `if x` (strips `nil`), or `unless x.nil?` |
| `v, ok := x.(string)` (comma-ok assertion) | `x.is_a?(String)` narrowing in an `if` |
| `switch v := x.(type) { case string: … }` | `case x; in String => v` |
| `x.(T)` (assertion, panics on fail) | (no panicking assertion) — `is_a?` guard, or `T.cast` via [`rigor-sorbet`](../../plugins/rigor-sorbet/) |
| user func returning `bool` | `%a{rigor:v1:predicate-if-true: x is Foo}` directive |

Go's type switch is *not* exhaustive — you can omit cases and
fall through `default` — and neither is Rigor's `case`. Both
report what they can prove, not what you forgot. (Where Rigor
adds value is the dual: if a `case`/`in` clause can *never*
match because earlier clauses already covered its type, the
`flow.unreachable-clause` rule from
[ADR-47](../adr/47-narrowing-driven-clause-reachability.md) says
so.)

## Errors as values vs raising

Go's defining idiom — `(T, error)` returned together, checked
with `if err != nil` — has no direct Rigor analogue, because
Ruby signals failure by *raising*, not returning. A Go function
becomes a Ruby method that returns `T` and raises on the error
path:

```go
func parse(s string) (int, error) { return strconv.Atoi(s) }

n, err := parse("x")
if err != nil { return err }
```

```ruby
def parse(s)             # returns Integer, raises on bad input
  Integer(s)
end

n = parse("x")           # raises ArgumentError on the error path
```

Rigor does not track the exception as part of the signature —
there is no typed error return and no `if err != nil` shape to
narrow. If you want to keep Go's value-returning style, you
*can* return a `Tuple` (`[value, error]` or `[:ok, value]` /
`[:error, reason]`) and pattern-match it with `case`/`in`;
Rigor types the `Tuple` and the union precisely. But that is a
port of the Go idiom, not idiomatic Ruby.

## nil, zero values, and absence

Go has no null-the-type, but it has nil-able pointers, maps,
slices, and interfaces — and *zero values*: an unset `int` is
`0`, an unset `string` is `""`, an unset pointer is `nil`.

Ruby has no zero-value rule. An unset instance variable reads
`nil`; an unset *local* raises `NameError` (it does not silently
become a zero). So:

- A Go nil-able `*T` maps onto Rigor's `T?` — `T | nil`,
  narrowed by an `x.nil?` / `if x` guard, the way you write
  `if p != nil` in Go.
- Go's zero-value-on-declare convenience has no Ruby analogue;
  Ruby forces you to assign before use, and Rigor's flow
  analysis tracks that a never-assigned local is not in scope.

The upshot: the `if err != nil` / `if ptr != nil` reflex
translates straight to `unless x.nil?`, and Rigor narrows the
non-nil branch exactly as you would expect.

## Structs ↔ `Data.define`

A Go `struct` used as an immutable value maps onto Ruby's
`Data.define` — value-equal, member-shaped, frozen. Rigor models
it natively ([ADR-48](../adr/48-data-struct-value-folding.md)).

```go
type Point struct{ X, Y int }
p := Point{X: 1, Y: 2}
a := p.X            // a : int
q := p
q.X = 9            // Go structs are mutable; this copies-then-mutates
```

```ruby
Point = Data.define(:x, :y)
p = Point.new(1, 2)
assert_type("1", p.x)   # member value is folded, not just Integer
q = p.with(x: 9)                  # immutable update — returns a new Point
```

Two notes for a Go reader:

- **Member values fold.** `Point.new(1, 2).x` is `1`,
  not merely `Integer`. Go erases the literal; Rigor keeps it
  (subject to the folding budget).
- **`Data` is immutable.** Unlike a Go `struct`, `Data.define`
  produces frozen values; you get a new one via `Data#with`. If
  you need Go's mutable struct, Ruby's `Struct` is the closer
  fit — but Rigor does not yet value-fold `Struct`, because its
  mutability breaks the soundness story (see
  [Chapter 6](06-classes.md)).

## Sum types Go doesn't have

This is the gap that bites Go programmers most, and the place
Rigor most clearly adds something. Go has **no union types** —
no way to say "this is a `Circle` or a `Rectangle`." The
workarounds are a sealed interface with unexported methods, or
an `interface{}` plus a type switch with a `default: panic`.

Rigor has first-class unions, and a closed set of variants is
simply a union of `Data.define` types dispatched with `case`/`in`:

```ruby
Circle    = Data.define(:radius)
Rectangle = Data.define(:w, :h)

def area(s)             # s : Circle | Rectangle
  case s
  in Circle    then Math::PI * s.radius * s.radius
  in Rectangle then s.w * s.h
  end
end
```

No marker interface, no `panic` default. The union is a real
type Rigor tracks, and `in Circle` narrows `s` to `Circle` along
that clause. This is the single biggest expressiveness gain
moving from Go's type system to Rigor's.

## Refinements and defined types

Go's `type Celsius float64` makes a *nominally distinct* type
from `float64` — but it cannot say "a positive `Celsius`" or "a
non-empty string." Rigor cannot reproduce Go's defined-type
nominal distinctness (`type Celsius float64` collapses to
`Float` in Rigor), but it adds the thing Go lacks: refinement
carriers that encode an invariant on the value.

| Rigor refinement | Go idiom | Comment |
| --- | --- | --- |
| `non-empty-string` | runtime `if len(s) == 0` check | Rigor produces it from `unless s.empty?`. |
| `positive-int` | runtime `if n <= 0` check | Rigor narrows from `n > 0`. |
| `int<1, 9>` | runtime range check | Rigor's range carrier handles arbitrary bounds. |
| `numeric-string` | `strconv.Atoi` + error check | No type-level analogue in Go. |
| `non-empty-array[T]` | runtime `len(xs) == 0` check | Rigor produces it from `unless arr.empty?`. |

So the trade runs both ways: Go gives you nominal newtypes
Rigor flattens, and Rigor gives you value-level refinements Go
has to check at runtime.

## Generics

Go added generics in 1.18; RBS has had them longer, and Rigor
reads them. The surfaces are close for the common cases.

| Go | Rigor (via RBS) |
| --- | --- |
| `func Id[T any](x T) T` | `def id: [T] (T) -> T` |
| `[]T` | `Array[T]` |
| `map[K]V` | `Hash[K, V]` |
| `[T constraints.Ordered]` | `[T < Comparable[T]]` bound |
| type sets / unions in constraints | RBS bounds (narrower) |

Go's constraint type-sets and Rigor's RBS bounds are both
modest by design; neither tries to be as type-level-expressive
as a fully dependent system.

## Severity, suppression, and "strict mode"

| Go | Rigor |
| --- | --- |
| `go vet` / linter severity | `severity_profile: lenient` / `balanced` / `strict` |
| `//nolint:rule` (golangci-lint) | `# rigor:disable <rule>` |
| file-level lint disable | `# rigor:disable-file all` |
| `go build` (the gate) | `rigor check lib` (the advisor) |

The mental shift: `go build` is the gate — code does not ship
until it compiles. `rigor check` is an advisor over code that
already runs, tuned with severity profiles and adopted
incrementally via baselines.

## What Go has and Rigor does not

Be honest about what you give up:

- **The compile gate.** Go does not run until it builds. Rigor
  is advisory; the program runs regardless of what it reports.
- **Defined-type nominal distinctness.** `type Celsius float64`
  is a distinct type in Go; Rigor flattens it to `Float`.
- **Goroutines and channel types.** `chan T`, `select`, the
  concurrency type machinery — no Rigor analogue.
- **Zero values.** Go's declare-and-it-is-zero convenience has
  no place in Ruby's assign-before-use model.
- **A single binary and compile-time guarantees.** Compile-model
  benefits a runtime advisor does not provide.

## What Rigor has and Go does not

The other direction — and for Go the list is long, because Go
is deliberately minimal:

- **Union / sum types.** The big one: `T | U` is first-class in
  Rigor and absent from Go. Closed variant sets need no marker
  interface.
- **Literal / constant types.** `Constant<42>`, `Constant<:ok>`,
  `Constant<"FOO">`. Go has no literal types; the nearest is an
  `iota` const group.
- **Constant folding through method calls.** `"foo".upcase` is
  `Constant<"FOO">`, not `string`.
- **Refinements.** `non-empty-string`, `positive-int`,
  `int<1, 9>` — invariants on the value, no runtime check needed
  to know them statically.
- **Inferred shapes beyond interfaces.** Rigor infers anonymous
  object shapes and capability roles, not just satisfaction of a
  declared `interface`.
- **No-false-positives stance.** Silent on `Dynamic[Top]`
  receivers rather than complaining — the `interface{}` you
  haven't narrowed yet costs you nothing.
- **No annotation tax beyond `:=`.** Go infers `:=` locals;
  Rigor infers whole method bodies *and* across `def`
  boundaries. A zero-`.rbs` project still yields useful
  diagnostics.

## A migration vignette

You are porting a Go package — an interface, a couple of
implementers, and a constructor that can fail — to Ruby. The
original:

```go
type Shape interface{ Area() float64 }

type Circle struct{ Radius float64 }
func (c Circle) Area() float64 { return math.Pi * c.Radius * c.Radius }

type Rectangle struct{ W, H float64 }
func (r Rectangle) Area() float64 { return r.W * r.H }

func parseRadius(s string) (float64, error) { return strconv.ParseFloat(s, 64) }
```

The Rigor approach — duck-typed implementers, an inferred
structural interface, and a raising parser:

```ruby
# lib/shape.rb
Circle    = Data.define(:radius) do
  def area = Math::PI * radius * radius
end

Rectangle = Data.define(:w, :h) do
  def area = w * h
end

def parse_radius(s)        # returns Float, raises on bad input
  Float(s)
end
```

What carries over and what changes:

- The `Shape` interface needs no Ruby declaration. Any object
  with `area` satisfies the structural interface; if you *want*
  to name it, an RBS `interface _Shape` works exactly like Go's,
  satisfied implicitly.
- `Circle` and `Rectangle` become `Data.define` values with
  methods — immutable where Go's structs were mutable.
- `(float64, error)` becomes a `Float` return that raises. The
  `if err != nil` check at the call site becomes a `rescue`, or
  you keep the value-style by returning a `Tuple` and matching
  it with `case`/`in`.
- If you dispatch over the shapes with a `case`/`in`, you get
  the union type Go could not express — and Rigor's
  `flow.unreachable-clause` will flag a clause that can never
  match.

## What's next

You probably do not need to read the rest of the handbook
sequentially. Useful pointers:

- [Protocols and structural typing](appendix-protocols-and-structural-typing.md)
  — the canonical page on RBS interfaces, the direct analogue to
  Go's implicit interfaces, and how they differ from ADR-28
  protocol contracts.
- [Chapter 3 — Narrowing](03-narrowing.md) for the flow rules —
  the analogue to type switches and assertions.
- [Chapter 6 — Classes](06-classes.md) for `Data.define`, the
  `struct` analogue, and its value-folding.

If you want to compare against another tool, the sibling
appendix pages cover [TypeScript](appendix-typescript.md),
[PHPStan](appendix-phpstan.md), [mypy](appendix-mypy.md),
[Steep](appendix-steep.md), [TypeProf](appendix-typeprof.md),
[Java / C#](appendix-java-csharp.md), [Rust](appendix-rust.md),
and [Elixir](appendix-elixir.md).
