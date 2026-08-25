# ADR-104 — Boot-slim probe for the effects surfaces

Status: **Accepted, 2026-08-26.** Implemented for `rigor effects` and the four snapshot verbs
(`Analysis::EffectsCacheProbe`), on top of the #482 entry split this ADR's slice absorbed. Grounded
in the 2026-08-25 feature warm/cold campaign
([`docs/notes/20260825-feature-warm-cold-corpus-perf.md`](../notes/20260825-feature-warm-cold-corpus-perf.md)).

## Context

After the 2026-08-25 campaign landed the effects table sidecar (#475), the synthetic-scan
short-circuit (#477) and the lazy envelope positions (#479), a warm `rigor effects` / `rigor
effects check` does almost no work — and still costs 2–2.5× a warm `rigor check`. Measured on
Mastodon: 0.74 s against check's 0.37 s, of which the in-run work is 0.35 s and the rest is
process boot — `require` of the inference engine and the environment layer, loaded only to
compute two cache keys and adopt two cached values. `rigor check` already refuses to pay this:
ADR-87 WD4's `RunCacheProbe` serves a warm check without `rigor/inference` entering
`$LOADED_FEATURES`. The effects surfaces have no equivalent, so every effects CI gate pays an
engine boot per run to read a Marshal blob.

Feasibility, verified against the current code rather than assumed:

- The diagnostics key half is already engine-free — `RunCacheProbe` computes it today
  (`lib/rigor/analysis/run_cache_key.rb`).
- The effects identity on top (`lib/rigor/effects/identity.rb`) digests the vocabulary version,
  the catalogue file, the `effects:` block, and `PluginFacts#digest` — and `compute_digest`
  (`lib/rigor/effects/plugin_facts.rb:325`) is a pure function of the loaded plugins' declared
  contributions. It needs `Plugin::Loader`, never the engine and never project discovery.
- The report needs the propagated table and the per-unit sources; both are in the #475 sidecar
  (`[collections, table]` — sources derive from the collections' summary keys). The
  ancestry-dependent declared-lane linking (#464/#467) happens at collection time and is baked
  into the cached summaries, so a served run cannot lose it.
- `effects check` / `diff` additionally need the registry (plugin load), the reach globs
  (configuration) and the committed snapshot (a YAML read). `Snapshot.build` was measured at
  0.006 s.

## Decision

An effects probe beside the check probe: `rigor effects` and the four snapshot verbs first
attempt to serve from the whole-run effects summary entry, loading configuration, cache, the
plugin loader and the `effects/*` value layer — not `rigor/inference`, not `Environment`. Any
miss, and any mode the stored values cannot answer, declines to the full Runner path unchanged.

The criterion, which is the #442/#428 rule generalised: **a probe may serve a surface only when
every answer that surface can give is reproducible from stored values and declarations alone;
an answer computed from live analysis state must either ride the cache entry or force a
decline.** The #428 family documented what happens when the two halves of that rule are decided
separately; a new probe surface adopts it as a design precondition, not a lesson to relearn.

Working decisions, as implemented:

- **WD1** — the decline list is every reason the key cannot be reproduced or the entry cannot
  answer: no cache root, `effects.check?` off, a key the probe cannot rebuild (a project whose
  plugins synthesise virtual RBS, which the ADR-87 probe already declines for the same reason),
  a miss, a stale dependency, a corrupt entry, a stored value of the wrong shape. A path
  argument is *not* a decline — it joins the analysed set exactly as it does on the runner path,
  and keys the entry accordingly, so an uncovered scope declines as an ordinary miss.
- **WD2** — non-vacuous serving specs in the ADR-87 shape, in a subprocess. The served arm
  asserts **zero** `analysis/runner` / `environment` / `scope` entries in `$LOADED_FEATURES`
  against an analysing control that loads ~90; the `inference/` directory count is asserted as
  an order-of-magnitude drop rather than zero, because `Effects::Catalog` and `Reflection` pull
  a handful of value-layer files from that directory on any path that can name a label at all.
  Every decline example is paired with a must-still-answer one, and the drift gate is proven to
  still exit 1.
- **WD3** — one snapshot build, whichever lane produced its inputs (`#snapshot_from`), and the
  probe hands back the vocabulary it already built for the key rather than letting the caller
  rebuild one, so a served answer and an analysed one cannot drift.
- **WD4** (absorbed from [#482](https://github.com/rigortype/rigor/issues/482)) — the whole-run
  effects cache spends two entries under one key and one dependency descriptor: the summary a
  warm run serves from, and the collections only an incremental recheck and the fail-soft
  re-propagation read. The collections stay reachable behind a loader, so a consumer the split
  did not anticipate loads them rather than reading an empty table.

## Rejected / deferred alternatives

- **A daemon / watch mode** — flattens the boot cost for every command, already deferred as a
  product decision with the measured shape recorded (2026-07-13 campaign § ④). This ADR's probe
  is the CLI-first answer for the two surfaces measured to need it.
- **Slimming the full path's requires** — the engine require *is* the bulk; there is no useful
  subset of `rigor/inference` that computes the keys but not the analysis.
- **Doing nothing** — leaves every effects gate at 2–2.5× check's warm floor, which reads as
  "effects are expensive" when the expense is an idle boot.

## Consequences

- Warm `rigor effects` **−34 % / −38 %** and `rigor effects check` **−26 % / −38 %** on
  redmine / mastodon (interleaved A/B, three reps, medians 0.76 → 0.50 s and 0.93 → 0.58 s;
  every rep of the served arm beat every rep of the analysing one). Output is byte-identical on
  both projects across the default report, `--full --why`, `--format json` and `explain` —
  175,534 lines of JSON on mastodon.
- A second probe surface must stay answer-complete as the effects surfaces grow. The criterion
  above is the guard, and WD2's `$LOADED_FEATURES` specs make a silent divergence a red spec
  rather than a silent lane. **Re-evaluation trigger:** any new effects answer computed from
  live analysis state must add either a summary-entry field or a decline before it ships.
- Plugin load stays on the served path (the vocabulary comes from it, and so does the key) —
  measured at 0.02–0.04 s and required for correctness, not an optimisation gap.
- **The summary entry is not small at scale, and #482's estimate of it was wrong.** On gitlab
  `app lib` it is 5.1 MB against the collections' 4.8 MB: the table carries `causes` and `edges`
  per row, which is what makes `explain` and `--why` servable. Dropping them would halve the
  read and silently break both surfaces on a warm run — precisely what the criterion forbids —
  so the split's win at monorepo scale is "load one blob instead of two", not "load almost
  nothing". Measured, recorded, not chased.

## Relationship to other ADRs

ADR-87 WD4 (the check probe this copies), ADR-45 (the run-result cache), ADR-103 WD12/WD13 and
issue #382/#475 (the sidecar this reads), ADR-97 (index budgets — this entry stays a lookup).
