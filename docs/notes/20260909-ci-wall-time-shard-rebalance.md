# CI wall time 371s → 220s: the spread was never the partition (2026-09-09)

Status: measurement note, no design commitments. Observations taken against Rigor **v0.3.8**,
GitHub Actions `ubuntu-latest`, binpacker 0.5.0, 2026-09-09. Landed as
[#863](https://github.com/rigortype/rigor/pull/863), [#867](https://github.com/rigortype/rigor/pull/867),
[#889](https://github.com/rigortype/rigor/pull/889).

## What prompted it

The three Tests shards finished at visibly different times — 339s / 172s / 117s on
[run 34269150881](https://github.com/rigortype/rigor/actions/runs/34269150881) — and the question was
whether the split could be evened out.

## It could not, because it was already even

binpacker's `--shard K/N` cuts the slice with the same weight-balanced partitioner it uses for
workers, so the first thing to read is each shard's run report rather than the job durations. They
said the partition was optimal:

| | shard 1 | shard 2 | shard 3 |
| --- | --- | --- | --- |
| slice weight | 534.6s | 534.6s | 534.6s |
| `predicted_makespan` | 167.341 | **133.661** | **133.661** |
| `actual_deviation_pct` | 24.6% | 5.8% | 4.3% |

438 files, ~1604s of predicted work, twelve workers (3 shards × 4) — a theoretical floor of ~133.7s
each, which shards 2 and 3 hit *exactly*, at 0.0% predicted deviation. No partition and no shard
count improves on that.

## Cause 1 — 145s of unrelated work pinned to one matrix arm

`Run pool-runner spec` (18s) and `Run plugin integration tests` (127s) ran as steps guarded by
`if: matrix.shard == 1`. Neither belongs to any shard: `binpacker.yml`'s `test_exclude` keeps both
out of the sharded suite because they modify global state and must own their rspec process. The only
requirement was that they run exactly once, and shard 1 was an arbitrary place to satisfy it — the
one that also held the suite's heaviest file.

That was 145s of the 222s spread. Moving them to a peer job recovered 127s of critical path, more
than every scheduler lever combined.

**This is invisible in binpacker's own data.** The reports look balanced because they *are*
balanced; the extra work is not in them at all. Diagnosing it means comparing `predicted_makespan`
across shards, seeing that they agree, and then looking outside binpacker entirely.

### This refines, and does not contradict, the 2026-07-18 note

[20260718-ci-test-time-growth-attribution.md](20260718-ci-test-time-growth-attribution.md) has a
section titled *"カテゴリ別ジョブ分割の検討（否定的）"* concluding that splitting into more jobs is
counterproductive: max-of-N worsens the straggler tail, it discards binpacker's global balancing,
fixed overhead multiplies by N, and a larger runner beats it on every axis. It ends
「現 rigor は単一 gem の unit spec なので該当なし」.

**That argument is still correct for its actual subject** — carving the *balanced spec pool* into
category jobs. What was split here is a different category the note did not consider: work that was
**already outside the pool**. #863 moved two suites `test_exclude` had removed from binpacker's
scheduling; #889 moved four gates that are not tests at all. Global balance was never at stake, and
neither split added a shard to the max-of-N draw — the count of *test* jobs is unchanged.

Read the 2026-07-18 conclusion as: *do not fragment what binpacker is balancing.* It says nothing
about work that binpacker was never balancing, which is exactly where the wall time was hiding.

## Cause 2 — one file over the per-worker budget

`spec/rigor/analysis/runner_spec.rb` weighed ~167s against the ~134s floor, so LPT correctly gave it
a whole worker and the shard's makespan became that one file. A spec FILE is the scheduling unit and
cannot be split, so this is the one thing the scheduler genuinely cannot fix.

Finding the seam turned out to be cheap. The timing file records per **example**, so a heavy file can
be attributed to its blocks with no instrumentation — sum the median of each example's samples,
grouped by top-level `describe`:

```
  93.3s  65.2%  n=225  L1405  CheckRules diagnostics (Slice 7 phase 8)
  13.4s   9.4%  n=32   L176   configuration wiring at runtime (audit guard)
  12.5s   8.8%  n=17   L5297  `rigor:v1:conforms-to` conformance directive
   8.9s   6.2%  n=6           (root-level examples)
   …23 more blocks, 14.4s combined
```

One block was 65.2% and the next was 9.4% — a single seam rather than a judgement call. The block
carried no shared state (the `analyze` harness lives in `spec/support/runner_helpers.rb`), so it
moved verbatim, keeping its own `describe` wrapper so nothing was re-indented and every example's
full description stayed byte-identical. `rspec --dry-run --format json` over both sides confirmed 355
examples with an identical description set. 5,955 lines → 2,605 + 3,361.

## Cause 3 — the same shape a third time, in Self-check (cold)

Attributing that job by step showed it spent **17% of itself on the self-check**:

| step | median | share |
| --- | --- | --- |
| Run rigor self-check | 27–31s | 17% |
| `make coverage` | 23–26s | 15% |
| `make check-plugins` | 12s | 7% |
| `make check-incremental` | 70–78s | **43%** |
| `make check-mutation-cache` | 22–24s | 14% |

The four gates hung off the warm/cold matrix via `if: matrix.cache == 'cold'`, with the rationale
written beside them — *"the result is deterministic and needs no warm/cold cross-check"* — which is
precisely why they are not part of that matrix. Moved to `acceptance-gates`: cold 164–196s → **40s**.

## What the split cost before it paid

Three things bit, none of them documented upstream at the time. All are now commented at the code and
were fed back to binpacker (below).

1. **binpacker charges a file for tests that no longer exist.** `Timing#load_with_fallback` keys on
   the file PATH, and `compact!` trims samples per test but never drops a vanished one. After the
   split the old path stayed predicted at 163.9s while running 88.7s, and the new file, having no
   history, fell back to filesize at 0.3s against 66.5s actual. Shard 1's deviation went to 43.6%
   and its job to 213s — **the correct split made the balance worse**
   ([run 34274577832](https://github.com/rigortype/rigor/actions/runs/34274577832)). Fixed with a
   generation token in the cache key (`binpacker-timings-v2-…`); bump it on any spec split, rename or
   delete. Preserving example names does not help — the lookup is per-path.
2. **The `--report` write depended on a cache hit, silently.** `Report#write` is a bare `File.write`
   with no mkpath (the timing writer does mkpath) and `tmp/` is gitignored, so it only ever worked
   because `actions/cache` restored `tmp/binpacker.timings` into that directory first. The first
   genuine miss failed the whole matrix **with all 3,357 of a shard's examples passing**
   ([run 34275199747](https://github.com/rigortype/rigor/actions/runs/34275199747)). `write_report`
   also precedes `finalize`, so that run recorded no timings either.
3. **A cache-key bump costs two cold runs, not one.** A cache saved on a feature branch is invisible
   to `master`, so the first run after the merge is cold as well and is what actually seeds the
   namespace. Never read a partition's balance from a run whose restore step logged
   `Cache not found for input keys`.

## Result, and where the floor is now

| | before | after |
| --- | --- | --- |
| workflow wall | 371s | **220s** |
| Tests shard 1 / 2 / 3 | 339 / 172 / 117s | 180 / 176 / 164s |
| shard actual makespans | — | within 4.4s of each other |
| Self-check (cold) | 164–196s | 40s |

Essentially all of the 151s came from #863. The floor is now the Tests matrix at 176–182s (twelve
workers, ~160s actual makespan plus setup), and nothing job- or shard-shaped moves it further — only
reducing spec volume would. #889's own predicted ~20s did **not** materialise: it was sized against
runs where Self-check (cold) measured 184–196s, but the run the workflow was actually judged on had
it at 164s, already under Tests. *Size a job split against the critical path on the same run you are
quoting, not the worst run in the sample.*

## Where the durable knowledge went

- **binpacker** ([binpacker#20](https://github.com/rigortype/binpacker/pull/20), merged) — a README
  section on diagnosing an unbalanced matrix (compare predicted makespans first; the floor
  arithmetic; the per-example attribution recipe) and one on timing data after a file moves; both
  shipped skills updated; traps 1 and 2 filed as gem issues under `.scratch/rigor-shard-rebalance/`.
- **This repo** — the traps are commented where they bite, in
  [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) and the `test-binpacker` target in
  [`Makefile`](../../Makefile).

One gap worth naming: `docs/CURRENT_WORK.md`'s header routes operational pitfalls to *"the
workflow's skill"*, and there is no CI or verification skill under `.claude/skills/` to receive them.
A one-off did not justify creating one; a second CI campaign would.

## 関連

- [2026-07-18 CI テスト時間の伸び — 要因分解](20260718-ci-test-time-growth-attribution.md) — the
  negative conclusion on category job-splitting that this note refines, plus the instance-gacha
  analysis and the md-only PR skip that became the `changes` job.
- [2026-06-22 Parallel spec suite: runtime-based distribution](20260622-parallel-suite-runtime-distribution.md)
- [2026-06-23 binpacker parallel-suite trial](20260623-binpacker-parallel-suite-trial.md)
