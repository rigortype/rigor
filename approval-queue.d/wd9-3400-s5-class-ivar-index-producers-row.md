# Add a producers.yml row for the body of `ScopeIndexer::ClassIvarIndex`, which names node classes since `IVAR_BARRIER_NODES` moved into it

- **PR:** [#3418](https://github.com/rigortype/rigor/pull/3418)
- **Issue:** [#3400](https://github.com/rigortype/rigor/issues/3400)
- **Class:** gate-row
- **Precedent:** [#2469](https://github.com/rigortype/rigor/pull/2469)
- **Decided:** 2026-11-26

## Background

Slice 5 of #3400 moves the class ivar index out of `scope_indexer.rb` into `ScopeIndexer::ClassIvarIndex`. The
cluster owns 17 constants, the ones only it reads in that file. One of them is
`IVAR_BARRIER_NODES = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode]`: the nodes a walk of one body stops
at, because the ivars below each are another method's or another class's.

`spec/rigor/declaration_facts/producers_spec.rb` lists every method, and every class or module body, that names a
declaration node class. In `scope_indexer.rb` the constant stood in the body of `ScopeIndexer`, whose row is
`grandfathered` and covers every node-class list of that file. Moved, it stands in the body of `ClassIvarIndex`,
so the scan lists that body as a producer: 618 keys where the file had 617. The other 51 rows the slice touches
are re-keys, each with the reason it had.

## Options and trade-offs

- **Move the constant and give the body a row with a reason.** The constant goes with the five functions of the
  index that read it (`collect_explicit_return_ivars`, `define_method_written_ivars`,
  `collect_class_body_ivar_writes`, `detect_read_before_write`, `gather_ivar_writes`), as ADR-116's re-measure
  counts a row's own constants and as slices 1 to 4 moved theirs. The list grows by one key for a fact the
  base's list held under another key, and the reason says what the constant is for. Nothing is hidden: the five
  functions keep their rows, four of them grandfathered and one (`define_method_written_ivars`, #1768) saying
  that it stops "at a nested def, class or module".
- **Leave the constant in `scope_indexer.rb`, read lexically from the new file.** The list stays at 617 keys, as
  `NodePropagation` left `SELF_OPENING_BODIES` and `CLASS_BODY_DEF_BARRIERS` behind (#3311). It keeps on the
  indexer a name nothing in its file reads, and it is code shaped to pass the gate. The five reads would cross a
  file. By `docs/internal-spec/inference-engine.md` § "The publication census" a constant publishes to other files
  only as a single-write frozen scalar literal, and `[Prism::DefNode, …].freeze` is a non-literal rvalue, so each
  of the five `IVAR_BARRIER_NODES.any? { … }` calls would be `Dynamic` in the self-typing scan, with what is
  computed in its block. Where the constant stands with them the five read `shaped` as they did.
- **Mark the new row `grandfathered`.** The pin's count would go from 366 to 367. A new key is not a
  grandfathered one, and the spec says so.

## Decision

The first. The row reads: "IVAR_BARRIER_NODES lists the nodes a body walk of the ivar census stops at (a def, a
class, a module), each a body whose ivars belong to another method or another class; the constant moved here
from scope_indexer.rb with the five functions that read it (ADR-116 WD9, #3400), whose module body is a row for
the node-class lists that stay; it bounds a walk and derives no declaration context".

The precedent is the rows of the same kind the file already holds: the body of a module, listed for a node-class
list it uses as the boundary of a scan. `Rigor::Inference::DirectIvarWrites` (#2469) and
`Rigor::Inference::InterveningIvarReset` (#2036) each say that `NON_RUNNING_NODES` "lists a def and a class,
module or singleton class body only as code" that does not run on the self in question, and
`Rigor::Inference::SelfCallIvarWrites` (#1965) that it "lists `class << self` and `extend` only as code the proof
declines to read past". Each says that it derives no declaration context or records no declaration fact, and each
is a row with a reason of its own, not a grandfathered one. This row is one more of that kind. Slice 4 added the
same kind of row for the body of `MixinEffects` and `LOCAL_SCOPE_BOUNDARIES` (#3415); its entry is still in this
queue, so it is no precedent, and this row is decided as that one was.

The grandfathered pin keeps its count of 366; only its digest moves, for the 43 grandfathered keys the slice
re-keys.

Two mutations in the pull request hold the row to the gate: taken out of `producers.yml` it fails "lists exactly
the producers the tree has" (X6), and marked `grandfathered` it fails "keeps the grandfathered list closed" (X7).

## To undo

Move `IVAR_BARRIER_NODES` back into `scope_indexer.rb` with its `private_constant` line, delete the row, and
read it by its bare name again in `class_ivar_index.rb` (five sites, lexically) and in `class_cvar_census.rb`
(one site, where it is read as `ClassIvarIndex::IVAR_BARRIER_NODES`). The self-typing scan then reads the five
calls of the index as `Dynamic`. Nothing else depends on the row.
