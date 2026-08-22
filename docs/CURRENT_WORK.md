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

## Next session: work the effect backlog the walkthrough opened

The owner's manual/UX blocker is **done** — [`docs/manual/19-effect-labels.md`](manual/19-effect-labels.md)
exists, the user story ran end to end on Redmine, and its worst finding is fixed. What is left is the
rest of what the story exposed, now filed. Take them in this order:

1. **#440** — `AuthSource#save` reports the validator's read and drops `io.db.write`. Needs a minimal
   fixture first; it is the line that decides whether a Rails developer believes the report.
2. **#439** — a path argument silently weakens every label, and it is the only tractability lever the
   report has. Pairs with **#434** (31,191 lines, 38.5 % of rows content-free).
3. **#441** — `effect.annotations-unchecked` may not fire for the rbs-inline lane. Settle before the
   v0.4.0 flip: it is how a project learns its `%a{pure}` tags are about to start being checked.
4. **#438** — every emitted `documentation_url` points at `blob/main` and 404s; the branch is `master`.
   Small, and it has been broken for every consumer that ever followed one.
5. **#429** / **#436** / **#435** / **#433** / **#432** / **#437** — vocabulary discoverability, empty
   `reach:` default, CLI affordances, config errors with backtraces, rbs-inline declaration position,
   the `Date#to_time` collision.

`make verify` + `make docs-check` green on integrated master at `08d1a97a`.

## What shipped this session

- **ADR-103 WD16** (PR #426) — five of #409's six graduation preconditions resolved; #410 and #414
  closed. See below.
- **The effect-labels manual chapter** (541 lines) plus effect sections in chapters 11 and 12, and
  fixes to the mislinks and phantom output chapters 02/03/16 carried.
- **#428 fixed** (PR #442) — the declared-envelope check fired cold and was dropped by every cache hit,
  on both lanes. Mechanism below; it is worth knowing.
- Dependabot #413 (rack) and #412 (rbs 4.1.3, audited — see #427) merged.

## #428's mechanism, because it will recur

`CheckCommand#try_run_cache_hit` serves a whole warm run from the ADR-45 `analysis.run-diagnostics`
slot **before the inference engine loads** (ADR-87 WD4 boot-slimming). ADR-103 WD12 deliberately keeps
the effect passes *out* of that slot, so `Runner#run_analysis` appends them after
`#compute_run_diagnostics` — exactly the code a served hit skips. Two correct decisions, one gap
between them. **Any diagnostic appended after `compute_run_diagnostics` is invisible on a warm run.**
The fix makes the probe answer for what the slot omits: reproduce the cheap residual pass, and
*decline* the fast path for a project that could earn an envelope diagnostic, measured off the
declarations alone. Cost: warm runs go 0.25 s → 0.92 s on redmine **only** when an envelope is
declared; projects without one are unchanged.

## The v0.4.0 graduation (ADR-103 WD16, 2026-08-22)

Five of #409's six preconditions are resolved: non-fork backends **replaced** by the sequential degrade
(no thread backend exists; the Ractor one is dead upstream), vocabulary **cleared** (vocabulary 1 ships
as it stands; the Steins divergence is architectural, raised as steins#468 / steins#469), WD13 budget
**arbitrated** by the CI `effect-budget` job, `effects.lsp` **decided** (editor mode stays effect-free,
spelled as a key defaulting to `false`), taint-only rows closed by #411/#415.

Left: the release-notes migration note, and the flip commit itself.

## Also open, not effects

- **#427** — the warm==cold self-check gate is structurally blind on every gem-bump PR: the cache key is
  scoped to `hashFiles('Gemfile.lock')`, so the warm arm starts empty and the gate compares cold to
  cold. **Green CI on a gem bump is not evidence about the rbs marshal hazard.**
- **#431** — text output carries no rule ID for any rule. Re-scoped from an effects-only claim after
  checking; needs a design call, not a fix.
- **#343** (rubocop 1.89.0) still fails Lint; #86 stays held.

## What this session learned that is not in a commit

- **Verify a subagent's finding before filing it.** Two of the walkthrough's 28 were misdiagnosed —
  "effect diagnostics lack rule IDs" (no rule has them) and "`plugin-attribution` is never emitted" (it
  is; first-party rows discharge their own taint). Both were already public issues when the next agent
  caught them. Chasing the first correction is what turned up #438, so the checking paid twice.
- **Give parallel agents disjoint survey checkouts.** Two agents used
  `rigor-survey/redmine` at once; one deleted the other's cache mid-measurement, and that batch had to
  be discarded and re-run on a private copy. The rigor repo tolerates concurrent readers; a survey
  target under measurement does not.
- **A walkthrough finds what a spec cannot.** Every item in the batch was in shipped, gated, green code.
  The suite proves the feature works; only a person walking it finds that half of it is inert warm, that
  narrowing the path weakens the answer, and that nothing lists the vocabulary.
