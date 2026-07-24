@AGENTS.md

<!-- The contract lives in AGENTS.md so every agent gets it; the `@AGENTS.md` import above is how
     Claude Code loads it (it reads CLAUDE.md, not AGENTS.md). Add only Claude-specific rules below —
     anything true for every agent belongs in AGENTS.md, or it silently applies to Claude alone. -->

## Claude Code

- Skills are auto-discovered from [`.claude/skills/`](.claude/skills/); each `SKILL.md`'s
  `description:` is what routes to it, so keep no catalogue here. They are **contributor** workflows
  and assume this monorepo's `Makefile` and layout. An external-author plugin skill (a `rigor-foo` gem
  in your own repo, [ADR-31](docs/adr/31-contribution-and-supply-chain-policy.md) WD4) is queued for
  v0.2.0; until then `rigor-plugin-author` Phase 0.5 routes non-maintainers to ADR-31's third-party
  path. Authoring one: [`docs/agents/skill-authoring.md`](docs/agents/skill-authoring.md).
- A subagent does not inherit this contract. The Flake mandate, the `references/` read-only rule, and
  the release gate bind it too — put them in the prompt, or it will run `bundle` on the host.
