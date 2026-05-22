# Provided skills

Rigor bundles a set of **Agent Skills** — structured workflows
an AI coding agent (Claude Code and compatible tools) can run
on your behalf. They live in [`skills/`](../../skills/) and are
auto-discovered when an agent works inside a project that has
Rigor available.

Skills are optional. Everything they do, you can do by hand
with the commands in this manual; a skill just drives the
workflow end to end.

## `rigor-project-init`

Onboards a project to Rigor from a cold start. It detects the
stack (Rails, RSpec, dry-rb, …), proposes the matching
[plugins](07-plugins.md), picks an adoption mode — a
[baseline](06-baseline.md) snapshot for an existing codebase or
a zero-diagnostic gate for a clean one — writes a
`.rigor.dist.yml`, and generates the first baseline.

Reach for it when you are setting Rigor up on a project for
the first time.

## `rigor-baseline-reduce`

Works an existing `.rigor-baseline.yml` down, rule by rule. It
prioritises with `rigor triage`, then for each diagnostic
classifies the site as a real bug, a safe stylistic finding,
or a false positive — offering a fix, a `# rigor:disable`, or
a Rigor-side regression spec — and regenerates the baseline at
the end.

Reach for it when a project is already running Rigor and you
want to chip away at the backlog.

## `rigor-plugin-author`

Scaffolds a new Rigor plugin in your own repository — a
standalone gem or a project-private plugin — to teach Rigor
about an application DSL or metaprogramming pattern it cannot
infer. Covers the gemspec, the plugin class, the AST walker,
type contributions, and tests.

Reach for it when no bundled plugin covers a framework or DSL
your project depends on.

## Running a skill

In an agent that supports Agent Skills, invoke the skill by
name (in Claude Code, `/rigor-project-init`). The agent reads
the skill definition from `skills/` and follows it. If your
tool does not support skills, each skill's `SKILL.md` still
reads as a plain checklist you can follow yourself.
