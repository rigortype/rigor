# Reflection.project_method_defined does not yet read the unnamed-mixin mark, which waits for the #618 veto to read it too

- **PR:** [#2993](https://github.com/rigortype/rigor/pull/2993)
- **Issue:** [#2991](https://github.com/rigortype/rigor/issues/2991)
- **Class:** scope
- **Precedent:** none — sets one
- **Decided:** 2026-11-09

## Background

Issue #2991 opens `call.undefined-method` on the instance side of a class whose instance-side chain holds a
splatted `include(*MODS)` or `prepend(*MODS)` (`Scope::ResolutionChain#unnamed_mixin?`). The brief asked whether
the plugin facade `Reflection.project_method_defined` should read the same mark. It does not today: it answers
`maybe` for an open-names mark (#2968, via #2977), and `no` for a class whose only route to the name is a splatted
mixin.

## Options and trade-offs

- Make the `:discovered` walk answer `maybe` on a wildcard chain, as it does on an open-names mark. Plugins would
  then stand down where the module may define the name. But the activerecord implicit-self column tier
  (`implicit_self_instance_member_type`) would then decline on such a model. The engine's own top-level-`def` veto
  (#618, `ExpressionTyper#instance_self_answers?`) does not read the mark. So a top-level `def title = nil` would
  start binding inside the model, and `title.upcase` would report on `nil`. #2977 changed both readers together for
  this reason.
- Change the facade and the #618 veto together in this PR. That fixes a second false positive: under
  `include(*MODS)`, a module's `m1` is shadowed by a top-level `def m1 = nil` on master. But the veto is outside what
  #2991 asks, and it is a separate reader with its own specs.
- Leave both as they are, and file the pair as one follow-up.

## Decision

Leave both, and file the pair. The facade change alone regresses a plugin tier, and the pair together goes beyond the
issue. `call.undefined-method` reads the mark directly. No plugin answer changes in this PR. The rails-routes and
activerecord plugin specs pass unchanged.

## To undo

Add `|| Scope::ResolutionChain.for(scope, class_name.to_s, kind, :methods).unnamed_mixin?` beside
`open_names_on_chain?` in `Reflection.project_discovered_defined`. Add the same read to
`ExpressionTyper#instance_self_answers?` in the same change. Add rows for both.
