# pi-harness contracts

Stub I/O shapes for ADR-115 roles. Keep shapes small; expand only when
a real architect→lane run proves a field is load-bearing.

## Architect → lane

```text
LaneInput:
  issue:           #<n> | URL
  acceptance:      [checkable bullet, ...]
  touch:           [path glob / file, ...]   # likely bounds
  must_not:        [constraint, ...]
  worktree:        path | branch name
  model_band:      deepseek-flash-class
```

```text
LaneOutput:
  head_sha:        <40-hex>
  status:          "lane done" | "blocked"
  notes:           optional short blocker / deferral
```

Lane stops after push. It does **not** return CI status.

## Orchestrator ↔ CI

```text
CiWatchInput:
  pr:              #<n> | URL
  head_sha:        <40-hex>   # expected tip
  poll:            external | in-session   # prefer external until approved waits work
```

```text
CiWatchOutput:
  verdict:         "CI green" | "CI red" | "CI stalled"
  head_sha:        <40-hex>
  failing_jobs:    [name, ...]   # when red
```

## Reviewer

```text
ReviewInput:
  pr:              #<n> | URL
  acceptance:      [checkable bullet, ...]
```

```text
ReviewOutput:
  verdict:         "Approved" | "Needs fix"
  checklist:       [finding, ...]   # required when Needs fix
```

## Shared non-goals (encode in every lane/orchestrator prompt)

- No parallel full-suite `make verify` on the host
- Lanes do not own long CI watchers
- Issues are the backlog (ADR-98)
