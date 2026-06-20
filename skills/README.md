# Rigor Agent Skills

These are the **user-facing** Agent Skills Rigor ships — step-by-step
workflows that walk an AI coding agent (Claude Code and any tool that
reads the [Agent Skills](https://agentskills.io/) shape) through adopting
and operating Rigor on *your* project.

Each skill is a directory with a `SKILL.md` carrying YAML `name:` +
`description:` frontmatter, plus optional `references/` detail loaded on
demand. They reference only the public `rigor` CLI surface.

> Looking for the skills that work *on the Rigor repository itself*
> (release prep, ADR authoring, builtin imports)? Those are **contributor**
> workflows under [`.claude/skills/`](../.claude/skills/), marked
> `metadata.internal: true` so they are not installed for end users.

## Two skills to remember

You only ever need to remember two; the rest are reached through them.

- **`rigor-next-steps`** — *"what should we do next?"* The entry point: it
  resolves the `rigor` command (installing it if missing), onboards the
  project if it has no config, then asks the live binary what to do next
  and routes to the right skill below.
- **`rigor-ask`** — *"answer this about Rigor."* Ask anything in plain
  language — why a diagnostic fired or whether it's a false positive, how
  the type model works, what a flag or config key does, how Rigor compares
  to Sorbet / Steep / mypy, whether it handles your gem or framework, or
  how to type a method. Rigor is niche and version-specific, so rather
  than answer from memory it **investigates**: it reads Rigor's own
  handbook and manual **offline** via `rigor docs` *and* runs Rigor over
  your code (`rigor check` / `annotate` / `type-of`), then answers from
  the page or the inferred type. You only have to remember the question.

`rigor-next-steps` runs `rigor skill describe`:

```sh
rigor skill describe
```

`rigor skill describe` (also `rigor skill --describe`) probes the
project's current state (config / baseline / `sig/` / CI), recommends the
next skill with a reason, and lists every skill's current description.
The recommendation logic ships **with the gem**, so it stays current to
your installed version rather than being frozen into a SKILL file — see
[ADR-73](../docs/adr/73-skill-driven-user-experience.md).

## The catalogue

| Skill | Use it to |
| --- | --- |
| [`rigor-next-steps`](rigor-next-steps/SKILL.md) | **Start here.** Figure out the next step on this project and route to the right skill below. |
| [`rigor-ask`](rigor-ask/SKILL.md) | **Ask anything about Rigor**, any time — a diagnostic, the type model, a flag, a comparison to another checker, whether it handles your stack, how to type something. It investigates from the bundled docs (`rigor docs`) *and* your actual code (`rigor check` / `annotate` / `type-of`) rather than answering from memory. |
| [`rigor-project-init`](rigor-project-init/SKILL.md) | Onboard a project from scratch — detect the stack, choose an adoption mode, write `.rigor.dist.yml`, snapshot a baseline. |
| [`rigor-rbs-setup`](rigor-rbs-setup/SKILL.md) | Install community RBS for the project's gems (`rbs collection install`) so Rigor stops typing RBS-less dependencies as `Dynamic`. |
| [`rigor-ci-setup`](rigor-ci-setup/SKILL.md) | Wire Rigor into CI and surface diagnostics inline on the PR / MR (SARIF, GitHub Actions, GitLab Code Quality, reviewdog, …). |
| [`rigor-baseline-reduce`](rigor-baseline-reduce/SKILL.md) | Work an existing `.rigor-baseline.yml` down rule by rule — classify, fix or suppress, regenerate. |
| [`rigor-monkeypatch-resolve`](rigor-monkeypatch-resolve/SKILL.md) | Resolve `undefined-method` clusters from the project's own monkey-patches by wiring the defining files into `pre_eval:`. |
| [`rigor-editor-setup`](rigor-editor-setup/SKILL.md) | Wire `rigor lsp` into the editor (Neovim, VS Code, Helix, Emacs) for live diagnostics, hover types, and completion. |
| [`rigor-mcp-setup`](rigor-mcp-setup/SKILL.md) | Wire `rigor mcp` into an AI agent (Claude Code, Cursor, Cline, …) so it can call Rigor's read-only analysis tools. |
| [`rigor-protection-uplift`](rigor-protection-uplift/SKILL.md) | Close the type-protection holes `rigor coverage --protection` surfaces, under a double gate that keeps `rigor check` clean. |
| [`rigor-plugin-tune`](rigor-plugin-tune/SKILL.md) | Re-match `Gemfile.lock` against the bundled plugin catalogue and enable the plugins for the project's current stack; verify with `rigor plugins --strict`. |
| [`rigor-plugin-author`](rigor-plugin-author/SKILL.md) | Author a Rigor plugin (in your own repo) to teach Rigor an application DSL, framework, or metaprogramming pattern. |
| [`rigor-upgrade`](rigor-upgrade/SKILL.md) | Adopt a new Rigor version cleanly — diff diagnostics against the baseline, sort genuine new catches from sig-quality FPs, regenerate. |
| [`rigor-doctor`](rigor-doctor/SKILL.md) | Validate the setup is healthy — config resolves, plugins load, baseline is fresh, the analysis sees your code. |

## Installing the skills

There are two channels, both reading this same `skills/` tree.

### A. Via the `rigortype` gem (once Rigor is installed)

The skills are bundled inside the gem. Browse and load them with the
`rigor skill` command:

```sh
rigor skill describe              # recommend the next step for this project
rigor skill --list                # name + absolute path of every bundled skill
rigor skill rigor-project-init    # print a skill's body to follow
rigor skill --path rigor-ci-setup # just the SKILL.md path (for a Read tool)
```

### B. Via [vercel-labs/skills](https://github.com/vercel-labs/skills) (works before Rigor is installed)

`npx skills` installs a skill straight from this repo into your project —
useful for dropping the entry point into a project that has not adopted
Rigor yet:

```sh
# Just the entry point (recommended):
npx skills add https://github.com/rigortype/rigor/tree/master/skills/rigor-next-steps

# Or the whole user-facing set (contributor skills under .claude/skills are
# hidden via metadata.internal, so this installs only the skills above):
npx skills add rigortype/rigor

# Try one without installing it:
npx skills use rigortype/rigor@rigor-next-steps | claude
```

Once installed, the entry-point skill takes over: it installs `rigor`
(following [`docs/install.md`](../docs/install.md)) and routes the rest
through `rigor skill describe`.

## Authoring / changing a skill

Keep each skill's `description:` accurate — `rigor skill describe` reads
it live for the catalogue, so a stale description shows up immediately.
Skills are packaged by the gemspec's `skills/*/SKILL.md` +
`skills/*/references/*.md` globs; a new skill directory is picked up
automatically. The authoring conventions for the contributor-side skills
are in [`.claude/skills/`](../.claude/skills/).
