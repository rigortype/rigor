# The plugin contribution tier keeps its former function as a positional second entry, and `try_dispatch` is one line over it

- **PR:** [#3364](https://github.com/rigortype/rigor/pull/3364)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-19

## Background

ADR-116 § "Amendment, 2026-11-19 — WD12's interface (#3345)" turns each of `MethodDispatcher`'s private tiers into a module whose entry is `try_dispatch(context)`. #3363 did that for four tiers by renaming the tier's function and binding its former parameters from the context. The plugin contribution tier's function, `try_plugin_contribution(call_node, scope, receiver_type)`, has a caller that is not `resolve`: `MethodDispatcher.plugin_member_answers?`, the veto `ExpressionTyper` asks before it binds a top-level `def` of the same name (#963). The veto holds a call node, a scope and the type of the call's own `self`. It holds no `CallContext`, and no argument types to build one from.

The amendment says a tier takes the site alone. It does not say what a tier does when its entry has a second caller with other arguments. For a rung module it does: "A rung module may expose a second named entry when a caller outside the rung asks part of it with arguments that differ from the site's."

## Options and trade-offs

- **The veto builds a context.** `plugin_member_answers?` calls `PluginContribution.try_dispatch(CallContext.build(receiver: …, method_name: …, args: [], call_node: …, scope: …))`. Every tier then has one entry. The site it builds carries `args: []` for a call that may pass arguments. The tier reads three fields today; a later change that read `args` or `block_type` there would be answered with a made-up value, and nothing would fail. One object more per veto, off the hot path.
- **A positional second entry.** The former function keeps its three parameters and its body, renamed `merged_return_type`, and `try_dispatch(context)` is one line that passes it the three fields. The veto asks with exactly what it holds. `resolve` pays one more method call for each dispatch that reaches the tier, and no object.
- **Move the veto into the module.** `plugin_member_answers?` asks two tiers, this one and the synthetic-method index, so it belongs to neither. The typer and `docs/internal-spec/inference-engine.md` name it on `MethodDispatcher`.

## Decision

A positional second entry: `PluginContribution.merged_return_type(call_node, scope, receiver_type)`, with `PluginContribution.try_dispatch(context)` one line over it. A site built from values the caller does not have is worse than a second entry that takes what the caller does have.

The precedent is the amendment's rule for a rung's second entry, where `UserMethod.infer` "takes its arguments as positionals" for the same reason. It fits a tier as it fits a rung, but the amendment states it only for rungs, so this applies it one step sideways. #3363 gave `MetaIntrospection` a second entry too (`array_new_element`); that was a helper with outside callers, not the tier's own function.

The allocation A/B over `lib` measures the move of all four tiers, this one included; the pull request's body has the figure.

## To undo

Rename `merged_return_type` to `try_dispatch(context)` with a three-line preamble (`call_node`, `scope` and `receiver_type` from the context), delete the one-line adapter, and build the context in `plugin_member_answers?`. Three places name the function: `spec/rigor/inference/method_dispatcher/plugin_contribution_spec.rb` (its `.merged_return_type` examples), the comment in `sig/rigor/plugin/base.rbs`, and the veto paragraph of `docs/internal-spec/inference-engine.md`.

ADR-116's slice S8 moves the veto's caller into a rung that holds a site. The veto could then pass `site.with(receiver: self_type)`, and the second entry would have no caller left.
