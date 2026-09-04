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

**A release is imminent and master is the release candidate.** 64 changelog fragments and ~510 commits since
v0.3.6; `make verify` green on the integrated tree. The version bump is NOT autonomous — `Rigor::VERSION`,
`CHANGELOG.md` and `Gemfile.lock` move only on an explicit request (ADR-50 § WD5, the `rigor-release-prep`
skill). Release prep consolidates `changelog.d/` at the cut; every fragment now carries its landing PR link.

**Two false positives on correct code landed today, both found by vetting the backlog against the release
rather than by a gate.** [#733](https://github.com/rigortype/rigor/pull/733) (#723) and
[#734](https://github.com/rigortype/rigor/pull/734) (#684) are the same family — *the analysis had the
answer and the rule reported otherwise* — with two unrelated roots:

- #723: `CheckRules#source_declared_method?` asked a table keyed on the receiver's own NAME while the typer
  resolved the call through the project ancestor walk, so a class declared in `sig/` without its project
  superclass drew `undefined method 'x'` on the line `dump_type` printed `x`'s return type on. Writing MORE
  RBS made the run worse — #653's incentive with the project's own ancestry in the plugin's place.
- #684: the cross-file discovery pre-pass ran over the INVOCATION's file set, so `rigor check one_file.rb`
  reported what `rigor check .` does not. Discovery now spans the configured project while the analysis
  still targets the given files (ADR-46 §2's property, extended to the CLI's own invocation). Measured:
  the discovery pass is 0.55s over `lib`'s 444 files, so a cold single-file check goes 0.54s → 1.15s; a
  whole-project run is byte-identical and pays nothing.

## Backlog, ranked — vetted against this release, reproduction status stated

Everything below was reproduced on master today unless marked otherwise. Titles are not evidence; three
issues that read like the same bug turned out to have three different roots.

1. **[#610](https://github.com/rigortype/rigor/issues/610)** (external, still untriaged with #609/#611) —
   `rigor-activerecord`'s `class Relation[Elem]` collides with `gem_rbs_collection`'s non-generic
   `Relation`, and EVERY AR relation degrades to `Dynamic[top]`. The documented Rails setup
   (`rbs collection install` + the plugin) is what triggers it. Structurally confirmed
   (`plugins/rigor-activerecord/sig/active_record/relation.rbs:51`); not reproduced end-to-end, which needs
   a real collection checkout. This is the biggest user-facing item open.
2. **[#722](https://github.com/rigortype/rigor/issues/722) residue 3 — SigGen's renderer.** Two live wrong
   outputs confirmed today: `module Outer; class ::Rooted < ::Base` is emitted as `class Outer::Rooted`
   (a class that does not exist, and the real one omitted), and a cross-file lexical superclass is emitted
   as `< Record` where the checker itself resolves `Admin::Record` on the same tree. RBS resolves a compact
   header's superclass at the TOP level (verified against the rbs gem), so flattening a nested declaration
   changes what the emitted token means — `generator.rb:record_superclass`'s "matches Ruby's lexical scope"
   comment is true only when the emitted namespace equals the source nesting. A complete fix needs sig-gen's
   per-file scope seeded with project discovery; it has none today.
3. **[#609](https://github.com/rigortype/rigor/issues/609)** (external) — `sig-gen --write` produces a
   `sig/` the next run cannot load. Probe first: the self-inheritance shapes #721 repaired are the leading
   suspect, so this may already be closed on master. Cheap to settle against the reporter's repro, and a
   good release note either way.
4. **[#728](https://github.com/rigortype/rigor/issues/728)** — reproduced: rigor answers `:outer` where MRI
   answers `:top`. A wrong class, not a wider candidate list; #721's residual union.
5. **[#731](https://github.com/rigortype/rigor/issues/731)** (new) — a class method inherited from a project
   superclass types `Dynamic[top]`: the singleton-side lookup has no ancestor walk. Precision, not an FP.
   `spec/integration/sig_declared_ancestor_undefined_method_spec.rb` ASSERTS the `Dynamic[top]`, so closing
   it fails there with the reason.
6. **[#732](https://github.com/rigortype/rigor/issues/732)** (new) — `known_user_class?` is forked between
   `Scope` and `CheckRules`; #733 widened only the `Scope` copy.
7. **[#717](https://github.com/rigortype/rigor/issues/717) / [#718](https://github.com/rigortype/rigor/issues/718)** —
   banner noise around #696's new diagnostic. Note #725 already made `Location#_dump` preserve the buffer
   name, so re-check what `<cached>` still reaches: the cold path now prints real paths.
8. **[#700](https://github.com/rigortype/rigor/issues/700)**, **[#660](https://github.com/rigortype/rigor/issues/660)**,
   **[#574](https://github.com/rigortype/rigor/issues/574)** — the human ADR adjudications. #574 still gates
   the corpus's biggest pair (`Parameters#[]`, 581 redmine + 496 mastodon).

## Measurement — read before writing a gate or trusting a number

- **"The gate is green" and "the gate can EXECUTE that path" are different claims.** #696 paid for this
  three times. The working form: neuter the change and confirm the new example — and ONLY that example —
  fails. #734's cache arm was verified that way; three of its five examples fail on master and two are
  controls that pass both ways by design.
- **A corpus diff can be inert by construction, and saying so is part of the result.** #733 is
  byte-identical on redmine (1,019 diagnostics) and on Rigor's own `lib` (2) — but redmine has no `sig/`
  at all and Rigor's own `sig/` declares its superclasses, so neither corpus contains a movable site. That
  is evidence the change silences nothing, not evidence it fixes anything. The fixture was the instrument.
- **A collapsed class, a crashed run, an empty plugin registry and an empty capture all produce zero
  diagnostics.** Assert the TYPE alongside the rule set; compare two non-empty answers, not two empties.
- **Ask the expensive probe where the answer is needed, not where it is convenient.** #733's ancestor walk
  reads `superclass_of` / `includes_of`, which record ADR-46 ancestry edges. Placed on the hot path it made
  `Widget.new` — a call RBS answers — record an ancestry dependency, coarsening incremental invalidation
  project-wide. `dependency_recorder_spec` caught it; nothing else would have.
- **Measure the obvious optimisation before adopting it.** A `sig/`-presence gate on #734's widening looked
  free and would have missed the whole monkey-patching population: the same shape occurs with no project
  signatures, through a reopened core class.
- A compatibility claim about a **persisted** format needs both directions run (#725).

## Pipeline notes (each earned by an incident)

- **`gh pr checks --watch` exits 0 with "no checks reported" when it runs inside the registration window.**
  That is the #608 misread, and it is silent. Confirm `statusCheckRollup` is non-empty before believing an
  exit code, then watch.
- **A finding's REPRO is reproducible; its CHARACTERISATION is a separate claim.** #723 and #684 were filed
  as one family and are not: one is a name-keyed table, the other a file-set-scoped pre-pass. The shared-root
  hypothesis in the plan was wrong, and reading the code — not the issues — is what settled it.
- **Structural guards ENUMERATE a surface**: `public_api_drift_spec` (runtime AND the `sig/` coverage half),
  `scope_spec`, `project_pre_passes_spec`, `precision_snapshot_spec`, `scope_indexer_seed_bundle_spec`.
  Check by COMPUTING what they pin, not by grepping your identifiers.
- Read gate exit codes UNPIPED. Lint your own diff with `--force-exclusion`. File a follow-up issue BEFORE
  opening the PR that cites it. After a parallel batch, verify the INTEGRATED master.
