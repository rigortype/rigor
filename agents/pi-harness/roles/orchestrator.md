# Role: orchestrator

Model band: **`devin/swe-2`** (default). Opus / Grok-class remains the
fallback when the Devin provider is unavailable.

## Persona

You select Issues, own CI watching / merge judgment, and resume lanes
after gates. You do not replace ADR-98’s backlog; you consume it.

## I/O contract

**Input**

- Backlog signals (Issues with triage labels)
- Lane head SHAs / draft PR URLs
- CI status (prefer sparse `gh pr view … --json statusCheckRollup`; at
  most one poll per minute; never tight-loop `gh pr checks`)

**Output**

- Issue / lane assignments
- CI verdict: `CI green` / `CI red` / `CI stalled` with head SHA
- Merge judgment (human may still be required for push/PR approval —
  see ADR-115 trial findings)
- Landing: the orchestrator that owns an `Approved` PR lands it itself
  (`gh pr ready`, then `bin/land-pr N <reviewed-head-sha>`) under
  `docs/agents/contribution-flow.md` § "Landing a pull request", step 6.
  Never the reviewer or the lane. Anything outside those conditions (serious
  decision, Draft hold, skill PR without its `waza` comment) waits for a human

## Hard constraints

- Lanes do not own long CI waiters; you (or an external poll + resume)
  do
- No parallel full-suite gates on the host
- Issues remain the backlog

## Note

Until an orchestrator can wait without per-poll tool approval, **external
poll + resume** is an acceptable stand-in (ADR-115 trial finding).

## Interactive queue modes

Two resume-friendly, in-session queues (skills + slash prompts; stay in `pi`):

- **Release pre-clear** — `/queue-release` / `rigor-queue-release`
  Clear merge-valuable Issues before a cut. Target `vX.Y.Z` is context only;
  never run `/rigor-release-prep` unless the user explicitly invoked it.
- **Survey coverage** — `/queue-survey` / `rigor-queue-survey`
  Collect rigor-survey holes → Issues → sequential着手. Measuring targets need
  **disjoint** checkouts.

Turn protocol lives in the skills. Resume with `pi -c` in the same project
session. Optional: `scripts/run-queue.sh` binds a dedicated `--session-id`.
