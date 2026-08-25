# ADR-104 — Boot-slim probe for the effects surfaces

Status: **Proposed, 2026-08-25.** No implementation. Grounded in the 2026-08-25 feature warm/cold
campaign ([`docs/notes/20260825-feature-warm-cold-corpus-perf.md`](../notes/20260825-feature-warm-cold-corpus-perf.md)).

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

## Decision (proposed)

Add an effects probe beside the check probe: `rigor effects` (report), `effects check` and
`effects diff` first attempt to serve from the diagnostics descriptor plus the effects sidecar,
loading configuration, cache, plugin loader and the `effects/*` value layer — not
`rigor/inference`, not `Environment`. Any miss, and any mode the stored values cannot answer,
declines to the full Runner path unchanged.

The criterion, which is the #442/#428 rule generalised: **a probe may serve a surface only when
every answer that surface can give is reproducible from stored values and declarations alone;
an answer computed from live analysis state must either ride the cache entry or force a
decline.** The #428 family documented what happens when the two halves of that rule are decided
separately; a new probe surface adopts it as a design precondition, not a lesson to relearn.

Working decisions expected at implementation time:

- **WD1** — the decline list: sidecar or diagnostics miss, pool-mode configuration, an editor
  buffer, and any CLI mode whose answer is not a pure function of the stored values. Judgment-
  time switches (`--no-tolerated-effects`) stay servable: `tolerated:` is in the effects
  identity, and the switch only changes how the served table is judged.
- **WD2** — non-vacuous serving specs in the ADR-87 shape: the served arm asserts
  `rigor/inference` is absent from `$LOADED_FEATURES`, and the cold arm proves the same
  invocation can produce the answer at all.
- **WD3** — the probe and the Runner share one implementation of "sources from collections" and
  one of the snapshot build, so the served and full paths cannot drift.

## Rejected / deferred alternatives

- **A daemon / watch mode** — flattens the boot cost for every command, already deferred as a
  product decision with the measured shape recorded (2026-07-13 campaign § ④). This ADR's probe
  is the CLI-first answer for the two surfaces measured to need it.
- **Slimming the full path's requires** — the engine require *is* the bulk; there is no useful
  subset of `rigor/inference` that computes the keys but not the analysis.
- **Doing nothing** — leaves every effects gate at 2–2.5× check's warm floor, which reads as
  "effects are expensive" when the expense is an idle boot.

## Consequences

- Warm `rigor effects` / `effects check` land at check-parity plus plugin load and one Marshal
  read (estimated ~0.45 s on Mastodon from the phase attribution; the saving is the engine
  require).
- A second probe surface must stay answer-complete as the effects surfaces grow. The criterion
  above is the guard, and WD2's `$LOADED_FEATURES` specs make a silent divergence a red spec
  rather than a silent lane. **Re-evaluation trigger:** any new effects answer computed from
  live analysis state must add either a sidecar field or a decline before it ships.
- Plugin load stays on the served path (the registry's labels come from it) — measured at
  0.02–0.04 s and required for correctness, not an optimisation gap.

## Relationship to other ADRs

ADR-87 WD4 (the check probe this copies), ADR-45 (the run-result cache), ADR-103 WD12/WD13 and
issue #382/#475 (the sidecar this reads), ADR-97 (index budgets — this entry stays a lookup).
