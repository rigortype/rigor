<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Hard cap: 120 lines, enforced by spec/docs/agent_index_spec.rb. Compress, do not append.
- Verify a claim before carrying it forward, by the thing that decides rather than a proxy —
  including claims in THIS file. Three sessions running, its own pointers have been wrong.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones.
If this file disagrees with an ADR, the CHANGELOG, or an issue, this file is the one that is wrong.

## Where the cycle stands

**v0.3.7 is on `master` and not published.** [#774](https://github.com/rigortype/rigor/pull/774) merged
2026-09-05 (`e131c4a3`). `Rigor::VERSION` is `0.3.7`. There is no `v0.3.7` tag, no RubyGems push, and
no GitHub Release. `bundle exec rake release` still needs an explicit request (ADR-50 § WD5; it tags,
pushes, and publishes).

The next session that is asked to publish: `git switch master && git pull`, then
`nix … develop --command bundle exec rake release` from a clean tree at the merge commit.

## Ranked next engineering work

1. **[#775](https://github.com/rigortype/rigor/issues/775)** — recover `rigor check lib` allocations
   toward the v0.3.6 18.8M. Blessed at the cut so the release could land: Linux CI measured
   36,171,454 allocations (+91.9%) and 417,716 KB RSS (+32.4%) against ~9% more `lib` lines.
   Mastodon OSS sweep on the same run stayed inside its thresholds. Do not recalibrate again without
   measuring *which* v0.3.6..v0.3.7 change paid the extra 17M.
2. Then re-rank. The 2026-09-05 queue's top three are closed; what is left is second-tier.

## Work in flight elsewhere — check before starting

**[#768](https://github.com/rigortype/rigor/pull/768) (#718) and [#769](https://github.com/rigortype/rigor/pull/769)
(#713) are open as DRAFTS with commits**, in `~/repo/ruby/rigor-wt/`. They are someone else's lane; do not
merge them. Coordinate before touching `spec/integration/precision_snapshot_spec.rb`, the
`spec/integration/snapshots/` goldens, or `lib/rigor/environment/rbs_loader.rb`.

## Pipeline notes (each earned by an incident)

- **A worktree SHARES `.git`, and submodules are NOT populated in one.** `references/ruby` is empty in a
  fresh worktree, so a gate reading it silently SKIPS — verify such a gate EXECUTED, not merely that it was
  green. A worker's `git submodule deinit` there deregistered the submodule for the MAIN CLONE. Adding a
  checkout in a worktree is fine; removing a registration never is.
- **Serialize the full gate across parallel lanes** with a `mkdir /tmp/rigor-verify.lock` mutex — parallel
  `make verify` runs have OOM-killed this host.
- **GitHub closes only the FIRST `Fixes #N` in a comma list.** Put each `Fixes #N` on its own line. Run an
  issue's repro before ranking; `OPEN` does not mean LIVE.
- **Verify the INTEGRATED master after a batch.** No single PR's CI sees the combination.
- **`merge=union` on `CHANGELOG.md` is silent.** A `[Unreleased]` entry that lands on `master` during a
  release cut folds under the wrong heading. Fragments in `changelog.d/` cannot conflict; do not skip them.
