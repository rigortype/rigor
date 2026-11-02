# The #2618 baseline refresh takes allocations from the CI run but keeps the old wall_s and peak_rss_kb

- **PR:** [#2636](https://github.com/rigortype/rigor/pull/2636)
- **Issue:** none
- **Class:** process
- **Precedent:** [#2331](https://github.com/rigortype/rigor/pull/2331)
- **Decided:** 2026-11-03

## Background

#2618 recovered about 2.95M allocations, and `make bench-perf` began printing `STALE`. The refresh was measured on Linux CI at #2618's merge commit f558448b0 (release-gate run 41481534538). That run read 63,444,766 allocations, wall_s 81.2 to 81.8 (a slow runner draw; it failed only the wall band), and peak_rss_kb 684,168 and 696,332. The old RSS baseline is 647,748, so the run is +5.6%, inside the +10% band. `bench/README.md` says to commit the run's artifact. That artifact would set all three figures from one run, raising the wall and RSS ceilings along with lowering the allocation one.

## Options and trade-offs

- **Commit the artifact whole.** This follows the README to the letter. It raises wall_s to 81.2, against the README's rule never to recalibrate for wall. It also raises the RSS ceiling by 5.6% with no attribution for the rise, so a later RSS regression of that size would pass unseen.
- **Take allocations only, and keep wall_s and peak_rss_kb.** The allocation band tightens to the real cost, which is the point of the refresh. Wall follows the v0.4.6 ruling. RSS keeps its stricter ceiling, 712,523, but this run already sits at 684,168 to 696,332, so only 2.3% to 4.1% of headroom is left, and the next cut may fail on RSS.
- **Take allocations and peak_rss_kb, and keep wall_s.** This re-anchors RSS at 684,168, which needs an attribution for the +5.6% rise that nobody has yet.

## Decision

Take allocations only. Holding RSS is the stricter reading, so it hides nothing. The cost is that an RSS failure at the next cut is more likely. That failure then goes through the README's red-cut path: attribute the rise, rule on it, and recalibrate on the same corpus. That path is where an unattributed +5.6% RSS rise belongs, rather than being absorbed silently by an allocation refresh. Only the wall hold follows a precedent: #2331, the v0.4.6 calibration, held wall_s against a slow-runner draw. The RSS hold has none.

## To undo

Commit run 41481534538's `peak_rss_kb` (684,168), and wall_s too if wall should follow the run, into `bench/baseline.json`, with the reason in the note. Nothing depends on the held values except the gate's RSS and wall ceilings.
