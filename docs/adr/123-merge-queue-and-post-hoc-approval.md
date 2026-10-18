# ADR-123 — Merge-queue landing and post-hoc approval

Status: **Accepted, 2026-10-19.** `ci.yml` answers the `merge_group` event and the flow documents
describe queue landing; the queue itself is the `master merge queue` ruleset on `master`,
enabled with the maintainer's approval on the same day. The approval queue (`approval-queue.d/`, gated by
`spec/docs/approval_queue_spec.rb`) and the `rigor-release-prep` ratification step land with
this ADR.

Archetype: mechanical / policy. Stakes: medium — it moves when a merge is checked, and which
decisions wait for the maintainer.

## Context

The v0.4.5 batch (about 40 PRs, #2062–#2130, up to four lanes) spent its landing time on two
serial points, neither of which bought correctness:

- **Re-gating before merge.** `parallel-lanes.md` step 7 sent a PR back through `bin/lane-push`
  whenever it or master had touched `lib/`, `sig/`, `data/` or `.rigor.dist.yml` since the branch's
  merge base: an engine change on one side can move the other side's specs through files neither
  shares. In an engine batch that is nearly every PR, so each merge waited on a rebase, a local
  `verify-changed` and a full CI run of the rebased head — about fifteen such cycles in the batch,
  each one changing the head SHA the review had pinned and racing the next merge to master.
  The check the rule wanted is the merged result; the rule approximated it by serialising.
- **Waiting on the maintainer.** Every ADR-119 gate row (a `producers.yml` or
  `admission_census.yml` entry, a provenance-pin move) and every open design choice stopped its
  lane until the maintainer answered, although every one of them in the batch was approved as
  proposed and most repeated an earlier approval's reason almost word for word.

[ADR-105](105-pr-landing-flow.md) rejected GitHub's merge queue because a `CONFLICTING` PR cannot
enter it. That still holds for textual conflicts, which ADR-105's fragments solve. The cost here is
the other one: semantic interaction between PRs that merge cleanly, which is exactly what a queue
checks.

## Decision

**1. PRs land through a merge queue on `master`.** `bin/land-pr` adds a green, reviewed PR to the
queue (`gh pr merge` cannot: it enqueues through the auto-merge API, which the repository keeps
off); the queue runs the full CI (`CI required`) on the PR merged onto `master` and the entries
ahead of it, and merges only when that run passes. A PR need not be rebased onto the latest `master`
before it is queued; it is re-pushed only when it is `CONFLICTING` or the queue drops it.
`bin/lane-push` still rebases at each push, which keeps conflicts surfacing early and costs nothing
extra. *Criterion: check the result that will land, once, instead of approximating it by re-gating
every branch in series.*

**2. Decisions below a stated line are made by precedent and ratified afterwards.** A decision
that is not *serious* (the list in `contribution-flow.md` § "Decisions and the approval queue") is
made by the coordinator, following the closest precedent, and lands with its PR. The PR carries an
approval-queue entry: why a decision was needed, the options and their trade-offs, the precedent
followed, and how to undo it. Serious decisions still wait for the maintainer before landing.
*Criterion: a decision waits up front only when undoing it after merge would be costly or visible
to users; everything else is reversible until a release ships it.*

**3. A release ships only ratified decisions.** `/rigor-release-prep` opens by reporting every
queue entry to the maintainer, in the maintainer's language, and asking them to ratify, revise or
revert each one. The release proceeds only when the queue is empty: ratified entries are deleted,
and a revised or reverted one is deleted by the PR that changes it. *Criterion: the release is the
point after which undoing costs users something, so it is where post-hoc approval must close.*

## Working decisions

- **WD1 — one file per decision.** Entries live in `approval-queue.d/<slug>.md`, not one
  `APPROVAL_QUEUE.md`: parallel PRs appending to one file conflict, and a conflicting PR cannot
  enter the queue (ADR-105's lesson, applied again).
- **WD2 — the entry travels with its PR.** Landing the change and recording the decision are one
  merge, so reverting the PR also removes the entry. A decision with no PR (a triage call) is
  recorded by a Markdown-only commit to `master`.
- **WD3 — tightening needs no entry.** A residue pin moving down, a check that now checks more, or
  an outcome a `ready-for-agent` issue already stated is not a decision anyone must ratify.
- **WD4 — the gate.** `spec/docs/approval_queue_spec.rb` holds the entry format (validator pinned
  by inline examples, as ADR-105 WD4) and fails on a `release/**` pull request while any entry
  remains. CI's change detection fails any run that changes `lib/rigor/version.rb` while an entry
  remains, the merge-queue run included, which no branch-name check can see. The serious list
  covers its own edits, so the line cannot be moved by precedent.
- **WD5 — the queue's settings.** Merge method "merge commit", required check `CI required`,
  groups of up to five, all entries green. The repository administrator role may bypass, which keeps
  Markdown-only commits straight to `master` possible; agents do not use `gh pr merge --admin`.
  Auto-merge stays off, so a PR enters the queue only when an agent or the maintainer queues it.

## Rejected alternatives

| Alternative | Why not |
| --- | --- |
| Keep step 7, narrow its path list | Engine PRs still touch `lib/` on both sides, so the serial re-gate stays the common case. |
| Require branches to be up to date | The same serialisation as step 7, enforced by GitHub instead of by agents. |
| Ask the maintainer per gate row, as before | Every row in the batch was approved as proposed; the wait bought no correction. |
| Ratify continuously, without a release gate | Nothing then forces the queue to drain, and an unratified decision could ship. |

## Consequences

- A merged PR's CI has run on what master became, not on an older base. The post-merge master run
  still runs, but a newer push can replace a pending one, so it is not a check on every merge.
- Every queued PR runs CI twice (on the PR and in the queue); grouping amortises the second run.
- A lane no longer stops for a precedented gate row; the maintainer reviews such rows in one
  sitting at release time, with the trade-offs written down.
- A rejected entry costs a follow-up PR before the release instead of a wait before the merge.

## Relationship to other ADRs

- [ADR-105](105-pr-landing-flow.md) — its rejection of the merge queue is answered above; the
  fragment mechanism is unchanged and is what keeps queued PRs mergeable.
- [ADR-98](98-development-flow-document-roles.md) — adds a fifth flow surface, the approval queue;
  the handoff, issue and changelog roles are unchanged.
- [ADR-50](50-release-engineering-and-stability-strategy.md) — release prep gains the ratification
  step; the release gate itself is unchanged.
- [ADR-119](119-discovery-fact-certainty.md) — its gate files keep their checks; only who approves a
  precedented row, and when, changes.
