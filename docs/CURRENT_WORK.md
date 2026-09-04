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

**Master is the release candidate and `make verify` is green on it.** 75 changelog fragments and ~560 commits
since v0.3.6, every fragment carrying its landing PR link. The version bump is NOT autonomous —
`Rigor::VERSION`, `CHANGELOG.md` and `Gemfile.lock` move only on an explicit request (ADR-50 § WD5, the
`rigor-release-prep` skill), which consolidates `changelog.d/` at the cut.

**Twelve fixes landed on 2026-09-04, all found by vetting the backlog against the release
rather than by a gate.** One theme runs through every one of them: *the analysis had the answer and the
output said otherwise.*

- [#733](https://github.com/rigortype/rigor/pull/733) (#723) — the rule asked a name-keyed table while the
  typer walked the project's ancestry, so a `sig/`-declared class drew `undefined method 'x'` on the line
  `dump_type` printed `x`'s type on.
- [#734](https://github.com/rigortype/rigor/pull/734) (#684) — discovery ran over the INVOCATION's file
  set, so `rigor check one_file.rb` reported what `rigor check .` does not. It now spans the configured
  project while the analysis targets the given files (0.55s over `lib`'s 444; whole-project runs unchanged).
- [#737](https://github.com/rigortype/rigor/pull/737) (#735) — `sig-gen --write` made the next run **5.9×
  noisier**: unresolvable superclasses collapsed 98 classes, and a partial sidecar turned every cross-file
  `def` into an ADR-17 monkey-patch report. [#738](https://github.com/rigortype/rigor/pull/738) (#722 r3)
  fixed the flattened superclass token.
- The receivers the rule could not enumerate but did: [#741](https://github.com/rigortype/rigor/pull/741)
  (#739, mixin-module `self` and its `self.class`), [#743](https://github.com/rigortype/rigor/pull/743)
  (#742, an inherited method under a sidecar `sig/`, plus `Class` / `Module`),
  [#747](https://github.com/rigortype/rigor/pull/747) (#746, a class including a module no RBS declares).
  Each closed a fork where the UNION rule already declined what the scalar rule reported.
- [#740](https://github.com/rigortype/rigor/pull/740) (#736) — `mattr_accessor` / `cattr_accessor` /
  `class_attribute` introduce methods discovery never recorded.
  [#745](https://github.com/rigortype/rigor/pull/745) (#744) — sig-gen wrote a base class's precise return
  for a method an unsigned subclass overrides, and RBS gave the subclass the base's answer.
- [#748](https://github.com/rigortype/rigor/pull/748) (#731) — the singleton-side lookup walks the
  superclass chain (+62 precise sites on redmine, diagnostics byte-identical).
  [#749](https://github.com/rigortype/rigor/pull/749) (#728, half) — `Class.new { include M }` in a class
  body put `M` on the class around it.
- [#751](https://github.com/rigortype/rigor/pull/751) (#657) — an UNKNOWN class ordering collapsed the
  positive edge to `Bot`, so reopening a core class with a project module made every `case`/`is_a?` arm on
  that module read as dead code.

**The sig-gen workflow drove seven of the twelve.** `sig-gen --write` on redmine then `check`, per site:
the penalty for running the command ADR-14 recommends fell from **82 extra diagnostics over the project's
own baseline to 5** (baseline moved once, by 3, deliberately — #743's `Class` receivers). Of the five left,
three are `class_eval`-string metaprogramming, one is `include Singleton`'s class-side `instance`
([#527](https://github.com/rigortype/rigor/issues/527)), and one is a TRUE POSITIVE:
`Views::Builders::Structure < BasicObject` calls `self.class.name`, which raises.

**The three external reports (#609/#610/#611) are triaged** — they had sat unlabelled; #609 and #610 carry
what today established and what it could NOT reproduce.

## Backlog, ranked

1. **[#744](https://github.com/rigortype/rigor/issues/744) half 2** (needs adjudication) — should an
   INHERITED declaration outrank the receiver class's own source `def`? RBS semantics say yes and
   `def.return-type-mismatch` already reports the inconsistency; FP-first says the type that flows is the
   override's. #745 stopped sig-gen manufacturing the conflict; the engine question is untouched.
2. **[#610](https://github.com/rigortype/rigor/issues/610)** — every AR relation degrades to `Dynamic[top]`
   when `rbs collection install` and `rigor-activerecord` are both used (the documented Rails setup).
   Structurally confirmed, **not reproduced end-to-end**; the issue comment says what a real repro needs.
3. **[#728](https://github.com/rigortype/rigor/issues/728)'s titled half** — per-SITE header nesting.
   Reproduced (rigor `:outer`, MRI `:top`). #749 took its second half; what is left needs a NEW discovery
   table through the ADR-85 seed bundles — a persisted-format schema bump with both directions run. The
   issue comment records that cost so the next person sizes it first.
5. **#722** residues 1, 2 and 4 (the rooted/compact ancestor names); **#732** is real but INERT — see the
   measurement note. **#717 is closed** (verified fixed by #725); #718's banner wall stands.
6. **#700**, **#660**, **#574** — the human ADR adjudications. #574 still gates the corpus's biggest pair
   (`Parameters#[]`, 581 redmine + 496 mastodon).

## Measurement — read before writing a gate or trusting a number

- **Neuter the change and confirm the new example — and ONLY that example — fails.** #734's cache arm was
  verified that way; #737's and #738's discriminating examples likewise, with their controls stated as
  controls. "The gate is green" and "the gate can execute that path" remain different claims.
- **A corpus diff can be inert by construction, and a corpus of ZERO is a result, not a gap.** #733 is
  byte-identical on redmine and Rigor's own `lib` — neither holds a movable site. `flow.unreachable-clause`
  fires zero times across redmine, mastodon and five gems (all on `lenient`, where it IS reported), so #751
  could not be sized on the corpus and said so.
- **Run the user's own workflow end to end before believing the feature works.** `sig-gen --write` on a real
  Rails app, then `check`, found #735 and #736 while every gate in the repo stayed green — our own `sig/` is
  thorough enough never to reach the shape.
- **No gate, no landing.** #732's stated missed detection does not exist: both consumers of the narrow
  predicate additionally require a def node or an RBS declaration that the widened one does not supply, so
  the one-line "fix" could not be made to fail without itself. Dropped, with the evidence written back to
  the issue — the fork is real but inert, and priced accordingly.
- **Ask the expensive probe where the answer is needed.** #733's ancestor walk and #747's include walk both
  record ADR-46 ancestry edges; on the hot path each coarsened incremental invalidation project-wide, and
  `dependency_recorder_spec` was the only thing that caught either. Expect a third.
- **Measure the obvious optimisation, and a suppression's COST as well as its benefit.** A `sig/`-presence
  gate on #734's widening looked free and would have missed the whole monkey-patching population; #747
  landed on "the no-`sig/` baseline is unchanged at 26", the number that would have said "too broad".

## Pipeline notes (each earned by an incident)

- **`gh pr checks --watch` exits 0 with "no checks reported" inside the registration window.** Confirm
  `statusCheckRollup` is non-empty first, then read the per-check outcomes, not the wrapper's exit code.
- **A finding's REPRO is reproducible; its CHARACTERISATION is a separate claim.** #723 and #684 were filed
  as one family and have two unrelated roots; #732's characterisation was mine and was wrong. Read the code.
- **A spec can use a diagnostic as its observable and be invalidated by a correct fix.** #737 removed the
  ADR-17 message `runner_fork_pool_spec` used to prove pool seeding; #748 turned a `Dynamic[top]` that
  `railties_plugin_spec` read as "the gate declined" into a real answer. Both moved the fixture rather than
  weakening the contract, and both got STRONGER assertions out of it.
- Structural guards ENUMERATE a surface (`public_api_drift_spec` in BOTH halves — the runtime list is
  order-sensitive and the `sig/` coverage half is separate). Check by COMPUTING what they pin.
- Read gate exit codes UNPIPED. Lint your own diff with `--force-exclusion`. File a follow-up issue BEFORE
  opening the PR that cites it. After a parallel batch, verify the INTEGRATED master.
