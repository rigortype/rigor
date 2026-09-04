<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Hard cap: 120 lines, enforced by spec/docs/agent_index_spec.rb. Compress, do not append.
- Verify a claim before carrying it forward, by the thing that decides rather than a proxy —
  including claims in THIS file. Two sessions running, its own pointers have been wrong.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones.
If this file disagrees with an ADR, the CHANGELOG, or an issue, this file is the one that is wrong.

## Where the cycle stands

**v0.3.7 is still DEFERRED, deliberately, to raise completeness — there is no cut to prepare.** 84
`changelog.d/` fragments and 585 commits since v0.3.6 are why the bar moved, not a backlog to flush.
`Rigor::VERSION`, `CHANGELOG.md` and `Gemfile.lock` move only on an explicit request (ADR-50 § WD5).
`make verify` and `make docs-check` are green on the integrated master, and every fragment carries its
landing PR link.

## Read this before ranking anything: OPEN does not mean LIVE

Six PRs landed on 2026-09-05, but the session's most useful hour was spent discovering that **seven open
issues were already fixed**. GitHub closes only the FIRST reference in `Fixes #a, #b, #c` — every issue
after the first comma stays open forever. #678/#679 (by [#750](https://github.com/rigortype/rigor/pull/750))
and #727 (by [#752](https://github.com/rigortype/rigor/pull/752)) died that way; #682, #637, #638 and #662
were fixed by the #652/#709/#721/#754 constant-resolution arc and simply never closed.

All seven are now closed with the repro re-run and pinned against MRI, not on a PR title. **Run an issue's
repro before ranking, outsourcing or starting it** — `grep -rn "#<N>" lib/ spec/ changelog.d/` is the cheap
pre-filter, an implementation comment naming the issue usually means it landed. And put each `Fixes #N` on
its own line.

## What landed

- [#758](https://github.com/rigortype/rigor/pull/758) — ten scratch files (`test.rb`…`test10.rb`) that rode
  #753 onto the repository root. The `git add -A` hazard this file documented, one day later.
- [#759](https://github.com/rigortype/rigor/pull/759) (#756) — a `spec/docs` gate checking every
  `raises`-omitting builtin-catalogue row against the C body its own `c_body_at` cites. Found ten more wrong
  rows beyond #757's 36 and fixed the data rather than loosening the check.
- [#760](https://github.com/rigortype/rigor/pull/760) (#670) — the ActiveSupport `Date` / `DateTime` surface,
  with per-class `DateTime` overrides. [#765](https://github.com/rigortype/rigor/pull/765) (#762 + #659) then
  removed five `Date` singletons ActiveSupport never defines, retyped `Date.beginning_of_week` to `Symbol`,
  and declared `Duration`'s six-method `ago` family.
- [#761](https://github.com/rigortype/rigor/pull/761) (#611) — bundle `sig/` discovery now walks the
  `bundler/gems/` layout, so a git-sourced gem's own signatures are found.
- [#764](https://github.com/rigortype/rigor/pull/764) (#716) — a top-level `def` resolves its constants at the
  top level, as Ruby does, instead of under the caller's namespace.

## Two measurements that change what is worth doing

**[#574](https://github.com/rigortype/rigor/issues/574)'s stated blocker does not exist.** The issue said the
witness-gate tightening needs its own corpus FP/FN diff before landing. That diff has been run and is empty:
1,529 analysis examples pass unchanged, redmine (1,016 diagnostics) and mastodon (2,356) are byte-identical,
and the `Dynamic | String | nil` must-fire example it predicted would break keeps firing. The zero is not an
unexercised path — a second counter shows the vacuity firing 198 times across the two corpora; every one of
those arms is a project class the discovery table knows, so it stays a legitimate witness under #574's own
criterion. **It cannot land alone** (`params[:username]` types as non-nilable `Parameters` today, so the new
branch is unreachable) — land it WITH #534 item 1's `#[] -> Parameters | nil`, which is the pair that gates.
Harness: branch `measure/574-witness-gate`, do-not-merge, two counters behind `RIGOR_574_PROBE`.

**[#656](https://github.com/rigortype/rigor/issues/656) is real and not release-blocking.** Reproduced (wrong
class, then a false positive against it). Sized at **6 movable sites in 210,000 constant paths** across eight
targets — all gitlab, all through an `include` edge (a superclass-only probe finds zero), five of the six in
`spec/`. The fix is segment-by-segment ancestor resolution in two hot resolvers; six sites does not buy that
risk now. Note the correction in the issue: the HEAD segment resolves fine, the second one does not.

## Work in flight elsewhere — check before starting

**Worktrees under `~/repo/ruby/rigor-wt/`: #713 (120 dirty files) and #718 (1), both still uncommitted** after
two sessions; `class-new-struct-factory-carrier` is clean and behind master. Coordinate before touching
`spec/integration/precision_snapshot_spec.rb`, the `spec/integration/snapshots/` goldens, or
`lib/rigor/environment/rbs_loader.rb`.

## Backlog, ranked

1. **[#610](https://github.com/rigortype/rigor/issues/610)** — every AR relation degrades to `Dynamic[top]`
   under the documented Rails setup. Still the largest user-facing unknown, still **not reproduced
   end-to-end**; needs a real Rails app plus an actual `rbs collection install`.
2. **[#574](https://github.com/rigortype/rigor/issues/574) + [#534](https://github.com/rigortype/rigor/issues/534) item 1 as ONE PR** — now unblocked by measurement, and the corpus's biggest FP pair (`Parameters#[]`, 581 redmine + 496 mastodon).
3. **[#763](https://github.com/rigortype/rigor/issues/763)** (new) — `MissingGemConstantIndex` still walks only
   the RubyGems layout, so a git-sourced gem owns none of its constants; feeds #530's mislabelling.
4. **[#744](https://github.com/rigortype/rigor/issues/744) half 2** and **[#728](https://github.com/rigortype/rigor/issues/728)** — the adjudication and the persisted-schema half, unchanged.
5. Then **#700**, **#660**, **#605/#601** — the human adjudications.

Good next outsourcing lanes, all independent and repro-complete: **#630** (four plugins bypass the
`IoBoundary`), **#530**, **#686**, **#695 + #724** items 1-2 (#724 item 3 belongs to #713).

## Pipeline notes (each earned by an incident)

- **A worktree SHARES `.git`, and submodules are NOT populated in one.** `references/ruby` is empty in a fresh
  worktree, so a gate reading it silently SKIPS — verify such a gate EXECUTED, not merely that it was green.
  A worker's `git submodule deinit` there deregistered the submodule for the MAIN CLONE (files survived,
  `git status` stayed clean, only `git submodule status` showed it). Adding a checkout in a worktree is fine;
  removing a registration never is.
- **Serialize the full gate across parallel lanes** with a `mkdir /tmp/rigor-verify.lock` mutex — parallel
  `make verify` runs have OOM-killed this host. Expect several minutes per gate under contention.
- **Subagents stall waiting on a backgrounded gate, and `SendMessage` may be disabled** — then the coordinator
  must finish the lane by hand, and an agent that later resumes will collide with those commits. Brief every
  worker to run gates in the FOREGROUND with a generous timeout.
- **Verify the INTEGRATED master after a batch.** Run it; no single PR's CI sees the combination.
- A finding's REPRO is reproducible; its CHARACTERISATION is a separate claim. `docs/notes/`'s own
  top-level-def census called 66 name collisions "the canonical shape of the defect" and was wrong — the
  reading defs were all in `spec/`, where no caller pushes a cref. It is corrected in place; the correction
  came from the implementer, not the author.
