---
name: rigor-upgrade
description: >-
  Adopt a new `rigortype` version by comparing its diagnostics with the committed baseline and separating
  new catches from signature-quality false positives. Use after a Rigor gem upgrade; not for first-time
  setup or routine baseline reduction.
license: MPL-2.0
metadata:
  version: 0.1.0
  homepage: https://github.com/rigortype/rigor
---

# Rigor Upgrade

A new Rigor release sharpens inference and may add or tighten rules, so
`rigor check` can report diagnostics it did not before — most are the new
version catching more, a few are sig-quality false positives the new
sharpness exposes. This skill adopts the upgrade without either blindly
regenerating the baseline (which buries genuine new catches) or treating
every new line as a regression.

## First: load the version-current copy

This skill's exact commands, flags, and config keys drift between Rigor
releases, so follow the copy that ships with the **installed** Rigor rather
than any vendored or frozen copy of this file — doubly so here, since you
just changed the version this skill is meant to track. Get the complete
current procedure in one call:

```sh
rigor skill --full rigor-upgrade
```

If you already loaded this skill *via* `rigor skill` you have the current
copy — just proceed. If `rigor` is not on `PATH`, this task needs it: run
**`rigor-next-steps`** to install Rigor first, then come back.

## When to use

- You just ran `mise use gem:rigortype` / `gem update rigortype` and want
  to understand what the new version changed about your project's
  diagnostics.

## Procedure

### Phase 1 — confirm the new version

```sh
rigor --version
```

### Phase 2 — see the delta against the committed baseline

```sh
rigor check             # everything outside the committed baseline's envelope
rigor baseline drift    # per-bucket movement against .rigor-baseline.yml
```

With `baseline:` wired, `rigor check` already hides what the baseline
covers, so what it prints is **new** relative to the baseline — that set
is what the upgrade changed. `rigor baseline drift` adds the bucket view:
buckets now over their recorded count, and buckets the new version
cleared or shrank.

### Phase 3 — sort the new diagnostics

For each newly-surfaced diagnostic:

- **A genuine new catch** — the sharper inference found a real latent
  issue. Fix it. (Check `evidence_tier` in `rigor check --format json`:
  `high` is most likely a true positive.)
- **A sig-quality false positive** — a known class (Struct
  `call.wrong-arity`, an over-nilable RBS return, a regex-capture `$1`
  read). `# rigor:disable <rule>` the site with a reason, or address the
  RBS. Read `rigor explain <rule>` if unsure whether the rule should fire
  here.
- **Expected envelope growth** — broadly acceptable in acknowledge mode.

### Phase 4 — regenerate the baseline (acknowledge mode)

Once you have triaged and fixed the genuine catches, record the new
envelope so the regeneration does not bury what you just fixed:

```sh
rigor baseline regenerate
```

Recommend committing the updated `.rigor-baseline.yml` together with any
fixes, so the team adopts the same post-upgrade baseline.

## Note

`rigor skill describe` cannot detect that you just upgraded — the
baseline records only its schema version, not the Rigor version that
generated it — so this skill is invoked on demand rather than
recommended automatically. Run it whenever you bump the gem.

## Next step

Re-run `rigor skill describe` for the next move.
