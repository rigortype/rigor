# `plugin.api-surface` judges plugin source by its class declarations, and exempts every object's own members

- **PR:** [#2822](https://github.com/rigortype/rigor/pull/2822)
- **Issue:** [#2686](https://github.com/rigortype/rigor/issues/2686)
- **Class:** open-choice
- **Precedent:** [ADR-128](../docs/adr/128-plugin-hook-surface-interfaces.md)
- **Decided:** 2026-11-05

## Background

ADR-128 WD6 confines `plugin.api-surface` to "classes that inherit `Plugin::Base` outside `lib/`", and the ADR-130 slice 2 brief replaced the path with the class reading because third-party plugin gems live under `lib/rigor/plugins/...`. Three readings were left to the implementation: how "inherits `Plugin::Base`" and "plugin source" are decided, which members count as the interface's surface, and which receivers count as carrying the facet.

## Options and trade-offs

- **Plugin source.** A call is plugin source when the scope's recorded `Module.nesting` holds a class whose discovered superclass chain reaches `Rigor::Plugin::Base` (through a project base class too). `Base`'s own body is not plugin source, because `Base` does not inherit itself. Taking only the innermost entry would miss a module nested in a plugin class; reading `self_type` would miss a `node_rule` block, whose `self` is the plugin instance at runtime but whose lexical class is what the ADR names. A scope with no recorded nesting is not plugin source, so the rule stays silent rather than guess.
- **Surface.** A WD4-style allowance for `Object` / `Kernel` / `BasicObject` members (`nil?`, `respond_to?`, `is_a?`), which the boundary gate also allows. Without it, `scope.nil?` guards, which ADR-128 counts as valid, would report.
- **Receivers.** `Dynamic[<Rigor::Plugin interface>]`, or a union of such values with `nil`, since a nilable hook position keeps the facet on its non-nil arm (ADR-130 WD1). A union with any other member is skipped, because that member may declare the call.

## Decision

All three as listed. Each reports less than a looser reading would, which is the false-positive direction ADR-0 / ADR-5 ask for. The rule id stays `plugin.api-surface`, as ADR-128 names it, although `plugin.` is otherwise the prefix of a plugin's own rows (`plugin.<id>.<rule>`): the id is in `CheckRules::ALL_RULES`, so `disable:`, markers and `severity_overrides:` resolve it as a catalogue id before any plugin-id reading. A plugin whose manifest id is `api-surface` would share the prefix; none exists.

## To undo

The readings live in `lib/rigor/analysis/check_rules/plugin_api_surface.rb` (`plugin_source?`, `object_member?`, `receiver_interfaces`) and are pinned by `spec/integration/plugin_api_surface_spec.rb`. The rule is off by default, so no default run depends on them.
