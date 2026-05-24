---
name: rigor-plugin-author
description: |
  Author a new Rigor plugin end-to-end: decide `plugins/` (production) vs `examples/` (tutorial), then run requirements → template → scaffold → demo → spec → verify. Triggers: "Create a Rigor plugin for X", "Extend Rigor for our DSL", "Plugin similar to rigor-units for currency". NOT for edits to existing plugins or analyser-engine work in `lib/rigor/`.
license: MPL-2.0
metadata:
  version: 0.1.0
  homepage: https://github.com/rigortype/rigor
---

# Rigor Plugin Author

Decide placement first (Phase 0 below), then load the four reference files in order. All commands run through the Nix Flake (`nix develop --command ...`) per `AGENTS.md`.

## Phase 0 — Decide where the plugin lands

Trigger this skill when the user requests a **new** plugin: "Create a Rigor plugin that catches Y", "Extend Rigor to understand our DSL Z", "Write a plugin similar to rigor-units but for currency", or Japanese equivalents.

Do NOT trigger for:

- **Edits / bug-fixes / new diagnostics on an existing plugin** under `plugins/<id>/` or `examples/<id>/` — these are ordinary edit tasks; modify the plugin in place and bump only the `[Unreleased]` CHANGELOG.
- **Analyser-engine work** in `lib/rigor/inference/` / `lib/rigor/analysis/` / `lib/rigor/plugin/` — that's core development.
- **Post-landing maintenance** (refactor / rename / dependency bump on an already-shipped plugin) — these don't need the 10-phase pipeline; they're scoped per task.

| Signal | Lands under |
| --- | --- |
| Real gem / framework (Rails, RSpec, dry-rb, Sorbet, Devise, Sidekiq, GraphQL, …) | **`plugins/<id>/`** |
| User's in-house DSL on a real project | **`plugins/<id>/`** |
| Installed via `Gemfile`, activated in `.rigor.yml` against real source | **`plugins/<id>/`** |
| Deliberately fictional / virtual domain (tiny Lisp, units-of-measure, fake route YAML) | **`examples/<id>/`** |
| Authored to **demonstrate one architectural surface** of the contract | **`examples/<id>/`** |
| Referenced by the handbook / ADRs as a teaching reference | **`examples/<id>/`** |

Default to `plugins/`. The five walkthroughs under [`examples/`](../../../examples/) (`rigor-deprecations` / `rigor-lisp-eval` / `rigor-pattern` / `rigor-routes` / `rigor-units`) are a curated set; adding to that tree requires a positive teaching reason.

Mechanical differences: production specs live at `spec/integration/plugins/<id>_plugin_spec.rb`; walkthrough specs at `spec/integration/examples/<id>_plugin_spec.rb`. Both auto-include [`spec/integration/support/plugin_helpers.rb`](../../../spec/integration/support/plugin_helpers.rb). RuboCop excludes `plugins/**/*` and `examples/**/*` but lints the specs.

## Phase 0.5 — Where this plugin will live (per ADR-31)

Phase 0's table assumes you are a **Rigor maintainer** authoring directly inside the monorepo. The placement table above applies to monorepo-internal authoring only — typical paths: a new bundled plugin Rigor team adds to support a real framework, or a new `examples/` walkthrough teaching an architectural surface.

If you are **not** a Rigor maintainer (i.e. you don't have commit rights to [rigortype/rigor](https://github.com/rigortype/rigor)), or you are authoring a plugin in response to an external author's proposal, the plugin's home is **outside** this monorepo per [ADR-31](../../../docs/adr/31-plugin-contribution-and-supply-chain-policy.md) (plugin contribution and supply-chain policy):

| Situation | Path |
| --- | --- |
| Authoring a plugin you'll consume yourself | **Third-party `rigor-<gem>` gem in your own repo** depending on `gem "rigortype"` ([ADR-31 WD4](../../../docs/adr/31-plugin-contribution-and-supply-chain-policy.md)). For FFI bindings, also see [`rigor-ffi-plugin-author`](../rigor-ffi-plugin-author/SKILL.md) which adds an upstream coverage-assessment phase to talk users out of plugin work when core suffices. |
| Want the plugin officially bundled with Rigor | **File an issue** at the rigor repo with the [ADR-31 WD2](../../../docs/adr/31-plugin-contribution-and-supply-chain-policy.md) fields: wrapped gem identity, evidence of community adoption ([ADR-31 WD3](../../../docs/adr/31-plugin-contribution-and-supply-chain-policy.md) keeps the criterion deliberately vague), pointer to your working third-party plugin (as reference implementation), upstream-effort confirmation. The Rigor team re-implements from scratch; you are credited via `Co-authored-by:` on the implementation commit(s). |
| You ARE a Rigor maintainer and the plugin's authorship matches the bundled-plugins discipline | Proceed with Phase 0's table above (monorepo placement). |

**Why there is no PR path for new plugins.** The `rigortype` gem runs in every user's CI / dev environment, so accepting external code through a PR is the canonical supply-chain attack vector (`xz-utils`, `event-stream`, `ua-parser-js`). [ADR-31 WD1](../../../docs/adr/31-plugin-contribution-and-supply-chain-policy.md) codifies the de facto practice that every bundled plugin has been maintainer-authored; this SKILL's procedural shape (Phases 1–10 below) supports both the monorepo path and the third-party-repo path identically — only the destination directory tree differs.

## Reading order — modules and their outputs

Load each reference when you reach its phase. The phases assume prior context, so backwards skipping is fine but forward skipping leaves gaps.

| Module | Read | Covers | Output of this module |
| --- | --- | --- | --- |
| 1 | [`references/01-requirements-and-templates.md`](references/01-requirements-and-templates.md) | **Phases 1–2.** Five-question scope check (trigger surface / look at / prove / diagnostic / config). Picks ADR-16 macro-substrate tier (A/B/C/D, declarative) or a hand-rolled walker template from six worked examples. | Five Q&A answers + one template name from the table. |
| 2 | [`references/02-scaffold-walker-demo.md`](references/02-scaffold-walker-demo.md) | **Phases 3–5.** Directory tree, gemspec, plugin class skeleton, per-template walker patterns, IoBoundary + cache producer rule (read BEFORE `cache_for`), demo project with `tmp/`-anchored cache + per-demo `.gitignore`. | Working plugin directory + runnable `demo/` whose `rigor check` diagnostic stream matches expectations. |
| 3 | [`references/03-test-and-ship.md`](references/03-test-and-ship.md) | **Phases 6–10.** RSpec integration helpers, README sections, CHANGELOG `[Unreleased]` entry, `make verify` expectations, commit subject convention. | Passing integration spec + README + CHANGELOG entry + one green `make verify` + one commit. |
| 4 | [`references/04-appendix.md`](references/04-appendix.md) | **Side material.** Common pitfalls (top 10), real-Rails alignment for `rigor-rails-*` plugins, post-ADR-9 `services.fact_store` cross-plugin pattern, reading list, closing checklist. | Reference-only — no fixed output. Consult per the surface the plugin touches. |

## Worked examples to copy from

Map the [Phase 1](references/01-requirements-and-templates.md) answers to one of these:

```text
ADR-16 substrate (declarative, no walker):
  Tier A  → plugins/rigor-sinatra/        (block-as-method)
  Tier B  → plugins/rigor-devise/         (trait registry)
  Tier C  → plugins/rigor-dry-struct/     (heredoc template)
  Tier D  → contract only as of v0.1.x

Hand-rolled walker templates:
  Q1=A/B Q2=A Q3=A Q5=C        → examples/rigor-deprecations/  (~80 lines; config-driven)
  Q1=A   Q2=A Q3=E Q5=A/B      → examples/rigor-lisp-eval/     (literal AST recursion)
  Q1=D   Q2=B Q3=C Q5=A        → examples/rigor-units/         (local-variable flow)
  Q1=C/E Q2=C Q3=A Q5=A/B      → plugins/rigor-statesman/      (two-pass collect → validate)
  Q1=B   Q2=A/B Q3=B Q5=C      → examples/rigor-pattern/       (asks Scope#type_of)
  Q1=A/B/C Q2=E Q3=A/D Q5=C/D  → examples/rigor-routes/        (IoBoundary + cache)
```

If the requirement fits neither substrate nor template, **stop and ask the user** — the v0.1.x plugin contract may not yet expose what they need. Check the [per-library survey](../../../docs/notes/20260515-macro-expansion-library-survey.md) before inventing a workaround.

## What "done" looks like

The plugin is shippable when **all** of these hold:

- `bundle exec exe/rigor check` against the plugin's `demo/` prints the diagnostic stream documented in the plugin's `README.md` § "What the plugin recognises" — verbatim, no drift.
- `spec/integration/plugins/<id>_plugin_spec.rb` (or `examples/`) covers every diagnostic shape the plugin emits, passing under `make verify`.
- `make verify` is green: parallel-rspec 0 failures, rubocop 0 offenses on the spec file (the plugin source itself is excluded from rubocop), `rigor check lib` baseline unchanged.
- `git status` is clean (`tmp/`-anchored cache + per-demo `.gitignore` keep build artefacts out of the index).
- `CHANGELOG.md` `[Unreleased]` carries one new bullet naming the plugin; `Rigor::VERSION` is **not** bumped (the project user drives release cuts per `AGENTS.md` § "Release Cadence").
- One commit, subject following `AGENTS.md` style (`Add rigor-<id> plugin (<facet>)` or `Add rigor-<id> walkthrough (<facet>)`).

Publishing to RubyGems is **out of scope** for this skill — the plugin lives in this repo until a maintainer runs the `git subtree split` + `bundle exec rake release` flow ([`.claude/skills/rigor-release-prep/SKILL.md`](../rigor-release-prep/SKILL.md)).

## Example walkthrough

Concrete trace through a fictional request — "Create a Rigor plugin for the `dotenv` gem" — to anchor expectations:

1. **Phase 0** — `dotenv` is a real gem → `plugins/rigor-dotenv/`. (Not a fictional teaching domain.)
2. **Phase 1** (Module 1) — user answers narrow the surface: Q1=A (`Dotenv.load(path)` call), Q2=E (reads `.env` file), Q3=A (known finite set of variable names), Q4=B (error on missing var), Q5=D (external file path config).
3. **Phase 2** — answers match the `rigor-routes` template row (Q1=A/B/C, Q2=E, Q3=A/D, Q5=C/D). Copy the `rigor-routes` directory layout.
4. **Phases 3–5** (Module 2) — scaffold `plugins/rigor-dotenv/{lib,demo}/`, add the cache-producer + IoBoundary pattern verbatim from Module 2, demo with `tmp/`-anchored cache.
5. **Phases 6–10** (Module 3) — write `spec/integration/plugins/dotenv_plugin_spec.rb`, README, CHANGELOG entry, run `make verify`, single commit.

If the request shifts mid-flow (e.g. user later says "and also error when the value is empty"), restart from Phase 1 Q3 — the requirements gathering is the gate that prevents accidental scope creep.

## Troubleshooting (most common at landing time)

- **`make verify` fails on the new spec** — the spec doesn't `Rigor::Plugin.unregister!` in `before` + `after`. See [`references/04-appendix.md`](references/04-appendix.md) § Common pitfalls #2.
- **Cache key never invalidates** — `io_boundary.read_file` was called AFTER `cache_for` instead of before. See [`references/02-scaffold-walker-demo.md`](references/02-scaffold-walker-demo.md) Phase 4.5.
- **Diagnostics don't appear in the demo output** — `source_family:` was passed to the `Diagnostic` constructor. Don't — the runner overwrites it. See pitfall #7.
- **`Prism::CallNode#name == "foo"` always false** — `node.name` returns a `Symbol`. Use `== :foo`. See pitfall #4.
- **Plugin's `lib/` not on load path in tests** — spec needs `$LOAD_PATH.unshift(...)` before `require "rigor-<id>"`. See pitfall #10.
- **`git status` shows leaked `.rigor/cache/`** — demo `.rigor.yml` didn't set `cache.path: tmp/.rigor/cache` or missing per-demo `/tmp/`-only `.gitignore`. See pitfall #1.
