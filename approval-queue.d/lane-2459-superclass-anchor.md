# sig-gen recomputes a resolved superclass's type arguments for the class it resolves to

- **PR:** [#2465](https://github.com/rigortype/rigor/pull/2465)
- **Issue:** [#2459](https://github.com/rigortype/rigor/issues/2459)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-10-28

## Background

Issue #2459 is about a superclass spelled with a leading `::`. Its brief says unanchored tokens keep the #722
resolution unchanged, but its control case asks that `class Sub3 < Hash`, inside a `module Foo` that declares a
plain `Foo::Hash`, be written `< ::Foo::Hash` with no type arguments. On master it was written
`< ::Foo::Hash[untyped, untyped]`: the arguments were computed for core `Hash` before the token was resolved to
`Foo::Hash`. That fails `rbs validate` the same way as the anchored case. The two parts of the brief disagree.

## Options and trade-offs

- **Recompute the arguments after resolution (taken).** `resolve_superclass_token` asks for the arity of the
  class the token resolves to. The class Ruby resolves to is unchanged; only the arguments follow it. It changes
  output only where an unanchored superclass shares its name with a generic top-level class and resolves to a
  nested one, and that output was invalid RBS before.
- **Leave unanchored tokens alone.** Keeps the brief's "unchanged" wording literally, but fails its control case
  and keeps writing a header `rbs validate` rejects.

## Decision

Recompute. The control case is the acceptance criterion, and the defect is the same one the issue fixes for the
anchored spelling. No survey project changed because of it (liquid, kramdown, alba, faraday, mail).

## To undo

In `resolve_superclass_token` in `lib/rigor/sig_gen/generator.rb`, return `"#{candidate}#{args}"` with the
original arguments instead of `generic_superclass_spelling(candidate)`, and drop the "still resolves an
unanchored token against the nesting" example in `spec/rigor/sig_gen/generator_core_type_spelling_spec.rb`.
