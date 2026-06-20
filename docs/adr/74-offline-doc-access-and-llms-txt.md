# ADR-74 — Offline doc access (`rigor docs`) + `llms.txt` linkage

Status: **Accepted — design ratified 2026-06-20; implementation queued (WD1–WD4 below).** Completes the [ADR-73](73-skill-driven-user-experience.md) SKILL-driven UX on the *documentation* axis: an installed Rigor serves the docs an agent needs **offline** (the `rigor docs` command over a gem-bundled `docs/manual`), and the project's agent doc-discovery index — `llms.txt` — both reflects the new skill surface and tells the agent it can read those docs locally without the network.

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
