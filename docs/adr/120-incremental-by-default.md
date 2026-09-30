# ADR-120 — `--incremental` as the default local `check` route

Status: **Proposed, 2026-10-01.** Answers #120 for the maintainer. Accepting it flips nothing: the
default changes only in the PR that clears WD7's gates, after WD8's preview.

Grounding: the warm-journey measurements on #1507, two runs of `engine-warm.yml` at `e0c6b3bcb`, the
maintainer's 2026-07-18 ruling on #120, and the stale-answer issues filed during the reviews of #1545,
#1552 and #1577.

## Context

**The gap.** One edit to a Rails application of about 1,400 files costs a default `rigor check`
almost a cold run, because ADR-45's run-result cache is all or nothing. `--incremental` answers most
edits in a tenth of that time.

The table gives median wall time on CI Linux: Mastodon v4.5.10, `app lib config`, three runs per
step, each a fresh process, every warm answer equal to a `--no-cache` run. The leaf file is
`about_controller.rb` and the hub file is `account.rb`. The first figure in each cell comes from
[run 36746631018](https://github.com/rigortype/rigor/actions/runs/36746631018) (an empty method
added), the second from [run 36746637783](https://github.com/rigortype/rigor/actions/runs/36746637783)
(a comment line appended).

| route | null | leaf edit | hub edit | cold prime (one run) |
| --- | ---: | ---: | ---: | ---: |
| default | 0.29 / 0.24 s | 24.3 / 20.3 s | 24.2 / 19.9 s | 27.6 / 25.9 s |
| `--incremental` | 0.30 / 0.24 s | 2.6 / 2.1 s | 18.7 / 2.6 s | 35.0 / 28.4 s |

The everyday loop is the leaf and hub columns, and today only users who found an opt-in flag get
them. Adding a method to the hub still re-checks every ancestry dependent (#1538).

**The 2026-07-18 ruling named three blockers. Where each stands:**

1. **The two fast paths competed.** Resolved by #1552 (ADR-45 WD2): a null `--incremental` run is
   now served engine-free.
2. **No gate measured the path.** `engine-warm.yml` now measures it, but `bench/baseline.json` still
   measures only the cold full path.
3. **The incremental tail prints less.** Still true. It lacks the JSON `config_warnings` block,
   CI-native annotations, the `--baseline-strict` verdict, cache eviction and `--coverage`, and it
   ignores `--explain` (#1533). Run stats and trace appendices are a separate question (WD4).

**Since then, the campaign found that most stale-answer bugs on the incremental path share one
cause.** The incremental snapshot decides whether it is still valid from a hand-picked list:

- `IncrementalSnapshot.fingerprint` covers the engine, the configuration, the roots,
  `./Gemfile.lock`, `rbs_collection.lock.yaml` and a *configured* `signature_paths:`.
- Beside it are per-file digests of the analysed set, and three gates: ADR-88's fact digest, the
  effects identity, and #1536's source-RBS gate.

ADR-45 WD2's incremental run slot, by contrast, is record-and-validate. The part of its chain that a
recheck carries forward rather than re-derives (`Runner#baseline_dependency_rows`) holds the
signature tree and its roots, the auto-detected `sig/` included. It also holds the
discovered-but-not-analysed files with a listing row per discovery root, and the `pre_eval:` files
outside the analysed set. Its key holds the lockfiles as `RunCacheKey` reads them. The snapshot
lacks each of these:

| Issue | The input the snapshot does not see |
| --- | --- |
| #1532 | the configured or auto-detected lockfiles |
| #1554 | an auto-discovered `sig/` directory |
| #1560 | a discovered-but-not-analysed file |
| #1585 | a `pre_eval:` file outside the analysed paths |
| #1553 | a file a plugin read through its `IoBoundary` while analysing a now-cached file |

Patching each input into the fingerprint is how the list came to miss them. A list kept beside the
code misses the next input, the failure mode that kept #1531's reviews going round.

The other stale answers have other causes and are gated separately (WD7 G1):

- #1459: a missing dependency edge.
- #1541: a null recheck in pool mode.
- #1561: a stat-then-digest race.
- #1583: rechecks never widen discovery the way #684 widens a full run.
- #980: dropped rows persisted across warm runs.
- #1525: `--no-cache` still replays the snapshot.

## Decision

**`rigor check` takes the incremental route by default on local whole-project runs, once the
snapshot is validated by the record-and-validate chain rather than a list beside it, and once both
routes print the same thing.** The route may change. The answer may not: it must equal a
`--no-cache` run of the same tree.

The criterion, reusable for any cache that would become a default route:

1. Its validity is read from the recorded inputs, not from a list.
2. It ends in the same output tail.
3. A run that no later run reuses does not pay for it.

### Working decisions

- **WD1 — The snapshot is validated by the carried chain.** The snapshot owns the chain's carried
  part: `baseline_dependency_rows` (`BaselineRows#owned` and `#pinned`) and the per-file reads
  (`by_file`). The slot copies them from it, so a slot evicted under `cache.max_bytes` cannot turn a
  warm project cold.
  - The `observed` and `derived` rows (plugin `#prepare` and producer reads, `watch:` globs, template
    files and globs, existence rows) are re-derived on every run, as today. A template edit keeps
    its current cost.
  - **Any stale carried row triggers a full baseline, per-file reads included.** ADR-45 records that
    a value memoised in an ivar, through `producer_value`, or by the ADR-84 return memo reaches later
    files without a read of their own. So re-analysing only the file credited with a read is
    unsound (#1553). Narrower responses are later amendments, each with its own proof. For per-file
    reads, that proof needs a plugin-declared contract that the plugin keeps no cross-file memo.
  - **A snapshot written without a complete chain is not reusable**, and the next run is a full
    baseline. Today the chain is missing under a worker pool, with no recording, and when a plugin
    makes a read that is credited to no file (one from a thread it started).
  - **WD1 lands together with pool support.** Workers send their credited reads back, as
    `PoolCoordinator` already does with dependency records, and the main process builds the baseline
    part, so a pool run records a complete chain. Without this, WD1 would make every explicit
    `--incremental --workers N` run cold.
  - A run with an uncredited read records that in the same marker as opacity (WD5).
  - **The chain moves into the snapshot.** It is carried inside the snapshot rather than from the
    previous slot. `IncrementalSession#carry_chain`'s snapshot-identity check retires, and so does
    ADR-45's case of a slot that stays off indefinitely after a pool run, a `--no-cache` run or a
    cache restore.
  - Validating the `pinned` rows, the signature files of the gems and the engine, costs stats on
    every recheck. G3 measures that cost.
  - **Gate:** a spec enumerates the row kinds the carried part emits, taken from the builders
    themselves. Each kind needs an example that primes, edits that input in a new process, and
    asserts the warm answer equals a `--no-cache` run. A new row kind without an example fails the
    spec.
- **WD2 — The snapshot key.** `IncrementalSnapshot.fingerprint` keeps the engine identity, the
  schema, the configuration and the roots. It reads the lockfiles through
  `RunCacheKey.lockfile_entries` in place of `./Gemfile.lock` (#1532). It drops the
  `signature_paths:` digest, which WD1's rows replace (#1554). ADR-88's fact digest, the effects
  identity and #1536's gate stay as they are.
- **WD3 — Digests are checked per file.** Each per-file digest is taken between two stats of the
  file, and a file whose stat moved is re-read (#1561, option 1). The slot's `WriteGuard` stays the
  slot's own. It takes no mark on filesystems without fine timestamps, and gating the snapshot on it
  would leave those users with no snapshot at all.
- **WD4 — One tail.** The default miss path, the plain slot hit, the incremental path and the
  incremental slot hit end in one tail. That tail writes the `config_warnings` block, CI-native
  annotations, the `--baseline-strict` verdict and `--explain` output (#1533). Eviction runs on the
  miss paths, the default miss and the full incremental path. A slot hit defers it, as today, so a
  null run pays for no walk of the store.
  - Only a run that built the environment prints the run stats block and trace appendices: a
    default miss or a cold incremental baseline. A run served from a slot, or a warm recheck, prints
    neither, as a plain hit already does. Their RBS counts describe an environment such a run never
    built.
  - The `--incremental warm / cold` banner and ADR-88's fact-surface notes print only when
    `--incremental` or `incremental: true` asked for the route. A default run's stderr stays as it
    is today.
  - **Gate:** extend #1552's CLI spec. Every output-affecting flag and format goes through each
    route, and must produce byte-identical stdout, the same exit code, and stderr that is equal once
    timings and the stats block are normalised away.
- **WD5 — `incremental: auto | true | false`.** The CLI switch `--[no-]incremental` beats the
  environment variable `RIGOR_INCREMENTAL` (same values), which beats the key. The variable is a
  route-only override: the spec helper pins it, as it pins `RIGOR_CI_DETECT`, so specs take the
  same route everywhere. The default becomes `auto` at the flip. `auto` takes the incremental route unless one of the
  following holds:
  - **The run is excluded from the incremental slot probe** (`incremental_run_hit_eligible?`):
    - an editor buffer;
    - `--no-cache`, which under any setting also means no snapshot is read or written (#1525);
    - `--explain`, until #1533 lands;
    - `--coverage`, since a report run gains nothing from it;
    - `--cache-stats` or a `RIGOR_*_TRACE` probe;
    - a worker pool, until workers send their reads back (WD1).
  - **The run names file or directory arguments** other than the configured `paths:`, compared
    after normalising both as `IncrementalRunSlot.normalize_roots` does (`./lib` is `lib`). A pre-commit
    hook or an editor's "check this file" would otherwise pay for recording and replace the project
    snapshot with one that nothing reuses. Serving a subset run from the project snapshot is
    deferred until a measurement asks for it.
  - **The environment is CI.** The predicate is `CiDetector`'s provider table with
    `RIGOR_CI_DETECT` ignored, because that switch silences annotations and must not move a job's
    route. A generic truthy `CI` counts, so a dev container that sets it takes the full route unless
    `RIGOR_INCREMENTAL` says otherwise. A CI job usually starts cold, and it is where merge decisions are made. On its current
    route it pays for no recording and changes nothing at the gate of record. A job that persists
    `.rigor/cache` opts in with `incremental: true`.
  - **Effects are enabled** (ADR-103). The session writes no slot then, so null runs would lose
    their engine-free path.
  - **The previous run found an opaque plugin** (ADR-88, #924), **or a read credited to no file**
    (WD1). Opacity is known only after `#prepare`, so a marker in the store records it, and `auto`
    reads it on the next run. The marker is keyed like the fingerprint, by the configuration and
    the plugins' identity. Every run that prepares plugins rewrites it, the full route included
    (`PluginFactFingerprint.from_registry`), so a marker cannot outlive the plugin it names. The
    first run pays. An opaque project re-analyses everything on every incremental run, and today
    after a recheck as well, so the full route is strictly cheaper for it.
- **WD6 — Other readers of the snapshot.** The language server primes from it
  (`ProjectContext`), and `rigor coverage --protection --mutation` loads it across root sets
  (`Protection::MutationCache`). Both validate it through WD1 and WD2, and neither may keep
  trusting a snapshot those decisions call stale.
- **WD7 — Gates for the flip PR.** The default changes in one PR, and only when all of these hold:
  - **G1 (soundness):** WD1–WD3 have landed with their specs. Every stale-answer or output-parity
    issue open against `--incremental` at the time of the flip is closed. Today that means #980,
    #1459, #1525, #1532, #1541, #1553, #1554, #1560, #1561, #1583 and #1585. #1565 is stale on both
    routes and does not block.
  - **G2 (parity):** WD4 has landed, and `--verify-incremental` compares order as well as the set
    (#1542).
  - **G3 (cost):** on `engine-warm.yml`, every warm journey (null, leaf, hub) is no slower with
    `incremental: true` than with `false`. Both are set explicitly, because the job runs on CI, where
    `auto` would take the full route. With `RIGOR_INCREMENTAL=auto` and the CI predicate bypassed, a
    file-argument run takes the full route and is no slower than today. On `engine-wall.yml`, a cold incremental
    run into an empty cache directory costs at most 10% more than a cold plain run, on Mastodon and
    on Rigor's own `lib`. The comparison uses the lower of five runs and total allocations, since the
    ±7% CI spread (ADR-50) is too wide for one sample. Today's single samples are +27% and +10%
    (table above).
  - **G4 (perf gate):** `bench/baseline.json` gains a target for a cold incremental run into an
    empty cache directory, under ADR-50 WD4, so the cost of recording cannot creep back.
- **WD8 — Preview, then the flip at a minor.** An `incremental-by-default` bleeding-edge feature of
  kind `:behaviour` (ADR-50) makes `auto` the default early, as `effects-on-by-default` did for
  ADR-103 WD15. The project's own evidence is G3's CI runs, not dogfooding: `make check` runs
  `--no-cache`, and `bleeding_edge: true` also turns effects on, which WD5 excludes. The flip lands
  at the next minor after G1–G4, with a release note naming `--no-incremental` and
  `incremental: false`.
- **What stays.** `--verify-incremental` and `make check-incremental` remain, alongside WD1's spec.
  Editor mode option B is still reached only through an explicit `--incremental`. `rigor unused`
  keeps rejecting `--incremental`.

## Rejected and deferred alternatives

| Alternative | Reason |
| --- | --- |
| Flip now, as #120 first asked | Every user would meet the stale answers in the Context, and the default tail's outputs would disappear. |
| Keep `--incremental` opt-in indefinitely | It leaves a tenfold leaf-edit gap on the everyday loop. |
| Patch each missing input into the fingerprint | That list is how the bugs arose. A list beside the code does not converge, and the recorded chain does (WD1). |
| On everywhere, CI included | A cold CI job pays for recording no later run reuses, and the newer route would become the gate of record. |
| Re-analyse only the file credited with a stale plugin read | Unsound under plugin memoisation (WD1). It waits for a plugin contract. |
| One snapshot per root set | File-argument runs rarely repeat a root set, so each would pay for recording into a snapshot nothing reuses. It also needs eviction the snapshot lacks. WD5 routes those runs to the full path instead. |
| Per-file result reuse on the default path without the dependency graph | A file's diagnostics depend on other files. Reuse without the graph is unsound, and the graph is what `--incremental` is. |
| A new cache format, a daemon or native code | #1507's profiles give none of them a target. |

## Consequences

- **Positive**
  - A local edit on a Rails-sized project costs seconds rather than a cold run, with no flag.
  - A new input joins both caches by being read, and WD1's spec enforces it.
  - Five open issues close as one class.
- **Negative, accepted**
  - A local cold run pays for recording, and G3 bounds that at 10%.
  - Local and CI runs take different routes. WD1's cross-process spec is what makes their answers
    equal, since `--verify-incremental` never reads a snapshot. A stale answer that escapes it
    shows locally first, where `--no-cache` recovers.
  - Any stale carried row forces a full baseline, so a `sig/` edit costs a cold run until
    per-kind refinements land.
  - The first run of a project with an opaque plugin pays for recording once.
  - A warm local run no longer prints the run stats block; only runs that built the environment
    print it.
- **In the same changes:** `docs/internal-spec/cache.md` § "Two-level gating", the Caching and CLI
  manual pages, and ADR-46's status line.

## Relationship to other ADRs

- [ADR-45](45-unchanged-project-fast-path.md): WD2's carried chain becomes the snapshot's validity
  check (WD1), and the snapshot, not the slot, owns it. § "Why the chain holds together" is amended:
  the snapshot-identity check retires. After the flip, only runs on the full route write the plain
  slot.
- [ADR-46](46-incremental-dependency-graph.md): WD1–WD3 amend the snapshot's validity check and key.
  The dependency graph is unchanged.
- [ADR-50](50-release-engineering-and-stability-strategy.md): the preview mechanism (WD8) and the
  baseline target (G4).
- [ADR-51](51-ci-diagnostic-output-formats.md) WD7: its provider table picks the route under `auto`,
  through a predicate that ignores `RIGOR_CI_DETECT` (WD5).
- [ADR-88](88-incremental-plugin-fact-soundness.md): the fact digest stays in the key. Opaque
  plugins take the full route (WD5).
- [ADR-103](103-effect-labels.md): an effects-enabled project takes the full route under `auto`
  until the session writes a slot with effects on. If `effects-on-by-default` graduates before that,
  `auto` takes the full route everywhere, and the flip waits for it.
