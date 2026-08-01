<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward — and verify it by the thing that decides, not by a
  proxy. This cycle's example: the #260 design assumed the seeded-site survivor cluster was oracle
  blindness; the implementation measurement split it, and only half was.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Where things stand

- **v0.3.1 is released** (2026-07-29). No version bump is due — releases wait for an explicit ask.
- **Two audited PRs are OPEN and waiting for a human merge** (2026-08-01; each: parent re-ran
  `make verify` → exit 0, `git diff --check` → exit 0, CI green or green-but-Tests-pending at last
  check). The session's `gh pr merge` was blocked by the permission classifier — merging needs the
  user, or a permission rule for `gh pr merge`:
  - [#261](https://github.com/rigortype/rigor/pull/261) — Tuple `first(n)`/`last(n)` folds to the
    precise sub-Tuple (the `take`/`drop` shape); closes the last asymmetry in that family (#121
    slice). Two Slice-4 overload specs were legitimately rewritten onto `Nominal[Array]` locals so
    the arity path stays exercised.
  - [#262](https://github.com/rigortype/rigor/pull/262) — #260's fix: one `Protection::DiscoverySeed`
    table set threaded to BOTH Tier-2 halves (site filter + a new opt-in
    `Runner.new(discovery_seed:)` seam the `DiagnosticOracle` passes through). Default nil keeps
    the prebuilt/LSP contract byte-identical; OFF arm untouched.
- **#260 is decided and amended** — read both comments on the issue before touching Tier 2. The
  short version: the unkillable-survivor cluster was only HALF measurement blindness
  (`discovered_classes` — fixed by #262, +21 kills, spec-proven). The other half is ADR-67 WD6b
  *by construction*: negative rules decline on inferred-param-rooted values (lower bound ⇒ FP), so
  those survivors are TRUE "no teeth here" reports and stay in the denominator. Full seed stays in
  the oracle (fidelity + no filter/oracle drift). Rigor `lib` graduation numbers: 10,252 sites /
  5,580 killed / 0.5443.
- **Filed this cycle**: [#263](https://github.com/rigortype/rigor/issues/263) (Tier 1 counts
  WD6b-guarded sites as protected — the proxy over-claim #260's measurement exposed; wants ONE
  shared predicate for both tiers), [#264](https://github.com/rigortype/rigor/issues/264) (Tier-2
  site totals jitter: `classify` rescues harness failures to `:invalid` silently).

## Next session

- **Merge #261 and #262 first** (user action), then delete the worktree
  `.claude/worktrees/agent-ac6545cbe4fcd600f` and prune branches.
- **redmine `app/models` ON-arm re-measure** is the remaining #260 acceptance box and a graduation
  precondition (survey-project setup: cwd=target + `BUNDLE_GEMFILE`; see the memory note on survey
  projects).
- **The graduation cluster is now #254 + #263** (both "what does the ratio mean" issues). #254's
  design premise should be re-checked against #260's amendment: its "the most valuable catch is
  scored as a miss" example (`Account.find` return-type change caught in callers) sits right next
  to the empirical footnote that renaming `Account.find` is not killable even by whole-project
  `check` on an RBS-less class — the dependent-closure oracle is still right, but the example
  sites it will rescue are fewer than the issue implies. Audit seams already verified:
  `IncrementalSession#buffer_path?` (a bound buffer is never stat-fresh) + `scan_summary_for_paths(buffer:)`
  + ADR-46 `file_dependents`.
- **An UNFILED draft upstream report is ready for user sign-off**: `rbs-inline` parses
  `# @rbs module-self: Foo` (colon form) and silently drops the self-type — confirmed live against
  the vendored 0.14.0 gem, no existing upstream issue, full discard path with file:line in the
  draft. The draft was in the session scratchpad (regenerate cheaply if gone: the evidence chain is
  ADR-32 WD12 + `annotation_parser.rb:323-326` → `753-764` → rescue at `617-621` →
  `annotations.rb:527-536`). Side-finding: ADR-32's "upstream docs use the colon" citation actually
  points at rbs-core's built-in `RBS::InlineParser` doc, not the rbs-inline gem's — worth a
  one-line ADR correction when next touching ADR-32.
- **#134 slices 2-3, #135, #137, #142, #147** remain the `ready-for-agent` pool; #121 stays open
  (the remainder after #261: `Regexp.compile` alias, `Integer#rationalize`, `Integer`/`Float#abs2`
  — all probed real but small; Set projections audited CLOSED, nothing bounded remains).

## What this session learned that is not in a commit

- **Delegation pattern, second confirmation**: fixed design decisions in the brief ("do not
  relitigate") + the repo contract restated verbatim + gates by exit code + the parent re-running
  gates independently worked again — AND the brief's escape hatch mattered: the #262 agent was told
  to report contradictions rather than redesign, and its measurement overturned half the design
  premise. Write that hatch into every brief.
- **A subagent's "deliberately declined" comment can be stale**: the Tuple `first(n)` decline
  predated `take`/`drop` landing the identical fold; the #261 agent correctly read it as historical
  rather than binding. Check the sibling precedent before honouring an old "deliberate" comment.
- **The auto-mode permission classifier blocks `gh pr merge` (and intermittently blocked complex
  awk/git-diff one-liners)**: plan for PRs to end at "open + audited", and read branch files
  directly instead of fancy diff extraction pipelines.
