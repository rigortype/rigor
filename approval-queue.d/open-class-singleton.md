# call.undefined-method stops checking class methods on an open class the project's sig declares without members

- **PR:** [#2477](https://github.com/rigortype/rigor/pull/2477)
- **Issue:** [#2438](https://github.com/rigortype/rigor/issues/2438)
- **Class:** open-choice
- **Precedent:** [#2264](https://github.com/rigortype/rigor/pull/2264)
- **Decided:** 2026-10-28

## Background

A class Rigor knows only from source is open: an unresolved call on it reads `Dynamic` and is not reported.
`rigor sig-gen --write` then declares the class in `sig/`, and `call.undefined-method` enumerated that declaration.
Correct calls started firing: `TagManager.instance` on a class that `include`s `Singleton`, ActiveRecord class
methods (`Poll.joins`) on a model whose sidecar lists no members, and namespace helpers defined where sig-gen
cannot see them. sig-gen cannot fix these (the issue's table). The coordinator ruled for an engine fix and, after
review, ruled that the member-less decline must also require the source to leave the class open.

## Options and trade-offs

- Decline only for `C.instance` with `include Singleton`. Exact, but the ActiveRecord and wrapper-namespace
  sidecars keep firing.
- Decline singleton calls on every class whose project declarations are all member-less. This silences typos on
  closed classes whose whole definition is in `paths:` (`Plain.fooo`, `Admin::Metrics::Dimension.retreive`), so
  it was rejected in review.
- Decline singleton calls on a member-less class only when the source leaves it open. That covers the measured
  clusters and keeps typos on closed classes.
- Also decline the instance side of a member-less class. No measured cluster needs it.

## Decision

The third option, singleton side only. `C.instance` asks `SingletonMixinDispatch.answers?`, the predicate the
typer uses. It answers for an `include` (not a `prepend`) of the stdlib `Singleton` in `C` or a project class up
its superclass chain, so the rule and the typer cannot disagree. The member-less decline asks
`RbsLoader#memberless_project_class?` and then `CheckRules#open_source_class?`. A class is open when it, or a
project class up its superclass chain, matches any of these:

1. It records an `include` / `extend` / `prepend`, an `inherited` / `included` / `extended` / `prepended` hook,
   or `method_missing` / `respond_to_missing?`.
2. It has no body of its own inside `paths:`.
3. Its superclass chain reaches a class the project does not define, other than `Object` and `BasicObject`.

Accepted costs:

- `NS.typo` on an open member-less namespace is not reported. It was not reported before sig-gen either.
- A member-less error class (`class MyErr < StandardError`) counts as open, because a core superclass is a
  library class. `MyErr.typo` is not reported.
- A definition in a file outside `paths:` cannot be seen. The issue's `module NS` wrapper, whose body is in `paths:`
  and whose `NS.helper` is in `ext/`, therefore still reports `NS.helper`. Seeing such definitions would need a scan
  outside `paths:`.

This follows #2264 (issue #2174), which opened a class whose project-only declaration cannot describe its surface.

## To undo

Remove the `RbsLoader#memberless_project_class?` arm of `CheckRules#open_project_singleton?`, with
`#open_source_class?`. Its pins are the "member-less project declaration" examples in
`spec/integration/project_sidecar_open_singleton_spec.rb`. The `Singleton` arm can stay.
