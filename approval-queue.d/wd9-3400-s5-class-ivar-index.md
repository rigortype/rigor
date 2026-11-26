# Slice 5 of #3400 moves the class ivar index and the census scope as two modules, `CensusScope` behind the two functions three censuses call and `ClassIvarIndex` behind one, makes public the two constants the class-variable census reads by a path, and gives the new 1,926-line file a budget row

- **PR:** [#3418](https://github.com/rigortype/rigor/pull/3418)
- **Issue:** [#3400](https://github.com/rigortype/rigor/issues/3400)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-26

## Background

ADR-116's re-measure of 2026-11-26 names the class ivar index "one over" the #3318 cut-off, a candidate "once its
slice says which helper moves, as U4's did: it calls four when the census scope is not in the file". It commits
to nothing. #3400 holds the candidates, and this is its fifth and last slice. Re-measured at `156d1a443` with the
re-measure's own scripts, the index is 94 functions and 994 lines of code behind one entry
(`build_class_ivar_index`, which `index` calls once), with 17 constants only it reads in the file, two of them
nested (`MethodEffectResolver`, a class, and `BindingTargets`, a module). It calls back five functions at eight
sites: `census_body_scope` at four, and four recognisers at one each (`def_side`,
`def_receiver_targets_lexical_self?`, `each_attr_macro_name`, `attr_macro`). The census scope is two functions
and seven lines of code, `census_body_scope` and the `census_nesting` it calls, with no call back; two modules
that have already left call it on the indexer, `ClassCvarCensus` at two sites and `ConstantTables` at two.

The coordinator's brief asked the slice to verify that the census scope is the helper that moves, to choose
between a module of its own and the index's module, to confirm what the cut-off's "no ivar writes" half is
about, and to record each. Four more things were open.

- Two of the index's constants are read from another file. `class_cvar_census.rb` reads `IVAR_BARRIER_NODES`
  and `BindingTargets` by their bare names, which resolve through `ScopeIndexer`'s own scope, where both are
  private. U5 left the two on the indexer because the ivar census, which stayed, read both at more sites.
- `collect_class_method_defs` is called by no file of `lib/` and by specs at five sites.
- The index's file is 1,926 lines. Every module the slices of #3346 and #3400 made is under 1,000 lines, and
  `spec/docs/lib_file_budgets_spec.rb` fails for a `lib/` file of 1,000 lines or more with no row: "a new large
  file is a decision".
- What the move costs the self-typing ratchet.

One of the 17 constants lists node classes, which the producers gate reads. That is a row of a gate file and has
an entry of its own, `wd9-3400-s5-class-ivar-index-producers-row.md`.

## Options and trade-offs

**Which helper moves.** Measured for each of the five calls back, the helper taken into the index's module:

| Moved with the index | Calls back | What stays in `scope_indexer.rb` would call the module for |
| --- | --- | --- |
| `census_body_scope` and `census_nesting` | 4 at 4 sites | nothing |
| `census_body_scope` alone | 5 at 5 sites (`census_nesting` is one) | nothing |
| `each_attr_macro_name` and `attr_macro` | 4 at 8 sites (`literal_method_name` is one more) | the methods table (5 sites) and visibility (3) |
| `def_side` | 4 at 8 sites | the methods table (2), the deferred ranges (1), singleton defs (1) |
| `def_receiver_targets_lexical_self?` | 4 at 7 sites | `def_side` (1), visibility (2), the methods table (1) |

Only the census scope is called by no row left in the file. Each of the others would leave three or four rows of
`scope_indexer.rb` calling into a module named for the ivar index.

**A module of its own, or the index's.**

- *The census scope inside the index's module.* One file fewer. The module would show three functions, the
  entry and the two the other censuses call, and `ClassCvarCensus` and `ConstantTables` would ask the ivar
  index for a scope that is no part of an ivar index. `constant_tables.rb` would name that module for nothing
  else.
- *A module of its own.* The re-measure counts the census scope as a row of its own ("2 · 7 · 21 … both are
  entries"). `CensusScope` shows two functions and calls nothing back, the index's module shows its one entry,
  and `class_cvar_census.rb` goes from one call back to none and `constant_tables.rb` from two to none. It is a
  44-line file whose two functions are both its interface, the shape `LeafNodes` went back for (#3319); here
  the row has no host left to go back to that all three callers could name.

**"No ivar writes".** #3318 wrote the cut-off for code leaving a stateful class: a moved method "never reads or
writes an evaluator ivar". `ScopeIndexer` is a module. None of its 498 module functions reads or writes an
instance, class or global variable (0 state nodes in them, 39 in three nested classes), so the half that decides
is the calls back, as the amendment says. The 13 instance-variable nodes of `MethodEffectResolver` are the state
of that class's own instances, each created and dropped inside one call of `method_definite_assigns`. Read the
other way, as "no instance-variable node in what moves", the half would have stopped slice 3, which moved
`AliasMap` and its six nodes with the alias pass.

**The two constants another file reads.**

- *Leave them on `ScopeIndexer`*, read lexically by both censuses, as U5 left them. They stay private and no
  call site changes in `class_cvar_census.rb`. The indexer keeps two names nothing in its file reads, and the
  index's five `IVAR_BARRIER_NODES.any? { … }` calls cross a file: by `docs/internal-spec/inference-engine.md`
  § "The publication census" a constant publishes to other files only as a single-write frozen scalar literal,
  so each would read `Dynamic` in the self-typing scan, and so would its two calls of `BindingTargets`, a
  module whose functions no signature declares.
- *Put them in `CensusScope`*, as what the two censuses share. Neither is part of the scope a census types
  under, the re-measure counts both with the index's row, and all eight reads would then cross a file.
- *Move them with the index, public.* The re-measure counts a row's own constants and nested classes with it.
  Five of the six reads of `IVAR_BARRIER_NODES` and two of the three calls of `BindingTargets` are the index's
  and stay in one file with what they read. `class_cvar_census.rb` reads the two by a path,
  `ClassIvarIndex::IVAR_BARRIER_NODES` and `ClassIvarIndex::BindingTargets`, and a constant another module
  reads by a path cannot be private: U5 decided the same for `JoinOnlyCvarWrite`, which `CvarHierarchy` reads.
  The class-variable census then names the ivar index for two things, where it named the indexer for them.

**The requires of `class_cvar_census.rb`.** The slices' files require the file of what they name. That file now
names `CensusScope` and `ClassIvarIndex`. `census_scope.rb` requires the rules alone. `class_ivar_index.rb`
requires the dispatcher, which requires the `rbs` gem, and the class-variable census loads without either: its
mirror spec loads it in an unbundled child. So it requires `census_scope` and not `class_ivar_index`, and its
header says so, as `constant_tables.rb` says why it does not require `in_effect_refinements.rb`.

**`collect_class_method_defs`.** Private and reached through `send`, as slice 2 left `constant_writes_for_file`
and slice 4 the two include builders; or public, for the specs alone; or left on `ScopeIndexer`, which takes the
row apart. One example of `scope_indexer_spec.rb` called it and nothing else.

**The new file's size.**

- *One file with a budget row.* The row moves whole, as every slice has moved its row, and the file is what the
  row is: 1,812 lines in `scope_indexer.rb`, 1,926 with its header and its `private_class_method` list. The
  budget file gains a row of 2,000, and the indexer's row falls by 1,800.
- *Cut the row so that each file is under 1,000 lines.* Measured on the re-measure's graph
  (`tmp/wd9/split_probe.rb`): no one cut does it. The cleanest is the definite-assignment summary with the
  table of instance defs it reads (22 functions, 231 lines of code, about 360 lines, three entries, no call
  back), which leaves about 1,240 lines; the widening with the census of handed-back ivars (13 functions) calls
  two functions back, and the gather of a body (17) three at eight sites. Two cuts would be three modules with
  calls between them, a design the re-measure did not make, and a row taken apart is where #3398 was met.

**The ratchet.** There was nothing to choose. The slice adds no `Dynamic` call site: 50,986 at the base and at the head, and
no expression of the nine touched files changes tier. Each list, cap and key the index reads moved with it;
the one constant of `scope_indexer.rb` it still reads, `INSTANCE_EVAL_CALLS`, is `ScopeIndexer`'s binding to
a constant of `DeclarationWalk::Rules` and read `Dynamic[top]` before it moved (#3392); and the three sites of
`class_cvar_census.rb` that U5 accepted (#3396) read as they did. The tally of what the file splits of ADR-116
have cost stays at 31 call sites (#3416).

## Decision

Two modules: `ScopeIndexer::CensusScope` in `scope_indexer/census_scope.rb`, showing `census_body_scope` and
`census_nesting`, and `ScopeIndexer::ClassIvarIndex` in `scope_indexer/class_ivar_index.rb`, showing
`build_class_ivar_index`. The cut-off's ivar half is read as being about the module functions. The 17 constants
move with the index; `IVAR_BARRIER_NODES` and `BindingTargets` are public there, `MethodEffectResolver` and
`ATTR_WRITER_MACROS` public as they were, and the other 13 private as they were. `class_cvar_census.rb` and
`constant_tables.rb` require `census_scope.rb`, and the first does not require `class_ivar_index.rb`.
`collect_class_method_defs` moves with its row and is private; the one example that called it alone is in the
mirror spec with its assertion unchanged, and the four calls that stay are spelled
`ClassIvarIndex.send(:collect_class_method_defs, …)`. The index is one file, with a budget row of 2,000.
No pin of `tool/coverage_ratchet.yml` is touched and no `sig/` row added.

The precedent for each is the amendment and the slices landed under it. The amendment moves a cluster "whole,
behind its entry", says of the nested classes that they "move whole with the cluster that builds them", and its
re-measure names the helper's question as this slice's ("as U4's did"). U4
([#3397](https://github.com/rigortype/rigor/pull/3397)) is the precedent for a slice naming the helpers that
move so that a cluster meets the cut-off. U5 ([#3396](https://github.com/rigortype/rigor/pull/3396)) is the
precedent for a constant another module reads by a path being public where it lands. Slice 2
([#3406](https://github.com/rigortype/rigor/pull/3406)) is the precedent for a function only specs call being
private and reached through `send`, for the examples that called it alone moving with their assertions, and for
a header that says which file it does not require and why. Slice 3
([#3409](https://github.com/rigortype/rigor/pull/3409)) is the precedent for a nested class with instance
variables moving with its row. There is no precedent among these slices for a module whose file passes 1,000
lines; the budget gate's own rule is what applies, a row in the pull request that adds the file.

Three smaller choices follow landed slices and need no ruling. Comment links to a module function are spelled
with a dot, `{.x}` inside the module and `{ClassIvarIndex.x}` outside it. Each file has a row in rule (v)'s
table, the census scope's as `mutated_carrier_widening.rb` has one: it writes no table today. And
`ClassIvarIndex` carries a `Metrics/ModuleLength` directive, as `ConstantTables`, `SharedWalkTables` and
`MixinEffects` do.

## To undo

To put the census scope into the index's module, move the two functions, spell the four sites of
`class_cvar_census.rb` and `constant_tables.rb` on `ClassIvarIndex`, and delete `census_scope.rb` with its
mirror spec and its rows in `typing_state_closure_spec.rb` and `DeclarationWriterScan::SOURCES`; no row of
`producers.yml` moves. To rename a module, rename the file, its mirror spec, those two rows, the calls spelled
on it, and for the index its section of `producers.yml` (43 grandfathered keys, so the pin's digest moves again)
and its budget row. To make `IVAR_BARRIER_NODES` and `BindingTargets` private again, move them back to
`scope_indexer.rb` with their `private_constant` lines and read them by their bare names in both census files;
the index's reads then cross a file. To make `collect_class_method_defs` public, take it off the
`private_class_method` list and spell the five spec sites without `send`; the mirror spec's "exposes the entry
alone" then lists two functions. To cut the index's file, start from the definite-assignment summary: 22
functions behind `build_method_assign_effects`, `collect_class_method_defs` and `dead_transient_nil_writes`,
with `MethodEffectResolver` and `SAME_CLASS_CALL_DEPTH_CAP`, calling nothing back.
Nothing outside this pull request depends on any of these yet. #3400's candidate list is done with this slice;
WD10 ([#3401](https://github.com/rigortype/rigor/issues/3401)) reads `scope_indexer.rb` at 7,207 lines under a
budget of 7,300, and the grandfathered pin at the digest this slice leaves.
