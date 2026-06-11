# Appendix — Coming from Rust

If your mental model of "types" was set by Rust, this appendix
maps Rigor's vocabulary onto the concepts you already know.
Rust and Rigor sit at opposite ends of one axis — Rust is
ahead-of-time, sound, and refuses to compile anything it cannot
prove safe; Rigor analyses Ruby that already runs and stays
silent on anything it cannot prove *wrong* — but they meet
surprisingly often on the others: sum types, exhaustive
matching, the absence of a billion-dollar null.

This is a translation table plus a discussion of the places
where the two systems make genuinely different choices. Those
are where your Rust reflexes will mislead you. The biggest one:
Rust's type checker is a gate the program must pass before it
exists; Rigor's is an advisor over a program that already runs.
There is no borrow checker, no ownership, and no "it does not
compile" — the Ruby ran, and Rigor tells you where it can prove
a type goes wrong.

> **In this appendix**
> [Five-second pitch](#the-five-second-pitch) ·
> [Type vocabulary mapping](#type-vocabulary-mapping) ·
> [Option and Result](#option-and-result) ·
> [Narrowing ↔ match / if let](#narrowing--match--if-let) ·
> [Sum types & exhaustiveness](#sum-types-and-exhaustiveness) ·
> [Structs ↔ Data.define](#structs--datadefine) ·
> [Traits ↔ RBS interfaces](#traits--rbs-interfaces) ·
> [Refinements vs the newtype pattern](#refinements-vs-the-newtype-pattern) ·
> [Generics](#generics) ·
> [Severity & strict mode](#severity-suppression-and-strict-mode) ·
> [What Rust has, Rigor doesn't](#what-rust-has-and-rigor-does-not) ·
> [What Rigor has, Rust doesn't](#what-rigor-has-and-rust-does-not) ·
> [Migration vignette](#a-migration-vignette)

## The five-second pitch

| Question | Rust | Rigor |
| --- | --- | --- |
| When does the checker run? | At compile time; nothing runs until it passes | After the fact, on code that already runs |
| Soundness stance | Sound — a type error is a hard stop | No-false-positives — silent unless it can prove the error |
| Where do annotations live? | In source; locals inferred, signatures explicit | In `.rbs` files; whole bodies inferred |
| The "I don't know" type | (none — Rust has no escape hatch) | `Dynamic[Top]` — silent at the boundary |
| Null | Does not exist (`Option<T>` instead) | `nil` exists; narrowed away like Rust narrows `Option` |
| Identity of types | Nominal, with trait coherence | Nominal + structural facets |

Rust earns its guarantees by refusing to run until every value
is accounted for. Rigor takes the opposite bet: the program
runs, most of it is fine, and the analyzer should only speak
when it can *prove* a problem — never frighten working code over
a worst-case it cannot rule out. If "the compiler is always
right and I obey it" is your reflex, the one to retrain is that
Rigor is an advisor, not a gate.

## Type vocabulary mapping

| Rust | Rigor | Notes |
| --- | --- | --- |
| `i8` / `i32` / `i64` / `u32` / `usize` | `Integer` | Ruby integers are arbitrary-precision; no width or signedness in the type. |
| `f32` / `f64` | `Float` | `Numeric` is the common supertype. |
| `bool` | `bool` (`Constant<true> \| Constant<false>`) | Structurally a union of two constants. |
| `char` / `&str` / `String` | `String` | Ruby has one string type; no borrow distinction. |
| `()` (unit) | `nil` / `void` | `void` when the caller must ignore the result; `nil` as a value. |
| `!` (never) | `Bot` | Empty type — unreachable branches, `raise`-only bodies. |
| `Option<T>` | `T?` (i.e. `T \| nil`) | See [Option and Result](#option-and-result). |
| `Result<T, E>` | (no single carrier — Ruby raises) | See [Option and Result](#option-and-result). |
| `Vec<T>` / `&[T]` | `Array[T]` | |
| `HashMap<K, V>` | `Hash[K, V]` | |
| `HashSet<T>` | `Set[T]` | |
| `(i32, String)` (tuple) | `Tuple[Integer, String]` | Same per-position model. |
| `struct Point { x: i32, y: i32 }` | `Point = Data.define(:x, :y)` | See [Structs ↔ Data.define](#structs--datadefine). |
| `enum E { A, B(i32) }` (sum type) | union of the variants | See [Sum types & exhaustiveness](#sum-types-and-exhaustiveness). |
| `trait T { … }` | RBS `interface` (structural) | Nominal in Rust, structural in Rigor — see below. |
| `<T: Trait>` / `where T: Trait` | RBS `[T < Bound]` bounded parameter | |
| `dyn Trait` | a structural interface type | Dynamic dispatch over the method set. |
| `Box<dyn Any>` | `Dynamic[Top]` | The closest Rust has to "silence the checker"; Rigor reaches for it routinely, Rust almost never. |
| (no literal types) | `Constant<42>` / `Constant<"hi">` | Rust has no literal types (const generics aside); a Rigor novelty. |

## Option and Result

Rust's two famous enums split cleanly: one maps almost exactly
onto Rigor, the other does not, because Ruby chose a different
error-handling model.

**`Option<T>` ↔ `T?`.** This is a near-perfect match.
`Option<T>` is "a `T` or nothing"; Rigor's `T?` is `T | nil`,
and the narrowing mirrors `match` / `if let`:

```rust
fn length(s: Option<String>) -> usize {
    match s {
        Some(v) => v.len(),
        None => 0,
    }
}
```

```ruby
def length(s)            # s : String?  (RBS-declared)
  return 0 if s.nil?
  s.length               # s : String — nil stripped by the guard
end
```

The reflex to drop is `unwrap()`. In Rust you reach for
`.unwrap()` / `.expect()` when you *know* it is `Some`. Rigor
has no in-source assertion that lies to the checker; the
equivalents are a `nil?` guard (checked, not asserted) or
`T.must` via the [`rigor-sorbet`](../../plugins/rigor-sorbet/)
plugin (see [Chapter 10](10-sorbet.md)).

**`Result<T, E>` ↔ exceptions.** Here the models diverge. Ruby
signals failure by *raising*, not by returning a tagged value,
so there is no single `Result` carrier. A Rust function
returning `Result<T, E>` becomes a Ruby method that returns `T`
and raises on the error path:

```rust
fn parse(s: &str) -> Result<i32, ParseIntError> { s.parse() }
```

```ruby
def parse(s)             # returns Integer, raises on bad input
  Integer(s)
end
```

Rigor does not track the exception type as part of the
signature — there is no typed `throws` and no `?` operator. If
you want to keep Rust's value-returning style, you *can* return
a tagged tuple (`[:ok, value]` / `[:error, reason]`) and pattern-
match it with `case`/`in`, and Rigor will type the `Tuple` and
the union precisely — but that is a deliberate port of the Rust
idiom, not the idiomatic Ruby.

## Narrowing — `match` / `if let`

Rust narrows through `match`, `if let`, and pattern binding.
Rigor has direct analogues; the behaviour matches even though
the surface differs.

| Rust | Rigor |
| --- | --- |
| `match x { … }` | `case x; in …` |
| `if let Some(v) = x` | `if x` (strips `nil`), or `case x; in val` |
| `if let Pat = x { … }` (binding) | `case x; in Pat => v` |
| `x as i64` (numeric cast) | `x.to_i` / `Integer(x)` — a real conversion, not a type cast |
| `x.unwrap()` | (no in-source assertion) — `nil?` guard, or `T.must` via `rigor-sorbet` |
| `matches!(x, Pat)` | `case x; in Pat then true; else false; end`, or an `is_a?` predicate |
| guard `Pat if cond =>` | `in Pat if cond` (pattern guard) |

The structural-pattern part of `match` maps onto `case`/`in`
one-to-one: `in Circle => c` narrows `x` to `Circle` along that
clause exactly as `Circle(c) =>` does in Rust.

## Sum types and exhaustiveness

Rust's `enum` is an algebraic sum type, and `match` over it is
*compiler-enforced* exhaustive — miss a variant and it does not
compile. Rigor models the data the same way but approaches
exhaustiveness from the dual side.

A Rust `enum` whose variants carry data becomes, in Ruby, one
`Data.define` per variant plus a union of them:

```rust
enum Shape {
    Circle { radius: f64 },
    Rectangle { w: f64, h: f64 },
}

fn area(s: Shape) -> f64 {
    match s {
        Shape::Circle { radius } => PI * radius * radius,
        Shape::Rectangle { w, h } => w * h,
    }
}
```

```ruby
Circle    = Data.define(:radius)
Rectangle = Data.define(:w, :h)

def area(s)
  case s
  in Circle    then Math::PI * s.radius * s.radius
  in Rectangle then s.w * s.h
  end
end
```

The crucial difference is *direction*.
[ADR-47](../adr/47-narrowing-driven-clause-reachability.md)'s
`flow.unreachable-clause` rule fires when a clause is provably
*dead* — its subject already narrowed to `Bot` by prior clauses
or prior exhaustion:

```ruby
case shape
in Circle    then shape.radius
in Rectangle then shape.width * shape.height
in Circle    then "…"   # flow.unreachable-clause — Circle already covered
end
```

Rust **requires** you to cover every variant and rejects a
non-exhaustive `match`. Rigor does the dual — it reports clauses
that can never run, but it does **not** force you to handle every
variant. A `case` that omits a branch is not an error; an
*unreachable* clause is. This follows the no-false-positives
stance: an omitted branch may be intentional (that variant
cannot reach this point), and Rigor will not frighten working
code over it. If you want the missing-arm safety back, a
trailing `else raise` makes the omission explicit — the analogue
of Rust's `_ => unreachable!()`.

## Structs ↔ `Data.define`

A Rust `struct` maps onto Ruby's `Data.define` — an immutable,
value-equal, member-shaped aggregate. Rigor models it natively
([ADR-48](../adr/48-data-struct-value-folding.md)).

```rust
struct Point { x: i32, y: i32 }
let p = Point { x: 1, y: 2 };
let a = p.x;                       // a : i32
let q = Point { x: 9, ..p };       // functional update
```

```ruby
Point = Data.define(:x, :y)
p = Point.new(1, 2)
assert_type("1", p.x)    # member value is folded, not just Integer
q = p.with(x: 9)                   # Data#with ↔ Rust's ..p update
```

Two things go beyond Rust here:

- **Member values fold.** `Point.new(1, 2).x` is `1`,
  not merely `Integer`. Rust erases the literal at
  construction; Rigor keeps it (subject to the folding budget).
- **`with` is first-class.** `Data#with` is the analogue of
  Rust's `..p` functional-update syntax, and Rigor types the
  result with the overridden member folded in.

Ruby's mutable `Struct` is deliberately not folded the same way
yet; its mutability breaks the value-folding soundness story.
See [Chapter 6](06-classes.md).

## Traits ↔ RBS interfaces

Rust traits and Rigor's structural interfaces both describe "a
type that has these methods," but they differ on *how
membership is decided* — and the difference is the same one
Go programmers feel from the other side.

A Rust trait is **nominal with coherence**: a type has the trait
only if there is an explicit `impl Trait for Type`, and the
orphan rule governs where that `impl` may live. Rigor's RBS
`interface` is **structural**: any object with the right methods
satisfies it, no declaration of intent, no coherence rule. This
is Go's `interface`, not Rust's `trait`.

```ruby
# An RBS structural interface
interface _Drawable
  def draw: () -> String
end
```

Any Ruby object that responds to `draw` returning a `String`
satisfies `_Drawable` — you never write `impl _Drawable for …`.
Rigor also infers anonymous object *shapes* and capability roles
without any interface declared at all. The
[structural-typing appendix](appendix-protocols-and-structural-typing.md)
is the canonical explainer; the short version is "traits you do
not have to implement on purpose."

## Refinements vs the newtype pattern

When a Rust invariant outruns the type system — "a string that
is non-empty," "an integer in 1..=9" — you reach for the newtype
pattern: a `struct NonEmptyString(String)` with a validating
constructor. Rigor has first-class refinement carriers instead;
the invariant rides on the ordinary type, produced automatically
by narrowing.

| Rigor refinement | Rust idiom | Comment |
| --- | --- | --- |
| `non-empty-string` | `struct NonEmptyString(String)` newtype | Rigor produces it from `unless s.empty?`, no wrapper. |
| `positive-int` | `struct PositiveInt(u32)` newtype | Rigor narrows from `n > 0`. |
| `int<1, 9>` | newtype + range check, or const generics gymnastics | Rigor's range carrier handles arbitrary bounds directly. |
| `numeric-string` | newtype wrapping validated parse | No type-level analogue. |
| `non-empty-array[T]` | newtype over `Vec<T>` | Rigor produces it from `unless arr.empty?`. |

If you have ever written a newtype purely to encode an invariant
the compiler could not express on the base type, this is the
part of Rigor that earns its keep — no wrapper allocation, the
invariant narrowed from a plain `if`.

## Generics

RBS generics are what Rigor reads; they are more conservative
than Rust's. RBS supports class- and method-level type
parameters with bounds, but does not infer call-site
instantiation as eagerly, and has nothing like trait-bound
dispatch resolution.

| Rust | Rigor (via RBS) |
| --- | --- |
| `fn id<T>(x: T) -> T` | `def id: [T] (T) -> T` |
| `Vec<T>` | `Array[T]` |
| `HashMap<K, V>` | `Hash[K, V]` |
| `fn f<T: Ord>(x: T)` | `def f: [T < Comparable[T]] (T) -> void` |
| `impl Trait` return | a structural interface return type |

Rust's associated types, higher-ranked trait bounds, and const
generics have no RBS analogue. Rigor's generics are deliberately
modest so the analyzer stays fast on real Ruby.

## Severity, suppression, and "strict mode"

| Rust | Rigor |
| --- | --- |
| `#![deny(warnings)]` / lint levels | `severity_profile: lenient` / `balanced` / `strict` |
| `#[allow(lint_name)]` | `# rigor:disable <rule>` |
| crate-level `#![allow(…)]` | `# rigor:disable-file all` |
| `cargo check` (the gate) | `rigor check lib` (the advisor) |

The mental shift: `cargo check` is part of the build — code does
not ship until it passes. `rigor check` is not a gate the
program must clear; it is a diagnostic surface you tune with
severity profiles and adopt incrementally via baselines. The
program already runs.

## What Rust has and Rigor does not

Be honest about what you give up:

- **Ownership and borrowing.** Rust's defining feature has no
  Rigor analogue — Ruby is garbage-collected and aliases freely.
  Rigor does not model lifetimes, moves, or `&mut` exclusivity.
  (This is not a gap Rigor is trying to fill; it is a different
  language's contract.)
- **Enforced exhaustiveness.** A non-exhaustive `match` is a
  Rust compile error. Rigor reports *unreachable* clauses, not
  *missing* ones — by design (see above).
- **No-null guarantee.** Rust *eliminates* null; `Option<T>` is
  the only absence. Rigor's `nil` still exists — it narrows it
  away, but it cannot promise a value is never `nil` the way
  Rust's type system can.
- **`Result` / the `?` operator.** Typed, value-level error
  propagation has no Rigor analogue; Ruby raises.
- **Trait coherence and associated types.** The `impl`-based,
  orphan-ruled trait machinery is outside RBS's structural model.
- **Const generics, zero-cost guarantees, `unsafe`.** All
  compile-model concepts with no place in a runtime advisor.

## What Rigor has and Rust does not

The other direction:

- **Literal / constant types.** `Constant<42>`, `Constant<:ok>`,
  `Constant<"FOO">`. Rust has no literal types; the nearest is a
  unit-variant `enum`, hand-declared. Rigor infers them from
  ordinary values.
- **Constant folding through method calls.** `"foo".upcase` is
  `Constant<"FOO">`, not `String`. Rigor catalogues which
  built-in methods are pure and folds through them.
- **Refinements without a newtype.** Invariants on the ordinary
  type, no wrapper struct and no validating constructor.
- **Structural facets without an `impl`.** A Ruby object that has
  the right methods satisfies an RBS `interface` with no
  declaration of intent — and Rigor infers anonymous shapes and
  capability roles besides.
- **No-false-positives stance.** Rigor stays silent on
  `Dynamic[Top]` receivers rather than complaining. You will
  never see a diagnostic whose honest answer is "well, the
  checker cannot know."
- **No annotation tax.** `rigor check` on a Ruby project with
  zero `.rbs` files still yields useful diagnostics from
  inference. Adding `.rbs` is incremental — every file you skip
  is `Dynamic[Top]` at the boundary, not an error.

## A migration vignette

You are porting a Rust module — a sum type with an exhaustive
`match` and an `Option`-returning lookup — to Ruby. The
original:

```rust
enum Shape {
    Circle { radius: f64 },
    Rectangle { w: f64, h: f64 },
}

fn area(s: &Shape) -> f64 {
    match s {
        Shape::Circle { radius } => PI * radius * radius,
        Shape::Rectangle { w, h } => w * h,
    }
}

fn first_circle(shapes: &[Shape]) -> Option<&Shape> {
    shapes.iter().find(|s| matches!(s, Shape::Circle { .. }))
}
```

The Rigor approach — `Data.define` for the variants, `case`/`in`
for the dispatch, `T?` for the optional, no annotations:

```ruby
# lib/shape.rb
Circle    = Data.define(:radius)
Rectangle = Data.define(:w, :h)

def area(s)
  case s
  in Circle    then Math::PI * s.radius * s.radius
  in Rectangle then s.w * s.h
  end
end

def first_circle(shapes)
  shapes.find { |s| s.is_a?(Circle) }   # returns Circle?  (Circle | nil)
end
```

What carries over and what changes:

- The `enum` variants become `Data.define` — immutable, value-
  equal, member-shaped, and Rigor folds their member reads.
- The `match` becomes `case`/`in`; `in Circle` narrows `s`
  exactly as `Shape::Circle { .. }` does.
- `Option<&Shape>` becomes a plain `Circle?` return —
  `Array#find` yields the element or `nil`, and a `nil?` guard
  at the call site narrows it, the way `if let Some(c)` would.
- The exhaustive `match` loses its enforced totality. Rigor will
  not demand the third variant you have not written; it will
  only tell you if a clause you *did* write can never run. Add a
  trailing `else raise` if you want Rust's `_ => unreachable!()`.

## What's next

You probably do not need to read the rest of the handbook
sequentially. Useful pointers:

- [Chapter 3 — Narrowing](03-narrowing.md) for the flow rules —
  the direct analogue to `match` / `if let` narrowing.
- [Chapter 6 — Classes](06-classes.md) for `Data.define`, the
  `struct` analogue, and its value-folding.
- [Chapter 7 — RBS and `RBS::Extended`](07-rbs-and-extended.md)
  for the directive grammar — `predicate-if-true` is the
  user-defined narrowing analogue.

If you want to compare against another tool, the sibling
appendix pages cover [TypeScript](appendix-typescript.md),
[PHPStan](appendix-phpstan.md), [mypy](appendix-mypy.md),
[Steep](appendix-steep.md), [TypeProf](appendix-typeprof.md),
[Java / C#](appendix-java-csharp.md), [Go](appendix-go.md), and
[Elixir](appendix-elixir.md).
