# pi-harness (ADR-115 stubs)

Thin in-tree package for a **role-bound multi-model harness on pi**.
Owns role×model bindings and lane I/O contracts. Does **not** yet own a
full long-loop orchestrator — that remains optional (takt under `.takt/`,
or a later in-tree driver).

See [ADR-115](../../docs/adr/115-pi-multi-model-harness.md). Backlog and
flow rules stay in [ADR-98](../../docs/adr/98-development-flow-document-roles.md)
and [`docs/agents/contribution-flow.md`](../../docs/agents/contribution-flow.md).

## Roles

| Role | Model band | Stub | Owns |
| --- | --- | --- | --- |
| `architect` | Opus / Grok | [`roles/architect.md`](roles/architect.md) | Direction, contracts, planning |
| `lane` | DeepSeek Flash | [`roles/lane.md`](roles/lane.md) | Worktree imitation; push head SHA and stop |
| `reviewer` | Fable (or Opus/Grok-class) | [`roles/reviewer.md`](roles/reviewer.md) | Adversarial review of engine changes |
| `docs` | Gemini Flash | [`roles/docs.md`](roles/docs.md) | JA publish + EN docs finish; docs-only |
| `orchestrator` | Opus / Grok-class | [`roles/orchestrator.md`](roles/orchestrator.md) | Issue selection, CI watch, merge judgment |

I/O shapes: [`contracts/README.md`](contracts/README.md).

## v1 path (architect → lane)

Acceptance is [ADR-115 WD6](../../docs/adr/115-pi-multi-model-harness.md):
prove once, then open survey/docs.

1. **architect** (pi skill, Opus/Grok) fixes contracts for one scoped
   change (issue-shaped; Acceptance restated as checkable outcomes).
2. Spawn **N** disjoint worktree **lanes** (DeepSeek Flash-class) under
   those contracts.
3. Each lane implements, pushes, prints **head SHA**, and **stops**.
4. **orchestrator** (or external poll + resume) owns CI — lanes do not.
5. Separate **reviewer** adversarially judges the result.

Wire this with pi skills / prompt templates that bind models so free
`/model` switching cannot demote an architect task.

## Non-goals (v1)

- No full in-tree orchestrator yet; **takt is optional**.
- No parallel full-suite `make verify` on the host.
- Lanes do not own long-lived CI watchers / sleep loops.
- Issues remain the backlog (ADR-98); this package does not invent a
  second queue.
- Survey (B) and docs (C) flows wait until the architect→lane path works
  once.
- mise stays runtimes-only (ADR-115 WD5).
