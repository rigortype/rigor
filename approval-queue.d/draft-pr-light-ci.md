# A Draft PR's CI runs only change detection, lint and docs-check; the full CI starts at gh pr ready

- **PR:** [#0](https://github.com/rigortype/rigor/pull/0)
- **Issue:** none
- **Class:** process
- **Precedent:** [ADR-123](../docs/adr/123-merge-queue-and-post-hoc-approval.md)
- **Decided:** 2026-11-13

## Background

GitHub Actions runs about 20 jobs at once for this repository, and one full CI run is about 20 jobs.
Each PR cost three full runs: the Draft push, the review fix-up push and the `merge_group` run. On
2026-11-12, six merges took 45 `merge_group` runs and 69 `pull_request` runs, and runners, not
implementation or review time, set the landing rate. The user delegated CI-load measures to the
coordinator, which settled this design; nobody had decided whether a Draft PR needs the full gate.

## Options and trade-offs

- **Keep the full gate on every PR push.** Every reviewed head is fully checked before review ends,
  at three full runs a PR.
- **Light gate on drafts, full at `gh pr ready` (taken).** A Draft push runs change detection, `lint`
  on a code PR and `docs-check` on a no-code PR; `CI required` is skipped, so a draft never reads
  green to `bin/land-pr` and never attests. The full run starts at `gh pr ready` and on every later
  push, and the queue runs as before. A PR costs two full runs (one, when the queue reuses the ready
  run's attestation). The gate trade-off: the review no longer sees the specs, self-check, the
  acceptance gates or the engine-allocation summary in CI; it reads the light run plus the lane's
  local `make verify-changed`. A defect those jobs catch surfaces after `gh pr ready`, costing a fix
  push and another full run, and the advisory summaries are read on the ready run. What lands is
  still fully checked, by the ready run and by `merge_group`.
- **Skip the PR run entirely and rely on the queue.** One full run a PR, but a failure would surface
  only in the queue, where it drops the PR and can hold the entries batched with it, and the queue's
  attestation reuse would never apply.

## Decision

The light draft gate. It keeps `CI required` as the only landing signal and keeps two full checks of
what lands, and ADR-123's criterion (check the result that will land, once, rather than re-gating
every step) favours dropping the checks of intermediate draft heads. `bin/land-pr` and
`land-when-green.sh` read the newest `CI required` check run, since a head now carries the draft
run's SKIPPED one beside the full run's.

## To undo

Remove the `full` output from the `changes` job in `.github/workflows/ci.yml`, the
`needs.changes.outputs.full == 'true'` term from each heavy job's `if:`, and the `full != 'false'`
term from `required`; keep `ready_for_review` in the trigger types or drop it too. Restore
contribution-flow.md steps 1, 2, 3 and 6, parallel-lanes.md steps 6 and 7, and the ADR-123
amendment. The newest-run rule in `bin/land-pr` and `land-when-green.sh` is harmless to keep.
