# `ScopeIndexer::SharedWalkTables` takes the three readers of a factory call's member list with it and leaves `add_header_nesting` behind, so that it calls back three functions; it exposes eight, keeps the builders and the shadow oracles private, and the two `Dynamic` call sites the move adds to the self-typing scan are accepted

- **PR:** [#3397](https://github.com/rigortype/rigor/pull/3397)
- **Issue:** [#3346](https://github.com/rigortype/rigor/issues/3346)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-26

## Background

Slice U4 of ADR-116's amendment for #3346 moves the tables one shared `DeclarationWalk` builds for a
file (the superclasses with their header nestings, the def nestings, and the `Data.define` and
`Struct.new` member layouts) out of `scope_indexer.rb`, with the recorders their three collectors
call and the walkers those collectors replaced. The amendment counts five calls from that cluster
back into the file and leaves the answer to the slice: "that slice states which helpers move with
it to meet the cut-off, or why the cluster stays". The cut-off (#3318) is four.

Recounted at `57657b119` from a Prism call graph of the file, the cluster is 42 functions and the
five are `rebound_block_self` (which block rebinds `self`, asked by the scan for the mixin names a
header nesting is keyed by), `merge_header_nesting_bucket` (the bucket merge of the header-nesting
table, which the cross-file fold calls too), and `resolve_meta_factory_call`, `meta_member_names`
and `meta_members_open?` (the factory call an expression unwinds to, and its member list, which the
two layout recorders ask). No function of the cluster reads or writes an instance, class or global
variable.

Five more things were open once the helpers were chosen, the first four as they were for U5
(`wd9-u5-cvar-census.md`, still in this queue, so a sibling and not a precedent): what the module
shows of itself, where the walkers the collectors replaced stand, the module's name, and what the
move costs the self-typing ratchet. A fifth is this slice's own: the module is about 470 lines by
RuboCop's count, against its limit of 200 for a module.

## Options and trade-offs

**Which helpers move.** Three of the five calls go to one group of six functions that read a
`Data.define` or `Struct.new` call, and the methods table reads it as well.

- *The three that read the member list* (`meta_member_names`, `meta_members_open?` and
  `meta_member_positionals`, 10 lines of code). The member list is what a layout table holds. One
  function that stays, `record_meta_member_names`, which registers a reader per member in the
  methods table, then asks the module at two sites. Three calls back.
- *The three that unwind an expression to its factory call* (`resolve_meta_factory_call` and its two
  helpers). Four calls back, which is the cut-off itself. Two functions that stay call it
  (`record_meta_members` and `record_meta_new_constant?`, the methods table and the
  discovered-classes walk), on paths that have nothing to do with a layout.
- *All six.* Two calls back, and four call sites in three functions of the file that ask a module
  of tables for something a table is not about.
- *A module per table.* The def nestings (8 functions, 92 lines of code) call nothing back, the
  superclass tables (17, 165) two functions and the layouts (16, 187) three, so each would pass
  without a helper moving, and each would fit RuboCop's 200 lines for a module. The five calls would
  still be five: the count the amendment made is of what the slice leaves the file calling, not of
  how many files it is spread over. The three modules would share one entry and one root context,
  which would stay in `scope_indexer.rb` or make a fourth module, and rule (v)'s table in
  `spec/support/declaration_fact_sources.rb` had five lines left before RuboCop's limit, where three
  rows are six.
- *The cluster stays.* The amendment allows it. The measurement gives no reason: the cut-off is met
  by moving ten lines that are the layout tables' own reading.

**`add_header_nesting`.** By the call graph it belongs to the cluster: one function calls it,
`record_declaration_ancestry`, which moves. Moved, it calls `merge_header_nesting_bucket` back.

- *Move it.* The producers gate's rule (v) finds `add_header_nesting` because it hands its `table`
  parameter to a writer in the same file, and the rule follows a table inside a file and never from
  one file into the next. Moved, it is no producer the gate can see: its grandfathered row has no
  key to move to, and the closed list would read 365 where 366 is pinned, for a function that
  writes the table as it did.
- *Leave it, and call it back.* It stays beside `merge_header_nestings` and the bucket functions,
  which are the cross-file fold's and WD2's. The module then knows that a site adds a nesting under
  its names, and nothing of buckets or of the unkeyed entry. The call back is one function either
  way, and 22 grandfathered rows move with their keys renamed and the count unchanged.

**What the module shows.** Other files of `lib/` call eight of its functions: `scope_indexer.rb`
the entry and the two readers of a member list, `SuperclassesCollector` and `MemberLayoutsCollector`
the four recorders, `CvarHierarchy` `recorded_ancestor_name`. Ten more are called by specs alone:
the builders that run one collector on a walk of its own (`build_superclass_tables`,
`build_def_nestings`, `build_data_member_layouts`, `build_struct_member_layouts`,
`member_layout_tables`), whose comments say that nothing in `lib` calls them; the four walkers the
collectors replaced; and `superclass_walk_root`, which one equivalence spec asks for a walk's root
context.

- *Eighteen public functions*, the specs calling the ten as they did.
- *Eight*, what other files of `lib/` call, with the ten private and reached through `send` from
  the mirror spec, the two equivalence specs and two more. 29 call sites in five spec files
  change their spelling and none its assertion.

**The name.** `DeclarationWalkTables`, after the entry (`declaration_walk_tables`), reads as a part
of `DeclarationWalk`, which it is not: it is a client of the walk inside `ScopeIndexer`.
`SharedWalkTables` is what the amendment calls the slice ("the shared-walk tables"), what the code
calls the run ("ONE shared {DeclarationWalk}") and what the equivalence spec is named for
(`scope_indexer_shared_walk_spec.rb`).

**The two call sites.** `mixin_call?`, which moves, reads `MIXIN_CALL_NAMES`, a frozen Array of
`scope_indexer.rb` that three functions of the mixin tables read too. Read from another file an
Array constant types `Dynamic[top]` ([#3392](https://github.com/rigortype/rigor/issues/3392)), so
`MIXIN_CALL_NAMES.include?(node.name)` and the `mixin_call?(node)` that returns it read `Dynamic`
where the scan had both in its `constant` tier.

- *Leave `mixin_call?` in `scope_indexer.rb`.* Measured on a scratch tree: the first call site
  keeps its tier, and `ScopeIndexer.mixin_call?(node)` in the module still reads `Dynamic`, so one
  call site is won back for a fourth call back, of a function only the module calls.
- *Move the constant.* The three readers that stay would read it across the boundary instead.
- *Declare it in `sig/`.* A hand-written row for the provenance gate to hold, in a slice that is a
  move.
- *Accept them.* Both ratchet figures stay better than their pins.

**The module's length.** One module needs `# rubocop:disable Metrics/ModuleLength` inline on its
`module` line, as `NodePropagation` (#3311) and `DeclarationWalk::Rules` (R1) carry it. The split by
table above needs none.

## Decision

The three readers of a member list move; `add_header_nesting` stays and is one of the three
functions the module calls back; the module is `SharedWalkTables`, with eight public functions and
the builders and walkers private; the two `Dynamic` call sites are accepted, with no pin in
`tool/coverage_ratchet.yml` touched; and the module carries the inline `Metrics/ModuleLength`
directive.

The precedent for each is the amendment itself: it names moving helpers as the way to meet the
cut-off, it moves a cluster "whole, behind its entry" inside `ScopeIndexer`'s namespace, and in
what it decides for `DeclarationWalk::Rules` it pins a public list to what other files call and
reports a ratchet delta without tightening or loosening a pin. The helpers chosen are the fewest
lines that are the layout tables' own, and they leave the count at three, one under the cut-off.
`add_header_nesting` is the one place where the call graph and a gate disagreed, and the gate's
reading is kept: a move may not take a writer out of the producers list by putting a file boundary
between it and the table it writes.

Three smaller choices follow landed slices and need no ruling. The two equivalence specs stay where
they are and call the module, as U5's did. The 16 examples of `scope_indexer_spec.rb` that called a
builder and nothing else move to the mirror spec with their assertions unchanged. And comment links
to a module function are spelled with a dot (`{.x}`, `{ScopeIndexer.x}`), which the review of #3396
asked of that slice's file and of this one's.

## To undo

To move `resolve_meta_factory_call` as well, cut it and its two helpers into the module, add it to
the public list the mirror spec pins, and spell the two calls left in `scope_indexer.rb` on the
module; the calls back fall to two. To put the member-list readers back, move the three functions to
`scope_indexer.rb` and spell the module's four calls on `ScopeIndexer`; the calls back rise to
five, over the cut-off. To move `add_header_nesting`, cut it into the module, call
`ScopeIndexer.merge_header_nesting_bucket` from it, delete its row from `producers.yml` and lower
the grandfathered pin to 365 with the reason at the pin. To make a builder or a walker public, take
it off the module's `private_class_method` list, add it to the list the mirror spec pins, and
replace the `send` calls in the mirror spec, `scope_indexer_shared_walk_spec.rb`,
`scope_indexer_superclasses_equivalence_spec.rb`, `layered_def_nestings_spec.rb` and
`scope_indexer_spec.rb`. To rename the module, rename the file, its mirror spec, the row in
`DeclarationWriterScan::SOURCES`, the section in `producers.yml` (the grandfathered digest moves,
the count does not) and the row in `typing_state_closure_spec.rb`. To win the two call sites back
without #3392, declare `ScopeIndexer::MIXIN_CALL_NAMES` in `sig/rigor/inference.rbs`. Nothing
outside this pull request depends on any of these yet; step 7 of the amendment, the re-measure
table, reads the three calls back as they are here.
