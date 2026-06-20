# Provided skills

Rigor bundles a set of **Agent Skills** — structured workflows an AI
coding agent (Claude Code and compatible tools) can run on your behalf.
They live in [`skills/`](../../skills/) and are auto-discovered when an
agent works inside a project that has Rigor available.

Skills are optional. Everything they do, you can do by hand with the
commands in this manual; a skill drives the workflow end to end.

## Start here — `rigor-next-steps`

`rigor-next-steps` is the single entry point: hand it to an agent and
it resolves the `rigor` command (installing it if missing), onboards an
unconfigured project, then asks `rigor skill describe` what to do next
and routes to the matching skill below. The end-to-end workflow it
drives is [Driving project improvement with `rigor-next-steps`](17-driving-improvement.md).

If you do not know which skill you need, start with this one.

## The catalogue

Every skill below is a destination `rigor-next-steps` (via
`rigor skill describe`) can route you to.

### Onboarding and foundation

- **`rigor-project-init`** — onboards a project from a cold start. It
  detects the stack (Rails, RSpec, dry-rb, …), proposes the matching
  [plugins](07-plugins.md), picks an adoption mode — a
  [baseline](06-baseline.md) snapshot for an existing codebase or a
  zero-diagnostic gate for a clean one — writes a `.rigor.dist.yml`, and
  generates the first baseline. Reach for it when setting Rigor up for
  the first time.
- **`rigor-rbs-setup`** — installs community RBS for your gems
  (`rbs collection install`) so RBS-less dependencies stop typing as
  `Dynamic`. Rigor auto-detects the resulting `rbs_collection.lock.yaml`.
- **`rigor-plugin-tune`** — re-matches `Gemfile.lock` to the bundled
  plugin catalogue and enables the plugins for your current stack
  (verifying with `rigor plugins --strict`). Reach for it after adding a
  gem, or for a Rails app whose Rails plugins are not yet enabled.

### Improving and reducing

- **`rigor-protection-uplift`** — closes the type-protection holes
  `rigor coverage --protection` surfaces: sig-gen first, then the
  minimal hand-RBS residual, under a double gate (the site becomes
  protected *and* `rigor check` gains no new diagnostic). See
  [Type-protection coverage](15-type-protection-coverage.md).
- **`rigor-baseline-reduce`** — works an existing `.rigor-baseline.yml`
  down rule by rule. It prioritises with `rigor triage`, classifies each
  site as a real bug / safe stylistic finding / false positive, and
  regenerates the baseline. Reach for it to chip away at the backlog.
- **`rigor-monkeypatch-resolve`** — resolves an `undefined-method`
  cluster that is really your project's own monkey-patches by wiring the
  defining files into `pre_eval:`.

### Integration and operations

- **`rigor-ci-setup`** — wires Rigor into CI with inline PR/MR
  diagnostics (SARIF / GitHub Actions / GitLab Code Quality / reviewdog).
  See [Running Rigor in CI](11-ci.md).
- **`rigor-editor-setup`** — wires the bundled `rigor lsp` language
  server into your editor (Neovim, VS Code, Helix, Emacs). See
  [Editor integration](09-editor-integration.md).
- **`rigor-mcp-setup`** — wires the bundled `rigor mcp` server into an
  AI coding agent (Claude Code, Cursor, Cline, …). See
  [MCP server](10-mcp-server.md).

### Maintenance and authoring

- **`rigor-upgrade`** — adopts a new Rigor version cleanly: diff against
  the baseline, sort genuine new catches from sig-quality false
  positives, regenerate.
- **`rigor-doctor`** — validates that the setup is healthy (config
  resolves, plugins load, the baseline is fresh, the RBS environment is
  not broken). See [Troubleshooting](13-troubleshooting.md).
- **`rigor-plugin-author`** — scaffolds a new Rigor plugin in your own
  repository to teach Rigor an application DSL or metaprogramming
  pattern it cannot infer. Reach for it when no bundled plugin covers a
  framework or DSL your project depends on.

## Discovering skills from the CLI

The skills ship inside the `rigortype` gem, so they are reachable even
when Rigor is installed via `mise` / `gem install` with no project-side
source checkout. The `rigor skill` command surfaces them:

```sh
rigor skill describe        # probe the project + recommend the next skill (alias: rigor describe)
rigor skill --list          # name + absolute path for each bundled skill
rigor skill <name>          # print the SKILL.md body (with a references/ header)
rigor skill --path <name>   # one-line absolute SKILL.md path, for a file-reading tool
```

`rigor skill describe` is the recommendation engine driven by
`rigor-next-steps`; `rigor skill rigor-project-init` is the
canonical way to hand an agent the onboarding workflow without pointing
it at the repository. The `list` / `print` / `path` verb spellings are
deprecated (removed in v0.3.0). See [CLI reference](02-cli-reference.md#rigor-skill).

## Installing skills into a project

In addition to the gem, the user-facing skills are installable via
[vercel-labs/skills](https://github.com/vercel-labs/skills) — useful for
dropping the entry point into a project *before* Rigor is installed:

```sh
# Just the entry point (recommended):
npx skills add https://github.com/rigortype/rigor/tree/master/skills/rigor-next-steps
# Or the whole user-facing set:
npx skills add rigortype/rigor
```

(The contributor-only skills under `.claude/skills/` are marked internal
and are not installed by a bulk `npx skills add`.)

## Running a skill

In an agent that supports Agent Skills, invoke the skill by name (in
Claude Code, `/rigor-next-steps`). The agent reads the skill definition
(from `skills/` in a source checkout, or via `rigor skill <name>`
otherwise) and follows it. If your tool does not support skills, each
skill's `SKILL.md` still reads as a plain checklist you can follow
yourself.
