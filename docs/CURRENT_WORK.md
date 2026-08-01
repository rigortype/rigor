<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward — and verify it by the thing that decides, not by a
  proxy. This cycle produced two examples: the #260 design assumed the seeded-survivor cluster was
  oracle blindness (only half was — the other half is WD6b by construction), and #254's premise
  ("the best catch is scored as a miss") measured out to ~zero on both available corpora.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Where things stand

- **v0.3.1 is released** (2026-07-29). No version bump is due — releases wait for an explicit ask.
- **The Tier-2 graduation cluster (#260 / #263 / #254) is fully decided and CLOSED** (2026-08-01,
  one session; every PR: audited diff + CI fully green + parent-re-run `make verify` exit 0; the
  user granted standing authorisation for autonomous PR merges mid-session, recorded in memory):
  - [#262](https://github.com/rigortype/rigor/pull/262) (closes #260) — one
    `Protection::DiscoverySeed` table set threaded to BOTH Tier-2 halves; opt-in
    `Runner.new(discovery_seed:)` seam. The amended decision on #260 is the load-bearing document:
    only the `discovered_classes` half of the unkillable cluster was oracle blindness; the
    `param_inferred_types` half is ADR-67 WD6b *by construction* and its survivors are truth.
  - [#265](https://github.com/rigortype/rigor/pull/265) (closes #263) — Tier 1 now reports
    `lower_bound_typed` (WD6b-guarded sites) as a split WITHIN protected; headline untouched.
    Rigor `lib`: 2,223 of 12,056 protected sites (~18.4%).
  - [#266](https://github.com/rigortype/rigor/pull/266) (closes #254) — `dependent-closure-kill-oracle`
    (behaviour feature, off): strictly additive closure oracle. **Empirical headline: the closure
    adds ~zero kills on both corpora** (+2 on `lib`, none on redmine) — verified independently by
    disk-written whole-project re-analysis of 21 survivors (zero diagnostics anywhere). Graduation
    precondition recorded on #254: find a corpus where it bites (predicted shape: a `sig/`-shipping
    project like textbringer, where a return-type mutation can produce a caller-side mismatch).
  - Also merged: [#261](https://github.com/rigortype/rigor/pull/261) — Tuple `first(n)`/`last(n)`
    precise sub-Tuple folds (#121 slice).
- **Graduation-note numbers** (in #260's closing comments): Rigor `lib` ON 10,252/5,580/0.5443;
  redmine `app/models` ON 2,762/464/0.1680, with 66.2% of redmine ON-survivors on project-class
  singletons (the honest RBS-less-model gap). OFF arms reproduce #253 byte-identically.

## Next session

- **[#264](https://github.com/rigortype/rigor/issues/264)** (site-total jitter: `classify` rescues
  harness failures to `:invalid` silently, ±3 sites between identical runs) is the remaining
  measurement-hygiene item — small, `ready-for-agent`, and now the only thing between the Tier-2
  numbers and bit-stability.
- **The `ready-for-agent` pool**: #134 slices 2-3 (ADR-46 forward-edge result cache + the
  incremental==cold gate — the remaining Tier-2 *speed* work), #135, #137, #142, #147. #121 stays
  open (remainder after #261: `Regexp.compile` alias, `Integer#rationalize`, `Integer`/`Float#abs2`;
  Set projections audited closed).
- **A textbringer Tier-2 run would answer #254's graduation precondition cheaply** — it ships its
  own `sig/` (see the survey memory), so it is the predicted corpus where the closure oracle's
  caller-side catches exist. One measurement, recorded on #254, settles whether the feature ever
  graduates.
- **The rbs-inline upstream report is ON HOLD by user decision** (2026-08-01: upstream movement not
  expected; do not file without a fresh ask). Evidence chain if ever needed: ADR-32 WD12 +
  `annotation_parser.rb:323-326` → `753-764` → rescue at `617-621` → `annotations.rb:527-536`; also
  ADR-32's "upstream docs" citation actually points at rbs-core's built-in `RBS::InlineParser` doc,
  not the rbs-inline gem's — a one-line ADR correction when next touching ADR-32.

## What this session learned that is not in a commit

- **The delegation pattern that survived contact**: fixed design in the brief ("do not relitigate")
  + repo contract verbatim + gates by exit code + parent re-runs gates + **an explicit escape hatch
  ("report contradictions, do not silently redesign")**. The hatch carried the session twice: #262's
  agent overturned half the #260 design premise with an attribution measurement, and #266's agent
  caught its own first design conflating two feature axes (it lost 11 kills on redmine and could
  not attribute them) and corrected to the strictly-additive shape before opening the PR.
- **Subagents stall by ending their turn on background waits** — three separate stalls in one
  session, all recovered by a resume message. Put "run gates/measurements in the FOREGROUND with a
  generous timeout; never end a turn while anything is pending" in every brief up front.
- **The auto-mode permission classifier intermittently blocks complex one-liners** (awk pipelines,
  multi-path `git diff`); read branch files directly instead of fancy diff extraction.
- **Fixture lesson for oracle specs**: equalise the knowledge axis before comparing oracles (the
  brute-force cross-check in #266 reported missing cross-file *knowledge* as a closure defect until
  both features were adopted in the fixture).
