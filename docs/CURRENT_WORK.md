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
Post-cut fragments ride under `changelog.d/` (#830, #844, #846, #848, #854, #857, #858, #859, #864,
#865, #866, #868, #869 among them). The next cut happens only when the user invokes
`/rigor-release-prep`.

## The 2026-09-09 five-lane batch — landed

Five issues, five worktrees (`bin/rigor-worktree`), five Draft PRs, each merged on the user's word
with its master run green, in this order:

- [#869](https://github.com/rigortype/rigor/pull/869) closed #821 (reported by Nicolas Rodriguez):
  `sig-gen` and the four probe commands built their environment with `libraries:` +
  `signature_paths:` only, so the rbs collection, the bundle's per-gem `sig/` and plugin signatures
  were invisible and the superclass-without-RBS skip guard declined every Rails model. New
  `Rigor::ProjectEnvironment` (`lib/rigor/project_environment.rb`) is the single build path for every
  non-`check` command; `ProjectEnvironment.dependency_discovery_options(configuration)` is the ONE
  spelling of the five discovery axes, used by the pool coordinator, the worker session and the LSP
  context too. Fail-soft is three-tiered (plugins → dependencies → RBS core + `sig/`). Behaviour
  note: `sig-gen` now passes `source_files:`, so ADR-93 inline `#:` annotations count as existing
  declarations for it, as they do for `check`.
- [#864](https://github.com/rigortype/rigor/pull/864) closed #849: a structural gate in
  `spec/rigor/cache/rbs_environment_spec.rb` reads `RbsLoader.build_env_for`'s keyword list off the
  method (past `RbsEnvMemo::Interception`) and proves `Cache::RbsEnvironment.compute` forwards every
  one from the loader's own readers, through a real `Cache::Store`. The manual now states that
  `type-of` / `type-scan` / `trace` / `annotate` never touch the persistent cache.
- [#865](https://github.com/rigortype/rigor/pull/865) closed #853: a block-level `break <value>` is
  unioned into the yielding CALL's type at `ExpressionTyper#call_dispatch_type_for`, above every
  dispatch tier; the folds keep folding the no-break path. Arms come from a separate thread-local
  value sink in `StatementEvaluator`, filtered by node identity; only bodies whose syntactic scan
  finds a block-level `break` pay the extra evaluation. #852's `next` join no longer declines when a
  `break` is co-resident. Residue: the `break` entry in `JUMP_NODES` (scope threading) is now
  conservative rather than load-bearing — `5 | Dynamic[top]` where threading would reach `5 | 42`;
  lifting it moves every block carrying a `break`, so it waits for a change that can measure that.
- [#866](https://github.com/rigortype/rigor/pull/866) closed #862 (decision: option 1, recorded on
  the issue): `RbsDispatch#range_element_binding` also binds `Range[A]` from a
  `Nominal[Range, [T]]` carrier when `T` is a Nominal or a union of Nominals; `untyped`, `Dynamic`
  and a type variable keep declining. Range-only, because a Range is immutable and its element type
  is fixed at construction — the #303 widening argument does not carry.
- [#868](https://github.com/rigortype/rigor/pull/868) closed #861: `clamp` on a plain `Integer` /
  `Float` receiver folds to the bracket (`ConstantFolding#try_fold_unbounded_clamp`): `i.clamp(1..9)`
  and `i.clamp(1, 9)` are `Integer[1..9]`, `f.clamp(0.0..1.0)` is `Float[0.0..1.0]`. Exclusive end,
  mixed-class bounds, NaN bounds and non-literal bounds decline. `i.clamp(1..)` renders as the
  existing alias `positive-int`. Rebased once after #866: both added rows to
  `spec/integration/fixtures/range_endpoint_acceptance.rb` and its snapshot.

Open from the batch:

- [#880](https://github.com/rigortype/rigor/pull/880) — Draft, CI green, spec-only: the #864 gate's
  sibling for the other build entry. `spec/rigor/project_environment_spec.rb` reads
  `Environment.for_project`'s keywords and asserts every one not on an explicit non-discovery
  allowlist is spelled by `dependency_discovery_options`, pins each value to its configuration
  reader, and checks the call sites (behaviourally where cheap, at source level for the worker
  session / LSP context / sig-gen collectors). Merge on the user's word.
- [#876](https://github.com/rigortype/rigor/issues/876) (`ready-for-agent`): `RbsDescriptor` digests
  inputs rather than calling `build_env_for`, so #864's gate cannot see it; pin its digest to every
  environment-changing keyword.

Operational lessons from the batch:

- Five lanes serialise on ONE machine-wide `make verify` lock (`mkdir /tmp/rigor-verify.lock`); the
  last lane waited ~55 min for it. Another session's gate does not take the lock — two full gates
  did overlap once and survived, but do not count on it.
- A subagent that "holds for the monitor notification" after a background gate is dead, not
  waiting: finish its lane by hand (verify log → push → Draft PR → watch).
- ADR-105's fragment grammar wants the line to start with `- `; a lane whose full gate ran before
  its fragment existed (PR first, fragment second) only learns that on CI.

## How to enter

1. Nothing of this session's is uncommitted. Six lane worktrees under `../rigor-wt/` were removed;
   `gate-project-environment-discovery-keywords` (#880) and `fix-861-clamp-unbounded-receiver`
   (merged) may still exist — remove after #880 lands.
2. Next: land [#880](https://github.com/rigortype/rigor/pull/880) on the user's word, then
   [#876](https://github.com/rigortype/rigor/issues/876) (`ready-for-agent`). After that the
   `ready-for-agent` engine bugs [#807](https://github.com/rigortype/rigor/issues/807) (cache store
   `repair_writable_marker!` race) and [#806](https://github.com/rigortype/rigor/issues/806)
   (unguarded manifest reads in `Plugin::Registry`) are independent and small.
3. Full gates run one at a time on this machine: two parallel `make verify` runs exhaust memory.
