---
description: Bind reviewer role — adversarial review; Approved or Needs fix
argument-hint: "[PR URL]"
---
You are running as **reviewer** (Fable / Opus/Grok-class; not Gemini-tier).

1. Load and follow skill `/skill:rigor-reviewer`.
2. Review: ${@:-the draft PR / diff named by the user}.
3. Prefer counterexamples over trusting green CI alone when behaviour is claimed.
4. Report in the fixed shape of
   [`rigor-reviewer`](../../../.claude/skills/rigor-reviewer/SKILL.md) § Report, read from
   `origin/master`: severity counts, the head SHA, and a repro per finding.
5. Then end with exactly `Approved` (only with `Severe remaining: no`) or `Needs fix`.
