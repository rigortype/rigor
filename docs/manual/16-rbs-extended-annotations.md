# RBS::Extended annotations

Plain RBS can say a method returns a `String`. It cannot say it
returns a *non-empty* string, that a predicate narrows its
argument on the true branch, or that a class is meant to satisfy
a structural interface as a checked contract. Rigor reads that
extra information from **`RBS::Extended` annotations** — ordinary
RBS `%a{...}` annotations under a reserved `rigor:v1:` key — so
you can sharpen a signature without leaving RBS and without
breaking any other RBS tool, which preserves or ignores
the annotation.

You write these in your `*.rbs` files, on the method or class
declaration they refine:

```rbs
%a{rigor:v1:return: non-empty-string}
def read_name: () -> String
```

The plain `() -> String` stays the compatibility contract; the
annotation tells Rigor the return is a non-empty string.

You may also write any of them **in a `.rb` file**, as an
rbs-inline `# @rbs %a{…}` comment — `%a{}` is rbs-inline's own
upstream grammar, and the annotation reaches Rigor on the same
path the generated signature does:

```rb
# rbs_inline: enabled

class Reader
  # @rbs %a{rigor:v1:return: non-empty-string}
  # @rbs return: String
  def read_name = "x"
end
```

This needs the `rbs-inline` library installed; Rigor ingests
inline annotations by default when it is
([ADR-93](../adr/93-default-rbs-inline-ingestion.md)). There is
no Rigor-only comment dialect: `# rigor:` comments remain
suppression-only.
This page is the *operational* reference — the directives you can
write and their syntax. For the normative rules (conflict
handling, merging, provenance) see
[`docs/type-specification/rbs-extended.md`](../type-specification/rbs-extended.md);
for the type-model walkthrough see
[handbook chapter 7](../handbook/07-rbs-and-extended.md).

## Per-method directives

Each directive is one `%a{rigor:v1:<directive> …}` annotation
written immediately above the `def` it applies to. Multiple
directives may stack on one method; they compose independently of
order.

| Directive | Effect |
| --- | --- |
| `rigor:v1:return: T` | Override the RBS-declared return type with `T` at every call site. |
| `rigor:v1:param: name [is] T` | Tighten parameter `name` to `T` — both at overload selection / argument checks *and* inside the method body during inference. The `is` glue word is optional. |
| `rigor:v1:predicate-if-true target is T` | Refine `target` to `T` on the **true** branch when the call is used as a condition. |
| `rigor:v1:predicate-if-false target is T` | Refine `target` to `T` on the **false** branch. |
| `rigor:v1:assert target is T` | Refine `target` after the method returns normally. |
| `rigor:v1:assert-if-true target is T` | Refine `target` when the method returns a truthy value. |
| `rigor:v1:assert-if-false target is T` | Refine `target` when the method returns `false` or `nil`. |

`target` is an RBS *parameter name* from the method's own
signature, or the literal `self`. To refer to an argument, the
RBS method type must name it (`(untyped value)`, not `(untyped)`).

### Predicates — narrowing through a guard

A predicate teaches Rigor to narrow a variable across the
branches of a method that tests it — the equivalent of
TypeScript's type guards or Python's `TypeGuard` / `TypeIs`. A
true-branch fact alone is enough for `TypeGuard`-style narrowing;
supplying both branches gives `TypeIs`-style narrowing.

```rbs
%a{rigor:v1:predicate-if-true value is String}
%a{rigor:v1:predicate-if-false value is ~String}
def string?: (untyped value) -> bool

%a{rigor:v1:predicate-if-true self is LoggedInUser}
def logged_in?: () -> bool
```

After `if string?(x)`, Rigor types `x` as `String` in the `then`
branch; in the `else` branch the `~String` negative fact removes
`String` from its type.

### Assertions — narrowing after a call

An assertion narrows a variable *after* the call returns, the way
PHPStan models `assert`-style helpers. Use `assert` for a method
that raises unless the fact holds, and `assert-if-true` /
`assert-if-false` for a method whose return value carries the
fact.

```rbs
%a{rigor:v1:assert value is String}
def assert_string!: (untyped value) -> void

%a{rigor:v1:assert-if-true value is String}
def valid_string?: (untyped value) -> bool
```

After `assert_string!(x)` returns, `x` is `String` for the rest
of the scope.

## The payload type grammar

The right-hand side of `return:`, `param:`, `assert*`, and
`predicate-if-*` accepts either:

- an **RBS class name** — `String`, `::Foo::Bar`; or
- a **refinement payload** — a kebab-case name from the
  imported-built-in catalogue
  ([`imported-built-in-types.md`](../type-specification/imported-built-in-types.md)),
  such as `non-empty-string` or `positive-int`.

Refinement payloads support the parameterised forms
`non-empty-array[Integer]`, `non-empty-hash[Symbol, Integer]`,
and the bounded-integer form `int<min, max>`. Type-argument
positions also accept Symbol / String literal tokens and unions
of them — `pick_of[T, :name | :email]`,
`Pick[T, "name" | "email"]` — each lifted to a `Constant<value>`.

Negation with `~T` is allowed on **class-name** payloads (it is
how the false branch of a predicate is usually written); it is
**not** yet accepted on refinement-form payloads. For an explicit
user-authored difference type, prefer `T - U` (see
[type-operators.md](../type-specification/type-operators.md)).

## `conforms-to` — a checked structural contract

Rigor checks structural compatibility implicitly wherever a value
flows into a position that needs an interface. The `conforms-to`
directive makes that contract *explicit and always-checked* on a
class, regardless of whether any call site currently exercises it
— useful when a library wants its structural contract to be a
design assertion:

```rbs
%a{rigor:v1:conforms-to _RewindableStream}
class MyBuffer
end
```

If the class is missing a method the interface requires, Rigor
fires
[`rbs_extended.unsatisfied-conformance`](04-diagnostics.md#rule-rbs_extended-unsatisfied-conformance);
a satisfied directive is silent. Multiple `conforms-to`
directives on one class combine like an intersection of
interfaces. The directive is purely additive — a class that
already satisfies the interface type-checks with or without it.

## Effect envelopes — bounding what a method *does*

Every directive above describes what a method returns. Two
describe what it *does*: `%a{pure}` — rbs' own purity
annotation, read as "nothing at all" — and
`%a{rigor:v1:effect <labels>}`, a comma-separated list of bare
[effect labels](19-effect-labels.md) the
method may not exceed. Both attach to a method or to a `class` /
`module`, where they distribute to that class's own methods
(nearest wins), and both tolerate mutating objects the method
itself allocated and never let out:

```rbs
class UserRepository
  %a{rigor:v1:effect io.db, nondet.time}
  def find: (Integer) -> User

  %a{pure}
  def slug: (String) -> String
end
```

The same two work as rbs-inline comments in a `.rb` file:

```rb
# rbs_inline: enabled

class UserRepository
  # @rbs %a{rigor:v1:effect io.db}
  # @rbs id: Integer
  # @rbs return: User
  def find(id) = User.find(id)

  # @rbs %a{pure}
  # @rbs return: String
  def slug(s) = s.strip.downcase
end
```

Three things follow, and all three need an `effects:` block in
`.rigor.yml` — an annotation alone never turns effect collection
on:

- A method whose proven effects escape its bound fires
  [`effect.envelope-exceeded`](04-diagnostics.md#rule-effect-envelope-exceeded),
  positioned at the Ruby `def`.
- A label the registry does not recognise makes the **whole
  annotation** read as unbounded — a typo can never manufacture
  a finding — and, where the spelling is evidently meant to be a
  label, says so as
  [`effect.unknown-label`](04-diagnostics.md#rule-effect-unknown-label)
  at the declaration.
- Without the block, one
  [`effect.annotations-unchecked`](04-diagnostics.md#rule-effect-annotations-unchecked)
  `:info` per run tells you the annotations are inert — from either
  lane, with one exception: a run that analyses **no file at all**
  (a warm `rigor check --incremental` with nothing changed) has no
  synthesised RBS to read, so it reports a `.rbs` annotation and not
  an inline one. Any run that analyses something reports both.

Two practical notes. Annotating one method in a `.rbs` file forces you to
declare its whole signature — RBS has no way to annotate a method it does
not declare — while the rbs-inline form above does not, so prefer the
inline lane when the bound is all you want. And an envelope is checked
against the **proven** lane only: a method whose labels all sit in the
declared (`≤`) lane passes `%a{pure}` in silence.
[Effect labels](19-effect-labels.md) covers both, with the vocabulary
these annotations draw from.

## Higher-kinded type directives

Two declaration-level directives register and define the
defunctionalised type constructors behind Rigor's lightweight HKT
mechanism ([ADR-20](../adr/20-lightweight-hkt.md)). Unlike the
per-method directives they attach to a `class` / `module` and
take **space-separated `key=value` pairs** (RBS's annotation
grammar does not accept nested punctuation):

| Directive | Effect |
| --- | --- |
| `rigor:v1:hkt_register: uri=<uri> arity=<int> variance=<v1>,… bound=<class\|untyped>` | Register a type-constructor URI with its arity, per-position variance, and erasure bound. |
| `rigor:v1:hkt_define: uri=<uri> params=<P1>,… body=<body-text>` | Bind the URI to a type-function body; `body=` consumes the rest of the payload and is parsed into a union tree. |

```rbs
%a{rigor:v1:hkt_register: uri=json::value arity=1 variance=out bound=untyped}
%a{rigor:v1:hkt_define: uri=json::value params=K
   body=nil | true | false | Integer | Float | String |
        Array[App[json::value, K]] | Hash[K, App[json::value, K]]}
module JsonOverlay
end
```

This is an advanced authoring surface; the worked walkthrough is
[handbook chapter 12](../handbook/12-lightweight-hkt.md).

## Authoring rules

- The plain RBS signature is always the compatibility contract;
  annotations only refine or explain it.
- Always use the explicit, versioned `rigor:v1:` prefix. An
  unversioned `rigor:` directive is invalid.
- Multiple annotations on one node are interpreted independently
  of source order; exact duplicates are idempotent.
- A directive that **conflicts** with the RBS signature, or two
  contradictory directives on the same target and flow edge, are
  reported as diagnostics — Rigor never silently picks a winner.
- Annotations under unrelated keys belong to other tools; Rigor
  preserves them untouched. Conversely, exported plain RBS
  ([RBS erasure](../type-specification/rbs-erasure.md)) drops
  Rigor-only annotations unless you ask to keep them.

## See also

- [`docs/type-specification/rbs-extended.md`](../type-specification/rbs-extended.md)
  — the normative grammar and merging rules.
- [`imported-built-in-types.md`](../type-specification/imported-built-in-types.md)
  — the reserved refinement-name catalogue.
- [handbook chapter 7](../handbook/07-rbs-and-extended.md) — the
  type-model walkthrough.
- [Inspecting inferred types](05-inspecting-types.md) — the
  `assert_type` / `dump_type` source helpers, the Ruby-side
  counterpart to these RBS-side annotations.
