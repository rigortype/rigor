---
name: rigor-upgrade
description: |
  Adopt a new Rigor version cleanly: after upgrading the `rigortype` gem, re-run the analysis, diff the diagnostics against the committed baseline, and sort the changes into genuine new catches (sharper inference), known sig-quality false positives, and the baseline you should regenerate. Triggers: "I upgraded Rigor, what changed?", "new diagnostics after gem update rigortype", "adopt the new Rigor version", "rigor baseline drifted after upgrade". NOT for first-time setup (use rigor-project-init) or routine baseline work unrelated to an upgrade (use rigor-baseline-reduce).
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
rigor check
rigor diff            # compare current diagnostics to the saved baseline JSON
```

`rigor diff` shows what is **new** relative to the baseline — that set is
what the upgrade changed.

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

Commit the updated `.rigor-baseline.yml` together with any fixes, so the
team adopts the same post-upgrade baseline.

## Note

`rigor skill describe` cannot detect that you just upgraded — the
baseline records only its schema version, not the Rigor version that
generated it — so this skill is invoked on demand rather than
recommended automatically. Run it whenever you bump the gem.

## Next step

Re-run `rigor skill describe` for the next move.
