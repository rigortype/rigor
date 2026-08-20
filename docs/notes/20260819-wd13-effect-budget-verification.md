# Re-verifying the WD13 effect-collection budget (#409): method, and why it runs on CI

Status: measurement note plus the harness it produced. No design commitments. **The local numbers below
are contradicted by a better-provenanced measurement from 2026-08-17 and should not be acted on** — see
the section marked so. The authoritative figures will come from
[`oss-sweep.yml`](../../.github/workflows/oss-sweep.yml)'s `effect-budget` job.

[ADR-103](../adr/103-effect-labels.md) § WD13 states the budget verbatim:

> working budget ≤ ~5 % wall / RSS on mastodon and ≤ 1 s of fixpoint at gitlab scale

and § WD15 makes re-verifying it a precondition for effects-default-on, because "the ≤5% wall/RSS and
≤1s fixpoint figures were measured pre-default-on, when only opted-in projects paid the cost;
universality changes the population the budget has to hold for."

Two things about the bound are easy to get wrong and worth stating plainly. It names **mastodon**, not
the corpus generally. And **gitlab's bound is not the run** — it is the closure, `Propagator.propagate`,
at ≤ 1 s. A full gitlab A/B would be 11,344 files × 2 arms × N reps to answer a question the bound does
not ask.

## The harness

[`tool/effect_budget.rb`](../../tool/effect_budget.rb), also `make effect-budget`. Four properties, each
of which cost something to learn:

- **Interleaved A/B** (off, on, off, on, …), not blocked. A measuring host drifts, and blocked runs
  charge all of the drift to whichever arm ran during it. See below — this is not hypothetical.
- **Median reported with the full range, and an explicit `separated` bit.** If the arms' ranges overlap,
  the reps could not separate them and the delta is a number with no finding behind it. Hiding that
  behind a median is how a noisy measurement becomes a confident wrong answer.
- **`--no-cache`, cache directory removed between runs.** A warm slot serves an unanalysed result in
  milliseconds ([ADR-45](../adr/45-run-result-cache.md)), which reads as a spectacular improvement.
- **A zero-file guard.** Both arms must analyse a positive and *identical* file count or the script
  aborts. The first version of the script wrote its variant configs to a tmpdir; a config's relative
  `paths:` resolve against the config file's own directory, so it analysed nothing, finished in 0.18 s
  and reported a 33 % *improvement*. The guard exists because that is what it did.

## Why the authoritative run is CI, not a laptop

`tool/bench.rb` already names the CI runner "the authoritative measurement host", and peak RSS is only
readable from `/proc` — on macOS `bench.rb` reports RSS as nil and skips the gate.

The local attempt made the case concretely. Partway through, an unrelated process (`target/debug/xtask`,
99.7 % of a core for 48 minutes) took the machine to a load average of 17–29 on 12 cores. The damage is
legible in the timestamps: round 1 finished at 08:17:31, the interloper started at 08:23:34, and the
data breaks at exactly that boundary — mastodon reps 1–4 are tight, rep 5 jumps to 36.98 s, and a
confirmation run afterwards produced 1069 s and 972 s for a run that takes 14 s. A release-gate figure
cannot depend on what else the author happened to be building.

The `effect-budget` job therefore lives in `oss-sweep.yml` beside the existing Mastodon sweep, and
**as its own job** — the sweep restores a warm analysis cache across weekly runs, which is exactly what
a cold cost measurement must not have.

## These figures contradict a careful measurement from two days earlier — do not act on them

**Read this section before the table.** On 2026-08-17,
[`20260817-effect-rails-layer-corpus.md`](20260817-effect-rails-layer-corpus.md) measured the same
question against the **same survey checkouts** (redmine `a12198ea0`, mastodon `163f96cee`), cold,
sequential, cache-wiped, with each project's own plugin list **plus `rigor-railties`**:

| | wall off → on | RSS |
| --- | --- | --- |
| redmine | 8.77 → 9.07 s (**+3.4 %**) | +3.3 % |
| mastodon | 12.82 → 13.26 s (**+3.4 %**) | +0.4 % |

Both inside the budget. The figures below say +9.7 % and +27.9 %. Both cannot be right, and the
earlier one has the better provenance:

- Only **three** commits have touched the effect path since (`b52f7552` snapshot rendering,
  `e9410a9f` the Ractor hang fix — unused at `workers: 0` — and `9a6d482b` the Solid Queue roots, in
  a plugin neither target loads). None of them is on the collection hot path, so a code regression of
  this size has no candidate.
- The earlier run carried **more** work, not less: a fuller plugin set including railties, and a cold
  *enabled* cache that still writes entries where these runs pass `--no-cache` and write none. Both
  differences should make the earlier run slower.
- This host was demonstrably contaminated (below), and while redmine's numbers were taken before the
  interloper started, "before that particular process" is not the same as "on a quiet machine".

The redmine off-arms nearly agree (8.77 vs 8.69 s) while the on-arms do not (9.07 vs 9.53 s), which
is the one detail that keeps this from being pure noise and is worth settling rather than dismissing.
**Settling it is what the CI job is for.** Until it reports, WD13's budget should be read as *last
measured inside, with an unreconciled local contradiction*, not as failing.

## Provisional local figures

Sequential runs (`parallel.workers` defaults to `0`, and neither target sets it, so both arms are
sequential — the fork-pool pinning WD13 mentions does not apply and is not a confound here). This is
also the default user experience, which is the population #409 is asking about.

| target | files | wall off → on | RSS off → on | clean? |
| --- | --- | --- | --- | --- |
| redmine | 347 | 8.69 → 9.53 s (**+9.7 %**) | 304 → 328 MB (+7 %) | yes — ran before the interloper |
| mastodon | 1,312 | 14.57 → 18.63 s (**+27.9 %**) | 558 → 553 MB (noise) | reps 1–4 only; needs CI confirmation |

The mastodon arms did not overlap (max off 16.69 s < min on 17.24 s). Taken alone that would read as a
solid direction; taken against the 2026-08-17 figures it reads as a host artifact that was consistent
across the batch, which non-overlapping ranges cannot distinguish from a real effect. Range separation
proves the reps were sufficient to separate the arms **under the conditions that prevailed**; it says
nothing about whether those conditions were representative.

A mechanism that would explain a large cost *if one exists*, unverified and now doubtful given the
above: collection adds a second full AST walk per file. `Effects::Scanner`
is explicitly "a separate walk … taken here" rather than riding `ScopeIndexer`'s descent, because it
must attribute each recorded call node to its enclosing unit. That is a per-file cost proportional to
the tree, which is the shape of a double-digit percentage rather than a rounding error. Confirming or
refuting it is the obvious next step and is **not** done here.

## YJIT is an RSS confounder and must be reported alongside

On redmine, `RIGOR_DISABLE_YJIT=1` moves peak RSS 303 → 259 MB (−15 %) while making the run *slower*,
8.69 → 9.50 s. Any RSS figure near a 5 % bound is inside the JIT's own swing, so the budget job records
the YJIT-on numbers and any future recalibration should say which it measured.

## What would make this a hard gate

The job ships **advisory**, following the perf-bench precedent ([ADR-50](../adr/50-release-engineering-and-stability-strategy.md)
WD6): a measurement earns the power to fail a release only once its band is known to be stable on the
measuring host. Promoting it needs a few weekly runs establishing the CI band, and then `--gate` in the
workflow step. The first thing those runs have to settle is the contradiction at the top of this note:
whether collection costs ~3 % as measured on 2026-08-17 or something much larger. Whichever it is, the
bound is not being widened to fit a measurement.

## Not done here

- The gitlab fixpoint bound (≤ 1 s). `tool/effect_budget.rb` measures whole runs and is not it: timing
  `Propagator.propagate` at gitlab scale is a separate measurement, and gitlab is not in the sweep at
  all. The closure is a pure function of the merged collection, so it can be timed in-process off one
  analysed run rather than needing an A/B.
- Confirming the double-AST-walk mechanism above.
- Any change to collection's cost. This note measures; it does not optimise.
