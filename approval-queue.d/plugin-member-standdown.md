# A plugin's signature member stands down to an inline one too, its colliding declarations stand down alone, and its file reports one notice row

- **PR:** [#2424](https://github.com/rigortype/rigor/pull/2424)
- **Issue:** [#2422](https://github.com/rigortype/rigor/issues/2422)
- **Class:** open-choice
- **Precedent:** [#610](https://github.com/rigortype/rigor/issues/610)
- **Decided:** 2026-10-27

## Background

#2422 extends the #610 stand-down from a plugin file's class header to its members. The user ruled on the
review of #2424 that a plugin method colliding with a source that is not the project's own (an `rbs collection
install`, a gem's `sig/`, a vendored or another plugin's file) composes with it as an overload continuation
rather than standing down, and that it stands down only to the project's own `sig/` or inline RBS. That ruling
is recorded in `docs/type-specification/diagnostic-policy.md` (the `rbs.coverage.plugin-signature-stood-down`
row), `docs/manual/plugins/rigor-activesupport-core-ext.md` and the `changelog.d/fixed/plugin-member-standdown.md`
fragment; it is the user's, not this entry's. Three choices around it were made without a ruling.

First, inline RBS was added to the environment after the plugins' files, and ADR-112 WD5's consistency rule
(#1075) ranked a plugin's `.rbs` against an inline member like a project `sig/` file: the more precise side bound,
and on a contradiction the plugin's `.rbs` won. So an inline `def ordinalize: () -> Symbol` lost to the plugin's
`() -> String`, the opposite of #610's rule that the plugin stands down to the project's sources.

Second, loading the plugins after inline RBS made a declaration both declare (a constant such as rigor-ffi's
`FFI::Pointer::NULL`) raise `DuplicatedDeclarationError` on the plugin's file and drop all of it. The review
ruled, by the same precedent, that only the conflicting declaration stands down.

Third, the brief asked for one notice row per stood-down member "as the vendored notice does". The vendored
notice (#1713) is one row per directory listing its members. Before the composing ruling, the activesupport 7.0
collection on `rigor-survey/conference-app` overlapped `rigor-activesupport-core-ext` on 289 methods.

## Options and trade-offs

Inline RBS:

- Keep the #1075 ranking for plugin files. No load-order change, but a user's inline annotation can lose to a
  plugin, and a contradiction reports `rbs.contradicting-signature` against the user's code naming a file the
  plugin owns.
- Load the plugins' files after inline RBS and drop them from the consistency rule, so the planner sees inline
  members like any other project source. One rule for every source. The load order of a class both a plugin and
  inline RBS declare changes (the inline declaration now comes first).

Colliding declarations: drop the plugin's whole file (what the load order produced), or only the declaration.

Notice granularity:

- One row per stood-down declaration: hundreds of `:info` rows on a project whose own `sig/` overlaps a plugin.
- One row per plugin file, naming the count and the first 10 declarations with the displacing file each. The
  loader's `signature_standdowns` still carries one entry per declaration, so the grouping is only in the report.
  A composed method is not in it: the plugin's overloads still bind, so nothing degraded.

## Decision

The plugins' files load after inline RBS and are excluded from the consistency rule, by #610's precedent that a
plugin stands down to the project's own sources. A colliding constant, global, type alias, interface, class alias
or kind-clashing type stands down alone. The notice is one row per plugin file, following the vendored notice's
shape, which the brief names as the model, and composed methods are left out of it.

A type whose kind contradicts another source's stands down whole, with the types nested in it, rather than as a
#1713-style shell that keeps them. The round-2 review accepted this: a class one source declares as a module is a
program that is wrong at runtime, and losing the nested types costs no false positive.

The composing ruling's continuation order and continuing onto an attribute or alias were verified on rbs 4.2 locally.
CI's `RBS compatibility (RBS 3.x)` job runs `spec/rigor/environment` on the 3.x line, which includes
`plugin_sig_member_stand_down_spec.rb`'s order and attribute/alias examples, so the 3.x line is checked there rather
than locally.

## To undo

Inline: move `add_deferred_signatures` back into `add_project_signatures` and drop the
`- project_sig_files(deferred_signature_paths)` exclusions in `build_env_attempt` and `RbsLoader#member_consistency`.
Declarations: drop the non-type branch of `DeferredSignaturePlan.plan_declaration`. Notice: map each member row
to its own diagnostic in `rbs_plugin_signature_stood_down_diagnostics`.
