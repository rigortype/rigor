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

**Thirteen PRs landed 2026-09-01/02** through the serial landing pipeline (worktree fleet →
corpus arms → independent critical review → draft-PR remote CI → merge). Batch 1 (#571 #576
#578 #579 #581 #582 #584 #585): redmine 50.2→53.4% (+3.2pp, the #569 AR unlock), mastodon
54.8→55.5%. Batch 2 (#591 #592 #593) and batch 3 (#596 #598): **correctness-dominated, corpus
precision ~flat by measurement** — three wrong-value FP families killed (fluent-builder
freshness #595, member-aliasing mutation via the #596 scan fix, the join silently revoking
struct fold grants — #589's true mechanism: `Scope#join` dropped `struct_fold_safe_locals`, an
`if` revoked exactly as a `while`), plus the request predicates/flash surface (#592) and the
unreadable-args widening (#593). Every engine PR's review round found at least one verified
wrong-type FP the corpus arms could NOT see — the two instruments stay mandatory together.

## The struct precision frontier, settled by measurement (do not re-derive)

The #591 grant + #596 join fix + #598 freshness narrowing left corpus struct precision flat
because the remaining declines are REAL: mail's ragel = 131 in-loop setters behind the
load-bearing `deferred_setter` gate → **[#597](https://github.com/rigortype/rigor/issues/597)**
(per-iteration setter modeling — the actual mail lever); factory-method/aliased-constant/
block-form-include recovery → **[#599](https://github.com/rigortype/rigor/issues/599)** (incl.
the budget fail-open); the aliasing-optimism umbrella →
**[#601](https://github.com/rigortype/rigor/issues/601)** (mutation/escape evidence updates
exactly one binding — append new corners there, don't file fresh).

## Backlog, ranked

1. **[#574](https://github.com/rigortype/rigor/issues/574)** (ready-for-HUMAN) — the
   witness-gate vacuity; sole blocker on the corpus's biggest remaining pair
   (`Parameters#[]` 581 redmine + 496 mastodon; `session[:user_id]` measured as the same
   blocker by #592's adjudication). Needs its own corpus FP/FN measurement round.
2. Engine bugs with repros, all agent-doable: [#586](https://github.com/rigortype/rigor/issues/586)
   (likely near-free after a #580-style provenance), [#587](https://github.com/rigortype/rigor/issues/587),
   [#583](https://github.com/rigortype/rigor/issues/583), [#590](https://github.com/rigortype/rigor/issues/590),
   [#600](https://github.com/rigortype/rigor/issues/600) (`opaque_block_self` join drop — and
   its suggestion: ONE spec asserting every Scope field survives a join, to end the class),
   [#577](https://github.com/rigortype/rigor/issues/577), [#588](https://github.com/rigortype/rigor/issues/588).
3. Design/policy: [#594](https://github.com/rigortype/rigor/issues/594) (nil-masquerading
   `Mime::NullType`, pairs with #542's carrier property), [#580](https://github.com/rigortype/rigor/issues/580)
   (carrier-level provenance — the scope-side route measured into the method-return wall;
   evidence on the issue), #541 / #542 / #531 / #527 / #530 items 1+3.
4. Non-levers verified this cycle: mastodon `Rails.*` residue = its survey config omits
   rigor-railties (fix at the next full sweep — it invalidates saved base arms);
   `Duration#ago`/`to_i` pairs = the typed frontier moving forward; `User.current` honest.

## The landing pipeline (unchanged; it caught 7+ FPs the corpus missed this cycle)

- Implementation parallel in worktrees (`.bundle/config` copy + `vendor` symlink; NEVER
  `git stash` — shared stack; COMMIT before any `git checkout <sha> -- <file>` baseline swap).
- ONE heavy job on the machine at a time (a 4×`make verify` fleet OOM-killed the host at
  200GB+). Workers: single spec files + `--workers=0` fixtures only.
- Draft-PR remote CI = the post-rebase verification; PRs stay **Draft until every gate is
  green** (corpus arms + review APPROVE + CI), then `gh pr ready` + merge. Watch the FINAL
  head's run to completion before merging — one merge slipped through with the last docs-only
  commit's run still in progress (harmless that time; don't repeat).
- Corpus arms: `check --no-baseline --no-cache --format json --workers=4`; a corpus-neutral
  merge keeps the base arms valid (`landing/` dirs in the session scratchpad).
- Every engine PR gets an adversarial review with VERIFIED findings; coordinator adjudicates
  direction on REQUEST-CHANGES; worker refutations of reviewer measurements are sometimes
  right (twice this cycle: the break-shape cwd contamination, the reviewer's own harness).

## Pitfalls that still bind

- `rigor type-of` can't see discovery-seeded joins; `rigor type-scan` can't see
  Dynamic→precise changes (it counts unrecognized node classes) — pick the instrument per
  question. The precision ratio under-credits `dynamic_specific`; pair with the FP tally.
- Compound-shell A/B arms inherit `cd` from earlier lines in the same Bash call; one
  invocation per arm, explicit cwd.
- The fixture auto-formatter strips "useless" if-guards and reassignments — write such
  fixtures via script, or as spec heredocs.
- GitHub mergeability lags pushes; retry with backoff. Read gate exit codes in their own call.
