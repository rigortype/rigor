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


## Interactive queues (QueueTurn)

Used by `/queue-release` and `/queue-survey` (skills `rigor-queue-release`,
`rigor-queue-survey`). Multi-turn; one unit per user go.

```text
QueueTurnInput:
  mode:            release | survey
  goal:            restated goal + constraints
  target_version:  vX.Y.Z?          # release context only — NOT release auth
  survey_root:     path?            # survey mode; default ~/repo/ruby/rigor-survey
  backlog:         [QueueItem, ...] # ranked; with gh / survey evidence
  user_command:    next | do #<n> | skip | stop | (JA equivalents)
```

```text
QueueItem:
  id:              #<issue> | survey-hole:<path> | …
  rank:            int
  evidence:        gh URL | survey path | short note
  why_now:         one-line merge / coverage value
```

```text
QueueTurnOutput:
  proposed_unit:   exactly one QueueItem (or none if empty/stopped)
  lane_input:      LaneInput?       # when handing off to run-role.sh lane
  status_line:     "Queue: N remaining | Next candidate: … | say next/stop"
  finish:          optional — "Queue clear for context cut — one /rigor-release-prep away"
                   | "Survey holes cleared for now"
                   | "Queue paused — resume with pi -c then /queue-…"
                   | "Blocked — need human"
```

### Queue hard rules (encode in skills)

- Release goal / `target_version` is **not** authorization to cut a release
  (no changelog seal, VERSION bump, `release/x.y.z`, or `/rigor-release-prep`
  unless explicitly invoked).
- Survey measuring targets need **disjoint** checkouts across agents.
- Shared non-goals above still apply.

## Shared non-goals (encode in every lane/orchestrator prompt)

- No parallel full-suite `make verify` on the host
- Lanes do not own long CI watchers
- Issues are the backlog (ADR-98)
