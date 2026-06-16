# ADR-68 — Plugin-declarable class-builder folding (member-shape carriers beyond Struct / Data)

Status: **Proposed — demand-gated.** Generalize the [ADR-48](48-data-struct-value-folding.md)
member-shape carrier substrate from the two hard-coded builders (`Struct.new` /
`Data.define`) to a **declared** family of Struct-like class builders, so a constant
assigned from a custom builder — faraday's `ConnectionOptions = Options.new(:a, :b, …)` —
types as a named member-shape class tied to the constant instead of falling to `Dynamic`.
Recognition is the only new mechanism; the carriers and folding tiers already exist.

Grounding: the 2026-06-16 protection-uplift pilot
([`docs/design/20260616-act-on-coverage-skill.md`](../design/20260616-act-on-coverage-skill.md)
— faraday's protection ceiling (~31%) is gated by `Options.new`-built constants
(`Env`/`ConnectionOptions`/`RequestOptions`/`ProxyOptions`) typing as dynamic class objects
Rigor cannot connect to the RBS namespace).

## Context

[ADR-48](48-data-struct-value-folding.md) folds `Foo = Struct.new(:x, :y)` /
`Point = Data.define(:x, :y)` to a member-shape class carrier (`Type::StructClass` /
`Type::DataClass`) tied to the constant via the cross-file `Scope#data_member_layouts`
side-table, recognised by the scope indexer's `data_define_call?` / Struct equivalent.
Member reads then fold (`Point.new(1, 2).x → Constant[1]`), precision-additive, no FP
surface. But the recognition is **hard-coded to the two core builders**.

Many libraries define their own Struct-like builder: faraday's `Options` (`ConnectionOptions
= Options.new(:request, :proxy, …)`), and the broad `Klass = SomeBase.new(*member_syms)`
idiom where `SomeBase < Struct` or mimics it. Those constants evaluate to a dynamically
built class Rigor does not fold, so the constant types `Dynamic`, every instance is
`Dynamic`, and every member/method call on it is unprotected — the pilot's faraday ceiling.
This is the **same member-shape shape** ADR-48 already solved, blocked only on *recognising*
a non-core builder. (It is distinct from the [ADR-26](26-activerecord-relation-typing.md)
Activeord case: an AR relation/model has an *unbounded* method surface — open receivers —
not a fixed member layout. That stays ADR-26's province; this ADR is for fixed-member
builders.)

## Decision

Make the qualifying-builder set **declarable**, reusing the ADR-48 substrate unchanged.

> **Criterion:** a constant (or subclass / local) assigned from a **declared** Struct-like
> class builder folds to an ADR-48 member-shape carrier tied to that constant, with members
> taken from the builder call's symbol arguments. The builder must be **declared** (a plugin
> contribution or a built-in allow-list) or **followed to a Struct-ancestor definition** —
> never guessed from an arbitrary `X = Y.new`, since a `.new` that does not return a class
> must not be misfolded. Precision-additive only: an unrecognised builder keeps today's
> `Dynamic` (ADR-48's no-FP-surface contract).

## Working decisions

- **WD1 — reuse the ADR-48 carriers and tiers; add only recognition.** No new carrier:
  the folded class is a `StructClass`/`DataClass`-family member-shape with a
  `data_member_layouts` entry. The sole new surface is *which builder calls qualify* —
  today a hard-coded `data_define_call?` predicate, generalised to a registry.
- **WD2 — plugin-declared builders via the ADR-16 substrate.** A plugin declares "a `.new`
  on builder `Options` with symbol arguments produces a Struct-like member class; members =
  the symbol args" (the [ADR-16](16-macro-expansion.md) macro/DSL recognition surface, the
  same place `data_define_call?` conceptually lives). faraday's `Options.new` is the first
  consumer (a `rigor-faraday` contribution). Bounds the feature: only a declared builder
  folds.
- **WD3 — inferred recognition by following the builder definition (deferred).** Recognise
  `Foo = Builder.new(*syms)` where `Builder` is itself a `Struct` subclass / an ADR-48-folded
  class, by following `Builder`'s own definition — so no per-builder declaration is needed.
  Budget- and soundness-gated (the builder may override `.new` to return something other than
  a member-shape instance); deferred behind WD2's declared route.
- **WD4 — compose with ADR-26 open receivers, do not re-derive.** A builder class often also
  mixes in dynamic methods (faraday `Options` adds helpers beyond its members). A folded
  builder class is **known** (concrete, protected) but MAY need the
  [ADR-26](26-activerecord-relation-typing.md) `open_receivers` undefined-method exemption so
  its dynamic surface does not fire `call.undefined-method`. Reuse that exemption; the two
  mechanisms compose (member folding for the declared members + open-receiver tolerance for
  the rest).
- **WD5 — precision-additive-only / mis-recognition guard.** Like ADR-48, no new diagnostic
  family. Only declared (WD2) or definition-followed (WD3) builders fold; an
  un-recognised `X = Y.new` stays `Dynamic` exactly as today, so a builder that does not in
  fact return a member-shape class can never be misfolded into one.

## Rejected / deferred alternatives

| Alternative | Verdict |
| --- | --- |
| A new carrier for custom builders | **Rejected** — reuse the ADR-48 `StructClass`/`DataClass` family + `data_member_layouts`; only recognition is missing. |
| Guess any `X = Y.new(*syms)` as a class builder | **Rejected** — a `.new` that does not return a class would misfold; recognition must be declared (WD2) or definition-followed (WD3). |
| Fold the ActiveRecord model/relation case here | **Out of scope** — that is an *open receiver* (unbounded method surface), not a fixed member layout; it stays [ADR-26](26-activerecord-relation-typing.md). |
| Inferred builder-following (WD3) before the declared route | **Deferred** — `.new` may be overridden to return a non-member value; the declared route (WD2) is the FP-safe first step. |

## Re-evaluation triggers

Demand-gated. Proceed when [ADR-63](63-type-protection-coverage.md) protection-coverage
surfaces a custom-builder constant as a recurring `add_a_type_here` ceiling (faraday is the
first), or when a `rigor-faraday` plugin is scoped.

## Consequences

- **Positive** — lifts the faraday-class protection ceiling by typing builder-defined
  constants as named member-shape classes; precision-additive, reusing a proven substrate;
  generalises ADR-48 to the whole Struct-like-builder family at the cost of one recognition
  registry.
- **Negative** — WD2 needs a per-builder declaration (a plugin), so it does not fold an
  undeclared in-house builder until WD3; the open-receiver composition (WD4) must be wired
  per builder that adds a dynamic surface.
- **Carry-over** — WD2 (declared, faraday) is the FP-safe first step; WD3 (definition-following)
  removes the per-builder declaration but carries the override-`.new` soundness question.

## Implementation note (scoping, 2026-06-16)

A pre-implementation dig pinned the extension point and the real crux, so the dedicated
session starts de-risked:

- **Extension point** — `Inference::ScopeIndexer#struct_new_call?` (`scope_indexer.rb` ~L2615)
  matches only the literal `Struct` receiver (`meta_constant_receiver?`). Add a *separate*
  `struct_builder_new_call?` — do NOT broaden the shared `struct_new_call?`, which also gates
  `record_meta_superclass_members` and the check-rules arity path — that accepts a
  `<Const>.new(*symbols)` whose receiver constant **transitively descends from `Struct`** via
  the `discovered_superclasses` map, and route it into `record_struct_member_layout` only.
  `meta_member_names` / `struct_new_keyword_init?` already work unchanged on such a call (the
  non-`Struct.new` branch keeps the symbol args and drops a trailing keyword hash by node
  type). FP-safe by construction: an unresolvable receiver does not fold (stays `Dynamic`).
  faraday is tractable — `class Options < Struct`; `ConnectionOptions = Options.new(:request, …)`.
- **The crux — cross-file builder folding needs a two-phase project pre-pass.** Layouts are
  built in two places: the per-file path (`merge_member_layouts`, which already has the
  *complete* cross-file `discovered_superclasses` from the project seed) and the project
  pre-pass (`accumulate_project_index` ~L2401, which accumulates `acc[:superclasses]`
  *incrementally* per file). A builder constant (`ConnectionOptions`) is **used across files**,
  so its layout must land in the cross-file seed the pre-pass builds — but the pre-pass may
  process the *use* file before the *definition* file (`Options < Struct`), leaving its
  superclass map incomplete when it folds. The sound fix is to split `accumulate_project_index`
  into two phases (accumulate all superclasses first, then compute builder layouts against the
  complete map), not to fold against the incremental map. Per-file-only folding gates green but
  yields ~no faraday win (cross-file usage dominates) — this two-phase restructure is the
  careful part and the real reason this is separate-session work. faraday baseline to beat:
  227/1066 (21.3%) protected.

## Relationship to other ADRs

- **ADR-48** — the carrier substrate this generalises; recognition is the only addition.
- **ADR-16** — the plugin/DSL recognition surface WD2's declaration rides on.
- **ADR-26** — the sibling dynamic-class case (open receivers); WD4 composes with its
  `undefined-method` exemption rather than re-deriving it.
- **ADR-63** — the protection pilot that surfaced faraday's builder-gated ceiling.
