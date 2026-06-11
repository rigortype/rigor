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

> **In this appendix**
> [Five-second pitch](#five-second-pitch) ·
> [The type lattice](#the-type-lattice) ·
> [Set-theoretic foundations](#set-theoretic-foundations-of-the-lattice) ·
> [Subtyping and gradual consistency](#subtyping-and-gradual-consistency) ·
> [Nominal vs structural](#nominal-vs-structural-typing) ·
> [Polymorphism](#polymorphism) ·
> [F-bounded polymorphism and self types](#f-bounded-polymorphism-and-self-types) ·
> [Object shapes / row polymorphism](#object-shapes--row-polymorphism-hack-and-hashshapes-lineage) ·
> [Variance](#variance) ·
> [Refinement types and predicate subtyping](#refinement-types-and-predicate-subtyping) ·
> [Occurrence typing](#occurrence-typing-flow-sensitive-narrowing) ·
> [Pattern matching and exhaustiveness](#pattern-matching-and-exhaustiveness) ·
> [Gradual typing](#gradual-typing) ·
> [Blame and trust boundaries](#blame-the-gradual-guarantee-and-trust-boundaries) ·
> [Effect systems](#effect-systems) ·
> [Soundness vs completeness](#soundness-completeness-and-the-no-false-positives-stance) ·
> [Decidability of inference](#decidability-of-inference) ·
> [Hindley–Milner and principal types](#hindleymilner-principal-types-and-rigors-inference-architecture) ·
> [Bidirectional type checking](#bidirectional-type-checking) ·
> [Beyond pure inference](#beyond-pure-inference-reach-and-precision) ·
> [The expression problem](#the-expression-problem-and-rigors-plugin-contract) ·
> [Smaller connections, in brief](#smaller-connections-in-brief) ·
> [What Rigor does NOT model](#what-rigor-does-not-model) ·
> [Reading list](#a-short-reading-list)

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
| Why do some features force annotations everywhere? | Decidability of inference — certain combinations (Rank-3+, polymorphic recursion, subtyping + intersection) are undecidable | **The trinary `maybe`** — when inference cannot decide, Rigor stays silent rather than guessing or pestering the user for an annotation |

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
assert_type("Dynamic[top]", x)  # Top widened with the Dynamic marker

# Bot — no value inhabits it; raised-only methods return Bot
def boom!
  raise "no"
end
assert_type("Dynamic[top]", method(:boom!).call)  # Method indirection; direct boom! call returns Bot

# Join — Union of two non-overlapping types
n = rand < 0.5 ? 1 : "a"
assert_type("\"a\" | 1", n)

# Meet — Intersection (rarely needed at the surface level)
# Mostly arises during refinement combinations
```

Spec: [`docs/type-specification/value-lattice.md`](../type-specification/value-lattice.md),
[`docs/type-specification/special-types.md`](../type-specification/special-types.md).

## Set-theoretic foundations of the lattice

The previous section described `Top` / `Bot` / `|` (join) / `&`
(meet) as "the standard textbook picture." The semantic
foundation that makes that picture *work* — where union and
intersection on types behave the way the user expects — is the
**set-theoretic** view of types.

In the set-theoretic view, a type `T` is interpreted as the *set
of values inhabiting it*, and the type operators correspond to
set operations:

| Type operator | Set operation |
| --- | --- |
| `T \| U` | `T ∪ U` (union of inhabitants) |
| `T & U` | `T ∩ U` (intersection of inhabitants) |
| `T - U` | `T ∖ U` (set-theoretic difference; sometimes written `T ¬ U`) |
| `Top` | the universal set |
| `Bot` | the empty set |

This is the semantics behind **semantic subtyping**: `T <: U` iff
every inhabitant of `T` is also an inhabitant of `U`. Subtyping
becomes set inclusion.

### Academic root

**Frisch, Castagna & Benzaken** developed semantic subtyping in
the early 2000s as the type-theoretic foundation of CDuce — a
language for processing XML where union, intersection, and
negation types are first-class. The framework was consolidated
in **Castagna's 2024 textbook *Programming with Union,
Intersection, and Negation Types***, the current canonical
reference for the area.

The headline result: under semantic subtyping, the lattice
operators are *exactly* the set-theoretic ones, and a decidable
subtyping algorithm exists for the resulting fragment — much
richer than HM but still tractable.

### Industrial uptake

- **TypeScript** and **Flow** use union / intersection
  arithmetic informally — the spec talks about "subtype-of-T-or-U"
  rather than committing to a semantic model, but the resulting
  behaviour matches the set-theoretic reading in most cases.
- **Elixir's set-theoretic type system** (José Valim + Giuseppe
  Castagna collaboration, 2023–) is the first major industrial
  language to *deliberately* adopt the formal framework. The
  decision to ground Elixir's typed surface in semantic subtyping
  rather than a syntactic ad-hoc subtyping relation is the most
  consequential design choice the project has made.
- **Scala 3** ships union types and intersection types as
  first-class constructs; the semantics are loosely
  set-theoretic.
- **Ceylon** (now retired) was an early industrial experiment
  with explicit union / intersection types at the surface.

### Rigor's position

Rigor's lattice **is** set-theoretic in spirit:

- `T | U`, `T & U`, `T - U` are present at the surface
  ([`docs/type-specification/type-operators.md`](../type-specification/type-operators.md)).
- Top / Bot behave as the universal / empty sets.
- The difference operator `T - U` is what lets occurrence typing
  express "in the `else` branch of `if x.is_a?(String)`, the type
  of `x` is `Top - String`" precisely, rather than as an
  approximation.

Rigor does NOT formalise its lattice as a semantic-subtyping
system in the Castagna sense. Three reasons:

1. **The trinary certainty already absorbs the hard cases.**
   Semantic subtyping's value is a decision procedure for full
   union / intersection / negation. Rigor's `maybe` arm handles
   "cannot decide" without needing the decision procedure to
   terminate.
2. **Nominal-first conflicts with pure semantic subtyping.**
   A semantic-subtyping reading would collapse two distinct
   nominal classes with identical method sets (§ "Nominal vs
   structural typing"), which Ruby authors do not want.
3. **Implementation cost.** Castagna's decision procedure is
   theoretically elegant but operationally heavy for an analyser
   that walks an AST per file under a per-file budget
   ([`inference-budgets.md`](../type-specification/inference-budgets.md)).

The takeaway: Rigor's `T | U` / `T & U` / `T - U` operators are
best read with the set-theoretic interpretation in mind, even
though Rigor's algorithms do not formally lean on it. A reader
coming from Elixir's set-theoretic types or from Castagna's
textbook will find the surface familiar; the gap is in the
formalisation depth, not the surface design.

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
assert_type("{ name: \"Alice\", age: 30 }", person)

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
| **Row polymorphism** | (not exposed at the user surface) | `HashShape` carries closed-vs-open key sets internally; not a quantifiable axis. See § "Object shapes" for the lineage. |

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

## F-bounded polymorphism and self types

A recurring concrete need in object-oriented languages: a method
that "returns an instance of the actual receiver's class." Ruby's
`Object#tap` is the canonical example — `arr.tap { |x| ... }`
returns the same `arr`, with the same type, not the widened
`Object` ancestor.

Expressing "I return *my own* class" needs a mechanism beyond
plain parametric polymorphism, because the return-type parameter
must track the *runtime* class of `self`, not just a static type
variable bound at the call site. Two related mechanisms in the
literature:

### Self types

A reserved keyword (`self`, `Self`, `this`) inside a class
declaration meaning "the type of the actual receiver." A method
declared `def m: () -> self` in class `Foo` returns `Foo` in
`Foo` but returns `Bar` in `class Bar < Foo`. RBS uses `self`
exactly this way:

```ruby
# RBS for Object#tap (excerpt)
class Object
  def tap: { (self) -> void } -> self
end
```

When called on an `Array[Integer]`, the block sees the receiver
typed as `Array[Integer]` and the call returns `Array[Integer]` —
not `Object`.

### F-bounded polymorphism

A more general mechanism — a type parameter constrained to
extend its own parameterisation: `T <: Comparable[T]`. The
classical reference is **Canning, Cook, Hill, Olthoff &
Mitchell 1989** (*F-Bounded Polymorphism for Object-Oriented
Programming*). The motivating problem is the same — "a method on
`Comparable` should return the comparing class itself, not the
abstract `Comparable` interface" — but the encoding is via a
constrained type parameter rather than a `self` keyword.

### Industrial uptake

| Language | Self-type form | F-bounded form |
| --- | --- | --- |
| Java | (none direct) | `<T extends Comparable<T>>` |
| Scala | `this: T =>` self-type | `[T <: Comparable[T]]` |
| TypeScript | `this` type in method signatures | `<T extends C<T>>` |
| Sorbet | `T.self_type`, `T.attached_class` | Limited via generic class |
| RBS | `self` keyword | `[T < Comparable[T]]` (syntactically supported, limited) |

### Rigor's position

Rigor honours the RBS `self` keyword in method signatures. The
walker substitutes the actual receiver type for `self` when
synthesising the return type — so `Array[Integer]#dup` (declared
as `def dup: () -> self`) returns `Array[Integer]`, not the
ancestor's `Object`. This is the small mechanism that quietly
removes a major source of unwanted widening in OO Ruby code:

```ruby
arr = [1, 2, 3]
copy = arr.dup
# Without self-type: copy : Object  (useless)
# With self-type:    copy : Array[Integer]  (load-bearing)
```

F-bounded polymorphism in its full generality is harder. The
inference machinery has to solve a constraint that mentions the
type variable on both sides of `<:`. Rigor's RBS surface accepts
the constrained form `[T < C[T]]` but the walker treats
unresolved F-bounded constraints conservatively (`Dynamic[Top]`
fallback when the bound cannot be solved locally). This matches
the no-false-positives stance: an over-precise F-bounded
inference would spread `T`-mention errors through the codebase,
and the practical Ruby idiom — declare `self` rather than
quantify over `T <: C[T]` — sidesteps the harder cases anyway.

The type-theoretic family extends further (G-bounded polymorphism;
parameterised self-types; ML-style first-class modules with
`with type self = ...`) but those forms are not exposed at the
Rigor surface.

## Object shapes — row polymorphism, Hack, and HashShape's lineage

The `HashShape{...}` carrier and the closely related `Tuple[...]`
appeared first in § "Nominal vs structural typing" and again in
the precision table of § "Beyond pure inference," where they turn
an otherwise-`Hash[Symbol, A | B | C]`-shaped join into something
a downstream caller can use. They sit in a family of *structural
shape* designs with both an academic root and an industrial
lineage. Tracing those threads is the easiest way to explain why
`HashShape` looks the way it does.

### The academic root: row polymorphism

**Row polymorphism** (Wand, 1987; Rémy, 1989; Cardelli & Mitchell,
1991) is the formal mechanism for typing "records that may carry
additional fields beyond the ones I named." A *row variable* `ρ`
quantifies over the trailing fields of a record type:

> `{ name: String; age: Integer | ρ }` — "any record with at
> least these two fields; ρ is the rest."

Garrigue (1990s) extended the framework with **kinds**, letting
OCaml's polymorphic-record system distinguish "the class of
records carrying `name: String`" from "the class of records
carrying `length: Int`." OCaml's open object types
(`< get_name : string; .. >`) sit on this foundation.

**Matsumoto & Minamide (2008)** applied the Garrigue-kinded
framework directly to Ruby — 多相レコード型に基づくRuby
プログラムの型推論. The paper demonstrated that Ruby's
"duck typing" surface admits a row-polymorphic reading: a method
`def shout(x); x.upcase; end` infers as roughly
`∀α, ρ. {upcase: () -> α | ρ} -> α`. The inference algorithm
works, but the inferred types — together with the kind constraints
they drag along — are dense for everyday Ruby code, where users
overwhelmingly reason in nominal classes rather than structural
rows.

The [Rigor-perspective review of the
paper](../notes/20260518-matsumoto-2008-poly-records-rigor-review.md)
records the retrospective: the experiment *worked* but it
**retroactively justified Rigor's nominal-first design** rather
than recommending row variables as the primary modeling tool.
Rigor's carrier zoo treats nominal classes as the unit of
modelling, with structural shapes as inference-precision fallbacks.

### The industrial lineage: Hack → Psalm/PHPStan

In parallel with the academic line, the practical "typed
dictionary" trajectory went a different way. Facebook's
[**Hack `shape(...)`**](https://docs.hhvm.com/hack/built-in-types/shape/)
introduced first-class shape types as part of the migration story
from dynamic PHP arrays to a typed surface:

- Per-key typing — `shape('name' => string, 'age' => int)`.
- Optional keys via `?'key' => T`.
- Closed by default; `...` opens the shape to additional keys.

**Psalm** and **PHPStan** adopted the same idea under the PHPDoc
syntax `array{name: string, age: int}`, with one important
emphasis flipped: the shape is *inferred* from the literal at the
use site rather than declared up front. TypeScript's object-type
literal `{ name: string; age: number }` is the same idea under
different syntax, with structural subtyping turned on by default.

The industrial design **deliberately avoids row variables**.
There is no `array{name: string, ...ρ}` quantified over the
trailing keys; every shape is closed (or fully open) with no
quantifiable in-between. The price is loss of full
row-polymorphic expressiveness; the benefit is tractable inference
and *readable* inferred types.

### HashShape's position

Rigor's `HashShape{...}` sits squarely in the Hack / Psalm
lineage rather than the row-polymorphic one:

| Property | Row polymorphism | Hack `shape(...)` | Psalm `array{...}` | Rigor `HashShape{...}` |
| --- | --- | --- | --- | --- |
| Per-key typing | Yes | Yes | Yes | Yes |
| Optional keys | Yes (via row constraints) | Yes (`?'k'`) | Yes (`?k:`) | Yes (open/closed flag internally) |
| Row variables quantifiable by the user | **Yes** | No | No | **No** |
| Inferred from literals | (Inference is global) | No — user-declared | Yes (per call site) | **Yes** — built-in for hash literals |
| Primary modelling vehicle for users | Yes (in ML-family languages that adopt it) | Yes (idiomatic Hack) | Sometimes (alongside classes) | **No** — nominal classes are primary; HashShape is the inference-precision fallback |

Two specific choices stand out:

1. **No row variables at the user surface.** Like Hack and Psalm,
   Rigor does not let the user write
   `HashShape{name: String, *rest}` quantified over the trailing
   keys. Internally `HashShape` carries an open/closed flag, so
   the analyser can still answer "is this set of keys finite?",
   but the type language has no `ρ`. This is the same trade Hack
   made: more readable inferred types and tractable inference, at
   the cost of full row-polymorphic expressivity.
2. **Inferred, not declared.** Where Hack expects the user to
   write `shape(...)` explicitly, Rigor produces `HashShape`
   automatically from hash literals. The common Ruby-author
   experience is "I wrote `{a: 1, b: 'x'}` and Rigor reported
   `HashShape{a: Constant<1>, b: Constant<"x">}`," not "I
   declared a shape type and Rigor checked my literal against
   it." This matches the Psalm / PHPStan emphasis more closely
   than Hack's declaration-first design.

The combination — inferred-from-literal + Hack/Psalm-shaped
surface + nominal-first ecosystem — is what makes `HashShape` a
**precision carrier** (§ "Beyond pure inference") rather than a
*modelling primitive*. It exists to sharpen the type of a hash
literal that would otherwise widen to
`Hash[Symbol, A | B | C]`. It is not the unit a Rigor user
reaches for to describe a domain object — that role belongs to
`class User; end` plus the surrounding RBS, exactly as the
Matsumoto retrospective recommends.

### `Tuple` and the same lineage

`Tuple[A, B, C]` is the array analogue, and the same lineage
applies — TypeScript's `[A, B, C]`, Hack's `tuple(A, B, C)`,
Psalm/PHPStan's `array{0: A, 1: B, 2: C}` shorthand. The
motivation is identical: a literal `[1, "a", :sym]` carries
per-index information that the `Array[Integer | String | Symbol]`
join discards.

### Why not full row polymorphism in Rigor?

The temptation — surface row variables for users who want them —
is real, and the question is open at the ADR level. The reasons
it has not landed at the user surface in v0.1.x:

- **Inference cost.** Garrigue-kinded inference is decidable but
  more expensive than Rigor's local walker; the analyser's
  per-file budget (see
  [`inference-budgets.md`](../type-specification/inference-budgets.md))
  would have to accommodate global row-constraint solving.
- **Readability.** The Matsumoto experiment found that inferred
  row-polymorphic types for everyday Ruby code are dense and hard
  to skim — a problem amplified by Rigor's no-false-positives
  stance, which makes the inferred type a thing the user actually
  reads in `rigor annotate`.
- **Empirical demand.** Hash literals in real Ruby code are
  typically per-call ad-hoc dictionaries, not polymorphic-record
  values flowing through multiple operations. The closed-or-open
  per-call structural type matches the observed use; the row
  quantification rarely earns its complexity.

If row variables ever become genuinely needed — for a typed
`merge` / `transform_keys` / `slice` story that benefits from
quantifying over rows — the question opens through an ADR rather
than at the user surface by default.

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

## Pattern matching and exhaustiveness

The previous section noted that Rigor narrows along
`case x; in pattern` branches the same way it narrows along
`if x.is_a?(...)`. There is a related but distinct property that
pattern matching enables in type systems built around **algebraic
data types** (ADTs) or **tagged unions**: **exhaustiveness
checking**.

A `case` that does not cover every value the scrutinee can take
*should*, under exhaustiveness, be a type error — not a runtime
fallthrough. The compiler verifies that for every possible shape
of the scrutinee, some arm matches.

### Academic root

**Maranget 2007** (*Warnings for Pattern Matching*) gave the
algorithm OCaml uses to compute pattern-matching warnings —
non-exhaustive matches and redundant arms. The broader topic
sits in the ML / Haskell lineage where exhaustiveness has been
load-bearing since the late 1970s.

### Industrial uptake

- **OCaml**: emits warnings for non-exhaustive matches; can be
  turned into hard errors via `-strict-formats` or per-pattern
  attributes.
- **Rust**: requires exhaustiveness on `match` against an `enum`
  type; non-exhaustive matches are *compile* errors.
- **Scala**: warns on non-exhaustive `match`; raises
  `MatchError` at runtime if unmatched.
- **TypeScript**: simulates exhaustiveness via the "exhaustive
  `never` check" idiom — assigning the scrutinee to a `never`-
  typed variable in the default branch fails to type-check if
  any case was missed.
- **Sorbet**: `T.absurd(x)` checks that every case of a union
  has been narrowed away by the point of the call.

### Ruby and Rigor's position

Ruby's `case/in` is non-exhaustive at runtime — an unmatched
scrutinee silently falls through the `case` expression (returns
`nil`), or raises `NoMatchingPatternError` if the strict
`case/in` form is used without an `else`. Rigor inherits the
language behaviour:

- Occurrence-typing narrowing through `case/in` is implemented
  and load-bearing for downstream precision.
- Exhaustiveness checking is **NOT** implemented in v0.1.x.

The choice is consistent with Rigor's no-false-positives stance.
A `pattern.non-exhaustive` diagnostic would fire on:

1. A scrutinee inferred as a union whose arms were not all
   matched — but the inferred union itself may be approximate
   (`Dynamic[T]` widening, capability-role narrowing, plugin
   contributions), so the "missing arm" cluster could be
   pathological.
2. A scrutinee whose "exhaustive set" is open-ended at runtime —
   open class hierarchies, user-defined `===`, monkey-patched
   `kind_of?`. These shapes are common in Ruby and rarely typed
   precisely enough for an exhaustiveness check to be reliable.
3. A developer deliberately relying on the fall-through return
   of `nil`. Idiomatic in some Ruby styles.

The false-positive surface is uncomfortably large for a language
without ADTs. A `pattern.non-exhaustive` diagnostic is a future
direction (no committed milestone). Users wanting exhaustiveness
*today* can replicate the TypeScript / Sorbet idiom — call a
method declared to take `Bot` in the default branch — and
Rigor's narrowing will surface the missed arm via the
`call.argument-type-mismatch` diagnostic that already exists.

```ruby
# Self-rolled exhaustiveness via the Bot-receiver idiom
def unreachable(x)
  raise "unreachable: #{x.inspect}"
end
# RBS:  def unreachable: (bot) -> bot

case shape
in :circle then ...
in :square then ...
# missing :triangle
else unreachable(shape)
  # If `shape` could still be :triangle here, the
  # `unreachable` call's argument type mismatches `bot`
  # and call.argument-type-mismatch fires.
end
```

This is not as ergonomic as a first-class
`pattern.non-exhaustive`, but it is sound under Rigor's
no-false-positives discipline and works today.

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
| Casts | No in-source cast operator. The opt-in [`rigor-sorbet`](../../plugins/rigor-sorbet/) plugin reads `T.let` / `T.cast` / `T.must` as cast forms; `RBS::Extended` `assert_type` directives serve the same role from `.rbs`. |

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

## Blame, the gradual guarantee, and trust boundaries

The previous section described `Dynamic[T]` and the consistency
relation `~` but stopped at the static side. The full
gradual-typing literature has a substantial run-time-and-policy
theory built on those static foundations. Rigor inherits part of
it; the rest is deliberately out of scope.

### Blame

**Findler & Felleisen 2002** (*Contracts for Higher-Order
Functions*) introduced the **blame** principle: when a value
flows across a static / dynamic boundary and a contract violation
is detected at runtime, *whose code is at fault*? The answer must
be unambiguous and inferable from the boundary topology — a value
crossing from typed code into untyped code carries a positive
contract obligation; from untyped to typed, a negative one.

**Wadler & Findler 2009** (*Well-Typed Programs Can't Be Blamed*)
gave the slogan: a typed module that follows its declared
interface is never the cause of a blame error — only untyped code
(or a static / dynamic interface mismatch) can be.

### The gradual guarantee

**Siek, Vitousek, Cimini & Boyland 2015** (*Refined Criteria for
Gradual Typing*) formalised the property a gradual type system is
most commonly *expected* to satisfy:

> Adding type annotations to a previously well-typed program does
> not introduce new errors. Removing annotations from a previously
> well-typed program does not introduce new errors either.

This is the **gradual guarantee**. It is the property that makes
gradual adoption psychologically viable: a developer adding an
RBS annotation to a working method should never break a
previously-passing call site, and removing an annotation should
never fire a new diagnostic.

### Rigor's position

Rigor does not insert runtime contracts. Blame in the
Findler-Felleisen sense has no direct operational analogue —
Rigor is static-only, and a `Dynamic[T]`-to-concrete-`T` flow is
a static decision, not a runtime check that could "blame" anyone.

The **gradual guarantee** *is* a property Rigor can be measured
against:

- **In spirit**, the no-false-positives stance
  ([ADR-5](../adr/5-robustness-principle.md)) is strictly
  stronger than the gradual guarantee. If Rigor was silent on a
  call site before an annotation was added, it remains silent
  after — unless the annotation provably contradicts the runtime
  behaviour, in which case the diagnostic fires on the annotation
  rather than on the call. The asymmetry "strict on returns,
  lenient on parameters" is calibrated to satisfy this property
  by construction.
- **In practice**, the gradual guarantee in Rigor reads as: a
  project's baseline of "passes without annotation" should never
  regress when an RBS file is added. This is exactly the property
  the [PHPStan-shaped baseline mechanism](../adr/22-baseline-and-project-onboarding.md)
  enforces — adding annotations shrinks the baseline; it never
  grows it on un-annotated code.

### What Rigor explicitly does NOT do

- **Runtime contract insertion at the static / dynamic boundary.**
  The opt-in [`rigor-sorbet`](../../plugins/rigor-sorbet/) plugin
  reads Sorbet's `T.let` / `T.cast` / `T.must` as cast forms, but
  the contract *enforcement* is `sorbet-runtime`'s job, not
  Rigor's. Rigor's static analysis uses the cast as a hint, not
  as a check.
- **Blame-tracking algebra.** Rigor's dynamic-origin tracking
  records *why* a value became `Dynamic[T]` (which plugin / which
  file / which boundary) and is consulted by refactoring tools,
  but does not assign run-time fault. There is no positive /
  negative contract obligation in Rigor's algebra.
- **Trust polarity at boundaries.** The "typed code is trusted;
  untyped code is suspect" framing that the
  Wadler-Findler-Greenberg lineage builds on is replaced in
  Rigor by the simpler "we report only diagnostics we can
  prove" framing — which removes the question of who is to
  blame by removing the runtime decision point.

The gradual-typing trinity for Rigor: **consistency `~`** (the
static side, § "Gradual typing"); the **gradual guarantee** (the
migration story, this section); and **no runtime cost** (the
engineering stance — Rigor is a compile-time tool, not a
contract system).

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

## Decidability of inference

A type system's *expressive power* and the *decidability of
inferring its types* pull in opposite directions. Adding the wrong
combination of features can push inference into undecidable
territory — equivalent in difficulty to the halting problem.
Language designers therefore pick a fragment that is decidable for
inference and require annotations for anything beyond.

The friendliest accessible-level survey of this landscape in
Japanese is 水野雅之「計算機に推論できる型、できない型」
(Wantedly Advent Calendar, 2021; see the reading list below). The
key results it walks through, in terms of where Rigor sits:

| Feature | Inference status | Rigor stance |
| --- | --- | --- |
| Let-polymorphism (Hindley–Milner) | Decidable; ~linear in practice | Not Rigor's strategy. Rigor is gradual, not HM-based — RBS generics resolve by walking call sites and consulting signatures, not by global unification. |
| Higher-rank polymorphism, Rank-2 | Decidable with annotations (Kfoury & Wells, 1994) | Not exposed at the user surface. RBS generics are predicative. |
| Higher-rank polymorphism, Rank-3+ | **Undecidable** (Wells, 1999) | Not exposed. Would force annotations wherever a polymorphic value flows. |
| Polymorphic recursion | **Undecidable** (Henglein, 1993) | Not exposed. A generic method body sees its type parameter as fixed at the call site — recursive calls do not re-instantiate it. |
| Recursive types as inference targets | Decidable for equi/iso-recursive forms, but most languages exclude them from inference | RBS type aliases are nominal — recursive shapes (a tree, a JSON value) live behind a name. Rigor does not synthesise an anonymous fixed-point type during inference. The OCaml cautionary example `let f g x = x x` is well-typed under unrestricted recursive types — exactly the kind of "accepted but unwanted" judgment that motivates the exclusion. |
| Subtyping + intersection types (full) | **Undecidable in general** | Rigor exposes both `<:` and `&` (meet). Instead of restricting the language to recover decidability, it trades completeness for the trinary certainty — the `maybe` arm is what closes the gap. |

### Rigor's pragmatic response: the third arm

A textbook sound type checker has two ways to react when inference
cannot decide:

1. **Restrict the language** — give up the offending feature (HM
   gives up rank-N polymorphism to keep inference total).
2. **Demand annotations** — push the burden onto the author
   (System F makes the user write `Λα.` themselves).

Rigor's no-false-positives stance enables a third route, available
only in the gradual setting:

> When inference cannot decide, return `maybe` and stay silent.

The `maybe` arm of the trinary certainty is therefore not only an
acknowledgement of *runtime* uncertainty (the gradual concern from
the previous section); it is also the formal acknowledgement that
the static system is *deliberately incomplete in the inferability
sense*. The two incompletenesses share one representation in
Rigor's algebra because the practical answer in both cases is the
same: do not fire a diagnostic the system cannot justify.

```ruby
# A call where deciding the subtyping-with-intersection constraint
# would require global, undecidable inference. Rigor returns
# `maybe` and emits no diagnostic.
def consume(x)
  x.frobnicate if x.respond_to?(:frobnicate)
end
consume(some_value_from_a_dynamic_source)  # certainty: maybe — silent
```

This stance also explains a recurring shape in Rigor's design:
when a feature would only be addable at the cost of global,
inference-time blow-up (closed row variables, first-class
higher-rank polymorphism, full GADT-style constructor-driven
narrowing), Rigor either ships a nominal substitute (capability
roles for row polymorphism, `interface` for existentials) or
defers the feature behind an ADR rather than degrade to a noisy
approximation.

## Hindley–Milner, principal types, and Rigor's inference architecture

The previous two sections discussed **soundness** (does the
system reject only programs that really would crash?) and
**decidability** (does the system always give an answer in finite
time?). Type-theory textbooks bundle these with a third property
that the appendix has not named so far:

- **Principal type property** — every well-typed expression has a
  *most general* type, of which every other valid typing is a
  substitution-instance. In a system with the principal type
  property, "the type of `e`" is a canonical, unambiguous answer
  — not a guess among many.

These three properties interact in a way worth understanding,
because **Hindley–Milner (HM)** — the type system underlying ML,
OCaml, and Haskell — is the canonical example of having all three
at once.

### What HM achieves and what it gives up

The classical Damas–Milner theorem (1982) is roughly:

> Every term typable in HM has a unique principal type, computable
> by unification (Algorithm W). The system is sound, decidable,
> and inference is "free" — the user writes no type annotations.

The cost is structural. HM accepts only a language without:

- rank-N polymorphism beyond let-bound generalisation;
- subtyping;
- intersection types;
- unrestricted recursive types at the user surface;
- polymorphic recursion.

Each excluded feature is exactly the kind that breaks one of the
three properties when added back:

| Added feature | Property that breaks first |
| --- | --- |
| Rank-3+ polymorphism | Decidability (Wells, 1999) |
| Polymorphic recursion | Decidability (Henglein, 1993) |
| Subtyping in general | Principal types (a value can satisfy several incomparable interfaces; "most general" stops being unique) |
| Subtyping + intersection (full) | Decidability |
| Unrestricted recursive types | The "principle of least surprise" — terms like `λx. x x` become well-typed |

### Why Rigor cannot be HM

Rigor's surface **already contains the features HM excludes**.
Subtyping is the foundation of the lattice (`<:`); intersection
(`&`) is in the algebra; refinements add predicate subtyping;
generics + occurrence typing + capability roles cover the
polymorphism uses Ruby programmers actually have. An HM-style
"infer a principal type for every expression by global
unification" architecture is therefore not available to Rigor in
principle — not a missing feature, but a structural consequence of
the type language Ruby authors expect.

Rigor's inference is instead **local and walker-driven**:

- The walker descends the AST once.
- At each expression site it consults RBS signatures, narrowing
  facts, mutation effects, and plugin contributions.
- It returns *the* type of the expression *at that point in the
  control flow* — the most specific type the local walk can
  justify, not a canonically most-general one.

The same expression appearing at two program points may yield two
different types (narrowing, flow merges, mutation, plugin
contributions can all enter). This is closer in spirit to
TypeScript's contextual / flow-sensitive typing than to HM's
unification, and it matches how Ruby authors actually reason about
their code — `arr` after `arr.compact!` is not "the same type" as
`arr` before it.

### Property ledger

The three properties laid against Rigor and HM:

| Property | Hindley–Milner | Rigor |
| --- | --- | --- |
| **Soundness** | Yes | **No, by design** — `maybe` cases stay silent (§ "Soundness, completeness, and the no-false-positives stance"). |
| **Decidability** | Yes (DEXPTIME worst-case, near-linear in practice) | Decidable per local walk; whatever the walker cannot decide, it returns `maybe` (§ "Decidability of inference"). |
| **Principal type property** | Yes | **No** — subtyping + intersection break it. Rigor reports a *per-occurrence* type, not a canonical most-general one. |

The headline observation: HM trades expressiveness for the
trinity (soundness + decidability + principal types). Rigor
trades the trinity for expressiveness, and recovers what it can
through the trinary certainty and the no-false-positives stance.

### A note on bidirectional / local type inference

Once subtyping enters the picture, the textbook fallback for
HM-style global unification is **bidirectional** or **local type
inference** (Pierce & Turner, 2000): split typing rules into a
*synthesis* mode (compute the type of `e` from `e`) and a
*checking* mode (verify that `e` has an expected type). Steep is
in this lineage. Rigor's walker is bidirectional in this informal
sense — call sites synthesise; RBS signatures check parameters
against the synthesised argument types — but Rigor does not
formalise the bidirectional rules because the gradual setting and
the trinary certainty make the "could not decide" case explicit
rather than a typing-rule failure.

The next section makes this informal claim concrete.

## Bidirectional type checking

The HM section noted in passing that Rigor's walker is
"bidirectional in everything but formalisation." That is the
short version of the relationship between Rigor and a substantial
contemporary line of type-system work, and worth its own
treatment.

### The synthesis / checking split

**Pierce & Turner 2000** (*Local Type Inference*) and the modern
canonical reformulation by **Dunfield & Krishnaswami 2013**
(*Complete and Easy Bidirectional Typechecking for Higher-Rank
Polymorphism*) split typing judgments into two modes:

- **Synthesis** (`Γ ⊢ e ⇒ T`): given an expression `e`, compute
  its type `T`. The type flows out.
- **Checking** (`Γ ⊢ e ⇐ T`): given `e` and an expected type
  `T`, verify that `e` has type `T`. The type flows in.

Every typing rule is one or the other. The two modes alternate
top-down (checking propagates expected types) and bottom-up
(synthesis returns types) through the AST, replacing the global
unification of HM with *local* constraint discharge. The same
machine handles subtyping, intersections, and higher-rank
polymorphism without needing a global solver.

### Industrial uptake

- **Steep** is explicitly bidirectional and the closest Ruby
  analogue — its rules are authored in `⇒` / `⇐` form.
- **TypeScript**'s "contextual typing" is bidirectional in
  everything but the name.
- **Scala 3**'s match types and contextual typing.
- **OCaml** uses local type inference (Pierce & Turner directly)
  for higher-rank-polymorphic positions where HM cannot decide.
- **Roc**, **ReScript**, **Idris 2** — all bidirectional in the
  modern Dunfield-Krishnaswami style.

### Rigor's bidirectional behaviour, informal

Rigor's walker performs the two modes without naming them:

| Walker behaviour | Bidirectional mode |
| --- | --- |
| Computing the type of an argument expression at a call site | Synthesis |
| Verifying the argument type against the RBS parameter type | Checking |
| Inferring `HashShape` for a hash literal | Synthesis |
| Inferring `Tuple` for an array literal | Synthesis |
| Walking the `then` / `else` branches of an `if` under a narrowed environment | Synthesis under each branch + join (no expected-type checking) |
| Verifying a plugin protocol contract ([ADR-28](../adr/28-path-scoped-protocol-contracts.md)) — method exists + return-type matches | Checking |
| Honouring an `RBS::Extended` `assert_type` directive | Checking |

What Rigor does NOT do that a fully formalised bidirectional
system would:

- **Constraint propagation across non-adjacent expressions.**
  Each expression's type is decided when the walker reaches it;
  later uses see the decision as a fixed fact, not as a
  constraint to be solved together with theirs.
- **Local generalisation.** HM's `let`-binding generalisation
  step does not exist in Rigor; the walker does not introduce
  fresh type variables to be solved later.
- **Formal mode discipline.** Rigor's rules are not authored as
  `⇒` / `⇐` judgments; the walker's behaviour matches a
  bidirectional reading but the spec does not enforce it.

The practical consequence: Rigor's inference is faster than a
constraint-based bidirectional system (no global solving) and
gives a definite "what type is this expression?" answer at every
point — at the cost of not being able to defer typing decisions,
which a more constraint-based system would allow when context
arrives later in the walk.

For a reader who has internalised the bidirectional literature,
the mental model is: **synthesis everywhere except at the RBS /
plugin-contribution boundary, where the declared type is the
check side.** That is the entire bidirectional discipline Rigor
needs.

## Beyond pure inference: reach and precision

The previous sections framed "what cannot be statically inferred"
in terms of theoretical decidability — `maybe` as the response
when no proof is available. That covers one half of the design
space. There is a second half that the reading-order of this
appendix has implied but not yet named: phenomena that are *not*
theoretically undecidable, where a pure AST-walking inference
*could* return a type but the type it would return either (a)
does not exist in the AST at all, or (b) exists but is too wide
to be useful.

Both halves are addressed by the same substrate — `RBS::Extended`
directives, plugin contributions, the specialised carrier zoo —
but for different reasons. It is worth giving them separate
names.

### Reach: the AST does not describe the program

The walker reads the AST. For a Ruby program, the AST is not a
complete description of the program's runtime behaviour:

- `define_method` synthesises methods whose names are computed at
  evaluation time.
- `attr_accessor :name` defines `#name` / `#name=` whose existence
  the walker recognises by pattern, not by general reasoning.
- `class_eval` / `instance_eval` over a block injects code under
  a different `self`.
- DSL forms like `has_many :posts` or
  `attribute :name, Types::String` declare *both* a method and a
  type contract through a single helper call.
- `eval(string)` with an arbitrary string is genuinely outside
  the AST.

None of these is "undecidable" in the sense of the previous two
sections. The semantics are perfectly well-defined; the walker
simply cannot *read* them from the AST. This is the **reach**
problem, distinct from the decidability problem:

| Problem class | Example | Rigor's response |
| --- | --- | --- |
| Theoretical undecidability of inference | Rank-3 polymorphism; subtyping + intersection | The trinary `maybe` |
| Reach — the AST does not contain the semantics | `define_method`, Rails DSL, `attr_*` | Plugin contributions + `RBS::Extended` + the [ADR-16](../adr/16-macro-expansion.md) macro substrate |
| Genuine runtime opacity | `eval(user_input)` | `Dynamic[Top]`, then `maybe` at use sites |

Plugins are written in Ruby because the reach problem cannot be
solved in the type language alone — it needs a Ruby-side
recogniser that walks the AST, decides "this `has_many :posts`
declares an accessor returning `Relation[Post]`," and contributes
that fact to the walker's worldview.
[ADR-2](../adr/2-extension-api.md),
[ADR-16](../adr/16-macro-expansion.md),
[ADR-25](../adr/25-plugin-contributed-rbs.md), and
[ADR-28](../adr/28-path-scoped-protocol-contracts.md) define the
structured extension points where this knowledge enters.

### Precision: naive inference produces useless joins

The second motivation is subtler but at least as important. The
simplest "correct" inference rules for compound expressions
produce types so wide they tell the user nothing useful:

| Expression | Naive join | More useful type | Mechanism in Rigor |
| --- | --- | --- | --- |
| `{user: u, count: 3, msg: "ok"}` | `Hash[Symbol, User \| Integer \| String]` | `HashShape{user: User, count: Integer, msg: String}` | `HashShape` carrier (built-in for hash literals) |
| `[1, "a", :sym]` | `Array[Integer \| String \| Symbol]` | `Tuple[Integer, String, Symbol]` | `Tuple` carrier (built-in for array literals) |
| A provably-constant value (e.g. `42`, `"ok"`) | `Integer`, `String` | `Constant<42>`, `Constant<"ok">` | `Constant<T>` carrier |
| `JSON.parse(input)` | `Hash[String, untyped] \| Array[untyped] \| String \| Integer \| Float \| true \| false \| nil` | `App[json::value, K]` per option `K` | [ADR-20](../adr/20-lightweight-hkt.md) Lightweight HKT + `METHOD_RETURN_OVERRIDES` |
| A method whose return depends on its arguments | A wide union of every observed exit | A per-call-site discriminated return | `RBS::Extended` `return_override` directive |
| A DSL-managed accessor (`has_many`, `attribute`) | `Dynamic[Top]` | `Relation[Model]`, a model-specific shape | Plugin `flow_contribution_for` + macro substrate |

These are not undecidability cases — the inference can decide a
type, it just decides a *useless* one. A type like
`Hash[Symbol, Foo | Bar | Buz]` or
`true | false | String | Integer | Float` is technically the
correct join of observed values, but its consumer cannot do
anything with it without narrowing first; the union has erased
exactly the information the type system existed to carry.

The shared design principle is **strictness on returns** — the
robustness principle ([ADR-5](../adr/5-robustness-principle.md))
treats "the most specific type the analysis can justify" as the
goal, not "the smallest type that covers every observed exit."
Naive join-widening fails that test in nearly every case where
the inputs are heterogeneous.

This is also why `HashShape` and `Tuple` are not "exotic
refinements" but **foundational carriers** — without them every
hash literal would degrade to a `Hash`-with-union and the
inferred type language would describe almost nothing useful in
practice.

### One substrate, two problems

The plugin contract and the `RBS::Extended` directive family
therefore serve two complementary roles. They extend *where*
Rigor can produce a type at all (reach), and they raise *how
specific* that type is when produced (precision). The two roles
share a substrate but answer different limitations — one of
static-analysis scope, one of useful-type design — and neither
is the same as the decidability question that the trinary
`maybe` answers.

## The expression problem and Rigor's plugin contract

A theoretical framing for one of Rigor's central design choices
— the plugin contract — comes from a paper that gave the framing
its name.

### The problem

**Wadler 1998** (*The Expression Problem*, informal note) posed
the challenge: in a typed language, can you simultaneously
support

1. **Adding new types** (new data variants) without modifying
   existing operations, *and*
2. **Adding new operations** (new functions over existing data)
   without modifying existing types?

Most type-system paradigms handle one or the other:

| Paradigm | Easy to add | Hard to add |
| --- | --- | --- |
| OO (subtyping + dispatch) | New types (subclass) | New operations (must touch every class) |
| Functional ADTs + pattern matching | New operations (new function) | New types (must touch every operation) |
| Haskell type classes | Either, with care | The other requires `OverlappingInstances` etc. |
| Scala traits + pattern matching | Either, with elaboration support | Boilerplate on the unsupported side |
| Clojure / Elixir protocols | Either (protocol dispatch) | (Solved by design) |
| Ruby open classes | Both! (reopen + monkey-patch) | (Solved by design — sometimes too directly) |

Ruby sits in the "open classes" row — a non-typed language where
the expression problem is solved by `module Foo; def bar; …;
end; class String; include Foo; end`. The language solution
trades safety for flexibility.

### Rigor's plugin contract as the tool-side answer

Rigor's plugin substrate ([ADR-2](../adr/2-extension-api.md),
[ADR-16](../adr/16-macro-expansion.md),
[ADR-25](../adr/25-plugin-contributed-rbs.md),
[ADR-28](../adr/28-path-scoped-protocol-contracts.md), …) solves
the **tool-level** version of the same problem:

- **Adding new type knowledge** the engine can act on — new RBS
  bundles, new structural shapes via `signature_paths:`, new
  TypeNode resolvers ([ADR-13](../adr/13-typenode-resolver-plugin.md))
  — **without modifying the engine**.
- **Adding new analyses / operations** over existing types — new
  diagnostic rules, new flow contributions, new protocol
  contracts ([ADR-28](../adr/28-path-scoped-protocol-contracts.md))
  — **without modifying the type language**.

The plugin contract is therefore the **expression problem solved
at the analyser's extension boundary**, where the language-level
solution (open classes) is too coarse for static analysis.

A worked example:

- `rigor-activesupport-core-ext` adds a *new fact* about existing
  classes (`Numeric#hours`, `String#blank?`, `Hash#stringify_keys`)
  — type-extension axis.
- `rigor-web` adds a *new analysis* over existing classes
  (every class under `lib/controller/` must define
  `#get(Rack::Request) -> Rack::Response`) — operation-extension
  axis ([ADR-28](../adr/28-path-scoped-protocol-contracts.md)).

Neither plugin requires modifying the Rigor engine, and they
*compose* — a single plugin can do both axes ([ADR-12 dry-rb
packaging](../adr/12-dry-rb-packaging.md) discusses the
production examples).

### Connection to earlier appendix sections

This framing also retroactively explains several design choices:

- **Nominal-first** (§ "Nominal vs structural typing"):
  nominal class names are the stable attachment point for
  plugin-contributed facts. Structural shapes are inferred
  per-call; a plugin would have no name to bind its knowledge
  to. The expression problem framing prefers explicit `class`
  declarations precisely because the name is the extension
  handle.
- **The macro substrate** ([ADR-16](../adr/16-macro-expansion.md)):
  each tier (A: block-as-method, B: trait-inlining, C: heredoc
  template, D: external-file inclusion) is a different way to
  add knowledge about a class's behaviour without modifying the
  class — the type-extension axis made plural.
- **Path-scoped protocol contracts**
  ([ADR-28](../adr/28-path-scoped-protocol-contracts.md)): a
  plugin can declare a behavioural contract for an entire
  directory of user-authored classes without the classes
  opting in — the operation-extension axis made tool-side.

The plugin contract is therefore not an ad-hoc Rigor design
choice but **the expression problem solved at the analyser layer
rather than the language layer**. The same theoretical pressure
that drove Haskell to type classes and Clojure to protocols
drives Rigor to a structured plugin substrate.

## Smaller connections, in brief

A grab-bag of further type-theoretic / programming-languages
connections. Each is summarised in a paragraph rather than a
section because the topic either maps to mechanisms already
covered or to a deliberate non-feature
([§ What Rigor does NOT model](#what-rigor-does-not-model)), but
a reader hunting for "does Rigor have a story for X?" should be
able to find one here.

### Type erasure vs reification

A language **erases** types at runtime (Java generics, Haskell,
OCaml) or **reifies** them (C#, .NET, Ruby's `.class`). Ruby is
fully reified — `arr.class` returns `Array` at runtime, and
`is_a?` queries are first-class. Rigor leans on this: occurrence
typing's predicate set (`is_a?` / `kind_of?` / `instance_of?` /
`respond_to?`) all use Ruby's reified class objects, and the
narrowing rules are sound *because* the run-time check matches
the type-theoretic class membership. The gradual-typing
literature on "type-erased" vs "reified" gradual systems
(Wrigstad et al. 2010, *Integrating Typed and Untyped Code in a
Scripting Language*) classifies Rigor's setting as fully reified
on the dynamic side — which is what makes `Dynamic[T]` narrow
back to a concrete type safely whenever the runtime predicate
fires.

### Algebraic effects vs monadic effects

The textbook alternative to monadic effects (Haskell `IO`, Scala
`cats-effect`) is **algebraic effects with handlers** (Plotkin &
Pretnar 2009; Koka / Eff / OCaml 5's effect handlers). Algebraic
effects let an "effectful" computation be paused at the effect
site and resumed by a handler — closer to delimited
continuations than to monad bind. Rigor's effect model
(§ "Effect systems") is neither monadic nor algebraic; it is
*inferred* and *engine-internal*. Surfacing effects to the user
(annotation grammar; pure-function marker; algebraic-effect
signatures) is a future direction tracked in the spec corpus;
the relevant prior art is the Koka community's surface design.

### Single vs multiple dispatch

Ruby is single-dispatch — method selection depends on the
receiver's class only. Languages with **multiple dispatch**
(CLOS, Julia, Dylan) select methods based on the runtime types
of every argument. RBS overloads — `def m: (Integer) -> Integer
| (String) -> String` — simulate a static-side analogue of
multiple dispatch by picking an arm by argument type at the call
site. Rigor honours the "most-specific arm wins" resolution that
multiple-dispatch type systems require, but the runtime dispatch
remains single-dispatch; the overload arm is selected at
type-check time, not at call time.

### Phantom types and brand types

A **phantom type** carries a type parameter that does not appear
in any field — e.g., `class Length<U>` where `U` is `Metres` or
`Feet`. The type carries an invariant the runtime does not
enforce. **Brand types** wrap a base type in a unique nominal
type (`class ValidatedEmail < String`) so that only
verified-via-constructor values inhabit it. Rigor's refinement
carriers (§ "Refinement types") cover the brand-type use case
for the common refinements (`non-empty-string`, `positive-int`,
…); user-extensible brand types via `class X < Y` are typed
nominally by Rigor — `ValidatedEmail` is distinct from `String`
at the type level. The phantom-type-via-unused-parameter pattern
is also typeable but not widely used in Ruby; the equivalent
expressiveness usually arrives via refinements or nominal
wrapping.

### Open-world vs closed-world assumption

RBS treats unknown methods on a `Dynamic[T]` receiver under the
**open-world** assumption — "we do not know the full method set;
an unknown method might exist at runtime." Rigor inherits this
on dynamic receivers, which is why a `respond_to?`-narrowed call
on a `Dynamic[T]` value does not fire `call.undefined-method`.
On a concretely-typed receiver (e.g. `String`), Rigor uses the
**closed-world** assumption — the RBS signature is taken as the
authoritative method set, and an unknown method fires
`call.undefined-method` (subject to the
[ADR-26 `open_receivers:`](../adr/26-activerecord-relation-typing.md)
exemption for receivers whose method set is provably open at
runtime, like `ActiveRecord::Relation`).

### Equirecursive vs isorecursive types

Two formalisms for recursive types: **equirecursive** treats
`T = μX. F(X)` as judgmentally equal to `F(μX. F(X))` (any
recursive type can be silently unfolded); **isorecursive**
requires explicit `fold` / `unfold` conversions at every use.
RBS type aliases are nominally recursive — `type tree = [Symbol,
tree?]` is the type *by name*, and Rigor compares them by name,
not by structural unfolding. This is the conservative path that
sidesteps the equirecursive-vs-isorecursive debate entirely:
naming a recursive type is the only way to write it.

### Polarity and variance positions

Variance (§ "Variance") is derived from **positions** in a type
expression: a type variable appearing in **positive** position
(return type, output of a producer) is covariant; in **negative**
position (parameter type, input to a consumer) is contravariant;
in both (mutable storage) is invariant. The polarity reading is
the standard textbook derivation (Pierce, *Types and Programming
Languages*, ch. 15). RBS's `out T` / `in T` annotations express
the result directly without forcing the user to read variance
off a type expression's polarity structure; Rigor honours the
declared variance without re-deriving it.

### Subtype-with-bounded-existentials

The standard encoding of "a value with a hidden type that
satisfies an interface" is **bounded existential types** — `∃X
<: I. T(X)`. Most industrial languages encode this via
*structural interfaces* instead: a parameter typed `I` accepts
any value with `I`'s method set, hiding the receiver's concrete
type. Rigor follows the industrial convention — `interface
_Comparable` (§ "Nominal vs structural typing") is the
existential-bound mechanism users actually reach for. The pack /
unpack syntax of ML-style existential types is not exposed.

### Refinement-as-types vs refinement-as-predicates

The § "Refinement types" section covers Rigor's curated
refinement catalogue (`non-empty-string`, `positive-int`, …),
which sits in the **refinements-as-types** tradition. The
alternative — **refinements-as-predicates** (SMT-backed Liquid
Types; F\*'s subset types) — keeps the predicate as a first-class
formula attached to the base type, and discharges it via SMT at
each constraint site. Rigor uses a much weaker, decidable
fragment: the predicate is a named refinement carrier (not an
arbitrary formula), and the "narrow into the refinement" rule is
a deterministic engine step (not an SMT call). The Rondon-
Kawaguchi-Jhala Liquid Types reference in the reading list is
the technical seed Rigor's catalogue draws from at a distance.

## What Rigor does NOT model

For completeness, a short list of type-theoretic features Rigor
*does not* currently expose at the user surface — naming them
here so you can stop looking:

- **Higher-kinded types (HKT).** `Functor[F[_]]` style
  abstraction. Tracked as a "future direction" but not in any
  shipped slice. (General HKT inference is undecidable; ADR-20
  sketches a defunctionalised, annotation-driven approach that
  sidesteps this.)
- **Higher-rank polymorphism (System F⊤).** All RBS generics
  are predicative; type variables cannot quantify over
  polymorphic types. (Rank-3 inference is undecidable per Wells,
  1999; the predicative restriction keeps Rigor's surface
  inferable without per-call annotations.)
- **Polymorphic recursion.** A generic method body re-applied
  inside itself at a *different* instantiation. Inference is
  undecidable (Henglein, 1993); RBS does not offer the syntax
  and Rigor does not synthesise it.
- **Full dependent types.** No `Vec[n, T]` with `n : Integer`.
  Type-checking is decidable but inference is not; integer-range
  refinements (`int<min, max>`) cover the most common practical
  need without crossing the line.
- **Row polymorphism as a user-quantifiable axis.** `HashShape`
  carries open-vs-closed semantics internally but does not
  expose row variables. See § "Object shapes — row polymorphism,
  Hack, and HashShape's lineage" for the design rationale.
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
- Canning, Cook, Hill, Olthoff & Mitchell. "F-Bounded
  Polymorphism for Object-Oriented Programming." *FPCA 1989.*
  The classical reference for F-bounded polymorphism — the
  type-theoretic root of RBS's `self` keyword and Sorbet's
  `T.attached_class`.
- Wadler, P. "The Expression Problem." Informal note posted to
  the `java-genericity` mailing list, 1998. The challenge that
  motivates Rigor's plugin substrate as the analyser-layer
  answer.
- Wand, M. "Complete Type Inference for Simple Objects."
  *LICS*, 1987. The seed of row polymorphism — first
  formulation of "infer object types with extra fields."
- Rémy, D. "Type Checking Records and Variants in a Natural
  Extension of ML." *POPL 1989.* The row-variable mechanism in
  the form it is most commonly cited.
- Cardelli, L. & Mitchell, J.C. "Operations on Records."
  *Mathematical Structures in Computer Science*, 1991. The
  algebraic treatment of record operations under row
  polymorphism — the substrate Garrigue and then Matsumoto &
  Minamide build on.
- Siek & Taha. "Gradual Typing for Functional Languages."
  *Scheme Workshop*, 2006. The original gradual-typing paper.
- Garcia, Clark & Tanter. "Abstracting Gradual Typing."
  *POPL 2016.* The modern reformulation of gradual typing in
  terms of abstract interpretation.
- Findler & Felleisen. "Contracts for Higher-Order Functions."
  *ICFP 2002.* The origin of blame as a formal principle —
  background for § "Blame, the gradual guarantee, and trust
  boundaries."
- Wadler & Findler. "Well-Typed Programs Can't Be Blamed."
  *ESOP 2009.* The headline result on the asymmetry between
  typed and untyped code at the boundary.
- Siek, Vitousek, Cimini & Boyland. "Refined Criteria for
  Gradual Typing." *SNAPL 2015.* The original statement of the
  gradual guarantee.
- Frisch, Castagna & Benzaken. "Semantic Subtyping: Dealing
  Set-Theoretically with Function, Union, Intersection, and
  Negation Types." *Journal of the ACM*, 2008. The foundational
  treatment of set-theoretic types — background for § "Set-
  theoretic foundations of the lattice."
- Castagna, G. *Programming with Union, Intersection, and
  Negation Types.* 2024. The current canonical reference for
  semantic-subtyping-based type systems; the framework behind
  Elixir's set-theoretic types.
- Dunfield & Krishnaswami. "Complete and Easy Bidirectional
  Typechecking for Higher-Rank Polymorphism." *ICFP 2013.* The
  modern canonical reference for bidirectional type checking —
  background for § "Bidirectional type checking."
- Tobin-Hochstadt & Felleisen. "The Design and Implementation
  of Typed Scheme." *POPL 2008.* Origin of occurrence typing.
- Maranget, L. "Warnings for Pattern Matching." *Journal of
  Functional Programming*, 2007. The algorithm OCaml uses for
  pattern-match exhaustiveness — background for § "Pattern
  matching and exhaustiveness."
- Rondon, Kawaguchi & Jhala. "Liquid Types." *PLDI 2008.* The
  refinement-types-with-SMT framework that informs the
  `int<min, max>` carrier (Rigor uses a much weaker, decidable
  fragment).
- Lucassen & Gifford. "Polymorphic Effect Systems."
  *POPL 1988.* Origin of effect systems.
- Plotkin & Pretnar. "Handlers of Algebraic Effects."
  *ESOP 2009.* The algebraic-effect-handler design that Koka,
  Eff, and OCaml 5's effect system descend from — background
  for the § "Smaller connections" note on algebraic vs monadic
  effects.
- Wrigstad, Nardelli, Lebresne, Östlund & Vitek. "Integrating
  Typed and Untyped Code in a Scripting Language."
  *POPL 2010.* The taxonomy of type-erased vs reified gradual
  systems — background for § "Smaller connections" on Ruby's
  fully reified dynamic side.
- Milner, R. "A Theory of Type Polymorphism in Programming."
  *JCSS*, 1978. The Hindley–Milner system in its original form
  — the canonical type system that achieves soundness,
  decidability, and the principal type property simultaneously
  by restricting the language.
- Damas, L. & Milner, R. "Principal Type-Schemes for Functional
  Programs." *POPL 1982.* The principal-type theorem and
  Algorithm W. The reference for what Rigor consciously does
  *not* attempt.
- Pierce, B.C. & Turner, D.N. "Local Type Inference." *ACM
  TOPLAS*, 2000. The bidirectional / local-inference design that
  the Ruby static-typing landscape (Steep especially) draws from
  once subtyping is in the picture — the practical successor to
  HM under those conditions, and the closest textbook analogue
  to Rigor's walker.
- Wells, J.B. "Typability and Type Checking in System F are
  Equivalent and Undecidable." *Annals of Pure and Applied
  Logic*, 1999. The proof that Rank-3 (and higher) type
  inference is undecidable — the reason RBS generics stay
  predicative.
- Henglein, F. "Type Inference with Polymorphic Recursion."
  *ACM TOPLAS*, 1993. Establishes that inferring polymorphic
  recursion is undecidable.
- 水野雅之.「計算機に推論できる型、できない型」.
  *Wantedly Advent Calendar*, 2021.
  <https://www.wantedly.com/companies/wantedly/post_articles/349494>.
  A friendly Japanese-language tour of the decidability boundary
  — Let多相, Rank-N, 多相再帰, 再帰型, サブタイピング+交差型 —
  and the most accessible companion to the
  "Decidability of inference" section above.
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
