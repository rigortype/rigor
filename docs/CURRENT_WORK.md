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

## Verify diagnostic changes with a COLD cache — #1009

A warm `.rigor/cache` written by another build can mix a stale plugin-synthesized RBS with new rule
code and report neither build's answer. Reproduced deterministically on #999: populate at the parent
commit (2 diagnostics), switch to the child, run warm → 4, while `--no-cache` and a cache-cleaned warm
run both give 2. A `lib/`-only change (#1006) does not show it, so the hole is in the plugin-synthesis
lane. Until [#1009](https://github.com/rigortype/rigor/issues/1009) is fixed, judge any
diagnostic-affecting change with `rigor check --no-cache` or after `rm -rf .rigor/cache` — a warm run
is not a valid instrument for "does this fire?".

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

## Issues this batch filed, and what is worth picking up first

Fourteen, all from measured behaviour rather than reading: #991-#998, #1002, #1003, #1004, #1007,
#1008, #1009.

Three are worth reading before choosing anything else:

- [#1009](https://github.com/rigortype/rigor/issues/1009) — the cache hole above. It makes every other
  diagnostic verification less trustworthy, so it buys more than its own fix.
- [#1004](https://github.com/rigortype/rigor/issues/1004) — `Integer#to_s(16)` and a bare-hex-digit
  regex both claim `hex-int-string`, whose predicate requires the `0x` prefix. A refinement that is
  false of its inhabitants is worse than the `String` it replaces.
- [#1003](https://github.com/rigortype/rigor/issues/1003) — a predicate guard narrows in `if`/`else`
  and not in the ternary spelling of the same guard. Structural: every guard-dependent refinement is
  reachable in one spelling only.

[#992](https://github.com/rigortype/rigor/issues/992) LANDED as PR [#1010](https://github.com/rigortype/rigor/pull/1010)
on 2026-09-14, default on: `call.wrong-arity` now checks positional arity against a `def` nobody
declared, reading one per-class parameter-envelope table that joins disagreeing shapes to opaque.
Zero new firings across 34 survey targets — ~8,400 call sites reached an envelope and the only 4
outliers became declines (two were real bugs that depend on load order). A literal `Base.new.x` with
the wrong arity stays silent because the subclass-override decline applies to `Nominal[Base]`; that is
a deliberate false negative. Keyword arguments are out of scope. Remaining risk it names: an
`--incremental` run misses a newly added subclass override until a full run.

## Where the worktrees are

`rigor-wt/{arity-declared-source-methods,sig-gen-untyped-declared-return,numeric-to-s-refinements,inline-annotation-parse-diagnostics,tuple-union-absorption,arity-undeclared-source-methods,adr-inline-refinement-dialect}`,
one per PR (all six merged; safe to remove) plus the ADR's. `adr-inline-refinement-dialect` also carries an installed `tool/steep/`
bundle (ignored) if another Steep measurement is wanted — a CoW-copied bundle needs `bundle pristine`
before it runs, because its native extensions were built against a different Ruby store path.
