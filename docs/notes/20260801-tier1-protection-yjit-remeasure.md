# Tier-1 `coverage --protection` re-measure after the ForkMap YJIT re-arm (#257/#258)

Status: measurement note, no design commitments. Observations taken against `master` @
`a7a7cc1d` (post-#258), macOS arm64, Ruby 4.0.5, 2026-08-01.

## Why

[#257](https://github.com/rigortype/rigor/pull/257) found that `Inference::ForkMap`
never re-armed deferred YJIT after `fork` — every `ForkMap`-backed pass, including the
Tier-1 `coverage --protection` scan and the ADR-67 parameter-inference pre-pass, ran its
worker processes fully interpreted. [#258](https://github.com/rigortype/rigor/pull/258)
tightened the fix further: a child now re-arms with the parent's *remaining* deadline
rather than a fresh 5s window. #257's own PR body names the consequence directly:

> The Tier-1 P3-10 numbers (`61s → 43s`) were measured with the latent ForkMap deficit
> in place; a Mastodon-scale re-measure would likely improve them.

This note is that re-measure.

## Provenance of the old numbers

The "61s → 43s" figure traces to
[PR #67](https://github.com/rigortype/rigor/pull/67) ("Fork-parallelize the coverage
protection scan", merged 2026-07-10), which introduced the P3-10 fork-map for both the
protection scan and the ADR-67 parameter-inference pre-pass. From the PR body:

> Wall **61s → 43s** at 4 workers, **peak RSS roughly halved** (814MB → 351MB); the
> parameter-inference pass alone is **2.3× at 8 workers**.

with the phase breakdown (Mastodon `app lib`, warm cache) that motivated fork-mapping
*both* passes rather than just the scan:

| phase | time |
| --- | ---: |
| env build (warm cache) | 1.2s |
| ADR-67 parameter-inference pre-pass | 48.6s |
| protection scan | 11.0s |

The condensed form landed in the changelog, `docs/CHANGELOG-0.2.x.md:38`:

> The parameter-inference pre-pass and the per-file protection scan are each
> fork-mapped over worker processes built from one parent-side environment (RBS env,
> plugin registry, and cross-file seed built once and copy-on-write inherited). Worker
> count resolves exactly as `check` does (`--workers=N` › `RIGOR_RACTOR_WORKERS` ›
> `.rigor.yml` `parallel.workers:` › `0`), and the output is byte-identical to a
> sequential run. Measured on Mastodon `app lib`: 61 s → 43 s at four workers, with
> peak memory roughly halved.

**Note the arm mismatch**: the historical comparison is sequential (`--workers 0`)
vs. **4** workers, not 8. This note measures 0, 4, and 8 so the new numbers are
comparable to the old ones and also cover the task's requested 8-worker arm.

The deficit itself, and its fix, are recorded in #257/#258 (not yet archived to
`docs/notes/` as of this writing — both PRs merged today, 2026-08-01, `a7a7cc1d`).
#257's own measurement (on `lib/rigor/analysis`, a different corpus — the Tier-2
mutation scan, not Tier 1) is the direct evidence the deficit was real:

| workers | before the YJIT fix | after |
| --- | ---: | ---: |
| 0 | 37.2s | 35.1s |
| 2 | 48.0s | 27.8s |
| 4 | 43.6s | 26.7s |
| 8 | 67.4s | 23.2s |

i.e. the pool was a *pessimization* at 8 workers before the fix (67.4s, worse than
sequential) and a clear win after (23.2s). #258 shaved a further ~8% off the 8-worker
case (23.2s → ~21.3-21.6s) by carrying the remaining deadline instead of a fresh one.

## Method

Target: `~/repo/ruby/rigor-survey/mastodon`, which carries `.rigor.dist.yml` (paths:
`app`, `lib` — matching the historical "Mastodon `app lib`" scope) but no `.rigor.yml`,
so `--config .rigor.dist.yml` is passed explicitly rather than copying it into the tree.

```
cd ~/repo/ruby/rigor-survey/mastodon
BUNDLE_GEMFILE=/Users/megurine/repo/ruby/rigor/Gemfile \
  nix --extra-experimental-features 'nix-command flakes' develop /Users/megurine/repo/ruby/rigor --command \
  bash -c 'time bundle exec /Users/megurine/repo/ruby/rigor/exe/rigor coverage --protection \
    --config .rigor.dist.yml --workers <N> app lib'
```

Arms: `--workers 0` and `--workers 8` per the task, plus `--workers 4` to stay
comparable to the historical figure above. Each arm run twice. `coverage --protection`
does not touch Rigor's persistent `.rigor/cache` (that store backs `check`, not
`coverage` — confirmed by grep, no `cache`/`CacheStore` reference in
`lib/rigor/cli/coverage_command.rb`), so there is no cache-warmup effect to call out
between the two runs of an arm; both are cold/warm in the same sense (OS page cache
for the gem/rbs files, which is already hot from the `bundle check` dry-run before
timing started).

## Runs

All commands: `cd ~/repo/ruby/rigor-survey/mastodon`, `BUNDLE_GEMFILE=.../rigor/Gemfile`,
through the Flake, `coverage --protection --config .rigor.dist.yml --workers <N> app lib`.

| workers | run | real | user | sys | load avg (1m) just before |
| --- | --- | ---: | ---: | ---: | ---: |
| 0 | 1 | 23.006s | 17.679s | 2.362s | 7.16 |
| 0 | 2 | 21.815s | 17.536s | 2.063s | 8.53 |
| 4 | 1 | 16.337s | 28.290s | 9.670s | 8.45 |
| 4 | 2 | 16.405s | 28.376s | 9.655s | 9.21 |
| 8 | 1 | 13.345s | 37.186s | 17.415s | 8.18 |
| 8 | 2 | 12.748s | 35.855s | 16.002s | 7.61 |

Averages: 0w **22.41s**, 4w **16.37s** (1.37×), 8w **13.05s** (1.72×).

## Quiet-machine re-run — the reference numbers

The runs above were taken under sustained foreign load (see § Honesty). Once the 1-minute
load dropped to ~4, every arm was re-run twice, same command shape, end-to-end timed
(includes ~1s of warm Flake entry, constant across arms):

| workers | run | real | load avg (1m) just before |
| --- | --- | ---: | ---: |
| 0 | 1 | 18.55s | 4.40 |
| 0 | 2 | 17.86s | 4.24 |
| 4 | 1 | 15.29s | 4.09 |
| 4 | 2 | 15.35s | 4.40 |
| 8 | 1 | 12.55s | 6.70 |
| 8 | 2 | 13.01s | 6.82 |

(The elevated "before" load on the 8-worker rows is this measurement's own residual from
the just-finished 4-worker arm decaying out of the 1-minute average, not foreign load.)

Averages, and the numbers this note exists to establish: 0w **18.2s**, 4w **15.3s**
(1.19×), 8w **12.8s** (1.42×), protected sites `10264 / 30822 (33.3%)` on every run.
The quiet machine mainly helped the *sequential* arm (22.4s → 18.2s), so the parallel
ratio drops further — see the fixed-per-worker-cost point below, which this strengthens.

Peak RSS (`/usr/bin/time -l`, one run each, load avg 9.26 / 6.93 respectively):

| workers | real | maximum resident set size |
| --- | ---: | ---: |
| 0 | 18.96s | 852,246,528 B (813 MB) |
| 8 | 12.90s | 371,687,424 B (354 MB) |

## Sanity check: worker count must not change the answer

**Passed, strongly.** Every run above reports the identical `protected dispatch sites:
10264 / 30822 (33.3%)` regardless of worker count. Beyond the summary line, the full
`--format json` output was diffed byte-for-byte between `--workers 0` and `--workers 8`
(fresh runs, not reused from the timing runs above): identical SHA-256
(`60bd0fc9118c3cc...`) for both. Worker count changes speed only, never the answer, on
this run.

## What this does and does not show

**The wall-clock magnitude does not match the historical entry, in either direction the
#257/#258 fix would explain.** Historical: 61s sequential → 43s at 4 workers. Here (quiet
re-run): 18.2s sequential → 15.3s at 4 workers. The sequential (`--workers 0`) arm never forks, so
`ForkMap`/#257/#258 cannot touch it at all — yet it dropped by **2.7×** on its own. That
gap has to be attributed to the three weeks of general engine work between the two
measurements, not to this fix: PR #67 (the source of "61s → 43s") merged 2026-07-10
against the `0.2.9` cycle; this session measures `a7a7cc1d` on `0.3.1`, which sits on the
other side of the v0.3.0 perf campaign (YJIT deadline tuning, `rigor_each_child`, prepare
cache, lazy pre-pass —
[`20260713-corpus-perf-campaign.md`](20260713-corpus-perf-campaign.md), PRs #74-#77) and
the #207 stub-detection allocation cut. The Mastodon checkout itself is unchanged (`163f96ce`,
2026-07-03, same 1,312 files under `app`+`lib` both times), so corpus drift is ruled out
as the explanation.

Two things it back up, unaffected by the wall-clock drift:

- **Peak RSS lines up almost exactly with the historical figures** (813 MB now vs. 814
  MB then, sequential; 354 MB now at 8 workers vs. 351 MB then at 4 workers) even though
  wall time fell 2.7×. Memory is governed by the one-time parent-side RBS-environment
  build (COW-shared into children), which the intervening perf work did not target —
  consistent with the historical claim that peak memory is set by that shared build, not
  by wall-clock-affecting changes.
- **The parallel speedup ratio is *lower* now than historically**
  (1.19× @ 4w quiet — 1.37× under load — vs. the old 1.42× @ 4w), which is the *opposite* direction from what a pure
  YJIT-rearm win would predict. This is plausibly explained by PR #67's own documented
  residual — "sub-linear scaling is inherent fork re-warm of per-dispatch resolution
  memos […] amortizes better on larger trees" — which is a **fixed** per-worker cost.
  As the total workload shrank ~2.7× from unrelated perf work, that fixed overhead
  became a larger fraction of a smaller total, pulling the achievable speedup down even
  though #257/#258 fixed a real deficit elsewhere.
- **#257's own measurement is the clean evidence the deficit was real**, on a different
  (smaller, Tier-2 mutation) corpus where it could isolate the effect: `lib/rigor/analysis`
  (45 files / 916 mutants) went from the pool being a **pessimization** at 8 workers
  before the fix (67.4s, worse than 37.2s sequential) to a clear win after (23.2s), further
  cut ~8% by #258 (~21.3-21.6s). That before/after held the tree fixed except for the
  fix itself — this note's Mastodon numbers do not, because three weeks and a full
  perf campaign separate the two Mastodon data points.

**This note therefore establishes a fresh Mastodon-scale reference for current master
(0w/4w/8w wall times and RSS above), but does not attempt to re-derive an isolated
#257/#258 delta on Mastodon** — doing that cleanly would need a same-tree before/after
(checking out the commit immediately before #257 in an isolated worktree and re-running
this exact command), which was out of scope here given the read-only/no-branch-switch
constraint on the main checkout. Recommended as a natural follow-up if the isolated
Mastodon-scale delta is wanted.

## Honesty / environment

Machine: 12-core (`sysctl -n hw.ncpu` reports 12; `uptime` above), macOS arm64.
**Sustained background load throughout this session** from an unrelated `cargo test
--workspace` invocation in another Claude Code session (`~/repo/rust/steins`), plus
ordinary desktop-app load (Chrome, Slack). Load average (1-minute) ranged **7.16-9.26**
across every run in this note — never under the ~4 threshold this repo's own perf
lessons call for. A 5-minute wait (`Monitor` polling every 5s) was tried before the
first run and did not bring it down; the 1-minute figure only dipped to 4.49 once,
immediately before the RSS run, then rose again. Per the project's own prior-perf
lesson ("perf numbers taken under load were discarded"), **the absolute wall-clock
figures above should be read as indicative, not clean** — the load was general desktop
+ another session's CPU-bound Rust compile/test, not this measurement fighting itself,
so the relative comparisons (0w vs 4w vs 8w; historical-vs-now direction of the gap)
are probably still informative. **That quiet re-run happened** (§ Quiet-machine re-run,
1-minute load ~4.1-4.4 on the sequential and 4-worker arms) and its figures are the ones
to cite; the loaded table above is retained to show the load sensitivity — almost all of
it lands on the sequential arm.
