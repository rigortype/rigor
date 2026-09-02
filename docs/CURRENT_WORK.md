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

**Seven PRs landed 2026-09-03** through the worktree → adversarial-review → draft-PR pipeline:
- [#654](https://github.com/rigortype/rigor/pull/654) (#626 drop rigor-railties' `::Rails` hard-code),
  [#664](https://github.com/rigortype/rigor/pull/664) (#635 relative constant paths in narrowing),
  [#666](https://github.com/rigortype/rigor/pull/666) (#632 `Duration` readers),
  [#669](https://github.com/rigortype/rigor/pull/669) (#644 cross-file value constants, SCHEMA 13),
  [#675](https://github.com/rigortype/rigor/pull/675) (#658 the Rails `Time` instance surface),
  [#676](https://github.com/rigortype/rigor/pull/676) (#665 spec-harness fail-fast),
  [#677](https://github.com/rigortype/rigor/pull/677) (#623 demodulized AR table names).

**The review round found more than the implementations did.** Every branch went through an
independent adversarial review that reproduced its findings; those rounds produced **19 new
issues**, and three branches shipped a *different* fix than the issue asked for because the review
falsified the issue's premise. Two implementations had to be split or narrowed to avoid shipping
false positives that the issue's own prescribed gate would have passed.

## The two themes worth carrying

**1. Constant resolution is one bug repeated in five resolvers.** #635 fixed it in `Narrowing`
(a multi-segment path is relative too — `Type::Nominal` inside `module Rigor` names
`Rigor::Type::Nominal`; the fix removed 2 FPs on concurrent-ruby and −1,091 opaque expressions).
The same defect — a constant resolved by string rather than through the lexical ladder — is open in
four more places: [#652](https://github.com/rigortype/rigor/issues/652) (compact `module A::B` gets
the nested form's nesting chain; the root fix closes reads, `is_a?`, `when` and `===` at once),
[#656](https://github.com/rigortype/rigor/issues/656) (a path's first segment never resolves through
ancestors), [#655](https://github.com/rigortype/rigor/issues/655) (the `case`/`when` VALUE side skips
the walk entirely and drops a live arm), [#662](https://github.com/rigortype/rigor/issues/662)
(`class << self` constants keyed to the enclosing module). #637/#638 are the same family.
**Fix #652 first** — it is the only one whose repair is shared by all four shapes.

**2. Absence assertions have been passing on crashed analysis, at scale.**
[#665](https://github.com/rigortype/rigor/issues/665) landed the guard for the two shared spec
helpers. [#674](https://github.com/rigortype/rigor/issues/674) is the rest and is the highest-value
self-testing item open: **1,177 of 1,925 examples still pass with every check rule crashing**, across
86 files with their own local `Runner.new` wrappers. The issue scopes it down to the 28 files whose
assertions are actually about diagnostics (~304 examples) — do not chase the raw number, the
effects/cache tiers pass because they never depended on check rules. Same shape at the engine level:
[#672](https://github.com/rigortype/rigor/issues/672), where a duplicated RBS row collapses a class
to `Dynamic` and the run exits 0 with *zero* diagnostics.

## Backlog, ranked

1. **[#674](https://github.com/rigortype/rigor/issues/674)** — the vacuity sweep above. Every other
   measurement in this repo rests on the suite meaning what it says.
2. **[#652](https://github.com/rigortype/rigor/issues/652)** — the constant-resolution root fix.
3. **[#653](https://github.com/rigortype/rigor/issues/653)** — a plugin-typed call still reports
   `call.undefined-method` when a partial RBS declares the receiver, so *writing more RBS makes a
   project's diagnostics worse*. Cheap, and it removes a perverse incentive.
4. **[#672](https://github.com/rigortype/rigor/issues/672)** + [#670](https://github.com/rigortype/rigor/issues/670)
   (Date/DateTime, the twin of the landed Time work — note the `-> self` sizing comment) +
   [#659](https://github.com/rigortype/rigor/issues/659) (`Duration#ago`, now unblocked).
5. **[#574](https://github.com/rigortype/rigor/issues/574)** (ready-for-HUMAN) — still the sole
   blocker on the corpus's biggest pair (`Parameters#[]`, 581 redmine + 496 mastodon). Measurement is
   DONE and on the issue; not agent-adjudicable.
6. Filed from this cycle's reviews, all with repros:
   [#667](https://github.com/rigortype/rigor/issues/667), [#668](https://github.com/rigortype/rigor/issues/668),
   [#671](https://github.com/rigortype/rigor/issues/671), [#673](https://github.com/rigortype/rigor/issues/673),
   [#661](https://github.com/rigortype/rigor/issues/661), [#663](https://github.com/rigortype/rigor/issues/663),
   [#657](https://github.com/rigortype/rigor/issues/657). Design call for a human:
   [#660](https://github.com/rigortype/rigor/issues/660).

## What the corpus cannot see (read this before writing a gate)

- **A survey-config `paths:` gate can be green while the change ships false positives.** #632's
  prescribed gate was "no new firing on redmine/mastodon"; those configs scope `paths: [app, lib]`
  while gitlab's 87 `to_fs` sites are under `spec/` and redmine's inside ERB in `test/fixtures/`. The
  FP was found only by an adversarial fixture. Widen `paths:` for the measurement and say that you did.
- **A collapsed class produces zero diagnostics**, so "nothing fires" passes on the failure. Gate on a
  declared return *resolving*.
- Corpus arms and review rounds are different instruments and stay mandatory together, in both
  directions — the corpus caught one the reviewers missed last cycle, reviewers caught FPs the corpus
  structurally could not see this cycle.

## Pipeline notes (the worker/reviewer contract earned these)

- Workers must find affected specs by **grepping the identifiers they changed**, not by name
  similarity: two files are named `pre_eval_constants_spec.rb`, and `spec/rigor/analysis/runner_spec.rb`
  is not `spec/rigor/analysis/runner/`. A tally with no pasted command behind it has been wrong here.
- Lint your own diff: `git diff --name-only origin/master...HEAD | grep '\.rb$' | xargs rubocop
  --force-exclusion`. Without `--force-exclusion` RuboCop ignores `Exclude` for explicit paths and
  reports phantom offenses; without the `.rb` filter it tries to parse `.rbs` as Ruby.
- A normative `MUST` written in the same PR is worth checking against the code: two branches this
  cycle shipped spec text broader than their implementation, and both were caught in review, not by a
  gate.
- `git update-ref` on a checked-out branch leaves the index holding a staged *reversal*. Use
  `git reset --hard origin/master` in the main clone, never `update-ref`.
- Two landing-script traps, both of which LOOK like a red gate and are not: `gh pr view --json
  headRefOid` lags a push, so reading it right after `git push` returns the previous commit and the
  run you then watch gets cancelled by the new commit's; and editing a shell script while a
  background invocation is running it corrupts that process (bash reads by byte offset).
