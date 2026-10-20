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

*Amended 2026-10-19 (maintainer's decision; mechanism revised 2026-10-20, #2154).* A `pull_request`
run into `master` that passes `CI required` attests the tree it tested, the head merged with `master`
at that moment. A queue run whose merged tree has such an attestation reuses that result and skips
the suite, so the result that will land is still checked once. Only a run into `master` attests: a
Markdown-only run skips the code suite because its base's code already passed CI, which holds for
every code change on `master` and not for another branch.

The attestation is a signed artifact attestation (Sigstore, `actions/attest-build-provenance`) whose
subject is the tree, not a check run. Any workflow of the repository can write a check run of any
name, and a run into another branch executes that branch's workflow. A writer could therefore emit a
matching check from a PR into a branch of their own and close that PR before queueing. Neither a
commit's PR list nor a workflow run's PR list excludes this: the API omits closed PRs from the first
and recomputes the second from the PRs open when it is read. The attestation's certificate is issued
by GitHub and names the commit whose workflow file ran. The queue reuses a result only when that
commit's tree is the queued tree, the run was a `pull_request` run, and the signer was that commit's
own `ci.yml`. The workflow that attested is then the workflow that lands, and it attests only a run
into `master` that passed `CI required`. A run into another branch either ran another tree, whose
attestation is ignored, or ran the queued tree's own `ci.yml`, whose condition refuses a base other
than `master`; the tree check relies on that condition. The tree binds the files, not inputs outside
them (actions referenced by tag, the runner image, repository variables), as with any CI result. A
fork's run gets no signing token and does not attest.

A head equality would not do either: a check run attaches to the head, while the run tested a
merge, which differs when the PR's base was another branch or `master` was rewound. In the v0.4.5
cycle every landing queued a head that already contained `master`, and the queue reran an identical
11-minute CI each time. Any other tree (`master` moved, a batch whose tree no PR run tested) and any
lookup or verification that fails run the full CI as before. The approval-queue check still runs in
every queue run.

*Amended 2026-10-20 (maintainer's decision, #2157).* The `CI required` check that the queue waits on
is to be pinned to GitHub Actions (`integration_id: 15368`) in the `master merge queue` ruleset
(25351003) by the maintainer; until that change is applied, any source can satisfy it. This amendment
records the decided configuration and does not change the ruleset. Once pinned, a status posted through
the commit status API with a personal token cannot satisfy the check.

The pin leaves one gap. A check run or commit status posted from another workflow of this repository
also runs as GitHub Actions (a `GITHUB_TOKEN` status is attributed the same way), so it could satisfy
`CI required` too. The model therefore trusts writers: anyone with write access to the repository is
trusted not to post such a check. The 2026-10-19 attestation amendment above still closes the
reused-result path; writer trust covers the direct-posting path, and neither makes the other redundant.

Re-evaluate this when the set of writers grows beyond the maintainer and trusted agents. The option then
is a dedicated GitHub App that posts the required check from a `workflow_run` workflow. That workflow
must run only from the default branch, and the App's private key must sit where only master's workflow
can read it (for example, an environment restricted to the default branch), so a branch in a fork or a
writer's own branch cannot reach it. The ruleset would then require only that App's check. The workflow
first verifies the run's `event` is `merge_group` and its `conclusion` is `success`; it then checks that
`head_sha` matches the queued entry and that `path` is `.github/workflows/ci.yml`. The option is
deferred until that trigger fires.

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
  gives every merge commit pushed to `master` its own run (per-SHA group, #2140). When the queue
  merges several entries in one group (`max_entries_to_merge: 5`), master moves in one push, so only
  the tip gets a push run; the intermediate merge commits' status is their merge-queue `CI required`
  run. That is the expected behaviour, not yet verified.
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
