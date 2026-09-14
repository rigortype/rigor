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

## v0.3.9 is fully released — the previous handoff's "mid-publish" section is done

Verified, not assumed: `gem list -r rigortype` answers `0.3.9`, `git ls-remote --tags origin v0.3.9`
resolves, and `gh release view v0.3.9` exists with the `[0.3.9] - 2026-09-12` body. Nothing about the
release is outstanding. `changelog.d/` is collecting the next cycle's fragments again.

## The 2026-09-12 inference-gap batch LANDED on 2026-09-14

All five PRs merged at the user's word: #999, #1005, #1000, #1001, then #1006; master CI green at
`4d6ac321`, closing #991, #993, #994, #995 and #997. The playground snippet that started it —
`# @rbs num: Float` then `p Foo.new.f` — now reports `call.wrong-arity`.

Per-PR CI could not see the batch's interactions; a local five-way merge could. #1001's
`Float#to_s` → `non-empty-string` sharpened #1006's tuple fixture, and #995's alias expansion plus
#994's absorption made `StatementEvaluator#eval_branch_or_nil` / `#eval_class_body` generated-equivalent,
dropping the `sig/rigor/inference.rbs` residue pin 88 → 86. Both were fixed on #1006 before it merged,
and the four-way tree was verified identical to what master became.

PR [#990](https://github.com/rigortype/rigor/pull/990) (playground editor) belongs to another session. Hands off.

## Second wave landed 2026-09-14: #1009, #1004, #1003

- [#1012](https://github.com/rigortype/rigor/pull/1012) closes #1009. The stale slot was
  `plugin.source_rbs_synthesizer`, keyed on source digest + plugin manifest only, so a checkout that
  edited the rbs-inline synthesizer kept serving the previous build's RBS; plugin-producer keys had the
  same gap. Both now carry `Cache::EngineSource.key_config_entries`. Diagnose this class with
  `rigor check --cache-stats`. **Still unverified:** the `rbs.*` translated-value producers keyed by
  `RbsDescriptor` ([#1014](https://github.com/rigortype/rigor/issues/1014)) — until it closes, judge
  "does this fire?" cold.
- [#1013](https://github.com/rigortype/rigor/pull/1013) closes #1004: `to_s(8)` / `to_s(16)` and the
  bare hex/octal digit-class regex rows now yield `non-empty-string`, not a prefix-requiring refinement
  their values fail.
- [#1015](https://github.com/rigortype/rigor/pull/1015) closes #1003. The gap was statement vs value
  position, not ternary vs `if`: `ExpressionTyper#type_of_if` was a second typer and is deleted; a
  value-position conditional now goes through `scope.evaluate`. Corpus flat on 21 targets; `rigor check
  lib` wall time unchanged within noise.

## ADR-111 is Proposed and waits on the maintainer

[`docs/adr/111-inline-refinement-carrier.md`](adr/111-inline-refinement-carrier.md), grounded in
[`docs/notes/20260912-inline-refinement-carrier-probe.md`](notes/20260912-inline-refinement-carrier-probe.md)
— fourteen spellings measured through three readers (the `rbs-inline` gem, rbs 4.2.0's
`RBS::InlineParser`, Steep 2.0.0 with `check "lib", inline: true`).

It recommends **reaffirming** that Rigor has no comment dialect of its own, on a boundedness rather
than invisibility criterion. Two measurements decided the spelling: Steep reports the own-line
`%a{rigor:v1:…}` form — the form `docs/manual/16-rbs-extended-annotations.md` documents — as a
user-visible error (`%a{pure}` too), while the same-line form is clean and genuinely bound; and
`# @rbs-ext` is measured out as a name (`@rbs\b` matches before the hyphen) where `# @extrbs` is clean
in all three readers. So the same-line form is the only spelling the ADR recommends, and
[#998](https://github.com/rigortype/rigor/issues/998) — Rigor's own reader silently dropping it — is
the prerequisite for the manual recommending anything, not a follow-up. Re-evaluation trigger (i) is
half-fired. The maintainer decides; nothing is implemented.

## Open follow-ups, and what is worth picking up next

Open from these two waves: #996 (ADR-111, the maintainer's ruling), #998, #1002, #1007, #1008, #1011,
#1014, #1016, #1017.

- [#998](https://github.com/rigortype/rigor/issues/998) — Rigor's inline reader silently drops the
  same-line `%a{}` forms rbs's built-in reader and Steep accept. ADR-111 makes it the prerequisite for
  the manual recommending any inline refinement spelling.
- [#1016](https://github.com/rigortype/rigor/issues/1016) — a bare `&&` / `||` as a value still has the
  two-typer shape #1015 removed for conditionals (`x.finite? && x` is `Float | false` as a value). Mind
  the #313 short-circuit gate that only the value path carries.
- [#1014](https://github.com/rigortype/rigor/issues/1014) — reproduce-first check of the `rbs.*` cache
  producers; closing it retires the "judge cold" caveat above.

[#992](https://github.com/rigortype/rigor/issues/992) LANDED as PR [#1010](https://github.com/rigortype/rigor/pull/1010)
on 2026-09-14, default on: `call.wrong-arity` now checks positional arity against a `def` nobody
declared, reading one per-class parameter-envelope table that joins disagreeing shapes to opaque.
Zero new firings across 34 survey targets — ~8,400 call sites reached an envelope and the only 4
outliers became declines (two were real bugs that depend on load order). A literal `Base.new.x` with
the wrong arity stays silent because the subclass-override decline applies to `Nominal[Base]`; that is
a deliberate false negative. Keyword arguments are out of scope. Remaining risk it names: an
`--incremental` run misses a newly added subclass override until a full run.

## Where the worktrees are

`rigor-wt/{arity-declared-source-methods,sig-gen-untyped-declared-return,numeric-to-s-refinements,inline-annotation-parse-diagnostics,tuple-union-absorption,arity-undeclared-source-methods,cross-build-synthesis-cache,hex-octal-int-string-soundness,ternary-predicate-narrowing,adr-inline-refinement-dialect}`,
one per PR (all nine merged; safe to remove) plus the ADR's. `adr-inline-refinement-dialect` also carries an installed `tool/steep/`
bundle (ignored) if another Steep measurement is wanted — a CoW-copied bundle needs `bundle pristine`
before it runs, because its native extensions were built against a different Ruby store path.
