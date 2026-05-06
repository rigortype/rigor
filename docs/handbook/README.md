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
5. [**Methods and blocks**](05-methods-and-blocks.md) — argument
   typing, return-type inference, block parameters, arity.
6. [**Classes**](06-classes.md) — instance-side vs class-side,
   `self`, `attr_accessor`, `Data.define`.
7. [**RBS and `RBS::Extended`**](07-rbs-and-extended.md) — when
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
assert_type(n, "Constant<3>")  # Rigor folds the literal sum
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
