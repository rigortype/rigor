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

**Master is the release candidate and `make verify` is green on it.** 68 changelog fragments and ~530 commits
since v0.3.6, every fragment carrying its landing PR link. The version bump is NOT autonomous —
`Rigor::VERSION`, `CHANGELOG.md` and `Gemfile.lock` move only on an explicit request (ADR-50 § WD5, the
`rigor-release-prep` skill), which consolidates `changelog.d/` at the cut.

**Six false-positive fixes landed on 2026-09-04, all found by vetting the backlog against the release
rather than by a gate.** One theme runs through every one of them: *the analysis had the answer and the
output said otherwise.*

- [#733](https://github.com/rigortype/rigor/pull/733) (#723) — the rule asked a name-keyed table while the
  typer walked the project's ancestry, so a class declared in `sig/` without its superclass drew
  `undefined method 'x'` on the line `dump_type` printed `x`'s type on.
- [#734](https://github.com/rigortype/rigor/pull/734) (#684) — discovery ran over the INVOCATION's file
  set, so `rigor check one_file.rb` reported what `rigor check .` does not. It now spans the configured
  project while the analysis still targets the given files (0.55s over `lib`'s 444 files; whole-project runs
  are byte-identical and pay nothing).
- [#737](https://github.com/rigortype/rigor/pull/737) (#735) — `sig-gen --write` on redmine made the next
  run **5.9× noisier**: unresolvable superclasses collapsed 98 classes, and a partial project sidecar turned
  every cross-file `def` into an ADR-17 monkey-patch report. 171 → 121 `call.undefined-method`, 8 → 0 failed
  builds.
- [#738](https://github.com/rigortype/rigor/pull/738) (#722 residue 3) — a flattened declaration's
  superclass token silently re-pointed at a different class than the checker resolves.
- [#740](https://github.com/rigortype/rigor/pull/740) (#736) — `mattr_accessor` / `cattr_accessor` /
  `class_attribute` introduce methods discovery never recorded.
- [#741](https://github.com/rigortype/rigor/pull/741) (#739) — a mixin module's surface belongs to its
  includer and cannot be enumerated; the rule enumerated it anyway, and its union twin never had.

**The sig-gen workflow is the measurement that drove four of the six.** `sig-gen --write` on redmine then
`check`, deduplicated by site, against the project's own no-`sig/` baseline of **29** `call.undefined-method`:
111 before today, **43** now — the penalty for running the command ADR-14 recommends fell from 82 extra
diagnostics to 14. The baseline itself never moved, so none of it was bought by silencing real findings.

**The three external reports (#609/#610/#611) are triaged** — they had sat unlabelled. #609 and #610 carry
what today's investigation established and, as importantly, what it could NOT reproduce.

## Backlog, ranked

1. **The last 14.** A generated `sig/` still costs 14 `call.undefined-method` over baseline on redmine, now
   spread across shapes rather than concentrated (`FixedIssuesExtension`, `Redmine::Plugin`,
   `Redmine::Scm::Adapters::FilesystemAdapter`, a `Module` receiver, four with a `nil` receiver). Nobody has
   adjudicated them one by one yet; that is the next honest step, and it is small enough to finish.
2. **[#610](https://github.com/rigortype/rigor/issues/610)** — every AR relation degrades to `Dynamic[top]`
   when `rbs collection install` and `rigor-activerecord` are both used, which is the documented Rails setup.
   Structurally confirmed; **not reproduced end-to-end** — the issue comment records why (a synthetic fixture
   cannot exercise the plugin's `Relation` typing) and what a real reproduction needs.
3. **[#728](https://github.com/rigortype/rigor/issues/728)** — reproduced: rigor answers `:outer` where MRI
   answers `:top`. A wrong class, not a wider candidate list.
4. **[#731](https://github.com/rigortype/rigor/issues/731)** — a class method inherited from a project
   superclass types `Dynamic[top]`: the singleton-side lookup has no ancestor walk.
   `sig_declared_ancestor_undefined_method_spec` ASSERTS that `Dynamic[top]`, so closing it fails there.
5. **[#722](https://github.com/rigortype/rigor/issues/722)** residues 1, 2 and 4;
   **[#732](https://github.com/rigortype/rigor/issues/732)** (the forked `known_user_class?`);
   **[#717](https://github.com/rigortype/rigor/issues/717)** / **[#718](https://github.com/rigortype/rigor/issues/718)**
   (banner noise — but #725 already made `Location#_dump` preserve buffer names, so re-check what `<cached>`
   still reaches before working it).
6. **[#700](https://github.com/rigortype/rigor/issues/700)**, **[#660](https://github.com/rigortype/rigor/issues/660)**,
   **[#574](https://github.com/rigortype/rigor/issues/574)** — the human ADR adjudications. #574 still gates
   the corpus's biggest pair (`Parameters#[]`, 581 redmine + 496 mastodon).

## Measurement — read before writing a gate or trusting a number

- **Neuter the change and confirm the new example — and ONLY that example — fails.** #734's cache arm was
  verified that way; #737's and #738's discriminating examples likewise, with their controls stated as
  controls. "The gate is green" and "the gate can execute that path" remain different claims.
- **A corpus diff can be inert by construction, and saying so is part of the result.** #733 is byte-identical
  on redmine (1,019 diagnostics) and on Rigor's own `lib` (2) — but redmine has no `sig/` and Rigor's own
  declares its superclasses, so neither contains a movable site. Evidence it silences nothing, not evidence
  it fixes anything.
- **Run the user's own workflow end to end before believing the feature works.** `sig-gen --write` on a real
  Rails app, then `check`, is what found #735 and #736; every gate in the repo was green throughout, because
  our own `sig/` is thorough enough never to hit the shape.
- **Ask the expensive probe where the answer is needed.** #733's ancestor walk records ADR-46 ancestry edges;
  on the hot path it coarsened incremental invalidation project-wide (`dependency_recorder_spec` caught it).
- **Measure the obvious optimisation before adopting it.** A `sig/`-presence gate on #734's widening looked
  free and would have missed the whole monkey-patching population.
- A compatibility claim about a **persisted** format needs both directions run (#725).

## Pipeline notes (each earned by an incident)

- **`gh pr checks --watch` exits 0 with "no checks reported" inside the registration window**, and again on a
  network drop mid-watch. Confirm `statusCheckRollup` is non-empty first, and read the per-check outcomes
  (`awk -F'\t' '{print $2}' | sort | uniq -c`) rather than the wrapper's exit code.
- **A finding's REPRO is reproducible; its CHARACTERISATION is a separate claim.** #723 and #684 were filed
  as one family and have two unrelated roots; reading the code, not the issues, settled it.
- **A spec can use a diagnostic as its observable and be invalidated by a correct fix.**
  `runner_fork_pool_spec` asserted the ADR-17 message to prove the pool's discovery seeding; #737 legitimately
  removed that message, and the fixture moved to a bundled class rather than the contract being weakened.
- Structural guards ENUMERATE a surface (`public_api_drift_spec` in BOTH halves — the runtime list is
  order-sensitive and the `sig/` coverage half is separate). Check by COMPUTING what they pin.
- Read gate exit codes UNPIPED. Lint your own diff with `--force-exclusion`. File a follow-up issue BEFORE
  opening the PR that cites it. After a parallel batch, verify the INTEGRATED master.
