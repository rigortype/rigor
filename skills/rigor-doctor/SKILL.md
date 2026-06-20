---
name: rigor-doctor
description: |
  Validate that a project's Rigor setup is actually healthy — config parses with no silently-inert values, every configured plugin loads, the baseline is not stale, and the bundled paths resolve — by running Rigor's existing validators and interpreting them. Triggers: "is my Rigor setup correct?", "check my rigor config", "rigor diagnostics look wrong / suspicious", "validate rigor setup", "why is rigor reporting nothing / everything?". NOT for first-time setup (use rigor-project-init) or for working real diagnostics down (use rigor-baseline-reduce).
license: MPL-2.0
metadata:
  version: 0.1.0
  homepage: https://github.com/rigortype/rigor
---

# Rigor Doctor

`rigor skill describe` reports what *exists* (presence checks). This skill
goes a level deeper: it *runs* Rigor's validators to confirm the setup is
actually working — the difference between "a `.rigor.yml` is present" and
"it parses, loads its plugins, and analyses the right files." Use it when
the diagnostics look wrong (suspiciously zero, or suspiciously many) or
after editing the config.

It needs **no special command** — it orchestrates checks Rigor already
ships and interprets the results.

## Checks

### 1. Config resolves with nothing silently inert

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

### 2. Every configured plugin loads

```sh
rigor plugins --strict
```

Reports the activation status of each plugin in `plugins:`; `--strict`
exits non-zero on any failure. A failure is usually a misspelled id or a
plugin whose `signature_paths:` did not resolve. Fix it, or the plugin's
type knowledge is silently absent.

### 3. The baseline is not stale (if one exists)

```sh
rigor baseline drift
```

Shows whether the live diagnostics have drifted from `.rigor-baseline.yml`
— entries the baseline ignores that no longer occur (safe to prune) and
new diagnostics outside the envelope. A large drift means the baseline
needs regenerating (often after an upgrade — see `rigor-upgrade`).

### 4. The analysis is actually seeing your code

```sh
rigor check --format json   # check the "Ruby source files" count
```

If the file count is `0` or far below your project size, `paths:` /
`exclude:` are mis-scoped, or the command is running from the wrong
directory. The analysis is only as good as the files it reads.

## Interpreting the result

- **All clean** → the setup is healthy; any diagnostics are about the
  code, not the configuration. Move on to `rigor-baseline-reduce` or
  `rigor-protection-uplift`.
- **A `config_warning` or a plugin failure** → that is the real problem;
  fixing it usually resolves a whole cluster of confusing downstream
  diagnostics at once.

For deeper symptoms (hover shows `untyped` everywhere, completion empty,
LSP silent) see the manual's troubleshooting:
<https://github.com/rigortype/rigor/blob/master/docs/manual/13-troubleshooting.md>

## Next step

Re-run `rigor skill describe` for the recommended next move.
