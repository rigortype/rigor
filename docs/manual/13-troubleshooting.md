# Troubleshooting

Common problems and their fixes. For editor-specific issues,
see [Editor integration](09-editor-integration.md); for "why
did this diagnostic (not) fire", see
[handbook chapter 8](../handbook/08-understanding-errors.md).

## `rigor: command not found`

Rigor is installed but not on your `PATH`. With a version
manager this usually means the shell is not activated — see
[Installing Rigor](01-installation.md). As a stop-gap,
`mise exec gem:rigortype -- rigor …` runs it explicitly.

## `rigor check` analyses nothing

Rigor checks the `paths:` from the configuration file when no
paths are given on the command line. If `paths:` is wrong, or
no config file was found, the run is empty. Confirm a
`.rigor.yml` or `.rigor.dist.yml` exists at the project root,
or pass paths explicitly: `rigor check lib app`.

## Everything is `untyped` / `Dynamic[Top]`

Rigor has no type information for the code in question. The
usual causes:

- **A gem ships no RBS.** Install signatures with
  `rbs collection install`, or opt into
  `dependencies.source_inference` (see
  [Configuration](03-configuration.md)).
- **A framework needs a plugin.** Rails, RSpec, dry-rb and
  others are only legible to Rigor through a
  [plugin](07-plugins.md).
- **A project monkey-patch is invisible.** List the patching
  files under `pre_eval:` so Rigor walks them first.

`rigor type-of FILE:LINE:COL` reports the exact type at a
point, which narrows down where the information is lost.

## Too many diagnostics to act on

A first run on a large, untyped project can report hundreds of
diagnostics. Do not start by suppressing them one by one:

1. `rigor triage` — see which rules and files dominate, with
   hints about likely causes.
2. Fix the systemic causes triage points at — a missing
   plugin, a missing RBS bundle.
3. `rigor baseline generate` — snapshot the rest so CI tracks
   only new diagnostics. See [Baselines](06-baseline.md).

The [`rigor-project-init` skill](08-skills.md) automates this
sequence.

## A diagnostic is wrong (a false positive)

Rigor aims never to flag working code, so a genuine false
positive is a bug worth reporting. In the meantime, suppress
the single site with a `# rigor:disable <rule>` comment (see
[Diagnostics](04-diagnostics.md)) — prefer that over a
project-wide `disable:`, which also hides real instances.

If the diagnostic is *correct* but you are not ready to fix
it, a [baseline](06-baseline.md) is the right tool.

## A result looks stale

It should not — cache entries are keyed by content and
invalidate themselves (see [Caching](12-caching.md)). If you
suspect the cache anyway, `rigor check --clear-cache` rules it
out. A result that survives a cleared cache is real analyzer
behaviour, not a caching artefact.

## The run is slow

- Let the cache warm up — the first run is the slow one.
- Narrow `paths:` and widen `exclude:` so Rigor is not walking
  generated or vendored code.
- For a large project, `rigor check --workers=N` spreads
  per-file analysis across Ractor workers.

## Reporting a bug

Open a GitHub issue with the Rigor version (`rigor version`),
the command you ran, a minimal reproduction, and — for a
suspected false positive — what you expected Rigor to infer.
