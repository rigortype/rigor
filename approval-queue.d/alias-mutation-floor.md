# A mutation through another holder floors every local that may share the object, at a precision cost on bodies where locals escape

- **PR:** [#2677](https://github.com/rigortype/rigor/pull/2677)
- **Issue:** [#2335](https://github.com/rigortype/rigor/issues/2335)
- **Class:** open-choice
- **Precedent:** [#2621](https://github.com/rigortype/rigor/pull/2621)
- **Decided:** 2026-11-03

## Background

A local's literal shape (`[1]`, `{ a: 1 }`, `"a"`) describes its object. A mutation through a
copy, a block parameter, a container slot, an ivar, a call result or a callee kept the local's
literal, so a later read reported `undefined method` on correct code (17 shapes in the issue). The
fix has to widen locals the mutation does not name, and which locals to widen is a precision
trade-off nobody had set.

## Options and trade-offs

- Widen every aliased local at every mutation through an unknown receiver, with the #2621 holder
  scan as is. Sound for the table, but every call argument counts as a holder and the scan is
  flow-insensitive, so `sig/` provenance residue rose by 6 rows and the floor fired tens of
  thousands of times over `lib/`.
- Order the scan by where a local is handed on, count only the arguments of calls that may keep
  them (`new`, in-place mutators, reflective calls), and let a receiver only ever written a new
  object reach only foreign aliased locals. Keeps every row fixed and the residue pins where they
  were; loses precision only where a local really escaped before the mutation.
- Skip the callee paths for a method parameter. The callee census reads every opaque hand-off as a
  write, and flooring each local a parameter was copied into moved two residue pins with no
  finding.

## Decision

The second and third options together. The widening is the unknown store the named path already
gives a site nothing typed (`Dynamic[top]` arguments with the gradual arm), so a local that escaped
before a mutation through an unknown receiver loses its literal size and element pins; a body where
nothing escapes keeps its answers exactly. Two fixture goldens moved (`loop_value`'s alias case now
reads as the direct mutation does, and `aliased_mutation_receiver`'s `declared` takes one unknown
store) and one remover-narrowing spec now reads the copied-from name as floored. #2621's holder scan
is the precedent for reading object facts off a per-body escape scan. The engine cost (+5.75% allocations on the frozen corpus, over the per-PR band and the `bench-perf` band) is reported on the PR for the maintainer's ruling, not decided here.

## To undo

Remove `AliasMutationFloor` and its four call sites (`widen_mutated_receivers`,
`widen_for_outer_receiver`, `floor_arguments`, `floor_ivar_mutating_callee`), the
`call_passes_local_argument?` widening and the collector hooks in `RemoverHolderScan`, and restore
the three goldens and the remover-narrowing expectation.
