# The refined rung moves with the union re-entry as a re-entry point, its site built above it, and its method name taken from the site

- **PR:** [#3377](https://github.com/rigortype/rigor/pull/3377)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-20

## Background

Slice S4 of ADR-116's WD12 amendment moves the `refined` rung of the call ladder, a call through an in-effect Ruby
refinement (ADR-121), out of `ExpressionTyper` into `CallLadder::Refined`. It is the last rung move. The amendment lets
a rung move only when it writes no typer state and calls back at most four typer methods (the #3318 cut-off), and
lists S4 "only with a plan for the self-typing ratchet", adding that "its re-entry per union member may stay in the
typer". A static census of the typer gives the rung 12 methods and 107 lines, no instance variable, one typer constant
(`REFINED_NAMING_CALLS`), and four callbacks: `call_result_type_for` (for each member of a union receiver that no
refinement wins), `dynamic_top`, `infer_user_method_return` and `positional_correspondence`.

The lane's brief settled three of the choices and asked for a decision record: `dynamic_top` inlined as S8 did, the
union re-entry taken through `CallLadder::REENTRY` unless a reason against it turned up, and the method name taken
from the site throughout. A fourth came with the entry's shape: where the call's site is built.

## Options and trade-offs

- **The union re-entry.** Kept in the typer, the rung's `try_call` could not ask it, so the typer would wrap the
  module's `try_call` in a method that re-enters for each member: the adapter shape the amendment rejects, and a
  second ask of the rung in the typer. As a re-entry point, `call_result_type_for` is public, `@api private`, in the
  typer's one `public` statement and in `REENTRY`, and `reentry_spec.rb` holds every caller other than the typer itself
  to a rung module's `typer`. The amendment already names it as one. No reason against it turned up: the call is the
  base's, on the typer the rung was given, inside the walk that asked the rung.
- **`dynamic_top`.** Inlined as `Type::Combinator.untyped`, it is a constant answer and no callback; kept, it would be
  a fourth callback and a `PUBLIC_CALLBACKS` row. S8's choice, measured byte-identical there and here.
- **The site.** `call_result_type_for` asked the refined rung with the call's fields and built the site below it. The
  entry is `try_call(site, typer)`, so the site is built one step higher and handed to the refined rung and every rung
  after it. A call the refined rung answers now builds a site it did not build before.
- **The method name.** The typer's rung read `node.name` in five places: the name recorded as a refinement read, the
  naming-call test (`send`, `respond_to?` …), the instance and class-object winner lookups, and the refine body's
  lookup. Reading `node.name` is the base body unchanged and is right for a call. Reading `site.method_name` is what
  the internal spec requires of a rung, and is right too for the read of `c[k] += v`, whose site has the write node
  as its call node: that is the entry #3358's fix will add. One path does not follow the site: on a union receiver
  the rung re-enters `call_result_type_for` with the write node, which has no `name` and raises. The index read does
  not ask the rung today, so the path is unreachable; #3358's fix must re-enter the asking entry or decline unions
  there (recorded on #3358). No guard is added here, so that a one-line fix fails loudly rather than silently
  dropping unions.

## Decision

`call_result_type_for` is a re-entry point and the rung calls back three methods. `dynamic_top` is inlined. The site is
built above the refined rung. The rung takes the method name from the site in all five places, threaded as a
parameter through `refined_indirect_result`, `refined_receiver_result`, `refined_member_result`,
`refined_class_object_result` (whose call node is then unused and renamed `_node`) and `refined_body_return`;
`refined_spec.rb` pins each on a site whose name is not its node's, and on the write node of an index write. Each
substitution is listed in the PR's body-identity table. The extra site's cost is in the PR's allocation section.

The precedent is the amendment's rung module, its move rule and its naming of `call_result_type_for` as a re-entry
point; S8's entry (`wd12-s8-overriding-toplevel.md`) made the same choices for `dynamic_top`, the site and the method
name, but is still in this queue, so it is a sibling here.

## To undo

Moving the rung back into the typer is the revert of the slice's move commit: `REENTRY` and the `public` statement
lose `call_result_type_for`, and the site goes back below the refined rung. Keeping the module but taking the re-entry
back into the typer needs a typer method that wraps `CallLadder::Refined.try_call`, which the amendment would have to
allow. #3358's fix, which asks the rung from the index read, depends on the method name coming from the site.
