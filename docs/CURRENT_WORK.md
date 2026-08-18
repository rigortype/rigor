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

## Where things stand

- **The effect system's second stack was triaged by measurement, and two of its three slices died.**
  `make verify` + `make docs-check` are green on the INTEGRATED master at `a403da0f`. v0.3.3 remains
  the released version; the CHANGELOG `[Unreleased]` carries the new entries.
- **Landed**: PR #415 (#411 — taint-only snapshot rows omitted by default, `--full` keeps them;
  redmine 3,581 rows / 660 KB → 1,560 / 296 KB) · PR #416 (#414 — the Ractor pool no longer hangs
  when a worker dies). A docs commit carries the #389 measurement note.
- **#390 (`effect.discarded-pure-result`) is measured and should be declined too.** 7,151
  discarded-position call sites across `rigor lib` / redmine / mastodon yield **14 firings, all
  false positives**, and the corpus contains no instance of the footgun the rule is named for. Its
  acceptance fixture also cannot pass: under the `raises` facet `h.fetch(:k)` fires (`rb_key_err_raise`
  is not in the extractor's `RAISE_RE`), and under the folding-purity alternative `arr.sort` and
  `xs.map` do not. Full record:
  [`docs/notes/20260819-discarded-pure-result-corpus-gate.md`](notes/20260819-discarded-pure-result-corpus-gate.md);
  harness on the deliberately unmerged branch `measure/discarded-pure-result`. **The evidence comment
  is posted; the issue still needs closing by hand.**
- **#389 (the B2.2 ivar-reset skip, the first *typing* consumer) is measured and declined.** Not a
  scope call — an evidence one, and the issue's own acceptance criterion turned out unreproducible.
  Full record: [`docs/notes/20260818-b22-ivar-reset-headroom.md`](notes/20260818-b22-ivar-reset-headroom.md);
  harness on the deliberately unmerged branch `measure/b22-yield`. **The issue still needs closing by
  hand** (the evidence comment is posted).
- **#410 cannot be delivered, and #414 explains why.** The Ractor pool backend does not analyse a
  file under rbs 4.x: `RBS::Namespace.[]` interns every namespace through a process-wide mutable
  flyweight cache in module ivars, which a non-main Ractor may not read. PR #416 fixed the two
  Rigor-side defects around it (a `Plugin::Isolation` module-ivar write from the worker Ractor, and
  a drain loop bounded by `:done` counts that hung forever when every worker died), so the backend
  now fails per file and degrades rather than hanging — but it is not revivable without upstream rbs.

## Next session

- **Two owner decisions are open, both on the graduation path (#409)**:
  1. #410 — close as won't-do and relax the precondition to "without `fork`, a collecting run
     degrades to sequential and says so" (today's behaviour, costs nothing, affects only Windows);
     or keep it open pending upstream rbs.
  2. #414 — retire the Ractor backend outright, or park it behind the override. It now fails
     honestly, but a backend that reports an internal analyzer error for every file still costs a
     spec-process isolation, an exclusion pattern and a `make test-ractor-pool` target.
- **The effect system's remaining implementable slices**: #391 (`sig-gen` write-back of `%a{pure}` /
  envelopes), then views #392 → #393 → #394. #378 is the human cross-repo item and gates the
  vocabulary before v0.4.0. #389 and #390 are both measured and declined, so **every remaining
  diagnostic consumer of the effect system has now been measured away** — what is left is reporting
  and annotation surface.
- **Two builtin-catalogue extractor bugs fell out of the #390 audit and are filed** (neither is
  effect-system work, both `ready-for-agent`): #417 — `RAISE_RE` misses every helper-macro raise, so 35
  catalogued methods read `raises: false` while raising, `Hash#fetch` among them; #418 — `Array#sort`
  reads `purity: mutates_self` because the mutator heuristic's "first argument is a formal parameter"
  net fires on a parameter `rb_ary_sort` rebound to a dup, which also costs it constant folding.
- The next typing consumer worth trying is ADR-103 § 8 (2)'s computed purity for remembering call
  results across re-invocation (`if x.foo && x.foo.bar`): unlike B2.2's, its rule reads **locals**,
  which is the only receiver shape `call.possible-nil-receiver` fires on.

## What this arc learned that is not in a commit

- **Evaluate the acceptance fixture against the real data files before building anything.** #390's
  gate was named in the issue as "the catalogue's `raises` facet / the folding totality criterion".
  Reading those two files against the five named cases took under an hour and showed no composition
  of them passes. This is the second consecutive slice whose acceptance criterion was assumed rather
  than checked (#389's was unreproducible), so it is now the cheapest first move on any gated rule.
- **A census probe must measure a call's OWN contribution, not a delta.** The first cut snapshotted
  the unit's accumulated labels around each call. A second `lines << ""` in one method contributes
  `mutate.local` that is already present, so the delta read empty and 14 `Array#<<` sites looked pure.
  Walking the subtree against fresh accumulators and merging back is the fix. The tell was a control
  fixture disagreeing with the corpus — the corpus rows had a shape neither control could produce.
- **Post-order, or containment is invisible.** A block literal's origins join through the child walk,
  so a probe that emits at `visit_call` reports `xs.map { puts x }` as pure and quietly contradicts
  the design's own containment claim.
- **An effect system tuned for envelopes is mistuned for discards, and that is not a bug.**
  `mutate.local` tolerance, `freeze` not being modelled, and `&:sym` not tainting are all right for
  "what does this method's code do to the world" and all wrong for "did this statement do anything
  for its caller". Three of #390's five FP mechanisms are that mismatch, so any future discard-shaped
  rule inherits them.
- **Measure a consumer's headroom before building it, by removing the thing it optimises.** Disabling
  the B2.2 reset entirely is an upper bound on every criterion #389 could gate on, and it cost two
  runs per subject. It removed zero diagnostics over 809 reset sites and added one false positive.
  A yield percentage would not have found this: the join said 3–5 % of sites were skippable, which
  reads like a small win rather than like nothing.
- **An acceptance criterion can be unreproducible, and writing the fixture is how you find out.**
  #389 promised to remove a `call.possible-nil-receiver` from `return unless @user; audit!;
  @user.name`. That shape has never reported one: the rule fires only on a local-variable receiver
  (`check_rules.rb:1271`). The fixture took ten minutes; the slice would have taken days.
- **Both extremes need a control.** Zero-diagnostic-change is the shape of a broken toggle, so the
  census had to show the reset firing at that exact site and the toggle had to move the inferred type
  (`String?` → `String`) before the zero meant anything. The same for the Ractor degrade: the fix was
  proved by poisoning a worker and watching the run finish in seconds where it had hung past ten
  minutes.
- **A backend CI never selects is a backend that rots.** `runner_pool_spec.rb` runs in `make verify`,
  but on the *fork* backend — only the no-`cache_store` example pins Ractor, and it returns before
  spawning anything. The Ractor path had been dead for some time with every gate green. When a spec
  file's name and the backend it exercises disagree, the name is not the thing that decides.
- **A hang is worse than a crash and should be fixed even in dead code.** The Ractor coordinator's
  `while done_count < pool.size` had no way to observe a worker dying. `Ractor#monitor` posts
  `:exited` / `:aborted` to the same mailbox, so bounding the loop by termination rather than by
  `:done` is a four-line change that turns an unbounded hang into a degrade.
- **`gh issue close` and chained `gh` commands are not auto-approved in this harness**; comments and
  `gh pr create` / `merge` are. Post the evidence, then leave the close to the owner.
