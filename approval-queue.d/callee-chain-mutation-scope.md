# Leave a mutation inside a callee's non-escaping block out of the callee floor, so XXH3#hash_long stays literal

- **PR:** [#2295](https://github.com/rigortype/rigor/pull/2295)
- **Issue:** [#2104](https://github.com/rigortype/rigor/issues/2104)
- **Class:** scope
- **Precedent:** [#68](https://github.com/rigortype/rigor/pull/68)
- **Decided:** 2026-10-22

## Background

#2104 names `XXH3#hash_long` as its real instance. There `accumulate_512` mutates `acc` inside `ACC_NB.times { … }`,
a non-escaping block, and the callee floor has never counted that: it counts a direct mutation and one inside an
escaping block. The issue's repro mutates directly, so the chain alone fixes it; XXH3 needs the block channel too.

## Options and trade-offs

- **Count it.** The first cut did. It floored haml's `AttributeCompiler#compile` `temple` array, which
  `restore_newlines!` fills in `missing.times { temple << [:newline] }`, to `Array[Dynamic[top]]`, and a new
  `def.return-type-mismatch` fired against its declared tuple. It also moved the `sig/rigor/inference.rbs`
  provenance residue from 83 to 84 (`ScopeIndexer.finalize_constant_writes`, whose `sources` hash a callee fills in
  an `each` block, read `Hash[untyped, untyped]`). #68 tried and dropped the same channel for the same haml firing.
- **Leave it out.** The repro is fixed; XXH3 keeps its literal `acc`, which fires nothing there today.

## Decision

Leave it out, as #68 did. Counting it needs a floor that keeps the element type (a join of the block's evidence
rather than the bare collection), which is a separate change; the spec pins the current answer as a decision.

## To undo

Walk blocks in `StatementEvaluator#compute_direct_content_parameters` with the read depth matched to the block depth
(the first cut of this PR), once the floor can keep the haml return and the provenance pin.
