# The override-parameter bridge serves every ADR-43 allow-listed ancestor, declines `initialize`, Object-surface declarations and a nearer definer, and keeps a reopen's shadow

- **PR:** [#2768](https://github.com/rigortype/rigor/pull/2768)
- **Issue:** [#2681](https://github.com/rigortype/rigor/issues/2681)
- **Class:** open-choice
- **Precedent:** [ADR-43](../docs/adr/43-rbs-complete-ancestor-resolution.md)
- **Decided:** 2026-11-04

## Background

#2681 asked that an overriding hook `def` in a source-only subclass of `Rigor::Plugin::Base` bind the parameter types `base.rbs` declares, as an empty RBS declaration of the subclass would. The issue did not settle five things:

- which ancestors this covers;
- whether a constructor counts as an override;
- what a member every class has (`Kernel#load`) does;
- what happens when a source class between the plugin and its ancestor also defines the hook;
- whether the fix that lets `Base`'s own Ruby source stop shadowing its RBS also applies to the manifest-declared ancestors.

## Options and trade-offs

- **Which ancestors.**
  - The engine seed (`Rigor::Plugin::Base`) alone is the narrowest reading.
  - The whole allow-list also covers the ancestors that rigor-graphql, rigor-grape and rigor-sorbet declare in `rbs_complete_ancestors:`, whose calls and block parameters already bridge. That changes typing in users' application code (a `GraphQL::Schema::Object` subclass's `def resolve`), which the bundled plugin trees do not exercise.
  - GitLab's `app/graphql` and `lib/api` (2,279 files) with its configured rigor-graphql, rigor-grape and rigor-sorbet: 358 diagnostics on both sides, identical. An instrumented head run bound 217 overrides there from the plugins' RBS, 181 of them `resolve` on Resolver and RelayClassicMutation subclasses.
- **`initialize`.** Bridging it is what RBS inheritance does. But a subclass constructor routinely takes other arguments, so declining costs only the typed parameters of an `initialize` that keeps the base's shape.
- **Object-surface members.** An ancestor's built definition answers `load` from `Kernel`. That is every class's member, not the ancestor's contract, so the bridge rejects a declaration owned by `BasicObject`, `Object`, `Kernel`, `Module` or `Class`. The name gate in front of the walk is only a cost filter.
- **A nearer definer.** `class Leaf < Mid < Base` where `Mid` also defines the hook: declining matches the call bridge, which already withholds past a nearer definer.
- **A reopen.** Letting the allow-listed ancestor's own source stop shadowing is right for `Rigor::Plugin::Base`, whose source in this repository is the implementation its RBS describes. For a manifest-declared ancestor, a project `def` on the class is a reopen (`class Grape::API; def self.desc`), and Ruby calls it. Treating it as the declaration's own source would type the call through RBS instead.

## Decision

- One allow-list serves calls, blocks and overrides.
- `initialize` is never bridged.
- A declaration owned by `BasicObject`, `Object`, `Kernel`, `Module` or `Class` is rejected for each ancestor separately.
- A nearer source definer, or an unsettled ancestor chain, withholds the override bridge as it withholds the call bridge.
- Only the engine seed's own source stops shadowing; a reopen of a manifest-declared ancestor keeps withholding, as it did before this PR.

Every choice that declines leaves the parameter `Dynamic[top]`, which reports nothing (ADR-5). This follows ADR-43's allow-list criterion and its nearer-definer rule (d20377b09, #1572); no earlier decision covered override parameters.

## To undo

- **Restrict the override bridge to the engine seed.** Make `RbsDispatch#allowed_rbs_complete_ancestor` accept only `ALLOWED_RBS_COMPLETE_ANCESTORS` when it is called with `overriding: true`.
- **Bridge `initialize`.** Remove `method_name == :initialize` from `RbsDispatch.def_declaration` and the matching example in `spec/integration/plugin_base_bridge_parameters_spec.rb`.

Either change needs the text of ADR-43 WD8 and of `inference-engine.md` § "Method Parameter Binding" adjusted.
