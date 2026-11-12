# Leave a nil-able instance variable off the non-escaping block join until #1219 closes

- **PR:** [#3094](https://github.com/rigortype/rigor/pull/3094)
- **Issue:** [#1208](https://github.com/rigortype/rigor/issues/1208)
- **Class:** scope
- **Precedent:** [#2295](https://github.com/rigortype/rigor/pull/2295)
- **Decided:** 2026-11-12

## Background

#1208 asked the block content seams (ADR-56 slice C's join and the escaping floor) to cover an instance variable as well as a local. Taking every instance variable made the adversarial review's first round fail: the seams have two known gaps on locals. The join drops a seed's `nil` after a guarded mutation (#1219). The floor takes a union with a collection member whole (#1251). Instance variables are the common spelling of a lazily initialised, nil-able collection, so `@buf = flag ? [1] : nil; [1].each { @buf << 2 if @buf }; @buf.nil?` began folding on correct code. Before the PR it was silent. #3095 later closed the escaping half on its own.

## Options and trade-offs

- Take every instance variable. That makes the local gaps much easier to hit and adds new false positives on correct code (ADR-5).
- Fix #1219 and #1251 in this PR. They are separate defects with their own reviews, and they also change the local answers.
- Take an instance variable only when every member of its pre-call binding is an Array, Hash or String carrier (`StatementEvaluator#collection_only?`). A nil-able one keeps its pre-call binding, which is the base behaviour: no new diagnostic, but the stale contents remain for that shape.

## Decision

The third option. It keeps the fix for every shape #1208 lists and fires nothing new. The cost is that a nil-able instance variable a non-escaping block grows still reads its pre-call contents (`@buf&.last == 2` after `[1].each { @buf&.push(2) }` still folds). The escaping floor no longer has this cost: #3095 floors every instance variable member by member (`StatementEvaluator#member_content_floor`), so `@buf&.push(2)` in a stored callback reads `Array[Dynamic[top]]?` and keeps the `nil`. Only the non-escaping join is still deferred, pending #1219. #2295 is the closest ratified precedent. It left a shape out of a content floor until a separate fix could keep its element type, and the spec pinned the current answer as a decision. This entry makes the same move for a variable kind the seams cannot yet join soundly.

## To undo

Drop the `collection_only?` check in `ivar_content_mutation_target` once #1219 has landed, and turn the fixture's `guarded` line into a joined expectation. The escaping side needs no undo: #3095 removed its check.
