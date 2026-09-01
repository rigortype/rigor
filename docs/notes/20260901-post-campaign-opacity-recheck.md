# Post-campaign opacity re-attribution — the sweep probe re-run on merged master (2026-09-01)

Status: measurement note. Master `a7e5d805` (all 20 campaign PRs + ADR-105 merged). Sequel to
[`20260901-corpus-opacity-attribution.md`](20260901-corpus-opacity-attribution.md), discharging its
standing caveat: that sweep's counts were taken pre-#535 under an under-seeded lens, and its own
handoff required a re-run before sizing any new lever. This note is that re-run, plus the
verification passes on every cluster the fresh numbers left ambiguous.

## Method

The preserved probe (`opacity-sweep-harness-20260901`, byte-identical to the original) re-run over
all 30 targets. The probe calls `CoverageScan.discovery_seeded_scope` + the plugin-aware
`ProjectContext` environment, so post-#535 it inherits the full eleven-table seed by construction —
the #513 caveat no longer applies to these counts. Four independent verification agents adjudicated
the ambiguous clusters (Mutex/generic-binding, the redmine AR family, the two precision drops, and
a misc set), each with same-file controls and a positive control proving the harness could show the
signal. Re-run outputs and the attribution harness are preserved on the same branch
(`tool/opacity-sweep-20260901/rerun-20260901/`).

## Headline

Corpus-weighted expression precision is **57.6% excluding mail** (1,193,501 exprs total; mail's
ragel constant inflation carries 422k exprs at 97.98%). Campaign deltas on the anchor targets:
mastodon **48.9 → 54.8%** (+5.9pp), redmine 47.8 → 50.2%, rigor-lib 59.3 → 61.3% (paired lens),
kramdown +2.8pp, tdiary-core +2.8pp, herb +2.7pp, rbnacl +5.3pp; every target improved except two:

- **numo-narray −3.44pp and Data-Structures-and-Algorithms-in-Ruby −0.54pp are intended trades,
  zero unexplained residue.** A three-arm A/B (pre-campaign base / base+#537 / master) row-aligned
  over every expression attributes all losing sites to #537 (overload Dynamic-pin: `[true] * n` no
  longer answers `String`; numeric-arith joins over Dynamic operands) and #559 (phantom-Hash
  removal), both wrong-precise → honest-Dynamic corrections; the other campaign commits are net
  positive on both targets (+23 / +454) and simply don't offset #537 on arithmetic-dense code.
- Metric finding from that A/B: the precision lens scores `dynamic_top → dynamic_specific`
  transitions (113 on DSA, 74 standing on numo) as zero while scoring honest widening as full loss —
  it systematically under-credits #537-shaped correctness fixes. Read these two lines as the cost of
  killing 18 corpus FPs, not as a regression to chase.

## Where the remaining opacity is (named-receiver-opaque pairs, 12,082 sites, all targets)

| lane | sites | disposition |
| --- | --- | --- |
| Rails plugin surface: `Parameters#[]` 1,077, `Rails.*` readers 288, Duration 195, Flash/Session/Request ~350, sidekiq 64 | ~2,015 | [#534](https://github.com/rigortype/rigor/issues/534) — the widest tractable lever |
| **rigor-activerecord dead on schema-less apps** — `table_name` family 517 + first-hop `.where`/`.visible`/`.find` ~127, redmine | ~650 direct | **[#569](https://github.com/rigortype/rigor/issues/569)** (new): the plugin's `model_index` is all-or-nothing on `db/schema.rb`, which redmine gitignores; scopes/associations/table_name need no schema |
| container / stale-shape (`{}#[]=`, `Array[Dynamic]#[]`, tuple min/max…) | ~1,640 + 735 bare-container | mixed: [#560](https://github.com/rigortype/rigor/issues/560) join family + [#531](https://github.com/rigortype/rigor/issues/531) + honest C-propagation |
| mail struct-factory accessors (`AddressStruct#local=` …) | 296 | [#525](https://github.com/rigortype/rigor/issues/525) — re-measured up from 39 at filing; carrier already named, the fold-safety gate after setter writes is what declines |
| `singleton(User)#current` (redmine) | 494 | honest: `ActiveSupport::CurrentAttributes` macro + Dynamic-rooted `\|\|=`; even a full model caps at `Dynamic \| User`. Declined as a lever |
| Mutex/Monitor `#synchronize` | 75 | 65/66 honest propagation (generic X binds correctly); 1 site = the new [#533](https://github.com/rigortype/rigor/issues/533) item 9 |
| `Thread#[]`/`[]=`, `JSON.pretty_generate` | 78 + 28 | honest RBS `untyped`; the JSON pair is the one narrowable via a fold — [#570](https://github.com/rigortype/rigor/issues/570) (new) |
| user-class accessor/param returns (Heap/Graph/Tree, `Type::*` readers, Kramdown::Element…) | bulk of the 6.7k tail | the closed ADR-67/ADR-58 parameter lane; do not reopen |

Implicit-self opacity (37k sites corpus-wide) stays framework-shaped: Rails controller/view DSL ~4.7k
+ AR macros ~1.4k in the top-40 lists alone ([#534](https://github.com/rigortype/rigor/issues/534)
territory), and mail's `chars` cluster (218) plus `Mail::Utilities.blank?` (41) verified honest —
#554's singleton fold resolves existence correctly; the bodies operate on untyped params, so the
return summaries are genuinely `Dynamic`-bearing unions.

## New mechanisms found and filed

- **[#569](https://github.com/rigortype/rigor/issues/569)** — rigor-activerecord all-or-nothing
  schema gate (above). The largest single unlock found by this re-run: redmine currently gets zero
  AR typing, so a columns-less degraded `ModelIndex` is additive by construction.
- **[#533](https://github.com/rigortype/rigor/issues/533) item 9** — the block-return-typing pass
  evaluates only the body's last statement in the entry scope, so `m.synchronize do v = 42; v end`
  answers Dynamic while `{ 42 }` binds. Two corpus sites; recorded for correctness, not yield.
- **[#570](https://github.com/rigortype/rigor/issues/570)** — `JSON.generate`/`pretty_generate`
  fold to `String` (upstream RBS declares `untyped`).

## Instrument findings (add to the probe-pitfall ledger)

- `rigor type-of` cannot reproduce discovery-seeded joins: the phantom-Hash shape (#553/#559) and
  `{}`-seeded hash joins read `Dynamic[top]` under type-of on BOTH arms of an A/B — a type-of-only
  investigation concludes "no change" falsely. Binding-level claims need the probe's
  `discovery_seeded_scope` lens (or `check` itself).
- The precision ratio treats `dynamic_specific` as worthless (above); pair it with the FP tally
  before ranking any wrong-precise fix.

## Ranking after this re-run

1. **[#569](https://github.com/rigortype/rigor/issues/569)** — one bounded plugin change, ~650
   direct sites on redmine plus every schema-less Rails app, no FP surface.
2. **[#534](https://github.com/rigortype/rigor/issues/534)** — `Parameters#[]`/`expect`/`slice`
   first (1,077 sites), then Rails readers / Duration / sidekiq; each sub-item independently
   landable under the existing plugin FP argument.
3. **[#560](https://github.com/rigortype/rigor/issues/560)** — the ADDED-value join: small site
   count but it is the live always-falsey FP family, and mail's ragel cluster shares the root.
4. **[#525](https://github.com/rigortype/rigor/issues/525)** — evidence upgraded (296 mail sites);
   the design pass should now cover the setter-then-read fold-safety shape too.
5. Small/opportunistic: [#570](https://github.com/rigortype/rigor/issues/570),
   [#533](https://github.com/rigortype/rigor/issues/533) items 1/5/7/9, and the standing
   ready-for-human policy calls ([#541](https://github.com/rigortype/rigor/issues/541),
   [#542](https://github.com/rigortype/rigor/issues/542),
   [#531](https://github.com/rigortype/rigor/issues/531)) unchanged by this re-run.
