# The overriding-def and top-level-def rungs move with `dynamic_top` inlined, the two RBS wrappers called in place, and one new re-entry point

- **PR:** [#3374](https://github.com/rigortype/rigor/pull/3374)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-20

## Background

Slice S8 of ADR-116's WD12 amendment moves the `overriding_def` and `top_level_def` rungs of the call ladder out of
`ExpressionTyper` into `CallLadder::OverridingDef` and `CallLadder::TopLevelDef`. The amendment lets a rung move only
when it writes no typer state and calls back at most four typer methods (the #3318 cut-off). A static census of the
typer gives the overriding-def rung 3 methods and 28 lines, calling back three typer methods (`dynamic_top`,
`safe_rbs_method_definition`, `rbs_declared_on_class?`), and the top-level-def rung 9 methods and 84 lines, calling
back six (those three, `positional_correspondence`, `infer_user_method_return` and
`resolve_user_def_through_ancestors`). Neither writes an instance variable.

The coordinator ruled on #3372's review that calling `ExternalAncestorResolution` in place of
`safe_rbs_method_definition` and `rbs_declared_on_class?` is a legitimate substitution: each is a one-line scope
delegation with no typer coupling. The conditions: the substitution is listed in the body-identity table, the typer
keeps the wrappers for its other callers, and only pure scope delegations qualify. The ruling also made
`resolve_user_def_through_ancestors`, over the `:user_def` memo, a real addition to `CallLadder::REENTRY`. It left
`dynamic_top` to the slice: a `CallLadder::PUBLIC_CALLBACKS` row, or `Type::Combinator.untyped` inlined if the two
are byte-identical.

Three more choices came up in the move: where the read of `c[k] += v` builds its site, where the top-level-def rung
takes the method name from, and what block type the overriding-def rung types the own `def`'s body with.

## Options and trade-offs

- **`dynamic_top`.** `ExpressionTyper#dynamic_top` is public, marked `@api private` for `Writes`, and its whole body
  is `Type::Combinator.untyped`. No subclass overrides it, and `sig/` declares both `-> Dynamic`. As a public callback
  it is a fourth callback for the top-level-def rung (at the cut-off), a first for the overriding-def rung, and a
  `PORT` member that only answers a constant. Inlined, the two rungs call back three and none, and `PORT` does not
  grow. It couples a rung to the typer no more than a call of `Type::Combinator` does.
- **The two wrappers.** Called in place, as ruled. `safe_rbs_method_definition` keeps its other caller in the typer
  (`core_finder_member?`) and stays. `rbs_declared_on_class?` has no caller left: both were the two rungs'
  (`overriding_own_def?` and `singleton_self_answers?`). Keeping it leaves a method nothing calls; deleting it is
  the ruling's condition read as written, since there is no other caller to keep it for.
- **The index read's site.** `implicit_index_read_type` built the site for the dispatcher below the overriding-def
  rung, which it asked with its fields. The rung's entry is `try_call(site, typer)`, so the site is built one line
  higher and handed to the rung and the dispatcher. An index read the overriding-def rung answers now builds a site
  it did not build before.
- **The top-level-def rung's method name.** The typer's `try_local_def_dispatch` read the name off the call node
  (`node.name`), in the method and in two helpers. `docs/internal-spec/inference-engine.md` § "The call ladder" says
  a rung MUST take the method name from `site.method_name`, and the rung's row gives it to `send_target`, whose site
  has the `send` as its call node (that entry leaves the rung out today, as drift #3369). Reading `node.name` is the
  base body unchanged and is right for every site that asks the rung now. Reading `site.method_name` threads the name
  through the rung, `declined_top_level_def_answer`, `self_type_answers?` and `plugin_member_answers?`, and is right
  for the `send_target` site too. `CallLadder::LiteralSend` reads the call node's name, but its question is whether the
  call is a `send`.
- **The overriding-def rung's block type.** The typer's rung asked `CallLadder::UserMethod.infer` with `nil` for the
  block type, not the call's. Handing it the site's block type changes what a yielding override answers.

## Decision

`dynamic_top` is inlined as `Type::Combinator.untyped` in both rungs: the body is that expression, the declared
types agree, and `rigor check --no-cache --format json` is byte-identical between the base and head engines. The
two wrappers are called in place; `rbs_declared_on_class?` is deleted from the typer and `safe_rbs_method_definition`
stays. `resolve_user_def_through_ancestors` is public, `@api private`, in the typer's one `public` statement and in
`REENTRY`. The top-level-def rung calls back three methods, the overriding-def rung none.

The index read builds its site above the overriding-def rung. The top-level-def rung takes the method name from the
site, threaded through its helpers, with `top_level_def_spec.rb` pinning each read on a site whose name is not its
node's. The overriding-def rung types the body with no block type, as before, and `overriding_def_spec.rb` pins it.
Each substitution is listed in the PR's body-identity table.

The precedent is the amendment's rung module and its move rule, the coordinator's ruling on #3372 for the wrappers
and the re-entry point, and the internal spec's rule for the method name. S5's and S7's entries
(`wd12-s5-project-singleton.md`, `wd12-s7-literal-send.md`) are still in this queue, so they are siblings here.

## To undo

Give `PUBLIC_CALLBACKS` a `dynamic_top` row and call `typer.dynamic_top` in place of the inlined constant; the
top-level-def rung then calls back four, at the cut-off. Restore `rbs_declared_on_class?` if a later caller wants the
typer's spelling. Moving either rung back into the typer is the revert of the slice's move commit; `REENTRY` then
loses `resolve_user_def_through_ancestors`, and the splat index read asks the typer's `overriding_own_def?` again.
