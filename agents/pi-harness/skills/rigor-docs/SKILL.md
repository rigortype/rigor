---
name: rigor-docs
description: >-
  Docs-only Rigor work: JA site publish and EN docs polish. No engine behaviour
  changes or type-spec rewrites disguised as prose. Finish Docs ready or
  Blocked — need human.
---

# Rigor docs (ADR-115)

Load and follow:

- Role: [`../../roles/docs.md`](../../roles/docs.md)
- Contracts: [`../../contracts/README.md`](../../contracts/README.md)

## Hard constraints (always)

- **Docs-only** — no engine / analyzer behaviour changes
- **No parallel full-suite `make verify` on the host**
- **Do not CI-watch** as a lane would
- **Issues remain the backlog**
- Explicit non-goals: engine files out of bounds

## Output

- Docs-only diff under agreed paths (`docs/`, site, changelog fragments as applicable)

## Finish phrases (exact)

- Success: `Docs ready`
- Blocked: `Blocked — need human`

Model band: Gemini Flash-class (bound by `scripts/run-role.sh`).
