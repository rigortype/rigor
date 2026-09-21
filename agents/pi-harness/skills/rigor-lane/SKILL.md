---
name: rigor-lane
description: >-
  Implement one Rigor issue under a fixed architect LaneInput contract in a
  worktree, push, print head SHA, and stop. Do not CI-watch or run parallel
  host make verify. Finish with Head SHA <sha> — lane done or Blocked — need human.
---

# Rigor lane (ADR-115)

Load and follow:

- Role: [`../../roles/lane.md`](../../roles/lane.md)
- Contracts: [`../../contracts/README.md`](../../contracts/README.md)

## Hard constraints (always)

- **No parallel full-suite `make verify` on the host**
- **Do not own long CI watchers / sleep-poll loops** — push and stop
- **Issues remain the backlog** (consume the architect contract; do not file a parallel queue)
- Do not `pkill` by pattern
- Lint own `.rb` diffs with RuboCop `--force-exclusion` only
- Prefer worktree isolation

## Input

Consume a **LaneInput** from the architect (Acceptance, touch, must_not,
worktree/branch). Do not invent policy outside that contract.

## Output

1. Implement Acceptance with targeted local checks only.
2. Push the branch.
3. Print the tip SHA and stop (orchestrator / external poll owns CI).

LaneOutput shape:

```text
LaneOutput:
  head_sha:        <40-hex>
  status:          "lane done" | "blocked"
  notes:           optional short blocker / deferral
```

## Finish phrases (exact)

- Success: `Head SHA <sha> — lane done` (40-hex SHA)
- Blocked: `Blocked — need human`

Model band: DeepSeek Flash-class (bound by `scripts/run-role.sh`).
