---
description: >-
  Release pre-clear queue — clear blockers before a cut (vX.Y.Z context only;
  not release-prep). Also: 「リリース前に対処した方がいいタスクを解消して」
argument-hint: "[target version e.g. v1.2.3 — context only]"
---
You are running an **interactive release pre-clear queue** (orchestrator band;
do not demote via `/model`). Stay in this session.

1. Load and follow skill `/skill:rigor-queue-release`.
2. Target context from user (not release auth): ${@:-ask for vX.Y.Z if missing}.
3. Follow the skill turn protocol: restate → ranked Issues → exactly one next
   unit → wait for `next` / `do #N` / `skip` / `stop` (JA OK).
4. Hard rule: never seal changelog, bump VERSION, open `release/x.y.z`, or run
   `/rigor-release-prep` unless the user explicitly invoked release-prep. When
   appropriate, say the cut is one `/rigor-release-prep` away.
5. After each completed unit: `Queue: N remaining | Next candidate: … | say next/stop`.
