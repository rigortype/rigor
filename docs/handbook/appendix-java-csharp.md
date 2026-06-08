# Appendix — Coming from Java or C#

If your mental model of "static types" was set by Java or C#,
this appendix maps Rigor's vocabulary onto the concepts you
already know. Both languages bring nearly the same reflexes to
Ruby — nominal-first, annotate-everything, generics, records,
sealed hierarchies, pattern-matching `switch` — so one page
serves both, with the few places Java and C# diverge called out
inline.

The examples assume a modern LTS baseline: **Java 21** (records,
sealed types, pattern-matching `switch`, record patterns) and
**modern C#** on .NET 8 (nullable reference types, records,
`switch` expressions, declaration-site variance). Where a
feature is newer than that, the page says so.

This is a translation table plus a discussion of the places
where Rigor makes a genuinely different choice. Those are where
your Java / C# reflexes will mislead you — and for these two
languages the single biggest one is the direction of the
default: you annotate first and the compiler infers locally;
Rigor infers first and asks for annotations only at the edges.

> **In this appendix**
> [Five-second pitch](#the-five-second-pitch) ·
> [Type vocabulary mapping](#type-vocabulary-mapping) ·
> [Nominal-first vs inference-first](#nominal-first-vs-inference-first) ·
> [Narrowing](#narrowing--instanceof-is-pattern-switch) ·
> [Records ↔ Data.define](#records--datadefine) ·
> [Nullability](#nullability) ·
> [Generics & variance](#generics-and-variance) ·
> [Sealed types & exhaustiveness](#sealed-types-and-exhaustiveness) ·
> [Refinement carriers](#refinement-carriers--the-part-neither-language-has) ·
> [Severity & strict mode](#severity-suppression-and-strict-mode) ·
> [Where Java and C# differ](#where-java-and-c-differ) ·
> [What Java/C# have, Rigor doesn't](#what-java--c-have-and-rigor-does-not) ·
> [What Rigor has, Java/C# don't](#what-rigor-has-and-java--c-do-not) ·
> [Migration vignette](#a-migration-vignette)

## The five-second pitch

| Question | Java / C# | Rigor |
| --- | --- | --- |
| Where do annotations live? | In source, on every declaration | In `.rbs` files alongside `.rb` |
| Who writes them? | The author (always) | The author OR inference |
| Default for an unannotated value | There is no unannotated value (except `var` locals) | Inferred precisely or `Dynamic[Top]` |
| Identity of types | Nominal (a class `implements` / `: IFace`) | Nominal + structural facets |
| Inference scope | Local only (`var` / `var`) | Whole-method body, across `def` boundaries |
| When do diagnostics fire? | Whenever a type does not check | Only when Rigor can **prove** the unsoundness |

Java and C# are *ahead-of-time, soundness-first* type systems:
nothing runs until every declaration type-checks. Rigor is the
opposite stance — it analyses Ruby that already runs and stays
silent on anything it cannot prove wrong. The reflex to retrain
is "the type checker is a gate the program must pass": in Rigor
the program already passed (it runs), and the analyzer is an
advisor that only speaks when it is sure.

## Type vocabulary mapping

| Java | C# | Rigor | Notes |
| --- | --- | --- | --- |
| `String` | `string` | `String` | Display drops `Nominal[]`. |
| `int` / `long` | `int` / `long` | `Integer` | Ruby integers are arbitrary-precision; no `int`/`long` split. |
| `double` / `float` | `double` / `float` | `Float` | `Numeric` is the common supertype. |
| `boolean` | `bool` | `bool` (`Constant<true> \| Constant<false>`) | `bool` is structurally a union of two constants. |
| `null` | `null` | `nil` (`Constant<nil>`) | Ruby has one no-value; C#'s `null` and `default` collapse to `nil`. |
| `Object` | `object` | `Object` / `Top` | `Top` is the universal supertype when you mean "anything". |
| `void` | `void` | `void` | Same idea — caller must not consume the value. |
| (none) | (none) | `Bot` | Empty type — unreachable branches, `raise`-only bodies. Java's `Void` / C#'s `Never` (proposed) are the nearest spellings. |
| `Object` (untyped boundary) | `dynamic` | `Dynamic[Top]` | C#'s `dynamic` is the closest analogue — the "be silent here" carrier. |
| `T[]` / `List<T>` | `T[]` / `List<T>` / `IEnumerable<T>` | `Array[T]` | |
| `Map<K, V>` | `Dictionary<K, V>` / `IDictionary<K, V>` | `Hash[K, V]` | |
| `Set<T>` | `HashSet<T>` / `ISet<T>` | `Set[T]` | |
| `record Point(int x, int y)` | `record Point(int X, int Y)` | `Point = Data.define(:x, :y)` | See [Records ↔ Data.define](#records--datadefine). |
| `Optional<T>` | `T?` (nullable reference type) | `T?` (i.e. `T \| nil`) | Java models it as a *container*; C# as a *type modifier*. See [Nullability](#nullability). |
| `enum Color { RED, GREEN }` | `enum Color { Red, Green }` | `Constant<:red> \| Constant<:green>` (Symbol union) | Ruby has no native enum; the [`rigor-mangrove`](../../plugins/) plugin types richer enum DSLs. |
| `sealed interface Shape permits …` | `abstract` base + sealed hierarchy | union of the subtypes | See [Sealed types & exhaustiveness](#sealed-types-and-exhaustiveness). |
| `<T>` (generic) | `<T>` (generic) | RBS `[T]` type parameter | |
| `? extends T` (use-site) | `out T` (declaration-site) | covariant type parameter | See [Generics & variance](#generics-and-variance). |
| `? super T` (use-site) | `in T` (declaration-site) | contravariant type parameter | |
| `var x = …` | `var x = …` | (no spelling — every local is inferred) | Rigor infers *all* locals, not just `var`-declared ones. |
| (no literal types) | (no literal types) | `Constant<42>` / `Constant<"hi">` | Neither language has literal types; this is a Rigor novelty — see below. |
| `Stream<T>` / Streams API | `IEnumerable<T>` / LINQ | `Enumerable` (returns typed, no query layer) | Element types flow; there is no type-level query algebra. |

## Nominal-first vs inference-first

In Java and C# a value's type is whatever its declaration says.
`var` exists, but it is *local* inference — the compiler fills
in a type you could have written, and it never crosses a method
boundary. Field types, parameter types, and return types are
always authored.

Rigor turns this around. It infers across the whole method body
and *through* in-source `def` boundaries — a method with no
`.rbs` still binds its callers to the return type inferred from
its body:

```ruby
def classify(n)
  return :zero     if n.zero?
  return :positive if n.positive?
  :negative
end

result = classify(7)
assert_type("Constant<:zero> | Constant<:positive> | Constant<:negative>", result)
```

The C# equivalent demands the parameter type and the return
type as authored annotations, and even with both, `switch`
returns `string`, not the three-way literal union — C# has no
literal types to carry it:

```csharp
string Classify(int n) =>
    n == 0  ? "zero"
  : n > 0   ? "positive"
  :           "negative";
// result : string
```

When you DO need to write a sig — at a public boundary, when a
body is too dynamic, when you want to *enforce* a parameter
shape rather than observe it — it goes into `sig/<file>.rbs`,
never into the `.rb` source. That separation is deliberate (see
[ADR-1](../adr/1-types.md) and [ADR-5](../adr/5-robustness-principle.md));
it is the analogue of keeping declarations out of your method
bodies, except Rigor keeps them out of the *file*.

## Narrowing — `instanceof`, `is`, pattern `switch`

Both languages have flow-sensitive narrowing, and modern Java /
C# added pattern binding (`instanceof String s`, `is string s`).
Rigor has direct analogues; the vocabulary differs, the
behaviour matches.

| Java | C# | Rigor |
| --- | --- | --- |
| `if (x != null)` | `if (x is not null)` | `if x` (strips `false` / `nil`) or `unless x.nil?` |
| `x instanceof String` | `x is string` | `x.is_a?(String)` |
| `x instanceof String s` (binding) | `x is string s` (binding) | `case x; in String => s` |
| `switch (x) { case Foo f -> … }` | `switch (x) { case Foo f => … }` | `case x; in Foo => f` |
| `(Foo) x` (cast) | `(Foo)x` (cast) | (no in-source cast) — `is_a?` guard, or `T.cast` via [`rigor-sorbet`](../../plugins/rigor-sorbet/) |
| `Objects.requireNonNull(x)` | `x!` (null-forgiving) | (no in-source assertion) — `unless x.nil?`, or `T.must` via `rigor-sorbet` |
| user method returning `boolean` | user method returning `bool` | `%a{rigor:v1:predicate-if-true: x is Foo}` directive on the predicate |

The reflex to drop is the **cast**. In Java/C# you reach for
`(Foo) x` or C#'s null-forgiving `x!` whenever the compiler
disagrees with you. Rigor has no in-source cast. The
equivalents are:

1. **Add a guard.** `unless x.nil?; x.upcase; end` is the
   idiomatic move — and unlike `x!`, it is checked, not asserted.
2. **Tighten an `.rbs`.** Often the underlying issue is a
   library sig that is too loose.
3. **Use the `rigor-sorbet` plugin.** Adopt `T.let` / `T.cast`
   / `T.must` if you want in-source assertions; see
   [Chapter 10](10-sorbet.md).

## Records ↔ `Data.define`

A Java `record` or a C# positional `record` maps almost exactly
onto Ruby's `Data.define` — an immutable, value-equal, member-
shaped aggregate. Rigor models it natively
([ADR-48](../adr/48-data-struct-value-folding.md)).

```java
// Java 21
record Point(int x, int y) {}
var p = new Point(1, 2);
int a = p.x();          // a : int
Point q = p.withX(...); // (no built-in wither; you write it)
```

```csharp
// modern C#
record Point(int X, int Y);
var p = new Point(1, 2);
int a = p.X;            // a : int
var q = p with { X = 9 };  // non-destructive mutation
```

```ruby
Point = Data.define(:x, :y)
p = Point.new(1, 2)
assert_type("Constant<1>", p.x)   # member value is folded, not just Integer
q = p.with(x: 9)                  # Data#with ↔ C#'s `with` expression
```

Two things go further than either language:

- **Member values fold.** `Point.new(1, 2).x` is
  `Constant<1>`, not merely `Integer`. Java and C# erase the
  literal at construction; Rigor keeps it (subject to the usual
  folding budget).
- **`with` is first-class.** Ruby's `Data#with` is the direct
  analogue of C#'s `with` expression, and Rigor types the
  result with the overridden member folded in. (Java has no
  built-in wither.)

`Struct` — Ruby's *mutable* sibling — is deliberately not folded
the same way yet; its mutability breaks the value-folding
soundness story. See [Chapter 6](06-classes.md).

## Nullability

This is the one axis where Java and C# diverge enough to matter,
and where C# lands closer to Rigor than Java does.

**C#** (nullable reference types, C# 8+): `string?` is a *type
modifier*. The compiler tracks nullability flow-sensitively and
warns on a possible-null dereference. This is almost exactly
Rigor's model — `T?` is `T | nil`, and the narrowing is the
same:

```csharp
int Length(string? s) {
    if (s is null) return 0;
    return s.Length;   // s : string — null stripped by the flow
}
```

```ruby
def length(s)            # s : String?  (RBS-declared)
  return 0 if s.nil?
  s.length               # s : String — nil stripped by .nil?
end
```

**Java**: there is no nullable *type*. You either reach for
`Optional<T>` (a container you must `.map` / `.orElse` through)
or an annotation like `@Nullable` that the compiler does not
enforce. Rigor's `T?` is closer to C#'s `string?` than to Java's
`Optional<T>` — it is a union the flow narrows, not a wrapper you
unwrap. If you are porting Java `Optional<T>`-returning code, the
idiomatic Ruby is a plain `T?` return plus a `nil?` guard at the
call site, not a wrapper object.

One difference from C#: Rigor's nullability is **always on** and
**never forces** you. C#'s NRT warnings can be silenced with
`!`; Rigor simply will not fire `possible-nil` unless it can
prove the receiver is `nil` on some path — there is no nullable-
context to enable and no forgiving operator to reach for.

## Generics and variance

RBS generics are what Rigor reads, and they are more
conservative than either language's. RBS supports class-level
and method-level type parameters with bounds, but does not
infer call-site instantiation as eagerly as C#'s or Java's
target-typing.

| Java | C# | Rigor (via RBS) |
| --- | --- | --- |
| `<T> T id(T x)` | `T Id<T>(T x)` | `def id: [T] (T) -> T` |
| `List<T>` | `List<T>` | `Array[T]` |
| `Map<K, V>` | `Dictionary<K, V>` | `Hash[K, V]` |
| `List<? extends Animal>` (use-site) | `IEnumerable<out Animal>` (declaration-site) | covariant `[out T]` parameter |
| `Consumer<? super Cat>` (use-site) | `IComparer<in Cat>` (declaration-site) | contravariant `[in T]` parameter |
| bounded `<T extends Comparable<T>>` | `where T : IComparable<T>` | `[T < Comparable[T]]` bound |

The variance story is the notable gap. C# pins variance at the
*declaration* (`in` / `out` on the interface), Java pins it at
the *use* (wildcards on each reference). RBS uses declaration-
site variance markers like C#, but the surface is narrower and
Rigor leans on its structural facets and refinements for cases
where you would reach for a wildcard in Java.

## Sealed types and exhaustiveness

Java's `sealed interface … permits` and C#'s sealed hierarchies
let the compiler prove a `switch` is exhaustive — and *error* if
it is not. Rigor approaches the same shape from the other side.

A closed set of subtypes is a union in Rigor, and the flow
engine tracks which `case`/`when` and `case`/`in` clauses can
still match. [ADR-47](../adr/47-narrowing-driven-clause-reachability.md)'s
`flow.unreachable-clause` rule fires when a clause is provably
dead — its subject has already been narrowed to `Bot` by the
prior clauses (per-clause disjointness) or by prior exhaustion:

```ruby
case shape
in Circle    then shape.radius
in Rectangle then shape.width * shape.height
in Circle    then "…"   # flow.unreachable-clause — Circle already covered
end
```

The crucial difference in *direction*: Java and C# **require**
exhaustiveness and reject a `switch` that misses a case. Rigor
does the dual — it reports clauses that can never run, but it
does **not** force you to handle every variant. A non-exhaustive
`case` is not an error in Rigor; an *unreachable* clause is a
diagnostic. This follows Rigor's no-false-positives stance: a
`case` that omits a branch may be intentional (the omitted
variant cannot reach this point), and Rigor will not frighten
working code over it.

## Refinement carriers — the part neither language has

Neither Java nor C# can say "string of length ≥ 1" or "integer
in 1..9" at the type level. You reach for a constructor that
throws, a value object, or a runtime check. Rigor has first-
class refinement carriers, produced automatically by narrowing.

| Rigor refinement | Java / C# closest | Comment |
| --- | --- | --- |
| `non-empty-string` | a `NonEmptyString` value class wrapping validation | Rigor produces it from `unless s.empty?`, no wrapper type. |
| `positive-int` | a `PositiveInt` value object, or a runtime guard | Rigor narrows from `n > 0`. |
| `int<1, 9>` | an `enum` of nine constants, or a range check | Rigor's range carrier handles arbitrary bounds without enumerating them. |
| `numeric-string` | `string` + `int.TryParse` discipline | No type-level analogue in either language. |
| `non-empty-array[T]` | a non-empty-collection value class | Rigor produces it from `unless arr.empty?`. |

If you have ever written a `PositiveInt` value class purely to
encode an invariant the type system could not, this is the part
of Rigor that earns its keep — the invariant rides on the
ordinary `Integer`, no wrapper allocation, narrowed from a plain
`if`.

## Severity, suppression, and "strict mode"

| Java / C# | Rigor |
| --- | --- |
| `-Xlint` / `<TreatWarningsAsErrors>` / analyzer severity | `severity_profile: lenient` / `balanced` / `strict` |
| C# `<Nullable>enable</Nullable>` | Always-on nil-narrowing in Rigor (no context to enable) |
| `@SuppressWarnings("…")` / `#pragma warning disable` | `# rigor:disable <rule>` |
| file-level `#pragma warning disable` at top | `# rigor:disable-file all` |
| `javac` / `dotnet build` (the gate) | `rigor check lib` (the advisor) |

The mental shift: in Java/C# the type checker is part of the
build — code does not ship until it passes. `rigor check` is not
a build step the program must pass; it is a diagnostic gate you
tune with severity profiles and adopt incrementally via
baselines. The program already runs.

## Where Java and C# differ

For most of this page Java and C# move together. The places they
do not, and which way each leans relative to Rigor:

- **Nullability** (covered above): C#'s `string?` is close to
  Rigor's `T?`; Java's `Optional<T>` is a container, further
  away.
- **Variance**: C# is declaration-site (`in` / `out`), like RBS;
  Java is use-site (wildcards). RBS readers from C# will find
  the variance markers familiar.
- **`dynamic`**: C# has a genuine `dynamic` type — the direct
  analogue of `Dynamic[Top]`. Java's nearest equivalent is an
  `Object` reference plus reflection, with no "silence the
  checker" semantics.
- **Value types**: C#'s `struct` / `record struct` carry value
  semantics that Rigor does not model (Ruby has no value-vs-
  reference distinction at this layer). Java has no user value
  types at the modern LTS (Project Valhalla is not yet GA).
- **Checked exceptions**: Java's `throws` clause is a typed
  effect Rigor has no analogue for; C# (like Rigor) does not
  track exceptions in the type system.

## What Java / C# have and Rigor does not

Be honest about what you give up:

- **Enforced exhaustiveness.** A sealed `switch` that misses a
  variant is a compile error in Java/C#. Rigor reports
  *unreachable* clauses, not *missing* ones — by design (see
  above).
- **Compiler-enforced nullability.** C#'s NRT *warns* you into
  handling null. Rigor narrows nil but never forces a guard it
  cannot prove is needed.
- **Checked exceptions.** Java's `throws` has no Rigor analogue.
- **Value-type semantics.** C#'s `struct` / `record struct`
  value model is outside Rigor's surface.
- **Type-level computation.** Neither Java nor C# is as
  type-level-expressive as, say, TypeScript, but both have more
  generic machinery (higher-kinded-ish patterns, complex bounds)
  than RBS exposes. Rigor's generics are deliberately modest so
  the analyzer stays fast on real Ruby.
- **IDE completeness.** Decades of IntelliJ / Visual Studio
  investment back Java and C#. Rigor ships diagnostics and
  `rigor type-of` today; LSP-based editor integration is on the
  roadmap.

## What Rigor has and Java / C# do not

The other direction — and for these two languages the list is
longer than you might expect, because neither has literal types:

- **Literal / constant types.** `Constant<42>`, `Constant<:zero>`,
  `Constant<"FOO">`. Java and C# have *no* literal types — the
  closest is an `enum`, and that only covers a hand-declared
  set. Rigor infers them from ordinary values.
- **Constant folding through method calls.** `"foo".upcase` is
  `Constant<"FOO">`, not `String`. Rigor catalogues which
  built-in methods are pure and folds through them.
- **First-class refinements.** `non-empty-string`, `positive-int`,
  `int<1, 9>`, `numeric-string` — invariants on ordinary types,
  no value-class wrapper.
- **Structural facets without a declaration.** A Ruby object that
  has the right methods satisfies an RBS `interface` (a
  *structural* interface — Go's `interface`, not Java's nominal
  `implements`). You do not declare conformance; Rigor infers
  the shape. See the
  [structural-typing appendix](appendix-protocols-and-structural-typing.md).
- **No-false-positives stance.** Rigor stays silent on
  `Dynamic[Top]` receivers rather than complaining. You will
  never see a Rigor diagnostic whose honest answer is "well,
  technically the checker cannot know."
- **No annotation tax.** `rigor check` on a Ruby project with
  zero `.rbs` files still yields useful diagnostics from
  inference. Java and C# infer only `var` locals; everything
  else you author. Adding `.rbs` to Rigor is incremental — every
  file you skip is `Dynamic[Top]` at the boundary, not an error.

## A migration vignette

You are porting a C# domain model — a sealed-ish shape
hierarchy with a `switch` over it — to Ruby. The original:

```csharp
abstract record Shape;
record Circle(double Radius)          : Shape;
record Rectangle(double W, double H)  : Shape;

double Area(Shape s) => s switch {
    Circle c    => Math.PI * c.Radius * c.Radius,
    Rectangle r => r.W * r.H,
    _           => throw new ArgumentException(),
};
```

The Rigor approach — `Data.define` for the records, `case`/`in`
for the dispatch, and no annotations:

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
```

What carries over and what changes:

- The records become `Data.define` — immutable, value-equal,
  member-shaped, and Rigor folds their member reads (see
  [Records ↔ Data.define](#records--datadefine)).
- The `switch` patterns become `case`/`in`; `in Circle` narrows
  `s` to `Circle` along that clause exactly as C#'s `case Circle
  c` does.
- The `_ => throw` arm is gone. C# needs it to satisfy
  exhaustiveness; Rigor does not demand it. If a third variant
  appears later and reaches `area`, the result is a `nil` return
  on the unmatched path — and if you add an `in OtherShape`
  clause that can never match, `flow.unreachable-clause` tells
  you. Rigor reports the *dead* clause, never the *missing* one.

If you want the missing-arm safety back, that is a deliberate
opt-in, not a default: a trailing `else raise` makes the
omission explicit and Rigor types the body accordingly.

## What's next

You probably do not need to read the rest of the handbook
sequentially. Useful pointers:

- [Chapter 3 — Narrowing](03-narrowing.md) for the flow rules —
  the direct analogue to `instanceof` / `is` pattern narrowing.
- [Chapter 6 — Classes](06-classes.md) for `Data.define`,
  instance-side vs class-side, and `attr_accessor`.
- [Chapter 7 — RBS and `RBS::Extended`](07-rbs-and-extended.md)
  for the directive grammar — `predicate-if-true` is the
  user-defined type-guard analogue.

If you want to compare against another tool, the sibling
appendix pages cover [TypeScript](appendix-typescript.md),
[PHPStan](appendix-phpstan.md), [mypy](appendix-mypy.md),
[Steep](appendix-steep.md), [TypeProf](appendix-typeprof.md),
[Rust](appendix-rust.md), [Go](appendix-go.md), and
[Elixir](appendix-elixir.md).
