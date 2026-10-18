# Approval queue

Decisions an agent made on its own, waiting for the maintainer to ratify them. The rule for which
decisions may be made this way, and which must wait, is
[`docs/agents/contribution-flow.md`](../docs/agents/contribution-flow.md) § "Decisions and the
approval queue"; the reasoning is [ADR-123](../docs/adr/123-merge-queue-and-post-hoc-approval.md).

- **One file per decision**, `approval-queue.d/<slug>.md`, added by the PR that carries the
  decision (the branch name makes a good slug; add a suffix when one PR carries several). One file
  each keeps parallel PRs from conflicting, as `changelog.d/` does.
- **Ratification happens at release.** `/rigor-release-prep` reports every entry to the maintainer
  and asks them to ratify, revise or revert it. A ratified entry is deleted in the release branch;
  a revised or reverted one is deleted by the PR that changes the decision. A release ships only
  when this directory holds nothing but this README.
- **Gate**: `spec/docs/approval_queue_spec.rb` checks the format below, and fails a `release/**`
  pull request while any entry remains.

## Entry format

Write for a reader who was not in the session: the maintainer reads these weeks later, one after
another. Each section is prose or a list, never empty.

```markdown
# One sentence stating what was decided

- **PR:** [#2140](https://github.com/rigortype/rigor/pull/2140)
- **Issue:** [#2121](https://github.com/rigortype/rigor/issues/2121)
- **Class:** gate-row
- **Precedent:** [#2093](https://github.com/rigortype/rigor/pull/2093)
- **Decided:** 2026-10-19

## Background

What the change was doing, and why it needed a decision nobody had made: the gate that stopped,
the question the issue left open.

## Options and trade-offs

Each option considered, with what it costs and what it buys.

## Decision

The option taken and why the trade-off favours it, including how closely the precedent fits.

## To undo

What a revert or follow-up would change, and anything that has come to depend on the decision.
```

- **PR** — the PR that lands the decision, as a full link; `none` only for a decision committed
  straight to `master` (a triage call), with the commit named under "Decision".
- **Issue** — the issue the decision belongs to, as a full link, or `none`.
- **Class** — one of:
  - `gate-row`: an allow-list row in a gate file (`producers.yml`, `admission_census.yml`, a sig-gen
    marker, `gap_issues.yml`) or a residue pin moving up;
  - `open-choice`: a behaviour or spec reading the issue left open;
  - `scope`: splitting, deferring or closing part of an issue;
  - `process`: a change to the development flow, its tooling or its documents.
- **Precedent** — the merged PR (or the entry still in this queue) whose decision this one follows,
  as a full link; or `none — sets one` when no earlier decision fits.
- **Decided** — the date, `YYYY-MM-DD`.
