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

## What the 2026-09-22/23 `-> untyped` audit sessions landed

All merged, CI green, adversarial review (Fable/Grok) Approved:

- [#1169](https://github.com/rigortype/rigor/pull/1169) — incidental-return APIs → `void`.
- [#1170](https://github.com/rigortype/rigor/pull/1170) — `untyped`/`void`/`top` theory note
  (`docs/notes/20260922-untyped-void-top-return-contracts.md`) + first classification of 77 sites.
- [#1171](https://github.com/rigortype/rigor/pull/1171) — `dump_type`/`assert_type` generic
  pass-through.
- [#1174](https://github.com/rigortype/rigor/pull/1174) → `a2387d66` — batch 1: 22 `-> untyped`
  returns named precisely; also added the `Rigor::SigGen` shell decl that un-quarantined
  `sig/rigor/sig_gen/skip_reason_catalog.rbs`.
- [#1176](https://github.com/rigortype/rigor/pull/1176) — `instance_definition` false positive.
- [#1178](https://github.com/rigortype/rigor/pull/1178) → `0765b45b` — #1173 ancestor fallback for
  RBS-known modules; also corrected `includes_of` to runtime MRO order (include is last-wins across
  statements), SCHEMA 26→27, `declared_before_object?` + resiting guards in
  `ExternalAncestorResolution`.
- [#1179](https://github.com/rigortype/rigor/pull/1179) → `e890b0dc` — #1175: compound ivar writes
  (`||=`/`&&=`/`op=`) now seed the class-ivar accumulator; ADR-58 WD5 implemented; CI self-check
  runs `--fail-on=warning` (the `unit_scan.rb:560` warning is gone; `make check` is green on master).
- [#1180](https://github.com/rigortype/rigor/pull/1180) → `b0dd3cc3` — batch 2: Manifest/Runner/
  Loader/Narrowing/etc. tightened; `produces` is `Array[Symbol]` (post-`to_sym`),
  `source_rbs_synthesizer` deliberately stays `untyped` (multi-shape WD6/WD12 outcome).

Earlier `queue-release` merges (`#1158`–`#1162`, `79fa99cf`/`9fd4b6d4`/`19c2af59`) are all landed;
no open PRs at handoff time.

## Waiting on the maintainer

Nothing new. Long-standing `ready-for-human` backlog is unchanged (`gh issue list --label ready-for-human`).

## What is worth picking up next

- **#1181** — Class B sig-coverage backlog: add `sig/` for `Effects::*`, `Analysis::ProjectScan`,
  `Plugin::Macro::*`, `HktRegistry::*`, `ProtocolContract`, `AdditionalInitializer`,
  `Environment::Reflection`, `RuleWalk::CollectorDriver`, `Baseline::{Bucket,DriftRow}`, `Cache::*`,
  reporter duck types. Smallest slice first: `Baseline::{Bucket,DriftRow}` (two Structs, unblocks
  `Baseline#audit → Array[DriftRow]`). Process: `rigor sig-gen --print` provenance first per
  `docs/agents/type-authoring.md`.
- **#1177** — `OptimisticOrigin` lost across method boundary (needs-triage; a
  `rigor-wt/optimistic-origin-nil-predicate` directory exists on disk but is NOT a registered
  worktree — verify before reusing).
- **#1168** — ready-for-agent: straight-line multi-assign index targets.
- **sig-gen skip batch** — #1148–#1157 (element-type / Data-member / endless-def gaps); the honest
  fix per `type-authoring.md` is a sig-gen gap issue, several already filed.

## Where the worktrees are

All `rigor-wt/*` worktrees from this session were pruned after merge. The older
`/Users/megurine/repo/ruby/worktrees/rigor/pi-worktree-*` set belongs to the `queue-release` lane;
its PRs have landed, so the worktrees are prunable if idle (`git worktree remove` refuses on
`references/` submodule checkouts — `rm -rf` + `git worktree prune`).
