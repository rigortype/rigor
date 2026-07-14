# JIT evaluation for `rigor check` — YJIT vs ZJIT on Ruby 4.0 (2026-07-14)

Status: measurement note, no spec/design commitments. Grounds the JIT
guidance in [`skills/rigor-project-init/references/05-jit-performance.md`](../../skills/rigor-project-init/references/05-jit-performance.md)
and confirms the [ADR-75-era deferred-YJIT decision](../adr/50-release-engineering-and-stability-strategy.md)
(shipped as `Rigor::Runtime::Jit`, the 5 s deadline) still picks the right
JIT now that Ruby 4.0 ships ZJIT alongside YJIT.

## Question

Ruby 4.0.5 ships **both** JITs compiled in (`RbConfig::CONFIG` reports
`YJIT_SUPPORT="yes"` and `ZJIT_SUPPORT="yes"`; `ruby --yjit` / `ruby --zjit`
each report `+YJIT` / `+ZJIT` and `RubyVM::{YJIT,ZJIT}.enabled? == true`).
Rigor's deferred-JIT feature only knows YJIT. Now that ZJIT (the newer
method-based JIT, [docs](https://docs.ruby-lang.org/en/master/jit/zjit_md.html))
is available, should Rigor prefer it — and does a JIT help at all on the run
sizes users actually see?

## Method

Real product workload: in-process `rigor check --no-cache` (cold) on
`rigor-survey` targets spanning the size spectrum. The JIT is selected at
process start via `RUBYOPT=--yjit` / `--zjit`; the interpreter arm sets
neither. **Every arm sets `RIGOR_DISABLE_YJIT=1`** so Rigor's own
deferred-YJIT never fires and the only JIT active is the arm's flag.
Interleaved 3-pass reps, median reported. Wall is the metric (a JIT does
not change allocations — verified — nor diagnostics: **all three arms
produced byte-identical diagnostic counts on every target**, so both JITs
are correctness-safe on Rigor). Shared dev host (arm64-darwin, Ruby 4.0.5);
wall carries machine noise, but the pattern below is far larger than the
run-to-run spread and min tracks median.

## Result (cold `rigor check`, seconds, median of 3)

| target (size) | interp | YJIT | ZJIT | YJIT vs interp | ZJIT vs interp | ZJIT vs YJIT | diag |
|---|--:|--:|--:|--:|--:|--:|--:|
| kramdown `lib` (~1.6 s, small) | 1.61 | 2.69 | 2.21 | **+67 %** | **+37 %** | −18 % | 68 |
| mail `lib` (~4 s, medium) | 4.00 | 4.05 | 4.18 | +0 % | +4 % | +3 % | 26 |
| rigor `lib` (~8 s) | 8.06 | 7.03 | 7.71 | **−13 %** | −4 % | +10 % | 1 |
| gitlab `app/models` (~19 s) | 18.96 | 15.11 | 16.59 | **−20 %** | −13 % | +10 % | 210 |
| mastodon `app`+`lib` (~17 s, large) | 16.58 | 11.86 | 14.29 | **−28 %** | −14 % | +21 % | 2348 |

(mastodon interp is ~17 s, not the ~25 s of the session-start baseline,
because the v0.3.0 perf arc — allocation-free AST iteration etc. — has since
landed on master; this is current-master interp.)

## Findings

1. **Both JITs are correctness-safe.** Diagnostics are byte-identical across
   interp / YJIT / ZJIT on every target. Neither JIT miscompiles Rigor.
2. **A JIT only pays off once the run is long enough to amortize warm-up.**
   Below ~4 s both JITs *lose* to the interpreter (kramdown: YJIT +67 %,
   ZJIT +37 %). The crossover for YJIT is between ~4 s (mail, break-even) and
   ~8 s (rigor `lib`, −13 %). This is exactly why Rigor defers YJIT behind a
   5 s deadline rather than enabling it at boot.
3. **On the runs that matter (large, cold), YJIT wins and beats ZJIT
   everywhere.** YJIT −13 % to −28 %; ZJIT −4 % to −14 %; **YJIT is 10–21 %
   faster than ZJIT on every target where both help.** ZJIT's peak win is
   roughly half YJIT's.
4. **ZJIT beats YJIT only on the smallest target** (kramdown, ZJIT −18 % vs
   YJIT) — where *both* lose to the interpreter anyway. ZJIT's warm-up is
   lighter, so it is less bad on short runs, but that is the zone where you
   want no JIT at all.

## Verdict

**Keep YJIT as Rigor's JIT; do not adopt ZJIT at Ruby 4.0.** On every
workload long enough for a JIT to be worth enabling, YJIT delivers ~1.5–2×
more of the win than ZJIT. The result is consistent with the two JITs'
maturity at this point: YJIT (lazy basic-block versioning, mature) optimizes
Rigor's allocation-heavy, branchy, polymorphic-dispatch hot loops better in
steady state; ZJIT (newer method-based JIT) has a lighter warm-up but does
not yet match YJIT's throughput on this workload. Rigor's deferred-JIT design
(`Rigor::Runtime::Jit`, enable YJIT after a 5 s deadline) already picks the
right JIT and the right moment — this measurement confirms it against the new
option rather than changing it.

## Caveats / re-evaluation triggers

- **Defaults only.** ZJIT (like YJIT) has tuning knobs
  (`--zjit-call-threshold`, …); this compares out-of-the-box behaviour — what
  a user actually gets. Aggressive tuning could shift ZJIT's crossover but is
  not what ships.
- **Warm runs unmeasured.** A warm `rigor check` is ~0.2–1.5 s (IO / require
  bound, not JIT-able); both JITs would lose there, and Rigor never enables a
  JIT on a run that short.
- **Re-evaluate ZJIT** when a future Ruby's ZJIT closes the steady-state gap
  to YJIT on a large-cold `rigor check` (re-run this matrix), or if ZJIT
  becomes the upstream default JIT. Until then YJIT stands.
