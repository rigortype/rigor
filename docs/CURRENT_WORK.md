<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Hard cap: 120 lines, enforced by spec/docs/agent_index_spec.rb. Compress, do not append.
- Verify a claim before carrying it forward, by the thing that decides rather than a proxy —
  including claims in THIS file. Last session's own "next unaudited sections" pointer was wrong.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Next session: the snapshot surface, then a release

Unchanged from the previous handoff and still the next *feature* work: **#434's remaining two**
(regeneration event printing the full `-symbol` diff; `unresolved:` arrays = half the snapshot's
bytes) and **#435 item 3** (drift rows carry no `file:line`; `explain` never covers an
`exhaustive → not` transition) are one PR — same file, same renderer, same specs. Close both with
it. Then consider cutting **v0.3.6**: `[Unreleased]` now carries the 2026-08-25 perf batch plus the
`%a(pure)` silent-lane fix, which is a bug users can hit today. **No autonomous version bumps.**

Also open and independent: **#449** (`Date#to_time` overlay gap), **#427** (warm==cold gate blind
on gem-bump PRs), **#430** / **#431** (design calls), **#460** (parked deliberately — v0.4.x),
**#454** (decide before the #409 default-on flip).

## What the 2026-08-25 session shipped (all merged, master verified green after integration)

Feature-level warm/cold corpus campaign — the question the v0.3.0 cycle never asked: what do the
NON-check surfaces cost warm? Note: `docs/notes/20260825-feature-warm-cold-corpus-perf.md`;
harness preserved on branch `perfbench-harness-20260825`; memory
`project_feature_warm_perf_campaign_20260825`.

- **#473** — `rigor unused` reuses the analysis cache (env restore + plugin producers) and scans
  templates against capital-bearing identifier runs only. Mastodon 8.3 → 2.5 s, byte-identical.
- **#474** — `%a(pure)` / any non-brace annotation spelling was invisible to `ANNOTATION_HINT`, so
  the probe served the fast path while a bound existed (the #428 family through an orthography).
  All five RBS bracket pairs route now, and `EnvelopeScanner.scan` finally implements the
  documented regex pre-filter.
- **#475** — the whole-run effects entry stores `[collections, table]`; a warm hit re-runs neither
  merge nor fixpoint. `internal-spec/effect-summaries.md` § Caching updated in the same commit.
- **#477** — the synthetic scan short-circuits when only trait registries contribute and the
  environment is nil (it built a provably empty index from a 3,229-file parse per run).
- **#478** — per-run validation-stat memo; recording side (`pack_stat`, `GlobEntry`) deliberately
  un-memoised.
- **#480** (continuation) — the sweep's odd cold cell (`effects` +41 % over `check`, same
  analysis) was YJIT: only check/coverage armed the deadline. Proven by perturbing both directions;
  `CLI#dispatch` now arms it for every command. Cold effects at check parity.
- **#481** (continuation) — `Reachability::ScanCache`: one self-validating stat-signed bundle for
  `unused`'s per-file scan + template extraction (the #473 narrowing had moved the bottleneck into
  extraction). Mastodon unused warm 2.7 → 1.1 s; campaign total 8.4 → ~1.1 s (7.8×).
- **ADR-104 (Proposed)** — the effects boot-slim probe, feasibility verified in-code and
  empirically (declared lane cold==warm byte-identical, email.send 68 rows). **#482** (sidecar
  blob split, 0.7 s at gitlab scale) is folded into its implementation slice, not standalone.

**#476 (filed, needs a human design call):** synthetic Tier B is dead in production —
`project_pre_passes` passes `environment: nil` and every trait entry needs the env to explode
module methods, while `Environment.for_project` consumes the scanner's output. Two-phase env,
lazy dispatch-time resolution, or retire the tier; whichever lands removes #477's gate.

## Next perf levers, evidence-ranked (do not re-derive; the note has the numbers)

1. **Implement ADR-104** (effects boot-slim probe, #482 inside it) — the last big warm lever:
   ~0.5 s of every warm effects surface is engine require, plus 0.7 s of blob load at gitlab
   scale. The decline-rule criterion and the `$LOADED_FEATURES` spec shape are in the ADR.
2. **Environment restore at scale** — 0.83 s on gitlab warm, unattributed below
   `Environment.for_project`; sub-attribute before touching (RbsDescriptor digest vs Marshal vs
   lockfile resolve).
3. **`fresh?` scope hoist** for the probe-decline `check` path needs a `with_run` inheritance
   flag — nesting installs a fresh table by design (coverage_mutation relies on it).

## Pitfalls this session paid for

- **A config's relative `paths:` resolve against the CONFIG file's directory.** The first sweep
  measured an empty analysis for every non-check feature; only explicit-path `check` was real.
  Zero-work guards (units > 0, declarations > 0) are now part of the harness.
- **An `effects.envelopes[].match:` glob must be relative** — unit sources are cwd-relativised,
  so an absolute glob selects nothing and the envelope judgment is vacuously green.
- **Keep a Changelog section order is Added, Changed, …, Fixed** — a rebase-conflict resolution
  put Fixed first and CI caught it; the conformance spec must run after the LAST changelog edit,
  including merge resolutions.
- **`String#scan(...).uniq!` returns nil when nothing was removed** — use `.uniq`.
- Wall on this host moved ±0.3 s between same-arm blocks; every landed claim rests on
  byte-identity plus a phase-probe mechanism, not a wall delta alone.
- **After an engine-moving merge, re-prime the diagnostics slot with a `check` run** — `unused`
  never writes it, so the next "warm check" measurement is silently a cold one (it was, twice).
- **The gate call and the commit must never share one `&&` chain** — the piped-exit trap fired
  again (changelog conformance red behind `| tail`, pushed, force-amended). Gate in its own call,
  read `$?`, then commit.
