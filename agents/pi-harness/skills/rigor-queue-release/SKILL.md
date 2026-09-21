---
name: rigor-queue-release
description: >-
  Rank and clear merge-worthy Issues before a Rigor cut, one unit per turn,
  in an interactive pi session (/queue-release). USE FOR: 「リリース前に対処」,
  "before vX.Y.Z", release pre-clear, merge blockers before cut, next/skip/stop
  queue, spawn parallel rigor-lane subagents. DO NOT USE FOR: cutting a release,
  /rigor-release-prep, VERSION bump, sealing CHANGELOG, opening release/x.y.z,
  or survey coverage holes (use rigor-queue-survey).
---

# Rigor queue — release pre-clear

Orchestrator-led, multi-turn, **in-session** queue. Primary entry: user runs
`pi` in the Rigor repo (packages in `.pi/settings.json`) then `/queue-release`
or `/skill:rigor-queue-release`. Same project session continues with `pi -c`.

Not a one-shot architect→lane.

See also: [`../../roles/orchestrator.md`](../../roles/orchestrator.md),
[`../../contracts/README.md`](../../contracts/README.md) (QueueTurn),
project agents under `.pi/agents/` (`rigor-lane`, `rigor-reviewer`).

Requires project package `npm:pi-subagents` (listed in `.pi/settings.json`).

## Hard rules (always)

- A release **goal** / milestone / `vX.Y.Z` wording is **NOT** authorization to
  cut a release. Never seal changelog, bump `VERSION` / `lib/rigor/version.rb`,
  open `release/x.y.z`, or run `/rigor-release-prep` unless the user
  **explicitly** invoked release-prep.
- When the queue is clear enough, say the cut is one `/rigor-release-prep`
  away — do not start it.
- Lanes: push head SHA and stop; **this parent** owns CI. No parallel host
  `make verify`. Issues = backlog (ADR-98).
- GitHub API: sparse CI polls (`gh pr view --json statusCheckRollup`), ≤1/min/PR.
- Never mutate release metadata in this queue.
- Managed worktree fanout needs a **clean** source checkout (excluding
  `.pi/subagents/` runtime state). Do not auto-merge worktree patches into
  master without a human.

## Turn protocol (in this same session)

Every turn:

1. **Restate** queue goal + constraints (target version as *context*;
   non-authorization rule).
2. **Show ranked backlog** (open Issues) with evidence (`gh issue list` /
   `gh issue view`). Rank: bugs/blockers > tidy before that cut.
3. Propose **exactly one** next unit of work (unless the user asked for a
   parallel batch — see spawn below).
4. **Wait** for user: `next` / `do #N` / `skip` / `stop`
   (JA: `次` / `やる #N` / `スキップ` / `止めて` / `ストップ`).
   Also accept `spawn` / `spawn N` / `全部やれ` / `parallel` for fanout.
5. **On go — prefer pi-subagents spawn** (do **not** tell the user to open
   another terminal for `run-role.sh` when the package is available):

   **Caveat (docs):** managed `worktree: true` is documented for
   `workflowScript` children (`runs.run` / `runs.all`), not as a reliable
   direct `{ agent, task }` knob. Prefer the workflowScript patterns below.

   **Single lane** (`next` / `do #N`):

   ```text
   subagent({
     async: true,
     worktree: true,
     workflowScript: `
       return runs.run("lane", {
         agent: "rigor-lane",
         task: args.task,
         worktree: true
       })
     `,
     args: { task: "<LaneInput text>" }
   })
   ```

   Optional: pass `model: "deepseek/deepseek-flash"` (or another resolved id)
   on the outer call / child if the agent frontmatter model does not resolve
   for the user's providers. Pin via `MODEL=` / `subagents.agentOverrides`
   when unsure.

   **Parallel batch** (`spawn N` / `全部やれ` / `parallel`): one top-level
   async workflow that fans out disjoint units:

   ```text
   subagent({
     async: true,
     worktree: true,
     workflowScript: `
       return runs.all([
         { key: "i1", agent: "rigor-lane", task: args.t1, worktree: true },
         { key: "i2", agent: "rigor-lane", task: args.t2, worktree: true }
       ])
     `,
     args: { t1: "<LaneInput #1>", t2: "<LaneInput #2>" }
   })
   ```

   **Fallback** if `pi-subagents` / `subagent` is unavailable: produce
   `LaneInput` and tell the user to run
   `./agents/pi-harness/scripts/run-role.sh lane` (separate terminal).

6. **After children return:** collect head SHAs and handoff manifests
   (`artifactPaths` / handoff JSON). Parent owns CI via sparse polls — do
   **not** let children CI-watch or sleep-loop. Refresh queue, print
   `Queue: N remaining | Next candidate: … | say next/stop`.
7. Stay in this session — do not require a wrapper restart. Resume later with
   `pi -c` in the same project.

## When to call architect / lane vs stay here

| Stay in this session | Hand off |
| --- | --- |
| Ranking, triage, evidence, proposing next unit | Architect: only if a unit needs a fresh LaneInput |
| Waiting on next/skip/stop / spawn | Lane: prefer `subagent` → `rigor-lane` + managed worktree; fallback `run-role.sh lane` |
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
- Not auto-merging managed worktree patches without a human
