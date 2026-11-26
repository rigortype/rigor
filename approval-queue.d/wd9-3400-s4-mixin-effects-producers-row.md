# Add a producers.yml row for the body of `ScopeIndexer::MixinEffects`, which names node classes since `LOCAL_SCOPE_BOUNDARIES` moved into it

- **PR:** [#3415](https://github.com/rigortype/rigor/pull/3415)
- **Issue:** [#3400](https://github.com/rigortype/rigor/issues/3400)
- **Class:** gate-row
- **Precedent:** [#3021](https://github.com/rigortype/rigor/pull/3021)
- **Decided:** 2026-11-26

## Background

Slice 4 of #3400 moves the mixin effects and taints out of `scope_indexer.rb` into `ScopeIndexer::MixinEffects`.
The cluster owns three constants, the ones only it reads. One of them is
`LOCAL_SCOPE_BOUNDARIES = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode]`: the
nodes at which the scan for the name literals a computed `send` argument can hold stops, because each opens a
local scope of its own (#3006, #3024).

`spec/rigor/declaration_facts/producers_spec.rb` lists every method, and every class or module body, that names a
declaration node class. In `scope_indexer.rb` the constant stood in the body of `ScopeIndexer`, whose row is
`grandfathered` and covers every node-class list of that file. Moved, it stands in the body of `MixinEffects`, so
the scan lists that body as a producer: 617 keys where the file has 616. The other 27 rows the slice touches are
re-keys, each with the reason it had.

## Options and trade-offs

- **Move the constant and give the body a row with a reason.** The constant goes with the two functions that read
  it (`collect_local_send_names`, `constant_write_nodes`), as ADR-116's re-measure counts a row's own constants
  and as slices 1 to 3 moved theirs. The list grows by one key for a fact the base's list held under another
  key, and the reason says what the constant is for. Nothing is hidden: the two functions keep the rows #3021
  and #3040 gave them, each saying that its scan stops at a nested `def` or declaration.
- **Leave the constant in `scope_indexer.rb`, read lexically from the new file.** The list stays at 616 keys, as
  `NodePropagation` left `SELF_OPENING_BODIES` and `CLASS_BODY_DEF_BARRIERS` behind (#3311). It keeps on the
  indexer a name nothing in its file reads, it is code shaped to pass the gate, and the two reads would cross a
  file, where a constant whose value
  is a frozen Array literal reads `Dynamic[top]` in the self-typing scan: the slice pays 17 `Dynamic` call sites
  for ten such reads of the five constants that have to stay, and these two would add their `.any?` calls.
- **Mark the new row `grandfathered`.** The pin's count would go from 366 to 367. A new key is not a
  grandfathered one, and the spec says so.

## Decision

The first. The row reads: "issue #3006, LOCAL_SCOPE_BOUNDARIES lists the nodes that open a local scope of their
own (a def, a class, a module, a class << self), where the scan for the name literals a computed send argument
can hold stops; the constant moved here from scope_indexer.rb with the two functions that read it (ADR-116 WD9,
#3400), whose module body is a row for the node-class lists that stay; it bounds a scan and derives no
declaration context".

#3021 is the precedent: it listed the helpers of the computed-send reading in the same file for the same kind
of reason, and its entry says of `collect_local_send_names` that it "reads `LOCAL_SCOPE_BOUNDARIES` and appends
the literals it finds", a consumer and no producer. That entry weighed restructuring the code to dodge the
scanner and declined it. It was ratified by `e82a47057`, "Ratify the remaining five approval queue entries"
(2026-11-15). This row is the same constant's, for the same reading, one level up: the body that defines the
list instead of the function that reads it. The grandfathered pin keeps its count of 366; only its digest
moves, for the ten grandfathered keys the slice re-keys.

Two mutations in the pull request hold the row to the gate: taken out of `producers.yml` it fails "lists
exactly the producers the tree has" (X7), and marked `grandfathered` it fails "keeps the grandfathered list
closed" (X10).

## To undo

Move `LOCAL_SCOPE_BOUNDARIES` and its `private_constant` line back into `scope_indexer.rb`, delete the row, and
spell nothing else: `MixinEffects` reads the name lexically. The self-typing scan then reads the two
`LOCAL_SCOPE_BOUNDARIES.any?` calls as `Dynamic`, as it reads the calls on the five constants that stayed.
Nothing else depends on the row.
