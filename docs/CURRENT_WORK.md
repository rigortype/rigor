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

**v0.3.8 is published** (tag `v0.3.8`, RubyGems, GitHub Release; `Rigor::VERSION` is `0.3.8` and
`[Unreleased]` is empty as of 2026-09-08). Post-cut fragments ride under `changelog.d/`. The next cut
happens only when the user invokes `/rigor-release-prep` explicitly — a release date or goal mentioned
in a task is not that invocation (ADR-50 § WD5).

## The 2026-09-08 range-notation session (PR open, Draft)

The user asked whether Rigor's integer range type should use Ruby's own range notation so a Float
range could follow the same rule. It should, and ADR-1 had already said so on 2026-04-27: the
carrier shipped PHPStan's `int<min, max>` five days later against it, and a 2026-06-21
docs-contradiction sweep rewrote the spec to match the code. The old spelling also did not round-trip
(`int<0, max>` displayed, unparseable as input) and could not extend to Float (`min` reads as
`Float::MIN`).

- [#830](https://github.com/rigortype/rigor/pull/830) — **open, Draft, do not merge without the
  user's word.** ADR-109 + slice 1: `Integer[1..10]` / `Integer[0..]` / `Integer[..-1]` display and
  grammar (`TypeNode::RangeLiteral`), universal range displays `Integer`, `int<a, b>` kept as a
  deprecated input alias, spec corpus + handbook + manual swept, nine precision snapshots
  regenerated, grounding note `docs/notes/20260908-ruby-range-notation-and-float-intervals.md`.
  `make verify` and `make docs-check` were green locally on the head commit (`62f65600`); watch the
  HEAD commit's run by id, not `gh pr checks --watch`.
- [#831](https://github.com/rigortype/rigor/issues/831) — the rest of ADR-109: the `Float[R]`
  carrier with `non-nan-float` = `Float[-Float::INFINITY..]` and `finite-float` =
  `Float[-Float::MAX..Float::MAX]` (slice 2), truthy-edge Float comparison narrowing and folds
  (slice 3), and the `dynamic.rbs-extended.deprecated-form` diagnostic for the old alias. The
  design is in ADR-109 WD3–WD5; the spec carries *Reserved (as of this writing)* markers.
- **Another session's lane, hands off:** the crash on a reversed `int<10, 1>` annotation (internal
  analyzer error, `rigor check` still exits 0) was spun off from this session and is being fixed
  elsewhere; it edits `PARAMETERISED_INT_BUILDERS["int"]` in `imported_refinements.rb`, which #830
  does not touch.

Two things the next session should not rediscover:

- Union display order changed with the spelling: `Integer[..4] | Integer[11..]` now sorts the
  left half first (`[.` precedes `[1`). Regenerate a precision snapshot with `UPDATE_SNAPSHOTS=<name>`
  rather than editing the YAML by hand.
- Two engine gaps noticed while probing are filed, both `ready-for-agent`:
  [#833](https://github.com/rigortype/rigor/issues/833) (a Range literal argument matches the first
  `Range[T]` overload whatever its endpoints, so `rand(0.0...1.0)` types `Integer?`) and
  [#834](https://github.com/rigortype/rigor/issues/834) (`n.clamp(1..9)` types `Dynamic[top]` while
  `n.clamp(1, 9)` folds to `Integer[1..9]`).

## The 2026-09-08 types-and-comments session (landed, two waves)

Rule: **a type Rigor did not produce or check is never written down.** Wave one — [#822](https://github.com/rigortype/rigor/pull/822)
(1,121 YARD type slots emptied, doc tags `@param name — description`, `AGENTS.md` § "Types and
Comments", gate `spec/docs/type_shaped_comments_spec.rb` R1–R5, ADR-107), [#826](https://github.com/rigortype/rigor/pull/826)
(`skills/rigor-type-oracle/`, the `AGENTS.md` fragment `rigor-project-init` installs, ADR-108),
[#827](https://github.com/rigortype/rigor/pull/827) (`rigor check --fail-on=SEVERITY`; the self-check runs with
`--fail-on=warning`). Wave two — [#829](https://github.com/rigortype/rigor/pull/829) (the dialect and the gate
cover `spec/` and `tool/`), [#832](https://github.com/rigortype/rigor/pull/832) (`sig/` wins over an inline
annotation of the same member, one `:info` per collision; ADR-32 WD13), [#840](https://github.com/rigortype/rigor/pull/840)
(an unannotated sibling in an annotated file is declared but typed by inference, via
`%a{rigor:v1:inferred-return}`; ADR-93 WD6), [#835](https://github.com/rigortype/rigor/pull/835) (the `sig/`
provenance gate `spec/rigor/sig_gen/provenance_spec.rb`: residue pin 671 + `tighter_return` must carry a
`# sig-gen gap: #NNN` marker; nine stale declarations deleted). Master CI green after every merge.

Open, from the audits: [#836](https://github.com/rigortype/rigor/issues/836) (sig-gen tightens a `void`),
[#837](https://github.com/rigortype/rigor/issues/837) (literal onto a polymorphic contract),
[#838](https://github.com/rigortype/rigor/issues/838) (apply three genuine tightenings — `ready-for-agent`),
[#839](https://github.com/rigortype/rigor/issues/839) (`sig/` declarations with no method),
[#841](https://github.com/rigortype/rigor/issues/841) (`all?` block join drops `next` arms; a false positive).
Known and untouched: `make steep-check` reports 11 pre-existing problems in three `lib/` files with no `sig/`.

## How to enter

1. `gh pr view 830` — if the user has said to land it and the head run is green, `gh pr ready 830`
   then `gh pr merge 830 --merge`; otherwise leave it Draft.
2. Slice 2 of ADR-109 starts from `RANGE_HEAD_BUILDERS` in `lib/rigor/builtins/imported_refinements.rb`
   and the reserved paragraph in `docs/type-specification/imported-built-in-types.md`; read the
   grounding note's § 4 first, every Float fact there is already verified.
