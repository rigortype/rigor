# Authoring a skill in this repo

Two trees, two audiences. Each `SKILL.md`'s `description:` is the routing surface; do not maintain a
second catalogue of triggers.

- [`.claude/skills/`](../../.claude/skills/) contains contributor workflows. They assume this repo's
  `Makefile` and layout and carry `metadata.internal: true`.
- [`skills/`](../../skills/) contains user-facing workflows. They use only the public `rigor` CLI; no
  `make` targets, repository paths, or Flake commands. The two trees may share a name while serving
  different readers.

Third-party plugin authors are routed out of the monorepo — see `rigor-plugin-author` Phase 0.5 and
[ADR-31](../adr/31-contribution-and-supply-chain-policy.md) WD2/WD4.

## Description

Keep the description short enough to route from metadata alone: state the action, the concrete event or
artifact that triggers it, and only the non-obvious boundary that routes elsewhere. Prefer one or two
sentences over a catalogue of examples, implementation details, or exact flags. A trigger should name
the task this skill owns, not every task in its neighborhood; an anti-trigger is useful when two skills
could plausibly match.

Treat the description as a pointer, not a mini-procedure. Put exact commands, version-coupled values,
long examples, and branch-specific steps in the body or a conditional `references/` file. The body should
be the stable workflow spine: goal, phases, decision points, and an observable completion criterion.
When a skill has multiple branches, route to the relevant reference instead of loading every branch.

## The `waza` checker

After changing a `SKILL.md`, run `waza check <skill-path>` once for spec compliance. Apply advisories
only when they identify a real defect independent of the agentskills.io publication profile; Rigor's
comprehensive workflows do not need to be reshaped to satisfy its token budget or labels. See
[ADR-81](../adr/81-skill-set-optimization.md) for the standing calibration.

Never run `waza dev --auto`: it injects boilerplate that is often false. The hand-written `name:` and
`description:` pair is the binding surface.
