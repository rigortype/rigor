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
and `rigortype 0.3.8` on RubyGems all exist. `Rigor::VERSION` is `0.3.8`; `[Unreleased]` is empty;
`changelog.d/` holds the post-cut fragments — #810, [#813](https://github.com/rigortype/rigor/pull/813)
(the Ractor-pool twin of #798) and [#819](https://github.com/rigortype/rigor/pull/819) — all riding
the next cut. The next cut happens only when the user invokes `/rigor-release-prep` explicitly — a
release date or goal mentioned in a task is not that invocation (ADR-50 § WD5).

## The 2026-09-08 types-and-comments session (three Draft PRs, all gates green)

The maintainer redefined what a type may be in Rigor's own tree — **a type Rigor did not produce or
check is never written down** — and what Rigor ships to agents: a skill that routes "I am about to
write a type" to the oracle instead of the source. Everything is landed as Draft, in this merge order:

1. [#822](https://github.com/rigortype/rigor/pull/822) `type-comment-corpus` — 1,121 YARD type slots
   emptied (313 files, comment lines only), `AGENTS.md` § "Types and Comments", the gate
   `spec/docs/type_shaped_comments_spec.rb`, ADR-107 (Accepted) and ADR-108 (**Proposed** until #826
   lands; then a docs-only commit flips its status line and index row).
2. [#826](https://github.com/rigortype/rigor/pull/826) `type-oracle-skill` — `skills/rigor-type-oracle/`,
   the `AGENTS.md` fragment `rigor-project-init` installs (Phase 8a), catalogue wiring. Rebase onto
   #822 first; its README index row and ADR-108 status will need the dedupe.
3. [#827](https://github.com/rigortype/rigor/pull/827) `check-fail-on-warning` — `rigor check
   --fail-on=SEVERITY`; `make check` / `check-plugins` run with `--fail-on=warning`. Fixes #812.

Follow-ups filed, all `ready-for-human`: [#823](https://github.com/rigortype/rigor/issues/823)
(an annotated method's siblings), [#824](https://github.com/rigortype/rigor/issues/824) (`sig/` vs
inline precedence), [#825](https://github.com/rigortype/rigor/issues/825) (`sig/` provenance gate).
#779 is closed as superseded.

## The 2026-09-08 perf session (#775)

The v0.3.7 allocation regression is attributed and its mechanical half recovered in
[#819](https://github.com/rigortype/rigor/pull/819) (`perf-775-allocation-levers`, 15 levers +
note, **Draft until an APPROVE on GitHub**): `rigor check --no-cache lib` 36,492,665 → 21,933,996
allocations (−39.9%), diagnostics byte-identical on `lib` after every commit and on redmine at the
end, `make verify` green. Measurement record:
[`docs/notes/20260908-v037-allocation-regression-attribution.md`](notes/20260908-v037-allocation-regression-attribution.md);
instruments on the unmerged branch `perfbench-harness-775` (`tool/perf775/`). Short form: the
17M was per-file typing, not the environment build, the target or the rbs bump; no single merge
caused it (#547 +4.1M, #556 +2.3M, #753 +1.8M, #664 +1.7M, then a tail); the per-call driver was
the 21-member `Rigor::Type::t` alias re-translated at every call site and re-normalised at every
join.

## Ranked next engineering work

1. **Land #819, then close [#775](https://github.com/rigortype/rigor/issues/775)'s gate.** Once it
   is on `master`, trigger `release-gate.yml`, download the `bench-baseline-*` artifact and commit
   its targets as `bench/baseline.json` (expect ≈22M allocations, ≈+16% over v0.3.6's 18.85M) with
   a `note` that points at the attribution note — the remainder is the v0.3.7 line's inference
   volume (64% more user-method return inferences, 68% more body evaluations), recorded rather
   than blessed. Until then `make bench-perf` prints the `STALE` notice, not a failure.
2. **The design-seam remainder** — [#820](https://github.com/rigortype/rigor/issues/820): the
   measured-and-left items (a rebuilt `Scope` + merged locals `Hash` per binding, a
   `RuleWalk::Context` per visited node, an `ExpressionTyper` per `Scope#type_of`, a
   `StatementEvaluator` per `sub_eval`, `receiver_descriptor`'s triple per dispatch, lazy
   `AcceptsResult` reasons). Each is a design change, not a mechanical removal; size before
   choosing.
3. **[#812](https://github.com/rigortype/rigor/issues/812)** — `make check` exits 0 on a warning,
   so "MUST stay clean" is unenforced. The `def.return-type-mismatch` warning on
   `ExpressionTyper#return_type_for` is fixed at the root by #810 (`make check` is warning-free);
   it sat on `master` across #800–#809 because of this hole. Sibling finding
   [#811](https://github.com/rigortype/rigor/issues/811): negative-equality narrowing cannot prune
   a symbol literal from a mixed union — a type-model change, not a quick fix.
4. **[#807](https://github.com/rigortype/rigor/issues/807)** — `spec/rigor/cache/store_spec.rb:628`
   is a CI flake with a real cause: 16 threads each build a `Store` on a fresh root and race
   `repair_writable_marker!`, so one can read a torn `schema_version.txt` and `clear_cache_root!`
   under a sibling's `binread`. Seen once on #804's shard 1; 25 local repetitions clean.
5. [#806](https://github.com/rigortype/rigor/issues/806) — `Plugin::Registry#type_node_resolvers`
   unguarded at Environment construction (latent, no reachable trigger).

## Pipeline notes (each earned by an incident)

- **Measure allocations, not wall, and per lever.** `GC.stat(:total_allocated_objects)` over an
  in-process `rigor check --no-cache` reproduces Linux CI to under 1% on this host and is
  deterministic run to run; wall on the loaded laptop is not. One commit per lever, each measured
  against its parent with the `--format json` output diffed against master — a lever that changes
  a byte is not a lever.
- **`RIGOR_BUDGET_TRACE` counters drift ~1% across hours** on one host (42,285 → 42,728 infer
  entries for the same master tree; each run deterministic, diagnostics byte-identical). Compare
  them only back-to-back, engine against engine, in one script.
- **A hot-path helper must allocate nothing.** A `(0...n).all?` Range walk in overload selection
  cost 0.5M objects (2.3%) on its own; a counter captured by a literal block costs zero.
- **zsh `pipefail` + `grep -q` drops the big merges.** `git diff --name-only … | grep -q PAT`
  fails whenever grep exits before git finishes writing (SIGPIPE), so a "touches non-Markdown"
  filter silently kept 13 of 127 merges. Count with `grep -c`.
- **Every lane that edits a binding doc row conflicts with every other one.** The `rbs.coverage.*`
  and `rbs_extended.*` rows of `docs/type-specification/diagnostic-policy.md` are single very long
  lines; resolve by taking master's line and re-applying your own phrases, verify with
  `git diff --word-diff origin/master HEAD -- docs`, and re-read the merged sentence.
- **`Environment.default` is a process-wide `@default ||=` singleton.** A spec that stubs a shared
  build and then demands it on `.default` is order-dependent in a binpacker worker. Build a fresh
  `for_project` environment in any spec that stubs or degrades a memoised build.
- **A worktree SHARES `.git`, and submodules are NOT populated in one.** `git submodule deinit`
  there deregisters it for the MAIN CLONE. `bin/rigor-worktree` clones the bundle copy-on-write;
  a checkout of an older commit runs on the gems already in `vendor/bundle` (every rbs 4.x is
  there), no `bundle install` needed.
- **Serialize the full gate across parallel lanes** with a `mkdir /tmp/rigor-verify.lock` mutex —
  parallel `make verify` runs have OOM-killed this host.
- **GitHub closes only the FIRST `Fixes #N` in a comma list.** One `Fixes #N` per line.
- **`gh pr checks --watch` armed right after a push exits 1 with "no checks reported"** — GitHub
  has not registered the run yet. Poll until `gh pr checks` lists a check, then watch.
- **Verify the INTEGRATED master after a batch.** No single PR's CI sees the combination.
