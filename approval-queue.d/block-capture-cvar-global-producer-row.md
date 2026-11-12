# Widen the producers.yml reason for StatementEvaluator#under_scope_body? from instance variables to class variables and globals

- **PR:** [#3120](https://github.com/rigortype/rigor/pull/3120)
- **Issue:** [#3096](https://github.com/rigortype/rigor/issues/3096)
- **Class:** gate-row
- **Precedent:** [#2086](https://github.com/rigortype/rigor/pull/2086)
- **Decided:** 2026-11-12

## Background

#3096 extends the block content seams from instance variables to class variables and globals. Round 1 of the review showed that one scope-body exclusion cannot fit all three kinds, because Ruby runs a class, module or `class << self` body at once:

- a global under any of those bodies is the caller's global;
- a class variable under `class << self` is the enclosing class's;
- a `class` or `module` body has class variables of its own;
- a `def` body runs only when called.

The fix gives each kind its own list of excluding bodies (`NON_LOCAL_SCOPE_BODY_NODES`). A first cut read that table from a new helper, `non_local_under_scope_body?`. `spec/rigor/declaration_facts/producers_spec.rb` counts any method that reads a constant built from Prism body-node classes as a declaration producer, so it failed on the new method.

## Options and trade-offs

- Add a row for a second helper. That is accurate, but it leaves two definitions of "a nested scope body" for a later reader to keep in step.
- Fold the kind into the existing helper, `under_scope_body?(ancestors, kind = :ivar)`, and widen its row's reason. That is one definition and one row, and the instance variable answer is unchanged by default.
- Drop the lifted cases and keep the old exclusion for every kind. That keeps stale contents (a false positive) for a global grown in a module body and a class variable grown in `class << self`.

## Decision

The second option, ruled by the coordinator. The row's reason now names issues #1208 and #3096, the three kinds and the per-kind table. It still says what the row permits: the helper reads ancestor node classes to decide whether a non-local is the one the block's caller sees, and it derives no declaration context. #3094 made the same move (one helper, one row) for instance variables, but its entry is still in the queue, so #2086 is the ratified precedent. #2086 recorded `LexicalMethodSites` rows in the same file for the same kind of reason. No other producers.yml row moved.

## To undo

Restore the row's instance-variable-only reason, and drop the `kind` parameter and `NON_LOCAL_SCOPE_BODY_NODES` so that `under_scope_body?` tests `SCOPE_BODY_NODES` again. That brings back the uniform exclusion and with it the stale-contents folds that the fixture's `cvar_singleton_body` and `GlobalModuleBody` rows pin. Alternatively, route the test through `DeclarationWalk::Context` if it grows a per-kind "inside a nested scope body" query.
