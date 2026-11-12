# Leave a nil-able instance variable off the block content seams until #1219 and #1251 close

- **PR:** [#3094](https://github.com/rigortype/rigor/pull/3094)
- **Issue:** [#1208](https://github.com/rigortype/rigor/issues/1208)
- **Class:** scope
- **Precedent:** none — sets one
- **Decided:** 2026-11-12

## Background

#1208 asked the block content seams (ADR-56 slice C's join and the escaping floor) to cover an instance variable as well as a local. Taking every instance variable made the adversarial review's first round fail: the seams have two known gaps on locals. The join drops a seed's `nil` after a guarded mutation (#1219). The floor takes a union with a collection member whole (#1251). Instance variables are the common spelling of a lazily initialised, nil-able collection, so `@buf = flag ? [1] : nil; [1].each { @buf << 2 if @buf }; @buf.nil?` began folding on correct code. Before the PR it was silent.

## Options and trade-offs

- Take every instance variable. That makes the local gaps much easier to hit and adds new false positives on correct code (ADR-5).
- Fix #1219 and #1251 in this PR. They are separate defects with their own reviews, and they also change the local answers.
- Take an instance variable only when every member of its pre-call binding is an Array, Hash or String carrier (`StatementEvaluator#collection_only?`). A nil-able one keeps its pre-call binding, which is the base behaviour: no new diagnostic, but the stale contents remain for that shape.

## Decision

The third option. It keeps the fix for every shape #1208 lists and fires nothing new. The cost is that a nil-able instance variable a block grows still reads its pre-call contents (`@buf&.last == 2` after an escaping `@buf&.push(2)` still folds). Nothing earlier decided how a seam should defer a variable kind it cannot yet handle soundly, so this sets a precedent.

## To undo

Drop the `collection_only?` checks in `ivar_content_mutation_target` and `escaping_ivar_content_mutations` once #1219 and #1251 have landed, and turn the fixture's `guarded` / `guarded_escaping` lines into joined expectations. On the escaping path alone it could go sooner, by flooring through `UnknownStoreWidening.content_floor`, which keeps the `nil` member.
