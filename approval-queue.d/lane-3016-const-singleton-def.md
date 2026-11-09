# A call through a constant to a name `def OBJ.x` or a literal `OBJ.define_singleton_method(:x)` defines is declined, not typed

- **PR:** [#3017](https://github.com/rigortype/rigor/pull/3017)
- **Issue:** [#3016](https://github.com/rigortype/rigor/issues/3016)
- **Class:** open-choice
- **Precedent:** [#339](https://github.com/rigortype/rigor/pull/339)
- **Decided:** 2026-11-09

## Background

`OBJ = Object.new; def OBJ.each … ; OBJ.each` reported `call.undefined-method` against `Object`. The issue allowed
either typing the call as the def's return or declining it, and asked to follow whichever existing mechanism fits.

## Options and trade-offs

- Type the call from the def: needs a new def-node row for a `def` written outside the constant's body, keyed on
  every name the constant can denote. More precision, more surface, and a new incremental edge to prove.
- Decline through the envelope that the indexer already files (`[:singleton, x]` on the constant's candidates) inside
  #339's `SingletonObjectConstant` probe. No new table and no new edge, since the constant's class edge already
  covers the defining files. The call's result is not typed from the def.
- For `define_singleton_method`, honour the constant's dynamic mark, so any name is declined. This also silences
  `OBJ.nope` after a literal `define_singleton_method(:each)`. Or file a literal-name envelope, as the `def` path
  does, which keeps that report.

## Decision

Decline through the envelope, and file a literal-name envelope for `define_singleton_method`. A computed name files
nothing, so that call still reports. This follows #339, which scopes the recovery to recorded names so that an
undefined name still fires.

## To undo

Remove `SingletonObjectConstant.foreign_singleton?` and `ScopeIndexer#record_constant_singleton_definer`, along with
their rows in `spec/integration/constant_singleton_def_spec.rb`. Nothing else reads the new envelope.
