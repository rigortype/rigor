# 01 — The checks

## Run `rigor doctor`

```sh
rigor doctor                 # human-readable: [FAIL] / [WARN] / [PASS] lines
rigor doctor --format json   # machine-readable
```

It runs one scoped analysis, audits the config, loads the plugins, and
checks baseline drift in a single pass, then prints a finding per
problem with a hint. The JSON shape:

```json
{ "status": "issues_found",
  "checks": [ { "id": "plugins", "status": "fail",
                "message": "Plugin load errors: 1",
                "hint": "Run `rigor plugins --strict` for the full per-plugin report." } ] }
```

- Top-level `status` is `issues_found` when any check has `status: "fail"`,
  otherwise `clean` — a run with only `warn` findings still reads `clean`,
  so read the `checks` array too.
- `checks[].status` is `fail`, `warn`, or `pass`. A check with nothing to
  report is usually **absent**, not `pass`; only `rbs_environment` reports
  a `pass` line.
- The command exits non-zero when any check fails.

Fix `fail` findings first, in the order below: an early failure is usually
the root cause of a cluster of confusing downstream diagnostics.

## The check ids

### `config_audit` — config resolves with nothing silently inert

`fail` with a count of configuration warnings. Doctor gives only the
count; the individual warnings are in `rigor check --format json` under
`config_warnings`. They cover the typo class whose only symptom is a
confusing downstream error: a `signature_paths:` that is missing / not a
directory / holds no `.rbs` (which would turn every covered call into a
false `call.undefined-method` at `evidence_tier: high`), a `libraries:`
name RBS does not recognise, a `disable:` / `severity_overrides:` id
naming no real rule, or a missing `bundler` / `rbs_collection` path.
**Each warning is a real misconfiguration — fix it.**

### `rbs_environment` — the type universe loaded

- `fail` — the RBS environment is empty (zero classes). It failed to build
  or loaded no signatures: look for duplicate declarations across
  `signature_paths:`, or run `rbs collection install` for gem signatures.
- `warn` — degraded: one or more `signature_paths:` files did not parse
  and were skipped. The run is quieter, not cleaner — the types those
  files declare are gone. Run `rbs validate` on the `sig/` set and fix
  the parse error.
- `pass` — healthy, with the class count.

### `plugins` — every configured plugin loads

`fail` with a count of plugin load errors. Run `rigor plugins --strict`
for the per-plugin report. A failure is usually a misspelled id or a
plugin whose `signature_paths:` did not resolve. Fix it, or the plugin's
type knowledge is silently absent.

### `plugin_skew` — a bundled plugin came from another installation

`warn` when a bundled plugin was loaded from a different `rigortype`
installation than the engine. The engine and its bundled plugins are
versioned together, so a mismatched copy can produce wrong diagnostics.
Make sure a single `rigortype` is on the load path.

### `baseline` — the baseline is not stale (if one exists)

- `fail` — drift: some baseline buckets are over their recorded count,
  cleared, or reducible. The hint is `rigor baseline regenerate`; before
  regenerating, run `rigor baseline drift` to see which buckets moved, so
  a regeneration does not bury a new catch (often after an upgrade — see
  `rigor-upgrade`).
- `warn` — the baseline file failed to load. Check the `baseline:` path
  in the config.

### `plugin_gap` — the stack has a plugin that is not enabled

Read from the `DEPENDENCIES` section of `Gemfile.lock`.

- `fail` — the project depends on gems that bundled plugins model, and
  **none** of those plugins is enabled: framework calls will not resolve.
  Add the plugins for the stack to `plugins:` (the `rigor-plugin-tune`
  skill does this).
- `warn` — one per plugin that models a direct dependency but is not
  enabled. Enable it, or leave it out deliberately; declining a plugin is
  a legitimate choice.

### `gemfile_install` — Rigor is a project dependency

`fail` when `rigortype` is resolved from a gem source in the project's
`Gemfile.lock`. Rigor is a tool, not a library: remove it from the
`Gemfile` and install it standalone (`rigor docs manual/01-installation`).

### `bundle_layout` — gem-shipped signatures are not discovered

`warn` when a `Gemfile.lock` exists but Rigor cannot locate the installed
bundle (the gems live in the active Ruby's default gem home). Gems that
ship their own `sig/` are then not loaded. Point Rigor at the install
root with `bundler.bundle_path:`, install into `vendor/bundle`, or supply
signatures with `rbs collection install` instead.

## Not covered by `rigor doctor`: is the analysis seeing your code?

```sh
rigor check --no-cache --format json | jq '.stats.target_files'
```

`--no-cache` matters: a result served from the run cache carries no
`stats`. If the file count is `0` or far below your project size, `paths:`
/ `exclude:` are mis-scoped, or the command is running from the wrong
directory. The analysis is only as good as the files it reads.
