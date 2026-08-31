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

The 2026-09-01 session ran the corpus-wide opacity sweep (25 targets, 8 analysis agents), filed the
mechanism backlog, and landed wave 0–1 of the fixes. Synthesis:
[`docs/notes/20260901-corpus-opacity-attribution.md`](notes/20260901-corpus-opacity-attribution.md);
harness + per-target case reports on branch `opacity-sweep-harness-20260901`.

## FIRST: five green PRs are waiting on merge (the classifier blocks `gh pr merge` for agents)

All six of the session's PRs were verified individually AND as a local integration merge (all gates
green; corpus adjudicated below). #535 is merged; the rest need a human (or an allowed session):

1. **[#536](https://github.com/rigortype/rigor/pull/536)**, **[#537](https://github.com/rigortype/rigor/pull/537)**, **[#545](https://github.com/rigortype/rigor/pull/545)** — independent, any order.
2. **[#538](https://github.com/rigortype/rigor/pull/538)** — merge before #543.
3. **[#543](https://github.com/rigortype/rigor/pull/543)** — STACKED on #538: after #538 merges,
   `gh pr edit 543 --base master`, wait for CI, then merge. Do not let the auto-retarget race you
   (the stacked-PR trap: a top merged before its base retargets lands on the base branch).
4. After all five: run `make verify` on the integrated master and re-prime the diagnostics slot with
   a `check` run.

Integrated corpus (11 targets, vs pre-session master, every delta adjudicated in the PR bodies):
**+26 / −30**. The 26: 21 `def.return-type-mismatch` warnings against textbringer's own handwritten
sig (the contradiction rule's job), **3 true-positive bug finds** (redmine `diff_table.rb:153`
`elsif line[0, 1] = "\\"` — assignment where `==` was meant; textbringer `lsp/client.rb:193,219` —
nil reaches `.strip` outside the rescue), 2 FPs filed as
[#542](https://github.com/rigortype/rigor/issues/542). The 30 removed are all false positives.
mastodon 2,341 → 2,341 and redmine 792 → 791+1 by content. `make coverage` on the integrated tree:
59.67% against the recalibrated 0.58 gate.

## What the sweep filed (the fix backlog, all with verified repros)

- Landed this session: [#513](https://github.com/rigortype/rigor/issues/513)+[#523](https://github.com/rigortype/rigor/issues/523)
  (lens parity, PR #535) · [#522](https://github.com/rigortype/rigor/issues/522) (cause relabel, #536) ·
  [#521](https://github.com/rigortype/rigor/issues/521) (overload Dynamic-pin, #537) ·
  [#520](https://github.com/rigortype/rigor/issues/520) (assignment RHS, #538) ·
  [#518](https://github.com/rigortype/rigor/issues/518)+[#519](https://github.com/rigortype/rigor/issues/519)+[#540](https://github.com/rigortype/rigor/issues/540)
  (safe navigation, T|nil retry, mutated literal constants, #543) ·
  [#544](https://github.com/rigortype/rigor/issues/544) (indexed-narrowing gate, #545).
- **Next by leverage:** [#524](https://github.com/rigortype/rigor/issues/524) — per-parameter
  binder (optionals/rest/kwargs/block currently bail the whole signature; 10-target evidence; the
  single widest engine lever). Then [#527](https://github.com/rigortype/rigor/issues/527)
  (ancestor/include walk family, ready-for-human design pass) and
  [#534](https://github.com/rigortype/rigor/issues/534) (Rails plugin batch: Parameters#[] is the
  top named-receiver pair on both apps).
- Rest of the filed set: [#525](https://github.com/rigortype/rigor/issues/525) Struct.new factories ·
  [#526](https://github.com/rigortype/rigor/issues/526) extend family ·
  [#528](https://github.com/rigortype/rigor/issues/528) Zeitwerk namespaces ·
  [#529](https://github.com/rigortype/rigor/issues/529) RBS Alias/Intersection ·
  [#530](https://github.com/rigortype/rigor/issues/530) WD9 under-claiming ·
  [#531](https://github.com/rigortype/rigor/issues/531) Array.new element type ·
  [#532](https://github.com/rigortype/rigor/issues/532) Call*WriteNode ·
  [#533](https://github.com/rigortype/rigor/issues/533) eight minor gaps ·
  [#539](https://github.com/rigortype/rigor/issues/539) Set#any? block fold (wrong Constant[true],
  fires a standing warning on our own lib) ·
  [#541](https://github.com/rigortype/rigor/issues/541)/[#542](https://github.com/rigortype/rigor/issues/542)
  attr_writer ivar surface / Hash.new default (both ready-for-human).

## Findings worth more than the numbers

- **`unsupported_syntax` was a misnomer bucket**: 27 genuinely unmodeled nodes on mastodon out of
  26,505 carrying the cause; the mass is name resolution. #536 relabels the discovered-def half; the
  `unresolved_name` cause split is still open in #522.
- **The corpus-gate discipline paid for itself**: three latent wrong-type families (#540, #541,
  #544) surfaced only as engine precision rose — the audit's "a fold makes wrong types reachable"
  lesson, now with three more instances. Expect any future precision lever to be gated on bugs it
  did not cause.
- Textbringer is the adjudication-heavy target: its handwritten sig drifts from its code, so
  `def.return-type-mismatch` warnings there are usually the rule working, not a regression.

## Pitfalls that still bind

- Baseline corpus arms for A/B live in the session scratchpad only; re-collect from a master-pinned
  worktree (`.bundle/config` + vendor symlink) before the next engine change. `.rigor-ab.yml`
  (committed-config-minus-baseline) copies may still sit in redmine/mastodon survey checkouts —
  regenerate rather than trust.
- The probe on `opacity-sweep-harness-20260901` predates #535: its per-target counts overstate
  holes the check walk resolves. Re-run it post-merge before sizing any new lever.
- `rigor coverage` is plugin-aware since #535 — do not compare its ratios against pre-#535 numbers.
- Read a gate's exit code in its own call; run the gate after the LAST edit, merge resolutions
  included. A PHASED A/B is fine for diagnostic SETS, never for timings.
