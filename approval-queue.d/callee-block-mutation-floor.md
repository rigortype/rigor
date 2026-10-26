# `def.return-type-mismatch` spares a gradual Array a declared tuple may still be, and only `::Array.new`-style `new` is a fresh rebind

- **PR:** [#2373](https://github.com/rigortype/rigor/pull/2373)
- **Issue:** [#2296](https://github.com/rigortype/rigor/issues/2296)
- **Class:** open-choice
- **Precedent:** [ADR-5](../docs/adr/5-robustness-principle.md)
- **Decided:** 2026-10-26

## Background

#2296 makes the callee mutation floor count a mutation inside a block of the callee's body. The caller's argument is
widened with its element type kept: `acc = [-7, 9]; norm(acc)` reads `Array[Dynamic[top] | Integer]` after a `norm`
that rewrites `acc` in an `each_index` block. A nominal Array never conforms to a tuple, so a method declared
`-> [Integer, Integer]` that returns that `acc` drew `def.return-type-mismatch` on correct code. Ruby returns
`[7, 9]`, and the base engine was silent because it kept the literal. The review of #2373 found this.

The same rule had added one row in the haml corpus:
`lib/haml/attribute_compiler.rb:25:9`, declared `[:html, :attrs, [:dynamic, String]] | [:html, :attrs]`, inferred
`Array[Dynamic[top] | Symbol]`, from `restore_newlines!`'s `missing.times { temple << [:newline] }`. Ruby does
contradict that declaration: on the survey copy, `AttributeCompiler#compile` for `%p{class: foo,\n  id: bar} hi`
returns a 5-element array ending in `[:newline]`. But the declaration is not haml's: haml ships no `sig/`, the survey
copy's `sig/` is untracked, and an older `rigor sig-gen` generated it. Run without that `sig/`, this head's sig-gen
proposes `def compile: (untyped) -> (Array[untyped] | [:html, :attrs, [:dynamic, String]])`.

The same PR drops a parameter from the callee census once the callee rebinds it to a provably fresh object
(`acc = acc.dup; acc[0] = 0` leaves the caller's argument alone). The review found that `X.new` on any constant counted
as fresh. But a project class's `new` may wrap its argument and write through it (`acc = Wrap.new(acc); acc[0] = "x"`)
or hand it back (`Ident.new(acc)`). Either way Ruby mutates the caller's array, yet the census lost the floor, so
`acc[0].upcase` reported on correct code.

## Options and trade-offs

- Report every rejected Array against a tuple (the base rule): keeps the haml row, which is a true positive against
  a stale generated signature. Costs a false positive on every correct program whose tuple-typed return a callee
  rewrites in a block.
- Make the rule gradual-aware: an inferred `Array[E]` whose `E` has a `Dynamic` member is not reported against a
  declared tuple when every known member of `E` overlaps some element of one declared tuple. The length and the
  gradual elements are unknown, so nothing proves the tuple wrong. A known member that overlaps no slot
  (`Array[Dynamic[top] | Integer]` against `[String, String]`) and an Array with no gradual element still report.
  The cost is global, not limited to the callee floor. Every `Array[E]` with a `Dynamic` member is no longer reported
  against a declared tuple when its known members fit. That includes an RBS `Array[untyped]` return, `raw.map { |x| x
  }` over untyped input, and a literal widened by a push of an untyped value. The last one loses true positives Ruby
  proves: `a = [1, 2]; a.push(x); a` always has length 3, yet it is no longer reported against a declared
  `[Integer, Integer]`. The haml row is another such true positive.

- For the rebind: count `X.new` as fresh only when written `::Array.new`, `::Hash.new`, `::String.new` or
  `::Set.new`. The census reads the AST alone and cannot resolve a constant, and a bare `Array` inside a namespace
  may name the namespace's own class (`M::Array`, whose `new` can wrap its argument and write through it). The cost:
  a bare `Array.new(...)`, `Hash.new`, `String.new` or `Set.new` rebind, and a project `X.new` that really copies its
  argument, no longer count as fresh rebinds, so the caller's argument is floored after a callee that mutates only
  the copy. That is a precision loss in the conservative direction: the floor only forgets a literal shape, so it can
  drop a report but not add one.

## Decision

The gradual-aware rule (`CheckRules::GradualTupleReturn`). False positives outrank the true positive (AGENTS.md,
ADR-5), and the rule declines only where the evidence is gradual by construction. The haml row no longer fires, so the
named-mechanism adjudication an earlier round of this PR recorded is dropped. The coordinator ruled this in the #2373
review.

The maintainer ruled the rebind restriction: `X.new` counts as fresh only in the `::`-rooted spellings `::Array.new`,
`::Hash.new`, `::String.new` and `::Set.new` (`StatementEvaluator#core_collection_constant?`).

## To undo

Drop the `GradualTupleReturn.consistent?` line from `CheckRules#compare_return`, and the module. The "a floored
argument returned against a declared tuple" examples in `spec/integration/callee_block_mutation_floor_spec.rb` pin
the rule, and the issue's tuple-returning shape would report again on correct code. The haml row would come back.

To undo the rebind restriction, let `StatementEvaluator#core_collection_constant?` accept other spellings. Accepting a
bare `Array` makes the "namespace's own Array" and "bare Array.new" examples fail, and accepting any constant makes the
"wrapping project constructor" and "project constructor returning its argument" examples fail, all in
`spec/integration/callee_block_mutation_floor_spec.rb`.
