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

**v0.3.8 is published** (tag `v0.3.8` on `ffb456b0`, RubyGems `0.3.8`, GitHub Release; verified
2026-09-08 by `git ls-remote --tags`, the RubyGems API and `gh release view`). `Rigor::VERSION` is
`0.3.8`; `changelog.d/` holds the fragments of the next cycle.

## The 2026-09-08 perf session (#775)

The v0.3.7 allocation regression is attributed and its mechanical half recovered in
[#819](https://github.com/rigortype/rigor/pull/819) (`perf-775-allocation-levers`, 15 levers +
note): `rigor check --no-cache lib` 36,492,665 → 21,933,996 allocations (−39.9%), diagnostics
byte-identical on `lib` after every commit and on redmine at the end, `make verify` green.
Measurement record: [`docs/notes/20260908-v037-allocation-regression-attribution.md`](notes/20260908-v037-allocation-regression-attribution.md);
instruments on the unmerged branch `perfbench-harness-775` (`tool/perf775/`). Short form: the
17M was per-file typing, not the environment build, the target or the rbs bump; no single merge
caused it (#547 +4.1M, #556 +2.3M, #753 +1.8M, #664 +1.7M, then a tail); the per-call driver was
the 21-member `Rigor::Type::t` alias re-translated at every call site and re-normalised at every
join.

## Ranked next engineering work

1. **Close [#775](https://github.com/rigortype/rigor/issues/775)'s gate.** After #819 is on
   `master`, trigger `release-gate.yml`, download the `bench-baseline-*` artifact and commit its
   targets as `bench/baseline.json` (expect ≈22M allocations, ≈+16% over v0.3.6's 18.85M) with a
   `note` that points at the attribution note — the remainder is the v0.3.7 line's inference
   volume (64% more user-method return inferences, 68% more body evaluations), recorded rather
   than blessed. Until then `make bench-perf` prints the `STALE` notice, not a failure.
2. **The design-seam remainder** — [#820](https://github.com/rigortype/rigor/issues/820): the
   measured-and-left items (a rebuilt `Scope` + merged locals `Hash` per binding, a
   `RuleWalk::Context` per visited node, an `ExpressionTyper` per `Scope#type_of`, a
   `StatementEvaluator` per `sub_eval`, `receiver_descriptor`'s triple per dispatch, lazy
   `AcceptsResult` reasons). Each is a design change, not a mechanical removal; size before
   choosing.
3. `make check lib` prints one `def.return-type-mismatch` warning at
   `lib/rigor/inference/expression_typer.rb:274` (`return_type_for`). Pre-existing on the v0.3.7
   line; the gate exits 0 because it is a warning ([#812](https://github.com/rigortype/rigor/issues/812)),
   but AGENTS.md says the self-check MUST stay clean. Fix at the root.
4. **[#807](https://github.com/rigortype/rigor/issues/807)** — `spec/rigor/cache/store_spec.rb:628`
   is a CI flake with a real cause (16 threads race `repair_writable_marker!` on a fresh root).
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
- **Verify the INTEGRATED master after a batch.** No single PR's CI sees the combination.
