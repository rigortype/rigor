# The Rigor Handbook

A walkthrough of Rigor's type model written for Ruby
programmers — no prior static-typing background assumed. Read
top to bottom for the first pass; come back to individual
chapters for reference once you know what you are looking for.

## Who this is for

You write Ruby for a living, you have run into a `NoMethodError`
on `nil` more than once, and you want to know:

- What does `rigor check` actually look at?
- Why did it flag this expression — or, more often, why
  didn't it flag the one I expected it to?
- When inference falls short, how do I push it further
  without writing annotations all over my `.rb` files?

The handbook answers those questions. It does **not** try to
replace the [normative type
specification](../type-specification/README.md) — that lives
in `docs/type-specification/` and is the binding source when
this handbook disagrees.

Operational topics — installation, the CLI command reference,
configuration keys, baselines, CI — live in the
[User Manual](../manual/README.md). Reach for this handbook to
understand what a type *means*; reach for the manual to look
up the flag, key, or command that *acts* on it.

## Table of contents

1. [**Getting started**](01-getting-started.md) — running
   `rigor check`, reading diagnostics, the "no annotations
   needed" stance.
2. [**Everyday types**](02-everyday-types.md) — the carrier
   zoo. Constants, integer ranges, refinements, unions,
   `Dynamic[Top]`. The shortest path to "now I see what
   Rigor sees."
3. [**Narrowing**](03-narrowing.md) — how `if`, `case`, and
   predicate methods sharpen a variable's type along the
   branch.
4. [**Tuples and hash shapes**](04-tuples-and-shapes.md) — the
   structural carriers Ruby's `[a, b, c]` literals and
   `{key: value}` hashes get when Rigor can prove their layout.
   Includes the **shape-projection functions** (`pick_of` /
   `omit_of` / `partial_of` / `required_of` / `readonly_of`)
   that mirror TypeScript's `Pick` / `Omit` / `Partial` /
   `Required` / `Readonly` utility types.
5. [**Methods and blocks**](05-methods-and-blocks.md) — argument
   typing, return-type inference, block parameters, arity.
6. [**Classes**](06-classes.md) — instance-side vs class-side,
   `self`, `attr_accessor`, `Data.define`.
7. [**RBS and RBS::Extended**](07-rbs-and-extended.md) — when
   inference cannot prove what the runtime actually returns,
   how to nudge it through `.rbs` files and `%a{rigor:v1:…}`
   directives.
8. [**Understanding errors**](08-understanding-errors.md) —
   the rule catalogue (`call.undefined-method`,
   `call.argument-type-mismatch`, `flow.always-raises`, …),
   severity profiles, and `# rigor:disable` suppression.
9. [**Plugins**](09-plugins.md) — when to author one,
   pointer to the [examples/](../../examples/README.md)
   landing page.
10. [**Coexisting with Sorbet**](10-sorbet.md) — for users
    arriving from a Sorbet-using project: the
    [`rigor-sorbet`](../../plugins/rigor-sorbet/) adapter
    reads `sig { ... }` blocks, RBI files, and
    `T.let` / `T.cast` / `T.must` / `T.unsafe` assertions
    as type sources without rewriting in RBS.
11. [**Generating RBS with rigor sig-gen**](11-sig-gen.md)
    — emitting RBS from Rigor's inference results, the
    `new-file` / `new-method` / `tighter-return`
    classification model, the `--print` / `--diff` /
    `--write` modes, the `--params` policy and ADR-5
    trade-off, RSpec-aware observations.
12. [**Lightweight HKT (JSON.parse and friends)**](12-lightweight-hkt.md)
    — Rigor's defunctionalised higher-kinded type encoding
    ([ADR-20](../adr/20-lightweight-hkt.md), Yallop & White
    2014 / fp-ts shape). Covers the bundled `json::value`
    registration backing `JSON.parse` / `YAML.safe_load`,
    the `symbolize_names: true` + `permitted_classes: [...]`
    call-site discriminators, how to author your own URI
    overlay in `.rbs`, the body grammar, the reducer's
    lazy "tying-the-knot" handling for recursive sums, and
    the conscious non-goals (no conditional bodies, no
    multi-arg containers yet, no plugin manifest hookup).

### Appendix — Coming from another type checker

A short cross-language reference for readers whose mental
model of "static type checker" was set by another tool.
Each page maps Rigor's vocabulary onto the concepts you
already know — type carriers, narrowing primitives,
configuration shape, severity model, suppression — and
calls out the places where the two systems make genuinely
different choices.

- [**Coming from TypeScript**](appendix-typescript.md) —
  the structural-vs-nominal-with-refinements split, `unknown`
  / `any` / `never` ↔ `Top` / `Dynamic[Top]` / `Bot`,
  type guards ↔ `predicate-if-true` directives, what
  conditional / mapped types do not have a Rigor analogue.
- [**Coming from PHPStan**](appendix-phpstan.md) — the
  closest peer in spirit. Identical refinement vocabulary
  (`non-empty-string`, `int<min, max>`, `numeric-string`,
  `literal-string`), `@phpstan-assert*` ↔ `RBS::Extended`,
  Type-Specifying Extensions ↔ plugins, baseline diffing.
- [**Coming from mypy / Pyright**](appendix-mypy.md) — gradual
  typing parallels, `Literal` ↔ `Constant`, `TypeGuard` /
  `TypeIs` ↔ `predicate-if-true` / `predicate-if-false`,
  `Protocol` ↔ RBS `interface`, `LiteralString` ↔
  `literal-string`.
- [**Coming from Steep**](appendix-steep.md) — Ruby's other
  RBS-driven static checker. Both consume the same `.rbs`
  files; this page covers the layer each tool adds on top
  and the coexistence pattern for projects that want to run
  both.
- [**Coming from TypeProf**](appendix-typeprof.md) — Ruby's
  official type *inference* tool. Both infer without
  annotations; this page covers the whole-program-vs-local
  analysis trade, why `rigor sig-gen` is the direct analogue
  to the `typeprof` CLI, and the diagnostics-vs-RBS-output
  split.

### Appendix — Protocols and structural typing

A standalone concept page for the question this handbook gets
from Python and Swift readers alike: *"where is Rigor's
`Protocol`?"* It untangles the one word that means two
unrelated things in Rigor — the **interface** (RBS structural
type, the Python `typing.Protocol` analogue) and the
**protocol contract** (ADR-28's path-scoped behavioural
contract) — so you reach for the right one.

- [**Protocols, interfaces, and structural typing**](appendix-protocols-and-structural-typing.md)
  — RBS `interface` ↔ `typing.Protocol`, inferred object
  shapes and capability roles, and how all of that differs
  from the plugin-declared, path-scoped protocol contracts of
  [ADR-28](../adr/28-path-scoped-protocol-contracts.md).
  Includes the side-by-side "interface vs protocol contract"
  table and a "which one do I want?" guide.

### Appendix — Connections to type theory

A short bridge between Rigor's vocabulary and the formal
type-theoretic concepts you may have seen in a programming-
languages textbook or in another type checker's documentation.
Read this if you came in from a "where does Rigor sit in the
type-theory landscape" question; the handbook proper stays
deliberately short on theory.

- [**Connections to type theory**](appendix-type-theory.md) —
  the type lattice, subtyping vs gradual consistency, nominal
  vs structural, the polymorphism family (parametric / subtype
  / ad-hoc), variance, refinement / predicate subtyping,
  occurrence typing, gradual typing, effect systems, the
  soundness vs completeness trade-off, and a short list of
  features Rigor deliberately does not model (HKT,
  higher-rank, full dependent types, …) — each with the
  matching Rigor surface and a pointer into the spec corpus.
- [**The Liskov Substitution Principle**](appendix-liskov.md) —
  why LSP is a *behavioural* discipline that applies to Ruby
  *more* than to a statically-checked language (not less — the
  "Ruby isn't statically typed so LSP is optional" claim gets
  the principle backwards), how Rigor's robustness principle
  (strict returns, lenient parameters) re-derives the LSP
  signature rule (covariant returns, contravariant parameters)
  from Ruby-adoption ergonomics rather than substitutability
  proofs, why that convergence means Rigor's defaults do not
  fight duck typing or the "L" of SOLID, and which
  behavioral-subtyping obligations (cross-hierarchy override
  compatibility, exception rules, Design-by-Contract, the
  history constraint) Rigor does *not* statically enforce. On
  this page only, "LSP" means Liskov — not the Language Server.

## How to read this handbook

Each chapter is short on theory and long on examples. Every
example is real Ruby that runs under MRI as written; the
prose around it is what `rigor check` would say about that
code.

When you see an `assert_type(...)` line in a snippet, that is
Rigor's introspection helper, not a runtime check — it pins
the inferred type at that program point so you can compare
the prose to the actual analyzer output. `dump_type(...)` is
the same idea but emits a notice instead of failing on
mismatch.

Snippet conventions:

```ruby
n = 1 + 2
assert_type("Constant<3>", n)  # Rigor folds the literal sum
```

means: at the `assert_type` call, Rigor's inference for `n` is
`Constant<3>` — the `Type::Constant` carrier with the literal
value `3`.

When a chapter references a more formal document, the link
takes you out of the handbook into the binding spec corpus or
ADRs:

- [`docs/types.md`](../types.md) — one-page mental model.
- [`docs/type-specification/`](../type-specification/README.md)
  — normative spec corpus.
- [`docs/internal-spec/`](../internal-spec/README.md) —
  analyzer-internal contracts (engine surface, type-object
  public API).
- [`docs/adr/`](../adr/) — architecture decision records.

## Non-goals

The handbook is meant to be readable cover-to-cover in a few
hours. To keep it short:

- It does **not** introduce Ruby itself. `def`, `class`,
  blocks, modules, `attr_*`, regex, RBS basics — all assumed.
- It does **not** cover every edge case. Edge cases live in
  the spec corpus.
- It does **not** discuss internal contracts (engine surface,
  type-object public API). Those live in
  [`docs/internal-spec/`](../internal-spec/README.md).
- It does **not** cover plugin **authoring** — that is the
  job of [examples/](../../examples/README.md). Chapter 9 is
  a one-page pointer.

If a topic comes up that the handbook does not explain, the
relevant spec document is one click away.
