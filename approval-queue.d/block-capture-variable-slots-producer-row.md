# Record StatementEvaluator#under_scope_body? in producers.yml as a helper that derives no declaration context

- **PR:** [#3094](https://github.com/rigortype/rigor/pull/3094)
- **Issue:** [#1208](https://github.com/rigortype/rigor/issues/1208)
- **Class:** gate-row
- **Precedent:** [#2086](https://github.com/rigortype/rigor/pull/2086)
- **Decided:** 2026-11-12

## Background

The block content seams now take an instance variable a block mutates in place (#1208, #1235). To leave out an instance variable written inside a `def`, `class` or `module` body the block defines, four new methods tested the ancestors against `SCOPE_BODY_NODES`. `spec/rigor/declaration_facts/producers_spec.rb` counts any method that reads that constant as a declaration producer, so it failed on all four.

## Options and trade-offs

- Add four rows, one per method. That is accurate but spreads one test over four entries a later reader must check.
- Move the test into one helper, `under_scope_body?`, and add one row with its reason. That is one entry, and the four methods share one definition of "a nested scope body".
- Reuse the grandfathered `same_scope_local?`. It does not fit: it answers a local's `depth`, not whether an instance variable belongs to another `self`.

## Decision

One helper and one row. Its reason says what the row allows: the helper reads ancestor node classes to decide whether an instance variable is the block's `self`'s, and derives no declaration context. #2086 added `LexicalMethodSites` rows to the same file for the same kind of reason (a scan that derives no declaration context).

## To undo

Delete the row and inline the test, which brings back the four failures. Or route the test through `DeclarationWalk::Context` if that grows an "inside a nested scope body" query.
