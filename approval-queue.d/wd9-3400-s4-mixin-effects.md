# Slice 4 of #3400 moves the mixin effects and the mixin tables in one pull request, as two modules, `MixinEffects` behind the eight functions both mixin walks call and `MixinTables` behind one, keeps the two builders only specs call private, moves the three constants only the effects read, and accepts what the cut costs the self-typing scan

- **PR:** [#3415](https://github.com/rigortype/rigor/pull/3415)
- **Issue:** [#3400](https://github.com/rigortype/rigor/issues/3400)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-26

## Background

ADR-116's re-measure of 2026-11-26 names the mixin effects and taints a candidate, "alone or with the mixin
tables", and the mixin tables over the cut-off until the effects are out. It commits to neither. #3400 holds the
candidates, and this is its fourth slice. Re-measured at `2f3003b35` with the re-measure's own scripts, the
effects are 31 functions and 220 lines of code with three calls back, all recognisers (`opaque_mixin_argument?`,
`mixin_call_view`, `lexical_self_receiver?`), and eight entries, which the include walk and the extend walk each
call. The mixin tables are 17 functions and 169 lines of code that call back ten: those eight and two of the
recognisers. With the effects a module of their own they call back two. Both rows then meet the #3318 cut-off:
at most four calls back, and no function of the file reads or writes an instance variable. The extend tables
stay, at 12 calls back.

The amendment says a cluster moves "whole, behind its entry" to `ScopeIndexer::<Name>` and leaves the rest to the
slice. The coordinator's brief asked the slice to choose between the effects alone and the effects with the
tables, as one module or two, and to record it. Five more things were open.

- What each module shows. Two functions of the tables' row, `build_discovered_includes` and
  `build_discovered_prepends`, are called by no file of `lib/` and by specs at 25 sites.
- What becomes of the examples that call those two.
- What moves with the effects. Three constants are read by them alone, and two of the three share a
  `private_constant` line with a constant that stays.
- What the move costs the self-typing ratchet.
- One of those three constants lists node classes, which the producers gate reads. That one is a row of a gate
  file and has an entry of its own, `wd9-3400-s4-mixin-effects-producers-row.md`.

## Options and trade-offs

**The effects alone, or with the tables, as one module or two.**

| Shape | Functions | Calls back | Functions another file calls | What the extend walk, which stays, then calls |
| --- | ---: | ---: | --- | --- |
| The effects alone, the tables left | 31 | 3 | 8 of 31 | `MixinEffects` |
| One module of both | 48 | 3 | 9 of 48 | a module named for the include tables, for what is no table |
| Two modules | 31 and 17 | 3 and 2 | 8 of 31, and 1 of 17 | `MixinEffects` |

- *The effects alone.* The smallest review. The tables then meet the cut-off and wait for a slice that recounts
  the same pins again: the grandfathered digest of `producers_spec.rb`, the budget row of `scope_indexer.rb`
  and the sections of `producers.yml`.
- *One module.* The amendment's own count ("48 functions and four calls back"; three now, since
  `rebound_block_self` left with `ConstantTables`). It would show nine functions, eight of them for a walk
  that is not in it, and the extend tables, when they leave, would depend on the include tables' module.
- *Two modules.* Each row of the re-measure is a unit. The effects are a library two walks ask, and the tables
  one walk behind one entry, which calls the library at nine sites and is not called back, so the two files
  are no cycle. One set of guardrail runs covers both.

**What each module shows.** As U1 to U5 and slices 1 to 3 decided, the functions another file of `lib/` calls
are public and the rest private, with the mirror spec pinning the list: eight for the effects, one for the
tables. For the two builders only specs call:

- *Private, reached through `send`*, as slice 2 left `constant_writes_for_file` and slice 3
  `collect_class_alias_map`. The row moves whole. 25 spec sites change their spelling.
- *Public.* The examples keep `described_class.build_discovered_includes(…)` as it reads, and the module shows
  two functions no file of `lib/` calls.
- *Left on `ScopeIndexer`*, each as `MixinTables.mixin_tables(root).fetch(…)`. No spec changes, and the
  indexer keeps two functions whose table has left it, which is the delegator the slices have not left.

**The examples.** C4 moves an example to the module's spec when it can be rewritten against the module's
interface without losing what it checks. Fifteen examples of `scope_indexer_spec.rb` call the two builders and
no other: six of the "eval-block dual context (#1097)" group and the nine of ".build_discovered_prepends".
Five more, and one of `constant_tables_spec.rb`, read the include table beside the extend table, the methods
table or an index.

**The constants.** The re-measure counts with a row the constants only that row reads. `LOCAL_SCOPE_BOUNDARIES`,
`HOOK_DEFS` and `MIXIN_EVAL_CALLS` are the effects'; each is private. `HOOK_DEFS` and `MIXIN_EVAL_CALLS` are
named by one `private_constant` line with `INSTANCE_MIXIN_NAMES`, which the extend tables read. Moving them
divides that line in two. Leaving them keeps on the indexer three names nothing in its file reads.

**The ratchet.** The cut costs the self-typing scan 17 `Dynamic` call sites (50,969 to 50,986, on
`b4f0318b8`), and 37 expressions read a precise tier at the base and `Dynamic[top]` at the head. All 37 are in
the two new files, at ten reads of five constants that stay in `scope_indexer.rb` (`INSTANCE_MIXIN_NAMES`,
`MIXIN_KINDS`, `SEND_CALL_NAMES`, `ARRAY_ITERATORS`, `MIXIN_CALL_NAMES`) and in what is computed from them.
Every call the slice respelled keeps its tier. Two more expressions that read `Dynamic[top]` are new rows, the
`module Rigor` wrapper of each new file.

The mechanism is the binding rule of `docs/internal-spec/inference-engine.md` § "The publication census". A
constant publishes to other files only when exactly one file writes it, once, and the value is a frozen
scalar literal: a Symbol, an Integer, a Float, `true` or `false`. Each of the five is `%i[…].freeze`, a call,
which the rule withholds as a non-literal rvalue, as it withholds a bare Array as a mutable literal; the
reader in another file is left at `Dynamic[top]`. This is not #3392's mechanism, which is a constant bound
to another file's constant. With this slice the file splits of ADR-116 have cost the ratchet 31 call sites:
#3390 (8), #3396 (3), #3397 (2), #3405 (1 net) and this one (17).

- *Move the five constants with their readers.* It does not work: all ten reads sit on both sides of the cut.
  The extend tables read `INSTANCE_MIXIN_NAMES` and `ARRAY_ITERATORS`, `mixin_call_view` reads `MIXIN_KINDS`
  and `SEND_CALL_NAMES`, and the extend tables, the methods table and `SharedWalkTables` read
  `MIXIN_CALL_NAMES`. The reads that turn `Dynamic` would be the ones left behind.
- *Declare the five in `sig/`*, as five `Array[Symbol]` constant rows of `sig/rigor/inference.rbs`.
  `docs/agents/measurement.md` § "The self-typing ratchet", step 1, prescribes it when a delta is the change's
  own; the two-file probe of the review of #3415 shows that a constant declared so reads through from another
  file (the table is in #3416); and R1 kept it as the fallback. A hand-authored row needs the review
  `docs/agents/type-authoring.md` requires, and it states by hand what the rule could let the engine read.
- *Change the rule.* [#3416](https://github.com/rigortype/rigor/issues/3416) proposes that a single-write
  frozen Array of scalar literals publish across files as its erased nominal. That is the root fix, and a
  change to a binding spec, which is not this slice's to make.
- *Give each module its own copy of the lists.* Two objects where there was one, which is what R1 bound the
  rules' lists on `ScopeIndexer` to avoid, and two places to change a list.
- *Leave the clusters in the file until the rule changes.* The slice then waits on #3416.
- *Accept the sites and defer the remedy.* Precision is 0.5992 against a pin of 0.5958 and the `Dynamic` call
  share 0.4961 against 0.4983, each better than its pin. Precision is no lower than at the base, and the share
  is 0.0001 higher.

## Decision

One pull request, two modules: `ScopeIndexer::MixinEffects` in `scope_indexer/mixin_effects.rb`, showing the
eight functions both walks call, and `ScopeIndexer::MixinTables` in `scope_indexer/mixin_tables.rb`, showing
`mixin_tables`. The two builders move with their row and are private. The fifteen examples that called them
alone are in the tables' mirror spec with their comments and assertions unchanged and one substitution,
`described_class.build_discovered_x(` spelled `described_class.send(:build_discovered_x, `; the six calls
that stay are spelled `MixinTables.send(:build_discovered_includes, …)`. The three constants move, private as
they were, and the `private_constant` line is two lines. The 17 `Dynamic` call sites are accepted and
their remedy is deferred, as the coordinator ruled on the review of #3415: no pin of `tool/coverage_ratchet.yml`
is touched and no `sig/` row is added here. #3416 is the root fix, and the five `sig/` rows are the fallback.

The precedent for each is the amendment and the slices landed under it. The amendment moves a cluster "whole,
behind its entry", and its re-measure names the effects a candidate "alone or with the mixin tables". Slice 1
([#3405](https://github.com/rigortype/rigor/pull/3405)) moved three clusters in one pull request and slice 3
([#3409](https://github.com/rigortype/rigor/pull/3409)) two, each as a module of its own. Slice 2
([#3406](https://github.com/rigortype/rigor/pull/3406)) is the precedent for a function only specs call being
private and reached through `send`, for the examples that called it alone moving with their assertions, and
for a row's own constants moving with it. There is no precedent for a module behind eight entries among the
slices of #3400; `DeclarationWalk::Rules` (R1, [#3390](https://github.com/rigortype/rigor/pull/3390)) is
the one of #3346, a library most of whose functions other files call, and here the eight are a quarter of the
module and the mirror spec pins the list.

Three smaller choices follow landed slices and need no ruling. Comment links to a module function are spelled
with a dot, `{.x}` inside the module and `{MixinEffects.x}` or `{MixinTables.x}` outside it. Each file has a
row in rule (v)'s table. And `MixinEffects`, at 235 lines, carries a `Metrics/ModuleLength` directive, as
`ConstantTables` and `SharedWalkTables` do.

## To undo

To move the tables back, or to make one module of the two, move the functions and respell the calls between
them; the digest of the grandfathered pin and the budget row of `scope_indexer.rb` are recounted. To rename a
module, rename the file, its mirror spec, its rows in `typing_state_closure_spec.rb` and
`DeclarationWriterScan::SOURCES`, its section of `producers.yml` (ten grandfathered keys for the tables and
none for the effects, so the pin's digest moves again only for the tables), and the calls spelled on it. To
make the two builders public, take them off the `private_class_method` list and spell the 27 spec sites
without `send`; the mirror spec's "exposes the entry alone" then lists three functions. To put a constant
back on `ScopeIndexer`, move the statement and its `private_constant` name; the module reads it lexically with
no other change. The 17 call sites come back
when #3416 lands, since a single-write frozen Array of scalar literals then publishes across files; or, before
that, with five `Array[Symbol]` rows in `sig/rigor/inference.rbs` for `INSTANCE_MIXIN_NAMES`, `MIXIN_KINDS`,
`SEND_CALL_NAMES`, `ARRAY_ITERATORS` and `MIXIN_CALL_NAMES`, each reviewed as `docs/agents/type-authoring.md`
requires.
Nothing outside this pull request depends on any of these yet; the last slice of #3400 reads `scope_indexer.rb`
at 9,039 lines under a budget of 9,100, and the grandfathered pin at the digest this slice leaves.
