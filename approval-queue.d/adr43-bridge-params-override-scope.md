# The override-parameter bridge serves every ADR-43 allow-listed ancestor, and declines `initialize` and past a nearer definer

- **PR:** [#2768](https://github.com/rigortype/rigor/pull/2768)
- **Issue:** [#2681](https://github.com/rigortype/rigor/issues/2681)
- **Class:** open-choice
- **Precedent:** [ADR-43](../docs/adr/43-rbs-complete-ancestor-resolution.md)
- **Decided:** 2026-11-04

## Background

#2681 asked that an overriding hook `def` in a source-only subclass of `Rigor::Plugin::Base` bind the parameter types `base.rbs` declares, as an empty RBS declaration of the subclass would. The issue did not say which ancestors this covers, whether a constructor counts as an override, or what happens when a source class between the plugin and `Base` also defines the hook.

## Options and trade-offs

- **Which ancestors.** The engine's own seed (`Rigor::Plugin::Base`) alone is the narrowest reading of the issue. The whole ADR-43 allow-list also covers the manifest-declared ancestors (`rbs_complete_ancestors:` in rigor-graphql, rigor-grape and rigor-sorbet), whose calls and block parameters already bridge. Two lists would make the override bridge disagree with the call bridge on the same class; one list means a GraphQL or Sorbet user's override binds from the plugin's bundled RBS, which those plugins declare complete.
- **`initialize`.** Bridging it is what RBS inheritance does. But a subclass constructor routinely takes other arguments (`def initialize(name)` under a base `(Integer count)`), and positional slots bind by index, so the bridge would read correct code as a contradiction. Declining costs the typed parameters of an `initialize` that does keep the base's shape.
- **A nearer definer.** `class Leaf < Mid < Base` where `Mid` also defines the hook: binding `Leaf`'s parameters from `Base` is right when `Mid` keeps the contract and wrong when it changes it. Declining matches the call bridge, which already withholds past a nearer definer.

## Decision

One allow-list for calls, blocks and overrides; `initialize` never bridged; a nearer source definer, or an unsettled ancestor chain, withholds the override bridge as it withholds the call bridge. Every choice that declines leaves the parameter `Dynamic[top]`, which reports nothing (ADR-5). This follows ADR-43's allow-list criterion and its nearer-definer rule (d20377b09, #1572); no earlier decision covered override parameters.

## To undo

Restricting the override bridge to the engine seed is one membership test in `RbsDispatch#allowed_rbs_complete_ancestor` behind `overriding:`. Bridging `initialize` is removing `method_name == :initialize` from `RbsDispatch.def_declaration` and the matching example in `spec/integration/plugin_base_bridge_parameters_spec.rb`. Either change needs the ADR-43 WD8 and `inference-engine.md` § "Method Parameter Binding" text adjusted.
