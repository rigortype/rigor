# Add a producers.yml row for the body of `ScopeIndexer::MixinEffects`, which names node classes since `LOCAL_SCOPE_BOUNDARIES` moved into it

- **PR:** [#3415](https://github.com/rigortype/rigor/pull/3415)
- **Issue:** [#3400](https://github.com/rigortype/rigor/issues/3400)
- **Class:** gate-row
- **Precedent:** [#2469](https://github.com/rigortype/rigor/pull/2469)
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
  file. By `docs/internal-spec/inference-engine.md` § "The publication census" a constant publishes to other
  files only as a single-write frozen scalar literal, and `[Prism::DefNode, …].freeze` is a non-literal rvalue,
  so both reads would be `Dynamic[top]` in the self-typing scan. The slice already pays 17 `Dynamic` call sites
  for ten such reads of the five constants that have to stay (#3416), and these two would add their `.any?`
  calls.
- **Mark the new row `grandfathered`.** The pin's count would go from 366 to 367. A new key is not a
  grandfathered one, and the spec says so.

## Decision

The first. The row reads: "issue #3006, LOCAL_SCOPE_BOUNDARIES lists the nodes that open a local scope of their
own (a def, a class, a module, a class << self), where the scan for the name literals a computed send argument
can hold stops; the constant moved here from scope_indexer.rb with the two functions that read it (ADR-116 WD9,
#3400), whose module body is a row for the node-class lists that stay; it bounds a scan and derives no
declaration context".

The precedent is the rows of the same kind the file already holds: the body of a module, listed for a
node-class list it uses as the boundary of a scan. `Rigor::Inference::DirectIvarWrites` (#2469) and
`Rigor::Inference::InterveningIvarReset` (#2036) each say that `NON_RUNNING_NODES` "lists a def and a class,
module or singleton class body only as code" that does not run on the self in question, and
`Rigor::Inference::SelfCallIvarWrites` (#1965) that it "lists `class << self` and `extend` only as code the
proof declines to read past". Each says that it derives no declaration context or records no declaration fact,
and each is a row with a reason of its own, not a grandfathered one. This row is one more of that kind.

#3021 is the nearer row and of another kind, a function's: it listed the helpers of the computed-send reading,
and its entry says of `collect_local_send_names` that it "reads `LOCAL_SCOPE_BOUNDARIES` and appends the
literals it finds", a consumer and no producer. That entry weighed restructuring the code to dodge the scanner
and declined it, and was ratified by `e82a47057`, "Ratify the remaining five approval queue entries"
(2026-11-15). The grandfathered pin keeps its count of 366; only its digest moves, for the ten grandfathered
keys the slice re-keys.

Two mutations in the pull request hold the row to the gate: taken out of `producers.yml` it fails "lists
exactly the producers the tree has" (X7), and marked `grandfathered` it fails "keeps the grandfathered list
closed" (X10).

## To undo

Move `LOCAL_SCOPE_BOUNDARIES` and its `private_constant` line back into `scope_indexer.rb`, delete the row, and
spell nothing else: `MixinEffects` reads the name lexically. The self-typing scan then reads the two
`LOCAL_SCOPE_BOUNDARIES.any?` calls as `Dynamic`, as it reads the calls on the five constants that stayed,
until #3416 changes what a frozen Array publishes across files. Nothing else depends on the row.
