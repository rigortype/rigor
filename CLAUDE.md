@AGENTS.md

<!-- The contract lives in AGENTS.md so every agent gets it; the `@AGENTS.md` import above is how
     Claude Code loads it (it reads CLAUDE.md, not AGENTS.md). Add only Claude-specific rules below —
     anything true for every agent belongs in AGENTS.md, or it silently applies to Claude alone. -->

## Claude Code

- **Two skill trees, and only one of them is yours.** [`.claude/skills/`](.claude/skills/) is
  auto-discovered in this session — **contributor** workflows that assume this monorepo's `Makefile`
  and layout. [`skills/`](skills/) is the **user-facing** set Rigor ships to projects adopting it;
  it is not loaded here, references only the public `rigor` CLI, and several names appear in both
  trees (`rigor-plugin-author`). Each `SKILL.md`'s `description:` is what routes to it, so keep no
  catalogue here. Authoring either: [`docs/agents/skill-authoring.md`](docs/agents/skill-authoring.md).
- A subagent does not inherit this contract. The Flake mandate, the `references/` read-only rule, and
  the release gate bind it too — put them in the prompt, or it will run `bundle` on the host.
