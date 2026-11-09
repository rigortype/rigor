# The ivar census credits a constant-rooted class_eval to the constant and joins it through the reader's owners

- **PR:** [#3001](https://github.com/rigortype/rigor/pull/3001)
- **Issue:** [#2983](https://github.com/rigortype/rigor/issues/2983)
- **Class:** open-choice
- **Precedent:** [#2933](https://github.com/rigortype/rigor/pull/2933)
- **Decided:** 2026-11-09

## Background

Issue #2983 lists false positives where a `class_eval` or `module_eval` block on a constant other than the class's own
spelling defines a method that runs on the class's instances: `Anc.class_eval` with `K < Anc`, `M.module_eval` with
`include M`, `INST.class.class_eval` with `INST = K.new`, `AliasK.new.class.class_eval` with `AliasK = K`, and
`Object.class_eval` written in another file. The brief suggested resolving the receiver against K's ancestors in the
syntactic bar (`CensusForeignBlock`). It also asked that a literal-rooted chain read as foreign whatever calls it goes
through, and that a String `class_eval` widen K's census. Each of these left a reading open.

## Options and trade-offs

1. Resolve the receiver against K's chain, aliases and instance constants inside `CensusForeignBlock` and credit K. The
   cross-file census runs in a syntactic pre-pass with no chain or constant table, so it could only read the class
   header in the same file, and the same-file and cross-file answers would disagree.
2. File the reentered code under the root constant as written, as the host walk already files a `Base.class_eval`
   block's own `def`s under `Base` (#2933's receiver-writer precedent). Then widen the owners the join reads: the
   `:constants`-flavor chain, `Object`/`BasicObject`/`Kernel`, and each owner's alias and instance constants, which a
   new `[:binds_class, class, constant]` census entry records. One mechanism serves both layouts and the incremental
   session. The cost is that a project-wide `Object.class_eval { def … }` ivar write now reaches every class's census.
3. Literal roots: either read a literal-rooted chain as foreign through any call, as the brief asked, or only through
   blockless calls on a scalar literal that spells no constant. The second keeps `[self].first.class`,
   `"s".then { self }.class` and `"K".constantize` (ActiveSupport) as may-be-K.

## Decision

Option 2 for receivers and the narrower literal rule. Both follow the false-positive-first rule. Option 2 is semantically
what Ruby does, since the method lands on the constant's module and every instance of an owner runs it. The literal
rule narrows the brief's wording only where a literal's calls can answer an instance of the class. A String
`class_eval` records a `:dynamic` write of every ivar (`:*`) for the module its receiver may be. The join unions it
into each of the owner's ivars in both layouts, which makes those ivars `Dynamic[top]`-widened rather than reading the
String. That is a precision cost: a String `class_eval` on `Object` or `Kernel` widens every ivar of every class that
reaches `Object`.

Review round 1 tightened the owners so a credit reaches only the class the receiver resolves to. `Object` and
`Kernel` are not owners of a class whose superclass chain names `BasicObject`. A root constant and a binding's class
are recorded as candidate keys, the qualifications their lexical nesting allows, nearest first. The join resolves each
key to the first candidate the project declares or binds, as Ruby's constant lookup does.

Review round 2 added two refinements. A candidate a loaded signature declares counts as existing, so a nearer
constant only RBS knows credits no project class. A `.class` or `.singleton_class` of the root constant's own value
credits only an instance binding, and one of a class object credits nothing.

## To undo

Revert `remember_root_constant`, `record_binding` and `record_string_eval` in `IvarWriterCensus`, the owner widening in
`ScopeIndexer::IvarContributions` (flavor back to `:methods`), and `scalar_literal_rooted?` in `CensusForeignBlock`.
`spec/integration/ivar_census_constant_receivers_spec.rb` and the two #2983 rows in
`spec/rigor/analysis/cross_file_ivar_census_incremental_spec.rb` would then report again.
