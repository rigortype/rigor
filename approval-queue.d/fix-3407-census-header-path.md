# The publication census also walks a class or module header's path, not only the superclass expression

- **PR:** [#3434](https://github.com/rigortype/rigor/pull/3434)
- **Issue:** [#3407](https://github.com/rigortype/rigor/issues/3407)
- **Class:** scope
- **Precedent:** none — sets one
- **Decided:** 2026-11-27

## Background

Issue #3407 asked the cross-file constant publication census to see a constant write inside a class
header's superclass expression (`class C < (A = Base)`). The census walked a `class` / `module` node
straight into its body, so neither header position was reached. The header path can hold a write
too: `class (A = Object)::B; end` and `module (A = Object)::N; end` are valid Ruby and assign `A`
before the body opens. The issue did not name that position.

## Options and trade-offs

- Walk only the superclass, as the issue names. This leaves a header-path write missed, so another
  file's literal for `A` stays published although the program rebinds it: the same false positive
  through a rarer spelling.
- Walk both the header path and the superclass, under the enclosing prefix, self and cref. This
  costs one more call at the same site. It can only add censused writes, which retracts more
  publication, the safe direction (ADR-5). It also feeds those nodes to the global and ivar write
  census, which is the same direction.

## Decision

Walk both. The header path is the same family as the superclass write the issue names, the fix is
the same line, and retracting more is the safe direction. No measured run moved:
`spec/integration/fixtures`, `lib/rigor/inference` and the rbnacl survey all matched the base engine.

## To undo

Narrow the header child walk in `ConstantTables.walk_census_declaration` to the superclass alone.
The two integration examples for a header path and the mirror-spec line for
`class (A = Object)::B` / `module (D = Object)::E` then fail, and both go with it.
