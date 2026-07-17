<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward. Three items died of this in one week: a "live bug, do
  this first" refuted by its own repro (guarded since 2026-05-01), an "open" AR-lambda item fixed
  since 2026-05-28 (`fde760a2`), and ~40% of the old ROADMAP backlog already shipped.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Where things stand

- **v0.3.0 is nearly assembled.** The 2026-07-17 triage's implementation wave is done: ten issues
  closed this cycle (#161 #164 #172 #174 #176 #177 #178 + the config batch), PRs #175 #179–#185 all
  merged. Milestone open: **#121** (ongoing fold category, one slice landed), **#162** (direct-void
  slice, see below), **#173** (rbs-inline, slice 1 of 5 in PR #186). `[Unreleased]` holds **63
  bullets** — sealing them is the release step `make verify` cannot rescue; budget for it.
- **PR #186 is open and awaiting review**: the ADR-93 WD1 default flip (`require_magic_comment` →
  `false`, annotation-presence-gated). Verified standalone: 18 plugin-spec examples, full
  `make verify` green on the branch. It only affects projects that already load the plugin.
- ADR-100 landed (`f6112ae3`): the `static.*` family split, `static.value-use.void` as first id, the
  `void_origins` interface. #130's cut-scoped piece landed in #184; the issue left the milestone,
  keeping only deferred follow-ons.
- `make verify` and `make docs-check` clean on master; master and `origin/master` agree.

## Next session — three tracks, in this order

**1. Review/merge PR #187 — the #162 void slice landed.** The agent finished after the handoff was
first written: `static.value-use.void` behind the new `use-of-void-value` bleeding-edge feature,
`void_origins` mirroring `dynamic_origins`, spec rows in the same commit, `Advances #162` (the
transitive case + budget ids stay tracked). Verified this session: gates green, teeth 2+1, CHANGELOG
conflict resolved and re-verified (EXIT=0), mergeState CLEAN. One honest deviation worth knowing at
review: the issue's `x = puts(1)` example was wrong — core RBS declares `puts` `-> nil`, not
`-> void` (verified against `references/rbs`), so the fixtures use an author-declared `-> void`
method, which is the rule's actual normative trigger.

**2. #173 slices 2–5 — the auto-wire. This is the careful one; do not fleet it.** Slice 1 (the
default flip) is PR #186. What remains, with the design already settled and the blast radius already
measured this session:

- **The shape is decided**: the loader stays generic; auto-wiring is a *config-level* policy. Filter
  `enabled: false` entries in `Plugin::Loader#resolve_entries` (an entry-level key — the maintainer
  chose the `pluginEntry.enabled` form over a dedicated top-level key or a `disable_plugins:` list),
  and inject `{gem: "rigor-rbs-inline", config: {require_magic_comment: false}}` from the
  **`Configuration.load` path only** (the real-project route) — NOT `Configuration#initialize`, or
  every bare `Configuration.new` in the suite auto-wires. Gate on: not explicitly listed (gem name
  `rigor-rbs-inline` *or* manifest id `rbs-inline` — the loader raises on a duplicate id), not
  disabled, and upstream resolvable (`Gem::Specification.find_by_name("rbs-inline")`, a probe with no
  load side effect).
- **The measured blast radius** (a loader-level prototype was built, run, and reverted this session):
  `make verify` fails ~30 examples across 6 files — `plugin/loader_spec` (18; stays untouched once
  auto-wire moves out of the loader), `analysis/plugin_fact_fingerprint_spec` (8),
  `integration/plugins/activerecord_plugin_spec`, `integration/examples/routes_plugin_spec`,
  `integration/precision_snapshot_spec`, `ractor_readiness_spec`. Each integration failure must be
  **adjudicated individually**: stale assertion of the plugin-less world (update) vs real regression
  (fix). Do not bulk-update; this cycle's lesson is that the two look identical at a glance.
- Slice 3: `enabled` (boolean) on `pluginEntry` in `schemas/rigor-config.schema.json` (ADR-99 makes
  the schema a source of truth; the key becomes public vocabulary). Slice 4: the WD3 standalone
  residual — an `rbs.coverage.*`-style `:info` hint when annotation-shaped comments are seen with no
  synthesizer available (do NOT make `rbs-inline` a core dependency; ADR-0). Slice 5: flip ADR-93 to
  Accepted with WD2/WD3 resolved in its text + the `overview.md` divergence marker updated.
- Corpus gate at the end: mail / kramdown / haml / liquid byte-identical, herb keeps its −3 wins
  (the WD4 corpora, all under `~/repo/ruby/rigor-survey/`).

**3. Release — seal the CHANGELOG.** 63 `[Unreleased]` bullets. The `rigor-release-prep` skill is
the flow; **version bumps and `rake release` stay user-gated** — land entries, stop, and let the
user drive the cut-over (AGENTS.md § Release Cadence).

## Decided this cycle — do not re-litigate

- **The `enabled: false` opt-out shape** (pluginEntry key) — maintainer-decided 2026-07-18, over a
  dedicated top-level key and a `disable_plugins:` list.
- **#152** (widen `&&`/`||` polarity) is evidence-rejected, demand-gated, off the milestone — the
  measured evaluation is on the issue. **#126** (length-range carrier): its own design pass says
  don't build; demand-gated. **#120** (`--incremental` default): opt-in this cut; the gap analysis
  is on the issue, and the one human call left is ADR-45-cache vs incremental precedence. **#178**
  closed as intended behaviour (`5d5a9359` documents the optimism and bars certainty from resting on
  it). **#155** closed as already-implemented since `01491c63`.
- **#130 deferred remainder** (RBS-only ancestors + singleton) needs a corpus FP-acceptance decision
  first — it would fire on user overrides of library methods. Slice 5 stays blocked by #156.

## Waiting on the user

- **Review/merge PR #186** (the rbs-inline default flip; slice 2 builds on it) and the dependabot
  rubocop PR #86 stays deliberately held (upstream autocorrect bug).
- **Publish the staged `ruby/rbs` upstream fix** — branch `widen-strscan-resolv-stdlib-sigs` in
  `references/rbs`; push + upstream PR are the user's action. Tracked as #159.
- The upstream `rbs-inline` RDoc fix ([soutaro/rbs-inline#249](https://github.com/soutaro/rbs-inline/pull/249))
  is open under the user's fork; nothing to do repo-side until upstream responds.
- **rigor-rs:** `rigor_rs.ruby` is reserved in our schema (ADR-99); the port implements against it.
