# An alias whose old name has no def before it in the file no longer copies the file's later def

- **PR:** [#2225](https://github.com/rigortype/rigor/pull/2225)
- **Issue:** [#2006](https://github.com/rigortype/rigor/issues/2006)
- **Class:** open-choice
- **Precedent:** [#2003](https://github.com/rigortype/rigor/pull/2003)
- **Decided:** 2026-10-21

## Background

To fix #2006 and the review finding on #2225 (`def x = "s"; alias old_x x; def x = 1` typed `old_x` from the later `def`), the alias pass now copies what the old name held at the alias, in source order. `spec/rigor/inference/scope_indexer_spec.rb` pinned the opposite for one shape since the alias pass was added (992938b49): `alias say_hello greet` written before `def greet` resolved `say_hello` to that later `def`. In Ruby 4.0.5 that alias raises NameError unless `greet` is inherited or defined in a file loaded earlier, and then it copies that method, never the later `def`.

## Options and trade-offs

- Keep the forward reference: the alias of a name defined later still types from the later `def`. That preserves the old answer for code that, if it runs at all, runs a different method.
- Copy nothing (taken): the new name stays in the existence table but has no def node of this file, so calls on it read as untyped. This drops a typing answer for code that only runs when another definition is in play, and never asserts a type Ruby does not produce.

## Decision

Copy nothing. False positives outrank worst-case static reading (AGENTS.md), and #2003 settled the same way for definers the walk cannot order: the reader declines rather than picking one. The example is rewritten to pin the new answer.

## To undo

Fall back to the final-walk `class_defs[old_name]` in `AliasMap#copy_into` when the history holds no write before the alias, and restore the original example.
