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

## The 2026-09-09 batch — ten PRs, all landed

Each ran in its own `bin/rigor-worktree` lane, opened Draft, and merged on the user's word with its
master run green. Nothing from this session is open.

Engine and CLI behaviour:

- [#869](https://github.com/rigortype/rigor/pull/869) closed #821 (reported by Nicolas Rodriguez):
  `sig-gen` and the probes built their environment with `libraries:` + `signature_paths:` only, so
  the rbs collection, the bundle's per-gem `sig/` and plugin signatures were invisible and the
  superclass-without-RBS skip guard declined every Rails model. New `Rigor::ProjectEnvironment`
  (`lib/rigor/project_environment.rb`) is the one build path for every non-`check` command, and
  `dependency_discovery_options(configuration)` the ONE spelling of the five discovery axes. Note:
  `sig-gen` now passes `source_files:`, so ADR-93 inline `#:` annotations count as existing
  declarations for it, as they do for `check`.
- [#888](https://github.com/rigortype/rigor/pull/888) closed #882: `rigor unused`'s
  `foreign_predicate` had the same omission, so a gem class the project reopens was reported as an
  unused candidate — reproduced through the CLI before the fix. `signature_paths: []` stays, for its
  own documented reason.
- [#865](https://github.com/rigortype/rigor/pull/865) closed #853: a block-level `break <value>` is
  unioned into the yielding CALL's type at `ExpressionTyper#call_dispatch_type_for`, above every
  dispatch tier, so the folds keep folding the no-break path. Residue: the `break` entry in
  `JUMP_NODES` is now conservative, not load-bearing — `5 | Dynamic[top]` where threading would
  reach `5 | 42`; lifting it moves every block carrying a `break`.
- [#866](https://github.com/rigortype/rigor/pull/866) closed #862 (decision option 1, on the issue):
  `Range[A]` also binds from a `Nominal[Range, [T]]` carrier when `T` is a Nominal or a union of
  them. Range-only — a Range is immutable and its element type is fixed at construction.
- [#868](https://github.com/rigortype/rigor/pull/868) closed #861: `clamp` on a plain `Integer` /
  `Float` receiver folds to the bracket. Exclusive end, mixed-class bounds, NaN and non-literal
  bounds decline; `i.clamp(1..)` renders as the existing alias `positive-int`.
- [#890](https://github.com/rigortype/rigor/pull/890) closed #806: `Registry#type_node_resolvers`
  read `plugin.manifest` unguarded during Environment CONSTRUCTION, so a raising manifest aborted
  every `Environment.for_project`. Manifests are now read once at registry construction behind a
  per-plugin rescue and join `load_errors`. The issue's premise held with one correction: the raise
  comes from `plugin.manifest`, not from `Manifest#type_node_resolvers` (a frozen `attr_reader`).
  No IoBoundary bypass and no #630-shaped stale-cache seam — a manifest is an in-memory object.
- [#891](https://github.com/rigortype/rigor/pull/891) closed #807: the cache schema marker is now
  published by rename, an EMPTY marker is treated as absent (never as "mismatch, clear the root"),
  and `read_entry` tolerates `ENOENT` between the existence check and the open. Two concurrent
  `rigor check` processes over one fresh `.rigor/cache` hit this.

Structural gates — the "a second build entry silently drops an input" family, now closed on all
three entries:

- [#864](https://github.com/rigortype/rigor/pull/864) closed #849 (`RbsLoader.build_env_for` vs the
  cache producer, plus the manual line that the probes never touch the persistent cache),
  [#880](https://github.com/rigortype/rigor/pull/880) (`Environment.for_project` vs
  `dependency_discovery_options`, covering every file that reaches `for_project` outside
  `ProjectEnvironment` itself), [#886](https://github.com/rigortype/rigor/pull/886) closed #876
  (`RbsDescriptor`'s digest vs `build_env_for`'s inputs — no undigested input was found).
- All three read the keyword list off the method itself, so a new keyword lands red rather than
  shipping. #886 additionally checks that each variation really changes the built environment: a
  variation that does not makes the digest assertion vacuous and reads exactly like a passing gate.
  `libraries: ["set"]` is vacuous on rbs 4.x (`Set` is core); `"pathname"` discriminates.

## Open threads this batch leaves

- The cross-process probe behind #891 lives on branch `probe-807-marker-race` (`tmp/probe-807/`).
  The in-process variants never reproduced — MRI essentially never preempts mid-`File.write` — so
  the atomic-write half is justified by that fork harness, not by a spec.
- #891 leaves one named window: on a genuinely stale root two constructors can still clear
  concurrently, costing recomputation only, with the crash consequence closed.
- #890 leaves `Registry#find` / `#ids` / `#source_rbs_synthesizers` and
  `CLI::PluginsCommand#plugin_matches_entry?` reading `plugin.manifest` unguarded. None runs during
  Environment construction, and guarding them raises its own question (what should `ids` return for
  a plugin whose id cannot be read?).

## How to enter

1. Nothing of this session's is open or uncommitted; its lane worktrees are removed. Other sessions
   were merging to master throughout, so re-derive any file:line at current HEAD.
2. The `ready-for-agent` queue is the backlog: `gh issue list --label ready-for-agent`. #790, #732,
   #728, #722, #720 and #710 are independent and unblocked.
3. Full gates run one at a time on this machine: two parallel `make verify` runs exhaust memory. A
   lane fleet serialises on `mkdir /tmp/rigor-verify.lock`; five lanes made the last one wait ~55m.
4. A merge whose master run is CANCELLED is usually a sibling session's push overtaking it, not a
   failure — confirm the commit is contained in master and watch the newer run.
