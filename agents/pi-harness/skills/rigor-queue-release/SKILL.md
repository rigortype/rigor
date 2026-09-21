---
name: rigor-queue-release
description: >-
  Interactive continuable release pre-clear queue for Rigor. Use when the user
  asks to clear tasks before a cut (e.g. 「vX.Y.Z リリース前に対処した方がいいタスクを解消して」,
  "release pre-clear", "before v1.2.3 merge these blockers"). Rank Issues by
  merge value, propose exactly one unit per turn, wait for next/do #N/skip/stop.
  Target version wording is context only — never seal changelog, bump VERSION,
  open release/x.y.z, or run /rigor-release-prep unless the user explicitly
  invoked release-prep.
---

# Rigor queue — release pre-clear

Orchestrator-led, multi-turn, **in-session** queue. Primary entry: user runs
`pi` in the Rigor repo (package in `.pi/settings.json`) then `/queue-release`
or `/skill:rigor-queue-release`. Same project session continues with `pi -c`.

Not a one-shot architect→lane.

See also: [`../../roles/orchestrator.md`](../../roles/orchestrator.md),
[`../../contracts/README.md`](../../contracts/README.md) (QueueTurn).

## Hard rules (always)

- A release **goal** / milestone / `vX.Y.Z` wording is **NOT** authorization to
  cut a release. Never seal changelog, bump `VERSION` / `lib/rigor/version.rb`,
  open `release/x.y.z`, or run `/rigor-release-prep` unless the user
  **explicitly** invoked release-prep.
- When the queue is clear enough, say the cut is one `/rigor-release-prep`
  away — do not start it.
- Lanes: push head SHA and stop; orchestrator owns CI. No parallel host
  `make verify`. Issues = backlog (ADR-98).
- GitHub API: sparse CI polls (`gh pr view --json statusCheckRollup`), ≤1/min/PR.
- Never mutate release metadata in this queue.

## Turn protocol (in this same session)

Every turn:

1. **Restate** queue goal + constraints (target version as *context*;
   non-authorization rule).
2. **Show ranked backlog** (open Issues) with evidence (`gh issue list` /
   `gh issue view`). Rank: bugs/blockers > tidy before that cut.
3. Propose **exactly one** next unit of work.
4. **Wait** for user: `next` / `do #N` / `skip` / `stop`
   (JA: `次` / `やる #N` / `スキップ` / `止めて` / `ストップ`).
5. On go: either (a) produce `LaneInput` and tell user to run
   `./agents/pi-harness/scripts/run-role.sh lane` in another terminal, or
   (b) if user wants in-session work, note parallel lanes stay **outside**
   this session.
6. After a unit completes: refresh queue, print
   `Queue: N remaining | Next candidate: … | say next/stop`.
7. Stay in this session — do not require a wrapper restart. Resume later with
   `pi -c` in the same project.

## When to call architect / lane vs stay here

| Stay in this session | Hand off |
| --- | --- |
| Ranking, triage, evidence, proposing next unit | Architect: only if a unit needs a fresh LaneInput for an external lane |
| Waiting on next/skip/stop | Lane: via `run-role.sh lane` (or user-spawned outside session) |
| Sparse CI verdict after a lane push | — |

## Finish phrases

- After proposing: wait (no terminal finish until stop or empty).
- Queue clear / stop with cut appropriate:
  `Queue clear for context cut — one /rigor-release-prep away`
- Blocked: `Blocked — need human`
- User stop: `Queue paused — resume with pi -c then /queue-release`

## Non-goals

- Not a release cut; not `/rigor-release-prep`
- Not sealing changelog or bumping version files
- Not opening `release/x.y.z`
- Not parallel host `make verify` or long CI sleep loops
- Not a second backlog outside Issues (ADR-98)
