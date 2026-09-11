# v0.3.9 release-gate `lib peak_rss_kb` attribution

The v0.3.9 release gate reported `lib peak_rss_kb` 483,252 against 437,396 on the v0.3.8 gate
(+10.5%) while allocations fell 36,171,454 → 23,705,98x (−35%) and wall stayed flat. This note
attributes that rise across `v0.3.8..origin/master` (110 first-parent merges).

## Instrument

`tool/bench.rb` measures `lib` by calling `Rigor::CLI.new(["check", "--no-cache", "--no-stats",
"--format", "json", "lib"]).run` **in-process**, and reads peak RSS from `/proc/self/status`
(`VmHWM`), which does not exist on macOS — so local `make bench-perf` reports `peak_rss_kb: nil`.
The measurements below reproduce the same in-process call from a standalone driver and take peak
RSS from `/usr/bin/time -l` (`maximum resident set size`, bytes) around the whole process, with
`RIGOR_DISABLE_YJIT=1` on every arm. Host: macOS (Darwin 25.6.0), inside the Nix Flake, one process
at a time, arms alternating rep by rep, in a dedicated worktree.

The process-level number includes the interpreter and `require` baseline, so it is offset above
CI's `VmHWM`-of-the-same-process figure by a constant; only the **ratio** between arms transfers.

## Arms

Peak RSS in KB, alternating reps (reps 1–3 from the first A/B pass, 4–6 interleaved in the waypoint
sweep):

| arm | rep1 | rep2 | rep3 | rep4 | rep5 | rep6 | median | allocations | wall_s (median) | diagnostics |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `v0.3.8` | 431,015 | 457,968 | 433,568 | 460,992 | 448,256 | 434,320 | **441,288** | 36,498,88x | 18.8 | 2 |
| `origin/master` | 481,488 | 479,104 | 479,920 | 483,888 | 467,504 | 453,184 | **479,512** | 23,705,98x | 18.5 | 1 |

**+8.7% median peak RSS**, allocations −35%, wall unchanged — the CI signal reproduces locally in
both direction and magnitude (+10.5% there, single-run). Allocations are deterministic to ±20
objects across reps; peak RSS spreads ±30,000 KB (≈7%) on this host, which is the whole reason the
attribution below could not be done on RSS alone.

## Bisect: no single merge moved it

`git bisect run --first-parent` over `v0.3.8..master`, scoring min-of-2 peak RSS against a 480 MB
threshold, converged on `b32173ed` "Record #981 and #982 in the handoff" — a **docs-only** commit
that cannot move RSS. The bisect was tracking noise: its seven probe points read 410, 464, 464,
453, 490, 462, 463 MB, i.e. a flat band straddling the threshold rather than a step.

A 15-point first-parent waypoint scan (one rep each; allocations are the deterministic axis) shows
why — the cycle has no step, only a monotone climb:

| waypoint (first-parent merge) | allocations | Δ vs previous |
| --- | --- | --- |
| `e42fcdc8` #819 perf-775-allocation-levers | 21,842,079 | — (from 36,498,88x at `v0.3.8`) |
| `29c77473` #822 | 21,834,860 | −7,219 |
| `0f3eee4d` #830 | 21,961,250 | +126,390 |
| `c3a12849` #851 | 22,195,735 | +234,485 |
| `5cab4e07` #863 | 22,703,727 | +507,992 |
| `dd7a18bd` #880 | 21,844,747 | −858,980 |
| `9fb5e7ef` #888 | 21,850,416 | +5,669 |
| `58383219` #896 | 21,914,888 | +64,472 |
| `e58dab79` #907 | 22,522,766 | +607,878 |
| `aa6b423e` #946 | 22,676,028 | +153,262 |
| `3cfa4069` #956 | 22,734,018 | +57,990 |
| `c0248433` #958 | 23,255,266 | +521,248 |
| `f23cedf3` #974 | 23,369,500 | +114,234 |
| `43f533c4` #985 | 23,706,311 | +336,811 |
| `origin/master` | 23,705,987 | −324 |

The largest single span is +608k allocations (#896..#907), then +521k (#956..#958) and +508k
(#830..#863) — none of them a majority of the +1.86M post-#819 rise. Peak RSS over the same
waypoints (3 reps each, medians): #819 424,320 KB · #889 429,904 · #955 449,216 · #958 473,488 ·
#978 454,496 · master 479,512 — a climb of the same shape, inside a ±30,000 KB noise band.

### The prime suspects, checked

- **#819 (per-run memo tables)** is the opposite of the culprit. It is *inside* this cycle, and it
  is the merge that both drops allocations 36.5M → 21.8M **and** gives the lowest peak RSS of any
  waypoint measured (424,320 KB median — 17,000 KB *below* `v0.3.8`). Its memo tables did not trade
  allocations for retained memory here.
- **#976, #978, #975, #955, #958** each sit inside spans contributing 60k–520k allocations. No one
  of them accounts for the rise; #958's span is the largest of the five and is still ~28% of it.

So the v0.3.8 → v0.3.9 comparison confounds two independent movements that happen to land in the
same cycle: one large allocation *drop* (#819) and a diffuse RSS/allocation *climb* spread over the
~95 merges after it, each adding a little more analysis work.

## Shape: not a leak, and not retained memoisation

Live slots surviving a double `GC.start` after the run completes:

| arm | live slots after run | Δ |
| --- | --- | --- |
| `v0.3.8` | 1,356,584 | — |
| `e42fcdc8` (#819) | 1,317,998 | −2.8% |
| `origin/master` | 1,404,616 | **+3.5%** |

Retained heap grew +48,032 slots (≈ +1.9 MB) — 4% of the ~38,000 KB peak-RSS delta. There is no
leak-shaped growth and no large retained memo table: what a full GC can reclaim at the end is
essentially unchanged. The delta lives in the **transient** peak, i.e. how much is simultaneously
reachable mid-run plus how far the GC lets the heap grow between collections. Cutting allocations
by 35% at unchanged wall time means proportionally fewer minor GCs over the run, so pages that the
old allocation pressure would have forced through a collection now stay resident until the peak.

## Recommendation

Bless the number. The rise is (a) diffuse — no merge to fix, (b) not retention — the post-run live
set is flat, and (c) partly the *price of the allocation win* the same cycle banked. `bench/`'s
`rss_pct` band is 10 and the gate fires at +10.5%, so the v0.3.9 cut wants a recalibrated
`bench/baseline.json` carrying all three `lib` numbers from a Linux CI run, with a note recording
that allocations fell 36.2M → 23.7M in the same measurement — the pairing is what makes the RSS
rise readable rather than alarming.

Not edited here: `bench/baseline.json` is untouched by this investigation, and the recalibration
belongs to release prep with a CI-measured artifact, not to a macOS host.

Worth a follow-up issue, but not a release blocker: peak RSS is currently a *single-run* number on
the release gate, with a ±7% host spread measured here. A gate band of 10% over a single sample is
barely above its own noise floor. Taking the lower of two runs (the pattern `tool/bench.rb` already
notes it does *not* do) would make the band mean what it says.

## Reproducing

Drivers used for this note live outside the tree (scratchpad); the method is three files' worth of
glue over `tool/bench.rb`'s `measure`: a standalone script that requires `rigor/cli` from a
`RIGOR_ROOT`, runs the identical `check --no-cache --no-stats --format json lib` invocation, and
prints wall/allocations, wrapped in `/usr/bin/time -l` with `RIGOR_DISABLE_YJIT=1`, alternating
`git checkout` between the two arms inside one worktree.
