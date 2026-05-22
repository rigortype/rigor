---
name: rigor-baseline-reduce
description: |
  Work a Rigor project's `.rigor-baseline.yml` down rule by rule: prioritise with `rigor triage`, sample call sites, classify each as real bug / stylistic-safe / false positive, then fix, `# rigor:disable`, or open a Rigor issue — and regenerate the baseline. Triggers: "reduce the rigor baseline", "fix some baseline diagnostics", "what rigor issue should I fix next?". NOT for first-time setup (use rigor-project-init) or authoring a plugin (use rigor-plugin-author).
license: MPL-2.0
metadata:
  version: 0.1.0
  homepage: https://github.com/rigortype/rigor
---

# Rigor Baseline Reduce

Opportunistic, session-bounded quality improvement for a project
that already has a `.rigor-baseline.yml`. Each session picks a rule,
walks its sites, and lands a mix of fixes, intentional suppressions,
and issue reports — then refreshes the baseline so the gains stick.

This skill is for **users improving their own project**. It uses the
published `rigor` executable on `PATH` and references only public CLI
flags and config keys.

## Phase 0 — When to use this skill

Trigger when the user says "reduce the rigor baseline", "fix some
baseline diagnostics", "what should I fix next in rigor?", or asks to
work down the diagnostics a previous onboarding parenthesised.

**Precondition: the project is in acknowledge mode.** This skill
operates on a `.rigor-baseline.yml` that `.rigor.yml` /
`.rigor.dist.yml` declares via `baseline:`. A strict-mode project
(`severity_profile: strict`, no baseline) has nothing for this skill
to reduce — its diagnostics are already all live; fix them as
ordinary `rigor check` output. If no baseline exists, the user wants
`rigor-project-init`, not this skill.

Do NOT trigger for:

- **First-time onboarding** — no `.rigor.yml` yet → `rigor-project-init`.
- **Writing a plugin** for the project's DSL → `rigor-plugin-author`.

## What baseline reduction is

`.rigor-baseline.yml` records `(file, rule, count)` buckets — the
diagnostics that existed when the project adopted Rigor. They are
suppressed while their count holds. Reduction means: go through them
deliberately, decide what each one really is, and shrink the file.
Three outcomes per site:

- **Real bug** — Rigor caught a genuine defect. Fix the code.
- **Stylistic / safe** — the static reading is worst-case-sound but
  the site is fine in practice (an idiom the analyzer's narrowing
  doesn't follow, a slot the project always initialises). Mark it
  `# rigor:disable <rule>` with intent.
- **False positive** — Rigor is wrong; the rule should narrow
  further. Leave it baselined and open a Rigor issue.

Shrinking the baseline is progress whichever outcome applies — the
file gets smaller, and "reduce the baseline by N this sprint" is a
trackable goal.

## Phase outline

| Phase | What | Reference |
| --- | --- | --- |
| 1 | Prioritise — `rigor triage --format json` + `rigor baseline dump` pick the rule to work. | [`references/01-classify.md`](references/01-classify.md) |
| 2 | Per rule: sample 3–5 sites, classify each (real bug / stylistic / FP). | [`references/01-classify.md`](references/01-classify.md) |
| 3 | Act — fix, `# rigor:disable`, or open a Rigor issue. | [`references/02-fix-or-suppress.md`](references/02-fix-or-suppress.md) |
| 4 | Refresh — `rigor baseline drift`, then `rigor baseline regenerate`. | [`references/02-fix-or-suppress.md`](references/02-fix-or-suppress.md) |

Phases 2–4 repeat per rule until a stop condition (below) fires.

## Reading order — modules

| Module | Read | Covers |
| --- | --- | --- |
| 1 | [`references/01-classify.md`](references/01-classify.md) | **Phases 1–2.** Priority order from the `rigor triage` hints + ascending bucket count. The sample-and-classify protocol; the three-way real-bug / stylistic / FP triage and how to tell them apart. |
| 2 | [`references/02-fix-or-suppress.md`](references/02-fix-or-suppress.md) | **Phases 3–4.** Acting on each classification — fix patterns, `# rigor:disable` placement (per-line vs per-file), FP escalation as a Rigor GitHub issue. Refreshing the baseline with `drift` + `regenerate`. |

## Stop conditions

End the session — do not grind indefinitely — when any of these hit:

- The user signals halt.
- The next rule's site count exceeds the session budget (default:
  ~20 sites). A 200-site rule is systemic; escalate it as a decision
  (below), do not walk it site by site.
- A wall-time budget is reached (default: ~60 minutes).

Always finish with Phase 4 (refresh the baseline) before stopping, so
the landed work is recorded.

## Decision points to escalate to the user

- "This rule has 200 sites across 14 files — it looks systemic. A
  plugin or an engine fix would clear them in bulk; want me to
  investigate that instead of walking sites one by one?"
- "This file's diagnostics would be cleaner under one per-file
  `# rigor:disable-file <rule>` than 30 per-line comments — switch?"
- "The diagnostic wording changed between Rigor versions and the
  baseline no longer matches cleanly — regenerate now?"
