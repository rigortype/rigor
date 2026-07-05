# 01 — The four checks

Each check runs a validator Rigor already ships and interprets its
output. Run them in order; the first failure is usually the root cause of
a cluster of confusing downstream diagnostics.

## 1. Config resolves with nothing silently inert

```sh
rigor check --format json   # read the `config_warnings` array
```

`rigor check` audits the config and emits `config_warnings` for the typo
class whose only symptom is a confusing downstream error: a
`signature_paths:` that is missing / not a directory / holds no `.rbs`
(which would turn every covered call into a false `call.undefined-method`
at `evidence_tier: high`), a `libraries:` name RBS does not recognise, a
`disable:` / `severity_overrides:` id naming no real rule, or a missing
`bundler` / `rbs_collection` path. **Each warning here is a real
misconfiguration — fix it.** None appearing is the healthy state.

## 2. Every configured plugin loads

```sh
rigor plugins --strict
```

Reports the activation status of each plugin in `plugins:`; `--strict`
exits non-zero on any failure. A failure is usually a misspelled id or a
plugin whose `signature_paths:` did not resolve. Fix it, or the plugin's
type knowledge is silently absent.

## 3. The baseline is not stale (if one exists)

```sh
rigor baseline drift
```

Shows whether the live diagnostics have drifted from `.rigor-baseline.yml`
— entries the baseline ignores that no longer occur (safe to prune) and
new diagnostics outside the envelope. A large drift means the baseline
needs regenerating (often after an upgrade — see `rigor-upgrade`).

## 4. The analysis is actually seeing your code

```sh
rigor check --format json   # check the "Ruby source files" count
```

If the file count is `0` or far below your project size, `paths:` /
`exclude:` are mis-scoped, or the command is running from the wrong
directory. The analysis is only as good as the files it reads.
