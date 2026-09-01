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

**The 2026-09-02 fix batch is fully landed: eight PRs merged** (#571 JSON fold, #576 AR
columns-less index + ADR-26 WD7, #578 Parameters chain links, #579 oracle-tempfile flake fix,
#581 ADDED-value join, #582 shoulda fact shape, #584 block-return threading, #585 Rails
readers/Duration/sidekiq). Every PR went through the serial landing pipeline: rebase →
corpus FP arms (local, `collect_arm.sh`/`diff_arms.py` under the session scratchpad) →
independent critical review (three of eight needed fix rounds — the reviews caught four
genuine wrong-type FPs the corpus missed) → remote CI on the draft head → merge.
Post-batch probe re-run (13 targets, same probe as `opacity-sweep-harness-20260901`):
**redmine 50.2→53.4% (+3.2pp, the #569 unlock), mastodon 54.8→55.4%**, gems ±0, weighted
+0.49pp. Closed: #560 #569 #570 #572 #573; #533 item 9 and #534 items 1-4 landed.

## In flight (autonomous workers, worktrees under ~/repo/ruby/rigor-wt-*)

- **#525** struct-factory `:self` sentinel + setter-rejoin (branch `struct-factory-self-sentinel`).
- **#580** widened-carrier provenance mark — reopens the one-way door, may lift #581's gradual
  floors; staged commits so the Hash-gradualization revisit can drop independently (branch
  `widened-carrier-provenance`).
- **#534 request surface** — Request predicates / FlashHash / Session, measured-adjudication
  required per method (branch `actionpack-request-surface`).

## Backlog, re-ranked by the post-batch probe

1. **[#574](https://github.com/rigortype/rigor/issues/574)** (ready-for-HUMAN) — the witness-gate
   vacuity is now the single blocker on the corpus's biggest remaining pair: `Parameters#[]`
   581 redmine + 496 mastodon sites. Needs its own corpus FP/FN measurement.
2. Engine bugs from the batch's reviews, all with repros: **[#586](https://github.com/rigortype/rigor/issues/586)**
   (declared `Array[untyped]` closes under block mutation — likely one-liner after #580),
   **[#587](https://github.com/rigortype/rigor/issues/587)** (block-return content-mutation-blind
   gate + first-iteration pinning), **[#583](https://github.com/rigortype/rigor/issues/583)**
   (`class ::User` misses all model_index consumers), **[#577](https://github.com/rigortype/rigor/issues/577)**
   (absence-edge cache invalidation), **[#588](https://github.com/rigortype/rigor/issues/588)**
   (#585 nits). **[#575](https://github.com/rigortype/rigor/issues/575)** controller-ivar carve-out
   (ready-for-human).
3. Standing policy calls unchanged: #541 / #542 / #531 / #527 / #530 items 1+3.
4. Verified NON-levers (do not re-derive): `User.current` 494 (honest CurrentAttributes),
   mastodon's `Rails.*` residue (its survey config omits `rigor-railties` — a config gap, NOT an
   engine gap; adding it invalidates saved base arms, do it at the next full sweep), the
   `Duration#ago`/`#to_i` pairs (the chain frontier moved forward — receiver typed, lenient call).

## The landing pipeline (keep it — it caught what the corpus missed)

- Implementation parallel in worktrees (bundler = `.bundle/config` copy + `vendor` symlink; the
  shared stash stack means **NEVER `git stash` in a worktree**; commit before any
  `git checkout <sha> -- <file>` baseline swap).
- Heavy execution serial and coordinator-owned: ONE full-suite/corpus job on the machine at a
  time (a 4-worker parallel `make verify` fleet once OOM-killed the host at 200GB+). Workers run
  single spec files and `--workers=0` fixtures only.
- **Draft-PR remote CI is the post-rebase verification** — push early, keep the PR Draft until
  every gate (corpus arms + review APPROVE + CI) is green, then `gh pr ready` + merge.
- Corpus arms: `check --no-baseline --no-cache --format json --workers=4` per target, base arms
  re-derivable from the merged branch's own final arms (a corpus-neutral merge keeps them valid).
- Every PR gets an independent critical review with VERIFIED findings; a REQUEST-CHANGES round
  trips back to the implementing worker with the coordinator adjudicating direction.

## Pitfalls that still bind

- `rigor type-of` cannot see discovery-seeded joins; binding-level claims need the probe lens or
  `check`. The precision ratio under-credits `dynamic_specific`; pair it with the FP tally.
- Compound-shell A/B arms inherit `cd` from earlier lines in the SAME Bash call — a reviewer's
  master arm silently ran the branch engine; give each arm its own invocation with explicit cwd.
- GitHub's mergeability check lags pushes ("head branch is out of date" on an up-to-date branch)
  — retry with backoff, don't rebase-churn.
- Read gate exit codes in their own call; never compare post-#535 coverage ratios to older numbers.
