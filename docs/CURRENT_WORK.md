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

## Where the cycle stands

**v0.3.7 is still DEFERRED, deliberately, to raise completeness — there is no cut to prepare.** 87
`changelog.d/` fragments and 603 commits since v0.3.6 are why the bar moved, not a backlog to flush.
`Rigor::VERSION`, `CHANGELOG.md` and `Gemfile.lock` move only on an explicit request (ADR-50 § WD5).
`make verify` and `make docs-check` are green on the integrated master.

**The top three ranked backlog items all closed on 2026-09-05.** Nine PRs landed. What is left is
genuinely second-tier, so the next session should expect to re-rank rather than continue a queue.

## Read this before ranking anything: OPEN does not mean LIVE

Seven open issues turned out to be already fixed, four of them silently — GitHub closes only the FIRST
reference in `Fixes #a, #b, #c`, so everything after the first comma stays open forever. All seven are
now closed with the repro re-run and pinned against MRI, not on a PR title.

**Run an issue's repro before ranking, outsourcing or starting it.** `grep -rn "#<N>" lib/ spec/
changelog.d/` is the cheap pre-filter. And put each `Fixes #N` on its own line.

The same discipline caught a second class: **an issue can be a measurement artifact.** #530 item 2
("Sidekiq / Addressable / Doorkeeper unclaimed on mastodon") is not an engine defect — the survey
checkout has no `vendor/bundle`, and two of those gems are not installed anywhere on the host, so the
index correctly fails open to "no owner". Evidence is on the issue. Items 1 and 3 there are real.

## What landed

- [#758](https://github.com/rigortype/rigor/pull/758) ten scratch files that rode #753 onto the repo root ·
  [#759](https://github.com/rigortype/rigor/pull/759) (#756) a `spec/docs` gate checking every
  `raises`-omitting builtin-catalogue row against the C body it cites, which found ten more wrong rows ·
  [#761](https://github.com/rigortype/rigor/pull/761) (#611) bundle `sig/` discovery walks the
  `bundler/gems/` layout · [#764](https://github.com/rigortype/rigor/pull/764) (#716) a top-level `def`
  resolves its constants at the top level, as Ruby does.
- The ActiveSupport surface: [#760](https://github.com/rigortype/rigor/pull/760) (#670) `Date` / `DateTime`
  with per-class overrides, then [#765](https://github.com/rigortype/rigor/pull/765) (#762 + #659) removing
  five `Date` singletons ActiveSupport never defines, retyping `Date.beginning_of_week` to `Symbol`, and
  declaring `Duration`'s `ago` family.
- [#770](https://github.com/rigortype/rigor/pull/770) (**#610**) — a bundled plugin's signature now stands
  down against a colliding generic arity, so `rigor-activerecord` and `rbs collection install` stop
  cancelling each other out. Reproduced end-to-end first; the triage's belief that this needed a real
  `rbs collection install` was wrong, only a second declaration at a different arity is needed.
- [#771](https://github.com/rigortype/rigor/pull/771) (**#574** + #534 item 1) — `params[:key]` types
  `ActionController::Parameters?` instead of `Dynamic`, the largest untyped receiver pair on both survey
  apps. Diagnostics byte-identical on redmine and mastodon; `rigor coverage` precision 53.51% → 54.19% and
  55.66% → 56.04%.
- [#772](https://github.com/rigortype/rigor/pull/772) (**#763**) — a git-sourced gem owns its constants in
  the missing-RBS provenance index.

## Work in flight elsewhere — check before starting

**[#768](https://github.com/rigortype/rigor/pull/768) (#718) and [#769](https://github.com/rigortype/rigor/pull/769)
(#713) are open as DRAFTS with commits**, in `~/repo/ruby/rigor-wt/`. They are someone else's lane; do not
merge them. Coordinate before touching `spec/integration/precision_snapshot_spec.rb`, the
`spec/integration/snapshots/` goldens, or `lib/rigor/environment/rbs_loader.rb`.
`class-new-struct-factory-carrier` is clean and behind master.

## Backlog, ranked

1. **[#530](https://github.com/rigortype/rigor/issues/530) item 1** — WD9 tagging keys on CONSTANT READS,
   so a miss reached through a discovered superclass into a no-RBS gem records the generic cause
   (rubocop-ast, 41.3% mislabelled). Independent of any target having an installed bundle.
2. **[#728](https://github.com/rigortype/rigor/issues/728)** — per-site header nesting. Needs a new
   discovery table through the ADR-85 seed bundles and a persisted-schema bump with BOTH directions run.
3. **[#744](https://github.com/rigortype/rigor/issues/744) half 2** — should an INHERITED declaration
   outrank the receiver class's own source `def`? A human adjudication, not an implementation.
4. **[#534](https://github.com/rigortype/rigor/issues/534) remainder** — `expect` / `slice`, the Rails
   readers, `perform_async`, concern scopes, the AMS object. Item 1 is done; the rest is the live list.
5. Then **#700**, **#660**, **#605/#601**, and **[#530](https://github.com/rigortype/rigor/issues/530)
   item 3** (whose "distinct cause" half should also cover "Rigor could not see your gems at all").

Good outsourcing lanes, all independent and repro-complete: **#630** (four plugins bypass the
`IoBoundary`), **#686**, **#695 + #724** items 1-2 (#724 item 3 belongs to #713), **#720**.

## Pipeline notes (each earned by an incident)

- **A worktree SHARES `.git`, and submodules are NOT populated in one.** `references/ruby` is empty in a
  fresh worktree, so a gate reading it silently SKIPS — verify such a gate EXECUTED, not merely that it was
  green. A worker's `git submodule deinit` there deregistered the submodule for the MAIN CLONE. Adding a
  checkout in a worktree is fine; removing a registration never is.
- **Serialize the full gate across parallel lanes** with a `mkdir /tmp/rigor-verify.lock` mutex — parallel
  `make verify` runs have OOM-killed this host.
- **Subagents stall waiting on a backgrounded gate, and `SendMessage` may be disabled** — the coordinator
  then finishes the lane by hand, and an agent that later resumes collides with those commits. Brief every
  worker to run gates in the FOREGROUND with a generous timeout.
- **Verify the INTEGRATED master after a batch.** No single PR's CI sees the combination.
- **A control that cannot discriminate is worth nothing, and they fail quietly.** Two this session: a
  same-arity fixture that hit `DuplicatedMethodDefinitionError` instead of the arity path, and a
  must-still-fire arm that never fired on master either. Both looked green. Run the control against the
  UNFIXED tree and confirm it says what you think.
- A finding's REPRO is reproducible; its CHARACTERISATION is a separate claim. `docs/notes/`'s own
  top-level-def census called 66 name collisions "the canonical shape of the defect" and was wrong; the
  correction came from the implementer, not the author, and is recorded in place.
