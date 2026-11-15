# Add a producers.yml row for the cvar census's superclass-header recorder

- **PR:** [#3253](https://github.com/rigortype/rigor/pull/3253)
- **Issue:** [#3219](https://github.com/rigortype/rigor/issues/3219)
- **Class:** gate-row
- **Precedent:** [#3218](https://github.com/rigortype/rigor/pull/3218)
- **Decided:** 2026-11-15

## Background

#3219 asks the class-cvar census to join a superclass's writes into a subclass's entry, since Ruby keeps one cvar slot for the whole hierarchy. The fix adds `ScopeIndexer::CvarHierarchy`, whose `record` notes, as the census walk enters each `class` / `module` header, the name it declares and a class header's as-written superclass with the `Module.nesting` outside the header. `spec/rigor/declaration_facts/producers_spec.rb` counts `record` as a declaration producer, because it reads `Prism::ClassNode` and a header's superclass, so it needs a row.

## Options and trade-offs

- Add a row with a reason. That is accurate and keeps the recorder beside the join that reads it.
- Read the superclass and header-nesting tables `SuperclassesCollector` builds. Those are built by a later walk (`declaration_walk_tables`, after the cvar index), merged with the cross-file seed, and keyed per raw name; reusing them means running that collector a second time or moving the cvar index after the method indexes, and the declared-class set would still be missing.
- Put the reads in `ClassCvarsCollector#on_declaration`. That hides a new reading behind the collector's `grandfathered` row.

## Decision

The first option. The row says what `record` reads and that the prefix and nesting come from the walk's `DeclarationWalk::Context` and body context. #3218 added rows for the same census's class-body gather for the same kind of reason, and its entry (`lane-3204-cvar-class-body.md`) was ratified by [#3230](https://github.com/rigortype/rigor/pull/3230), "Ratify the sixteen gate-row entries".

## To undo

Delete the row and `cvar_hierarchy.rb`, and have `build_class_cvar_index` return `collector.table` again. A subclass's read of a cvar its superclass writes `nil` to then folds again (`flow.always-truthy-condition`, #3219).
