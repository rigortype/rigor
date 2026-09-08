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
Post-cut fragments ride under `changelog.d/` (#830, #844, #846, #848, #854, #857, #858, #859 among
them). The next cut happens only when the user invokes `/rigor-release-prep`.

## The ADR-109 range-notation line (2026-09-08 → 09) — landed

ADR-109 restores ADR-1's decision: `C[R] = { x | x.is_a?(C) && R.cover?(x) }`, spelled with the
Ruby literal (`Integer[1..10]`, `Float[0.0...1.0]`); `int<a, b>` is a deprecated input alias that
reports `dynamic.rbs-extended.deprecated-form` (`info`). Every slice is on master, each merged on the
user's word with its master run green:

- [#830](https://github.com/rigortype/rigor/pull/830) (notation), [#844](https://github.com/rigortype/rigor/pull/844)
  (`Type::FloatRange`, `non-nan-float` / `finite-float`), [#846](https://github.com/rigortype/rigor/pull/846)
  (truthy-edge Float comparison narrowing, `nan?` / `finite?`), [#854](https://github.com/rigortype/rigor/pull/854)
  (the deprecation stream), [#857](https://github.com/rigortype/rigor/pull/857) (`rand(a..b)` /
  `Random.rand(a..b)` folds, monotone `Math`, `FloatRange` unary folds, `clamp(range)` on bounded
  receivers; closed #831). Bare `rand`, `rand(n)`, `rand(1.5)` are deliberately NOT folded: the corpus
  uses `rand(100)` as its "unknown Integer" oracle and folding it changed 27 pins' meaning.
- [#858](https://github.com/rigortype/rigor/pull/858) — merged 2026-09-09 (merge `8a3ee8c5`,
  master run 34268973064 green); closed #842. An `IntegerRange` receiver now reaches RBS dispatch
  (`ARGV.size.fdiv(2)` types `Float`, not `Dynamic[top]`).
- [#859](https://github.com/rigortype/rigor/pull/859) — merged 2026-09-09 (merge `4d9637cd`,
  master run 34269827528 green); closed #833 and #834. A Range literal argument is read through its
  endpoints (`Rigor::Inference::RangeConstant`): acceptance refutes `Range[T]` from them
  (`Random.new.rand(1.0..2.0)` types `Float`, not the first-declared Integer arm) and a method-level
  `Range[A]` binds `A` from the endpoint classes (`i.clamp(1..9)` on a plain `Integer` types
  `Integer`, not `Dynamic[top] | Integer`). Endless / beginless literals still satisfy core's
  `Range[Integer?]` slicing parameter. #858 and #859 both touched `rbs_dispatch.rb`,
  `inference-engine.md` and `type_construction_spec.rb`; #859 was rebased once after #858 landed.
- Filed from the probes that closed the line: [#861](https://github.com/rigortype/rigor/issues/861)
  (`ready-for-agent`: `clamp` on an UNBOUNDED `Integer` / `Float` receiver keeps no bracket —
  `i.clamp(1..9)` types `Integer` and `i.clamp(1, 9)` types `1 | 9 | Integer`, both should be
  `Integer[1..9]`; the fold lives in `ConstantFolding#try_fold_clamp_range` and fires only for
  `bounded_range?` receivers) and [#862](https://github.com/rigortype/rigor/issues/862)
  (`ready-for-human`: `Range[A]` binds only from a Range LITERAL; `i.clamp(r)` with `r` a
  `Range[Integer]` local is back to `Dynamic[top] | Integer` — admitting the carrier is the
  Range-only step of the container walk #303 declined, and needs a decision first).
- Two CI lessons that cost a cycle each: a CONFLICTING PR gets no `pull_request` run at all (rebase
  first, then look for the run by `head_sha`); if a Tests shard dies on an artifact-upload `403`,
  rerun the WHOLE run or push a fresh commit, never `--failed` alone (`shard-coverage` goes red).
- The sig provenance gate (#835) pins per-file residue counts in `spec/rigor/sig_gen/provenance_spec.rb`;
  a new hand-written declaration goes red — mark it (`# sig-gen gap: #NNN — why`; #160 for a shape
  sig-gen does not emit) or move the pin with the reason in the commit body. A literal return over a
  declared nominal no longer needs a marker since #850 ([ADR-110](adr/110-inherited-declaration-precedence.md)).

## The #610 reopen (2026-09-09) — landed

[#848](https://github.com/rigortype/rigor/pull/848) (merge `c63a77ac`) closed #610: `rigor-activerecord`'s
`Relation[Elem]` stand-down against `rbs collection install`'s non-generic `Relation` now runs on the
cached (default) build too, reported as `rbs.coverage.plugin-signature-stood-down` (`:info`). Credit
`Co-Authored-By: Nicolas Rodriguez <nico@nicoladmin.fr>` on every commit of a fix in that area.
Open: [#849](https://github.com/rigortype/rigor/issues/849) (`ready-for-agent`) — a structural gate
that the producer forwards every `build_env_for` keyword, plus a manual line that the probe commands
(`type-of`, `type-scan`, `trace`, `annotate`) build without the persistent cache.

Two things not to rediscover: the loader has TWO build entries (`Cache::RbsEnvironment.compute` AND
`RbsDescriptor`; a store-less spec cannot see the producer), and a relation assertion goes on a call
INTO the relation, never on the receiver (`dump_type(rel)` reads `ActiveRecord::Relation[Post]` in the
collided arm too).

## The types-and-comments line (2026-09-08 → 09) — landed

Rule: **a type Rigor did not produce or check is never written down** — typeless YARD doc tags
(`@param name — description`) gated by `spec/docs/type_shaped_comments_spec.rb`; ADR-107 / ADR-108;
the `rigor-type-oracle` skill; `make check --fail-on=warning`; inline `#:` / `# @rbs` are checked type
sources written where they say what the name and the code do not (#843). Every engine and gate
follow-up landed (#840, #832, #835, #845, #850, #847, #855, #852, #851); `sig/` carries no
`# sig-gen gap:` marker and `rigor sig-gen --diff --tighter-returns lib` is empty. Open:
[#853](https://github.com/rigortype/rigor/issues/853) (`ready-for-human`: a block-level `break <value>`
does not reach the call's type — the `break` sibling of #841).

## How to enter

1. Nothing of this session's is open: #858, #859 and this handoff are on master; #831, #833, #834,
   #842 are closed. The two `../rigor-wt/` lane worktrees were removed after their branches merged.
2. Next, in this order: [#849](https://github.com/rigortype/rigor/issues/849) (`ready-for-agent`),
   [#861](https://github.com/rigortype/rigor/issues/861) (`ready-for-agent`, fork from master — its
   fixture rows in `range_endpoint_acceptance.rb` pin the `Integer` answer the fold replaces),
   then the decisions [#862](https://github.com/rigortype/rigor/issues/862) and
   [#853](https://github.com/rigortype/rigor/issues/853) (`ready-for-human`, ask the user).
3. Full gates run one at a time on this machine: two parallel `make verify` runs exhaust memory.
