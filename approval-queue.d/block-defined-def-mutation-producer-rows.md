# Add producers.yml rows for StatementEvaluator#block_defined_method_capture? and OperandEffects#method_mutation?

- **PR:** [#3169](https://github.com/rigortype/rigor/pull/3169)
- **Issue:** [#3163](https://github.com/rigortype/rigor/issues/3163)
- **Class:** gate-row
- **Precedent:** [#2086](https://github.com/rigortype/rigor/pull/2086)
- **Decided:** 2026-11-13

## Background

#3163 floors an instance variable, class variable or global that a method defined inside a block mutates in place, because the block may call that method. The content seams leave a `def` body out through `under_scope_body?`, so the fix needs a second test that lets a `def` through and still stops at a `class`, `module` or `class << self` body. `OperandEffects` needs the same stop when it looks into a `def` under an operand's block, so that a block in a call's argument or receiver reaches the floor.

`spec/rigor/declaration_facts/producers_spec.rb` counts any method that reads a constant built from Prism body-node classes as a declaration producer. It failed on both new methods and asked for a row each. The issue did not say how the gate should be answered.

## Options and trade-offs

- Add one row per method. That is accurate: each row says what the method reads and that it derives no declaration context. It adds two more places that name the class-body node kinds.
- Fold the new test into `under_scope_body?` as a further kind in `NON_LOCAL_SCOPE_BODY_NODES`. That keeps one row in `statement_evaluator.rb`, but the new test also needs the `def` nodes it passed (to read their receivers), which the table lookup does not return, and `OperandEffects` is a module of its own that cannot call the evaluator's private helper.
- Route both through `DeclarationWalk::Context`. Neither method asks where a declaration lands; they ask whether a mutation sits in a method the block defines. That query does not exist there.

## Decision

The first option, taken by the lane and confirmed by the coordinator in review round 1. Both rows state the issue, what the method decides, and that it reads node classes without deriving a declaration context. The precedent fits closely: #2086 recorded `LexicalMethodSites` rows in the same file for the same reason, and #3120 widened the `under_scope_body?` row in the same seam. No other producers.yml row moved.

## To undo

Delete the two rows together with `block_defined_method_capture?` and `OperandEffects.method_mutation?`. That reverts #3163: a non-local mutated by a method defined in a block keeps its pre-block contents again, which the `block_defined_method_mutation` fixture pins. Alternatively, route the class-body stop through `DeclarationWalk::Context` if it grows an "inside a nested class body" query, and drop the rows then.
