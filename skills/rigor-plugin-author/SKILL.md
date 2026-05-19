---
name: rigor-plugin-author
description: Author a new Rigor plugin end-to-end. Production plugins targeting real gems / frameworks land under `plugins/`; tutorial walkthroughs under `examples/`. Use when the user asks to create a Rigor plugin for X, write a plugin for a DSL, or extend Rigor for a framework. Covers requirements, placement, template selection, scaffolding, demo, integration spec, verification.
license: MPL-2.0
metadata:
  version: 0.1.0
  homepage: https://github.com/rigortype/rigor
---

# Rigor Plugin Author

Decide placement first (Phase 0 below), then load the four reference files in order. All commands run through the Nix Flake (`nix develop --command ...`) per `AGENTS.md`.

## Phase 0 — Decide where the plugin lands

Trigger this skill when the user requests a new plugin: "Create a Rigor plugin that catches Y", "Extend Rigor to understand our DSL Z", "Write a plugin similar to rigor-units but for currency", or Japanese equivalents.

Do NOT trigger for edits to existing plugins (ordinary edit tasks) or for analyser-engine work in `lib/rigor/inference/` / `lib/rigor/analysis/` / `lib/rigor/plugin/` (core development).

| Signal | Lands under |
| --- | --- |
| Real gem / framework (Rails, RSpec, dry-rb, Sorbet, Devise, Sidekiq, GraphQL, …) | **`plugins/<id>/`** |
| User's in-house DSL on a real project | **`plugins/<id>/`** |
| Installed via `Gemfile`, activated in `.rigor.yml` against real source | **`plugins/<id>/`** |
| Deliberately fictional / virtual domain (tiny Lisp, units-of-measure, fake route YAML) | **`examples/<id>/`** |
| Authored to **demonstrate one architectural surface** of the contract | **`examples/<id>/`** |
| Referenced by the handbook / ADRs as a teaching reference | **`examples/<id>/`** |

Default to `plugins/`. The five walkthroughs under [`examples/`](https://github.com/rigortype/rigor/tree/master/examples/) (`rigor-deprecations` / `rigor-lisp-eval` / `rigor-pattern` / `rigor-routes` / `rigor-units`) are a curated set; adding to that tree requires a positive teaching reason.

Mechanical differences: production specs live at `spec/integration/plugins/<id>_plugin_spec.rb`; walkthrough specs at `spec/integration/examples/<id>_plugin_spec.rb`. Both auto-include [`spec/integration/support/plugin_helpers.rb`](https://github.com/rigortype/rigor/blob/master/spec/integration/support/plugin_helpers.rb). RuboCop excludes `plugins/**/*` and `examples/**/*` but lints the specs.

## Reading order

Load each reference when you reach its phase. Don't skim ahead — the phases compound.

| Module | Read | Covers |
| --- | --- | --- |
| 1 | [`references/01-requirements-and-templates.md`](references/01-requirements-and-templates.md) | **Phases 1–2.** Five-question scope check (trigger surface / look at / prove / diagnostic / config). Picks ADR-16 macro-substrate tier (A/B/C/D, declarative) or a hand-rolled walker template from six worked examples. |
| 2 | [`references/02-scaffold-walker-demo.md`](references/02-scaffold-walker-demo.md) | **Phases 3–5.** Directory tree, gemspec, plugin class skeleton, per-template walker patterns, IoBoundary + cache producer rule (read BEFORE `cache_for`), demo project with `tmp/`-anchored cache + per-demo `.gitignore`. |
| 3 | [`references/03-test-and-ship.md`](references/03-test-and-ship.md) | **Phases 6–10.** RSpec integration helpers, README sections, CHANGELOG `[Unreleased]` entry, `make verify` expectations, commit subject convention. |
| 4 | [`references/04-appendix.md`](references/04-appendix.md) | **Side material.** Common pitfalls (top 10), real-Rails alignment for `rigor-rails-*` plugins, post-ADR-9 `services.fact_store` cross-plugin pattern, reading list, closing checklist. |

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

If the requirement fits neither substrate nor template, **stop and ask the user** — the v0.1.x plugin contract may not yet expose what they need. Check the [per-library survey](https://github.com/rigortype/rigor/blob/master/docs/notes/20260515-macro-expansion-library-survey.md) before inventing a workaround.
