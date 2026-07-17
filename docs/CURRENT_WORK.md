<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward. Three items have died of this in one week: the
  2026-07-17 #1 item ("a live bug, do this first") was refuted by its own repro — guarded since
  2026-05-01 — an "open" AR-lambda item had been fixed since 2026-05-28 (`fde760a2`), and roughly
  40% of the ROADMAP backlog turned out to have shipped.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue, this file is
the one that is wrong.

## Where things stand

- **v0.2.9 published 2026-07-11.** master accumulates toward **v0.3.0**; its two mandatory pieces
  (deprecation clearance [#94](https://github.com/rigortype/rigor/pull/94), perf recalibration
  [#95](https://github.com/rigortype/rigor/pull/95)) are done — the rest of the cut is whatever
  issues carry the `v0.3.0` milestone.
- The line is **evaluation** (ADR-50): outside feedback + completing the feature set toward the
  v1.0.0 freeze. The protection ceiling is a measured floor (ADR-67 WD2 spiked and deferred — do not
  re-recommend it); the next direction is the line's purpose, not another engine-precision feature.
- **The docs/flow re-org is done** (ADR-97, ADR-98, [#119](https://github.com/rigortype/rigor/pull/119)):
  the backlog is GitHub Issues, `docs/ROADMAP.md` is deleted and gated against recreation, `CLAUDE.md`
  is an `@AGENTS.md` shell, and this file is capped at 120 lines.
- **The config surface is done** (ADR-99, [#170](https://github.com/rigortype/rigor/pull/170)): the
  JSON schema is a named source of truth, `rigor_rs:` is reserved for the Rust port, and the nested /
  reserved / URL axes are gated.
- `make verify` and `make docs-check` clean.

## Next session

The `v0.3.0` config arc is closed; pick from the milestone. The two open items there:

1. **[#120](https://github.com/rigortype/rigor/issues/120) — mature `--incremental` (ADR-46) toward a
   default-capable check path.** `ready-for-human`: it needs a judgment call on what "default-capable"
   requires before implementation. The `--verify-incremental` gate (incremental == full `--no-cache`,
   byte-identical) is the acceptance bar and is already wired into CI.
2. Whatever else earns the milestone. The unmilestoned backlog is
   [the open issues](https://github.com/rigortype/rigor/issues); `ready-for-agent` ones are specified
   enough to start with no human context.

Carried over from the rbs-inline arc, still open and not milestoned:

- **`Regexp.last_match` match-success narrowing (ADR-93 WD1a).** herb gains 4
  `call.possible-nil-receiver` under `--treat-all-as-inline-rbs`: the receiver is
  `Regexp.last_match(1)` after a successful `=~` whose group always participates
  (`/\n([ \t]+)\z/`), so nil is unreachable. A pre-existing imprecision masked by herb's
  `-> untyped` sigs; FP-reducing on its own, and per the ADR-57 protocol it must land **before**
  ADR-93's default flip, which surfaces it.
- **ADR-93's `require_magic_comment:` default flip + the WD2 default-wiring decision.** Note ADR-94:
  if the rbs 3.x floor ever moves, the reader migrates to `RBS::InlineParser` and WD2/WD3 evaporate.
- **Correct ADR-94 WD2 — its `UntypedFunction` "live bug" does not reproduce.** `CheckRules`
  guards the form via `arity_eligible?` / `argument_check_eligible?` (both landed 2026-05-01,
  `fc1da90e` / `ef0dd777`); the ADR's own repro plus six variant shapes run clean (probed
  2026-07-17). Adjudicate whether any reproducing shape exists, then fix the ADR text.

## Waiting on the user

- **Publish the staged `ruby/rbs` upstream fix** — branch `widen-strscan-resolv-stdlib-sigs` in
  `references/rbs` (widens `StringScanner#[]`, `Resolv#initialize`); push + upstream PR are the
  user's action. Tracked as [#159](https://github.com/rigortype/rigor/issues/159).
- The upstream `rbs-inline` RDoc fix ([soutaro/rbs-inline#249](https://github.com/soutaro/rbs-inline/pull/249))
  is open under the user's fork; nothing to do repo-side until upstream responds.
- **rigor-rs side:** the reserve pipeline (ADR-99) now has its first reservation. `rigor_rs.ruby` is
  declared in our schema, so the port can implement against it and its vendored copy stops rejecting
  its own key on the next submodule bump.
