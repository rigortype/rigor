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

## Next session: #446 first, then the report's usability

**#446 is the priority and it is new.** A `super` call contributes nothing to an effect summary and
the row still claims to be **exhaustive**, so a method whose body is `super` reads as provably
effect-free — it passes `%a{pure}` and any envelope while its parent is correctly flagged. Verified on
a five-line fixture. That is a hole in the only half of the feature that can fail a build, in a shape
Rails code is made of (`def create; super; end`). Read the issue: it lists what the fix has to weigh
(which parent, overrides, the unresolved case, and a corpus measurement before landing).

Then the report's usability, which is what the walkthrough said stops adopters cold:

1. **#439** — a path argument narrows the *analysis*, so the same method gets a weaker answer, unmarked.
   It is also the only tractability lever the report has, which makes it a trap.
2. **#434** — 31,191 lines on Redmine, 38.5 % of rows content-free, no summary, no `--limit`.
3. **#429** (nothing lists the vocabulary) · **#436** (empty `reach:` by default) · **#435** (four CLI
   affordance gaps) · **#433** (config mistakes abort with a backtrace) · **#432** (rbs-inline
   declaration position) · **#437** (`Date#to_time` collides with rbs's stdlib).

`make verify` + `make docs-check` green on integrated master at `90c15bf0`.

## Shipped since the walkthrough

- **#428** — the declared-bound check fired cold and was dropped by every cache hit, both lanes. The
  boot-slim probe serves a warm run before the engine loads, so anything appended after
  `compute_run_diagnostics` was invisible. **Any new diagnostic outside the cached run assembly has to
  answer to that probe.**
- **#440** — a synthesised ActiveRecord `save` row carried only the validator's read. The row is built
  by `Effects::FrameworkUnits`, which read one source and never the plugin's own `save → io.db.write`
  claim, so callers were coloured correctly and the method's own row never was. 11 selectors plus the
  `create` twins were affected; `io.db.write` rows on Redmine went 202 → 608.
- **#441** — `effect.annotations-unchecked` dropped the rbs-inline lane on any run that was not plain
  cacheable sequential: `--no-cache`, `--workers=N`, `--incremental` cold, editor buffers. The lane was
  never the variable, the **run mode** was. Verified before/after: `--workers=2` silent → fires.
- **#438** — every emitted `documentation_url` 404ed (`blob/main`; the branch is `master`). Now points
  at the docs host with **no git ref in the string**, and a network-free spec pins any self-referential
  GitHub URL against the branch `ci.yml` gates pushes on. The sweep found three more live 404s,
  including the plugins link in the `.rigor.yml` that `rigor init` writes.
- The CI templates carry a commented-out `rigor effects check` step (#443).

## The v0.4.0 graduation (#409)

Five of six preconditions resolved by ADR-103 WD16 (2026-08-22). Left: the release-notes migration
note and the flip commit. Two updates posted to the issue: the migration note needs **no lane caveat**
and **no "clear your cache first"** (both cache keys carry `Rigor::VERSION`, so the first run after the
upgrade is always cold and analysing) — and **#446 is a counterweight**: either it lands before the
flip or the release note names it.

## Also open, not effects

- **#427** — the warm==cold self-check gate is structurally blind on every gem-bump PR. Green CI on a
  gem bump is not evidence about the rbs marshal hazard.
- **#431** — text output carries no rule ID for any rule; needs a design call, not a fix.
- **#343** (rubocop 1.89.0) still fails Lint; **#86** stays held.

## What this session learned that is not in a commit

- **Ask what varies before assuming which component is broken.** #441 was reported as an rbs-inline
  lane bug. The lane was innocent; the run mode was the variable, and the reporter's fixture was a
  `cache_store: nil` shape, i.e. `--no-cache`. Both observations were correct and the conclusion drawn
  from them was not.
- **A subagent's finding is a lead, not a fact.** Two of the walkthrough's 28 were misdiagnosed and
  already public as issues when the next agent caught them; chasing the first correction is what turned
  up #438. Verify before filing, and re-scope publicly when you did not.
- **Give parallel agents disjoint worktrees AND disjoint survey targets.** Two agents shared
  `rigor-survey/redmine`; one deleted the other's cache mid-measurement and that batch was void. The
  three-agent wave after that ran cleanly with one target assigned to one agent.
- **Rebase each PR onto master before merging a parallel batch, then re-run the gate on the integrated
  result.** Four PRs landed today; three conflicted on `[Unreleased]` alone, which is cheap — but the
  gate that matters is the one after the last merge, not the one on each branch.
