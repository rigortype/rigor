# `ScopeIndexer::ClassCvarCensus` exposes four functions, takes `JoinOnlyCvarWrite` with it as a public constant and keeps the shadow oracle private, and the three `Dynamic` call sites the move adds to the self-typing scan are accepted

- **PR:** [#3396](https://github.com/rigortype/rigor/pull/3396)
- **Issue:** [#3346](https://github.com/rigortype/rigor/issues/3346)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-26

## Background

Slice U5 of ADR-116's amendment for #3346 moves the class-variable census out of
`scope_indexer.rb`, whole, into `ScopeIndexer::ClassCvarCensus` under `scope_indexer/`. The
amendment says a cluster moves "behind its entry" and counts this one's calls back into what stays
(one). It does not say what the module shows of itself, and three facts of the cluster left that
open.

- `ClassCvarsCollector`, the collector on the shared walk and a file of its own since WD5, calls
  three of the 13 functions on the indexer by name: `collect_def_cvar_writes` from `on_def`,
  `collect_body_cvar_writes` from `on_declaration`, and `finished_cvar_census` from `table` and
  `hierarchy_table`. So the cluster has one entry from `scope_indexer.rb`
  (`build_class_cvar_index`, which `index` calls) and three more from a sibling file. U1 to U3 each
  had one function another file calls, and pinned `singleton_methods(false)` to it.
- `legacy_class_cvar_index`, the walker the collector replaced, is called by the entry under
  `RIGOR_SHADOW_RULE_WALK` and by two specs that compare it with the collector
  (`scope_indexer_class_cvars_equivalence_spec.rb` and
  `scope_indexer_superclasses_equivalence_spec.rb`). On `ScopeIndexer` every `module_function` is
  public, so the specs called it directly.
- `JoinOnlyCvarWrite`, the mark a joining write carries in the census's accumulator, is defined in
  the middle of the cluster as a `private_constant` of `ScopeIndexer`, and
  `scope_indexer/cvar_hierarchy.rb` reads it by its bare name, which resolves through
  `ScopeIndexer`'s own scope.

The module also needed a name, which the amendment leaves to the slice (`ScopeIndexer::<Name>`).

The move also costs the self-typing ratchet three call sites, which U1 to U3 did not. The gather
(`gather_cvar_writes`) reads two names that stay in `scope_indexer.rb` because the ivar census reads
them too: `IVAR_BARRIER_NODES`, a frozen Array, and `BindingTargets`, a private module. Read from
another file the Array types `Dynamic[top]`
([#3392](https://github.com/rigortype/rigor/issues/3392)), and `BindingTargets.names(…)` is a call
of a function no signature declares, whose result the scan inferred from the body while both were in
one file. So `IVAR_BARRIER_NODES.any? { … }`, `BindingTargets.names(…)` and the `.each` on it read
`Dynamic` at the head: 50,948 to 50,951 `Dynamic` call sites, both arms from `git archive`. A move
may not change a body to avoid them.

## Options and trade-offs

**What the collector calls.**

- *Leave the three functions on `ScopeIndexer`* and move the rest. The gather
  (`gather_cvar_writes`, the two recording steps) is reached only through them, so it would stay
  too, and what moved would be the entry and the oracle's six functions, calling back three
  functions instead of one. That is inside the cut-off (#3318 allows four), and it is not the census
  moving whole.
- *Move them and have the collector `send` them.* A `send` in `lib/` hides the call from the
  producers gate, which follows a module only from calls spelled on it.
- *Move them and leave them public.* The module then shows four functions: the entry and the three
  a sibling calls. The mirror spec pins that list, so a fifth is a visible edit.

**The oracle.**

- *A fifth public function.* The specs call it as they did. It would be public for the specs alone:
  no file under `lib/` calls it but the module itself, and the list the mirror spec pins would hold
  a function that goes when WD5 finishes its ports.
- *Private, reached through `send` from the two specs.* The public list is exactly what other files
  of `lib/` call. `declaration_signature_spec.rb` (#3389) reaches two private functions of its
  module the same way. A stub of it (`allow(...).to receive(:legacy_class_cvar_index)`) works on a
  private function, and the example that uses one fails when the entry runs the oracle with the flag
  unset.

**The constant.**

- *Leave it on `ScopeIndexer`.* `cvar_hierarchy.rb` is untouched and the moved bodies read it
  lexically, as they read `EMPTY_NESTING`, `IVAR_BARRIER_NODES` and `BindingTargets`. It would be a
  constant of the indexer that the indexer no longer reads, one more item for WD10's list of what
  stays and why.
- *Move it and bind `ScopeIndexer`'s name to it*, as R1 bound the five lists the indexer still
  reads. The indexer does not read this one.
- *Move it with the census.* The moved bodies still read it by its bare name. `CvarHierarchy` reads
  `ClassCvarCensus::JoinOnlyCvarWrite` at two sites, and a constant another module reads by a path
  cannot be private, so it is public on the module, where the mirror spec pins it as the one
  constant. R1's exported constants are the precedent for a constant that leaves with its cluster
  and is pinned where it lands.

**The three call sites.**

- *Declare `IVAR_BARRIER_NODES` and `BindingTargets.names` in `sig/`.* It closes them with two
  hand-written rows for the provenance gate to hold, in a slice that is a move; R1 weighed the same
  for its eight and kept the declaration as the fallback.
- *Move the two names with the census.* The ivar census, which stays, reads both at more sites than
  the gather does, so the boundary would be crossed from the other side.
- *Accept them.* Precision is 0.5989 against a pin of 0.5958 and the `Dynamic` call share 0.4964
  against 0.4983, each better than its pin, and the share falls by 0.001 points because the new file
  brings nine call sites.

**The name.** `ClassCvars`, after the table (`ClassDeclarations`, `LiteralReceiverMutations` and
`PublishedConstantIvars` say what each table holds), would sit beside `ClassCvarsCollector` with
nothing to tell which is the walk's collector and which the census it calls. `ClassCvarCensus` is
what the code calls it (`finished_cvar_census`, "the class-cvar census" in `cvar_hierarchy.rb` and
`producers.yml`) and what the amendment calls the slice; `MutatedElementCensus` is a sibling named
the same way.

## Decision

The three functions the collector calls move and stay public, beside the entry; the oracle is
private and the two equivalence specs call it through `send`; `JoinOnlyCvarWrite` moves with the
census and is public there; the module is `ClassCvarCensus`; and the three `Dynamic` call sites are
accepted, with no pin in `tool/coverage_ratchet.yml` touched.

Each follows the amendment's "moves whole, behind its entry" as far as the code allows without a
port: nothing of the census is left in `scope_indexer.rb`, and the one call back is
`ScopeIndexer.census_body_scope`, the scope the ivar and constant censuses also ask for. The
precedent is the amendment itself: for the namespace and the cut-off, and, in what it decides for
`DeclarationWalk::Rules`, for a public list a spec pins and for constants that move with their
cluster. A spec reaching a private function of the module it mirrors is what
`declaration_signature_spec.rb` does since #3389. For the call sites, #3392 (`known-limitation`) carries the first;
the other two come back when `BindingTargets.names` is declared in `sig/`, or when the gather and
that module are in one file again.

Four smaller choices follow landed slices and need no ruling: the equivalence spec stays where it
is, since it compares the collector with the oracle and is not the census's mirror; the comments
that named a moved function name its new home; `tool/probe-693/`, the instrument of a note, keeps
the names it was written with; and the rows of rule (v)'s table for files under `scope_indexer/`
are two lines each where they were three, which keeps the support module inside RuboCop's 200
lines.

## To undo

To make the oracle public, take `:legacy_class_cvar_index` off the module's
`private_class_method` list, add it to the list the mirror spec pins, and replace the `send` calls
in the mirror spec and the two equivalence specs. To put the constant back on the indexer, define it in
`scope_indexer.rb` with its `private_constant`, delete it from the module and from the mirror
spec's pin, and read it bare again at the two sites in `cvar_hierarchy.rb`. To rename the module,
rename the file, its mirror spec, the row in `DeclarationWriterScan::SOURCES`, the section in
`producers.yml` (the grandfathered digest moves, the count does not) and the row in
`typing_state_closure_spec.rb`. To win the three call sites back without #3392, declare
`ScopeIndexer::IVAR_BARRIER_NODES` and `ScopeIndexer::BindingTargets.names` in
`sig/rigor/inference.rbs`. Nothing outside this pull request depends on any of the five yet;
U4, the next slice, meets the oracle's question again for the shared-walk tables.
