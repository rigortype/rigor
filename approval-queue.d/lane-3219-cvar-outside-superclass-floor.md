# Floor a class variable's census entry when its superclass tree reaches a class outside the file

- **PR:** [#3253](https://github.com/rigortype/rigor/pull/3253)
- **Issue:** [#3219](https://github.com/rigortype/rigor/issues/3219)
- **Class:** open-choice
- **Precedent:** [ADR-5](../docs/adr/5-robustness-principle.md)
- **Decided:** 2026-11-15

## Background

#3219 joins a superclass's cvar writes into a subclass's census entry, since Ruby keeps one class-variable slot for a class and its subclasses. The census reads one file. When the topmost class of a superclass tree names a superclass the file does not declare, or reopens without a header a class that another file's header or a bundled signature declares, the writes made in that superclass's chain are unseen. That covers another file's class, a gem class, a core class such as `StandardError`, a name nothing declares, and a non-constant superclass such as `Struct.new(:a)`. The issue left open what such an entry should read. The coordinator ruled to keep the floor, and asked for it to be recorded here. The known limitation is tracked as [#3262](https://github.com/rigortype/rigor/issues/3262).

## Options and trade-offs

- **Keep the entry as the file's own writes.** This was the behaviour on base. A read keeps its precision, and `class E1 < StandardError; def s = @@c = 1; def x = @@c.nope; end` reports `nope` as undefined. But a superclass outside the file that writes `@@c = nil` (an `inherited` hook, a reopening, a gem) makes `@@c.nil?` in the subclass fold on correct code.
- **Join `Dynamic[top]` into every entry of such a tree (taken).** A read no longer folds, and no `nil` it cannot see reports. The cost is true positives: the `@@c.nope` report above is lost, as is any rule that needs the entry exact.
- **Exempt core and stdlib superclasses.** This keeps precision for `< StandardError`, but Ruby lets any file reopen a core class and write a cvar that every subclass shares, so the exemption would re-admit the fold. It also means deciding which signatures count as core.

## Decision

The floor. A false positive on correct code outranks a missed report (AGENTS.md; ADR-5's robustness principle). The cvar chain is shared, so a write the census cannot see is part of the subclass's value and not a corner case. A superclass written as `Object` or `BasicObject`, and a headerless class that only this file and the project's own `sig/` declare, still end the tree.

## To undo

Drop `writes << Type::Combinator.untyped if open` from `CvarHierarchy.tree_union` (the `open` flag then only marks the tree), and the `Dynamic[top]` expectations in `scope_indexer_spec.rb` and `cvar_superclass_join_spec.rb` flip to folds. #3222's cross-file census could instead replace the floor with the other files' writes.
