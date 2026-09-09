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

**v0.3.8 is published** (`Rigor::VERSION` is `0.3.8`, `[Unreleased]` empty as of 2026-09-09).
Post-cut fragments ride under `changelog.d/`. The next cut happens only when the user invokes
`/rigor-release-prep`.

## In flight — another session owns these, hands off

- [#885](https://github.com/rigortype/rigor/pull/885) — Draft, closes #878 (lambda literal's local
  writes bound to its body scope). Not yours to merge.
- Worktree `../rigor-wt/fix-882-unused-discovery-axes` is checked out at master and being worked:
  [#882](https://github.com/rigortype/rigor/issues/882), `rigor unused`'s `foreign_predicate` builds
  without the discovery axes (a #821-shaped gap) and `prewarm_rbs_cache_for_pool` spells the five
  axes literally instead of splatting `ProjectEnvironment.dependency_discovery_options`.

## CI wall time — landed, and the lever is now elsewhere

Workflow **371s → ~220s** ([#863](https://github.com/rigortype/rigor/pull/863),
[#867](https://github.com/rigortype/rigor/pull/867)); shard jobs 339/172/117s → 176/182/175s, with
their actual makespans inside 4.4s of each other.

The shard *partition* was never the problem — LPT already cut all three slices to 534.6s of weight
apiece and shards 2/3 hit the twelve-worker floor exactly. The spread was two other things:

- 145s of it was `Run pool-runner spec` + `Run plugin integration tests`, steps pinned
  `if: matrix.shard == 1` on the shard that also held the heaviest file. Both are outside the
  sharded set (`binpacker.yml`'s `test_exclude`), so they are now the peer job `excluded-specs`.
- `runner_spec.rb` (5,955 lines, ~167s) exceeded the per-worker budget and set the matrix makespan
  alone. Split at its one seam — attributing the timing file's **per-example** records to top-level
  `describe`s showed `CheckRules diagnostics` was 65.2% of the file and the next block 9.4% — into
  `runner_check_rules_spec.rb`. `--dry-run --format json` proves 355 examples and identical full
  descriptions on both sides.

**`Self-check (cold)` (172–196s) is now the critical path**, co-equal with the Tests shards. Further
spec-side work buys ~nothing at the workflow level; size that job before proposing anything here.

Residue worth knowing, all of it already commented at the code:

- binpacker weighs a file by summing every `[file, name]` entry its history holds and never drops a
  vanished test, so a split charges the old path forever. `ci.yml`'s cache key carries a manual
  generation token (`binpacker-timings-v2-…`) — **bump it whenever a spec file is split, renamed, or
  deleted**. Preserving example names does not help; the lookup is per-path.
- A cache-key bump costs **two** cold runs: caches saved on a feature branch are invisible to
  master, so the first master run after the merge is cold too and is what seeds the namespace. Do
  not read a partition's balance from a run whose restore step logged "Cache not found".
- `make test-binpacker` now does `mkdir -p tmp` because `Report#write` has no mkpath and `tmp/` is
  gitignored — the report write silently depended on the timing cache restoring into that directory,
  and the first genuine miss failed the whole matrix with all 3,357 of a shard's examples passing.

## Also landed 2026-09-09 by the parallel lanes

[#880](https://github.com/rigortype/rigor/pull/880) (the `Environment.for_project` discovery-keyword
gate, sibling to #864), [#881](https://github.com/rigortype/rigor/pull/881),
[#883](https://github.com/rigortype/rigor/pull/883) (rooted-spelling version guard folds),
[#884](https://github.com/rigortype/rigor/pull/884) (arity declines on a receiver whose surface is
not enumerable), [#886](https://github.com/rigortype/rigor/pull/886) (closed #876 — `RbsDescriptor`'s
digest pinned to every environment-changing `build_env_for` input).

## How to enter

1. Nothing of this session's is uncommitted; master is at the #886 merge and green.
2. Leave #885 and the `fix-882-unused-discovery-axes` worktree alone unless their session hands over.
3. Next unclaimed work: [#807](https://github.com/rigortype/rigor/issues/807) (cache store
   `repair_writable_marker!` races a concurrent constructor and can clear the root under a reader)
   and [#806](https://github.com/rigortype/rigor/issues/806) (unguarded manifest reads in
   `Plugin::Registry#type_node_resolvers`) — both `ready-for-agent`, independent, and small.
4. Full gates run one at a time on this machine: two parallel `make verify` runs exhaust memory, and
   the lanes serialise on a machine-wide lock (`mkdir /tmp/rigor-verify.lock`). Another session's
   gate does not take that lock, so check `ps` before assuming a lane is idle.
5. `../rigor-wt/` also holds `fix-876-rbs-descriptor-digest-gate` (merged) and
   `perfbench-harness-775`; the first is safe to remove.
