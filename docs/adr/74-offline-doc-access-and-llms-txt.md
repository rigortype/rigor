# ADR-74 — Offline doc access (`rigor docs`) + `llms.txt` linkage

Status: **Accepted — WD1–WD4 implemented 2026-06-20.** Completes the [ADR-73](73-skill-driven-user-experience.md) SKILL-driven UX on the *documentation* axis: an installed Rigor serves the docs an agent needs **offline** (the `rigor docs` command over a gem-bundled `docs/manual`), and the project's agent doc-discovery index — `llms.txt` — both reflects the new skill surface and tells the agent it can read those docs locally without the network. WD1+WD2 (gem ships `docs/install.md` + `docs/llms.txt` + `docs/manual/**`; `rigor docs` command) and WD3 (skills prefer `rigor docs <chapter>`) landed on the rigor side; WD4 (site `llms.md` / `llms-ja.md` refreshed through `rigor-next-steps` + the offline note + chapter 17, build dead-link guard green) landed on the site repo.

**Amendment (2026-06-21) — flag grammar + handbook bundling.** The WD2 discovery verbs (`rigor docs list` / `path <name>`) moved to flags (`--list [category]` / `--path <name>`) so the positional slot is unambiguously a doc *name* (a page literally named `list`/`path` could otherwise be shadowed by the verb); the bare `rigor docs <name>` print form is unchanged. The legacy verb spellings still work but emit a one-line stderr deprecation notice and are **removed in v0.3.0** (see [ROADMAP](../ROADMAP.md) § "Scheduled CLI deprecations"). WD1's bundle widens from manual-only to **manual + handbook** (`docs/handbook/**/*.md` added to the gemspec) — the handbook is user-facing drive-Rigor concept material, so it satisfies the offline-doc criterion above; the contributor-facing ADR / spec / notes corpus still stays web-only. With two categories, `<name>` resolves a category-qualified path (`handbook/03-narrowing`), a prefixed basename (`03-narrowing`), or a short name when unique (a cross-category collision such as `plugins` errors with the qualified candidates), and `--list` takes an optional category filter. [ADR-73](73-skill-driven-user-experience.md) gets the parallel `rigor skill` grammar change. The frozen public vocabulary (ADR-50 WD1) is the amended flag surface.

**Follow-up (2026-06-21) — the `rigor-ask` skill.** ADR-73's catalogue gains `rigor-ask`, the agent-facing realization of this ADR: when a user asks anything about Rigor in plain language ("why did this fire?", "how does narrowing work?", "what does this flag do?"), the skill drives `rigor docs` (plus `rigor explain <rule>` for a diagnostic id) and answers from the bundled source — so the human never has to remember the `rigor docs` command, only the question. Paired with `rigor-next-steps` it gives users a two-skill mental model — *what next?* (`rigor-next-steps`) and *ask about Rigor* (`rigor-ask`) — with the other catalogue skills reached through them. Catalogue-only under ADR-73 (question-triggered, never presence-recommended), so it adds no new public CLI surface; it is a `skills/` addition wired into the `rigor skill describe` catalogue.

**Amendment (2026-06-21) — `rigor-ask` widened to the full question surface (docs *and* the user's code).** The skill grew from the three doc-lookup shapes above (a diagnostic / a type-model concept / a flag) to the whole range of questions users actually open with: how Rigor compares to other checkers (→ the handbook comparison appendices, `handbook/10-sorbet`); whether it handles a given framework or gem (→ `rigor plugins` + the per-plugin `rigor docs rigor-<gem>` pages); how to type a method or write an annotation (→ the RBS chapters + `rigor sig-gen`); and the "what is this / why adopt it over rubocop+tests / is it right for us" adoption questions (→ `handbook/01-getting-started`). The deeper change extends *this ADR's own thesis*: "answer from the source, never from memory" now covers the user's **own code**, not just the bundled manual — for a question about their program the skill runs the read-only analysis commands (`rigor check` / `annotate` / `type-of` / `triage` / `coverage`) and answers from what Rigor actually infers; and because the gem ships its full source (ADR-31), where no doc page spells a detail out the skill may read the bundled file directly rather than guess. When a question is really a task ("set up CI", "reduce the baseline"), the skill answers briefly and hands off to `rigor-next-steps` or the matching doing-skill instead of reimplementing the workflow inline — keeping the two-skill model intact. Still catalogue-only with no new CLI surface; the frozen `description` is held within the agentskills.io 1024-character cap (a `waza check` spec gate).

Grounding: [ADR-73](73-skill-driven-user-experience.md) (the SKILL-driven UX this extends), the deployed `https://rigor.typedduck.fail/llms.txt` (source `site/.../src/llms/llms.md`), and the 2026-06-20 onboarding field trial ([`docs/notes/20260620-skill-driven-onboarding-dogfood.md`](../notes/20260620-skill-driven-onboarding-dogfood.md)).

## Context

ADR-73 made the *skills* a local-first agent surface: they ride in the `rigortype` gem and `rigor skill print <name>` serves them with no network. But the **docs** those skills route to are not local. `rigor-editor-setup`, `rigor-mcp-setup`, and `rigor-next-steps` point at **GitHub raw URLs** (`docs/install.md`, `docs/manual/09-editor-integration.md`, …) because the gemspec ships `README` / `lib` / `sig` / `data` / `skills` but **not `docs/`**. So an agent with Rigor already installed still needs the network to read the editor / MCP / install guidance — exactly the kind of stale-able, network-coupled dependency the SKILL-driven design otherwise avoids.

Separately, the site already publishes an [`llms.txt`](https://llmstxt.org/) — the agent's doc-discovery index. It is strongly AI-agent-oriented ("prefer running the matching skill"), but it is **web-only** and **stale on the new skill surface**: it lists the v0.1.x skills (`rigor-project-init` / `rigor-baseline-reduce` / `rigor-plugin-author` / `rigor-ci-setup`) and knows nothing of `rigor-next-steps`, `rigor skill describe`, the 13-skill catalogue, or that an installed Rigor could serve these docs offline.

## Decision

> **Offline-doc criterion.** A doc an agent consults to *drive Rigor* belongs in the gem and is served by `rigor docs`, mirroring `rigor skill print` for skills — so once Rigor is installed, the SKILL-driven UX never needs the network for guidance the gem already carries. The public web `llms.txt` + GitHub raw URLs remain the **pre-install** fallback (the one case — installing Rigor itself — that necessarily precedes a local `rigor`).

`rigor docs` completes the local-first agent surface (`rigor skill` + `rigor docs`), and `llms.txt` — the index over both — is refreshed to point at them and to record the offline path.

### WD1 — Bundle `docs/manual` in the gem

Add `docs/manual/**/*.md` + `docs/install.md` to the gemspec `files` glob (the chapters the skills and an onboarding agent actually consult). The cost is modest (markdown), and it makes `rigor docs` a complete offline manual. The full ADR / spec / notes corpus stays web-only (it is contributor-facing, not drive-Rigor guidance).

### WD2 — `rigor docs` command + a gem-side `llms.txt`

A new subcommand mirroring `rigor skill`'s shape (`lib/rigor/cli/docs_command.rb`, wired into `CLI::HANDLERS`):

- `rigor docs` — print the bundled `llms.txt` index (the offline twin of the site's, see WD4).
- `rigor docs <name>` — print a bundled doc to stdout (`rigor docs install`, `rigor docs editor-integration`, `rigor docs 17-driving-improvement`), accepting the chapter slug with or without the numeric prefix.
- `rigor docs list` / `rigor docs path <name>` — discovery, like `rigor skill`.

It reads from the bundled `docs/` under the gem root (the `SKILLS_ROOT`-style `File.expand_path` anchor); **no network**, read-only.

### WD3 — Skills prefer `rigor docs` (GitHub URL as pre-install fallback)

`rigor-editor-setup` / `rigor-mcp-setup` / `rigor-next-steps` change their doc pointers to *"run `rigor docs <chapter>` (local, no network — you have Rigor installed by this step); if Rigor is not installed yet, fetch the GitHub raw URL"*. The only irreducible network case is `rigor-next-steps`' **install** step (`docs/install.md` is consulted *before* `rigor` exists), so it keeps the raw URL with a `rigor docs install` note for re-reads.

### WD4 — `llms.txt` reflects the skill surface + the offline path (site + gem)

The site `llms.md` / `llms-ja.md` are refreshed: the "one prompt" start routes through **`rigor-next-steps`**, the skill list becomes the catalogue + `rigor skill describe`, chapter 17 ([Driving improvement](../manual/17-driving-improvement.md)) is indexed, and a note records that **with Rigor installed the docs/skills are available offline** (`rigor docs <chapter>` / `rigor skill print <name>`). The gem ships a copy as the `rigor docs` index — the site `llms.txt` is the canonical web copy; the gem copy is the offline mirror, kept in sync from the same manual source (no second authored truth — the manual is the source; both `llms.txt` copies index it).

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| Keep docs web-only (status quo) | Rejected | The network dependency the field trial flagged: an *installed* Rigor still can't serve its own editor/MCP/install guidance offline, against ADR-73's local-first design. |
| A separate `rigortype-docs` gem | Rejected | Duplicates the single-gem distribution (ADR-31); the manual is small enough to ride in `rigortype` like `skills/` already does. |
| Fetch the site `llms.txt` at runtime to build `rigor docs` | Rejected | Re-introduces the network coupling this ADR removes, and couples the CLI to a live site. |
| Bundle the whole `docs/` (ADRs, spec, notes) | Rejected | That corpus is contributor-facing, not drive-Rigor guidance; it would bloat the gem for no agent-onboarding benefit. The web `llms.txt` already links it. |

## Consequences

Positive:
- An installed Rigor is a **self-contained agent surface** — skills (`rigor skill`) + docs (`rigor docs`), both offline; the SKILL-driven UX stops depending on the network for guidance it already ships.
- `llms.txt` stops being stale and gains the offline path, so a web-discovering agent learns the local shortcut.

Negative / carry-over:
- The gem grows by the manual (markdown — modest). The full corpus deliberately stays out (WD1).
- **Two `llms.txt` copies** (site + gem) need sync discipline — mitigated by treating the manual as the single source both index; a generator (or a doc-check spec) keeping them aligned is a follow-up.
- `rigor docs` + the `llms.txt` vocabulary become **public surface frozen at v1.0 under [ADR-50](50-release-engineering-and-stability-strategy.md) WD1**.

## Relationship to other ADRs

- **[ADR-73](73-skill-driven-user-experience.md)** — the SKILL-driven UX this completes on the docs axis (`rigor docs` is the doc twin of `rigor skill print`; WD3 closes the skills' network dependency).
- **[ADR-27](27-tool-distribution-model.md) / [ADR-31](31-contribution-and-supply-chain-policy.md)** — the single-gem distribution; `docs/manual` rides in it like `skills/`, no second artifact.
- **[ADR-19](19-language-server-packaging.md) / [ADR-33](33-mcp-server.md)** — sibling "new `rigor` subcommand" packaging ADRs; `rigor docs` follows the same CLI-surface pattern.
- **[ADR-50](50-release-engineering-and-stability-strategy.md)** — freezes the `rigor docs` surface + `llms.txt` vocabulary at v1.0 (see Consequences).
