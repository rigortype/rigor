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
Post-cut fragments ride under `changelog.d/`: #830 and #844 landed (`changed/`, `added/`); #848
adds `fixed/` once it lands. The next cut happens only when the user invokes `/rigor-release-prep`.

## The #610 reopen (2026-09-09) — PR #848, Draft, awaiting the user's word

`rigor-activerecord`'s `Relation[Elem]` against `rbs collection install`'s non-generic `Relation`.
#770 (0.3.8) added the stand-down but threaded `deferred_signature_paths:` through the loader's own
`build_env` only; `Cache::RbsEnvironment.compute` — the build every cached run takes, which is the
CLI default — never passed it, so the stand-down ran under `--no-cache` and on no real run. The
gate stayed green because its loader held no store (#696's lesson in its other shape).

- [#848](https://github.com/rigortype/rigor/pull/848) — **open, Draft, do not `gh pr ready` or
  merge without the user's word.** CI green on head `0a0ba3e1`, rbs 3.x/4.x jobs included. Fixes:
  the producer forwards the deferred list (new public reader, `sig-gen gap` marker #160); the env
  key gains an env-only `rbs.deferred_signature_paths` slot (NOT in the shared run-key entries —
  the boot-slim probe cannot rebuild a plugin-derived slot); a stood-down file is no longer reported
  as `rbs.coverage.quarantined-signature` and is reported as
  `rbs.coverage.plugin-signature-stood-down` (`:info`, one per file, both sides named, on cold and
  warm runs; gated on the plugin registry contributing signatures, never on `signature_paths:`);
  the arity read takes the entry's FIRST declaration, since `type_params` validates and raises on
  both rbs lines. Credit: `Co-Authored-By: Nicolas Rodriguez <nico@nicoladmin.fr>` on every commit.
- [#849](https://github.com/rigortype/rigor/issues/849) — `ready-for-agent`: a structural gate that
  the producer forwards every `build_env_for` keyword, plus a manual line that the probe commands
  (`type-of`, `type-scan`, `trace`, `annotate`) build without the persistent cache. Fork it from
  post-merge master; on 0.3.8 `check` (cached) and `type-of` (store-less) typed one position from two
  environments, which `ProbeEnvironment`'s own contract forbids.

Two things the next session should not rediscover:

- The loader has TWO build entries. A new `build_env_for` input must go through
  `Cache::RbsEnvironment.compute` AND `RbsDescriptor` (the suite's `RbsEnvMemo.digest` is the
  precedent), and its gate must build through a real cold `Cache::Store` plus a second loader for
  the HIT — a store-less spec cannot see the producer.
- Assert on a call INTO a relation, never on the receiver: `dump_type(rel)` reads
  `ActiveRecord::Relation[Post]` in the collided arm too (the plugin's type-node resolver produces
  it whether or not the class's definition builds).

## The ADR-109 range-notation line (2026-09-08 → 09)

ADR-109 restores ADR-1's decision: `C[R] = { x | x.is_a?(C) && R.cover?(x) }`, spelled with the
Ruby literal (`Integer[1..10]`, `Float[0.0...1.0]`); `int<a, b>` is a deprecated input alias.

- [#830](https://github.com/rigortype/rigor/pull/830) (slice 1) and
  [#844](https://github.com/rigortype/rigor/pull/844) (slice 2, `Type::FloatRange`) — **merged**.
- [#846](https://github.com/rigortype/rigor/pull/846) — slice 3 (truthy-edge Float comparison
  narrowing, [#831](https://github.com/rigortype/rigor/issues/831)): **open, Draft, not this
  session's PR — hands off unless its session hands the lane over.**
- Engine gaps filed while probing, all `ready-for-agent`: [#833](https://github.com/rigortype/rigor/issues/833)
  (a Range literal argument matches the first `Range[T]` overload whatever its endpoints),
  [#834](https://github.com/rigortype/rigor/issues/834) (`n.clamp(1..9)` has no fold),
  [#842](https://github.com/rigortype/rigor/issues/842) (an `IntegerRange` receiver never reaches RBS
  dispatch; `FloatRange` ships with the arm IntegerRange lacks).
- The sig provenance gate (#835) pins per-file residue counts in `spec/rigor/sig_gen/provenance_spec.rb`;
  a new hand-written declaration goes red — mark it (`# sig-gen gap: #NNN — why`, #837 for a literal
  return, #160 for a shape sig-gen does not emit) or move the pin with the reason in the commit body.

## The types-and-comments line (2026-09-08 → 09, landed)

**A type Rigor did not produce or check is never written down** — typeless YARD doc tags gated by
`spec/docs/type_shaped_comments_spec.rb`; ADR-107 / ADR-108; the `rigor-type-oracle` skill;
`make check --fail-on=warning`. Inline `#:` / `# @rbs` are checked type sources, not banned (#843);
a declared `void` is authored intent (#845). Open, all `ready-for-human`:
[#837](https://github.com/rigortype/rigor/issues/837), [#839](https://github.com/rigortype/rigor/issues/839),
[#841](https://github.com/rigortype/rigor/issues/841). `make steep-check` has 11 pre-existing problems.

## How to enter

1. `gh pr view 848` — if the user has said to land it and the head run is green, `gh pr ready 848`
   then `gh pr merge 848 --merge`, and watch the master merge run; otherwise leave it Draft.
2. #849 next in this line, forked from post-merge master. #846 belongs to another session.
