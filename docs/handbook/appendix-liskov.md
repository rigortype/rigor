# Appendix — The Liskov Substitution Principle

A bridge between the **Liskov Substitution Principle (LSP)** — the
classical statement of what it *means* for one type to substitute
for another — and Rigor's design. The thesis of this page is small
and, once seen, hard to un-see:

> Rigor's robustness principle (Postel's law for types, strict on
> returns, lenient on parameters) **is** the LSP signature rule,
> reached from the opposite direction. LSP derives the
> wider-parameters / narrower-returns asymmetry *top-down* from
> "substitutability must preserve correctness." Rigor derives the
> identical asymmetry *bottom-up* from "minimise call-site friction
> and maximise downstream precision so Ruby programmers will
> actually run a type checker." Two motivations, one rule.

That convergence matters because it answers a worry a Ruby
programmer reasonably has about any type checker: *will this thing
fight my idioms?* The answer here is no — the discipline Rigor
quietly applies is the same discipline the Ruby community already
teaches under the "L" of SOLID, and the same one a careful duck-
typer follows by instinct.

> **A note on the acronym.** Everywhere else in this repository
> "LSP" means the **Language Server Protocol**
> ([ADR-19](../adr/19-language-server-packaging.md), `rigor lsp`).
> On *this* page, and only this page, "LSP" means the **Liskov
> Substitution Principle**. The collision is unfortunate and
> entirely conventional; the rest of the corpus keeps the
> language-server meaning.

This page is descriptive, not normative. When the language here
disagrees with the [type
specification](../type-specification/README.md), the spec binds.

## Five-second pitch

| LSP obligation | Ruby idiom that already honours it | Rigor surface |
| --- | --- | --- |
| A subtype may be substituted wherever the supertype is expected | Duck typing — "if it responds to the messages I send, I can use it" | Nominal-first typing + structural facets + capability roles |
| **Signature rule** — parameters contravariant, returns covariant | "Accept the widest thing you can use; return the most specific thing you can promise" | The **robustness principle** ([ADR-5](../adr/5-robustness-principle.md)) — lenient parameters (clause 2), strict returns (clause 1) |
| **Preconditions may not be strengthened** in a subtype | An override should not reject inputs the parent accepted | Clause 2: parameters widened to the largest correctness-preserving carrier |
| **Postconditions may not be weakened** in a subtype | An override should not return something less specific than the parent promised | Clause 1: returns tightened to the smallest correctness-preserving carrier; `def.return-type-mismatch` |
| **Invariants must be preserved**; **history constraint** | Don't add state transitions that break the parent's invariants; respect `freeze` | Mutation-effect model + fact stability + `frozen?` narrowing (partial; see § "Invariants") |
| Exception compatibility — no surprising new exceptions | Rescue what the contract documents | Internal exception/non-local-exit effect (not checked across overrides; see § "What Rigor does NOT check") |

## What LSP actually says

Barbara Liskov's 1987 OOPSLA keynote (*Data Abstraction and
Hierarchy*) stated the intuition:

> What is wanted here is something like the following substitution
> property: if for each object `o1` of type `S` there is an object
> `o2` of type `T` such that for all programs `P` defined in terms
> of `T`, the behavior of `P` is unchanged when `o1` is substituted
> for `o2`, then `S` is a subtype of `T`.

**Liskov & Wing 1994** (*A Behavioral Notion of Subtyping*, ACM
TOPLAS) made it precise. Behavioral subtyping `S <: T` requires two
groups of conditions:

### The signature rule

For every method the subtype shares with the supertype:

- **Contravariant parameters** — the subtype's method must accept
  *at least* every argument type the supertype's accepted (it may
  accept more).
- **Covariant return** — the subtype's method must return *at most*
  the supertype's return type (it may return something more
  specific).
- **Exception rule** — the subtype's method may raise *fewer*
  exception types than the supertype's, never new ones.

### The behavioral (methods) rule

Beyond signatures, the *behaviour* must be compatible — this is the
part most signature-only type checkers do not encode:

- **Preconditions may not be strengthened.** A subtype's method may
  require *no more* of its caller than the supertype's did.
- **Postconditions may not be weakened.** A subtype's method must
  guarantee *at least* what the supertype's did.
- **Invariants must be preserved.** Properties true of every
  supertype instance stay true of every subtype instance.
- **History constraint.** The subtype may not permit state changes
  that the supertype's specification forbids over an object's
  lifetime (the rule that rules out, e.g., a mutable `Point`
  subtyping an immutable one).

The behavioral rule is the **Design-by-Contract** inheritance
discipline (Bertrand Meyer, Eiffel) stated as a subtyping law:
`require` clauses weaken down the hierarchy, `ensure` clauses
strengthen, `invariant` clauses accumulate.

## LSP is about behaviour, not static types

A claim surfaces occasionally: *"Ruby is dynamically typed, so LSP
is a static-typing rule that does not strictly apply."* This gets
the principle backwards, and it is worth saying why plainly.

LSP is not a rule *about* type checkers. It is a rule about
**observable behaviour under substitution** — Liskov's own framing
quantifies over "all programs `P` defined in terms of `T`" and asks
that their *behaviour* be unchanged when an `S` is substituted. The
1994 paper's title is deliberate: *A **Behavioral** Notion of
Subtyping*. The signature rule is only the type-system-shaped half;
the load-bearing half is the behavioral rule — preconditions,
postconditions, invariants, history — and those are statements about
what code *does at runtime*, not about what a compiler accepts.

That behavioral focus is exactly what makes LSP **more** applicable
to a language like Ruby, not less:

- In a nominally-typed language a compiler enforces the signature
  half for you, so LSP feels like "a thing the type checker already
  did." The interesting, un-automated part is the behavioral half.
- In Ruby there is no compiler enforcing *either* half — so the
  *entire* principle, signature and behaviour both, is a discipline
  the programmer carries. "Subtype" in Ruby is defined by
  substitutability of *messages and behaviour* (duck typing), which
  is precisely the relation LSP is stated over. A language that is
  hard to formalise is the case where a behavioural substitutability
  discipline earns the most — it is the only safety net available
  when a static one is not.

So "Ruby is not statically typed" is an argument *for* taking LSP
seriously, not against. LSP is the tool that lets you reason about
the *behavioural* safety of substitution in a language whose shape a
classical type system cannot fully capture. Every working
duck-typed Ruby program already depends on something LSP-shaped
holding — the caller assumes the object it received behaves
compatibly with the contract it was written against.

### Rigor's relationship to this

Rigor does **not** provide a direct *static guarantee* that a
program obeys LSP. It does not prove behavioral subtyping, does not
check cross-hierarchy override compatibility, and does not verify
pre/postcondition contracts (§ "What Rigor does NOT check"). On that
narrow reading, "Rigor is not an LSP checker" is true.

But the *ideas* have substantial common ground, and that is the
point of this whole appendix. Rigor's design is steered by the same
behavioural-substitutability instinct LSP formalises:

- The robustness principle infers the LSP-correct signature shape
  (wide parameters, narrow returns) by default (§ next).
- Capability roles model substitutability the way duck typing does —
  by behaviour (messages answered), not by nominal identity.
- The mutation-effect and fact-stability model refuses to keep
  trusting a property a state change could have broken — the
  history-constraint instinct, applied locally.

Rigor is therefore best read as *tooling that shares LSP's
behavioural worldview and mechanises the parts of it that are
statically provable in Ruby*, while leaving the rest as the
discipline it has always been. The principle and the tool are
aligned in spirit even where the tool stops short of a proof.

## The signature rule is Rigor's robustness principle

This is the heart of the page. Lay the two rules side by side:

| Position | LSP signature rule | Rigor robustness principle |
| --- | --- | --- |
| Parameters | **Contravariant** — accept at least as much as the supertype | **Lenient** (clause 2) — widest correctness-preserving carrier |
| Returns | **Covariant** — return at most what the supertype promised | **Strict** (clause 1) — smallest correctness-preserving carrier |

They are the same asymmetry. What differs is *why* each system
reaches for it.

**LSP's derivation is top-down.** Start from "an `S` must be usable
anywhere a `T` is expected." A caller written against `T` may pass
any `T`-typed argument, so `S`'s method must accept all of them —
parameters can only widen. A caller written against `T` will use
the result as a `T`, so `S`'s method must return something every
`T`-context can consume — returns can only narrow. The asymmetry
*falls out* of substitutability; it is not chosen.

**Rigor's derivation is bottom-up.** ADR-5 starts from a Ruby-
adoption problem, not a substitutability proof
([`robustness-principle.md`](../type-specification/robustness-principle.md)):

- An over-strict **parameter** type forces callers to paste
  defensive coercions (`x.to_s`, `x || ""`, `Array(x)`) at every
  call site. The workarounds become load-bearing and hide intent.
  So Rigor widens parameters to "anything the body can actually
  use" — capability roles, structural interfaces, supertypes.
- An over-wide **return** type discards precision every downstream
  consumer needs. `Array#size` typed `Integer` rather than
  `non-negative-int` collapses every later `if size > 0`. So Rigor
  tightens returns to "the most specific thing the body provably
  produces."

Two completely different starting points — a 1994 substitutability
theorem and a 2020s "please don't make Ruby programmers write
`.to_s` everywhere" ergonomics concern — and they land on the
*identical* rule. That convergence is the reassurance: Rigor's
pragmatic, Ruby-first defaults are not a departure from classical
OO type discipline. They re-derive it.

```ruby
# Clause 2 / contravariant parameters: the body uses only #upcase,
# so the parameter widens to "anything that responds to upcase",
# not the nominal String. An override that accepted String only
# would be *strengthening* the precondition — an LSP violation,
# and exactly the over-strict shape clause 2 steers away from.
def shout(thing)
  thing.upcase
end

# Clause 1 / covariant returns: the body provably returns the
# receiver, so #dup returns `self` (Array, not the widened Object).
# Returning Object would *weaken* the postcondition.
copy = [1, 2, 3].dup
assert_type("Array", copy)
```

The connection to the type-theory appendix's **gradual guarantee**
([§ "Blame, the gradual guarantee, and trust
boundaries"](appendix-type-theory.md)) is direct: a system that
honours the signature rule by construction also satisfies "adding
an annotation never breaks a previously-passing call site," because
a correctly-widened parameter and a correctly-narrowed return are
precisely the annotations that preserve substitutability.

## Variance and the signature rule

The signature rule *is* a statement about variance, and Rigor
inherits RBS's variance vocabulary
([§ "Variance"](appendix-type-theory.md#variance) in the
type-theory appendix):

- **Covariant (`out T`)** — producer position; the return side of
  the signature rule.
- **Contravariant (`in T`)** — consumer position; the parameter
  side of the signature rule.
- **Invariant** — both at once; mutable storage.

Ruby's mutable containers (`Array`, `Hash`, `Set`) are **invariant**
in their element type, and this is the canonical place LSP and a
naive intuition collide. The "obvious" idea that `Array[Integer]`
should substitute for `Array[Numeric]` is *unsound* the moment a
caller writes `arr.push(1.5)` — the classic
covariant-arrays-are-broken cautionary tale (Java's `ArrayStoreException`).
RBS declares these containers invariant; Rigor honours the
declaration and so never offers the unsound substitution. The
signature rule, applied to the *mutating* methods (`push` takes the
element in a contravariant position; `[]` returns it in a covariant
one), forces invariance — and Rigor gets this for free by trusting
RBS rather than re-deriving variance.

**Self types** are the signature rule's covariant-return case made
load-bearing for OO Ruby. RBS's `self` keyword (`def dup: () ->
self`) means "I return *my own* class," so a subtype's inherited
method returns the subtype — covariant return, honoured
automatically. See [§ "F-bounded polymorphism and self
types"](appendix-type-theory.md#f-bounded-polymorphism-and-self-types)
for the deeper treatment; the LSP reading is just that `self` is the
mechanism that keeps `Sub#dup` returning `Sub`, never widening back
to the ancestor and thereby weakening the postcondition.

## Preconditions: contravariant parameters and duck typing

The behavioral rule "**preconditions may not be strengthened**" is,
in Ruby, almost a restatement of duck typing. A Ruby method does not
declare what *class* it wants; it declares what *messages* it sends.
Any object answering those messages is substitutable — which is
exactly "do not require more of the caller than necessary."

Rigor encodes this with **capability roles** and structural
interfaces (the clause-2 toolbox):

| Body uses | Over-strict (strengthened precondition) | Clause-2 / LSP-friendly |
| --- | --- | --- |
| only `#write` | `IO` | `_Writable` (StringIO, Tempfile, mocks all qualify) |
| only `#upcase` | `String` | a `#upcase`-bearing role |
| `+`, `-`, `<=>` | `Integer` | `Numeric` |
| `#to_s`, nil-guarded | `String` | `String \| nil` (body narrows) |

```ruby
# A subtype override that *narrowed* its parameter to IO would
# strengthen the precondition and break substitutability. Rigor's
# inferred parameter for the parent is already _Writable, so the
# LSP-honouring override is also the one Rigor infers by default.
def dump(stream)
  stream.write(serialize)
end
```

The **open-world assumption** on `Dynamic[T]` /
`respond_to?`-narrowed receivers
([§ "Open-world vs closed-world"](appendix-type-theory.md#open-world-vs-closed-world-assumption))
is the same instinct at the call site: Rigor does not assume it
knows the full method set of a dynamic value, so it does not
manufacture a precondition ("this exact class") the runtime never
required. Strengthening the precondition would mean firing a false
positive on working duck-typed code — which collides head-on with
the project's [false-positive
discipline](../adr/8-steep-inspired-improvements.md). LSP and "never
frighten working code" point the same way.

## Postconditions: covariant returns and `self` types

"**Postconditions may not be weakened**" is clause 1, and it has a
concrete enforcement surface: **`def.return-type-mismatch`**
([ADR-8](../adr/8-steep-inspired-improvements.md)). When a method
carries a declared RBS return type and the body's inferred type
*cannot satisfy* it, Rigor emits an error:

```ruby
class Repo
  # RBS:  def find: (Integer) -> User
  def find(id)
    @cache[id]   # inferred: User | nil
  end
  # def.return-type-mismatch — the body can return nil, which
  # weakens the declared "-> User" postcondition.
end
```

This is the postcondition rule applied to a single method against
its *own* declared contract. Note the scope precisely (it matters
for the next section): `def.return-type-mismatch` checks the body
against the method's **own** RBS signature, not against a
superclass's signature. The complementary check — comparing a
subtype's override against the supertype's declared return to verify
covariance across the hierarchy — shipped in v0.1.15 as the
`def.override-*` rule family (§ "Cross-hierarchy override
compatibility" below). The robustness principle keeps each
*individually authored* signature honest; the override family then
verifies that the authored child contract substitutes for the
authored parent contract.

The covariant-return half is also why **self types** earn their
keep here, mirrored from the variance section: `def dup: () -> self`
guarantees a subtype's inherited `dup` keeps returning the subtype.
A signature that widened `dup`'s return to `Object` in a subtype
would weaken the postcondition; `self` makes the LSP-correct
behaviour the *only* behaviour expressible.

## Invariants and the history constraint

The third and fourth behavioral rules — **invariants preserved** and
the **history constraint** — are where Rigor's coverage is genuinely
*partial*, and it is worth being precise about what is and is not
modelled.

Rigor has an internal **effect model**
([§ "Effect systems"](appendix-type-theory.md#effect-systems)) that
tracks mutation, non-local exit, and closure escape. The
user-visible consequences relevant to invariants:

- **Mutation invalidates narrowing (fact stability).** A narrowed
  fact about a variable is dropped after a mutating call, because
  the mutation might have broken the property the narrowing relied
  on. This is the *local, within-a-method* analogue of "an
  invariant must survive every operation" — Rigor refuses to keep
  trusting a fact a mutation could have falsified.
- **`frozen?` narrowing.** Rigor narrows on `frozen?`, and a frozen
  object is one whose state-history is closed — the strongest form
  of the history constraint Ruby offers. Immutable value objects
  (`Data.define`, frozen literals) are the idiom that satisfies the
  history constraint by construction, and Rigor types them
  precisely.

What Rigor does **not** do: it does not verify, across a class
hierarchy, that a subtype's added methods preserve a supertype's
declared invariant, nor does it enforce the Liskov-Wing history
constraint as a subtyping check (the rule that forbids a mutable
`Point` from subtyping an immutable `Point`). Ruby has no surface
for declaring such invariants, and inferring them is well outside
the AST-walking, no-false-positives envelope. The history-constraint
*spirit* is honoured operationally (fact stability, `frozen?`); the
*subtyping check* is not implemented.

## Behavioral vs nominal subtyping in Ruby

LSP is a statement about **behavioral** subtyping, but Ruby's
runtime dispatch is **nominal-and-mixin**: `is_a?` consults the
ancestor chain, and `Comparable` / `Enumerable` are behavioral
contracts delivered *through* a nominal mixin (include the module,
implement the one required method, inherit the rest). Ruby thus
blends the two — nominal inheritance for identity, module mixins for
shared behaviour.

Rigor's **nominal-first-with-structural-facets** stance
([§ "Nominal vs structural typing"](appendix-type-theory.md#nominal-vs-structural-typing))
matches this exactly:

- Nominal classes are the unit of modelling and the stable
  attachment point for declared contracts.
- `interface _Comparable`-style structural shapes and capability
  roles capture the behavioral, duck-typed substitutability that
  pure nominal subtyping misses.

The Ruby community already teaches LSP without the type theory.
Sandi Metz's *Practical Object-Oriented Design in Ruby* frames the
"L" of SOLID as: **subclasses should be substitutable for their
superclasses**, and the practical test is that callers written
against the superclass keep working unchanged. That is Liskov's 1987
sentence in plain Ruby. Rigor's contribution is to make the
*signature half* of that discipline machine-checkable — and to do so
without asking the programmer to write a single annotation, because
the robustness principle infers the LSP-correct parameter and return
shapes automatically.

## Where Ruby lets you violate LSP — and what Rigor does

Ruby imposes **no** static override discipline. You can override a
method with a different arity, a narrower parameter, an unrelated
return, or a brand-new exception, and the interpreter will not
complain until (and unless) a runtime path hits the incompatibility.
Every one of these is a potential LSP violation:

```ruby
class Animal
  def speak(volume) = "..." * volume
end

class Mute < Animal
  def speak              # arity narrowed: strengthened precondition
    raise NotImplementedError   # new exception: exception-rule violation
  end
end
```

A *sound* checker would flag the override. Rigor, by its
[no-false-positives stance](../adr/8-steep-inspired-improvements.md),
does **not** bark at every override — because in Ruby, overriding
with a changed shape is frequently *intentional and correct*
(template-method refinements, `method_missing`, DSL-driven
redefinition, `define_method`). Treating every shape change as an
LSP error would frighten enormous amounts of working code.

Instead Rigor fires only where it can *prove* a contract is broken:

- `call.argument-type-mismatch` when a call site provably passes
  something a declared parameter cannot accept.
- `def.return-type-mismatch` when a body provably cannot produce its
  *own declared* return.

Both are local proofs against an authored contract, never a
speculative cross-hierarchy substitutability judgment. This is the
LSP-pragmatic position: enforce the parts you can prove, infer the
LSP-correct shape everywhere you author one, and stay silent on the
override-compatibility question that Ruby idioms routinely and
legitimately blur.

The deeper point: because the robustness principle *infers*
wide parameters and narrow returns by default, the most common
LSP-correct design is also the *path of least resistance* under
Rigor. A programmer following Rigor's inferred shapes is, without
trying, writing overrides that don't strengthen preconditions or
weaken postconditions. Rigor nudges toward LSP compliance through
its defaults rather than policing it through diagnostics.

## Cross-hierarchy override compatibility

Since v0.1.15 ([ADR-35](../adr/35-override-signature-compatibility.md)),
Rigor *does* compare an override against the contract it inherits —
the signature rule applied across a project-defined class/module
hierarchy. Three rules make up the `def.override-*` family:

- **`def.override-param-narrowed`** — parameter contravariance: an
  override may not strengthen its precondition by narrowing a
  parameter type.
- **`def.override-return-widened`** — return covariance: an override
  may not weaken its postcondition by widening a return type.
- **`def.override-visibility-reduced`** — an override may not reduce
  inherited visibility (public → protected/private).

The family is the load-bearing-discipline counterpart to the
robustness principle: where the principle *biases inferred*
signatures toward substitutability, these rules *verify authored*
ones. They are gated for false-positive discipline — both the
override and the shadowed ancestor must carry an authored signature
(hand-written / rbs-inline / bundled RBS; inference-only either side
stays silent), only a proven (`:no`) violation fires, and severity
maps through `severity_profile:` (`lenient` → off, `balanced` →
warning, `strict` → error). The ancestor scope is the superclass
chain plus included/prepended modules, resolved cross-file.

The escape hatch for a *legitimate* specialization that looks like a
narrowing is **generics first, not suppression**: declare the parent
with a bounded type parameter (`interface _Consumer[T < Message]`)
and have the subtype bind it (`include _Consumer[SendMailMessage]`),
so the override matches the *instantiated* contract — the same
resolution PHPStan reaches for in [*Generics in PHP using
PHPDocs*](https://medium.com/@ondrejmirtes/generics-in-php-using-phpdocs-14e7301953)
("even Barbara Liskov is happy with it"). Second is keeping the
declared parameter wide and recovering the narrow type in the body
via occurrence typing; `# rigor:disable def.override-*` is the last
resort.

## What Rigor does NOT check (LSP-wise)

For completeness, the LSP obligations Rigor does **not** statically
enforce in v0.1.x — named here so you can stop looking:

- **The inferred-side of cross-hierarchy override compatibility.**
  The shipped `def.override-*` family (§ "Cross-hierarchy override
  compatibility" above) gates on *both sides carrying an authored
  signature*. The complementary case — checking a child's *inferred*
  return against an authored parent return ([ADR-35](../adr/35-override-signature-compatibility.md)
  slice 5) — plus RBS-only-ancestor reach and singleton (`def self.`)
  method coverage remain deferred (demand-driven, higher
  false-positive surface).
- **Exception compatibility.** The signature rule's "no new
  exceptions in a subtype" is not checked. Rigor has an internal
  exception/non-local-exit effect
  ([§ "Effect systems"](appendix-type-theory.md#effect-systems))
  but does not surface a `raise`-set per method or compare it across
  overrides. RBS has no widely-used `raises` clause to check
  against.
- **Behavioral pre/postcondition formulas (Design by Contract).**
  Meyer-style `require` / `ensure` predicate contracts, and their
  inheritance rules, have no Rigor surface. The closest analogues
  are refinement carriers (`non-empty-string`, `positive-int`, …) at
  the *type* level and `RBS::Extended` predicate directives — neither
  is a general contract formula.
- **The history constraint as a subtyping check.** Honoured
  operationally via fact stability + `frozen?` (§ "Invariants"); not
  enforced as a hierarchy-level rule.
- **Invariant inference across a class hierarchy.** No declaration
  surface, outside the AST-walking envelope.

If any of these becomes important to the user base, it will be
discussed in an ADR before any implementation slice — the same
discipline the type-theory appendix's [§ "What Rigor does NOT
model"](appendix-type-theory.md#what-rigor-does-not-model) records.

## A short reading list

- Liskov, B. "Data Abstraction and Hierarchy." *OOPSLA '87
  Addendum / SIGPLAN Notices*, 1988. The keynote that stated the
  substitution intuition.
- Liskov, B. & Wing, J.M. "A Behavioral Notion of Subtyping." *ACM
  TOPLAS*, 1994. The precise formulation — signature rule + the
  pre/postcondition/invariant/history behavioral rules. The
  reference for everything on this page.
- Meyer, B. *Object-Oriented Software Construction*, 2nd ed.
  Prentice Hall, 1997. Design by Contract and the inheritance rules
  for `require` / `ensure` / `invariant` — the behavioral rule
  stated as a contract discipline.
- Cardelli, L. & Wegner, P. "On Understanding Types, Data
  Abstraction, and Polymorphism." *ACM Computing Surveys*, 1985. The
  variance and subtyping vocabulary the signature rule is phrased
  in.
- Metz, S. *Practical Object-Oriented Design in Ruby* (POODR).
  Addison-Wesley, 2nd ed. 2018. The Ruby-community statement of the
  "L" in SOLID — substitutability as a practical design test,
  no type theory required.
- See also the companion [§ "Robustness principle (Postel's law for
  types)"](../type-specification/robustness-principle.md) (normative)
  and [ADR-5](../adr/5-robustness-principle.md) (rationale) — the
  Rigor surface this page maps LSP onto.

## What's next

- [Appendix — Connections to type theory](appendix-type-theory.md)
  for the formal scaffolding this page leans on — variance, the
  gradual guarantee, self types / F-bounded polymorphism, the
  soundness vs completeness trade-off.
- [Chapter 6 — Classes](06-classes.md) for instance-side vs
  class-side typing, `self`, and `Data.define` — the OO surface LSP
  is about.
- [Chapter 7 — RBS and `RBS::Extended`](07-rbs-and-extended.md) for
  authoring the declared contracts `def.return-type-mismatch` checks
  against.
- [Chapter 8 — Understanding errors](08-understanding-errors.md) for
  the `def.return-type-mismatch` / `call.argument-type-mismatch`
  rules and severity profiles.

If you want to compare against another *tool* rather than the
*principle*, the sibling appendices cover
[TypeScript](appendix-typescript.md),
[PHPStan](appendix-phpstan.md),
[mypy / Pyright](appendix-mypy.md),
and [Steep](appendix-steep.md).
