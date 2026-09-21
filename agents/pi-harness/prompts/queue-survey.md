---
description: >-
  Survey coverage queue — collect rigor-survey holes and work them sequentially.
  Prefer pi-subagents rigor-lane spawn; disjoint survey checkouts still required.
  Also: 「rigor-survey カバレッジの穴を収集して順次着手して」
argument-hint: "[optional survey root path]"
---
You are running an **interactive survey coverage queue** (orchestrator band;
do not demote via `/model`). Stay in this session.

1. Load and follow skill `/skill:rigor-queue-survey`.
2. Survey root: ${@:-~/repo/ruby/rigor-survey or /Users/megurine/repo/ruby/rigor-survey}.
3. Follow the skill turn protocol: restate → ranked holes (prefer Issues) →
   exactly one next unit → wait for `next` / `do #N` / `skip` / `stop` / `spawn`
   (JA OK).
4. On go: prefer `subagent` → `rigor-lane` via `workflowScript` + `worktree: true`;
   fallback `run-role.sh lane` if needed. A rigor managed worktree does **not**
   replace disjoint `rigor-survey/<project>` checkouts — put unique survey paths
   in every LaneInput.
5. Hard rule: measuring targets need **disjoint** checkouts — never share a
   target across agents; put that in every LaneInput / spawn prompt.
6. After each completed unit: `Queue: N remaining | Next candidate: … | say next/stop`.
