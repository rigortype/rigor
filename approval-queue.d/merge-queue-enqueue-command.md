# Queue PRs through bin/land-pr and the enqueue mutation, keeping auto-merge off

- **PR:** [#2143](https://github.com/rigortype/rigor/pull/2143)
- **Issue:** none
- **Class:** process
- **Precedent:** none — sets one
- **Decided:** 2026-10-19

## Background

The merge-queue flow (#2138) told agents to queue a PR with `gh pr merge --merge`. On the first
real landing that failed with "Auto merge is not allowed": gh adds a PR to a merge queue through
GitHub's auto-merge API, and this repository has auto-merge turned off. Something else had to do
the queueing.

## Options and trade-offs

- **Turn auto-merge on.** `gh pr merge` then works as documented, with no new script. But it is a
  repository setting (serious, so it would wait for the maintainer), and it also lets anyone with
  write access arm a PR to merge itself whenever checks pass, including a Draft-discipline slip
  where an agent arms a PR before its review has finished.
- **Call the merge queue's `enqueuePullRequest` mutation, wrapped in `bin/land-pr`.** No setting
  changes and nothing merges without an explicit queueing step. It costs one more script in `bin/`
  to maintain, and the docs must name it instead of the familiar `gh` command.

## Decision

The script. It needs no settings change, keeps "queued" an explicit act taken after review, and
lets the script also refuse when `master` has no queue and wait on `isInMergeQueue`, the two traps
the review of #2138 found that agents get wrong by hand.

## To undo

Turn auto-merge on in the repository settings, point `contribution-flow.md`, `parallel-lanes.md`,
the release-prep skill and ADR-123 back at `gh pr merge <N> --merge`, and delete `bin/land-pr` and
`spec/tool/land_pr_spec.rb`.
