# Perf benchmark data

Files that drive the `make bench-perf` perf-regression gate
([ADR-50](../docs/adr/50-release-engineering-and-stability-strategy.md) WD4),
run as a job in the release gate (`.github/workflows/release-gate.yml`),
where it is a hard gate once the baseline is calibrated.

| File | Purpose |
|---|---|
| `baseline.json` | The corpus revision (`"corpus"`) and the committed per-target baseline metrics measured on it (wall / allocations / peak-RSS). While `"calibrated": false` the gate passes and only suggests; activate by committing a CI-measured baseline (see below). |
| `thresholds.yml` | The tunable tolerance band — the reviewed knob for how much each metric may regress before the gate fails. |
| `baseline.updated.json` | **Not committed** (gitignored). The suggested baseline `make bench-perf` writes on **every** run — this is the file a refresh commits from. |

The benchmark runs this checkout's `rigor check --no-cache` in-process over a
target (default `lib`) of a **frozen corpus**, and measures wall time,
`GC.stat(:total_allocated_objects)`, and peak RSS. Peak RSS is read from
`/proc/self/status` and is therefore measured on **Linux only** (the CI runner
is authoritative); on macOS / other hosts it is reported `nil` and the gate
skips it, so local `make bench-perf` still measures the portable wall +
allocations.

## The corpus

`baseline.json` names the corpus as `"corpus"`: the previous release's tag.
`tool/bench.rb` `git archive`s that tree into a scratch directory and runs this
checkout's engine there, as `tool/engine_alloc_ab.rb` does. A clone without
the tag (a shallow checkout) stops with an error rather than measuring
something else, and so does a run that loaded any Rigor file from the corpus's
own older `lib`. Rigor's `lib` grows with every pull request
([ADR-50](../docs/adr/50-release-engineering-and-stability-strategy.md) WD4
records by how much), so a band on the current `lib` could not tell corpus
growth from engine cost at any width. On a frozen tree allocations repeat to a
few hundred objects, so the band in `thresholds.yml` is a budget for the
engine cost added since the baseline was last calibrated, not room for noise.

What the corpus run does not reproduce:

- **Gems' own `sig/`.** The corpus has no `vendor/bundle`, so gem-shipped
  signatures do not load. On the v0.4.0 corpus, loading them adds 1.02% to
  allocations.
- **The core RBS and the Ruby.** Both come from the run, not the corpus: the
  `rbs` gem in this checkout's `Gemfile.lock`, and whichever 4.0.x CI's
  `ruby-version: "4.0"` resolves to. Either can move the number without an
  engine change, and the per-PR job cannot see it, because both of its arms
  share them. The `rigor-dependency-update` and `rigor-ruby-version-bump`
  skills record the shift in their PR, and `calibrated_on` names the Ruby the
  baseline was measured on.
- **A user-global `BUNDLE_PATH`.** When the corpus has no bundle, Rigor's
  bundle discovery falls back to `~/.bundle/config`
  (`lib/rigor/environment/bundle_sig_discovery.rb`, `global_bundle_path`). A
  host whose global `BUNDLE_PATH` points at an existing directory loads that
  bundle's gem signatures into the run. CI's `ruby/setup-ruby` sets the path
  with `--local`, in the checkout the corpus does not include.

## Over a release cycle

- **At the cut**, the release gate measures the release candidate's engine
  over the previous release's tree, and `allocations_pct` gates the cost added
  since the last calibration.
- **A red cut has one way through.** The gate is planned as a required check,
  so recalibrating is the only thing that clears it, and it happens only on
  the user's ruling:
  1. Attribute the rise: the "Engine allocations" summaries of the PRs merged
     since the last calibration, plus any gem or Ruby bump (see above).
  2. Put the attribution to the user.
  3. On the user's ruling, recalibrate on the **same** corpus, on the release
     branch, with a `note` naming the ruling and the attribution.
  4. Publish, then advance the corpus.

  A `wall_s`-only failure is runner noise: rerun it, never recalibrate for it.
- **After tagging**, the corpus advances to the new tag and the baseline is
  recalibrated on it. The `rigor-release-prep` skill carries every step here.

## Calibrating the baseline

`release-gate.yml` runs on every `release/**` push and on demand
(`workflow_dispatch`). Every run uploads a `bench-baseline-<run id>` artifact:
the suggested baseline, reduced by the sampling rule and naming the corpus it
measured. Recalibrating is committing that file as `baseline.json`, with a
`note` saying why and `calibrated_on` naming the run and its Ruby:

```sh
gh workflow run release-gate.yml --ref <branch>
gh run list --workflow release-gate.yml --branch <branch> --limit 1 --json databaseId
gh run watch <run id>                       # can return mid-run:
gh run view <run id> --json status          # confirm "completed"
gh run download <run id> --name bench-baseline-<run id> -D <dir>
```

To move to a new corpus, set `"corpus"` to the new tag and `"calibrated":
false` on a branch with no PR, dispatch, and commit the calibrated artifact
before opening one: an uncalibrated baseline passes every run, and a spec
fails if one is committed. A local `make bench-perf` writes the same file to
`bench/baseline.updated.json`; commit the Linux CI numbers, not a laptop's.

## Refreshing after an improvement

The band is a percentage of the baseline, not of the current cost, so an
improvement left unrefreshed widens the real ceiling instead of tightening it:
after `lib` allocations fell 27%, the then +5% band still permitted +44% over
the true number. `make bench-perf` prints a `STALE` notice when allocations
fall more than `stale_pct` below the baseline. It is a request for a refresh,
not a failure.

A refresh re-anchors the band at a new measurement on the same corpus, so it
also absorbs every engine change merged before the measured commit. Two rules
keep it from hiding a regression:

- **Measure at the improving PR's own merge commit**, not at `master`'s tip
  later: push a branch at that commit
  (`git push origin <merge sha>:refs/heads/bench-refresh-<pr>`), dispatch the
  release gate on it, and commit the artifact to `master` through a PR.
- **The note lists every "Engine allocations" warning** since the last
  calibration and how each was answered. A warning nobody answered needs the
  user's ruling before the refresh lands, or the improvement would hide it.

## The per-PR engine A/B

The release gate above runs only at a cut or a refresh, so it sees the engine
cost added since the last calibration, not the step that added it. The
advisory "Engine allocations" CI job (`tool/engine_alloc_ab.rb`, #1507)
charges each step to its PR: the merge base's engine and the PR's engine each
run `rigor check --no-cache lib` over the merge base's tree, in fresh
processes, and the job summary reports the delta. It warns past
`pr_allocations_pct` in `thresholds.yml` and never fails the PR.

It measures only what that run executes. Rigor's own configuration loads no
plugin, so of `plugins/` only the rbs-inline ingestion the engine runs by
default is measured; a PR that touches none of `lib/`, `data/` and
`plugins/rigor-rbs-inline/` is skipped rather than reported as a zero.

The same comparison runs locally, including against uncommitted work. Measure
from the merge base, not `origin/master`: a base the branch did not start from
charges the work with every engine change merged since.

```sh
nix develop --command bash -c 'bundle exec ruby tool/engine_alloc_ab.rb --base "$(git merge-base origin/master HEAD)" --head WORKTREE'
```

## Wall and CPU on CI Linux

Wall and CPU time are noise on a shared development host, so they are measured
by the manually dispatched "Engine wall A/B" workflow
(`.github/workflows/engine-wall.yml`, `tool/engine_wall_ab.rb`). It runs two
engines N times each over one frozen corpus in ABBA order, every run a fresh
process after a discarded warm-up, and reports each arm's median and range for
wall, CPU, GC time and, where the runner exposes the counter, user-space
instructions. A row says the ranges separate only when that is unlikely by
chance: at most 5% across all the rows together, which takes five runs per
arm, the default.
`--yjit on` or `off` takes the wall-clock YJIT deadline out of the comparison,
and the report warns when the arms ended in different YJIT states.

```sh
gh workflow run engine-wall.yml -f base=v0.3.9 -f head=master -f corpus=v0.3.9
```

## Warm journeys on Mastodon

The dispatched "Engine warm journeys" workflow
(`.github/workflows/engine-warm.yml`, `tool/engine_warm_ab.rb`) measures how
long `rigor check` answers with a warm cache on Mastodon at the pinned tag, for
the default run-result cache and for `--incremental`:

- **null:** nothing changed;
- **leaf:** a file nothing depends on was edited;
- **hub:** a file many others depend on was edited.

Every step runs as a fresh process, boot included (the harness's
`bundler/setup` adds about 50 ms that a gem-installed user does not pay). Each
timed run must be the run its row is about, or the tool fails: an edit run must
load the engine (a miss), and every `--incremental` run must report itself
warm. The report counts how many default null runs the engine-free probe served.

The first timed run of each scenario is compared with a plain `--no-cache` run
of the same tree. (`--incremental --no-cache` still replays the snapshot,
#1525.) Different findings fail the tool, and the same findings in another
order are a note. How far an incremental edit spread is not reported yet
(#1526), so whether a leaf or hub is really one rests on the files chosen:
Mastodon's defaults re-analyse 1 and 277 files. With `base` set, two engines
alternate in ABBA order on separate project copies, and the table gives the
same separation verdict as the wall A/B.

With `profile` set, each scenario also runs once, untimed, under vernier. The
summary gives, per scenario, the chain of frames nearly every sample shares and
where the samples fan out below it, as shares of that run's wall time. The
profiler starts after Ruby boot and `bundler/setup`, and GC is not sampled, so
the shares do not add up to 100%. The artifact holds the top lists.

Each engine is laid out as an installed gem (`gems/rigortype-<VERSION>`), so
its result-cache key is the released one. A development checkout instead
digests the engine's source on every run, about 20 ms on a null build, which a
user of the released gem does not pay.

```sh
gh workflow run engine-warm.yml -f head=master -f profile=true
```
