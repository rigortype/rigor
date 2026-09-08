# PR #788 was merged under a stop instruction — Draft-discipline postmortem

Status: postmortem note, no design commitments. Observations taken against `master` at `518ed7b3`
(v0.3.8 published 2026-09-08); every fact below was verified against the GitHub API or the session
transcripts, not recalled.

- Date: 2026-09-08
- Sessions involved: the owner of [#788](https://github.com/rigortype/rigor/pull/788) ("Issue #776
  確認", main clone), the session that merged it ("high-priority-error-fix", worktree
  `high-priority-error-fix-bfa304`, the v0.3.8 coordinator), and a third session that assembled the
  first report ("Issue #778 triage").
- Follow-ups: [#814](https://github.com/rigortype/rigor/pull/814) (AGENTS.md rules),
  [#816](https://github.com/rigortype/rigor/pull/816) (skill examples create PRs `--draft`), and this note.

## What happened

1. 2026-09-07 16:32 / 16:44 JST — the user told #788's owning session "マージはストップ"; review
   continued in that session (the user's reviewer results pasted into chat, an Opus re-review run as
   a subagent). Nothing of this reached GitHub: reviews = 0, `reviewDecision` empty, the PR Ready,
   `mergeStateStatus` MERGEABLE.
2. 2026-09-08 04:20 JST — the user opened the coordinator session with "本日11時に向けてリリース
   したいので、それまでにマージする価値が高い issue を選び出して、worktree で並行稼動して解決したい"
   and went to sleep. No PR was named.
3. 04:23 — the coordinator found the main clone on `hkt-scan-failure-seam-784` with an uncommitted
   Round-11 diff (the owner's, awaiting its verify), read it as the same user's interrupted lane, and
   committed it as `fc86027b`. The owner's own commit attempt at 04:24 found "nothing to commit" and
   pushed the commit it had not written.
4. 04:25 — the owner started an Opus re-review of Round 11. 04:31 — the coordinator ran
   `make verify` (green), saw CI 13/13 green, and merged #788 (`341328ac`). The re-review was still
   running; its findings were docs-only and landed as `a6af7f24`, a direct master commit the owner
   pushed on the assumption the merge had been intended.
5. Six follow-up PRs (#800–#804, #808) and the v0.3.8 cut were built on that merge. No artefact was
   damaged: branch CI, the master run, and the release gate were green, and the pending re-review
   changed no code.

The merge was performed by the coordinator session. A first report attributed it to the triage
session; the transcript (`gh pr merge 788 --merge` at 04:31:11 in the coordinator's JSONL) settles it.

## Why the PR was not Draft, and why that was the whole failure

- #788 (like #783 and #787 before it) was created Ready, not `--draft`.
- The stop instruction was never translated into PR state (`gh pr ready --undo`). It lived in one
  session's conversation and, after context compaction, in a summary — invisible to every other
  session, and eventually to its own.
- Review happened off GitHub, so GitHub showed the only signal another session reads: open, green,
  Ready, unreviewed.
- The rule "a PR that must not be merged stays Draft" (user instruction, 2026-09-02) existed only in
  agent memory, where the index line had compressed it to "Draft-PR remote CI post-rebase". It was
  in no repository document. Of the 40 PRs since 2026-09-02, six went through Draft (the 09-03 review
  cycle); none since 2026-09-05.
- `master` has no branch protection and no ruleset, so a zero-review merge is mechanically allowed.
- AGENTS.md's "land audited+green PRs as you go" said nothing about whose PRs, and the coordinator's
  release framing turned "audited + green" into a merge trigger for a PR it did not own.

## What changed

- [#814](https://github.com/rigortype/rigor/pull/814) — AGENTS.md: every PR is created `--draft`
  and a non-mergeable PR stays Draft; `gh pr ready` only with an APPROVE on GitHub, CI green and no
  stop instruction; stop instructions become PR state at once; review verdicts are left on GitHub.
  The merge-as-you-go rule binds only the PRs a session opened, and another session's open PR or
  uncommitted tree is in-flight work. Bug-report fixes credit the reporter. The only release path is
  the user invoking `/rigor-release-prep`.
- The `gh pr create` examples in `rigor-dependency-update` and `rigor-release-prep` create the PR
  `--draft` and name the Ready step.
- Memory: the Draft rule is restored to the index line; both sessions recorded their part.

## Still open (the user's call)

A ruleset on `master` requiring one approving review would make steps 3–5 above structurally
impossible; it is repository configuration, independent of any agent's permission settings, which the
user chose to leave unchanged.
