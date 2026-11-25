# The declaration of `collect_class_decls` moves with its `def` into a declared `ScopeIndexer::ClassDeclarations` and takes the `def`'s parameter list, and each of the three modules U1 to U3 moved requires `declaration_walk/rules` itself

- **PR:** [#3393](https://github.com/rigortype/rigor/pull/3393)
- **Issue:** [#3346](https://github.com/rigortype/rigor/issues/3346)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-26

## Background

Slices U1 to U3 of ADR-116's amendment for #3346 move three collectors out of `scope_indexer.rb`,
each whole and behind its one entry, into modules under `scope_indexer/`: the class-declaration walk
(`ClassDeclarations.collect_class_decls`), the #540 mutation census
(`LiteralReceiverMutations.collect_literal_receiver_mutations`) and the #667 published-constant ivar
census (`PublishedConstantIvars.seed_published_constant_ivars`). The amendment fixes what moves, the
namespace and the gates. It left two things to the slice.

`sig/rigor/inference.rbs` declared one of the 27 moved functions:
`ScopeIndexer.collect_class_decls: (untyped node, Array[String] qualified_prefix, Hash[String, Type::t] accumulator) -> void`.
The amendment says of R1 that it "adds no `sig/` rows, since none of the moved `def`s has one", and
says nothing of a slice whose `def` has one. The provenance gate's existence rule (#839) fails a
declaration whose method is gone, so the row could not stay where it was.

The row also listed fewer parameters than the `def`, which takes `compacts = nil`,
`self_prefix = nil` and `singleton_cref: false` after the three. That was latent: the two callers
that pass `compacts` called the function with no receiver, and the self-check did not hold them to
the declaration. Called on the new module they are held to it, and `rigor check` reported
`call.wrong-arity` ("given 4, expected 3") at both.

R1 kept the require of `declaration_walk/rules.rb` in `scope_indexer.rb` alone, at the end of the
`require_relative` block at its head: the file declares the declared-names slot, and requiring it
from the walk, which loads earlier, would move that slot from 87 to 85. The three new modules call
`DeclarationWalk::Rules` in nearly every function, and #3389's modules require the file of each
constant they name so that each loads alone.

## Options and trade-offs

**The declaration.**

- *Delete the row.* The gate passes (declarations compared with a `def` fall from 1,135 to 1,134,
  above the floor of 1,132). The five callers in `scope_indexer.rb` then read the entry's return as
  whatever the body infers, and a declared `void` is a contract a move has no reason to withdraw.
- *Leave a delegator on `ScopeIndexer`* for the row to describe, as #3311 left `propagate`. `index`
  still calls that one; this would have no caller, since every caller names the module (the
  producers gate follows a module only from calls spelled on it), and the amendment moves a cluster
  "behind its entry".
- *Move the row with the `def`* into a `module ClassDeclarations` declared inside
  `module ScopeIndexer`. The row stays `return_intent` and paired with its `def`; no pin moves
  (unmarked residue 538, `parameter_only` 33 and 1,135 compared, each as before; one more row, the
  module's header, which is no method).

**The parameter list**, once the row had moved.

- *Leave the three parameters and suppress the two findings*, or spell the two calls some way the
  self-check does not read. Both hide a declaration that says less than the function takes.
- *Give the row the `def`'s list*: `?untyped compacts, ?untyped self_prefix,
  ?singleton_cref: untyped` after the three, which is what `rigor sig-gen --print` proposes for
  them, with the three declared types and the `void` return as they were. The self-check is clean,
  the provenance figures above do not move, and the self-typing ratchet reads the same with either
  list.
- *Type the three* (`Hash[String, [String, String]]?`, `Array[String]?`, `bool`). Each is a claim
  to check against every caller and every recursive call of the walk, in a slice that is a move.

**The require.**

- *No require of `rules.rb` in the new files*, as `certainty.rb` and `member_layouts_collector.rb`
  call it. Each new file would then fail at its first header when loaded alone, and the mirror specs
  could not show what each file needs.
- *Each new file requires it.* `scope_indexer.rb` requires the three files after `rules.rb`, so
  under every product path the require loads nothing: `TypingState.slots` has the same names in the
  same order under `require "rigor"`, a check run, the indexer alone, the LSP path and a plugin
  load, with the declared-names slot at 87, 87, 85 and 89 on the first four. The risk is a later
  file that requires one of the three before the head block reaches `rules.rb`; the slot-order
  measurement every WD9 slice carries would show it.

## Decision

The row moves with its `def` and takes the `def`'s parameter list, the added parameters untyped,
and each new file requires `declaration_walk/rules`.

For the declaration the precedent is WD12, whose slices declared the functions they moved under the
new module (`wd12-s4-refined-sig.md` and its siblings, still in this queue, so siblings and not
precedents). For its list it is the provenance gate's advice for a declared list that does not fit
its `def`, "regenerate the shape with `rigor sig-gen --print` and keep the declared parameter types;
the parameter TYPES are yours, the list is the def's" (`spec/rigor/sig_gen/provenance_spec.rb`).
This list fit the gate, since the `def` accepts every call it admits (#3335), and still said less
than the `def` takes. For the require it is #3389's rule that a module names the file of each
constant it reads, held to the amendment's own test, the slot order on every load path.

The self-typing ratchet needed no decision: the slice adds no `Dynamic` call site (50,948 before and
after), so nothing joins the 8 that `wd9-r1-rules.md` accepts until
[#3392](https://github.com/rigortype/rigor/issues/3392). The four reads of a bound name in the moved
code were `Dynamic` at the base and are `Dynamic` read from the nested module.

## To undo

For the declaration, delete the `module ClassDeclarations` block from `sig/rigor/inference.rbs`;
nothing else names it, and the provenance pins stay where they are. To type the three added
parameters, replace each `untyped` in that row. For the require, delete the
`require_relative "../declaration_walk/rules"` line from the three files and the "loads without the
indexer" example from each mirror spec, which depends on it.
