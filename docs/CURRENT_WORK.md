<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward — and verify it by the thing that decides, not by a
  proxy. This session shipped a "make verify green" claim read out of a grep for "offenses" that
  could not see "1 offense detected". CI saw it. Read exit codes.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Where things stand

- **v0.3.1 is released** (2026-07-29). No version bump is due — releases wait for an explicit ask.
- **Merged this cycle**, all with a corpus FP diff (eight RBS-shipping survey projects,
  diagnostic-identical unless stated):
  - [#238](https://github.com/rigortype/rigor/pull/238) / #237 — referenced-type stubs are emitted in
    the declaration kind each name needs, validated one at a time, and the fixpoint stops on a pass
    that appends nothing. herb went from a **complete no-op** to 5 → 2 passes, −30.1% allocations,
    precise coverage 59.3% → 60.0%. Cache `SCHEMA_VERSION` 5 → 6.
  - [#240](https://github.com/rigortype/rigor/pull/240) / #207 — dangling-reference detection reads
    the declarations instead of building every project class: pass 1 **7,841,785 → ~25k allocations**,
    −32.7% of a cold `check lib`. The builder sweep survives in spec as its oracle.
  - [#242](https://github.com/rigortype/rigor/pull/242) — perf baseline refreshed to the post-#207
    Linux CI measurement (15,769,515 allocations); the ceiling is 16.56M again instead of 24.70M.
  - [#243](https://github.com/rigortype/rigor/pull/243) / #239 — an instance method no longer masks a
    same-named `class << self` method, so `self.class.helper(1)` stops drawing a false
    `call.undefined-method`. Removed one real diagnostic from the corpus (`haml`'s
    `ScriptCompiler.find_and_preserve`) and added none.
  - [#244](https://github.com/rigortype/rigor/pull/244) / #146 — editor mode gains whole-project scope:
    `--tmp-file` / `--instead-of` **with `--incremental`** substitutes the buffer into an ADR-46
    recheck, so an unsaved edit surfaces in its dependents. Never writes the snapshot; falls back to
    single-file scope when there is none. `--verify-incremental` now refuses a buffer.
  - [#241](https://github.com/rigortype/rigor/pull/241) — the changelogs conform to Keep a Changelog
    1.1.0 (six section types, one per type per release, canonical order), gated by
    `spec/docs/changelog_conformance_spec.rb`. **There is no `Performance` section**: a speed-up is
    `Changed`, a docs fix is `Fixed`.
  - [#245](https://github.com/rigortype/rigor/pull/245) / #121 — the Tuple carrier's set operations
    fold (`&` `|` `-` `intersection` `union` `difference` `intersect?`, plus `at` / `one?` /
    `deconstruct`), each by running Ruby's own operator so `eql?` membership decides.
- `make verify` and `make docs-check` green on merged master (checked by exit code).

## Next session

- **The v0.4.x editor cluster is now a considered "not yet", not a queue item.** Phase attribution of
  one editor-mode invocation on mastodon `app/models` (248 files, warm) says the remaining levers are
  small: per-file analysis 0.60s, project pre-pass + plugin prepare **~0.24s**, RBS env 0.19s,
  snapshot load and closure decision ~0.01s each, of ~2.5s wall. Recorded on
  [#147](https://github.com/rigortype/rigor/issues/147#issuecomment-5132746607), which also notes that
  option B subsumes its `--also` bullet. Do not start #147's five-phase pathway on its stated estimate.
  [#142](https://github.com/rigortype/rigor/issues/142) needs a persistent pre-warmed worker pool and
  pays off only for multi-dirty-buffer bursts.
- **The LSP is the lever that measurement points at** — it has no process boot at all — and it still
  publishes **single-file** scope (`DiagnosticPublisher#run_analysis` → `runner.run([path])`). Giving
  it the option-B treatment (publish the dependents' diagnostics too, from an in-process
  `IncrementalSession` that needs no snapshot) is unfiled and would be the natural continuation of
  #146. It needs a design call first: publishing diagnostics for files the client never opened is
  legitimate LSP but needs a clear-on-empty story.
- **#121** stays open as the ongoing fold backlog, but its surface is thin: an empirical sweep across
  String / Array / Hash / Integer / Float / Symbol found the set operations as the only genuine gaps,
  and they are now landed. Re-sweep with the probe before assuming the audit doc's 🔲.
- **[#134](https://github.com/rigortype/rigor/issues/134) / [#135](https://github.com/rigortype/rigor/issues/135)**
  (self-testing) and **[#137](https://github.com/rigortype/rigor/issues/137)** (dry-rb ceiling slices)
  are the untouched `ready-for-agent` remainder.
- **Unfiled upstream report** (small, external): `rbs-inline`'s parser accepts
  `# @rbs module-self: Foo` and its writer then discards it — the defect behind ADR-32 WD12. Needs
  maintainer sign-off because it is an external filing.

## What this session learned that is not in a commit

- **A clean corpus result can be a silent harness failure.** Six of eight targets reported "both
  detectors found nothing"; the fixture built to force a positive is what produced the shape matrix and
  both #237 defects. Build the positive control before the corpus run.
- **Verify by the deciding signal, not a proxy for it.** `grep offenses` cannot see `1 offense
  detected`. Read the exit code.
- **`rescue <Error>; nil` around a batched synthesis is an availability bug** — the rescue degrades all
  N units for one bad input. Split the batch.
- **A fixpoint that cannot make progress still burns its whole budget.** Bound by progress; keep the
  cap as a backstop.
- **Read the raise sites, don't infer them.** The static walk in #207 is only equivalent because
  `references/rbs` says exactly where `NoTypeFoundError` comes from; three of the four resulting
  exclusions were invisible from outside.
- **A written rule with no gate is a temporary state** — the Keep a Changelog vocabulary was already in
  the release-prep skill and six `### Performance` sections accumulated anyway.
- **A buffer changes what "changed" means.** #146's real bug was computing the invalidation closure
  from disk bytes while analysing buffer bytes: the dependents of an unsaved edit were served from
  cache. Any substituted-input mode must thread the substitution through change detection, not only
  through the analysis.
