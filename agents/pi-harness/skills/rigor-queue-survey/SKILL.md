---
name: rigor-queue-survey
description: >-
  Collect rigor-survey coverage holes and work them sequentially in an
  interactive pi session (/queue-survey). USE FOR: 「カバレッジの穴を収集」,
  「順次着手」, survey coverage queue, fill survey holes, spawn rigor-lane
  subagents with disjoint survey targets. DO NOT USE FOR: parallel measurement
  on a shared survey checkout, release pre-clear (use rigor-queue-release),
  or cutting a gem release.
---

# Rigor queue — survey coverage

Orchestrator-led, multi-turn, **in-session** queue. Primary entry: user runs
`pi` in the Rigor repo (packages in `.pi/settings.json`) then `/queue-survey`
or `/skill:rigor-queue-survey`. Same project session continues with `pi -c`.

Not a one-shot architect→lane.

See also: [`../../roles/orchestrator.md`](../../roles/orchestrator.md),
[`../../contracts/README.md`](../../contracts/README.md) (QueueTurn),
project agents under `.pi/agents/` (`rigor-lane`, `rigor-reviewer`).

Requires project package `npm:pi-subagents` (listed in `.pi/settings.json`).

## Hard rules (always)

- Survey targets under measurement need **disjoint** checkouts; never share a
  measuring target across agents. Encode this in every spawn / LaneInput.
- **Managed worktree of *rigor* ≠ survey exclusivity.** A pi-subagents managed
  worktree isolates the *rigor* implementation checkout only. It does **not**
  satisfy exclusivity of survey measurement trees such as
  `~/repo/ruby/rigor-survey/<project>` (or
  `/Users/megurine/repo/ruby/rigor-survey/<project>`). Each measuring agent
  still needs its **own disjoint survey target checkout**; put that path in
  every LaneInput / spawn task.
- Default survey root: `~/repo/ruby/rigor-survey` (or
  `/Users/megurine/repo/ruby/rigor-survey`). Ask if unclear; accept a path from
  the user.
- Prefer filing or linking **Issues** for holes (ADR-98), then sequential着手.
- Lanes: push head SHA and stop; **this parent** owns CI. No parallel host
  `make verify`.
- GitHub API: sparse CI polls (`gh pr view --json statusCheckRollup`), ≤1/min/PR.
- Managed worktree fanout needs a **clean** source *rigor* checkout. Do not
  auto-merge worktree patches without a human.

## Turn protocol (in this same session)

Every turn:

1. **Restate** queue goal + constraints (survey root; disjoint **survey target**
   rule — separate from rigor managed worktrees).
2. **Show ranked backlog** of coverage holes with evidence (survey paths,
   `gh` issue links). Prefer Issues over ad-hoc path lists when possible.
3. Propose **exactly one** next unit of work (unless parallel spawn requested).
4. **Wait** for user: `next` / `do #N` / `skip` / `stop`
   (JA: `次` / `やる #N` / `スキップ` / `止めて` / `ストップ`).
   Also accept `spawn` / `spawn N` / `全部やれ` / `parallel`.
5. **On go — prefer pi-subagents spawn** (include disjoint survey target path
   in every LaneInput). Managed `worktree: true` applies to the *rigor* repo
   only; still assign unique survey checkouts.

   **Caveat:** use `workflowScript` + `runs.run` / `runs.all` for
   `worktree: true` (documented path). Direct `{ agent, task, worktree: true }`
   is not the documented isolation path.

   **Single:**

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
     args: { task: "<LaneInput including disjoint survey target path>" }
   })
   ```

   **Parallel** (`spawn N` / `全部やれ` / `parallel`):

   ```text
   subagent({
     async: true,
     worktree: true,
     workflowScript: `
       return runs.all([
         { key: "h1", agent: "rigor-lane", task: args.t1, worktree: true },
         { key: "h2", agent: "rigor-lane", task: args.t2, worktree: true }
       ])
     `,
     args: { t1: "<LaneInput + survey checkout A>", t2: "<LaneInput + survey checkout B>" }
   })
   ```

   **Fallback** if pi-subagents unavailable: LaneInput +
   `./agents/pi-harness/scripts/run-role.sh lane` with disjoint targets.

6. **After children return:** collect head SHAs / handoff manifests; parent
   owns sparse CI polls; children must not CI-watch. Refresh queue, print
   `Queue: N remaining | Next candidate: … | say next/stop`.
7. Stay in this session — no wrapper restart. Resume with `pi -c` then
   `/queue-survey` if needed.

## When to call architect / lane vs stay here

| Stay in this session | Hand off |
| --- | --- |
| Collecting holes, ranking, proposing next unit | Architect: when a hole needs a fixed LaneInput |
| Filing/linking Issues for holes | Lane: prefer `subagent` → `rigor-lane` + rigor worktree **and** disjoint survey checkout; fallback `run-role.sh lane` |
| Waiting on next/skip/stop / spawn | Parallel measuring agents: unique survey targets always |

## Finish phrases

- After proposing: wait for user.
- Empty / stop: `Survey holes cleared for now` or
  `Queue paused — resume with pi -c then /queue-survey`
- Blocked: `Blocked — need human`

## Non-goals

- Not sharing one measuring survey target across agents
- Not treating a rigor managed worktree as a substitute for survey exclusivity
- Not parallel host `make verify` or long CI sleep loops
- Not a one-shot architect→lane without the wait step
- Not inventing a backlog outside Issues when an Issue can be filed (ADR-98)
- Not auto-merging managed worktree patches without a human
