---
name: rigor-plugin-author
description: |
  Author a Rigor plugin in your own repository — a standalone rigor-prefixed gem or a project-private plugin — to teach Rigor about an application DSL, framework, or metaprogramming pattern. Covers gemspec / Gemfile wiring, the plugin class and AST walker, return-type contributions, fixture-based testing (RSpec or Minitest), and version pinning against the pre-1.0 plugin contract. Triggers: "write a Rigor plugin for our DSL", "extend Rigor for X in this project", "make Rigor understand our macro". NOT for onboarding a project (use rigor-project-init) or reducing a baseline (use rigor-baseline-reduce).
license: MPL-2.0
metadata:
  version: 0.1.0
  homepage: https://github.com/rigortype/rigor
---

# Rigor Plugin Author (external)

Author a Rigor plugin **in your own repository** — to teach Rigor a
DSL, framework convention, or metaprogramming pattern its core
analyzer cannot follow. The result is either a standalone
`rigor-<id>` gem or a project-private plugin.

This skill targets **external authors**: you depend on the published
`rigortype` gem (`bundle add rigortype`) and use the public plugin
API surface — `Rigor::Plugin::Base` and friends. It does not assume
the rigor monorepo's `Makefile`, `spec/integration/` helpers, or Nix
environment.

> **Authoring inside the rigor monorepo instead?** If you are adding
> a plugin to rigor's own `plugins/` or `examples/` tree, use the
> contributor `rigor-plugin-author` skill bundled in that repo — it
> covers the in-repo layout, `plugin_helpers.rb`, and `make verify`.
> This skill is for plugins that live in *your* project.

## First: load the version-current copy

The plugin contract is pre-1.0 and moving (see the next section), so this
skill's step detail — in its `references/` files — is exactly the kind that
drifts between releases. Follow the copy that ships with the **installed**
Rigor rather than any vendored or frozen copy of this file. Get the complete
current procedure (body + all references, inline) in one call:

```sh
rigor skill --full rigor-plugin-author
```

If you already loaded this skill *via* `rigor skill` you have the current
copy — just proceed. If the `rigor` command is not available, run
**`rigor-next-steps`** to install Rigor first, then come back.

## Important — the plugin contract is a preview (pre-1.0)

Rigor's plugin contract (ADR-2) is **not yet frozen**. It stabilises
at `rigortype` v0.2.0. Until then, treat each `rigortype` minor
release as potentially contract-changing:

- **Pin `rigortype` tightly** — `>= 0.1.0, < 0.2.0` in your gemspec
  or Gemfile. Do not float across the v0.2.0 boundary blind.
- Expect to **revisit your plugin** when you bump `rigortype` to the
  next minor. The walker hook signature, the `Diagnostic` shape, and
  the type carriers may shift.
- After v0.2.0 the contract is stable and ordinary semver applies.

Tell the user this up front. A plugin written today is a preview
artefact, valuable but not yet on a stable foundation.

## Read a real plugin — `rigor plugin`

You do not have to learn the `Rigor::Plugin::Base` surface from this
prose alone. Because Rigor is installed on disk (`mise` / `gem
install`), every plugin bundled in the toolchain is readable source.
Use it as a worked-example library throughout this skill:

```sh
rigor plugin list                              # all bundled + example plugins, with paths
rigor plugin print rigor-activesupport-core-ext  # a plugin's main source, inline
rigor plugin path  rigor-units                 # the dir, to browse with your file tool
rigor plugin root                              # gem root + public API (lib/rigor/plugin.rb)
```

`rigor plugin` (singular) browses the toolchain's plugins; `rigor
plugins` (plural) reports your own `.rigor.yml` activation — different
commands. When a step below is thinner than you need, read a shipped
plugin that does the same thing. (Paths are local to where `rigor`
runs — see the command's own note about containers.)

## Phase 0 — Standalone gem or project-private?

Decide where the plugin lives before scaffolding anything.

| Signal | Build it as |
| --- | --- |
| The DSL/library is reusable across projects, or you want to publish it | **Standalone `rigor-<id>` gem** — own repo, own gemspec, RubyGems-publishable |
| The pattern is specific to *one* application's own code / in-house DSL | **Project-private plugin** — lives inside the app repo, never published |

Both produce the same plugin class and walker; they differ only in
packaging and activation (Phase 1). When unsure, default to
**project-private** — it is less ceremony, and a plugin can always
be extracted into a gem later.

Do NOT use this skill for:

- **Onboarding a project to Rigor** (writing `.rigor.yml`, choosing
  plugins) → `rigor-project-init`.
- **Reducing a baseline** → `rigor-baseline-reduce`.
- **Editing an existing, already-working plugin** — that is ordinary
  code work; modify the plugin class directly.

## How a plugin works — the one-paragraph model

A Rigor plugin is a Ruby class that subclasses `Rigor::Plugin::Base`,
declares a `manifest(id:, version:, …)`, and calls
`Rigor::Plugin.register(self)` at load time. When `.rigor.yml` lists
the plugin under `plugins:`, Rigor `require`s it and runs its
**node rules**: the plugin declares `node_rule(Prism::CallNode) { |node,
scope, path, _fc, context| … }`, and the engine — which owns the single
AST walk per file — hands every matching node to the block along with a
`scope` it can query for inferred types. The block returns an array of
`Rigor::Analysis::Diagnostic` (built via the `diagnostic` helper).
Optionally the plugin also declares `dynamic_return(receivers:)` /
`narrowing_facts(methods:)` to *supply* a return type or narrowing facts
for call sites the core analyzer types as `Dynamic`. (`narrowing_facts`
was renamed from `type_specifier` in ADR-80; `type_specifier` remains as a
deprecating alias removed in 0.3.0 — use `narrowing_facts` in new plugins.)
`#diagnostics_for_file`
is the file-rule surface for whole-file diagnostics a per-node walk can't
express. (`flow_contribution_for` was removed pre-1.0 in ADR-52 WD3 —
defining it now raises `ArgumentError`; use `dynamic_return` /
`narrowing_facts`. See Phase 2.)

## Phase outline

| Phase | What | Reference |
| --- | --- | --- |
| 1 | Package and scaffold — gem vs project-private layout, gemspec / Gemfile, the plugin class skeleton, `.rigor.yml` activation. | [`references/01-plan-and-scaffold.md`](references/01-plan-and-scaffold.md) |
| 2 | Node rules — `node_rule` (engine-owned walk), building `Diagnostic`s via `Base#diagnostic`, querying `scope.type_of`, calling the target library directly instead of reimplementing it (ADR-39: `Plugin::Inflector`, `Base.suggest`), optional `dynamic_return` / `narrowing_facts`, RBS for the DSL. | [`references/02-walker-and-types.md`](references/02-walker-and-types.md) |
| 3 | Test and ship — fixture-based tests (RSpec / Minitest, no rigor internals), version pinning, README, publish or keep private. | [`references/03-test-and-ship.md`](references/03-test-and-ship.md) |

## Reading order — modules

| Module | Read | Covers |
| --- | --- | --- |
| 1 | [`references/01-plan-and-scaffold.md`](references/01-plan-and-scaffold.md) | **Phase 1.** The gem vs project-private packaging split, directory trees for both, gemspec template, project-private path-gem / `RUBYLIB` activation, the `Rigor::Plugin::Base` skeleton, `.rigor.yml` `plugins:` wiring. |
| 2 | [`references/02-walker-and-types.md`](references/02-walker-and-types.md) | **Phase 2.** The `node_rule` engine-owned AST walk over Prism nodes, the `Base#diagnostic` helper, asking the analyzer for inferred types via `scope.type_of`, two-pass / lexical context (`node_file_context` / `NodeContext`), the optional `dynamic_return` / `narrowing_facts` return-type hooks (`narrowing_facts` was renamed from `type_specifier` in ADR-80, alias removed in 0.3.0; `flow_contribution_for` was removed pre-1.0 in ADR-52 WD3), calling the target library's pure methods directly rather than reimplementing them (ADR-39: `Plugin::Inflector` over the real `ActiveSupport::Inflector`; `Base.suggest` for did-you-mean), and shipping `sig/*.rbs` so the DSL's types are visible. |
| 3 | [`references/03-test-and-ship.md`](references/03-test-and-ship.md) | **Phase 3.** Testing a plugin from outside the monorepo — fixture projects driven through `rigor check --format json`, plus pure unit tests of dispatch tables — with RSpec or Minitest. Version pinning against the pre-1.0 contract. README. Publishing to RubyGems or keeping the plugin private. |
