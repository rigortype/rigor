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

**Twenty-three PRs landed 2026-09-01/02** through the serial landing pipeline (worktree fleet →
corpus arms → independent critical review → draft-PR remote CI → chained merge). Batch 1 (#571
#576 #578 #579 #581 #582 #584 #585): redmine 50.2→53.4% (the #569 AR unlock). Batches 2-3 (#591
#592 #593 #596 #598 #603 #604 #607 + fix-forwards #602 #608): correctness-dominated, corpus flat
by measurement. Batch 4 (2026-09-02, the recovered engine-bug batch): #612 (absence-edge cache
dependencies, #577), #616 (a declared/untyped Array carrier survives the block join, #586 — four
master wrong-precise closes fixed), #619 (constant-assigned `Struct.new … do` bodies entered as
class bodies, #590 — haml −2 FPs, +1 honest `String?` report), #620 (block returns threaded
through captured content mutation + per-element folds at the rebound capture's converged
binding, #587 — CPU delta measured nil on textbringer/redmine). Every engine PR's review found
at least one wrong-type FP the corpus arms could NOT see — both instruments stay mandatory.

**In flight at handoff:** #624 (#583 de-rooted model keys + reopen merge, delta review APPROVE,
arms +11 info-only recognition at rooted `::Model` call sites) in its landing chain; the #588
branch (`rails-surface-follow-ups`, worktree `rigor-wt-f588`) fixed its second-round blocker
(the railties reader gate now records the ADR-46 negative edge from `Reflection.discovered_method?`)
and awaits the delta re-check; next batch implementing in worktrees: #613 (`rigor-wt-x613`), #614
(`rigor-wt-c614`), #615 (`rigor-wt-y615`), #618 (`rigor-wt-s618`) — land each through the same
chain, one heavy job (corpus arms) at a time.

## Backlog, ranked

1. **[#574](https://github.com/rigortype/rigor/issues/574)** (ready-for-HUMAN) — witness-gate
   vacuity, sole blocker on `Parameters#[]` (581 redmine + 496 mastodon). Measurement DONE:
   tightening refuted (7 FP : 27 TP), nilable `Parameters#[]` alone +2 post-#607; options on the
   issue. Not agent-adjudicable.
2. **External user reports, untriaged:** [#610](https://github.com/rigortype/rigor/issues/610)
   (rigor-activerecord's generic `Relation[Elem]` collides with gem_rbs_collection's non-generic
   `Relation` → every AR relation degrades to `Dynamic[top]` on a collection-using app; needs a
   reconciliation design, not a patch), [#609](https://github.com/rigortype/rigor/issues/609)
   (`sig-gen --write` emits a sig/ the next run cannot load, SystemStackError yet exit 0),
   [#611](https://github.com/rigortype/rigor/issues/611) (bundle-discovered sig/ skips git-sourced
   gems).
3. Engine/plugin bugs with repros, agent-doable, filed from this cycle's reviews:
   [#617](https://github.com/rigortype/rigor/issues/617) (block-return residues: find/detect
   first-iteration nil, cap-above-8 mutation, compound-write tails, `String#<<`),
   [#621](https://github.com/rigortype/rigor/issues/621) (rooted-key + retry on six sibling
   plugins' own indexes), [#622](https://github.com/rigortype/rigor/issues/622) (unresolved
   constant receiver records no absence edge), [#623](https://github.com/rigortype/rigor/issues/623)
   (`Blog::Post` tableizes to `blog_posts`), plus the in-flight four above.
4. Struct frontier, settled by measurement (do not re-derive): [#597](https://github.com/rigortype/rigor/issues/597)
   (per-iteration setter modeling = the mail lever), [#599](https://github.com/rigortype/rigor/issues/599),
   [#601](https://github.com/rigortype/rigor/issues/601) (aliasing umbrella — append corners there).
5. Design/policy: [#594](https://github.com/rigortype/rigor/issues/594), [#580](https://github.com/rigortype/rigor/issues/580),
   #541 / #542 / #531 / #527 / #530.
6. Non-levers verified: mastodon `Rails.*` residue = its survey config omits rigor-railties (fix
   at the next full sweep — it invalidates saved base arms); `User.current` honest.

## The landing pipeline (it caught 10+ FPs the corpus missed this cycle)

- Implementation parallel in worktrees (`.bundle/config` copy + `vendor` symlink; NEVER
  `git stash` — shared stack; COMMIT before any `git checkout <sha> -- <file>` baseline swap).
  Worker brief = the contract file (Flake, no full gates, spec pairing, fragment grammar).
- ONE heavy job on the machine at a time (a 4×`make verify` fleet OOM-killed the host at
  200GB+). Workers: single spec files + `--workers=0` fixtures only; corpus arms are local
  (CI has none) and serial.
- Draft-PR remote CI = the post-rebase verification; PRs stay **Draft until every gate is
  green**. The chain that holds (two red-masters came from drifting off it): rebase →
  `push --force-with-lease` → ONE `set -e` script that watches the head's checks by exit code
  (8 = pending; tolerate "no checks reported"), `gh pr ready` + merge only on 0, then watches
  the MASTER merge-commit run to its conclusion. Serial: the next PR's chain starts after the
  previous master run concludes. Validate the PR number before writing it into a fragment.
- Same-day PRs that each APPEND a WD section to one ADR (or a `describe` to one spec file)
  conflict on rebase — keep both, renumber (WD2.9 → WD2.10), re-rebase after the earlier lands.
- Every engine PR gets an adversarial review with VERIFIED findings; REQUEST-CHANGES round-trips
  to the implementing worker; the reviewer's own measurements are sometimes wrong — relay both
  ways. A delta re-check goes to the SAME reviewer (context intact) via SendMessage.

## Pitfalls that still bind

- `rigor type-of` can't see discovery-seeded joins; `rigor type-scan` can't see
  Dynamic→precise changes — pick the instrument per question. The precision ratio under-credits
  `dynamic_specific`; pair with the FP tally. `model-call` rows are `info` recognition traces.
- Compound-shell A/B arms inherit `cd` from earlier lines in the same Bash call; one
  invocation per arm, explicit cwd. A CPU A/B needs the target's `--config` or it measures boot.
- The fixture auto-formatter strips "useless" if-guards and reassignments — write such
  fixtures via script, or as spec heredocs.
- GitHub mergeability lags pushes; retry with backoff. Read gate exit codes in their own call.
