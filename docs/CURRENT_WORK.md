<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward. Two items died of this in one week: the 2026-07-17 #1
  item ("a live bug, do this first") was refuted by its own repro — guarded since 2026-05-01 — and
  an "open" AR-lambda item had been fixed since 2026-05-28 (`fde760a2`).
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue, this file is
the one that is wrong.

## Where things stand

- **v0.2.9 published 2026-07-11.** master accumulates toward **v0.3.0**; its two mandatory pieces
  (deprecation clearance [#94](https://github.com/rigortype/rigor/pull/94), perf recalibration
  [#95](https://github.com/rigortype/rigor/pull/95)) are done — the rest of the cut is whatever
  issues get the `v0.3.0` milestone.
- The line is **evaluation** (ADR-50): outside feedback + completing the feature set toward the
  v1.0.0 freeze. The protection ceiling is a measured floor (ADR-67 WD2 spiked and deferred — do not
  re-recommend it); the next direction is the line's purpose, not another engine-precision feature.
- `make verify` and `make docs-check` clean. PR [#119](https://github.com/rigortype/rigor/pull/119)
  (docs-economy + ADR-97/98 flow re-org) is open and awaiting the user's review.

## Next session

1. **`Regexp.last_match` match-success narrowing (ADR-93 WD1a).** herb gains 4
   `call.possible-nil-receiver` under `--treat-all-as-inline-rbs`: the receiver is
   `Regexp.last_match(1)` after a successful `=~` whose group always participates
   (`/\n([ \t]+)\z/`), so nil is unreachable. A pre-existing imprecision masked by herb's
   `-> untyped` sigs; FP-reducing on its own, and per the ADR-57 protocol it must land **before**
   item 2, which surfaces it.
2. **ADR-93's `require_magic_comment:` default flip + the WD2 default-wiring decision — after 1.**
   The WD1 gate is landed and the mode is corpus-safe; note ADR-94: if the rbs 3.x floor ever moves,
   the reader migrates to `RBS::InlineParser` and WD2/WD3 evaporate — do not over-invest.
3. **Correct ADR-94 WD2 — its `UntypedFunction` "live bug" does not reproduce.** The WD2 claim
   ("a `(?)` method type crashes `rigor check` today") is refuted: `CheckRules#arity_eligible?` and
   `#argument_check_eligible?` guard the form (landed 2026-05-01, `fc1da90e` / `ef0dd777`), and the
   ADR's own repro plus six variant shapes run clean (probed 2026-07-17). Adjudicate whether any
   reproducing shape exists, then fix the ADR text — a normative record asserting a bug that is not
   there is ADR-92's disease in the opposite direction.

Adjacent open issues, if a session wants them instead:
[#161](https://github.com/rigortype/rigor/issues/161) (env-quarantine warning → diagnostic; needs a
severity decision — new rule ids freeze at v1.0),
[#162](https://github.com/rigortype/rigor/issues/162) (`static.*` + `void_origins`),
[#163](https://github.com/rigortype/rigor/issues/163) (internal-spec status-fidelity sweep).

## Waiting on the user

- **Publish the staged `ruby/rbs` upstream fix** — branch `widen-strscan-resolv-stdlib-sigs` in
  `references/rbs` (widens `StringScanner#[]`, `Resolv#initialize`); push + upstream PR are the
  user's action. Tracked as [#159](https://github.com/rigortype/rigor/issues/159).
- **Merge or amend PR [#119](https://github.com/rigortype/rigor/pull/119).**
- The upstream `rbs-inline` RDoc fix ([soutaro/rbs-inline#249](https://github.com/soutaro/rbs-inline/pull/249))
  is open under the user's fork; nothing to do repo-side until upstream responds.
