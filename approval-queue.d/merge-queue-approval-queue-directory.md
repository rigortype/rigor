# Keep the approval queue as one file per decision in approval-queue.d/, not one APPROVAL_QUEUE.md

- **PR:** [#2138](https://github.com/rigortype/rigor/pull/2138)
- **Issue:** none
- **Class:** process
- **Precedent:** [#562](https://github.com/rigortype/rigor/pull/562)
- **Decided:** 2026-10-19

## Background

The maintainer asked for decisions made without them to be recorded in "a file like
`APPROVAL_QUEUE.md`" and reported at release time. The record has to land with the PR that makes
the decision, so several PRs in flight at once each add to it.

## Options and trade-offs

- **One `APPROVAL_QUEUE.md`.** One file to open and read top to bottom. But every PR appends at the
  same place, so two PRs in flight conflict; a conflicting PR starts no CI and cannot enter the
  merge queue, so each such pair costs a rebase and a re-run, the serial cost this revision exists
  to remove.
- **A directory, one file per decision.** Parallel PRs add different files and never conflict, and
  reverting a PR removes its entry with it. Reading the queue takes a directory listing instead of
  one file, which release prep does for the maintainer anyway.

## Decision

A directory, `approval-queue.d/`, named and laid out like `changelog.d/`. #562 made the same choice
for changelog entries after GitHub was shown to ignore `merge=union` for PR mergeability, and the
reason carries over unchanged.

## To undo

Concatenate the entries into one `APPROVAL_QUEUE.md`, point `spec/docs/approval_queue_spec.rb`,
the release-prep skill and `contribution-flow.md` at it, and accept that parallel PRs adding
entries will conflict.
