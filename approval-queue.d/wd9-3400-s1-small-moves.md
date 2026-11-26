# Slice 1 of #3400 names three modules `MutatedCarrierWidening`, `FactoryCallResolver` and `SingletonClassSources`, shows of each only what another file calls, lets `index` pass RuboCop's method length under its directive, gives each module a row in rule (v)'s table, and accepts two `Dynamic` call sites in the self-typing scan (net +1)

- **PR:** [#3405](https://github.com/rigortype/rigor/pull/3405)
- **Issue:** [#3400](https://github.com/rigortype/rigor/issues/3400)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-26

## Background

ADR-116's re-measure of 2026-11-26 names seven clusters of `scope_indexer.rb` that meet the #3318 cut-off
and commits to none: "each is a slice of its own". #3400 holds them. Its first slice takes the three
smallest and the deletion: the mutated-carrier widening (7 functions, no call back, 4 entries), the
factory-call resolver (3, none, 1), the singleton-class sources (4, 2 calls back, 1) and the two functions
nothing calls. Re-measured at `1a72c0580` with the re-measure's own scripts, the three rows are as the table
has them.

The amendment says a cluster moves "whole, behind its entry" to `ScopeIndexer::<Name>` and leaves the rest to
the slice. Six things were open.

- The names.
- What each module shows. The widening has three constants (`NO_ELEMENT_MUTATIONS`,
  `NO_CVAR_ELEMENT_MUTATIONS`, `CENSUS_CONTENT_CLASSES`) that only it reads, public on `ScopeIndexer` at the
  base because nothing marked them private. One spec called `census_mutated_type` on the indexer through
  `send`.
- `index` is 30 lines by RuboCop's count, which is `Metrics/MethodLength`'s limit, and calls both wideners.
  Each call fitted two lines. Spelled on a module of 22 characters, neither does.
- Rule (v)'s table (`DeclarationWriterScan::SOURCES`) has a row for each module that left the indexer so far, and
  each of those writes a table it is handed. Two of these three write none.
- Where the resolver goes. U4's entry (`wd9-u4-walk-tables.md`, still in this queue) names moving it into
  `SharedWalkTables` as the way to undo its own choice.
- What the move costs the self-typing ratchet, which U1 to U3 paid nothing of and U5 and U4 three and two call
  sites.

## Options and trade-offs

**The names.** Each is what ADR-116's table calls the row. `MutatedCarrierWidening` sits beside
`MutatedElementCensus`, which it asks and which asks it back; `MutationWidening` is taken by
`Inference::MutationWidening`, which a module of that name under `ScopeIndexer` would shadow for every
function of the indexer. `FactoryCallResolver` holds `resolve_meta_factory_call`; `MetaFactoryCall`, after the
function, reads as a value. `SingletonClassSources` is the table's own name (`singleton_class_sources`).

**What each module shows.** As U1 to U5 decided: the functions another file of `lib/` calls are public and
the rest go on `private_class_method`, with the mirror spec pinning the public list. That is four functions
for the widening (`index` calls two, `ConstantIvarValue` one of those, `MutatedElementCensus` the other two)
and one each for the others. The three constants move with the widening and stay public, as they were: a
`private_constant` would be a change the base did not have, and the mirror spec pins the list and that none
is left on the indexer. The example that reached `census_mutated_type` through `send` moves to the mirror
spec and calls it as the public function it now is.

**`index`.**

- *A shorter name.* The two statements keep their two lines only under a name of 13 characters or fewer.
  None of that length says what the module is, and the next slice of #3400 lengthens the second statement
  again whatever this module is called: `build_in_source_constants`, its first argument, moves with the
  constant tables.
- *A local for the census* (`cvars = ClassCvarCensus.build_class_cvar_index(…)`). A statement the base does
  not have, in a slice that is a move.
- *Leave the widening.* It calls nothing back and is the cleanest of the three.
- *Add `Metrics/MethodLength` to the directive `index` already carries* for `Metrics/AbcSize`. The file has
  five other directives that name the cop. `index` is 32 lines against 30.

**Rule (v).** The table's comment asks a row of "a module that leaves `scope_indexer.rb` with a table writer".
That is `SingletonClassSources`: `record_singleton_class_sources` writes its `sources` parameter, and its two
`producers.yml` rows re-key to the new file with their reasons. Run with a row each, the rule finds no writer in
the other two: `FactoryCallResolver` takes no table, and `MutatedCarrierWidening` writes only the copy it answers.

- *A row for the one module that writes.* What the comment asks, and two lines. A function of the other two that
  began to write into a parameter would not be listed until its file had a row, where in `scope_indexer.rb` it
  would have been listed the day it was written. This was the first choice while the support module had three
  lines left under RuboCop's 200; #3403 landed during the slice and left it 47.
- *A row for each.* Six lines. The rule goes on reading what it read while the three were in `scope_indexer.rb`,
  and since #3398 it follows a table from a caller into a writer of another listed file only when that file has
  a row. Mutation rows X1a to X1f of the pull request show the difference: a write into the table a widener is
  handed, or into the resolver's argument, is listed with the row and is not without it.

**The resolver.** Inside `SharedWalkTables` it would be one function more on that module's public list, asked
by the methods table and the declaration artifacts for something no layout table is about, which is why U4
left it. As a module of its own it is asked by both files, and `SharedWalkTables` calls back two functions
where it called three. `shared_walk_tables.rb` requires it, since a file under `scope_indexer/` requires what
it names.

**The ratchet.** `singleton_side_call?` asks `ScopeIndexer.surface_rewriting_call?`, a recogniser that stays because
three other walkers ask it. Its body tests a call's name against four constants of `scope_indexer.rb`, and called
on the module from another file it types `Dynamic[top]` where it typed `constant` in its own. That is the
project-wide constant publication rule (a `Set[...].freeze`, a mutable literal or a Regexp publishes nothing
across files), met through a call. It is not [#3392](https://github.com/rigortype/rigor/issues/3392)'s shape:
that issue covers a constant bound to another file's Array or String, and its landing would leave these Sets
and the Regexp `Dynamic`. So that call and `singleton_side_call?(node)`, whose
answer it decides, read `Dynamic` at the head. The deletion takes one `Dynamic` call site with it, so the scan
reads 50,953 → 50,954 `Dynamic` call sites, both arms from `git archive`. A move may not change a body to avoid
them.

- *Declare `surface_rewriting_call?` in `sig/`.* One row for the provenance gate to hold, in a slice that is a
  move; U5 and U4 weighed the same for their three and two.
- *Move the recogniser with the module.* Three walkers that stay call it.
- *Leave the singleton-class sources.* They meet the cut-off, and the cost is the kind the issue names.
- *Accept them.* Precision is 0.5990 against a pin of 0.5958 and the `Dynamic` call share 0.4963 against 0.4983,
  each better than its pin.

## Decision

The modules are `MutatedCarrierWidening`, `FactoryCallResolver` and `SingletonClassSources`, each a file of its
own; each shows what another file calls and keeps the rest private, and the widening's constants stay public;
`index`'s directive names `Metrics/MethodLength`; rule (v)'s table gains a row for each of the three; and the two
`Dynamic` call sites are accepted, with no pin in `tool/coverage_ratchet.yml` touched.

The precedent for each is the amendment: it moves a cluster "whole, behind its entry" inside `ScopeIndexer`'s
namespace, leaves the name to the slice, and in what it decides for `DeclarationWalk::Rules` pins a public
list to what other files call. The directive is the one place where a gate and the move disagreed. The code
keeps the shape the move gives it, and the gate is told so on the line that already tells it about the same
method; `NodePropagation` (#3311) and `DeclarationWalk::Rules` (R1) carry `Metrics/ModuleLength` directives
for the same reason.

Three smaller choices follow landed slices and need no ruling. Comment links to a module function are spelled
with a dot (`{.x}`), which the review of #3396 asked. The comments that named `def_singleton?` as live name
`def_side`, the function `ModuleFunctionState` and `record_deferred_def` call. And `SharedWalkTables`' head
comment and its mirror spec say two calls back, with the example that loads the file alone answering the
layout it could not answer before.

## To undo

To rename a module, rename the file, its mirror spec, its rows in `typing_state_closure_spec.rb` and
`DeclarationWriterScan::SOURCES` and the calls spelled on it; for `SingletonClassSources` also the section in
`producers.yml` (its two rows are not grandfathered, so the pin does not move). To take the directive off
`index`, bring the two statements back to two lines each, which a module name of 13 characters or a local for
each first argument allows. To take the two rows that list no writer off rule (v)'s table, delete two lines
each from `SOURCES` and say so in its comment; no row of `producers.yml` moves. To fold the resolver into
`SharedWalkTables`, cut its three functions into that module, add `resolve_meta_factory_call` to the list its
mirror spec pins, and spell the two calls in `scope_indexer.rb` on it. To make a constant of the widening
private, add `private_constant` to the module and drop the name from the mirror spec's list. To win the two
call sites back, declare `ScopeIndexer.surface_rewriting_call?` in `sig/rigor/inference.rbs`, or widen the
constant publication rule to frozen Sets and Regexps; #3392 alone does not.
Nothing outside this pull request depends on any of these yet; the next slice of #3400, the constant tables,
reads `SharedWalkTables`' two calls back as they are here, and meets `index` at 32 lines.
