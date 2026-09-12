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

## Five Draft PRs from the 2026-09-12 inference-gap batch — DO NOT MERGE without the user's word

Every one is `make verify` green locally and reviewed; every one is deliberately **Draft**. The user
stopped the batch before landing, so Draft is the hold signal (`docs/notes/20260908-pr-788-draft-discipline-postmortem.md`).
Do not `gh pr ready`, do not merge, and do not build on them without being told to.

| PR | Closes | What it does |
| --- | --- | --- |
| [#999](https://github.com/rigortype/rigor/pull/999) | #991 | `call.wrong-arity` stops exempting a source-defined method that also carries a signature. Adds `%a{rigor:v1:inferred-signature}` (written only when EVERY type slot was defaulted) so a parameter-annotated method is a declaration while a bare `def` stays #992's territory. |
| [#1000](https://github.com/rigortype/rigor/pull/1000) | #995 | A declared `untyped` return is the absence of a statement, so sig-gen proposes the inferred return instead of vanishing. Root cause found downstream: `translate_method_type_return` passed no `alias_expander:`, so any `-> Type::t` degraded to `Dynamic[Top]`. |
| [#1001](https://github.com/rigortype/rigor/pull/1001) | #993 | `Integer#to_s` → `decimal-int-string`; `Float#to_s` → `non-empty-string`, and `numeric-string` only with a finiteness proof. `Float[0.0..]` is not one — it contains `+Infinity`. |
| [#1005](https://github.com/rigortype/rigor/pull/1005) | #997 | An unresolvable inline type name is reported as itself instead of as a duplicate declaration, and an unparseable `#:` line is no longer dropped in silence. |
| [#1006](https://github.com/rigortype/rigor/pull/1006) | #994 | Same-arity tuple/HashShape union arms absorb element-wise, by lifting the union's own absorption relation one level down — so `1 \| Integer`'s exclusion follows rather than being stipulated. |

PR [#990](https://github.com/rigortype/rigor/pull/990) (playground editor) belongs to another session. Hands off.

## Verify these with a COLD cache — #1009

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

[#992](https://github.com/rigortype/rigor/issues/992) (arity for a method with no declaration at all)
is blocked by #999 landing, and is where the `define_method` / `method_missing` / `prepend` / alias
false-positive envelope has to be built. Do not start it as a quick follow-on.

## Where the worktrees are

`rigor-wt/{arity-declared-source-methods,sig-gen-untyped-declared-return,numeric-to-s-refinements,inline-annotation-parse-diagnostics,tuple-union-absorption,adr-inline-refinement-dialect}`,
one per PR plus the ADR's. `adr-inline-refinement-dialect` also carries an installed `tool/steep/`
bundle (ignored) if another Steep measurement is wanted — a CoW-copied bundle needs `bundle pristine`
before it runs, because its native extensions were built against a different Ruby store path.
