# Feature-level warm/cold corpus profile — check, effects, effects check, unused (2026-08-25)

Status: measurement + landed-lever record for the 2026-08-25 warm-path cycle. Successor to
[`20260713-corpus-perf-campaign.md`](20260713-corpus-perf-campaign.md) (which closed the *check*
cold/warm cycle with "the profile-driven levers are spent") — this note asks the question that cycle
did not: what do the **other feature surfaces** cost warm, now that `rigor check`'s fast path is
0.3 s? Baselines taken on master `bed65a46` (v0.3.5); levers landed same-session through PRs
[#473](https://github.com/rigortype/rigor/pull/473),
[#474](https://github.com/rigortype/rigor/pull/474),
[#475](https://github.com/rigortype/rigor/pull/475),
[#477](https://github.com/rigortype/rigor/pull/477),
[#478](https://github.com/rigortype/rigor/pull/478), plus issue
[#476](https://github.com/rigortype/rigor/issues/476).

## Method

- Harness: branch `perfbench-harness-20260825` (kept unmerged, cited here per the
  preserve-the-harness rule). `sweep.rb` drives one flake shell over the survey checkouts
  (`~/repo/ruby/rigor-survey/*`), each cell a fresh subprocess with cwd = the target,
  `BUNDLE_GEMFILE` = this repo's Gemfile, wall from a monotonic clock around the spawn and peak RSS
  from `/usr/bin/time -l`. Configs are derived per project from its committed `.rigor.dist.yml`:
  `baseline:` removed, `paths:` absolutized (a config-relative path silently analyses **nothing** —
  the zero-work guard now aborts the sweep when the effects report sees 0 units or `unused` sees 0
  declarations, after exactly that produced a vacuous first run), scratch `cache.path` per
  (project, variant), `parallel: {workers: 0}` (the run cache declines pool mode).
- Variants: `plain` (no effects), `fx` (`effects: {}` + a scratch snapshot path), `env` (fx + one
  wide `effects.envelopes:` stanza with a **relative** `match:` glob — an absolute glob never
  matches the cwd-relativised unit sources and judges nothing, the second vacuity trap this
  harness hit).
- Warm cells are medians of 3 fresh-process runs; cold cells are single runs (cold levers were
  spent last cycle; this cycle is about warm). Host was **loaded** (load avg ≈ 4, 14 users)
  throughout: wall is read as ratios within a block, byte-identity and phase attribution decide.
- Phase attribution: `prof_phases.rb`, an in-process `Rigor::CLI.start` with prepend-wrapped
  monotonic stamps on the known phases (driver-side monkeypatch; the repo is never modified).
  Nested phases overlap (propagate sits inside serve_collections), so columns are inclusive.

## Baseline (master `bed65a46`, subprocess wall medians)

| project | check warm | effects warm | effects check warm | env check warm | unused | check cold |
| --- | --- | --- | --- | --- | --- | --- |
| kramdown | 0.30 s | 0.56 s | 0.53 s | 0.52 s | 0.68 s | 3.1 s |
| liquid | 0.28 s | 0.49 s | 0.49 s | 0.50 s | 0.71 s | 2.2 s |
| mail | 0.27 s | 0.52 s | 0.50 s | 0.51 s | 0.79 s | 5.2 s |
| redmine | 0.30 s | 0.75 s | 0.73 s | 0.77 s | 2.41 s | 9.2 s |
| mastodon | 0.42 s | 1.12 s | 1.15 s | 1.21 s | **8.37 s** | 13.3 s |

Shape: the boot-slim probe keeps `check` warm flat (~0.3 s) at every project size, `effects: {}`
without declarations keeps that fast path (confirmed), and **every other feature pays 2–3× the fast
path on small projects and diverges with size**. `rigor unused` was the outlier: no cache anywhere,
so its every run is a cold run. Cold `effects` ≈ cold `check` + ~4–6 % — consistent with
[`20260817-effect-collection-perf.md`](20260817-effect-collection-perf.md).

## Phase attribution (warm, in-process run wall — excludes process boot)

redmine `effects` (run 0.38 s): sidecar read+fixpoint 0.17 s (fixpoint 0.106 s) · env restore
0.07 s · pre-passes 0.04 s · `fresh?` ×3 0.02 s. mastodon `effects` (run 0.96–1.12 s):
**pre-passes 0.45–0.54 s, of which `SyntheticMethodScanner.scan` 0.45 s** · sidecar+fixpoint
0.23 s (fixpoint 0.12 s) · env restore 0.15–0.20 s · **`Descriptor#fresh?` ×9** 0.08 s. mastodon
`unused` (run 8.73 s): **`template_mentions` 7.05 s (81 %)** · plugin roots (uncached `#prepare`)
0.50 s · per-file Prism scan 0.47 s · cold RBS env build 0.27–0.36 s · graph 0.10 s.

The `template_mentions` shape: 1,498 declaration names × 21.5 MB of templates (548 locale YAMLs =
13.1 MB, 121 JSONs = 8.0 MB), only **108 names ever match** (1,577 pairs) — ~93 % of the
`String#include?` sweeps scan megabytes to find nothing.

## Levers landed (all output-byte-identical on the measured corpus)

1. **`rigor unused` warm cost** ([#473](https://github.com/rigortype/rigor/pull/473)) — thread the
   cache store into `Environment.for_project` (ADR-54 restore instead of a cold env build) and into
   `PluginRoots` (ADR-60 producer hits), and scan templates against only the de-duplicated maximal
   `[A-Za-z0-9_:]` runs carrying a capital (an FQN starts with a capital and cannot cross a
   non-charset byte — provably the same `include?` answer). `--format json` byte-identical ×5
   corpora; warm 0.59→0.38 / 0.66→0.43 / 0.78→0.55 / 2.21→1.43 / **8.30→2.53 s**.
2. **Annotation-hint bracket routing** ([#474](https://github.com/rigortype/rigor/pull/474)) —
   correctness first: RBS accepts five annotation bracket pairs and the reader honours the payload
   in all of them, but `ANNOTATION_HINT` matched `%a{` alone, so a `%a(pure)`-only project served
   the warm fast path while its bound existed — the #428 silent-lane family through an orthography
   (probe spec fails on the previous lib, verified by toggle). The widened hint also finally
   implements the routing `EnvelopeScanner.scan` was documented to have: an annotation-free
   signature file is answered by one regex and never RBS-parsed.
3. **Propagated-table sidecar** ([#475](https://github.com/rigortype/rigor/pull/475)) — the
   whole-run effects entry stores `[collections, table]`; a warm hit adopts both and re-runs
   neither `merge_all` nor the fixpoint. Sound because that slot is already invalidated by every
   analyzed file (same post-run dependency descriptor as diagnostics) and every meaning input (the
   effects identity); the never-persist rationale genuinely binds only the ADR-46 incremental
   snapshot, which still carries collections only. Spec updated in the same commit
   (`internal-spec/effect-summaries.md` § Caching). redmine `effects` warm 0.75→0.61 s,
   `effects check` 0.73→0.60 s; byte-identical cold vs warm.
4. **Synthetic-scan short-circuit** ([#477](https://github.com/rigortype/rigor/pull/477), issue
   [#476](https://github.com/rigortype/rigor/issues/476)) — the production pre-pass passes
   `environment: nil`, under which every trait-registry entry provably emits nothing, so
   mastodon's scan Prism-parsed 3,229 files per run (warm included — the only whole-project parse
   left on a warm effects run since PR #77) to build an empty index. Scan now returns EMPTY before
   any I/O when only trait registries contribute and there is no environment. mastodon `effects`
   warm 1.12→0.90 s. The genuinely dead Tier-B lane (devise's synthesized methods never resolve
   through it) is #476 — a design call, not a perf patch.
5. **Validation stat memo** ([#478](https://github.com/rigortype/rigor/pull/478)) — a collecting
   run validated the effects and diagnostics entries against the same ~5k-file descriptor twice
   (the digest memo never engages on the happy stat tier); `with_run` now carries a stat table for
   the validation side only. `pack_stat` and `GlobEntry.signature_for` stay direct — the recording
   side must describe its own moment.

## Non-targets and residue (measured, for the next cycle)

- **Process boot dominates what remains of warm `effects`**: ~0.5 s of the ~0.6–0.9 s subprocess
  wall is ruby+bundler+require, not run work. The structural fix is an `effects`-shaped boot-slim
  probe (serve the report from the two slots + the stored table without loading the engine) — a
  design slice, contingent on #475's table entry, sketched but not attempted this session.
- **`unused` residue** (mastodon ~2.5 s): the per-file Prism scan (0.47 s, single-threaded,
  cacheless), the narrowed-but-still-N×M template scan, and the graph. A per-file scan cache or a
  pool ride is the next lever; the `tainted` O(U × mentions) term shrank with the mention count.
- ~~The envelope-judgment discovery parse~~ — landed as
  [#479](https://github.com/rigortype/rigor/pull/479) after this note's first cut (see the †
  caveat above).
- **`fresh?` scope topology**: the probe opens its own `with_run`, so a probe-decline `check` still
  pays validation twice (probe + Runner). Hoisting the scope into `check_command` would collapse it
  but `with_run` nesting installs a *fresh* table by design (coverage_mutation relies on it) — a
  scope-inheritance flag is the shape, deferred.
- **GlobEntry duplicate walks** (actionpack + pundit both watch `app/controllers/**/*.rb`): the
  stat memo collapses the per-file stats but each `Dir.glob` traversal still runs; small.
- **Wall noise**: the loaded host moved same-arm numbers by up to ±0.3 s between blocks
  (mastodon effects warm read 1.07–1.67 s across the afternoon). Every claim above rests on
  byte-identity plus a mechanism the phase probe located, not on a wall delta alone.

## Integrated after-sweep (master `9d56380b`, all five PRs merged, same harness)

Warm medians of 3 (`unused`: the second, cache-warm rep — the first primes the env blob and the
n = 2 median otherwise reports the priming run, which is how a −44 % first read as +16 %):

| project | check warm | effects warm | effects check | env check warm | unused warm |
| --- | --- | --- | --- | --- | --- |
| kramdown | 0.25 s | 0.43 s (−22 %) | 0.45 s | 0.45 s | 0.35 s (−44 %) |
| liquid | 0.24 s | 0.46 s (−6 %) | 0.46 s | 0.47 s | 0.39 s (−44 %) |
| mail | 0.25 s | 0.46 s (−12 %) | 0.46 s | 1.03 s † | 0.54 s (−30 %) |
| redmine | 0.24 s | **0.56 s (−26 %)** | 0.57 s (−23 %) | 0.57 s | 1.39 s (−40 %) |
| mastodon | 0.32 s | **0.74 s (−34 %)** | 0.77 s (−33 %) | 0.81 s (−33 %) | **2.53 s (−69 %)** |

Diagnostic/report bytes are identical to the baseline sweep in every cell. Two honest caveats:

- **† The env column is not apples-to-apples across sweeps.** The baseline sweep's envelope
  `match:` glob was absolute and therefore selected nothing (the vacuity trap § Method); the
  after-sweep's is relative and really judges. A judged envelope forces `ensure_project_discovery`
  — one Prism parse of every analyzed file — **even when zero findings result**, and mail is the
  corpus's parse-cost outlier (0.53 s for 111 files, P6 recon), which is the whole +0.5 s. Redmine
  and mastodon beat their vacuous baselines *while* paying the real judgment. The lever this
  exposed **landed same-session as [#479](https://github.com/rigortype/rigor/pull/479)**: both
  judgments now read positions per finding through a `DeferredPositions`, so a judged-clean
  envelope forces no discovery — mail env warm 1.03 s → **0.46 s (−55 %)**, redmine/mastodon
  timing-neutral (their parse is not the dominant term), output byte-identical on all three.
- The across-sweep improvement in the untouched `check warm` / cold columns (−7…−25 %) is host
  drift between the two sweep sessions, not a lever; the per-lever interleaved A/Bs above are the
  precision evidence, the integrated sweep the corroboration.

## Continuation (same day) — the cold gap, the gitlab validation, and the second `unused` cache

The residue list above scheduled two measurements before further optimisation; both paid off.

**The cold `effects` gap was YJIT, and the fix covers every command ([#480](https://github.com/rigortype/rigor/pull/480)).**
The baseline sweep's odd cold cell — `rigor effects` 20.9 s against `check` 15.4 s on mastodon,
same config — reproduced interleaved (14.7/14.8/14.9 s vs 21.6/20.8/21.9 s, +41–47 %), with both
arms writing byte-for-byte the same 8,640 KB cache (collection and the sidecar write — measured at
0.17 s in-process — both exonerated). The mechanism: `Runtime::Jit.enable_after` was armed only in
`check` / `coverage`, so every other command ran interpreted however long it took. Perturbing it
both ways swapped the numbers exactly (effects + `RUBY_YJIT_ENABLE=1` → 15.9 s; check +
`RIGOR_DISABLE_YJIT=1` → 21.1 s). The fix arms the deadline in `CLI#dispatch` for every command —
a run that finishes inside the window still never pays compile — confirmed at parity (17.4 s check
/ 17.8 s effects in one pair). This also covers `unused`, `sig-gen`, `type-scan`, `annotate`.

**gitlab-scale validation of the #475 sidecar.** Cold prime 205.9 s; warm `rigor effects`
3.1–3.7 s (check warm 0.7 s). The warm decomposition at this scale: environment restore 0.83 s,
sidecar Marshal load 0.71 s (the entry is **6.9 MB** of `[collections, table]`), dependency
validation 0.48–0.58 s across the slots, plugin prepare 0.42 s. The warm path only consumes the
table, the sources and the ancestry from that blob — the split is filed as
[#482](https://github.com/rigortype/rigor/issues/482) and deliberately folded into ADR-104's
implementation (the boot-slim probe needs the same small payload), not landed twice.

**`unused` round two: the extraction was the new bottleneck, and a per-file bundle removes it
([#481](https://github.com/rigortype/rigor/pull/481)).** Decision measurements first: the #473
narrowing had moved the template cost from matching into extraction (read + scrub + regex = 1.29 s
against 0.27 s of matching on mastodon), so a global-haystack index would have optimised the wrong
term; and a Marshal restore of all per-file scan results is 25× under the ADR-54 beats-recompute
bar (1.8 MB blob, 0.03 s load vs 0.66 s rescan). `Analysis::Reachability::ScanCache` — one
self-validating stat-signed bundle, the IncrementalSnapshot shape because the sound unit of reuse
is the file — caches both passes: mastodon 2.74 → **1.07 s**, redmine 1.53 → **0.81 s**, mail
0.59 → 0.42 s, kramdown/liquid at parity, `--format json` byte-identical on all five. Cumulative
across the campaign, mastodon `rigor unused` went **8.37 → 1.07 s (7.8×)**.

Integrated spot-check on the merged master (`905602ea`, warm cells, this host): redmine
check 0.30 s / effects 0.64 s / effects check 0.62 s / unused 0.74 s; mastodon 0.31 / 0.90 /
0.80 / 1.20 s. One harness note for the next session: after an engine-source-moving merge,
re-prime the **diagnostics** slot with a `check` run — `unused` does not write it, and the first
"warm" check otherwise measures a cold one (it did here, 8.6/11.8 s, before re-priming).

**The boot-slim probe is now [ADR-104](../adr/104-effects-boot-slim-probe.md) (Proposed).** The
feasibility facts are verified in the ADR: the effects identity is a pure function of
configuration, shipped data and plugin contributions (`PluginFacts#compute_digest` reads no
discovery table), and the declared-lane ancestry linking is baked into the cached collections.
Remaining residue after this continuation: the probe itself (~0.5 s of every warm effects
subprocess), #482's blob split (0.7 s at gitlab scale, inside ADR-104), the environment restore's
scale behaviour (0.83 s on gitlab — unattributed below `Environment.for_project`), and the
`fresh?` scope topology and GlobEntry items above, unchanged.

## Reconciliation with prior art

The redmine warm-check 0.25→0.92 s figure in the #442 probe note reproduces here as
plain 0.30 s vs env 0.77 s (same mechanism, this host). The 20260817 collection-cost ratios
(+5.5 % / +3.9 % cold) reproduce as cold `fx` ≈ cold `plain` within single-run noise. No prior
note had measured `rigor unused` or the warm `effects` report; those are this note's additions.
