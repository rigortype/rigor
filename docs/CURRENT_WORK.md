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

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Where things stand

- **v0.3.2 is released** (2026-08-08). No version bump is due — releases wait for an explicit ask.
  `make verify` is green on master at `13a5b456`, verified on the INTEGRATED tree after this arc's
  parallel batch (see the collision below for why that matters).
- **Landed this arc**: #303 (PR #304, argument-position `[T]` binding) · #121's final fold slice
  (PR #305) · #307 (mutation-harness `SpecMap` directory convention) · #306 (PR #314) · the #135
  checkbox-1 wave-1 specs (PRs #309/#310/#311) · #308 (PR #312) and its repair (PR #315).
- **`check_rules.rb` had never been type-checked**, and that is the arc's largest finding. Its own doc
  comment quotes `` `# rigor:disable-file all` `` in backticks, and the suppression patterns matched
  anywhere inside a comment, so the documentation file-suppressed the 3,063-line file that defines
  the rules. Found by an impossible measurement — the mutation recon's `DiagnosticOracle` killed
  **0 of 914** there against 24/24 on a control. Fixed by anchoring every marker pattern to the start
  of the comment (#306); the file is now provably live (poisoning a `Diagnostic.from_name_loc` call
  surfaces six errors). **A structurally impossible measurement is a finding, never a zero to report.**
- **#313 is the one defect that arc left open**: an optimistic nil-free HashShape read launders
  through `.nil?` into the `&&`/`||` polarity gate, so `return false if MAP[a].nil? || MAP[b].nil?`
  fires "always falsey" on live defensive code while the single-operand form correctly stays silent.
  `check_rules.rb:2743` carries a justified directive whose removal is the acceptance test. Check
  #152's landed change against the spec clause it was warned to preserve.
- **Two correct-in-isolation PRs collided and turned master red.** PR #310 pinned #308's
  then-current broken behaviour; PR #312 fixed #308. Disjoint files, no conflict, both green, red on
  merge. Two habits follow: a spec pinning known-wrong behaviour MUST carry an in-place "flip this
  when #N is fixed" comment (PR #310's did — the repair was one line), and **after merging a parallel
  batch, run the suite on the integrated master**, which is the only place such a collision surfaces.

## Next session

- **#135 checkbox 1, wave 2 is in flight**: `argument_type` (8 survivors, the ADR-58 ivar-provenance
  gate in `declaration_sourced_nil_only_mismatch?` the densest cluster) and the small remaining
  families (`nil_receiver` 5, `undefined_method` 4, `always_raises` 3, `dump_type`/`assert_type` 2,
  `visibility_mismatch` 1, `pipeline` 1). When it lands, this file's **biteable** survivors are
  exhausted — but the honest next step is a **re-measure**, because every number on the issue is
  test-axis-only: the type axis was structurally dead until #306. `--site biteable` is a complete
  169-site census (~63 min); `--site all` is 914 sites ≈ 6.1 h of rspec and stays infeasible, so
  745 sites remain unmeasured and the per-family `:all` inventory on the issue is the visible gap.
  #135's other four checkboxes are untouched.
- **#121 carries ZERO queued work** after six passes — the record, including the `Tuple#concat` and
  `compare_by_identity` 🚫 adjudications, is on the issue. Closing it or leaving it as the standing
  P3 category is the user's call.
- **`ready-for-agent`**: #313 (the open engine FP above), #147 (**demand-gated** — its three items
  really are unimplemented, verified, but the issue waits on a concrete editor-extension author),
  #135's remainder.
- **Three tooling traps recorded this arc**, all hit for real: `Style/ArrayJoin` autocorrects a
  literal-array `[1, 2] * "-"` into `.join`, silently defeating a `*`-with-String assertion (use a
  variable receiver); parallel `make verify` runs in two worktrees flake each other, so serialize
  gate re-runs when auditing parallel agents; and **poisoning `check_rules.rb` to prove it is
  checked must break something STATIC, not runtime** — renaming a method the analyzer itself calls
  yields an internal-analyzer-error, not a diagnostic. Rename a *called* method on a sig-known class
  (`Diagnostic.from_name_loc`) instead.
- **#158 was re-audited: do not build it yet.** Both preconditions (Layer-1 doc hygiene, the
  "exhaustion-as-explanation" observability its acceptance shape lists) are already satisfied, so it
  is purely demand-gated. Non-obvious: `BudgetTrace` counters do not cross `fork`, so a trace must
  run `--workers 0` or a real cliff reads as clean.
- **The rbs-inline upstream report stays ON HOLD by user decision** (2026-08-01; do not file without
  a fresh ask). Evidence: ADR-32 WD12 + `annotation_parser.rb:323-326` → `753-764` → rescue at
  `617-621` → `annotations.rb:527-536`; plus a pending one-line ADR-32 correction (its "upstream
  docs" citation points at rbs-core's `RBS::InlineParser` doc, not rbs-inline's).

## What this arc learned that is not in a commit

- **The delegation brief that works**: fixed design ("do not relitigate") + repo contract verbatim +
  gates by exit code + parent re-runs the gates independently + **"report contradictions, do not
  silently redesign"** + **"never use run_in_background or Monitor; run gates in the FOREGROUND with
  an explicit timeout, and never end a turn while anything is pending"**. The contradiction hatch
  overturned a premise on seven separate tasks — it is the highest-value sentence in the brief. For
  an engine FP add: *diagnose and report the root cause even if you also fix it; retreat rather than
  land a half-understood fix.*
- **A cheap proxy for the property you actually care about can be wrong in BOTH directions at once.**
  #286's carrier-shape gate would have declined 99 genuine proofs *and* still missed 12 optimistic
  values, because shape and provenance are different axes. Before scoping work around a proxy, measure
  the real property once — it cost one instrumented build and retired the option outright.
- **A measurement's landing rule can be the wrong gate.** I gated #152 on "zero new diagnostics"; it
  passed, and shipping would still have been wrong, because the harm was deleted fallbacks rather
  than new firings. Ask what the damage mode IS before choosing the number to watch.
- **Two harness traps that fabricate a convincing zero**, both hit for real: a project
  `.rigor-baseline.yml` silences diagnostics on both arms (redmine: 793), and a warm run-result
  cache used to ignore engine source. The second is fixed (#285/#290 — `Cache::EngineSource`, free
  for released gems, +7% on a checkout's warm path), but **always pass `--no-cache --no-baseline`
  for a before/after engine measurement.**
- **Queued-work descriptions here systematically under-report what already exists** — five instances
  across ROADMAP prose, an issue premise, an issue's acceptance criteria, a coverage table, and this
  handoff's own pointer. Budget one `ls`/`grep`/probe per claimed-missing artifact before briefing.
- **A "correct but slower" result is a defect, not a trade-off**: #142's pool was 0.66x at N=8, a
  realistic editor burst, and the repo had already fixed that exact shape once (#257). It merged
  only with a size gate whose sub-threshold path is literally the old computation.
- **A decline assertion (`expect(...).to be_nil`) is the easiest test to pass by accident**, since
  every construction error also yields nil — always pair it with a case that must still succeed.
  This repo's formatter hook also strips the `*` from `foo(*array)`, which is how one such spec
  shipped testing nothing (#283, repaired in #284). Re-read spec regions after editing.
- **Salvage an interrupted agent's uncommitted work rather than re-running it** — 642 good spec
  lines were sitting in a worktree when a run died mid-sweep; verifying and committing them cost far
  less than the sweep would have.
