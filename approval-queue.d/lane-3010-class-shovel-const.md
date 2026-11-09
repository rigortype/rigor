# A class << Const mixin is positioned only as a direct statement of the file that declares the class

- **PR:** [#3019](https://github.com/rigortype/rigor/pull/3019)
- **Issue:** [#3010](https://github.com/rigortype/rigor/issues/3010)
- **Class:** open-choice
- **Precedent:** [#3009](https://github.com/rigortype/rigor/pull/3009)
- **Decided:** 2026-11-09

## Background

`class << Const; prepend Y; end` and `include Y` now record singleton edges on `Const`. The brief allowed the edge to
be positioned when the `class << Const` sits "in the same file directly after the class body", and asked for it to be
unpositioned everywhere else, so the read declines there. "Directly after" needed a concrete test, and so did a
constant that may name more than one class (`module Admin; class << User`).

## Options and trade-offs

- Position only when the `class <<` is the statement right after `class Const ... end`. This is the narrowest test.
  It declines on a harmless statement in between, such as a second class declaration.
- Position when the `class <<` is a direct statement (top level, or directly in a direct body) of a file that declares
  the class, and the constant can denote one name only, names the enclosing class, or names its innermost candidate,
  which the file declares at a statement ahead of the `class <<`. Ruby resolves the constant when the statement runs,
  so a nested class the file declares only later (`module Admin; class << User; …; end; class User; end; end`) does
  not exist yet; the review of the first head found that case placed on the wrong class. Within one file,
  statement order is load order, and the multi-file rule already declines when another file also writes the class's
  edges.
- Position nowhere. This always declines, and the single-file witness in the issue would not answer.

## Decision

The second option. It follows #3009, which positions a direct `singleton_class.prepend P` on the class's own receiver
and keeps a constant receiver unpositioned on every name the constant can denote. Here the edge stays unpositioned
where a more-nested candidate is left, and a prepend also records, unpositioned, on the other candidates, as #3009's
`record_prepend_candidates` does. An `include` records on the resolved owner only, as #3009 records
`Const.singleton_class.include` on the owner only.

## To undo

Change the condition in `ScopeIndexer#walk_extends_constant_singleton` that calls `accumulator.direct_body`: drop it to
position nowhere, or narrow it to the statement right after the declaration.
