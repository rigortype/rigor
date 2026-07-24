# Authoring a skill in this repo

The skills under [`.claude/skills/`](../../.claude/skills/) are auto-discovered; each `SKILL.md`'s
`description:` is what routes to it, so no catalogue is kept anywhere else. They are **contributor**
workflows and assume this monorepo's `Makefile` and layout.

## The `waza` checker

After authoring a `SKILL.md`, run `waza check <skill-path>` once for spec compliance. Everything else
it reports is **informational** — its token budgets and `USE FOR:` markers target agentskills.io
publication, not these contributor skills.

Never run `waza dev --auto`: it injects frequently-false boilerplate. The hand-written `name:` +
`description:` pair is the binding surface.
