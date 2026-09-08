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

**v0.3.8 is published.** The release PR (`release/0.3.8`, `Bump up version to 0.3.8`) merged on
2026-09-08; the user ran `rake release` from `master`: tag `v0.3.8` at `ffb456b0`, the GitHub Release,
and `rigortype 0.3.8` on RubyGems all exist. `Rigor::VERSION` is `0.3.8`; `changelog.d/` holds only its
README; `[Unreleased]` is empty. The next cut happens only when the user invokes `/rigor-release-prep`
explicitly — a release date or goal mentioned in a task is not that invocation (ADR-50 § WD5).

## What v0.3.8 fixed (the 2026-09-07 triage batch)

Landed, each audited + `make verify` green + CI green before merge: #788 (#784, #793), #800 (#795),
#803 (#798), #802 (#791), #801 (#785), #804 (#799), #808 (#805 — found by the #785 lane's review and
fixed the same morning). Filed from the lanes' reviews, still open:
[#806](https://github.com/rigortype/rigor/issues/806) (`Plugin::Registry#type_node_resolvers`
unguarded at Environment construction — latent, no reachable trigger). Deliberately left out of the
cut: #790 (harness-side), #792 / #794 / #789 (design or latency calls), #796 (its conformance half
landed in #788 round 11; the per-file-analysis half is a snapshot-persistence design).

## Ranked next engineering work

1. **[#775](https://github.com/rigortype/rigor/issues/775)** — recover `rigor check lib` allocations
   toward the v0.3.6 18.8M. Unchanged from the previous handoff; still the top perf item.
2. `make check lib` prints one `def.return-type-mismatch` warning at
   `lib/rigor/inference/expression_typer.rb:274` (`return_type_for`). Pre-existing on the v0.3.7
   line (three lanes confirmed it independently against their base commit); the gate exits 0
   because it is a warning, but AGENTS.md says the self-check MUST stay clean. Fix at the root.
3. **[#807](https://github.com/rigortype/rigor/issues/807)** — `spec/rigor/cache/store_spec.rb:628`
   is a CI flake with a real cause: 16 threads each build a `Store` on a fresh root and race
   `repair_writable_marker!`, so one can read a torn `schema_version.txt` and `clear_cache_root!`
   under a sibling's `binread`. Seen once on #804's shard 1; 25 local repetitions clean.

## Pipeline notes (each earned by an incident)

- **Every lane that edits a binding doc row conflicts with every other one.** The `rbs.coverage.*`
  and `rbs_extended.*` rows of `docs/type-specification/diagnostic-policy.md` are single very long
  lines; six PRs in one morning each re-conflicted on them after every merge to `master`. Resolve
  by taking master's line and re-applying your own phrases (a token-level three-way merge script
  did it mechanically), verify with `git diff --word-diff origin/master HEAD -- docs` that only your
  phrases differ, and re-read the merged sentence — one master sentence (`a6af7f24`) became false
  the moment #803 landed and had to be dropped in the same PR.
- **`Environment.default` is a process-wide `@default ||=` singleton.** A spec that stubs a shared
  build and then demands it on `.default` is order-dependent in a binpacker worker (the #784 seam
  spec went red once) and, run first, poisons every later `.default` user. Build a fresh
  `for_project` environment in any spec that stubs or degrades a memoised build.
- **A worktree SHARES `.git`, and submodules are NOT populated in one.** Adding a checkout in a
  worktree is fine; `git submodule deinit` there deregisters it for the MAIN CLONE.
- **Serialize the full gate across parallel lanes** with a `mkdir /tmp/rigor-verify.lock` mutex —
  parallel `make verify` runs have OOM-killed this host. Kill a lane's redundant re-verify once its
  PR has merged; it holds the mutex for four minutes that the next lane needs.
- **GitHub closes only the FIRST `Fixes #N` in a comma list.** One `Fixes #N` per line.
- **Verify the INTEGRATED master after a batch.** No single PR's CI sees the combination.
