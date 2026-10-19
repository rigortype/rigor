# The merge queue reuses a PR's CI only on a signed attestation from the tree's own workflow

- **PR:** [#2155](https://github.com/rigortype/rigor/pull/2155)
- **Issue:** [#2154](https://github.com/rigortype/rigor/issues/2154)
- **Class:** process
- **Precedent:** [#2151](https://github.com/rigortype/rigor/pull/2151)
- **Decided:** 2026-10-20

## Background

#2151 lets a merge-queue run skip the suite when the queued tree carries a successful `Tested tree
<tree>` check on the PR head. #2154 showed that a writer can forge that check. A PR into a branch of
their own executes that branch's `ci.yml`, which can emit any check name. They then queue a PR into
`master` with the same head.

The issue proposed a guard based on PR association. Two reviews and the live API ruled it out:

- `commits/{sha}/pulls` omits a closed PR. A writer who closes the PR into their branch passes the
  check.
- A workflow run's `pull_requests` is recomputed from the PRs open when it is read. Run 39311143438
  executed head `25b8fa0f1` and lists head `1f6950be1`.
- The run object has no field naming its base, so no API answer proves which base a run tested.

## Options and trade-offs

- **Revert #2151's reuse.** Certainly safe. Every landing reruns about 11 minutes of identical CI.
- **Guard on PR association or run provenance (the issue's proposal, then the first revision).**
  Cheap, and bypassable as above.
- **A ledger written by a `pull_request_target` workflow.** Writers can cancel or delete those runs,
  and the absence of a record proves nothing.
- **Sign the tested tree with an artifact attestation and accept only a signer whose own commit has
  the queued tree.** GitHub issues the certificate, and it names the workflow commit
  (`workflow_sha`), the event and the signer workflow. A run into another branch ran a commit merged
  with another base, so its tree differs.
  - Costs: the `tested-tree` job gains `id-token: write` and `attestations: write`, plus a
    dependency on `actions/attest-build-provenance@v4` and Sigstore's public-good instance. The
    `changes` job trades `pull-requests: read` and `checks: read` for `attestations: read`.
  - A fork's run gets no signing token and does not attest, so a fork PR always runs the full queue
    CI.
  - Any verification failure, including Sigstore being unreachable, runs the full CI.

## Decision

Signed attestation. It keeps #2151's saving and rejects the forgery by construction rather than by
an absence check. Every way it fails runs the full suite, which is #2151's own rule (never skip on
doubt). The maintainer asked for an improvement before a revert. A design consultation and the
adversarial review of #2155 chose this option; the review rounds are recorded in that PR.

## To undo

There are two ways back:

- Revert #2155 to return to #2151's check-run reuse. That design is forgeable, as above.
- Delete the `merge_group` block in the `changes` job and the `tested-tree` job to drop reuse
  entirely.

Nothing else depends on the attestations. Attestations already published stay in the repository's
attestation store, and they are harmless once nothing reads them.

A separate gap is not covered here. The ruleset requires a `CI required` context from any source.
Whether a writer can post it on a merge-group commit before the real run finishes is being tracked
as its own issue.
