---
name: rigor-queue-survey
description: >-
  Collect rigor-survey coverage holes and work them sequentially in an
  interactive pi session (/queue-survey). USE FOR: 「カバレッジの穴を収集」,
  「順次着手」, survey coverage queue, fill survey holes, rigor-survey gaps.
  DO NOT USE FOR: parallel measurement on a shared survey checkout, release
  pre-clear (use rigor-queue-release), or cutting a gem release.
---

# Rigor queue — survey coverage

Orchestrator-led, multi-turn, **in-session** queue. Primary entry: user runs
`pi` in the Rigor repo (package in `.pi/settings.json`) then `/queue-survey`
or `/skill:rigor-queue-survey`. Same project session continues with `pi -c`.

Not a one-shot architect→lane.

See also: [`../../roles/orchestrator.md`](../../roles/orchestrator.md),
[`../../contracts/README.md`](../../contracts/README.md) (QueueTurn).

## Hard rules (always)

- Survey targets under measurement need **disjoint** checkouts; never share a
  measuring target across agents. Encode this in every spawn / LaneInput.
- Default survey root: `~/repo/ruby/rigor-survey` (or
  `/Users/megurine/repo/ruby/rigor-survey`). Ask if unclear; accept a path from
  the user.
- Prefer filing or linking **Issues** for holes (ADR-98), then sequential着手.
- Lanes: push head SHA and stop; orchestrator owns CI. No parallel host
  `make verify`.
- GitHub API: sparse CI polls (`gh pr view --json statusCheckRollup`), ≤1/min/PR.

## Turn protocol (in this same session)

Every turn:

1. **Restate** queue goal + constraints (survey root; disjoint target rule).
2. **Show ranked backlog** of coverage holes with evidence (survey paths,
   `gh` issue links). Prefer Issues over ad-hoc path lists when possible.
3. Propose **exactly one** next unit of work.
4. **Wait** for user: `next` / `do #N` / `skip` / `stop`
   (JA: `次` / `やる #N` / `スキップ` / `止めて` / `ストップ`).
5. On go: either (a) produce `LaneInput` including the **disjoint target**
   constraint and tell user to run
   `./agents/pi-harness/scripts/run-role.sh lane`, or (b) if in-session,
   note parallel lanes stay **outside** this session with disjoint targets.
6. After a unit completes: refresh queue, print
   `Queue: N remaining | Next candidate: … | say next/stop`.
7. Stay in this session — no wrapper restart. Resume with `pi -c` then
   `/queue-survey` if needed.

## When to call architect / lane vs stay here

| Stay in this session | Hand off |
| --- | --- |
| Collecting holes, ranking, proposing next unit | Architect: when a hole needs a fixed LaneInput |
| Filing/linking Issues for holes | Lane: via `run-role.sh lane` with disjoint checkout |
| Waiting on next/skip/stop | Parallel measuring agents: outside this session only |

## Finish phrases

- After proposing: wait for user.
- Empty / stop: `Survey holes cleared for now` or
  `Queue paused — resume with pi -c then /queue-survey`
- Blocked: `Blocked — need human`

## Non-goals

- Not sharing one measuring survey target across agents
- Not parallel host `make verify` or long CI sleep loops
- Not a one-shot architect→lane without the wait step
- Not inventing a backlog outside Issues when an Issue can be filed (ADR-98)
