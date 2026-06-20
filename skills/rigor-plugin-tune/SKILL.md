---
name: rigor-plugin-tune
description: |
  Re-scan a configured project's Gemfile.lock against Rigor's bundled plugin catalogue and enable the plugins that match its current dependencies (Rails, RSpec, dry-rb, Sidekiq, Devise, …), then verify they all load. Run it after adding a gem, or when an onboarding predates a dependency the project now uses. Triggers: "enable the right Rigor plugins", "I added gem X, does Rigor have a plugin?", "which rigor plugins should this project use?", "rigor plugins for my stack". NOT for first-time onboarding (use rigor-project-init, which does the initial selection) and NOT for authoring a new plugin (use rigor-plugin-author).
license: MPL-2.0
metadata:
  version: 0.1.0
  homepage: https://github.com/rigortype/rigor
---

# Rigor Plugin Tune

`rigor-project-init` selects plugins once, at onboarding. Dependencies
drift afterward — a project adds Sidekiq, adopts dry-rb, brings in
shoulda-matchers — and the bundled Rigor plugin that understands the new
gem is not enabled until someone wires it. This skill is the recurring
"re-match plugins to the current Gemfile.lock" pass.

All `rigor-*` plugins ship **bundled inside the `rigortype` gem** — no
separate install. Enabling one is just adding its id to `plugins:` in
`.rigor.dist.yml`.

## When to use

- The project added (or removed) a gem since it was onboarded.
- `rigor check` is missing framework knowledge (e.g. ActiveRecord
  relation methods, RSpec matchers) that a bundled plugin would supply.

## When NOT to use

- First-time setup — `rigor-project-init` does the initial selection.
- A gem with **no** bundled plugin and no RBS — that is
  `rigor-rbs-setup` (community RBS) or, for your own DSL,
  `rigor-plugin-author`.

## Procedure

### Phase 1 — list what is enabled vs what is installed

Read the current `plugins:` in `.rigor.dist.yml`, and the project's
dependencies in `Gemfile.lock`.

### Phase 2 — match against the bundled catalogue

The authoritative, current list of bundled plugins (the count drifts as
new ones land) is the catalogue:

<https://github.com/rigortype/rigor/blob/master/plugins/README.md>

For each Gemfile.lock dependency, check whether a bundled `rigor-<gem>`
plugin exists and is **not** already in `plugins:`. Common matches:
`activerecord`/`actionpack` → the Rails plugins, `rspec` → `rigor-rspec`,
`dry-*` → the dry-rb plugins, `devise`, `sidekiq`, `sorbet`, etc. Add the
missing ones to `plugins:`.

### Phase 3 — verify every plugin loads

```sh
rigor plugins --strict
```

`rigor plugins` reports the activation status of every configured plugin;
`--strict` exits non-zero on any activation failure (ideal as a CI gate).
Fix any failure it reports (a misspelled id, a missing `signature_paths:`)
before moving on.

### Phase 4 — re-check

```sh
rigor check
```

The framework calls the newly-enabled plugins understand should now
resolve. If enabling a plugin surfaced new diagnostics, treat the diff as
usual (baseline regenerate in acknowledge mode, or fix genuine findings).

## Next step

Re-run `rigor skill describe` for the next move.
