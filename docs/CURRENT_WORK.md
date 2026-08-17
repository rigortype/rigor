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

## Where things stand

- **The effect-labels stack merged into master at `86226e62` (2026-08-17)** — thirteen PRs
  #395 → #408 in one `gh stack merge`, then `make verify` re-run on the INTEGRATED master (9,845
  examples, `check` + `check-plugins` clean). Design: [ADR-103](adr/103-effect-labels.md) (WD1–WD15)
  and `docs/design/20260816-effect-labels.md`; umbrella issue #376. Slices #377, #379–#388 are
  closed. v0.3.3 remains the released version — no bump is due; the CHANGELOG `[Unreleased]` carries
  the `**[effects]**` / `**[plugins]**` entries.
- **What shipped, in one line each**: the label vocabulary + registry (`data/effects/registry.yml`,
  Steins' 25 verbatim + `mutate.self/instance/static` + shared roots); the collector (observational,
  `DependencyRecorder`-shaped, one integer read when off) + post-pool fixpoint + `rigor effects`
  report; the committed effect snapshot (`rigor effects update|check|diff|explain`,
  `.rigor-effects.yml`, symmetric gate + `additions`); the hand-audited catalogue
  (`data/effects/core.yml`, 80 classes / 420 rows, six narrowing handlers); the WD13 perf fix
  (superlinear `FileCollection#merge` fold — mastodon +50 % → +3.9 %); persistence (one cache, two
  identities, effects sidecar); RBS envelopes `%a{pure}` / `%a{rigor:v1:effect …}` +
  `effect.envelope-exceeded`; `effect.unknown-label` + `effect.annotations-unchecked` + the `.rb`
  rbs-inline path (handbook corrected); `.rigor.yml` `effects.{envelopes,attribution,labels,
  tolerated}` with per-origin discharge and `--no-tolerated-effects`; the declared lane through
  nominal carriers + `effect.liskov-widened`; the Rails layer (five manifest fields, new
  `plugins/rigor-railties`, ~400 rows, callback / mailer / `perform_now` edges, queue-adapter
  narrowing, `reach: [rails]`); `%a{pure}` across ActiveSupport core_ext; the
  `effects-on-by-default` bleeding-edge preview.
- **Owner ruling: effects become default-on at v0.4.0** (`effects: false` opts out) — ADR-103 WD15.
  Preconditions are tracked in **#409** (with #410 non-fork pool backends carrying the side-table,
  #411 the snapshot's taint-only rows, #378 Steins vocabulary alignment).
- **Measured at the stack top** (redmine `app`+`lib`, sequential, cold): `rigor check` off 9.99 s /
  375 MB → on 10.37 s / 396 MB; warm ~0.7 s either way; `rigor effects check` after a warm `check`
  ≈ 1.1 s; diagnostics byte-identical off vs on. Corpus notes: `docs/notes/20260817-effect-*.md`.

## Next session

- **A second stack** for the remaining slices, in this order: #389 (B2.2 ivar-reset skip — the
  first *typing* consumer; must land as a `BleedingEdge` `:behaviour` feature folded into the
  analysis-cache identity, off by default, corpus-adjudicated), #390 (`effect.discarded-pure-result`,
  `:off` pending a corpus gate), #391 (`rigor sig-gen` write-back of `%a{pure}` / envelopes), then
  views #392 → #393 → #394. #378 needs the owner (a Steins issue).
- **The dominant taint on a Rails app is `unresolved-self-call`** (the Rails layer barely moved the
  exhaustive ratio: redmine 16.1 → 16.6 %); `render`'s `template-not-analysed` fires 249/329 on the
  corpus — #392's debt, now countable. Improving self-call resolution is the highest-leverage engine
  work for the effect system's signal.
- Two `sig/*.rbs` one-liners were hand-added where `rigor sig-gen --print` declined to emit
  (`Configuration#initialize` arity, `read_effect_envelope`, `filter_suppressed`) — the ADR-14 gap
  signal, reported in the PR bodies, not yet filed as a sig-gen issue.

## What this arc learned that is not in a commit

- **The delegation brief that works** (unchanged from the last arc, confirmed on 13 slices): fixed
  design + repo contract verbatim + gates by exit code + parent re-runs the gates + "report
  contradictions, do not silently redesign" + **run gates in the FOREGROUND with an explicit
  timeout**. One Sonnet slice (#388) stalled on a background `make verify` and had to be finished
  by the parent — the foreground rule is not optional.
- **Audit the design, not just the gates.** Two subagent decisions contradicted the ADR while every
  gate was green: the declared lane was made direct-only (Steins/WD1: it travels edges) and the
  catalogue slice's census exposed a superlinear fold the tracer's small fixture never showed. A
  corpus measurement per slice is what caught both; keep it in every brief that changes hot code.
- **`gh stack` non-interactive discipline held**: `submit --auto`, `view --json`, `merge --yes
  --merge`; an empty top branch is removed with `unstack --local` + `init` over the existing names.
- **Survey-project measurement traps**: `paths:` in a scratch config resolve relative to the config
  file (use absolute paths); the `effects` verbs take no `--no-ci-detect`; a scratch config's
  `cache.path` keeps the survey checkout clean, but `effects update` writes `.rigor-effects.yml`
  into the cwd — delete it.
