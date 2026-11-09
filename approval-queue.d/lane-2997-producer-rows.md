# Three new producers.yml rows for the hook-definer and class_methods-block recorders

- **PR:** [#3003](https://github.com/rigortype/rigor/pull/3003)
- **Issue:** [#2997](https://github.com/rigortype/rigor/issues/2997)
- **Class:** gate-row
- **Precedent:** [#2999](https://github.com/rigortype/rigor/pull/2999)
- **Decided:** 2026-11-09

## Background

The declaration-producers tripwire (`spec/rigor/declaration_facts/producers.yml`, ADR-119 WD6) lists every method that decides a declaration context. Three methods that #2997 adds or splits out are new rows:

- `ScopeIndexer#each_hook_definer`, which tracks whether `self` is the module's singleton class inside `class << self` and skips nested class, module and instance-def bodies;
- `#record_hook_definer_calls`;
- `#record_class_methods_block`, split out of `record_concern_class_methods` for the method-size limit.

The existing `record_concern_class_methods` row also gained a clause saying that it now reads every body of the module.

## Options and trade-offs

- Add the rows with reasons, as #2996 and #2999 did for their hook recorders.
- Route the walk through `DeclarationWalk::Context`. No other hook recorder does this, and it would be a refactor beyond the issue.

## Decision

Add the rows. Each one says what it files, and that it decides no owner or side beyond the prefix its caller passes in.

## To undo

Delete the three rows, and the clause on the `record_concern_class_methods` row, together with the methods.
