# Forget a global after a call by a by-name search for its project writers, and let a calling `when` test of a global case subject ask the same

- **PR:** [#2382](https://github.com/rigortype/rigor/pull/2382)
- **Issue:** [#2314](https://github.com/rigortype/rigor/issues/2314)
- **Class:** open-choice
- **Precedent:** [#2260](https://github.com/rigortype/rigor/pull/2260)
- **Decided:** 2026-10-26

## Background

The maintainer ratified the policy on #2314: forget a global's binding after a call only when a project method that writes the global is reachable from the call, reusing the question #2260 asks of a `when` test so the two sites agree. #2260 has no writer-reachability query; it asks `GuardRebinding.may_rebind?`, whether the test may run any non-core code, and forgets the global subject on that alone. Used as-is past a statement call, it would forget `$h` after `noop` even when nothing writes `$h`, which the issue's second acceptance criterion forbids. So the reachability had to be built, three readings of it were open, and the `case` site had to move to match.

## Options and trade-offs

- **By-name search over project `def`s, gated by #2260's question (taken).** A writer census (`[:global_writer, name, method]`, nil for a lambda or stored block) plus a search from the call through every project `def` of each called name, on any class, transitively. A `Dynamic` receiver, an anonymous writer, a computed `send` or an `eval` count as reaching, which is #2260's unresolved-callee policy. Over-forgets when an unrelated class defines a method of the same name as a writer, never under-forgets through a typed path the search can see. Cost on the frozen corpus: +0.08% allocations.
- **#2260's question plus "the global has any method writer".** Simplest, but a write in the same method (`def m; $g = nil; helper; $g + 1; end`) makes `$g` method-written and every project call forgets it, losing the true positive the brief's table keeps.
- **Receiver-typed reachability.** Precise at the call site, but a callee body has no types for its receivers, so every call in it would count as unresolved and the search would collapse to the previous option.
- **Forget to `Dynamic[top]` (taken) or to the program-global seed.** The seed joins only the analysed file's writes, so a writer in another file (`$mf = nil; Other.set_mf; $mf + 1`) would keep the seed's `nil` and report; it would also leave `def reset! = ($g = 1); $g = nil; reset!; $g + 1` reporting `1?` as possibly nil. `Dynamic[top]` matches #2260.
- **A global a guard narrowed before the call keeps #1429's restore (taken).** Otherwise `return unless $sep; reset_sep; $sep.length`, where `reset_sep` writes `nil`, goes quiet: the restore reads `","?` and reports, which `global_constant_guards/invalidation.rb` pins.
- **Move #2260's `when`-test arm for a global subject to the same query (taken).** The brief requires agreement. It narrows #2260: `$cw = nil; case $cw when String then 1 when cw_noop then 2 else $cw + 1 end` now reports (Ruby raises NoMethodError) where it was quiet.

## Decision

The by-name search is the narrowest reading that meets every acceptance row and the brief's edge table, reads less wherever it cannot prove the call stays clear of a writer (the AGENTS.md false-positive rule), and keeps #2260's unresolved-callee policy. Moving the `case` site follows from the brief's "the two sites must agree".

## To undo

Drop `forget_reached_globals` from `StatementEvaluator#rebind_statement_specials`, restore the global arm of `#when_test_rebinds_subject?` to `GuardRebinding.may_rebind?`, and remove `GlobalWriterReach` and the census's `[:global_writer, …]` entries (bumping `IncrementalSnapshot::SCHEMA` again). `spec/integration/global_binding_after_call_spec.rb` pins every row.
