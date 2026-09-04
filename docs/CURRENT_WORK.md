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

**v0.3.7 is DEFERRED, deliberately, to raise completeness — there is no cut to prepare.** Do not read the
long fragment list as a release being overdue: 78 `changelog.d/` fragments and ~570 commits since v0.3.6 are
why the bar moved, not a backlog to flush. `Rigor::VERSION`, `CHANGELOG.md` and `Gemfile.lock` still move
only on an explicit request (ADR-50 § WD5), and the next session's job is this one's — close false positives
on correct code and finish the external reports, not tidy for a tag. `make verify` is green on master, and
every fragment carries its landing PR link, so the eventual cut is a consolidation, not archaeology.

**Fifteen fixes landed on 2026-09-04, all found by vetting the backlog against the release rather than by a
gate.** One theme runs through them: *the analysis had the answer and the output said otherwise.*

- [#733](https://github.com/rigortype/rigor/pull/733) (#723) / [#734](https://github.com/rigortype/rigor/pull/734)
  (#684) — the rule asked a name-keyed table while the typer walked the ancestry; discovery ran over the
  INVOCATION's file set, so `rigor check one_file.rb` reported what `rigor check .` does not.
- The receivers the rule could not enumerate but did: [#741](https://github.com/rigortype/rigor/pull/741)
  (#739, mixin-module `self` and its `self.class`), [#743](https://github.com/rigortype/rigor/pull/743)
  (#742, an inherited method under a sidecar `sig/`, plus `Class` / `Module`),
  [#747](https://github.com/rigortype/rigor/pull/747) (#746, a class including a module no RBS declares).
  Each closed a fork where the UNION rule already declined what the scalar rule reported.
- sig-gen writing signatures its own checker contradicts: [#737](https://github.com/rigortype/rigor/pull/737)
  (#735, 98 collapsed classes + sidecar monkey-patch reports),
  [#738](https://github.com/rigortype/rigor/pull/738) (#722 r3, flattened superclass token),
  [#745](https://github.com/rigortype/rigor/pull/745) (#744, a base's return inherited by an unsigned
  override).
- [#740](https://github.com/rigortype/rigor/pull/740) (#736) `mattr_accessor` / `class_attribute`;
  [#748](https://github.com/rigortype/rigor/pull/748) (#731) the singleton-side ancestor walk (+62 precise
  sites); [#749](https://github.com/rigortype/rigor/pull/749) (#728 half) a self-rebinding block's mixin;
  [#751](https://github.com/rigortype/rigor/pull/751) (#657) an UNKNOWN ordering collapsing to `Bot`;
  [#754](https://github.com/rigortype/rigor/pull/754) (#722 r1 / #637) a rooted ancestor name resolved
  lexically; [#757](https://github.com/rigortype/rigor/pull/757) the `raises` facet on 36 catalogue rows.

**The sig-gen workflow drove seven of them, and is the completeness measurement worth repeating.**
`sig-gen --write` on redmine then `check`, per site: the penalty for running the command ADR-14 recommends
fell from **82 extra diagnostics over the project's own no-`sig/` baseline to 5** — three `class_eval`-string
metaprogramming, one `include Singleton` ([#527](https://github.com/rigortype/rigor/issues/527)), and one
TRUE POSITIVE (`Views::Builders::Structure < BasicObject` calls `self.class.name`, which raises).

## Work in flight elsewhere — check before starting

Parallel lanes were handed out; several landed (#752 test isolation, #753 acceptance autoload, #755 `rigor
unused` rooted constants, #671). **Worktrees exist for #713 and #718** under `~/repo/ruby/rigor-wt/` with no
commits yet; the plugin lanes (#670/#659/#673, #629, #678/#679) have no branch. Coordinate before touching
`spec/rigor/public_api_drift_spec.rb`, `spec/spec_helper.rb`, `plugins/rigor-activerecord/**` or
`plugins/rigor-activesupport-core-ext/**`.

## Backlog, ranked

1. **[#610](https://github.com/rigortype/rigor/issues/610)** — every AR relation degrades to `Dynamic[top]`
   when `rbs collection install` and `rigor-activerecord` are both used (the documented Rails setup).
   Structurally confirmed, **not reproduced end-to-end**; the issue comment says what a real repro needs.
   The largest user-facing unknown left, and the one a deferred release exists to fix.
2. **[#744](https://github.com/rigortype/rigor/issues/744) half 2** (needs adjudication) — should an
   INHERITED declaration outrank the receiver class's own source `def`? RBS semantics say yes and
   `def.return-type-mismatch` reports the inconsistency; FP-first says the override's type flows. #745
   stopped sig-gen manufacturing the conflict; the engine question is untouched.
3. **[#728](https://github.com/rigortype/rigor/issues/728)'s titled half** — per-SITE header nesting.
   Reproduced (rigor `:outer`, MRI `:top`). What is left needs a NEW discovery table through the ADR-85 seed
   bundles — a persisted-format schema bump with both directions run. The issue comment sizes it.
4. **#722 residues 2 and 4**; **#756** (nothing checks `c_effects` against the C body it cites); **#732** is
   real but INERT, see the measurement note. Then **#700**, **#660**, **#574** — the human ADR
   adjudications; #574 still gates the corpus's biggest pair (`Parameters#[]`, 581 redmine + 496 mastodon).

## Measurement — read before writing a gate or trusting a number

- **Neuter the change and confirm the new example — and ONLY that example — fails.** #734's cache arm was
  verified that way, #737's and #738's likewise. "The gate is green" and "the gate can execute that path"
  remain different claims.
- **A corpus diff can be inert by construction, and a corpus of ZERO is a result, not a gap.** #733 is
  byte-identical on redmine and Rigor's own `lib` — no movable site. `flow.unreachable-clause` fires zero
  times across redmine, mastodon and five gems (all on `lenient`, where it IS reported), so #751 could not
  be sized on the corpus and said so.
- **Run the user's own workflow end to end before believing the feature works.** `sig-gen --write` on a real
  Rails app then `check` found #735 and #736 while every gate stayed green — our own `sig/` is thorough
  enough never to reach the shape.
- **No gate, no landing.** #732's stated missed detection does not exist: both consumers additionally
  require a def node or an RBS declaration the widened predicate does not supply, so the one-line "fix"
  could not be made to fail without itself. Dropped, evidence written back to the issue.
- **Ask the expensive probe where the answer is needed.** #733's ancestor walk and #747's include walk both
  record ADR-46 ancestry edges; on the hot path each coarsened invalidation project-wide, and
  `dependency_recorder_spec` was the only thing that caught either. Expect a third.
- **Measure the obvious optimisation, and a suppression's COST as well as its benefit.** A `sig/`-presence
  gate on #734's widening looked free and would have missed the whole monkey-patching population; #747
  landed on "the no-`sig/` baseline is unchanged at 26". A PRECISION change is read on the precision
  instrument: #748 is byte-identical in diagnostics and +62 precise sites in `rigor coverage`.

## Pipeline notes (each earned by an incident)

- **Uncommitted edits in the shared main clone travel across branch switches and get swept by `git add -A`.**
  A `data/builtins/` import sat loose all session and came within one commit of riding an unrelated engine
  PR (#757 landed it separately, all 36 rows re-verified against the C source). Give every parallel worker
  its own worktree — `~/repo/ruby/rigor-wt/`.
- **`gh pr checks --watch` exits 0 with "no checks reported" inside the registration window.** Confirm
  `statusCheckRollup` is non-empty first, then read the per-check outcomes, not the wrapper's exit code.
- **A finding's REPRO is reproducible; its CHARACTERISATION is a separate claim.** #723 and #684 were filed
  as one family with two unrelated roots; #732's characterisation was mine and wrong. Read the code.
- **A spec can use a diagnostic as its observable and be invalidated by a correct fix.** #737 removed the
  ADR-17 message `runner_fork_pool_spec` used to prove pool seeding; #748 turned a `Dynamic[top]`
  `railties_plugin_spec` read as "the gate declined" into a real answer. Both moved the fixture rather than
  weakening the contract, and got STRONGER assertions out of it.
- Structural guards ENUMERATE a surface (`public_api_drift_spec` in BOTH halves). Read gate exit codes
  UNPIPED. Lint your diff with `--force-exclusion`. File the follow-up issue BEFORE the PR that cites it.
  After a parallel batch, verify the INTEGRATED master.
