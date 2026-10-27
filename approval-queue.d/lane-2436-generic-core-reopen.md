# sig-gen copies a reopened generic class's plain type parameters onto its header and skips one with a bound or default

- **PR:** [#2473](https://github.com/rigortype/rigor/pull/2473)
- **Issue:** [#2436](https://github.com/rigortype/rigor/issues/2436)
- **Class:** open-choice
- **Precedent:** [#1422](https://github.com/rigortype/rigor/pull/1422)
- **Decided:** 2026-10-28

## Background

`rigor sig-gen` wrote every reopened class header without type parameters, so a project reopening `Array` or
`Hash` got `class Array` in `sig/`, which rbs rejects with `GenericParameterMismatchError`: the class, and every
class whose definition touches it, fails to build. rbs requires each declaration's parameters to equal the first's,
including variance, `unchecked`, bounds and defaults. The issue left open what to do when copying the parameters
is not obviously exact.

## Options and trade-offs

- Copy every declaration's parameters verbatim, bounds and defaults included. Covers the most classes, but a bound
  or default is a type spelled relative to the declaring file's namespace and can resolve to another class under the
  nesting sig-gen writes, which reproduces the failure this fixes.
- Copy only plain parameters (name, variance, `unchecked`) and skip the methods of a class with a bound or default
  under a new reason. Exact for every class it writes; costs the user those methods' signatures.
- Skip every generic reopening. Never wrong, but drops the common `Array` / `Hash` extension case entirely.

## Decision

The second option, as the coordinator ruled on the issue: copy when every parameter is plain, otherwise skip as
`sig.skipped.generic-reopening`, unless `sig/` already declares the class (its own header then stays, as for
`sig.skipped.inline-generic-class`). It follows #1422's `demote_inline_generic_classes`, which skips rather than
writes a header it cannot make exact; ADR-5 favours the skip over a definition-build failure. Review of #2473 added
the coordinator's second ruling: a class a member names whose bare spelling equals one of the class's declared
parameter names is written anchored (`::E`), rather than the class being demoted, so the member keeps its type.

## To undo

Remove `Generator#demote_generic_reopenings` and `#stamp_generic_reopenings` and the header interpolation in
`Writer#render_tree_node` and `Renderer#declaration_header`; retire `sig.skipped.generic-reopening` from
`Classification`, `SkipReasonCatalog` and `docs/type-specification/diagnostic-policy.md`. Written `sig/` files keep
whatever headers they were given.
