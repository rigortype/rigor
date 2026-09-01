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

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones.
If this file disagrees with an ADR, the CHANGELOG, or an issue, this file is the one that is wrong.

## Where the cycle stands

**The 2026-09-01 opacity campaign is merged AND re-measured.** All 20 sweep PRs + ADR-105 landed;
the sweep probe was then re-run on the merged master over all 30 targets (the handoff's mandatory
re-run before sizing new levers), with four verification passes on the ambiguous clusters. Full
numbers and per-cluster verdicts:
[`docs/notes/20260901-post-campaign-opacity-recheck.md`](notes/20260901-post-campaign-opacity-recheck.md);
re-run outputs preserved on `opacity-sweep-harness-20260901`
(`tool/opacity-sweep-20260901/rerun-20260901/`). Headlines: mastodon 48.9→54.8%, redmine
47.8→50.2%, rigor-lib 59.3→61.3%; the two per-target drops (numo −3.44pp, DSA-in-Ruby −0.54pp) are
FULLY attributed to #537/#559's intended wrong-precise→honest trades, zero unexplained residue.

## Backlog, ranked by the re-run (all on GitHub Issues)

1. **[#569](https://github.com/rigortype/rigor/issues/569)** (new) — rigor-activerecord is
   all-or-nothing on `db/schema.rb`: redmine gitignores it, so the plugin types NOTHING there
   (~650 direct sites: `table_name` 517 + first-hop `.where`/`.visible`/`.find`). Columns-less
   degraded `ModelIndex`; additive by construction. **Best next unit of work.**
2. **[#534](https://github.com/rigortype/rigor/issues/534)** — Rails plugin batch, ~2,015
   named-receiver sites: `Parameters#[]`/`expect`/`slice` first (1,077), then Rails readers 288 /
   Duration 195 / Flash+Session+Request ~350 / sidekiq 64. Each sub-item independently landable.
3. **[#560](https://github.com/rigortype/rigor/issues/560)** — the ADDED-value join (straight-line
   mutations never join the added value): the live always-falsey FP family; design fork + corpus
   census already on the issue. mail's ragel cluster shares the root.
4. **[#525](https://github.com/rigortype/rigor/issues/525)** — struct factories: re-measured to
   296 mail sites (was 39); the new comment adds the setter-then-read fold-safety shape to the
   design pass. `:self`-sentinel design for in-body reads already on the issue.
5. Small/opportunistic: **[#570](https://github.com/rigortype/rigor/issues/570)** (new,
   JSON.generate fold), [#533](https://github.com/rigortype/rigor/issues/533) items 1/5/7 + new
   item 9 (block-return pass reads only `body.last` — repro + decline point on the issue),
   [#527](https://github.com/rigortype/rigor/issues/527) ancestor-walk design pass,
   [#530](https://github.com/rigortype/rigor/issues/530) items 1+3. Ready-for-human policy calls
   unchanged: [#541](https://github.com/rigortype/rigor/issues/541) /
   [#542](https://github.com/rigortype/rigor/issues/542) /
   [#531](https://github.com/rigortype/rigor/issues/531).

Verified NON-levers (do not re-derive): `User.current` 494 sites (honest CurrentAttributes
propagation), `Mutex#synchronize` cluster (65/66 honest; generic X binds fine), `Thread#[]`
(honest RBS untyped), `Mail::Utilities.blank?`/`chars` (#554 works; bodies are param-Dynamic),
tuple min/max (element-union fallback already ships). The parameter/ivar lane stays closed
(ADR-67 gated / ADR-58 settled).

## Pitfalls that still bind

- The corpus baseline arms in older session scratchpads predate the merged master — re-collect
  from a master-pinned worktree before gating the next engine change; regenerate the two apps'
  `.rigor-ab.yml` (tell for a missing one: −787/−2306 with "silenced by baseline" in stderr).
- **`rigor type-of` cannot see discovery-seeded joins** (phantom-Hash read Dynamic on BOTH arms of
  an A/B): binding-level claims need the probe's `discovery_seeded_scope` lens or `check` itself.
- The precision ratio scores `dynamic_top → dynamic_specific` as zero and honest widening as full
  loss — pair it with the FP tally before ranking any wrong-precise fix (#537 lesson).
- Never compare post-#535 coverage ratios to older numbers; read a gate's exit code in its own
  call; a background corpus arm reads the LIVE checkout — freeze the tree for the whole arm.
