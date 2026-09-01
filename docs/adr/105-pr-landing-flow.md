# ADR-105 — PR landing flow: sequential merges and changelog fragments

Status: **Accepted, 2026-09-01.** Both halves land with this ADR: the sequential-landing norm is in
`AGENTS.md` § "Commit and PR Etiquette", and the `changelog.d/` fragment mechanism ships here (the
directory, the gate `spec/docs/changelog_fragments_spec.rb`, and the consolidation step in the
`rigor-release-prep` skill). The `merge=union` attribute from
[PR #500](https://github.com/rigortype/rigor/pull/500) is retained as prep-time insurance; the
expectation it encoded is corrected below.

## Context

[PR #500](https://github.com/rigortype/rigor/pull/500) marked `CHANGELOG.md merge=union` so that
parallel branches appending `## [Unreleased]` entries stop conflicting, and verified exactly that —
against **local git**. The operative layer was github.com: GitHub's PR-mergeability and merge
computation ignore `.gitattributes` merge drivers, union included. Landing the 2026-09-01
opacity-sweep campaign made the cost concrete: a 19-PR queue, each PR carrying one entry at the same
`### Fixed` anchor, where three PRs read CONFLICTING against a single previously-merged entry before
any queue merge happened, and every merge re-dirtied all remaining PRs. The queue drained as ~17
serial local-merge → push → full-CI → merge cycles of ~8–12 minutes each. Two independent causes
compounded:

- **A shared hot region.** Every PR appends at one anchor of one file, so any two PRs overlap
  textually — and GitHub serializes them regardless of the local merge driver.
- **A deferred queue.** The PRs accumulated all session instead of landing as each went green, a
  deviation from the standing merge-as-you-go authorization (2026-08-01). Deferral is what
  manufactured the stacks (#543, #557, #558 were stacked only because their bases had not landed)
  and the sibling conflicts: a branch forked from post-merge `master` cannot conflict with its
  predecessors.

## Decision

Two rules, one per cause.

**1. Sequential landing (the serial case).** A session producing serially-audited changes lands
each PR as soon as its gates pass (`make verify`, the corpus gate where applicable, CI green) —
attempt the merge, and surface a denial immediately rather than queueing. The next branch forks
from post-merge `master`; the merge's CI overlaps with developing the next item. *Criterion:
batching and stacking are reserved for changes the user must adjudicate as a set; deferral
manufactures stacks and sibling conflicts.*

**2. Changelog fragments (the parallel case).** An `[Unreleased]` entry lands as a new file
`changelog.d/<section>/<slug>.md` — one bullet line in the existing entry grammar (subsystem label,
full PR link), with the section encoded by the subdirectory (the six Keep a Changelog types,
downcased). Release prep consolidates fragments into `[Unreleased]` and deletes them at the cut;
`CHANGELOG.md` itself is written only by release prep. *Criterion: a file every PR must append to
is a serialization point on GitHub regardless of local merge drivers — convert per-PR appends into
per-PR file additions, which cannot conflict.*

## Working decisions

- **WD1 — section as subdirectory.** `changelog.d/fixed/…`, `changelog.d/added/…`, …: the section
  is lintable from the path, no content parsing.
- **WD2 — slug from the branch name.** Unique before the PR exists (the PR number is not). The PR
  link still goes in the entry text right after `gh pr create`, exactly as before — and the
  fragment gate now checks the link mechanically, which the direct-edit flow only ever trusted.
- **WD3 — `merge=union` stays.** Harmless, and still correct for the one writer left (release prep
  racing a straggler master-direct commit).
- **WD4 — the gate lives in `spec/docs/`** (both `make docs-check` and the suite run it), with the
  validator pinned by inline examples so the grammar holds even while the directory is empty.
- **WD5 — the honest trade.** Fragments keep sibling PRs MERGEABLE, so they merge with CI that ran
  against an older `master`. The repo already does not require up-to-date branches, so this widens
  an accepted window rather than opening a new one; the standing integrated-`master` verify after a
  batch is the net.

## Rejected alternatives

| Alternative | Why not |
| --- | --- |
| `merge=union` alone (PR #500) | Falsified at the operative layer: GitHub ignores merge drivers for PR mergeability. |
| Auto-drain bot (rebase + push each DIRTY PR) | Keeps the Θ(N) serialized CI cost, and keep-both code conflicts need human judgment — a mechanical resolver corrupted `expression_typer.rb` during this very campaign. |
| Reconstruct entries at the cut | Re-litigates #500: wording and PR link are cheapest at landing; v0.3.6's reconstruction dominated its prep. |
| GitHub merge queue | A CONFLICTING PR cannot enter the queue; the root cause is untouched. |
| Commit-trailer changelog (GitLab style) | Returns link derivation to cut-time enumeration — the exact cost #500 removed. |

## Consequences

- Parallel PRs stay MERGEABLE through a drain; the serialized update+CI cycles disappear for the
  conflict class that hit every PR pair. Genuine code overlaps still conflict and still deserve
  hand resolution.
- The PR link is mechanically gated at landing instead of trusted.
- `[Unreleased]` reads empty mid-cycle; the pending view is `ls changelog.d/*/`.
- One more file per PR; release prep gains one mechanical consolidation step.
- Meta-lesson, binding future workflow changes: **verify at the layer that enforces the
  behaviour** — a two-throwaway-PR probe on github.com would have falsified #500's premise in
  minutes, where local-merge verification could not.

## Relationship to other ADRs

- Partially supersedes the expectation set by PR #500: the attribute survives, but the "parallel
  entries no longer conflict" claim is corrected to local-only.
- [ADR-98](98-development-flow-document-roles.md) — the changelog's document role is unchanged;
  only the landing mechanism moves.
- [ADR-50](50-release-engineering-and-stability-strategy.md) — release flow; the consolidation
  step is specified in the `rigor-release-prep` skill.
