# A plugin's class header drops its superclass whenever another source declares one, and reports it only when the two differ

- **PR:** [#2464](https://github.com/rigortype/rigor/pull/2464)
- **Issue:** [#2439](https://github.com/rigortype/rigor/issues/2439)
- **Class:** open-choice
- **Precedent:** [#2424](https://github.com/rigortype/rigor/pull/2424)
- **Decided:** 2026-10-28

## Background

`rigor-activerecord`'s `framework.rbs` declares `StatementInvalid` and `ConnectionNotEstablished` `< ActiveRecordError`,
and activerecord 7.1+ in `gem_rbs_collection` declares both `< AdapterError`. The two clauses raised
`RBS::SuperclassMismatchError`. #2424's `DeferredSignaturePlan` stood a plugin's colliding members down, but not its
class header's superclass. The coordinator ruled on the brief for a generic stand-down inside `DeferredSignaturePlan` /
`GatedSignaturePlan`, recorded here. The lane made one further choice: when to report the dropped clause.

## Options and trade-offs

Stand-down rule:

- Rewrite `framework.rbs` to the 7.1 hierarchy. That collides with collections 6.x and 7.0, which have no `AdapterError`.
- A per-collection-version table in the plugin. It needs maintenance at every Rails release.
- Drop the plugin's clause whenever another source gives one, without comparing names. Names are unresolved at plan
  time, and the other source's clause binds either way, so dropping a matching clause loses nothing.

Report:

- A row for every dropped clause. On activerecord 8.1 that is 13 rows, 11 of them identical clauses, under a message
  saying the plugin's declaration stood down.
- A row only when the other source's clause differs from the plugin's: a different class or different type
  arguments (`Base[String]` against `Base[Integer]`). The report carries RBS's lexical context through its walk and
  resolves the plugin's clause with `RBS::Resolver::TypeNameResolver` over the built env, in the context the class
  is written in, with class aliases normalised on both sides. Its limit: a `use` directive in the plugin's file is
  not applied, so a superclass named through one is resolved as if the directive were absent, and its row can be
  missing or redundant. No bundled plugin's `sig/` uses one, and the plan is unaffected either way.

## Decision

The generic drop, per the coordinator's ruling and #2424's precedent that a plugin yields to other sources'
declarations. It covers collections 6.0 through 8.1 without a table (all seven checked against the fixture in #2439).
The report lists only clauses whose class or type arguments differ: a clause identical to the other source's, once
both are resolved, loses nothing, while one that differs in either loses the plugin's ancestry or its type arguments.
The brief named #2424's row path as the report, whose rows each name something that stood down.

## To undo

Drop `superclass_given?` from `DeferredSignaturePlan.plan_type` and the `drop_super_class:` keyword from
`GatedSignaturePlan.rebuild`. To report every dropped clause, delete the `same_super_class?` comparison in
`superclass_rows`.
