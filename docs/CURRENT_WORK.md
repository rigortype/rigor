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

**The 2026-09-01 opacity-sweep campaign is fully merged.** All 20 PRs (#535–#559 sweep numbers plus
#561) landed on master on 2026-09-01; the merge queue is empty (only the pre-existing dependency
bumps #86/#516/#517 remain open, outside this campaign). The integrated master passed `make verify`
from a cold cache (#554's `SCHEMA_VERSION` 6→7 bump) with the diagnostics slot re-primed, and the
`[Unreleased]` section merged clean — 27 entries, no duplicated `###` heading.

Campaign record: 11-target corpus **+39/−70** vs the pre-campaign master (11 true-positive bug finds
among the additions — mastodon `quote_request.rb` nil-deref ×8, textbringer LSP stderr crashes ×2,
redmine `diff_table.rb:153` `=` for `==`; every removal a false positive), `lib` precision
**59.8% → 61.3%** (same-day paired; `make coverage` gate pinned 0.58 since #535). Perf disclosures
that now apply to master: #547 ~+12% redmine cold-check wall (memo-key headroom on its PR), #556
~+5.5% lib cold self-check (post-memo; inherent to translating expanded aliases).
Synthesis: [`docs/notes/20260901-corpus-opacity-attribution.md`](notes/20260901-corpus-opacity-attribution.md);
sweep harness on branch `opacity-sweep-harness-20260901` (its probe predates #535 — re-run before
sizing new levers).

**The drain's postmortem landed as [ADR-105](adr/105-pr-landing-flow.md)** (PR #562, merged):
changelog entries now land as `changelog.d/<section>/<slug>.md` fragments (never direct
`[Unreleased]` edits — GitHub ignores `merge=union` for PR mergeability), and autonomous sessions
merge each audited+green PR as they go instead of queueing. Both rules are in AGENTS.md.

## What the merge session itself established (worth knowing before touching the same files)

- GitHub ignores `.gitattributes merge=union` for PR mergeability, so every post-first merge needed a
  local master-merge + CI cycle; the resolutions now live in this clone's **rerere cache**.
- **rerere replays superseded resolutions**: it re-applied a known-broken `expression_typer.rb`
  resolution (orphaned `try_user_method_inference` head) that had been recorded before its repair.
  `git rerere forget <path>` + re-resolving by hand re-records the good one — trust but VERIFY any
  rerere-resolved hunk against the intended shape before pushing.
- The three non-keep-both crossings landed as documented: #549+#555 (`method_name:` kwarg + carrier
  gate), #537+#556 (`join_candidate_returns` threads `alias_expander:`), #537+#558 (array-valued
  passes + hash-bundle signature).

## Backlog (all on GitHub Issues, with verified repros / designs)

- **[#560](https://github.com/rigortype/rigor/issues/560)** — the remaining ADDED-value half:
  `u = [1, 2]; u.push(6); u.last == 6` still folds falsey (the slot-rewriting half landed as #561),
  and mail's ragel cluster (#533 item 8) is the same root on the precision side. Design = option 1
  on the issue (thread mutator arg types into the straight-line widening the way the block path's
  `join_array_content` already does). **Next sized lever.**
- **[#525](https://github.com/rigortype/rigor/issues/525)** — in-body member reads for struct-factory
  block defs: full executable design on the issue (`:self` sentinel in `struct_fold_safe_locals`,
  the return-memo-key hazard, the self-setter guard). Stacks on nothing now — #555 is in master.
- **[#527](https://github.com/rigortype/rigor/issues/527)** ancestor/include walk family
  (ready-for-human design pass) · **[#530](https://github.com/rigortype/rigor/issues/530)** items
  1 (superclass-reach tagging) and 3 (no-lockfile degradation) — item 2 answered as environmental ·
  lambda-literal lane (design note on [#533](https://github.com/rigortype/rigor/issues/533); its
  `Queue`/`SizedQueue` item died on verification) · **[#534](https://github.com/rigortype/rigor/issues/534)**
  remaining Rails surfaces (`Parameters#[]` needs a rules-level decision, analysis on the issue).
- Ready-for-human policy calls: **[#541](https://github.com/rigortype/rigor/issues/541)** attr_writer
  ivar surface · **[#542](https://github.com/rigortype/rigor/issues/542)** Hash.new default ·
  **[#531](https://github.com/rigortype/rigor/issues/531)** `Array.new(n, fill)` (~500-site FP trade).

## Pitfalls that still bind

- The corpus baseline arms in the session scratchpad are now STALE (they predate the merged master):
  re-collect base arms from a master-pinned worktree before gating the next engine change, and
  regenerate the two apps' `.rigor-ab.yml` (committed config minus `baseline:`; the tell for a
  missing one: −787/−2306 with "silenced by baseline" in stderr).
- Never compare post-#535 coverage ratios to older numbers; `rigor coverage` is plugin-aware now.
- Read a gate's exit code in its own call; PHASED A/B only for diagnostic sets, never timings.
- A background corpus arm reads the LIVE checkout — freeze the tree (no stash/checkout) for the
  whole arm, or point the runner at a detached worktree.
