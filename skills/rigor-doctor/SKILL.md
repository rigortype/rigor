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
goes a level deeper: it *runs* Rigor's own validators to confirm the setup
is actually working — the difference between "a `.rigor.yml` is present"
and "it parses, loads its plugins, and analyses the right files." Reach for
it when the diagnostics look wrong (suspiciously zero, or suspiciously
many) or after editing the config. It needs no special command — it
orchestrates checks Rigor already ships and interprets the results.

## First: load the version-current copy

This skill's exact commands, flags, and config keys drift between Rigor
releases, so follow the copy that ships with the **installed** Rigor rather
than any vendored or frozen copy of this file. Get the complete current
procedure in one call:

```sh
rigor skill --full rigor-doctor   # this body + all its references/, inline
```

If you already loaded this skill *via* `rigor skill` you have the current
copy — just proceed (read any `references/NN-*.md` from the directory the
header names). If `rigor` is not on `PATH`, this task needs it: run
**`rigor-next-steps`** to install Rigor first, then come back.

## When to use

- After editing `.rigor.yml` / `.rigor.dist.yml`.
- When `rigor check` reports suspiciously few or suspiciously many
  diagnostics, or the config feels like it isn't taking effect.
- NOT for first-time setup (→ `rigor-project-init`) or working real
  diagnostics down (→ `rigor-baseline-reduce`).

## What it validates

Four validators, each a check Rigor already ships. The exact commands and
how to read each output live in the version-current
[`references/01-checks.md`](references/01-checks.md) (loaded per the
directive above):

1. **Config resolves with nothing silently inert** — no `config_warnings`.
2. **Every configured plugin loads** — `rigor plugins --strict` is clean.
3. **The baseline is not stale** (if one exists) — no large drift.
4. **The analysis is actually seeing your code** — the source-file count
   matches the project.

## Interpreting the result

- **All clean** → the setup is healthy; any diagnostics are about the
  code, not the configuration. Move on to `rigor-baseline-reduce` or
  `rigor-protection-uplift`.
- **A `config_warning` or a plugin failure** → that is the real problem;
  fixing it usually clears a whole cluster of confusing downstream
  diagnostics at once.

For deeper symptoms (hover shows `untyped` everywhere, completion empty,
LSP silent) read the manual's troubleshooting chapter — offline and
version-matched:

```sh
rigor docs troubleshooting
```

## Next step

Re-run `rigor skill describe` for the recommended next move.
