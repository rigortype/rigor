# A plugin's signature member stands down to an inline one too, and its file reports one notice row

- **PR:** [#2424](https://github.com/rigortype/rigor/pull/2424)
- **Issue:** [#2422](https://github.com/rigortype/rigor/issues/2422)
- **Class:** open-choice
- **Precedent:** [#610](https://github.com/rigortype/rigor/issues/610)
- **Decided:** 2026-10-27

## Background

#2422 extends the #610 stand-down from a plugin file's class header to its members: a method a bundled plugin's
deferred signature file declares, which another loaded source also declares, is left out of the plugin's file.
The brief lists inline RBS as one of the sources that stands a plugin member down. Two choices it did not settle
came up while implementing it.

First, inline RBS was added to the environment after the plugins' files, and ADR-112 WD5's consistency rule
(#1075) ranked a plugin's `.rbs` against an inline member like a project `sig/` file: the more precise side bound,
and on a contradiction the plugin's `.rbs` won. So an inline `def ordinalize: () -> Symbol` lost to the plugin's
`() -> String`, the opposite of #610's rule that the plugin stands down to the project's sources.

Second, the brief asked for one notice row per stood-down member "as the vendored notice does". The vendored
notice (#1713) is one row per directory listing its members. On `rigor-survey/conference-app` the activesupport
7.0 collection overlaps `rigor-activesupport-core-ext` on 289 methods.

## Options and trade-offs

Inline RBS:

- Keep the #1075 ranking for plugin files. No load-order change, but a user's inline annotation can lose to a
  plugin, and a contradiction reports `rbs.contradicting-signature` against the user's code naming a file the
  plugin owns.
- Load the plugins' files after inline RBS and drop them from the consistency rule, so the member planning sees
  inline members like any other source. One rule for every source. The load order of a class both a plugin and
  inline RBS declare changes (the inline declaration now comes first), and, by reading the code rather than a spec, a constant both
  declare would now drop the plugin's file rather than the inline one.

Notice granularity:

- One row per member: 289 `:info` rows on one Rails project.
- One row per plugin file, naming the count and the first 10 members with the displacing file each. The loader's
  `signature_standdowns` still carries one entry per member, so the grouping is only in the report.

## Decision

The plugins' files load after inline RBS and are excluded from the consistency rule, by #610's precedent that a
plugin stands down to the project's own sources. The notice is one row per plugin file, following the
vendored notice's shape, which the brief names as the model.

## To undo

Inline: move `add_deferred_signatures` back into `add_project_signatures` and drop the
`- project_sig_files(deferred_signature_paths)` exclusions in `build_env_attempt` and `RbsLoader#member_consistency`.
Notice: map each member row to its own diagnostic in `rbs_plugin_signature_stood_down_diagnostics`.
