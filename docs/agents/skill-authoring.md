# Authoring a skill in this repo

Two trees, two audiences. Each `SKILL.md`'s `description:` is what routes to it, so no catalogue is
kept anywhere else.

- [`.claude/skills/`](../../.claude/skills/) — **contributor** workflows, auto-discovered when working
  in this repo. They assume the monorepo's `Makefile` and layout and carry `metadata.internal: true`,
  so they are never installed for end users.
- [`skills/`](../../skills/) — the **user-facing** set Rigor ships to projects adopting it. These
  reference only the public `rigor` CLI: no `make` targets, no repo-relative paths, no Flake. A few
  names exist in both trees (`rigor-plugin-author`); they are different documents for different
  readers, and [`skills/README.md`](../../skills/README.md) carries the user-facing inventory.

Third-party plugin authors are routed out of the monorepo entirely — see `rigor-plugin-author`
Phase 0.5 and [ADR-31](../adr/31-contribution-and-supply-chain-policy.md) WD2/WD4.

## The `waza` checker

After authoring a `SKILL.md`, run `waza check <skill-path>` once for spec compliance. Everything else
it reports is **informational** — its token budgets and `USE FOR:` markers target agentskills.io
publication, which binds the `skills/` tree far more than the contributor one.

Never run `waza dev --auto`: it injects frequently-false boilerplate. The hand-written `name:` +
`description:` pair is the binding surface.
