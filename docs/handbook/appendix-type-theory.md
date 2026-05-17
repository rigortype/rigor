# Appendix — Connections to Type Theory

A short bridge between Rigor's vocabulary and the formal
type-theoretic concepts you may have seen in a programming-languages
textbook or in another type checker's documentation. The handbook
proper is deliberately short on theory; this appendix names the
underlying ideas so that if you already know one of them, you can
recognise the corresponding Rigor surface immediately.

This page is descriptive, not normative. When the formal language
here disagrees with the [type
specification](../type-specification/README.md), the spec binds.

## Five-second pitch

| Question | Type-theory term | Rigor surface |
| --- | --- | --- |
| What is the universe of types ordered by? | Subtyping (`<:`), a partial order forming a lattice | The carrier zoo with `Top` / `Bot`, `\|` (join), `&` (meet) |
| What about types that may or may not match? | Gradual consistency (`~`) | The `Dynamic[T]` carrier and the trinary certainty `yes / no / maybe` |
| How are user types identified? | Nominal vs structural | **Nominal-first hybrid** — classes by name, plus structural facets (`interface`, `HashShape`, capability roles) |
| How are generics expressed? | Parametric polymorphism (System F-style, but predicative) | RBS generics `class Array[Elem]`, method generics `def map: [U] () { (Elem) -> U } -> Array[U]` |
| How is "x is a non-empty string" expressed? | Refinement / predicate subtyping | First-class refinement carriers (`non-empty-string`, `int<min, max>`, …) |
| How does `if x.is_a?(String)` change `x`'s type? | Occurrence typing / flow-sensitive narrowing | Edge-aware narrowing with trinary certainty |
| What about side effects? | Effect systems | The engine's effect model (mutation, exception, escape) — internal, not user-visible |
| Soundness or completeness? | Pick one (or neither) | **Neither in full** — Rigor optimises for no-false-positives, with a robustness-principle bias |

Rigor's design pulls liberally from this catalogue but avoids the
parts that would force a Ruby author to write annotations they did
not author themselves.

## The type lattice

Rigor's types form a (bounded) lattice under the subtyping
relation `<:`. The standard textbook picture applies almost
verbatim:

- **`Top`** is the greatest element — every value has type `Top`.
- **`Bot`** is the least element — no value has type `Bot`. Useful
  for unreachable branches and "this method always raises."
- **Join `T \| U`** (union) is the least upper bound.
- **Meet `T & U`** (intersection) is the greatest lower bound.

```ruby
# Top — every value inhabits it
x = something_we_know_nothing_about
assert_type(x, "Dynamic[Top]")  # Top widened with the Dynamic marker

# Bot — no value inhabits it; raised-only methods return Bot
def boom!
  raise "no"
end
assert_type(method(:boom!).call, "Bot")  # never reached

# Join — Union of two non-overlapping types
n = rand < 0.5 ? 1 : "a"
assert_type(n, "Constant<1> | Constant<\"a\">")

# Meet — Intersection (rarely needed at the surface level)
# Mostly arises during refinement combinations
```

Spec: [`docs/type-specification/value-lattice.md`](../type-specification/value-lattice.md),
[`docs/type-specification/special-types.md`](../type-specification/special-types.md).

## Subtyping and gradual consistency

Static type theory uses one relation: **subtyping (`<:`)**.
`Integer <: Numeric` means every `Integer` is a `Numeric`.

Gradual typing adds a second relation: **consistency (`~`)**.
`Dynamic[T] ~ U` means "I do not statically know whether the
runtime value will satisfy `U`, but it is permitted to."
Consistency is reflexive and symmetric but **not transitive** —
this is the key technical move that distinguishes gradual typing
from "just add an `Any` type to the lattice."

Rigor exposes both relations through a **trinary certainty**:

| Certainty | Reads as | Use site |
| --- | --- | --- |
| `yes` | `T <: U` provably holds | The call is safe; no diagnostic. |
| `no` | `T <: U` provably fails | A diagnostic fires. |
| `maybe` | Cannot prove either way | No diagnostic — Rigor stays silent (robustness principle). |

```ruby
# yes: provably Integer <: Numeric
def add_one(n) = n + 1
add_one(42)  # certainty: yes

# no: Constant<"a"> <: Integer is provably false
add_one("a")  # certainty: no — call.argument-type-mismatch fires

# maybe: Dynamic[Top] ~ Integer holds; <: cannot be decided
add_one(JSON.parse(input))  # certainty: maybe — silent
```

Spec: [`docs/type-specification/relations-and-certainty.md`](../type-specification/relations-and-certainty.md).

## Nominal vs structural typing

Java is nominal: `class Foo {}` and `class Bar {}` with identical
member sets are distinct types. TypeScript is structural: two
type aliases with identical members are interchangeable.

Rigor is **nominal-first with structural facets**:

1. **Nominal** is the default. `Nominal[User]` and
   `Nominal[Admin]` are distinct even with identical methods.
2. **Structural via `interface`**. RBS `interface _Comparable`
   defines a shape — anything implementing the named methods
   satisfies it, regardless of class.
3. **Structural via `HashShape` and `Tuple`**. Ruby literals
   `{name: "x", age: 30}` and `[1, "a"]` get per-key / per-index
   structural types automatically.
4. **Capability roles** are a Rigor-specific structural facet —
   named structural interfaces with hidden carriers
   (`_ReadableStream`, `_RewindableStream`, …). These let the
   robustness principle widen user-method parameter types to "any
   value that supports the capability we actually use" without
   forcing the user to write the `interface`.

```ruby
# Nominal — User and Admin are distinct
class User; end
class Admin; end
u = User.new
def takes_user(u) end
takes_user(Admin.new)  # call.argument-type-mismatch

# Structural via HashShape — literals get per-key types
person = {name: "Alice", age: 30}
assert_type(person, "HashShape{name: Constant<\"Alice\">, age: Constant<30>}")

# Structural via interface
def shout(thing)
  thing.upcase
end
# Rigor infers the parameter as "anything with #upcase: () -> String"
```

Spec:
[`docs/type-specification/structural-interfaces-and-object-shapes.md`](../type-specification/structural-interfaces-and-object-shapes.md).

## Polymorphism

The Cardelli/Wegner taxonomy of polymorphism maps cleanly onto Rigor:

| Polymorphism family | Rigor surface | Notes |
| --- | --- | --- |
| **Parametric** (System F-style, predicative) | RBS generics `class Foo[T]`, method generics `def m: [U] (U) -> U` | No higher-rank or higher-kinded quantification at the user surface. |
| **Subtype** | `<:` over the lattice | Standard; method calls dispatch by inferred receiver type. |
| **Ad-hoc** (overloading) | RBS method overloads (`def m: (Integer) -> Integer \| (String) -> String`) | Resolution picks the most specific arm. |
| **Coercion** | Rigor's Ruby-coercion model (`Integer#coerce`, etc.) | Inferred per the runtime semantics; not a user-visible operator. |
| **Row polymorphism** | (not exposed at the user surface) | `HashShape` carries closed-vs-open key sets internally; not a quantifiable axis. |

```ruby
# Parametric — method generics in RBS
# sig:  def first: [E] (Array[E]) -> E?
def first(arr) = arr[0]

# Subtype — Integer <: Numeric flows through method calls
def total(ns) = ns.sum
total([1, 2, 3])      # ns: Array[Integer]
total([1, 2.0, 3])    # ns: Array[Numeric]

# Ad-hoc — RBS overload picks per call site
"abc" * 3   # String overload
[1, 2] * 3  # Array overload
```

Spec: [`docs/type-specification/rbs-compatible-types.md`](../type-specification/rbs-compatible-types.md).

## Variance

RBS (and therefore Rigor) inherits the standard variance
vocabulary for generic parameters:

- **Covariant (`out T`)** — `Foo[Sub] <: Foo[Sup]` when
  `Sub <: Sup`. Producer position.
- **Contravariant (`in T`)** — `Foo[Sup] <: Foo[Sub]` when
  `Sub <: Sup`. Consumer position.
- **Invariant (default)** — neither.

Ruby's mutable containers (`Array`, `Hash`, `Set`) are invariant
in their element type for soundness — the standard Java-arrays-
are-covariant cautionary tale applies. RBS declares them as such;
Rigor honours those declarations.

## Refinement types and predicate subtyping

A **refinement type** restricts a base type by a predicate: in
Liquid Types / SMT-driven systems this is written as
`{x: Int | x > 0}`. Rigor exposes a curated catalogue of
refinements with reserved names:

| Refinement | Predicate (informally) | Carrier |
| --- | --- | --- |
| `non-empty-string` | `s : String, s.size >= 1` | refinement on `String` |
| `numeric-string` | `s : String, s =~ /\A[+-]?\d+(\.\d+)?\z/` | refinement on `String` |
| `literal-string` | "provably built from literals" | refinement on `String` |
| `int<min, max>` | `n : Integer, min <= n <= max` | range carrier |
| `non-zero-int` | `n : Integer, n != 0` | refinement on `Integer` |
| `positive-int` | `n : Integer, n > 0` | refinement on `Integer` |
| `non-empty-array[T]` | `arr : Array[T], arr.size >= 1` | refinement on `Array[T]` |
| `non-empty-hash[K, V]` | `h : Hash[K, V], h.size >= 1` | refinement on `Hash[K, V]` |

The refinements compose with subtyping the way you would expect:
`positive-int <: non-zero-int <: Integer <: Numeric`. Crucially,
**Rigor narrows into refinement carriers automatically** when the
control-flow analysis proves the predicate:

```ruby
def length_of(s)
  return 0 if s.empty?
  s.size  # at this program point: s : non-empty-string
end
```

This is the practical payoff of refinement subtyping without
asking the user to author the refinement.

Spec: [`docs/type-specification/imported-built-in-types.md`](../type-specification/imported-built-in-types.md),
[`docs/type-specification/rigor-extensions.md`](../type-specification/rigor-extensions.md).

## Occurrence typing (flow-sensitive narrowing)

The technical term for "`if x.is_a?(String)` makes `x : String`
inside the branch" is **occurrence typing** (Tobin-Hochstadt &
Felleisen, 2008). TypeScript calls it *narrowing*; mypy calls it
*type guards*. The underlying mechanism is the same: the type
checker walks the control-flow graph and refines each variable
along the edges where a predicate must have held.

Rigor implements occurrence typing as **edge-aware narrowing** with
a few extensions specific to Ruby:

- Standard predicates: `is_a?`, `kind_of?`, `instance_of?`,
  `respond_to?`, `nil?`, `==`, `===`, `frozen?`, `empty?`,
  comparison operators.
- Pattern matching: `case x; in pattern` narrows along the
  matched branch.
- Equality semantics are split into structural and reference
  equality where Ruby distinguishes them.
- Mutation effects on a narrowed variable invalidate the
  narrowing at the next read — *fact stability*.
- User-extended predicates via the `predicate-if-true` /
  `predicate-if-false` directives (the analogue of TypeScript's
  `x is Foo` type guards).

```ruby
def describe(x)
  if x.is_a?(String)
    # x : String here
    x.upcase
  elsif x.nil?
    "(nil)"
  else
    # x : Top - String - nil here  (everything else narrowed out)
    x.inspect
  end
end
```

Spec: [`docs/type-specification/control-flow-analysis.md`](../type-specification/control-flow-analysis.md),
[`docs/type-specification/rbs-extended.md`](../type-specification/rbs-extended.md).

## Gradual typing

Gradual typing (Siek & Taha, 2006; Garcia, Clark & Tanter, 2016)
is the discipline of letting statically-typed and
dynamically-typed code coexist in one program. The technical
machinery is:

1. A distinguished "dynamic" type (`?` in the original paper).
2. A *consistency* relation `~` that admits the dynamic type
   anywhere a concrete type is expected (and vice versa) but
   refuses to bridge two unrelated concrete types.
3. Optional run-time casts at the static/dynamic boundary.

Rigor maps onto this as:

| Gradual concept | Rigor surface |
| --- | --- |
| Dynamic type `?` | **`Dynamic[T]`** — a carrier that *wraps* a "best-guess" type `T` while marking the value as not-statically-verified. `Dynamic[Top]` is the maximally-dynamic form. |
| Consistency `~` | The `maybe` arm of the trinary certainty — `Dynamic[T] ~ U` holds whenever `T ~ U` does. |
| Static/dynamic boundary | Per-method, per-file, per-plugin contribution — Rigor records *why* a value became `Dynamic[T]` in its dynamic-origin algebra. |
| Casts | No in-source cast operator. The opt-in [`rigor-sorbet`](../../examples/rigor-sorbet/) plugin reads `T.let` / `T.cast` / `T.must` as cast forms; `RBS::Extended` `assert_type` directives serve the same role from `.rbs`. |

Two Rigor-specific extensions matter:

1. **`Dynamic[T]` is parameterised.** The original gradual-typing
   paper has a single `?`; Rigor carries the "what we would
   *guess* the type is if asked to commit" alongside the
   uncertainty marker, so refactoring tools can offer better
   suggestions.
2. **The robustness principle (Postel's law for types)** —
   parameters are accepted leniently (closer to `Dynamic[T]`),
   returns are reported strictly. See
   [ADR-5](../adr/5-robustness-principle.md).

Spec: [`docs/type-specification/special-types.md`](../type-specification/special-types.md),
[`docs/type-specification/value-lattice.md`](../type-specification/value-lattice.md).

## Effect systems

A textbook **effect system** annotates each expression with two
things: a type *and* a set of effects (Lucassen & Gifford, 1988).
Effects include I/O, mutation, exceptions, divergence, allocation.

Rigor has an effect model but it lives **inside the engine**, not
at the user surface:

| Engine-internal effect | What it tracks | User-visible consequence |
| --- | --- | --- |
| Mutation | `arr << x`, `h[k] = v`, ivar writes | Narrowed types lose fact stability after mutating reads. |
| Exception / non-local exit | `raise`, `throw`, `return`, `break` | The branch contributes nothing to the join; methods that always raise return `Bot`. |
| Closure escape | A block stored or yielded outside its lexical scope | Narrowings inside the block are not exported to the outer scope. |

These effects are not part of an authored signature. They are
inferred from the AST walk and consulted by the narrowing logic.
Future plugin / annotation extensions to surface effects at the
user level are tracked in the spec corpus but not part of v0.1.x.

Spec: [`docs/type-specification/control-flow-analysis.md`](../type-specification/control-flow-analysis.md)
("Mutation effects" subsection).

## Soundness, completeness, and the no-false-positives stance

A static type system is:

- **Sound** when every program it accepts is free of the runtime
  errors the type system is supposed to catch ("no false
  negatives at runtime").
- **Complete** when every program free of those runtime errors is
  accepted by the type system ("no false positives at
  type-check time").

Rice's theorem implies you cannot have both in full generality.
Mainstream static type systems choose **sound but incomplete**
(Java, Haskell, Rust modulo unsafe). Rigor takes the opposite
default:

> Rigor only fires a diagnostic when it can **prove** the
> unsoundness. Cases it cannot decide are silent.

This is a deliberate design choice grounded in the project's
audience: Ruby programmers who would otherwise not run a type
checker at all. A noisy false-positive on the first day kills
adoption faster than a missed bug on day 30. The robustness
principle ([ADR-5](../adr/5-robustness-principle.md)) is the
formal expression of this stance: lenient on parameters
("anyone could call this with anything"), strict on returns
("we will commit to what we actually return").

The trade-offs to be aware of:

- **Rigor will miss bugs that a sound checker would catch.**
  This is by design; the alternative is more friction than the
  bug it would catch.
- **The trinary certainty (`yes` / `no` / `maybe`)** is the
  formal acknowledgement of incompleteness. Most checkers
  collapse to binary; Rigor preserves the third arm because
  it's the arm that earns silence.
- **`Dynamic[T]` is not a failure mode** in Rigor's model. It is
  a first-class carrier with full algebraic identity.

## What Rigor does NOT model

For completeness, a short list of type-theoretic features Rigor
*does not* currently expose at the user surface — naming them
here so you can stop looking:

- **Higher-kinded types (HKT).** `Functor[F[_]]` style
  abstraction. Tracked as a "future direction" but not in any
  shipped slice.
- **Higher-rank polymorphism (System F⊤).** All RBS generics
  are predicative; type variables cannot quantify over
  polymorphic types.
- **Full dependent types.** No `Vec[n, T]` with `n : Integer`.
  Integer-range refinements (`int<min, max>`) cover the most
  common practical need.
- **Row polymorphism as a user-quantifiable axis.** `HashShape`
  carries open-vs-closed semantics internally but does not
  expose row variables.
- **Existential types.** No `pack` / `unpack`. Closest analogue
  is structural `interface`.
- **GADTs.** No type-refinement-by-constructor; pattern
  matching narrows via the standard occurrence-typing path, not
  via type-index propagation.
- **Linear / affine types.** No move-checking or use-once
  enforcement.
- **Session types, capabilities-as-types.** Out of scope.
- **Mechanised soundness proof.** Deliberately deferred; see the
  [Matsumoto & Minamide 2010 review](../notes/20260518-matsumoto-2010-cfa-rigor-review.md)
  for the upstream "prove soundness on a tiny core" approach
  Rigor has not yet adopted.

If a topic on this list later becomes important to the user
base, it will be discussed in an ADR before any implementation
slice. Until then, the absence is a feature.

## A short reading list

Papers and books behind the choices above, in roughly the order
they map to the sections of this appendix:

- B.C. Pierce. *Types and Programming Languages.* MIT Press,
  2002. Standard reference for everything in the first half of
  this appendix.
- Cardelli & Wegner. "On Understanding Types, Data
  Abstraction, and Polymorphism." *ACM Computing Surveys*,
  1985. Origin of the polymorphism taxonomy.
- Siek & Taha. "Gradual Typing for Functional Languages."
  *Scheme Workshop*, 2006. The original gradual-typing paper.
- Garcia, Clark & Tanter. "Abstracting Gradual Typing."
  *POPL 2016.* The modern reformulation of gradual typing in
  terms of abstract interpretation.
- Tobin-Hochstadt & Felleisen. "The Design and Implementation
  of Typed Scheme." *POPL 2008.* Origin of occurrence typing.
- Rondon, Kawaguchi & Jhala. "Liquid Types." *PLDI 2008.* The
  refinement-types-with-SMT framework that informs the
  `int<min, max>` carrier (Rigor uses a much weaker, decidable
  fragment).
- Lucassen & Gifford. "Polymorphic Effect Systems."
  *POPL 1988.* Origin of effect systems.
- Matsumoto & Minamide. "Rubyプログラムの制御フロー解析と
  その健全性の証明." *IPSJ TPRO Vol.3 No.2*, 2010. The
  upstream Ruby-CFA soundness proof; Rigor-perspective review
  at
  [`docs/notes/20260518-matsumoto-2010-cfa-rigor-review.md`](../notes/20260518-matsumoto-2010-cfa-rigor-review.md).
- Matsumoto & Minamide. "多相レコード型に基づくRubyプログラム
  の型推論." *IPSJ TPRO Vol.49 No.SIG 3*, 2008. The
  Garrigue-kinded polymorphic-record experiment that
  retroactively justifies Rigor's nominal-first carrier choice;
  Rigor-perspective review at
  [`docs/notes/20260518-matsumoto-2008-poly-records-rigor-review.md`](../notes/20260518-matsumoto-2008-poly-records-rigor-review.md).

## What's next

If you came in from a "show me where Rigor stands in the type-
theory landscape" question, the rest of the handbook is the
practical companion:

- [Chapter 2 — Everyday types](02-everyday-types.md) for the
  carrier zoo at the surface level.
- [Chapter 3 — Narrowing](03-narrowing.md) for occurrence typing
  in practice.
- [Chapter 7 — RBS and `RBS::Extended`](07-rbs-and-extended.md)
  for the directive grammar that lets you teach Rigor about a
  custom predicate.
- [Chapter 8 — Understanding errors](08-understanding-errors.md)
  for the rule catalogue (the user-visible end of the trinary
  certainty).

If you want to compare against another *tool* rather than the
*theory*, the sibling appendices cover
[TypeScript](appendix-typescript.md),
[PHPStan](appendix-phpstan.md),
[mypy / Pyright](appendix-mypy.md),
and [Steep](appendix-steep.md).
