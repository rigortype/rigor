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

## Start here — `rigor-next-steps`

If you do not know which skill you need, start with **`rigor-next-steps`**.
It is the entry point: it resolves the `rigor` command (installing it if
missing), onboards the project if it has no config, then asks the live
binary what to do next:

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
| [`rigor-project-init`](rigor-project-init/SKILL.md) | Onboard a project from scratch — detect the stack, choose an adoption mode, write `.rigor.dist.yml`, snapshot a baseline. |
| [`rigor-rbs-setup`](rigor-rbs-setup/SKILL.md) | Install community RBS for the project's gems (`rbs collection install`) so Rigor stops typing RBS-less dependencies as `Dynamic`. |
| [`rigor-ci-setup`](rigor-ci-setup/SKILL.md) | Wire Rigor into CI and surface diagnostics inline on the PR / MR (SARIF, GitHub Actions, GitLab Code Quality, reviewdog, …). |
| [`rigor-baseline-reduce`](rigor-baseline-reduce/SKILL.md) | Work an existing `.rigor-baseline.yml` down rule by rule — classify, fix or suppress, regenerate. |
| [`rigor-editor-setup`](rigor-editor-setup/SKILL.md) | Wire `rigor lsp` into the editor (Neovim, VS Code, Helix, Emacs) for live diagnostics, hover types, and completion. |
| [`rigor-mcp-setup`](rigor-mcp-setup/SKILL.md) | Wire `rigor mcp` into an AI agent (Claude Code, Cursor, Cline, …) so it can call Rigor's read-only analysis tools. |
| [`rigor-protection-uplift`](rigor-protection-uplift/SKILL.md) | Close the type-protection holes `rigor coverage --protection` surfaces, under a double gate that keeps `rigor check` clean. |
| [`rigor-plugin-author`](rigor-plugin-author/SKILL.md) | Author a Rigor plugin (in your own repo) to teach Rigor an application DSL, framework, or metaprogramming pattern. |

## Installing the skills

There are two channels, both reading this same `skills/` tree.

### A. Via the `rigortype` gem (once Rigor is installed)

The skills are bundled inside the gem. Browse and load them with the
`rigor skill` command:

```sh
rigor skill describe              # recommend the next step for this project
rigor skill list                  # name + absolute path of every bundled skill
rigor skill print rigor-project-init   # print a skill's body to follow
rigor skill path  rigor-ci-setup       # just the SKILL.md path (for a Read tool)
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
