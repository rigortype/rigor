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

## Where the cycle stands

**v0.3.8 is published** (`Rigor::VERSION` is `0.3.8`, `[Unreleased]` empty as of 2026-09-09).
Post-cut fragments ride under `changelog.d/`, now including #830 (`changed/`) and, once it lands,
#844 (`added/`). The next cut happens only when the user invokes `/rigor-release-prep` explicitly.

## The ADR-109 range-notation line (2026-09-08 → 09)

The user asked whether integer ranges should use Ruby's own range notation so Float ranges could
follow the same rule. ADR-1 had already decided so; the carrier drifted to PHPStan's `int<min, max>`
and a docs sweep sided with the code. ADR-109 restores the decision and defines
`C[R] = { x | x.is_a?(C) && R.cover?(x) }`.

- [#830](https://github.com/rigortype/rigor/pull/830) — **merged 2026-09-09** on the user's word,
  master CI green. Slice 1: `Integer[1..10]` display + grammar, `int<a, b>` a deprecated input alias.
- [#844](https://github.com/rigortype/rigor/pull/844) — **open, Draft, do not merge without the
  user's word.** Slice 2: `Type::FloatRange`, `Float[0.0...1.0]` grammar, `non-nan-float` /
  `finite-float`, acceptance, RBS dispatch as `Float`, fixture `float_range_annotation/`. `make verify`
  / `make docs-check` / the sig provenance gate green locally on head `a5364d8f`; the `sig/rigor/type.rbs`
  residue pin moved 209 → 217 (reason in the commit body). Watch the HEAD run by id.
- [#831](https://github.com/rigortype/rigor/issues/831) — slice 3: truthy-edge Float comparison
  narrowing (`x > c` → `Float[c..]`, `x < c` → `Float[...c]`, falsy edge keeps the entry type),
  `nan?` / `finite?` narrowing, Float folds, and the `dynamic.rbs-extended.deprecated-form`
  diagnostic. Start from `Narrowing#narrow_integer_comparison` for the shape and from
  `RANGE_HEAD_BUILDERS["Float"]` in `lib/rigor/builtins/imported_refinements.rb` for the carrier.
- Engine gaps filed while probing, all `ready-for-agent`: [#833](https://github.com/rigortype/rigor/issues/833)
  (a Range literal argument matches the first `Range[T]` overload whatever its endpoints, so
  `rand(0.0...1.0)` types `Integer?`), [#834](https://github.com/rigortype/rigor/issues/834)
  (`n.clamp(1..9)` has no fold), [#842](https://github.com/rigortype/rigor/issues/842) (an
  `IntegerRange` receiver never reaches RBS dispatch, `ARGV.size.fdiv(2)` types `Dynamic[top]`;
  `FloatRange` ships with the arm IntegerRange lacks).

Two things the next session should not rediscover:

- The sig provenance gate (#835) pins per-file residue counts in `spec/rigor/sig_gen/provenance_spec.rb`.
  A new carrier's `sig/` block adds residue of the same shapes `IntegerRange` carries (hand-typed
  attr_readers, mixin-provided `top` / `bot` / `dynamic` / `accepts`, the `eql?` alias); mark
  `describe` with #837 like `Top#describe`, move the pin, and say why in the commit body.
- Union display order follows the spelling: `Integer[..4] | Integer[11..]` sorts the beginless
  half first. Regenerate a precision snapshot with `UPDATE_SNAPSHOTS=<name>`, never by hand.

## The types-and-comments line (2026-09-08 → 09, all landed)

Rule: **a type Rigor did not produce or check is never written down** — typeless YARD doc tags
(`@param name — description`) gated by `spec/docs/type_shaped_comments_spec.rb` over lib/, plugins/,
examples/, spec/, tool/; ADR-107 / ADR-108; the `rigor-type-oracle` skill; `make check --fail-on=warning`
(#822, #826, #827, #829). Follow-ups closed: #823 (an unannotated sibling is declared but inferred,
#840), #824 (`sig/` wins over an inline annotation, #832), #825 (the `sig/` provenance gate, #835).
Corrected on 2026-09-09: inline `#:` / `# @rbs` are **not** banned — checked type sources, written
where they say what the name and the code do not (`void`, `:asc | :desc` over `Symbol`); the nominal
class restated on every method is the noise to avoid (#843: ADR-107 amended, gate R2 withdrawn,
`static.value-use.void` enabled in the self-check). A declared `void` is authored intent: sig-gen no
longer proposes against it and the provenance gate counts it as earned (#845, closing #836). Open:
[#837](https://github.com/rigortype/rigor/issues/837), [#838](https://github.com/rigortype/rigor/issues/838)
(`ready-for-agent`), [#839](https://github.com/rigortype/rigor/issues/839),
[#841](https://github.com/rigortype/rigor/issues/841). `make steep-check` has 11 pre-existing problems.

## How to enter

1. `gh pr view 844` — if the user has said to land it and the head run is green, `gh pr ready 844`
   then `gh pr merge 844 --merge`; otherwise leave it Draft.
2. Next in the line is #831 slice 3, forked from post-merge master.
