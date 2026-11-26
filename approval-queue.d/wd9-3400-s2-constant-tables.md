# Slice 2 of #3400 moves the constant tables as one module, `ConstantTables`, behind four functions, takes `CONSTANT_UNPUBLISHABLE` and the binding of `OBJECT_OWNER` with it, leaves `in_effect_refinements.rb` unrequired, keeps `index`'s method-length directive, and accepts three expressions that read `Dynamic` in the self-typing scan

- **PR:** [#3406](https://github.com/rigortype/rigor/pull/3406)
- **Issue:** [#3400](https://github.com/rigortype/rigor/issues/3400)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-26

## Background

ADR-116's re-measure of 2026-11-26 names the constant tables of `scope_indexer.rb` a candidate "as one module
behind four entries" and commits to nothing: "each is a slice of its own". #3400 holds the candidates, and
this is its second slice. The row is three things: the typed in-source walk (`build_in_source_constants`, 9
functions), the publication census (`constant_write_census`, 22) and the write-target rules both ask
(`rebound_block_self`, `self_write_name`, …, 9). Re-measured at `13cd8581f` with the re-measure's own scripts
it is as the table has it: 40 functions, 336 lines of code, 752 lines, two calls back (`census_body_scope` and
`census_nesting`, one site each), four entries, six rows of `producers.yml`, three of `sig/`.

The amendment says a cluster moves "whole, behind its entry" to `ScopeIndexer::<Name>` and leaves the rest to
the slice. Seven things were open.

- One module or several. Apart, the three sub-clusters call 6, 6 and 1 functions outside themselves.
- The name, and what the module shows. `constant_writes_for_file` has a row in `sig/` and no caller in `lib/`:
  six sites of `scope_indexer_spec.rb` reach it through `send`.
- Which constants move. Four are read by these functions alone. One of them, `CONSTANT_UNPUBLISHABLE`, is
  public and stands beside `CONSTANT_MEMO`, which other files read; another, `OBJECT_OWNER`, is one of the five
  names `ScopeIndexer` binds to `DeclarationWalk::Rules`' constants, which `rules_spec.rb` looks up on
  `ScopeIndexer`.
- What the file requires. It names `InEffectRefinements`, whose file does not load alone.
- `index`, which slice 1 left at 32 lines under a directive, calls the typed walk's entry.
- The module is 336 lines of code against `Metrics/ModuleLength`'s 200.
- What the move costs the self-typing ratchet.

## Options and trade-offs

**One module or several.** Measured from the call graph of the file, each sub-cluster on its own:

| Sub-cluster | Functions · lines of code | Calls outside itself | Functions other code calls |
| --- | --- | --- | --- |
| The typed walk | 9 · 92 | 6: `census_body_scope`, and five of the rules | 1 |
| The publication census | 22 · 186 | 6, all of the rules | 1 (and `constant_writes_for_file`, from the specs) |
| The write-target rules | 9 · 58 | 1: `census_nesting` | 7 of the 9 |
| Together | 40 · 336 | 2 | 4 |

- *Three modules.* Each meets the cut-off if a call on a module that has left is not counted, which is the
  re-measure's rule. The rules' module would show seven of its nine functions, the shape `LeafNodes` went back
  for (#3319) and the reason the refinement readers stay. The walk and the census would each spell five or six
  calls on it.
- *Two*, the walk with the rules and the census apart. The census still calls six functions of the other, and
  that module shows seven.
- *One.* Four of 40 functions are entries, two calls go back, and the calls between the three stay receiverless,
  so the 47 moved statements are the base's apart from the two calls back.

**The name and the list.** `ConstantTables` is what ADR-116's table calls the row; no constant of that name
exists (`ProjectSeedTables.constant_tables` and `ScopeIndexer.fold_constant_tables` are functions). As U1 to
U5 and slice 1 decided, the functions another file of `lib/` calls are public and the rest private, with the
mirror spec pinning the list: `build_in_source_constants`, `constant_write_census`, `rebound_block_self` and
`dynamic_target_key`. `constant_writes_for_file` is private by that rule. Its seven examples move to the
mirror spec with their text and reach it through `send`, as they did; making it public for the specs would be
a fifth way into the module that no code takes.

**The constants.** The re-measure counts with a row the constants only that row reads.

- *Move the four*: `CONSTANT_UNPUBLISHABLE`, `OPAQUE_SELF_BLOCK_CALLS`, `OBJECT_OWNER` and `CensusTables`,
  each private or public as it was. `CONSTANT_UNPUBLISHABLE` then stands in the module and `CONSTANT_MEMO`,
  the other descriptor, on `ScopeIndexer`, where `ProjectSeedTables` and `DeclarationSignature` read it. The
  binding of `OBJECT_OWNER` moves from `ScopeIndexer` to the module, so the example of `rules_spec.rb` that
  holds each bound name to the rules' object looks that one up on `ConstantTables`.
- *Leave the two that are part of a set* on `ScopeIndexer` and read them lexically, as the module reads
  `OPAQUE_SELF`, `RECEIVER_EVAL_CALLS`, `CONSTANT_MEMO` and `DYNAMIC_TARGET_PREFIX`. `rules_spec.rb` stays as it
  is, and `ScopeIndexer` keeps two constants nothing in its file reads, as it keeps `EMPTY_NESTING` for the
  two modules that read it.

**The requires.** A file under `scope_indexer/` requires what it names. `in_effect_refinements.rb` reads
`Scope::DiscoveryIndex::REFINEMENT_WILDCARD` as it loads (`in_effect_refinements/scope_reads.rb`) and does not
require `scope.rb`, so it loads only after `scope.rb` has.

- *Require it.* `constant_tables.rb` then fails to load alone, and so does `shared_walk_tables.rb`, which
  requires it for the block rule and whose mirror spec loads it alone.
- *Require `scope.rb` first.* The module names no `Scope`, and the two files would load most of the engine
  when loaded alone.
- *Leave it unrequired* and say so. `scope_indexer.rb` has loaded both files by the time it requires this one,
  so every product path is as it was; alone, `constant_write_census` is a `NameError`. The defect is in
  `in_effect_refinements.rb` and is not this slice's to fix.

`shared_walk_tables.rb` requires `constant_tables.rb`, as it requires `factory_call_resolver.rb`. Loaded
alone it then loads 57 engine files where it loaded 17, and declares the flow tracer's slot and the dependency
recorder's three after its own four. Under every product path the slots are the base's, in the base's order.

**`index`.** Its statement for the constant table holds `ConstantTables.build_in_source_constants(…)` and the
splat of the mutations, which pass 120 columns on one line, so it is four lines where it was three and `index`
is 33 lines against `Metrics/MethodLength`'s 30. The directive slice 1 extended stays. It could go only if
`index` fitted in 30 lines, which would take module names short enough for each of the three statements to
keep the lines it had (11 characters or fewer for this one), or a local the base does not have.

**The module's length.** `Metrics/ModuleLength` is disabled on the module's own line, as it is on
`SharedWalkTables`, `NodePropagation` and `DeclarationWalk::Rules`: the code keeps the shape the move gives
it.

**The ratchet.** No call site changes tier. Three expressions read `Dynamic[top]` at the head that did not at
the base: 15,728 → 15,731 over the nine files the slice touched. One is new, the `module Rigor` wrapper of
`constant_tables.rb`, which reads `Dynamic[top]` as the wrapper of six of the other eight files does. Two
expressions of `dynamic_target_key` change tier: the read of `DYNAMIC_TARGET_PREFIX` and the interpolation that
holds it read `constant` at the base and `Dynamic[top]` at the head. `DYNAMIC_TARGET_PREFIX` is a String
constant of `scope_indexer.rb`, which two files outside the indexer and one function that stays read, so it
stays there; and the constant publication rule publishes no String across files (only a Symbol, an Integer, a
Float, `true` and `false`), so a read of it from another file is `Dynamic[top]`. The function still types
`String`, and its three callers read `nominal` on both sides.
[#3392](https://github.com/rigortype/rigor/issues/3392) tracks a constant bound to another file's frozen Array
or String; whether its landing covers a direct read was not traced.

- *Move `DYNAMIC_TARGET_PREFIX` with the module.* `runner/scope_seed.rb` and `expression_typer/writes.rb` read
  `ScopeIndexer::DYNAMIC_TARGET_PREFIX`, `dynamic_target_segment`, which stays with the fold, reads it too, and
  the amendment names it among what stays at WD10's end.
- *Leave `dynamic_target_key`* beside the constant. The census calls it twice and the fold once, so the
  module would call back three functions, and the row would not move whole.
- *Accept them.* Precision is 0.5990 against a pin of 0.5958 and the `Dynamic` call share 0.4962 against
  0.4983, each better than its pin and better than at the base.

## Decision

One module, `ScopeIndexer::ConstantTables`, in `scope_indexer/constant_tables.rb`. It shows the four functions
another file calls and keeps 36 private. The four constants only it read move with it, `OBJECT_OWNER`'s
binding among them, and `rules_spec.rb` follows that binding. The file requires what it names apart from
`in_effect_refinements.rb`. `index` keeps its directive at 33 lines, the module carries a
`Metrics/ModuleLength` directive, and the three expressions are accepted with no pin of
`tool/coverage_ratchet.yml` touched.

The precedent for each is the amendment and the slices landed under it. The amendment moves a cluster "whole,
behind its entry", and its table names this row as one module behind four entries. The re-measure counts a
row's own constants with it, and slice 1 moved the widening's three the same way. `SharedWalkTables` (U4)
carries the same directive for the same reason, and slice 1's entry is the precedent for `index`'s. The one
place where the move and a gate disagreed is `rules_spec.rb`: its example now asks the module that binds
`OBJECT_OWNER`, and still holds all five names to the rules' own objects.

Three smaller choices follow landed slices and need no ruling. Comment links to a module function are spelled
with a dot, `{.x}` inside the module and `{ConstantTables.x}` or `{ScopeIndexer::ConstantTables.x}` outside
it. The seven examples of `scope_indexer_spec.rb` that called `constant_writes_for_file` alone are in the
mirror spec with their assertions unchanged. And `SharedWalkTables`' head comment and its mirror spec say
one call back.

## To undo

To split the module, cut the nine rules into a module of their own and spell the fifteen call sites of them in
the walk and the census on it; its mirror spec then pins seven public functions. To rename it, rename the file,
its mirror spec, its rows in `typing_state_closure_spec.rb` and `DeclarationWriterScan::SOURCES`, its section
of `producers.yml` (six grandfathered keys, so the pin's digest moves again) and its block of
`sig/rigor/inference.rbs`, and the calls spelled on it. To put `CONSTANT_UNPUBLISHABLE` or `OBJECT_OWNER` back
on `ScopeIndexer`, move the statement and its `private_constant` line; the module reads the name lexically
with no other change, and for `OBJECT_OWNER` the example of `rules_spec.rb` goes back to asking `ScopeIndexer`
alone. To require `in_effect_refinements.rb`, first make it require `scope.rb`. To take the directive off
`index`, bring its three statements back within 30 lines. To win the two expressions of `dynamic_target_key`
back, widen the constant publication rule to a frozen String, or move `DYNAMIC_TARGET_PREFIX` when WD10
settles what stays in `ScopeIndexer`; the wrapper's reading goes only with the file.
Nothing outside this pull request depends on any of these yet; the next slice of #3400 reads `index` at 33
lines and `SharedWalkTables` at one call back.
