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

**Fifteen PRs landed 2026-09-03**, the last two being #709 (#681 the callee re-walk) and #711 (#705
dynamic-base name guessing). The review rounds produced **41 new issues**, all with reproduced repros.

**The constant-resolution arc is CLOSED.** #685 recorded `Module.nesting` at declaration time
instead of reconstructing it from a qualified-name string; #692 did the census scopes; #706 added the
rule that a write whose base is not statically nameable is DECLINED rather than guessed into a bare
name; #711 followed the `self` a block rebinds; #709 gave the def-node index each def's chain.
**Nothing in `lib/` now builds a scope from a self type alone.** What is left of the family is
enumerated in the ranked list below, and none of it is the old peel.

**Constant resolution, what is left after the arc.**
[#682](https://github.com/rigortype/rigor/issues/682) (a superclass name still peels the subclass's
qualified name), [#708](https://github.com/rigortype/rigor/issues/708) (a rooted declaration header
keeps the enclosing prefix — both walks agree with each other and disagree with Ruby),
[#707](https://github.com/rigortype/rigor/issues/707) (the ADR-85 seed bundle re-parses, so
`--incremental` keeps the old answer and `--verify-incremental` reports a difference),
[#710](https://github.com/rigortype/rigor/issues/710), plus the older
[#655](https://github.com/rigortype/rigor/issues/655),
[#656](https://github.com/rigortype/rigor/issues/656),
[#662](https://github.com/rigortype/rigor/issues/662).

**Analysis that reports LESS while exiting 0.** #676/#688/#694 closed the three spec-side entry
points (1,177 of 1,925 examples had been passing with every check rule crashing). Two remain, both
running `Runner#run` inside `lib/` where no spec wrapper reaches:
[#686](https://github.com/rigortype/rigor/issues/686) (`ClosureKillOracle` scores a crashed run a
*survivor*, inflating the mutation harness's headline in the direction that manufactures work) and
[#696](https://github.com/rigortype/rigor/issues/696) (a `DuplicatedMethodDefinitionError` leaves a
class known-but-empty; a vendored RBS copy collapses the whole type universe on a green run). **A
`Result#crashed?` predicate would serve both plus the existing guard from one definition** instead of
three string matches. Same family, different surface:
[#698](https://github.com/rigortype/rigor/issues/698) (five snapshot fixtures with no golden report
*pending*, so that gate is off) and [#704](https://github.com/rigortype/rigor/issues/704) (a
plugins-route spec can pass with an empty registry).

**Plugin/RBS precedence.** #702 stopped a plugin-typed call being re-decided from the RBS — *writing
more RBS no longer makes diagnostics worse*. It also surfaced that **ADR-2 says the opposite of what
ships**: an incompatible `dynamic_return` is meant to be a conflict diagnostic, and has silently
overridden RBS since v0.1.1. [#700](https://github.com/rigortype/rigor/issues/700) is that
adjudication (ready-for-human); [#701](https://github.com/rigortype/rigor/issues/701) and
[#697](https://github.com/rigortype/rigor/issues/697) are its neighbours, and
[#660](https://github.com/rigortype/rigor/issues/660) is the ADR-26 question they keep pointing at.

## Backlog, ranked

1. **[#696](https://github.com/rigortype/rigor/issues/696)** + **[#686](https://github.com/rigortype/rigor/issues/686)**
   via a shared `Result#crashed?` — the two remaining "reports less while exiting 0" entry points,
   both running `Runner#run` inside `lib/` where no spec wrapper reaches.
2. **[#707](https://github.com/rigortype/rigor/issues/707)** — a warm `--incremental` run keeps a
   stale resolution and `--verify-incremental` flips to FAILED on a project with compact
   declarations. Introduced by #709 in the sense that cold got fixed and warm did not.
3. **[#708](https://github.com/rigortype/rigor/issues/708)** + **[#682](https://github.com/rigortype/rigor/issues/682)**
   — the two constant-resolution leftovers that are wrong against Ruby rather than merely imprecise.
4. **[#700](https://github.com/rigortype/rigor/issues/700)** (human) and
   **[#660](https://github.com/rigortype/rigor/issues/660)** (human) — two ADR questions the plugin
   work keeps deferring to. Answering them unblocks #697 and #701 cleanly.
5. **[#574](https://github.com/rigortype/rigor/issues/574)** (human) — still the sole blocker on the
   corpus's biggest pair (`Parameters#[]`, 581 redmine + 496 mastodon).
6. Rails/AR: [#658](https://github.com/rigortype/rigor/issues/658)'s descendants
   [#659](https://github.com/rigortype/rigor/issues/659) (unblocked),
   [#670](https://github.com/rigortype/rigor/issues/670),
   [#673](https://github.com/rigortype/rigor/issues/673); plus
   [#678](https://github.com/rigortype/rigor/issues/678),
   [#679](https://github.com/rigortype/rigor/issues/679),
   [#671](https://github.com/rigortype/rigor/issues/671).

## Measurement — read before writing a gate or trusting a number

- **A gate an issue prescribes can be green while the change ships FPs.** #632's was "no new firing
  on redmine/mastodon"; those configs scope `paths: [app, lib]` and the sites were elsewhere.
- **A collapsed class, a crashed run, and an empty plugin registry all produce zero diagnostics** —
  "nothing fires" passes on each. Gate on a declared return RESOLVING, or on the autoload not having
  fired, or on the plugin being registered.
- **"Byte-identical diagnostics" is usually inert, not probative.** The pattern that works is #692's
  and #706's: a Prism probe counting the sites that CAN move, then adjudicating each. #706's found a
  real mastodon instance that moves no diagnostic at all.
- `rigor check` on a FILE LIST can fire a false `undefined-method` the same check over the DIRECTORY
  does not ([#684](https://github.com/rigortype/rigor/issues/684)) — pass directories.
- CRuby's `lib/` opacity, probed this cycle: stdlib-proper precision **72.7%**, whole tree 64.5%
  (vendored bundler/rubygems is 65% of the named-receiver residue). The top stdlib clusters are all
  honest `void`/`untyped`. The lens counts `-> void` as opaque.

## Pipeline notes (each earned by an incident)

- **A finding's REPRO is reproducible; its CHARACTERISATION is a separate claim.** Five issues were
  filed this cycle with an implementer's or reviewer's framing and had to be corrected after someone
  measured it — including one filed "FP-safe" that fires on correct code. Verify the framing.
- **Grepping your changed identifiers is necessary but NOT sufficient.** Structural guards ENUMERATE
  a surface: `public_api_drift_spec` (public method lists), `scope_spec`'s field coverage
  (constructor keywords), `project_pre_passes_spec` (Discovery slots), `precision_snapshot_spec`
  (goldens). None names what you added. Check by COMPUTING what they pin. Three workers were caught
  by these this cycle; when one goes red, moving the method somewhere unpinned usually beats editing
  the snapshot.
- **Check a normative `MUST` against the code it ships with.** Five branches this cycle shipped spec
  text broader than their implementation; all were caught by review, none by a gate.
- Read gate exit codes UNPIPED; lint your own diff with
  `git diff --name-only origin/master...HEAD | grep '\.rb$' | xargs rubocop --force-exclusion`;
  push a rebased branch with `--force-with-lease`; file a follow-up issue BEFORE opening the PR that
  cites it (a PR twice took the number it referenced).
- A version-RANGE dependency is only proven by the compat job: reproduce it at BOTH ends locally.
