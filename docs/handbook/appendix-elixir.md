# Appendix — Coming from Elixir

If your mental model of "types" was set by Elixir — Dialyzer's
success typing, `@spec` / `@type`, and the set-theoretic gradual
types now rolling into the language — this appendix maps Rigor's
vocabulary onto it. Of every page in this series, this is the
one whose *philosophy* matches Rigor most closely: both are
dynamic languages at heart, both add types gradually, both
refuse to cry wolf. Elixir's type checker only flags what it can
prove will fail; so does Rigor. That instinct (never frighten
working code) is shared DNA, not coincidence.

There is even a direct lineage: Rigor's clause-reachability rule
([ADR-47](https://github.com/rigortype/rigor/blob/master/docs/adr/47-narrowing-driven-clause-reachability.md)) was
modelled on Elixir's own work on detecting impossible `case`
clauses. You are coming from one of Rigor's design influences.

This is a translation table plus a discussion of where the two
diverge (Elixir is functional, immutable, and process-oriented;
Rigor analyses an object-oriented, mutable language) and where
they line up better than you would guess.

## The five-second pitch

| Question | Elixir | Rigor |
| --- | --- | --- |
| Origin | Dynamic; types added gradually | Dynamic; types added gradually |
| Soundness stance | Success typing — flag only provable failures | No-false-positives — silent unless it can prove the error |
| Where do annotations live? | `@spec` / `@type` in source | `.rbs` files alongside `.rb` |
| The "I don't know" type | `dynamic()` / `term()` | `Dynamic[top]` / `Top` |
| Narrowing engine | Pattern matching + guards | Pattern matching + guards + predicate methods |
| Type algebra | Set-theoretic (union / intersection / negation) | Union + type operators (`~T`, `T - U`) |

Elixir and Rigor agree on the thing that matters most: a type
checker for a dynamic language should be an advisor that earns
trust by never false-alarming, not a gate that rejects programs.
Dialyzer's "I will only tell you about a path that *cannot*
succeed" is the same contract as Rigor's "I stay silent unless I
can prove the error." If that stance is why you trust Dialyzer,
you will recognise Rigor immediately.

## Type vocabulary mapping

| Elixir | Rigor | Notes |
| --- | --- | --- |
| `integer()` | `Integer` | Both arbitrary-precision. |
| `float()` | `Float` | `Numeric` is the common supertype. |
| `boolean()` (`true \| false`) | `bool` (`Constant<true> \| Constant<false>`) | Structurally a union of two constants in both systems. |
| `:foo` (atom) | `Constant<:foo>` (Symbol) | Atoms ↔ symbols — a direct match. See [Atoms ↔ symbols](#atoms--symbols). |
| `nil` | `nil` (`Constant<nil>`) | Elixir's `nil` is the atom `nil`; Ruby's is its own singleton. Both falsy. |
| `binary()` / `String.t()` | `String` | |
| `term()` / `any()` | `Top` / `Dynamic[top]` | `any()` for "anything"; `dynamic()` for the gradual escape hatch. |
| `none()` | `Bot` | Empty type — no inhabitants. |
| `[t]` (list) | `Array[T]` | |
| `{a, b}` (tuple) | `Tuple[A, B]` | Same per-position model. |
| `%{optional(k) => v}` (map) | `Hash[K, V]` | |
| `%{a: t}` (map with known keys) | `HashShape{a: T}` | Closed shape with known keys. |
| `%User{}` (struct) | `User = Data.define(...)` | A named, member-shaped value. |
| `[key: t]` (keyword list) | `Hash[Symbol, T]` or `Array[Tuple]` | Ruby's keyword-ish data is a `Hash`. |
| `t \| u` (set-theoretic union) | `T \| U` | Same display; same idea. |
| `dynamic()` | `Dynamic[top]` | The "be silent here" gradual carrier. |
| `(integer() -> binary())` | `^(Integer) -> String` (RBS proc syntax) | |

## Pattern matching & guards ↔ narrowing

This is the section where an Elixir programmer feels at home,
because Ruby borrowed pattern matching in a shape close to
Elixir's — including the pin operator `^` — and Rigor's
narrowing engine is built around it.

| Elixir | Rigor |
| --- | --- |
| `case x do {:ok, v} -> … end` | `case x; in [:ok, v] then …` |
| function-head match `def f(%Circle{} = c)` | `case x; in Circle => c` (Ruby has no multi-clause heads) |
| guard `when is_integer(x)` | `if x.is_a?(Integer)`, or `in Integer` |
| guard `when x > 0` | `n > 0` narrows to `positive-int` — see [Refinements](#refinements--guards) |
| `^pinned` in a pattern | `^pinned` pin in `case`/`in` (same operator, same meaning) |
| `with {:ok, a} <- step1(), … do` | chained `case`/`in`, or guard clauses with early return |
| multi-clause function + guards | `case`/`in` with `if` guards in one method |

The one structural difference: Elixir dispatches by writing
*multiple function heads* with patterns and guards, and the
runtime picks the first that matches. Ruby has no multi-clause
`def`; you fold the clauses into a single method body with
`case`/`in`. The narrowing Rigor performs along each `in` clause
is the analogue of the type Elixir's compiler now infers for
each function head.

And the lineage runs the other way too: Rigor's
`flow.unreachable-clause` rule — which flags a `case`/`in` clause
that can never match because earlier clauses already covered its
type — was modelled directly on Elixir's clause-reachability
work ([ADR-47](https://github.com/rigortype/rigor/blob/master/docs/adr/47-narrowing-driven-clause-reachability.md)).
It is the feature you may know from Elixir warning you about an
impossible `case` clause, brought to Ruby.

## Set-theoretic types & gradual `dynamic()`

Elixir's type system is *set-theoretic*: types are sets of
values, and you compose them with union, intersection, and
negation, with a `dynamic()` type marking the gradual boundary.
Rigor is built on the same union-of-values intuition (the
[value lattice](https://github.com/rigortype/rigor/blob/master/docs/type-specification/value-lattice.md)) and has
the operator vocabulary to match the common cases:

| Elixir | Rigor |
| --- | --- |
| `t \| u` (union) | `T \| U` |
| intersection `t and u` | `Intersection[T, U]` |
| negation `not t` | `~T` (complement) |
| difference (set minus) | `T - U` (type difference) |
| `dynamic()` | `Dynamic[top]` |

The gradual story is nearly identical in spirit: a value typed
`dynamic()` in Elixir, like a `Dynamic[top]` receiver in Rigor,
is the point where the checker steps back and stays silent
rather than guess. Both systems lean on this to stay practical
on real code, and both treat reaching for it as ordinary.

Where Elixir goes further: it lets you *author* intersections
and negations as ordinary `@type` expressions, and its inference
reasons about them throughout. Rigor uses `~T` and `T - U`
internally and in some directives, but does not yet expose a
full set-theoretic authoring surface in `.rbs`. The everyday
overlap — unions and the gradual `dynamic()` boundary — is where
the two feel the same.

## Tagged tuples ↔ `case`/`in`

Elixir's signature idiom — `{:ok, value}` / `{:error, reason}`
returned and matched — translates almost verbatim, because Ruby
expresses the same shape with an array and `case`/`in`:

```elixir
case Integer.parse(s) do
  {n, ""} -> {:ok, n}
  _       -> {:error, :invalid}
end
```

```ruby
def parse(s)
  n = Integer(s, exception: false)
  n ? [:ok, n] : [:error, :invalid]
end

case parse(s)
in [:ok, n]      then n
in [:error, why] then handle(why)
end
```

Rigor types the `Tuple` per position and the union of the two
tagged shapes precisely, and `in [:ok, n]` narrows along that
clause exactly as the Elixir pattern does. (Ruby idiom does also
reach for raising on the error path; the tagged-tuple style
ports cleanly when you want to keep it.)

## Atoms ↔ symbols

Elixir atoms and Ruby symbols are the same idea — interned,
identity-compared name constants — and Rigor folds a symbol to
`Constant<:foo>`, the precise singleton type, not merely
`Symbol`:

```ruby
status = :ok
assert_type(":ok", status)

# a discriminated union over atoms/symbols:
def describe(s)         # s : Constant<:ok> | Constant<:error>
  case s
  in :ok    then "fine"
  in :error then "broken"
  end
end
```

This is the same modelling Elixir's set-theoretic types give an
atom — a singleton type for the specific atom — and it powers
the same discriminated-union dispatch you write with atom keys
in Elixir.

## Protocols & behaviours

Two Elixir concepts map onto Rigor's structural typing, with one
twist of difference each.

- **Behaviours** (`@callback` in a behaviour module, `@behaviour`
  on the implementer) describe a set of functions a module must
  provide. Rigor's nearest analogue is an RBS `interface` — a
  named set of methods — but with a key difference: an RBS
  interface is satisfied **structurally** (have the methods,
  satisfy it), whereas an Elixir `@behaviour` is declared.
- **Protocols** (`defprotocol` / `defimpl`) dispatch on the data
  type, and a protocol is satisfied by an *explicit* `defimpl`
  for that type — nominal, like Rust traits. Rigor has no
  per-type `defimpl`; an object satisfies a structural interface
  by responding to the methods, full stop.

So both of Elixir's "abstract over implementations" mechanisms
become Rigor's one structural-interface mechanism, which is
closer to Go's implicit interfaces than to either Elixir
construct. The
[structural-typing appendix](appendix-protocols-and-structural-typing.md)
is the canonical explainer.

## Refinements ↔ guards

An Elixir guard like `when x > 0` constrains a value at the
clause boundary, and the new type system reasons about some such
guards. Rigor turns the same guard into a named **refinement
carrier** that rides on the ordinary type:

```ruby
def reciprocal(n)
  return nil unless n > 0
  # n is positive-int here when typed as Integer; untyped params stay Dynamic[top]
  1.0 / n
end
```

| Rigor refinement | Elixir guard / idiom | Comment |
| --- | --- | --- |
| `positive-int` | `when n > 0` | Rigor names and carries the result. |
| `non-empty-string` | `when s != ""` / `byte_size(s) > 0` | Rigor produces it from `unless s.empty?`. |
| `int<1, 9>` | `when x in 1..9` | Rigor's range carrier handles arbitrary bounds. |
| `non-empty-array[T]` | `when xs != []` | Rigor produces it from `unless arr.empty?`. |
| `numeric-string` | `Integer.parse/1` + match | No direct Elixir analogue. |

The conceptual match is strong: both systems use a *runtime
guard* as the place where a more precise type becomes known.
Rigor's addition is naming that precise type so it flows onward.

## Severity, suppression, and "strict mode"

| Elixir | Rigor |
| --- | --- |
| Dialyzer warning selection | `severity_profile: lenient` / `balanced` / `strict` |
| `@dialyzer {:nowarn_function, …}` | `# rigor:disable <rule>` |
| module-level Dialyzer skip | `# rigor:disable-file all` |
| `mix dialyzer` (advisory) | `rigor check lib` (advisory) |

Both are advisory by nature — neither blocks the program from
running. The difference is when they run: Dialyzer over compiled
BEAM bytecode, Rigor over Ruby source. The adoption shape —
tune severity, suppress narrowly, baseline the rest — is the
same.

## What Elixir has and Rigor does not

Be honest about what differs:

- **Authored intersections and negations.** Elixir lets you
  write intersection and negation types as ordinary `@type`
  expressions and reasons about them throughout. Rigor uses
  `~T` / `T - U` internally but does not expose a full
  set-theoretic authoring surface.
- **Multi-clause function heads.** Pattern-matching dispatch
  across separate function heads, with the runtime selecting the
  match, has no Ruby `def`-level analogue; you fold it into
  `case`/`in`.
- **Pattern matching as pervasive assignment.** Elixir's `=` is
  a match operator everywhere; Ruby's pattern matching is scoped
  to `case`/`in` (and `=>` / `in` one-liners).
- **Process and concurrency types.** The BEAM's process model
  has no Rigor analogue.
- **Immutability by default.** Elixir data is immutable; Ruby is
  mutable, and Rigor has to reason about mutation effects that
  simply do not arise in Elixir.

## What Rigor has and Elixir does not

The other direction:

- **Shipping today, for Ruby.** Elixir's set-theoretic types are
  rolling into the language incrementally; Rigor's analyzer is
  here now for Ruby, with the no-false-positives stance already
  in force.
- **Constant folding through method calls.** `"foo".upcase` is
  `Constant<"FOO">`, not `String`. Rigor catalogues which
  built-in methods are pure and folds through them — Dialyzer
  and Elixir's types do not fold call results to singleton
  types this way.
- **Named refinement carriers.** `non-empty-string`,
  `positive-int`, `int<1, 9>`, `numeric-string` — first-class,
  named, and flowed onward from a guard.
- **Inferred object shapes and capability roles.** Beyond
  behaviours and protocols, Rigor infers anonymous structural
  shapes from how a value is used.
- **No annotation tax.** `rigor check` on a Ruby project with
  zero `.rbs` files yields useful diagnostics from inference
  alone; adding `.rbs` is incremental.

## A migration vignette

You are porting an Elixir module — a couple of pattern-matched
function heads over a struct, plus a tagged-tuple parser — to
Ruby. The original:

```elixir
defmodule Shape do
  def area(%{kind: :circle, radius: r}),    do: :math.pi() * r * r
  def area(%{kind: :rectangle, w: w, h: h}), do: w * h
end

def parse_radius(s) do
  case Float.parse(s) do
    {r, ""} -> {:ok, r}
    _       -> {:error, :invalid}
  end
end
```

The Rigor approach — `case`/`in` with hash patterns folding the
clauses into one method, and a tagged-tuple parser that ports
verbatim:

```ruby
# lib/shape.rb
def area(shape)
  case shape
  in {kind: :circle, radius:}      then Math::PI * radius * radius
  in {kind: :rectangle, w:, h:}    then w * h
  end
end

def parse_radius(s)
  r = Float(s, exception: false)
  r ? [:ok, r] : [:error, :invalid]
end
```

What carries over and what changes:

- The multiple function heads fold into one `case`/`in`. Ruby's
  hash patterns with key binding (`in {radius:}`) mirror
  Elixir's map patterns (`%{radius: r}`) almost exactly.
- The atom keys (`:circle`, `:ok`) become symbols, folded to
  `Constant<:circle>` / `Constant<:ok>` — the same singleton
  typing Elixir's atoms get.
- The `{:ok, r}` / `{:error, _}` tagged tuples become `[:ok, r]`
  / `[:error, _]` arrays, typed as a precise `Tuple` union and
  matched with `case`/`in`.
- If you add an `in` clause that can never match — say a second
  `:circle` arm — Rigor's `flow.unreachable-clause` flags it,
  the same warning Elixir would give you about an impossible
  clause.

## What's next

You probably do not need to read the rest of the handbook
sequentially. Useful pointers:

- [Chapter 3 — Narrowing](03-narrowing.md) for the flow rules —
  the analogue to guards and pattern-match narrowing.
- [Chapter 7 — RBS and `RBS::Extended`](07-rbs-and-extended.md)
  for the directive grammar — `predicate-if-true` is the
  user-defined guard analogue, the closest thing to teaching
  Rigor a custom `is_*` guard.
- [Protocols and structural typing](appendix-protocols-and-structural-typing.md)
  for how behaviours and protocols both map onto Rigor's single
  structural-interface mechanism.

If you want to compare against another tool, the sibling
appendix pages cover [TypeScript](appendix-typescript.md),
[PHPStan](appendix-phpstan.md), [mypy](appendix-mypy.md),
[Steep](appendix-steep.md), [TypeProf](appendix-typeprof.md),
[Java / C#](appendix-java-csharp.md), [Rust](appendix-rust.md),
and [Go](appendix-go.md).
