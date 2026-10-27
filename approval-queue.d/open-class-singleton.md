# call.undefined-method stops checking class methods on a namespace the project's sig declares without members

- **PR:** [#2477](https://github.com/rigortype/rigor/pull/2477)
- **Issue:** [#2438](https://github.com/rigortype/rigor/issues/2438)
- **Class:** open-choice
- **Precedent:** [#2264](https://github.com/rigortype/rigor/pull/2264)
- **Decided:** 2026-10-28

## Background

A class Rigor knows only from source is open: an unresolved call on it reads `Dynamic` and is not reported.
`rigor sig-gen --write` then declares the class in `sig/`, and `call.undefined-method` enumerated that declaration.
Two families of correct calls started firing: `TagManager.instance` on a class that `include`s `Singleton`, and
`NS.helper` on the wrapper `module NS` sig-gen writes around a nested class when `helper` is defined outside
`paths:`. sig-gen cannot fix either one (the issue's table). The coordinator ruled for an engine fix, which leaves
open how far the second decline reaches.

## Options and trade-offs

- Decline only for `C.instance` with `include Singleton`. Exact, but every wrapper namespace whose methods live
  outside `paths:` (the gitlab `Gitlab::Utils` / `Json` / `Metrics` and spree `Spree.api` clusters) keeps firing.
- Decline singleton calls on a class every one of whose RBS declarations is the project's own and member-less
  (no method, attribute, alias or mixin). This covers both clusters. The cost is that `NS.typo` on such a namespace
  stops firing, including a hand-written wrapper `sig/`. That call did not fire before sig-gen either, because
  the namespace was source-only and open.
- Also decline the instance side of a member-less class. No measured cluster needs it, and a typo on an instance
  of a member-less sidecar class keeps a working check.

## Decision

Both declines, singleton side only. `C.instance` asks `SingletonMixinDispatch.answers?`, the predicate the typer
uses, so the rule and the typer cannot disagree. The member-less decline asks `RbsLoader#memberless_project_class?`.
Declaring any member closes the class again, and bundled (core, stdlib, gem) declarations never count. This
follows #2264 (issue #2174), which opened a class whose project-only declaration cannot describe its surface. The member-less
`class Plain; end` sidecar is in this set too, so `Plain.instance` on it is silent. With a member in the
declaration, `Plain.instance` still fires.

## To undo

Remove the `RbsLoader#memberless_project_class?` arm of `CheckRules#open_project_singleton?`. Its pins are the
"member-less namespace declaration" examples in `spec/integration/project_sidecar_open_singleton_spec.rb`. The
`Singleton` arm can stay.
