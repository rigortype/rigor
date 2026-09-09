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

**v0.3.8 is published** (`Rigor::VERSION` is `0.3.8`, `[Unreleased]` empty). The cycle under
`changelog.d/` is now large — 2026-09-09 alone added roughly thirty PRs across four batches. The next
cut happens only when the user invokes `/rigor-release-prep`.

**Two sessions ran on 2026-09-09** and both finished; neither has an open PR.

## 2026-09-09 batch 4 — six lanes, all landed

- [#916](https://github.com/rigortype/rigor/pull/916) closed #673. `ActiveSupport::TimeWithZone` is a
  declared `::Time` SUBCLASS, which buys its readers without the union #632 measured as collapsing
  every downstream chain. Argument checking now admits keyword-bearing signatures, but only a
  CLASS-refuted argument fires there — unrestricted it produced two new verdicts on correct code
  across six projects. By-product true positive: `rigor-sorbet`'s `translate_shape` handed an Array
  to `hash_shape_of`, so every `sig { returns({…}) }` degraded to `Dynamic[top]` through the plugin's
  rescue, contradicting its documented never-fails contract.
- [#914](https://github.com/rigortype/rigor/pull/914) closed #661's three gaps. The overlay parity
  guard now names the drifted selector instead of raising `NameError` from its failure lambda (a
  lambda body only runs on failure, which is why a green suite never caught it); widening it to
  compare SIGNATURES was declined, because the overlay is legitimately the more conservative copy.
  `a <=> b` on an inherited `Kernel#<=>` reads `Integer?` rather than the identity comparison's `0?`,
  which had been narrowing `n.negative? if n` to a `bot` branch.
- [#912](https://github.com/rigortype/rigor/pull/912) closed #668 and #663. A dynamic constant target
  is filed under a `*::LIMIT` wildcard key, not the bare last segment — the one name such a write can
  never reach. `IncrementalSnapshot::SCHEMA` 18 → 19, because a pre-19 blob's bare key deserialises
  cleanly and would serve the pre-fix answer warm. For #663 the rule is "any writer outside the
  listed set", not the issue's literal `sources.size > 1`.
- [#910](https://github.com/rigortype/rigor/pull/910) closed #898 — `extend` survives to `Scope`
  (recorded since #526, thrown away inside the indexer). Per module the question is `M <= target`:
  `:equal` / `:subclass` / `:unknown` withhold the `Bot`, `:superclass` and `:disjoint` keep it. The
  first cut used "not `:disjoint`" and silently retracted `case Widget when Integer` — now pinned.
- [#907](https://github.com/rigortype/rigor/pull/907) — the #693 SIZING, and its conclusion was
  **not worth doing**. See below.
- Batch 3 (#899, #901, #902, #903, #904, #905), batch 2 (#892–#897) and batch 1 (#864–#891) are in
  the git log; each closed the issue it names.

## The #693 measurement, and why it matters more than the fix would have

#693 asked for two census-walk precision gaps to be SIZED before implementing, and they were:
`docs/notes/20260909-census-walk-gap-movable-sites.md`, instrument in `tool/probe-693/`, 14 targets
and 17,706 files. 28 / 25 / 3 movable sites, every recoverable rvalue a bare collection that hands
`untyped` onward one hop later. Declined, and #693 is closed as measured-and-declined.

The by-product is the part that mattered: the issue's premise that neither shape produces a wrong
answer is FALSE. A `class << self` ivar write lands in the enclosing class's INSTANCE facet, so
`def.ivar-write-mismatch` fires on correct Ruby — filed as
[#909](https://github.com/rigortype/rigor/issues/909) (`ready-for-agent`), cheaper than the seeding
it was found while declining, and with the only reachable symptom.

## The ADR corpus audit — the backlog changed shape

[`docs/notes/20260909-adr-corpus-audit.md`](notes/20260909-adr-corpus-audit.md) swept all 111 ADRs
and **filed 26 issues** (#911, #918-#930, #932-#943), so `ready-for-agent` returns a much larger set
than it did this morning; the note's § "Where each finding went" maps every finding. Its headline:
**the corpus under-claims.** ADR-102 says "Nothing implemented" about a command that shipped in
v0.3.4 and ADR-103's index row says it about the effect system, so `Proposed` is no longer readable
as "the unbuilt set" — do not trust an ADR's status without checking the code.

Three fixes landed from it: #906 (`rigor playground` dropped its first argument; `rigor help` omitted
`baseline` and `unused`), #908 (any FFI-family plugin listed ALONE failed to load — requiring it
registers `rigor-ffi` too and the loader called that a meta-gem; `rigor-rbnacl` never called
`Rigor::Plugin.register` at all), #913 (the `.rigor.yml` `plugins_isolation:` key the normative
internal spec documents has never existed).

## Open threads

- [#909](https://github.com/rigortype/rigor/issues/909) (`ready-for-agent`) — the facet conflation
  above. Do NOT take the census table split on its behalf; marking a `class << self` def as singleton
  for the write-mismatch collector is a spelling fix.
- [#915](https://github.com/rigortype/rigor/issues/915) (`ready-for-agent`) — two extend records the
  singleton ancestry still never sees: `class << self; include M; end` (widening the walk also moves
  #526's method fold) and an RBS-declared `extend` (the environment exposes no singleton-ancestry
  query at all).
- [#931](https://github.com/rigortype/rigor/issues/931) (`ready-for-human`) — there is no
  block-presence rule of any kind, so a call omitting a required block is never reported. Size the
  corpus before writing the rule; `&blk` forwarding, `&:sym`, and blockless-returns-Enumerator
  signatures are all shapes it must not fire on.
- [#697](https://github.com/rigortype/rigor/issues/697) stays open: #902 shipped only the
  loud-not-silent half and a spec PINS that the false positive still fires. The real fix waits on
  [#660](https://github.com/rigortype/rigor/issues/660). Do not add a fourth protection route.
- [#722](https://github.com/rigortype/rigor/issues/722) stays open for its last residue only.
- [#900](https://github.com/rigortype/rigor/issues/900) (`ready-for-human`) — #657's precision half;
  joining an in-source `include` DERIVES a positive edge and would license a fresh FP on an `else`
  arm.

## How to enter

1. Nothing is uncommitted and no PR of this session's is open. Other sessions merge to master
   throughout, so re-derive any file:line at current HEAD.
2. `gh issue list --label ready-for-agent` is the backlog. #909, #915, #710-adjacent census work and
   #530 are unblocked. From the audit, **#939 → #940 is the highest-leverage pair**: nothing compares
   an ADR's own `Status:` header to its README row, and no spec parses that header at all. #939 adds
   the gate, #940 is the ~20-ADR sweep it makes checked rather than asserted. #918-#924 are the
   audit's remaining live defects, each reproducible through the CLI.
3. Remote CI as the gate with NO local `make verify` is the default worth repeating: targeted specs
   plus rubocop locally, rebase onto master immediately before pushing. Three batches ran that way.
4. Two harness traps this cycle paid for: `FixtureHarness` under-detects versus the CLI on a flat
   fixture with no `sig/` (use a project fixture when the point is the diagnostic), and a `case`
   assigned to a local never consults per-pattern certainty (write the `case` inline).
5. A spec's failure-path lambda only runs on failure — a green suite proves nothing about its message.
   #661 gap 1 shipped a `NameError` there for months.
