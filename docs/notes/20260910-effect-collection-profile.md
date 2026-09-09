# Where effect collection's wall-time delta actually goes (#424)

Status: measurement note. **No code change**, and this note argues that the bounded changes #424 lists
cannot reach WD13's budget. The double-AST-walk hypothesis is **confirmed as the largest single
contributor and refuted as a sufficient explanation** — it is roughly a third of the delta, and the
part of it a shared descent could recover is roughly a seventh.

[ADR-103](../adr/103-effect-labels.md) § WD13 budgets collection at "≤ ~5 % wall / RSS"; § WD16
(2026-08-22) makes the CI `effect-budget` job the arbiter for the mastodon half and re-points the issue
at the `Propagator.propagate` bound. This note profiles the per-project cost anyway, because #424's
second comment asks for exactly that on the **plugin-less** configuration — the shape CI measures and
the population a default-on flip would newly charge.

## The A/B, reproduced locally on the population that matters

`tool/effect_budget.rb`, 3 interleaved reps, redmine (347 files, `app` + `lib`), **no plugins**,
`--no-cache`, sequential (`parallel.workers` default `0`), YJIT on:

| metric | off median | on median | Δ | arms separated? |
| --- | --- | --- | --- | --- |
| wall | 9.05 s (9.02–9.18) | 10.07 s (9.93–10.14) | **+11.3 %** | yes |
| peak RSS | 302.4 MB (294.8–323.5) | 328.3 MB (323.0–332.1) | +8.6 % | no |

The wall arms separate cleanly, and +11.3 % on redmine-without-plugins agrees with the CI job's
+10.9 % on mastodon-without-plugins. It also reconciles the contradiction the
[2026-08-19 note](20260819-wd13-effect-budget-verification.md) left open: that note's redmine arms
loaded the full Rails plugin list, and a larger base divides the same per-file linear cost down. The
plugin-less number is the real one for the question WD13 asks.

RSS is reported for completeness only — the ranges overlap, and a figure near a 5 % bound is inside
YJIT's own swing (2026-08-19, § YJIT).

## Attribution

`stackprof` (0.2.28, installed into a throwaway `GEM_HOME`), `mode: :wall`, 1 ms interval, cwd = the
target, one profiled run per arm, twice. Shares are of the **delta** (on-samples minus off-samples),
which was 710 and 793 samples across the two rep pairs.

| frame (inclusive) | rep 1 | rep 2 | share of delta |
| --- | --- | --- | --- |
| `Effects::Scanner.scan` — the second walk | 281 | 257 | **~36 %** |
| — of which `Effects::UnitScan#run` (method bodies) | 173 | 155 | ~22 % |
| — of which the identity descent (`Scanner#walk` / `walk_namespace` / `enter_def`) | ~91 | ~85 | ~12 % |
| `Effects::Collector.record_call` + `record_unresolved` + `active?` | 127 | 113 | ~15 % |
| `Effects::Propagator.propagate` | 83 | 80 | ~11 % |
| GC (`(marking)` + `(sweeping)`) delta | 70 | ~60 | ~9 % |
| dispersed remainder (snapshot, catalog, `FileCollection`, sampling noise) | — | — | ~29 % |

The phase totals corroborate it without depending on frame-level noise:
`PoolCoordinator#analyze_files_sequentially` moves 8421 → 8816 (rep 1) and 8331 → 8675 (rep 2), a
+395 / +344 per-file delta against a predicted scan-plus-recording cost of ~408 / ~370.

### One frame that looks like a contributor and is not

`Effects::EnvelopeIndex.build` reads as 217 (rep 1) / 251 (rep 2) inclusive samples, which would be a
third of the delta. It is not one. Its whole subtree is `RbsLoader#env` → `build_env_for`, and that
frame costs **211 in the on arm against 210 in the off arm** (rep 1; 244 / 205 in rep 2). The envelope
index simply asks for the built RBS environment earlier than anything else does, so the environment
build is *attributed* to it rather than *caused* by it. Reading the inclusive number without the
cross-arm comparison would have produced a confident wrong answer, which is why the arms were profiled
in pairs.

## Verdict on the hypothesis

**Confirmed in kind, refuted in size.** `Effects::Scanner` does walk every file's tree a second time,
and that walk is the largest single line in the table. But it is ~36 % of the delta, and the delta is
+11.3 %: removing the second walk *entirely* would land at roughly +7 %, still outside the bound.

The sub-split is what actually decides the issue's candidate directions:

- **Direction 1 (ride `ScopeIndexer`'s `def` descent).** The descent is the *smaller* half of the walk.
  `UnitScan#run` — the per-unit body scan that finds calls, ivar writes and globals — is ~22 % of the
  delta and does not become cheaper by being reached from a different parent; only the ~12 % identity
  descent is recoverable, and not all of it, since the attribution WD13 named still has to be paid
  somewhere. Best case is ~1.3 pp off 11.3 pp, bought by putting an effects-shaped concern on the hot
  path of every run — which is the trade WD13 declined when the upside was assumed to be larger.
- **Direction 2 (drive the walk off the `Collector`'s recorded call-site table).** The table covers call
  sites only. `UnitScan` also needs ivar writes, global accesses and local ownership, none of which the
  typer records; the walk would still have to visit the body for them. It addresses `visit_call`, not
  the descent that reaches it.
- **Direction 3 (skip units that cannot contribute).** Deciding a unit is empty requires visiting its
  body, which is the cost being avoided. It could only pay off against a predicate some existing pass
  already computes over the same bodies — which is direction 1 wearing a different hat, with the same
  hot-path cost.

Two other lines are large enough to matter and are not walks at all: per-dispatch recording (~15 %,
already the minimal shape ADR-103 WD13 specifies) and the GC delta (~9 %, the allocation the collection
itself makes). Neither is addressable without changing what collection produces.

## What this means for #424

The ≤ 5 % bound is **not reachable by any bounded change to the scanner**. Reaching it needs either a
single shared descent that subsumes `UnitScan`'s body work as well as the `def` identity walk — a
redesign of `ScopeIndexer`'s pass, paid by every run whether effects are on or not — or a reduction in
what collection proves. Per #424's own acceptance criteria, that is a No-Go input for #409 rather than
something to trim quietly.

`Propagator.propagate` is worth noting separately, since WD16 makes it the live target: at redmine
scale it is 83 / 80 samples, about 0.08 s. The bound it is measured against is the ≤ 1 s one at gitlab
scale, which this measurement does not reach and does not speak to.

## Method notes, for whoever repeats this

- Profile **both arms**, not just the on arm. The `EnvelopeIndex.build` trap above is invisible
  otherwise, and it is worth a third of the delta.
- The base config must have **no plugins**. A full Rails plugin layer changes the answer by a factor of
  three, and it is the plugin-less shape that WD13 has to hold for.
- `--no-cache` plus removing the cache directory between runs, per the 2026-08-19 note: a warm slot
  serves an unanalysed result and reads as an enormous improvement.
- stackprof went into a throwaway `GEM_HOME` reachable through `RUBYLIB` rather than into
  `vendor/bundle`; running it under `GEM_HOME` alone breaks Bundler's view of the bundle.
