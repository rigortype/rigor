# ADR-81 — Skill-set optimization: per-skill freshness + the `waza` evaluation stance

Status: **Accepted — implemented 2026-07-05.** Two standing decisions about how the user-facing `skills/` set is optimized and maintained: (1) the ADR-73 WD1 freshness criterion is generalized from the entry point to *every* skill body, realized by a "First: load the version-current copy" directive + a new `rigor skill --full <name>`; (2) a policy on which `waza` (the bundled skill evaluator) advisories are acted on. The mechanism detail for (1) lives in the [ADR-73](73-skill-driven-user-experience.md) amendment of the same date; this ADR records the reusable *criteria* and the evaluation stance.

Grounding: the [ADR-73](73-skill-driven-user-experience.md) 2026-07-05 amendment; `CLAUDE.md` § "Evaluating skills with `waza`"; [ADR-74](74-offline-doc-access-and-llms-txt.md) (`rigor docs`); [ADR-50](50-release-engineering-and-stability-strategy.md) WD1 (v1.0 vocabulary freeze).

## Context

The user-facing skills under `skills/` ship through two channels that read one source file each: the gem (served fresh by `rigor skill`) and vercel-labs/skills (`npx skills add`, **frozen at install time**). ADR-73 kept only the entry point `rigor-next-steps` free of version-coupled logic; the other 14 skills froze their full procedures into their bodies, so a vendored copy — auto-triggered by an agent on its own `description:` — drifts from the installed binary (陳腐化). That is the problem this session set out to close.

Separately, `waza` (the bundled Agent-Skill evaluator) reports readiness advisories, but its defaults are calibrated for **agentskills.io publication** — a 500-token budget, a `**WORKFLOW SKILL**` / `USE FOR:` / `INVOKES:` labeled description format — which do not fit Rigor's deliberately comprehensive single-file skills. A running `waza check` sweep this session made the mismatch concrete (every skill "fails" the 500-token limit at 816–4267 tokens), so a standing decision was needed on which `waza` signals to trust.

## Decision

**Criterion 1 — freshness.** A distributed skill freezes only version-stable scaffold; version-coupled step detail is fetched live from the installed gem. This is ADR-73 WD1's freeze-only-pre-install rule applied to *every* skill body, not just the entry point. The load-bearing observation: because both channels read one `skills/<name>/SKILL.md`, freshness cannot come from thinning the file — it comes from a **directive that re-fetches** the current body from the gem (a frozen copy is stuck at install time; `rigor skill` always reads the gem, so the two diverge across upgrades and the directive resolves toward the installed version).

**Criterion 2 — evaluation.** A `waza` advisory is adopted only when it flags a defect **independent of the publication profile**. This filters the tool: keep the signals that catch real problems, discard the ones that merely penalize non-agentskills.io shape.

## Working decisions

- **WD1 — the directive + `rigor skill --full`.** Every non-entry skill carries a "First: load the version-current copy" section pointing at `rigor skill --full <name>` — a new mode that inlines the SKILL.md body followed by every `references/*.md`, returning the complete current procedure in one call (`SkillCommand#run_full`, [`lib/rigor/cli/skill_command.rb`](../../lib/rigor/cli/skill_command.rb)). One call, no path arithmetic, no file-reading tool required, and no risk of reading a frozen co-located `references/`.
- **WD2 — hybrid calibration.** Split volatile detail into `references/` **only where the body carries drifting exact commands / flags / config keys / rule ids**; otherwise the directive alone suffices (most skills already externalize detail to `references/` or delegate to `rigor docs`). `rigor-doctor` is the demonstrating aggressive split; `rigor-next-steps` stays a pure pre-install bootstrap.
- **WD3 — `waza` usage.** Adopt: **link health** (`waza check` caught 4 × `blob/main` HTTP-404 doc links in `rigor-ci-setup` where the default branch is `master`) and **over-specificity of hardcoded doc URLs** (prefer offline `rigor docs <chapter>`, which converges with Criterion 1). Reject: the **500-token budget** / "complexity: comprehensive" (our skills are intentionally comprehensive) and the **labeled description format** (our prose `Triggers: "…"` + `NOT for … (use X)` conveys the same and reads better — `waza` penalizing its absence is the publication bias, not a real gap). `waza dev --auto` stays banned per `CLAUDE.md` (it injects frequently-false `USE FOR:` / `INVOKES:` boilerplate).
- **WD4 — description length is a per-skill judgment.** `waza`'s cross-model-density advisory (≤60-word descriptions, lead with an action verb) is applied only to an over-broad catalogue entry, never as a blanket rule that would trade trigger recall — the skill-creator "pushy description" guidance still governs. Only `rigor-ask` (169 words) is a candidate for tightening.
- **WD5 — frozen vocabulary.** `rigor skill --full` and the directive's presence become public surface frozen at v1.0 under ADR-50 WD1, alongside the existing `rigor skill` grammar.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| Thin the frozen bodies without a re-fetch directive | Rejected | Both channels read one file — thinning thins both; freshness comes from the directive, not from the file being short. |
| Adopt `waza`'s labeled `USE FOR:` / `INVOKES:` format + 500-token target | Rejected | Publication-calibrated; optimizes for the linter, not the reader. Our prose already carries triggers + anti-triggers with routing. |
| Drop vercel-labs distribution of the non-entry skills (serve gem-only) | Deferred | Reverses ADR-73 WD5's whole-set install; the directive mitigates the frozen-copy case without removing the channel. |
| Blanket ≤60-word descriptions | Rejected | Trades trigger recall for cross-model crispness; only the over-broad catch-all is trimmed. |
| Delegate `rigor-ci-setup`'s inline CI templates to `rigor docs ci` | Deferred | The templates duplicate the manual chapter; a full delegation is a larger, parity-checked refactor — queued follow-up. |

## Consequences

- **Positive.** Onboarding practices stay current to the installed version without re-publishing a single skill; `rigor skill --full` gives an agent the complete fresh procedure in one call; a cheap `waza check` link-lint catches broken doc URLs a human diff misses.
- **Carry-over.** `rigor skill --full` is frozen at v1.0 (ADR-50 WD1). `rigor-ci-setup` still duplicates the manual (deferred above). Out of scope but flagged: the gemspec `documentation_uri` uses `…/tree/main/docs`, likely a 404 (default branch is `master`).

## Relationship to other ADRs

- **[ADR-73](73-skill-driven-user-experience.md)** — the SKILL-driven UX + the freshness *mechanism*; Criterion 1 here generalizes its WD1, and the 2026-07-05 amendment holds the per-skill implementation detail.
- **[ADR-74](74-offline-doc-access-and-llms-txt.md)** — `rigor docs` is the offline, version-matched target the over-specificity fix (WD3) routes hardcoded URLs to.
- **[ADR-50](50-release-engineering-and-stability-strategy.md)** — freezes `rigor skill --full` as public vocabulary at v1.0 (WD5).
- **[ADR-49](49-adr-authoring-guidelines.md)** — this ADR's own quality bar (mechanical-policy archetype, low–mid stakes → economy-weighted).
