---
name: rigor-orchestrator
description: >-
  Select Issues, assign lanes, own CI watching / merge judgment for the Rigor
  pi harness. Prefer sparse gh status polls; external poll + resume is OK.
  Issues remain the ADR-98 backlog. Do not run parallel host make verify.
---

# Rigor orchestrator (ADR-115)

Load and follow:

- Role: [`../../roles/orchestrator.md`](../../roles/orchestrator.md)
- Contracts: [`../../contracts/README.md`](../../contracts/README.md)

## Hard constraints (always)

- **No parallel full-suite `make verify` on the host**
- **Lanes do not own long CI watchers** — you (or external poll + resume) do
- **Issues remain the backlog** (ADR-98); do not invent a second queue
- Prefer sparse `gh pr view … --json statusCheckRollup`; at most one poll per
  minute; never tight-loop `gh pr checks`

## I/O

Consume backlog signals and lane head SHAs / draft PRs. Emit assignments and:

```text
CiWatchOutput:
  verdict:         "CI green" | "CI red" | "CI stalled"
  head_sha:        <40-hex>
  failing_jobs:    [name, ...]   # when red
```

## Finish phrases

- CI: `CI green` / `CI red` / `CI stalled` (include head SHA)
- Human may still be required for push/PR approval (ADR-115 trial findings)

Model band: Opus / Grok-class (bound by `scripts/run-role.sh`).
