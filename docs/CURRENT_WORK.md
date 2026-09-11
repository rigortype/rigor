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

## v0.3.9 is cut and mid-publish — READ THIS BEFORE ANYTHING ELSE

`master` carries `Bump up version to 0.3.9` (`0c6c6ae0`, PR #989 rebase-merged): `Rigor::VERSION`
is `0.3.9`, `CHANGELOG.md` holds the sealed `## [0.3.9] - 2026-09-12` section, `changelog.d/` is
empty again, `README.md`'s status line names 0.3.9. The v0.3.9 milestone is closed (34 issues).

**The gem is NOT published yet.** The remaining steps, in order:

1. `gem push` — built and waiting at `~/repo/ruby/rigor-wt/publish-0.3.9/rigortype-0.3.9.gem`
   (a clean worktree at `0c6c6ae0`). RubyGems demands an MFA OTP, so this is the USER's command;
   an agent must not handle the code.
2. `git tag v0.3.9 0c6c6ae0` (annotated, matching v0.3.8) and `git push origin refs/tags/v0.3.9`,
   only after RubyGems accepts the gem.
3. `bundle exec rake release:github` from `master` — it needs the tag locally and extracts the
   `## [0.3.9]` section verbatim as the release body.

Do not re-run `/rigor-release-prep`, do not re-cut, and do not open `[Unreleased]` entries as
anything but `changelog.d/` fragments. If the push already happened, verify with
`gem list -r rigortype` and `git ls-remote --tags origin v0.3.9` before believing this file.

## What the cut cost, and the two gate findings behind it

The first release PR (#983) went red on both advisory gates, and both were real:

- **The OSS sweep caught a release-blocking crash `make verify` could not.** #961's compact-header
  re-anchoring rewrote each `header_nestings` BUCKET as if it were a chain, so every Mastodon file
  reported an `internal analyzer error` (1,073 rows against a 468 threshold). Filed #984, fixed by
  #985; the sweep then matched v0.3.8 row for row. Rigor's own `lib` has no compact header, so the
  rename pass never ran under `make check`, and the PR's single-file fixtures never reached the
  cross-file merge that raised. **An engine change to the discovery fold needs a multi-file fixture
  and an OSS sweep before a cut, not at it.** The review also found the colliding-bucket merge is
  still last-wins and fold-order dependent: #986 (v0.4.0).
- **The perf gate's RSS band is noise-wide.** `peak_rss_kb` read +10.5 % against v0.3.8 while
  allocations fell 35 %. Attributed in `docs/notes/20260912-v039-rss-attribution.md`: diffuse across
  ~95 merges with no step, live slots after GC only +3.5 %, so it is transient peak from fewer minor
  GCs, not retention. `bench/baseline.json` is recalibrated from the gate run and both halves are
  recorded together. The band is +10 % over a SINGLE sample whose host spread is ±7 %: #987 (v0.4.0).

A 34-project, 306-run crash check over the survey corpus (`docs/notes/20260912-v039-oss-corpus-crash-check.md`)
found no crash on the swept surface, and records what it did NOT sweep.

## Open threads

- **#424** keeps only its WD16 half (`Propagator.propagate` at gitlab scale). The per-project bound
  is measured and closed: `docs/notes/20260910-effect-collection-profile.md` shows the ≤ 5 % budget
  is unreachable without changing what collection proves, which is a No-Go input for #409.
- **#697** waits on **#660** (where open-receiver membership lives). Do not add a fourth protection
  route; #902 shipped only the loud-not-silent half and a spec pins that the FP still fires.
- Filed by the reviews of this cycle, all `v0.4.0`: #980 (a dropped `definition-build-failed` row
  stays dropped across warm runs), #986, #987.
- `gh issue list --label ready-for-agent` is 13 items; `v0.4.0` holds 20 and is the pre-1.0 break
  (ADR-50 WD5/WD7: `int<a,b>` removed, effects default-on, plugin-contract changes needing a corpus
  FP diff). `v0.4.x` holds the line-level backlog.

## How to enter

1. Working tree clean, no open PR. Worktrees: `publish-0.3.9` (keep until the gem is pushed) and
   `perfbench-harness-775` (pre-existing, not this cycle's).
2. The lane contract that carried ~110 PRs this cycle: one worktree per lane, targeted specs plus
   rubocop only, remote CI as the gate, `git push` then END. No CI polling from a lane — fifteen
   lanes with `gh run watch` loops exhausted the 5,000/hour GitHub API budget twice; poll once a
   minute per PR via `statusCheckRollup`. To add a commit to a lane's branch, reset to the remote
   tip and cherry-pick: rebase-then-push is non-fast-forward and force is blocked.
3. **Review before merge paid for itself.** A Fable adversarial-review subagent per PR (brief in the
   session scratchpad's `REVIEW.md`: false positives first, then unsound precision, contract drift,
   vacuous gates, blast radius) sent three PRs back with findings their own gates had missed.
4. Three traps every engine lane hit: the `sig/` provenance residue pin moves whenever a hand-written
   line lands OR inference changes what sig-gen would emit; a new precision fixture needs its golden
   (`UPDATE_SNAPSHOTS=<fixture>`); a spec that enables a bundled plugin by gem name is order-dependent
   unless it registers the class itself (`Plugin.unregister!` plus a no-op `require`).
