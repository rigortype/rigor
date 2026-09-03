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

**Eighteen PRs from this review cycle landed 2026-09-03.** The last three were #714 (#698 snapshot goldens), #715 (#707 seed-bundle
def nesting) and #725 (#696 + #686). The review rounds produced **49 new issues**, all with reproduced repros.

**"Reports LESS while exiting 0" is CLOSED as an arc.** #676/#688/#694 took the three spec-side entry
points (1,177 of 1,925 examples had been passing with every check rule crashing); #725 took the last two
inside `lib/`, behind one `Analysis::CrashSignature` predicate rather than a fourth string match. An
`RBS::DuplicatedMethodDefinitionError` is now a diagnostic (`rbs.coverage.definition-build-failed`,
`:warning`, promoted by `reject-unparseable-signatures`) instead of 2,709 stderr lines on a green run, and a
crashed mutation measurement no longer scores 100% or passes `--threshold`. What remains of the family is
[#704](https://github.com/rigortype/rigor/issues/704) (a plugins-route spec passing with an empty registry)
and [#713](https://github.com/rigortype/rigor/issues/713).

**Constant resolution: the arc is closed, one branch is open with two blockers.** #685/#692/#706/#709/#711
closed the peel. [#721](https://github.com/rigortype/rigor/pull/721) is #708 + #682, **Draft, DO NOT MERGE**:
review found three false positives on correct Ruby where master has none (`lexical_nesting_for_prefix` derives
the chain from a prefix that a rooted header can now reset, so the census walk and the declaration walk
disagree about the same body), and a union rule that imports a rooted reopening site's namespace into every
ancestor lookup. **The work in it is verified and worth finishing** — 13 of its 18 ancestor moves are
self-inheritance repairs, shapes MRI rejects with `TypeError: superclass mismatch`, i.e. master was answering
with classes that cannot exist. Residues: [#722](https://github.com/rigortype/rigor/issues/722) (four),
[#716](https://github.com/rigortype/rigor/issues/716), plus older #655/#656/#662.

## Backlog, ranked

1. **[#721](https://github.com/rigortype/rigor/pull/721)'s two blockers** — thread the chain to the three
   `lexical_nesting_for_prefix` callers rather than deriving it, and make the ancestor nesting per-site
   instead of a per-class union. Both are stated with repros in the PR body.
2. **[#723](https://github.com/rigortype/rigor/issues/723)** — a live FP on working code: a class declared in
   `sig/` without its project superclass draws `call.undefined-method` that `dump_type` contradicts on the
   same line. Two workers had to shape fixtures around it.
3. **[#720](https://github.com/rigortype/rigor/issues/720)** — `sig-gen` declines a method whose value comes
   from a `yield`ing helper; the gap is yield-through, not the `rescue` (an inlined variant with a `rescue`
   *is* emitted). It is why #725 carries one authorised hand-written RBS line, to be replaced once this lands.
4. **[#713](https://github.com/rigortype/rigor/issues/713)** — the precision-snapshot gate captures top-level
   locals only, so 49 of 117 goldens pin nothing and a real precision change passes green.
5. **[#700](https://github.com/rigortype/rigor/issues/700)** (human) and
   **[#660](https://github.com/rigortype/rigor/issues/660)** (human) — the ADR questions blocking #697/#701.
6. **[#574](https://github.com/rigortype/rigor/issues/574)** (human) — still the sole blocker on the corpus's
   biggest pair (`Parameters#[]`, 581 redmine + 496 mastodon).
7. Rails/AR: [#659](https://github.com/rigortype/rigor/issues/659) (unblocked),
   [#670](https://github.com/rigortype/rigor/issues/670), [#673](https://github.com/rigortype/rigor/issues/673),
   [#678](https://github.com/rigortype/rigor/issues/678), [#679](https://github.com/rigortype/rigor/issues/679),
   [#671](https://github.com/rigortype/rigor/issues/671). Noise: [#718](https://github.com/rigortype/rigor/issues/718),
   [#717](https://github.com/rigortype/rigor/issues/717), [#724](https://github.com/rigortype/rigor/issues/724).

## Measurement — read before writing a gate or trusting a number

- **"The gate is green" and "the gate can execute that path" are different claims.** #696 hit this three
  times, twice at blocker severity: the integration `run` helper defaults `cache_store: nil` and `prewarm`
  returns early without a store, so the one configuration the defect lived in was structurally unexecutable.
  The third was subtler — a one-receiver fixture could only assert two arms *agree*, so "both arms
  under-report" would have passed. **Assert the value, not the agreement.**
- **A collapsed class, a crashed run, an empty plugin registry and an empty capture all produce zero
  diagnostics.** Gate on a declared return RESOLVING, or on the expected diagnostic being PRESENT.
- **"Byte-identical diagnostics" is usually inert, not probative** — most of all where the fix *repairs*
  sites that currently emit nothing. The pattern that works is a movable-site Prism probe: count the sites
  that CAN move, adjudicate each. This cycle's is preserved at
  `~/repo/ruby/rigor-probe-20260903/movable_probe.rb`; it models both header naming rules and both candidate
  orders. `lib/` and `plugins/` contain **zero** compact and zero rooted declarations, so a green self-check
  proves nothing about that family.
- **Measure the obvious fix before keeping it.** Collapsing #725's hierarchy cache-state branch to one
  per-class demand was 50× slower on the warm path (0.0035s → 0.18s over 200 orderings).
- A compatibility claim about a **persisted** format needs both directions run. #725's "no schema bump
  needed" was wrong one way — a pre-change blob loaded and then persistently said less, under a store that
  never evicts (ADR-6). Cache size cost quoted from a one-file project was +12.3%; the realistic figure on
  349 files is +6.6%.

## Pipeline notes (each earned by an incident)

- **A finding's REPRO is reproducible; its CHARACTERISATION is a separate claim.** Also true of an
  instruction: this cycle's brief told #682's implementer to read the recorded nesting off the reader's
  scope, and he refused with the right reason — `class_graph_buckets` is memoised by index identity then
  class name, so a reader-scoped answer would be served to every scope sharing the trio. **The header cref
  is a property of the declaration.** An independent reviewer confirmed the instruction was wrong.
- **Grepping your changed identifiers is necessary but NOT sufficient.** Structural guards ENUMERATE a
  surface: `public_api_drift_spec`, `scope_spec`'s field coverage, `project_pre_passes_spec`'s Discovery
  slots, `precision_snapshot_spec`'s goldens, and `scope_indexer_seed_bundle_spec`'s `plain_tables` — which
  is itself incomplete by three tables (#724). Check by COMPUTING what they pin.
- **Check a normative `MUST` against the code it ships with.** Every branch this cycle that shipped spec
  text broader than its implementation was caught by a reviewer reading the two against each other, none by
  a gate — including #696's own sentence about whole-universe walks, twice.
- Read gate exit codes UNPIPED, and do not append `; tail` either — that masks them the same way. Lint your
  own diff with `--force-exclusion`. File a follow-up issue BEFORE opening the PR that cites it.
- After a parallel batch, verify the INTEGRATED master: #725 and another session's #719 landed minutes apart
  and no PR's CI saw the combination (checked clean — 1,448 examples, `make check-plugins` exit 0).
