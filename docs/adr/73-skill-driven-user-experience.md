# ADR-73 — SKILL-driven Rigor user experience (the `rigor-next-steps` entry point + live `rigor skill --describe`)

Status: **Accepted — WD1–WD5 implemented 2026-06-20; thin-shell/live-core split generalized to every skill + `rigor skill --full` added 2026-07-05 (see Amendment).** Establishes a single SKILL-driven entry point — `rigor-next-steps` — for "what should we do next with Rigor on this project," backed by a live, version-current `rigor skill --describe` so the distributed guidance never goes stale. Promotes the parked `rigor-protection-uplift` skill into the shipped set and settles where the user-facing SKILLs are distributed (vercel-labs/skills + the bundled gem). The `describe` catalogue is designed to **grow** (see "Extending the catalogue"); a first wave of seven additions — `rigor-rbs-setup`, `rigor-editor-setup`, `rigor-mcp-setup`, `rigor-monkeypatch-resolve`, `rigor-plugin-tune`, `rigor-upgrade`, `rigor-doctor` — landed the same day.

**Amendment (2026-07-05) — the thin-shell / live-core split, generalized to every skill.** WD1's distribution criterion — *freeze into a distributed SKILL only what must run before `rigor` exists; serve everything version-coupled live from the gem* — was originally realized only for the entry point `rigor-next-steps`. The other user-facing skills still froze their full procedures into their SKILL.md bodies, so a copy vendored via `npx skills add` (the whole-set install of WD5) drifts from the installed gem: a stale `.claude/skills/<name>/SKILL.md` is auto-triggered by the agent on its own `description:`, and it then follows last-quarter's flags / config, not the binary's. This amendment applies the split to **every** skill's body.

- Each skill carries a **"First: load the version-current copy"** directive that re-points the reader at the copy shipped with the *installed* Rigor. The load-bearing mechanism is that both channels read one `skills/<name>/SKILL.md`, so freshness cannot come from thinning alone — it comes from the directive making the agent re-fetch from the gem. A vendored copy is frozen at install time while `rigor skill` always reads the gem, so the two diverge across upgrades and the directive resolves in favour of the gem.
- A new **`rigor skill --full <name>`** mode inlines the SKILL.md body followed by every `references/*.md`, returning the complete, version-current procedure in one call — no path arithmetic, works without a file-reading tool, and removes the foot-gun of reading a frozen co-located `references/`. The directives point here.
- **Calibration (hybrid).** Version-coupled step detail belongs in `references/` (served fresh by `--full`); the SKILL.md body keeps only the stable scaffold (goal, when-to-use, phase names, decision points). Skills that already externalized their detail (`rigor-project-init`, `rigor-plugin-author`, `rigor-plugin-review`, `rigor-baseline-reduce`) or already delegate config to `rigor docs` (`rigor-editor-setup`, `rigor-mcp-setup`) took the directive alone; `rigor-doctor` had its inline checks moved into `references/01-checks.md` as the demonstrating aggressive split. `rigor-ci-setup`'s inline CI templates overlap the manual chapter, so its References now lead with the offline `rigor docs ci`; a deeper delegation of its templates to the manual is a queued follow-up. `rigor-ask` keeps its tables as orientation but now leads with "confirm against the live `rigor docs --list` / `rigor --help`". `rigor-next-steps` is unchanged — it is the one skill that must run before `rigor` exists, so it stays a pure install bootstrap.

`rigor skill --full` joins the frozen public vocabulary at v1.0 under [ADR-50](50-release-engineering-and-stability-strategy.md) WD1, alongside the existing `rigor skill` surface.

**Amendment (2026-06-21) — `rigor skill` flag grammar.** Aligning with the [ADR-74](74-offline-doc-access-and-llms-txt.md) `rigor docs` change, `rigor skill`'s discovery verbs moved to flags: `rigor skill <name>` (bare = print the body), `rigor skill --list`, `rigor skill --path <name>`. The `describe` action is **unchanged** — both `rigor skill describe` and `rigor skill --describe` stay first-class (it is a no-argument action, not a name-slot verb), as does the top-level `rigor describe` alias. The legacy `list` / `print <name>` / `path <name>` verbs still work but emit a one-line stderr deprecation notice and are **removed in v0.3.0** (see [ROADMAP](../ROADMAP.md) § "Scheduled CLI deprecations"). The bundled generators — `rigor skill --describe`'s catalogue + recommendation output, the `rigor-next-steps` SKILL, and the CI-detection hint — now emit only the canonical `rigor skill <name>` form, so the SKILL-driven UX never triggers its own deprecation notice.

Grounding: the existing `rigor skill` command ([`lib/rigor/cli/skill_command.rb`](../../lib/rigor/cli/skill_command.rb), shipped v0.1.13 per [ADR-22](22-baseline-and-project-onboarding.md) WD8), the parked act-on-coverage skeleton ([`docs/design/20260616-act-on-coverage-skill.md`](../design/20260616-act-on-coverage-skill.md), [ADR-63](63-type-protection-coverage.md) WD5, pilot-validated), and [`docs/install.md`](../install.md)'s agent-facing install flow.

## Context

Rigor ships a small set of Agent Skills under `skills/` — `rigor-project-init`, `rigor-baseline-reduce`, `rigor-ci-setup`, `rigor-plugin-author` — and serves them, once installed, via `rigor skill list/print/path` (`SkillCommand`, `SKILLS_ROOT = <gem_root>/skills`). Three gaps keep this from being a usable, self-serve experience:

1. **No single entry point.** A user (or their coding agent) who knows nothing about Rigor has no "start here." `docs/install.md` hard-codes one destination — it always hands off to `rigor-project-init` (Step 4) — and the other skills are invisible until the user already knows their names.
2. **The guidance goes stale (陳腐化).** Any "what to do next" advice baked into a *distributed* SKILL is frozen at publish time. As Rigor grows skills and sharpens its recommendations, a copy installed into a user's repo months ago silently rots — the exact failure the maintainer flagged.
3. **No public distribution channel for the SKILLs themselves.** They ride inside the `rigortype` gem, so an agent can reach them only *after* Ruby + the gem are installed. There is no way to drop the "start here" skill into a project that has not adopted Rigor yet — which is precisely where onboarding begins.

The standing value at stake is **self-serve onboarding** (ROADMAP § "Onboarding self-serve"): a user should be able to point any coding agent at their repo and have it drive Rigor adoption end to end, with advice that is current to the installed version.

## Decision

Split the experience into a **thin, distributable SKILL** and a **live, gem-resident brain**, divided by one rule:

> **Distribution criterion.** A piece of guidance is frozen into the distributed SKILL *only if it must run before `rigor` exists* (resolving the command, installing it). Everything that changes as Rigor evolves — the catalog of downstream skills, their descriptions, and the project-state → next-step recommendation — is emitted **live** by `rigor skill --describe` and is never copied into the SKILL.

Concretely:

- **`rigor-next-steps`** is the new entry-point SKILL (gem-bundled *and* vercel-labs/skills-installable). It carries only the bootstrap chain the chicken-and-egg forces into the SKILL, then delegates all routing to `rigor skill --describe`.
- **`rigor skill --describe`** is the live brain: a cheap project-state probe → a recommended next skill → the catalog of downstream skills with their *current* frontmatter descriptions → an agent action-prompt. It ships and updates with the gem, so the routing intelligence is always version-current.

### WD1 — The thin-wrapper / live-brain split (the load-bearing rule)

`rigor-next-steps`'s body is the five-step bootstrap chain the maintainer specified, and nothing version-coupled:

1. Resolve `rigor` on PATH (`which rigor` / `rigor --version`).
2. If absent → follow [`docs/install.md`](../install.md) (the SKILL points at the raw GitHub URL — see WD3 for why this one step cannot be `--describe`-driven).
3. If the project has no Rigor config (`.rigor.yml` / `.rigor.dist.yml`) → run `rigor skill print rigor-project-init` and follow it.
4. Otherwise → run `rigor skill --describe` and route on its output: present its recommended next step, or ask the user "what would you like to do next?" and `rigor skill print <name>` the choice.
5. Ideally, present the `--describe` recommendation proactively ("you should use `<skill>` to do X") rather than only asking.

Steps 1–2 (and the presence checks in 3) are the *only* logic that may live in the distributed SKILL, because they must execute when `rigor` — and therefore `rigor skill --describe` — is unavailable. Steps 3b–5 are intentionally *delegations*, not embedded logic.

### WD2 — `rigor skill --describe` contract

A new mode on `SkillCommand` (a `describe` subcommand, plus the `--describe` flag spelling the maintainer requested; `run` in `lib/rigor/cli/skill_command.rb` dispatches it alongside `list` / `print` / `path`). It emits, to stdout, for a calling agent:

- **Project state** — presence-only probes of the cwd: config (`.rigor.yml` / `.rigor.dist.yml`), baseline (`.rigor-baseline.yml`), `sig/`, CI wiring (`.github/workflows/*`, `.gitlab-ci.yml`). **It never runs `rigor check`** — the recommendation needs only presence signals, and a full analysis is the *downstream* skill's job.
- **A recommended next step** — a small decision tree over those signals (no config → `rigor-project-init`; config + no CI → `rigor-ci-setup`; config + baseline → `rigor-baseline-reduce`; protection goal → `rigor-protection-uplift`; unresolved project DSL → `rigor-plugin-author`).
- **The catalog** — every bundled skill with its frontmatter `description` (so the text is always current; `discover_skills` is extended to parse the YAML frontmatter) and the `rigor skill print <name>` to load it.
- **An agent action-prompt** — the closing instruction that turns the report into action (the same `# `-prefixed-header convention `print` already uses, so the combined output stays markdown-parseable).

Guardrail: `--describe` is **read-only and side-effect-free** — it touches no project files beyond stat-ing for presence, so an agent may run it freely at any point.

### WD3 — `rigor-next-steps`'s install branch points at `docs/install.md`; install.md defers back

The install step (WD1 step 2) is the one branch that cannot be `--describe`-driven — if `rigor` is not installed there is no binary to ask. So `rigor-next-steps` embeds a pointer to the raw `docs/install.md` URL (install mechanics change rarely; this is the minimal stale-able surface, accepted by necessity). Conversely, `docs/install.md` Step 4 — which today always hands off to `rigor-project-init` — is rewritten to defer to the same `rigor skill --describe` routing, so `install.md` and `rigor-next-steps` cannot diverge on "what comes after install."

### WD4 — Promote `rigor-protection-uplift` into the shipped set

The parked act-on-coverage skeleton ([`docs/design/20260616-act-on-coverage-skill.md`](../design/20260616-act-on-coverage-skill.md), ADR-63 WD5 — pilot-validated at +4.7pp mean protection / zero diagnostic regressions across 5 OSS repos) graduates to `skills/rigor-protection-uplift/SKILL.md` with sibling frontmatter (`license`, `metadata`). This settles the open packaging question the design doc deferred to "ADR-31's v0.2.0 external-author path": the answer is the same dual channel as every other user-facing skill (WD5) — there is no separate external-author artifact to build. The pilot record stays in the design note as grounding.

### WD5 — Distribution hygiene: two channels, contributor skills hidden

- **Two channels, one source.** The user-facing skills are distributed (a) via **vercel-labs/skills** — `npx skills add rigortype/rigor` (or per-skill, with `rigor-next-steps` as the documented entry), which discovers `skills/<name>/SKILL.md` straight from the repo and works *before* the gem is installed — and (b) **bundled in the `rigortype` gem**, served by `rigor skill` after install. Both read the same `skills/` tree; no second gem or repo (consistent with [ADR-31](31-contribution-and-supply-chain-policy.md)'s single-gem decision and the gemspec's existing `skills/*/SKILL.md` glob, which auto-includes the two new dirs).
- **Hide contributor workflows.** vercel-labs/skills also discovers `.claude/skills/` — Rigor's *contributor* workflows (release-prep, ADR-author, …). Each gets `metadata.internal: true` so a bulk `npx skills add rigortype/rigor` does not ship release tooling to end users.
- **`skills/README.md`** documents both channels, the `rigor skill --describe` entry, and the contributor/user split.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| Embed the routing + recommendation logic in the distributed `rigor-next-steps` SKILL | Rejected | Freezes version-coupled advice at publish time → the staleness this ADR exists to prevent. The whole split is to keep that logic in the gem. |
| `rigor skill --describe` runs `rigor check` / `coverage` to recommend | Rejected | Slow and side-effectful for a routing hint that needs only presence signals; the deep analysis belongs to the downstream skill the recommendation routes to. |
| Make the entry point a `rigor` subcommand instead of a SKILL | Rejected | The entry point must work *before* `rigor` is installed (the install branch). A binary subcommand cannot bootstrap its own absence; a distributable SKILL can. |
| A separate `rigor-skills` gem / git repo for the SKILLs | Rejected | The skills already ride in `rigortype`, and vercel-labs/skills installs from the same repo — a second artifact duplicates the source for no gain (ADR-31 single-gem). |
| Leave `.claude/skills/` discoverable by vercel-labs/skills | Rejected | Bulk install would ship contributor-only workflows (release, ADR authoring) to end users. `metadata.internal: true` is the tool's sanctioned hide. |
| Keep `rigor-protection-uplift` parked until a v0.2.0 external-author path is built | Superseded | This ADR *is* that decision — the external-author path is the existing dual channel; no further packaging work blocks promotion. |

## Consequences

Positive:

- One "start here" for any agent, and a recommendation that stays current to the installed Rigor — onboarding advice can sharpen every release without re-publishing a single SKILL.
- The SKILLs become genuinely installable (vercel-labs/skills) into projects that have not adopted Rigor yet, closing the pre-install discoverability gap.
- `rigor-protection-uplift` finally ships; the completeness-raising loop is reachable from the entry point.

Negative / carry-over:

- The raw `docs/install.md` URL inside `rigor-next-steps` (WD3) is a small stale-able surface — accepted because install must precede the gem; mitigated by keeping it a pointer, not a copy.
- `rigor skill --describe`'s output text + the new skill names become **public vocabulary frozen at v1.0 under [ADR-50](50-release-engineering-and-stability-strategy.md) WD1** — the recommendation *logic* stays free to evolve, but the command name and the skill ids are a compatibility commitment once 1.0 ships.
- The state → skill decision tree (WD2) is a heuristic; as the skill set grows it will need tuning. It is deliberately small and additive — a wrong recommendation costs a redundant suggestion, never a false diagnostic (it is outside the FP envelope entirely).

## Extending the catalogue — additional mechanical, describe-routed skills

The `describe` decision tree (WD2) and catalogue are deliberately
**open**: most of Rigor's adoption-and-operation journey is mechanical
work an agent can drive over the *existing* CLI, and each such workflow
becomes a new skill plus one branch in the decision tree. Because the
routing logic lives in the gem (WD1), adding a destination sharpens
`describe` for every installed copy without touching the distributed
`rigor-next-steps`.

A candidate qualifies when it (a) is drivable from existing CLI (or a
small *additive* command), (b) routes on a **cheap presence-only
signal** so `describe` stays side-effect-free (WD2's guardrail), and
(c) lives outside the FP envelope — a wrong recommendation costs a
redundant suggestion, never a diagnostic.

| Skill | Routing signal (presence-only) | Built on | Status |
| --- | --- | --- | --- |
| `rigor-rbs-setup` | `Gemfile.lock` present ∧ no `rbs_collection.lock.yaml` (headline branch) | `rbs collection install` (auto-detected, see [`rbs_collection_discovery.rb`](../../lib/rigor/environment/rbs_collection_discovery.rb)) | **Landed 2026-06-20** |
| `rigor-editor-setup` | committed `.vscode/` without a `rigor` reference (headline branch; catalogue-only for user-local Neovim / Emacs / Helix configs) | `rigor lsp` ([ADR-19](19-language-server-packaging.md)), routing to the manual's editor chapter | **Landed 2026-06-20** |
| `rigor-mcp-setup` | committed `.mcp.json` / `.cursor/mcp.json` without a `rigor` reference (headline branch; catalogue-only for user-local client configs) | `rigor mcp` ([ADR-33](33-mcp-server.md)), routing to the manual's MCP chapter | **Landed 2026-06-20** |
| `rigor-monkeypatch-resolve` | catalogue-only — the signal needs a `triage` run, not a presence check | `pre_eval:` ([ADR-17](17-monkey-patch-pre-evaluation.md)) + `rigor triage` | **Landed 2026-06-20** |
| `rigor-plugin-tune` | catalogue-only — re-matching `Gemfile.lock` to the plugin catalogue is an on-demand pass, not a cheap presence signal | `rigor plugins --strict` + the bundled plugin catalogue | **Landed 2026-06-20** |
| `rigor-upgrade` | catalogue-only — the baseline records only a schema version, not the generating Rigor version, so the "older than installed" check is unavailable (a future baseline `generated_with:` field would let it earn a headline branch) | `rigor diff` / `rigor baseline regenerate` | **Landed 2026-06-20** |
| `rigor-doctor` | catalogue-only — it *runs* validators rather than reading a presence signal | `rigor check` config-audit (`config_warnings`) + `rigor plugins --strict` + `rigor baseline drift` (no new command needed) | **Landed 2026-06-20** |

`rigor-rbs-setup` sits **right after `rigor-project-init`** in the
journey order: community RBS removes the dominant `Dynamic` source (the
RBS-less external gem the protection-uplift "honest bounds" named as its
ceiling) before baseline or CI work, so doing it early avoids
re-baselining against a noisier diagnostic set later.

Not every destination earns a headline branch. The decision tree gates
the **linear correctness journey** on reliable project-file signals;
**DX / integration** skills (`rigor-editor-setup`, `rigor-mcp-setup`)
are *catalogue-first* — they are listed for the agent
to offer via the "what would you like to do?" path, and fire a headline
recommendation only on a strong, repo-visible signal (a committed
`.vscode/` without `rigor`), because their real config is user-local and
not detectable. The same holds for **maintenance / validation** skills
(`rigor-plugin-tune`, `rigor-upgrade`, `rigor-doctor`,
`rigor-monkeypatch-resolve`): their trigger is an *event* (a new gem, a
version bump) or a *run-time check* (a `triage` / validator pass), not a
file the probe can stat, so they are catalogue entries the agent offers
when the user's goal or the diagnostics call for them. A skill that
cannot expose a reliable presence signal is a catalogue entry, never a
forced recommendation.

## Field-trial follow-ups (2026-06-20)

The first real-project exercise of this UX — conference-app (Rails 8.1) +
a 6-project rigor-survey Sonnet sweep, recorded in
[`docs/notes/20260620-skill-driven-onboarding-dogfood.md`](../notes/20260620-skill-driven-onboarding-dogfood.md)
— confirmed the design (the presence probe was accurate 7/7, the routing
advanced, `coverage --protection` was the most-praised surface) and
surfaced a set of UX fixes.

**Landed from the trial** (engine/CLI UX, no WD change): the `target_ruby`
diagnostic now names the supported floor + where to read the right value;
the convenience-meta-gem (`rigor-rails`) load error is actionable; `rigor
check` warn-and-skips a missing path among valid ones; `rigor describe` is
a top-level alias; and **WD2's `describe` agent-prompt now teaches
check-aware routing** — the recommendation stays presence-only, but the
"For the agent" section tells the agent to refine the choice from the
`rigor check` findings it already has (errors → `rigor-baseline-reduce`,
a monkey-patch cluster → `rigor-monkeypatch-resolve`, Dynamic framework
calls with no plugins → `rigor-plugin-tune`, `RBS classes available: 0` /
a `configuration-error` → `rigor-doctor`). This is the trial's headline
finding addressed **without breaking WD2** — the intelligence lives where
the check result already is (the agent), not in a `describe` that runs
analysis.

**Open decisions** (recorded for ratification; the trial floated them):

- **Headline check-awareness (revisits WD2).** Should the *recommendation
  line itself* — not just the agent-prompt — factor in check results?
  Two WD2-preserving shapes: (a) read the existing `.rigor/` cache's last
  `check` result and route on its error clusters (no new analysis, still
  side-effect-free); (b) a `rigor skill describe --deep` opt-in that runs
  a scoped check first (default stays pure). Criterion if pursued: never
  make the *default* `describe` run `check`. **Deferred** — the landed
  agent-prompt routing may suffice; revisit if the headline itself proves
  to mislead in practice.
- **`rbs-setup` priority softening.** The trial found the `rbs-setup`
  headline over-recommended. **Landed 2026-06-20:** a configured Rails
  project with no Rails plugins enabled now recommends `rigor-plugin-tune`
  ahead of `rbs-setup` (presence-only — Rails in `Gemfile.lock` + no
  `rigor-rails-*` plugin in the config; the strap case). The remaining
  cases — deprioritise when the no-RBS gems are all `development`/`test`,
  and prefer `ci`/`baseline` on a configured project before a
  network-bound `rbs collection install` — need to know whether the
  untyped gems actually hurt *this* project's analysis, so they fold into
  the headline check-awareness work above rather than more presence
  heuristics.
- **Broken-`sig/` blind spot (clear-win, queued).** `describe` reports
  "sig/ present" even when the RBS env fails to build (a
  `DuplicatedDeclarationError` → `RBS classes available: 0` → hollow
  analysis; redmine). Queued: a `check`/`coverage` banner when the env is
  empty, and promoting `rigor-doctor` when structural issues are
  detectable. Does not revisit WD2 (it is a check-time surfacing, not a
  describe-time analysis).

## Relationship to other ADRs

- **[ADR-22](22-baseline-and-project-onboarding.md)** (baseline + project onboarding) — introduced the onboarding SKILL trio and the `rigor skill` command (WD8); this ADR puts an entry point in front of them and makes the routing live.
- **[ADR-27](27-tool-distribution-model.md)** (tool distribution model) — governs how `rigor` itself is distributed; this ADR adds the *SKILL* distribution channel (vercel-labs/skills) on top, without a second artifact.
- **[ADR-31](31-contribution-and-supply-chain-policy.md)** (contribution + supply-chain) — the external-author path the protection-uplift skill was queued behind; WD4/WD5 resolve it to the existing dual channel.
- **[ADR-63](63-type-protection-coverage.md)** (type-protection coverage) — WD5's act-on-coverage layer; this ADR ships it as `rigor-protection-uplift` (WD4).
- **[ADR-19](19-language-server-packaging.md) / [ADR-33](33-mcp-server.md)** — sibling "new `rigor` subcommand packaging" ADRs; `rigor skill --describe` follows their CLI-surface pattern.
- **[ADR-50](50-release-engineering-and-stability-strategy.md)** (release engineering) — freezes the new CLI output + skill ids as public vocabulary at 1.0 (see Consequences).
