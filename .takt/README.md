# TAKT workflows (Rigor)

Project workflows for evaluating ADR-115 long quality-stable loops.

## `rigor-ready-for-agent`

Flow: **plan → develop → ship (Draft PR)**. The lane ends at the Draft PR. Waiting for CI, the
independent adversarial review and the landing belong to the coordinator
([`parallel-lanes.md`](../docs/agents/parallel-lanes.md) steps 6 to 8): a model-run CI watch aborted
lanes whose CI was only still running, and the in-lane review did not replace the independent one.

```bash
agents/pi-harness/scripts/takt-enqueue.sh 2576 2742   # one task per issue, issue text embedded
takt run                                               # needs TAKT_ANTHROPIC_API_KEY
agents/pi-harness/scripts/takt-status.sh -l            # live table
agents/pi-harness/scripts/takt-ledger.sh               # per-task outcome and failed step
```

After the review of a lane's PR:

```bash
agents/pi-harness/scripts/takt-lane-push.sh <worktree>         # push a fix-up commit from the lane's worktree
agents/pi-harness/scripts/land-when-green.sh <pr> <full-sha>   # wait for CI, then bin/land-pr; run in the background
```

CI runners, not lanes or reviews, bound the throughput (about one full CI run flows at a time), so
the intake is pull-based:

- `takt-enqueue.sh` refuses while open `takt/` PRs plus unfinished tasks plus the new ones exceed
  `TAKT_MAX_UNLANDED` (default 5). `takt run` stays at two lanes.
- Review each lane when its Draft PR appears, not in batches. Put every fix-up in one push, and mark
  the PR ready only after that push; do not push after ready unless CI or the queue failed it.
- Keep at most three takt PR runs in flight. A run superseded by a newer push can stay queued and
  hold its concurrency group: cancel it with `gh run cancel`.

Commit and push an edit under `.takt/` before `takt run`: takt copies the root's `.takt/` into each
worktree, and an edit that is not on `origin/master` would differ from the lane's base.

Validate:

```bash
takt workflow doctor rigor-ready-for-agent
```

Provider and model per persona are bound in `.takt/runtime.yaml`.
