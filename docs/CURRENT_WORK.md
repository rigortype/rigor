<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Hard cap: 120 lines, enforced by spec/docs/agent_index_spec.rb. Compress, do not append.
- Verify a claim before carrying it forward, by the thing that decides rather than a proxy —
  including claims in THIS file. Three sessions running, its own pointers have been wrong.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones.
If this file disagrees with an ADR, the CHANGELOG, or an issue, this file is the one that is wrong.

## Performance campaign, #1507 (2026-09-30)

The goal is the warm journeys on a Mastodon-sized Rails app (null build, leaf edit, hub edit), for
both plain `check` and `--incremental`. Decisions and measurements are on #1507. `engine-wall.yml`
and `engine-warm.yml` measure them.

Landed: #1530 (deflate level), #1535, #1545 (a hub edit went from re-checking 311 files to 1),
#1546 (recording memos), #1551, #1563, #1564 (`IoBoundary#replay`), #1566 (the `MEMBER_CLASSES`
fact gates), and #1577 (a value digest for ADR-88, fixing #1574). With the Rails plugins, a null
or edit `--incremental` run takes about 2–3 s, down from about 21 s. #1197's walk merge is not a
wall lever (~0.2%).

Open Drafts, in order:

1. **#1552** (`incremental-null-run-slot`, head `db83e3071` on `e12ab45fa`). It serves an unchanged
   `--incremental` run from an ADR-45 slot, engine-free, in 0.17–0.5 s. Plain `check` is
   byte-identical to master.
   - Round 5 changed the guards: an existence row fails only on a presence change, a lockfile needs
     presence plus ctime, and the overlap fix is `analysed.uniq { File.expand_path }`.
   - The focused review of that change never finished. Re-run it, then merge on green CI.
2. **#1578** (`ruby-order-resolution-chain`, head `72cfcb820`). `Scope::ResolutionChain` is an
   ADR-24 amendment that linearises ancestors in Ruby order, in three flavours (methods, constants,
   arity). Its implementer died mid-work, and that worktree is gone, so `72cfcb820` is all that
   survives. Remaining:
   1. Count every skip: one skip gives two worlds, two or more fall back to master's answer.
   2. Flag unpositioned edges (an `unpositioned_mixins` member written by `walk_class_includes`
      and `walk_class_extends`, where "unpositioned" wins). Also seed `discovered_class_sources` on
      every run for multi-file classes. Fall back to master whenever an edge on the chain is
      unpositioned. This bumps the snapshot SCHEMA and touches `MEMBER_CLASSES` and the census,
      so it could land first as its own data PR.
   3. Record a class edge in `prepend_region_visibility` (`ResolutionChain.record_class`), which
      closes a stale `--incremental` hole.
   4. Bound the retro build.
   5. Word ADR-24 so #1570 is fixed by ADR-119 PR C at the SourceArity site.
   6. Add `enqueue_ancestors` and `direct_ancestors` to the detection spec.
   7. Document the transitive trailing-duplicate gap, and file the repeated-prepend issue.
   8. Then rebase and run a delta review.
3. **#1562, ADR-119 (Proposed, v12).** It puts certainty on discovery facts and reads candidate
   sets through the resolution chain. It supersedes #1531's walker ports. Write v13 with the
   `fable-xhigh-architect` agent once #1578's approach settles. The review blockers still open on
   v12:
   - H1: the position fallback in #1578 must cover zero-skip firings (in a method, across files,
     under a condition).
   - H2: skip relevance counts all skips.
   - M1: the joint-cap gate needs a single owner.
   - M2: the detection-spec text.
   Concern hooks (PHPStan's trait model) are deferred to a follow-up ADR. The maintainer has lifted
   the review-round limit for this ADR. Present v13 for acceptance; once it is accepted, close
   #1531 as superseded.

Needs the maintainer: #120 (`--incremental` as the default) goes to them as an ADR, as would a new
cache format or native code. Next after the Drafts: #1537, #1532/#1533, and #1575 (a plain probe
for template projects).

## Special-variable semantics (ADR-117), carried over

These items were not re-verified this session beyond the states of the PRs.

- **#1499** (#1446, ivar class guards, Draft `9b8bc0c86`): round-1 fixes are pushed. Next is a
  round-2 delta review, then a merge on green CI. #1500 (a disjoint guard reads the guarded class
  for ivar, global or constant receivers, and `bot` for locals) builds on it.
- **Awaiting a user yes:** a one-line ruby/rbs PR adding `alias to_str to_s` to
  `stdlib/uri/0/generic.rbs`. It is an outward publication.
- **ADR-117 order:** #1426, then #1427, then #1366's stream part. #1484 must land before that
  stream part. #1366 stays `ready-for-human`.
- **#1454:** phase 3, the handbook chapter, waits for #1366, #1426 and #1427. Keep
  `docs/type-specification/global-variables.md`'s list of violations current.
- **`ready-for-agent` in `v0.4.x`:** #1447, #1437, #1423, #1375, #1372, #1371, #1416, #1373,
  #1443. Triage the `needs-triage` queue with `gh issue list -l needs-triage`.
- **Sibling Draft #1397** restructures `eval_ensure`. It must keep #1449's ensure rule for `$_`.

## What bit

- An agent's worktree can vanish along with its uncommitted work: #1578 lost one this way. Have an
  implementer commit and push at every green step.
- Measure a lever against the whole run before calling it one (`docs/agents/measurement.md`).
- When lane reviews stay severe into round 3, escalate to the maintainer rather than deciding alone.
