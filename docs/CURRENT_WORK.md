<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward — and verify it by the thing that decides, not by a
  proxy. Every arc this week paid that rule: #260's cluster was only half blindness, #254's premise
  measured out to zero on its own favourable corpus, #264's "jitter" would not reproduce quiet, and
  #271's minimal repro was missing a third ingredient nobody had guessed.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Where things stand

- **v0.3.1 is released** (2026-07-29). No version bump is due — releases wait for an explicit ask.
- **The Tier-2 measurement arc is closed** (#260 #263 #254 #264 #134, PRs #261 #262 #265 #266 #267
  #270). Load-bearing records live on the issues: #260's amended decision (only the
  `discovered_classes` half of the unkillable cluster was blindness; the `param_inferred_types`
  half is ADR-67 WD6b *by construction*), and #254's two closing comments
  (`dependent-closure-kill-oracle` is **presumptively non-graduating** — the Mutator never mutates
  `def` signatures and callers read declarations, so body mutations are cross-file-invisible on
  RBS-typed code; textbringer, the favourable corpus, gave byte-identical arms).
- **Graduation numbers** (in #260's closing comments): `discovery-seeded-mutation-sites` on Rigor
  `lib` 10,252/5,580/0.5443; redmine `app/models` 2,762/464/0.1680. Tier-1 `lower_bound_typed` on
  `lib`: 2,223/12,056 (~18.4%). Mutation cache: warm/cold **0.011** on `lib` (253.8s → 2.76s) —
  but the warm path REQUIRES a prior `rigor check --incremental` snapshot for those roots,
  otherwise the cache reports itself disabled and the run is simply cold.
- **Landed 2026-08-02 after that**: #271 (PR #275) — the engine FP where a nested
  `Const = Data.define(...)` never entered the cross-file `discovered_classes` table, so a
  consumer's lexical walk fell through to the parent namespace's same-named, RBS-declared (=closed)
  sibling and reported `call.undefined-method` on correct code. The trigger needs THREE ingredients
  at once (nested Data constant + same-named parent-namespace sibling + RBS for that sibling),
  which is why the first minimal repro stayed silent. #137 (PR #276) — all four dry-rb ceiling
  checkboxes, including the `dry-validation.rule-key-mismatch` `:error` behind two all-or-nothing
  FP gates (2 firing specs against 7 decline specs). #269 (PR #274) — the missing precision
  snapshot; the fixture had been running under a silent `skip`, not a vacuous pass.
- **Then closed in the same arc**: #277 (PR #278) — and its recorded hypothesis was WRONG in an
  instructive way: the defect was not ADR-55 recursive-return narrowing but `MutationWidening`
  ignoring receivers that *select* among variables (`(cond ? a : b)[k] = v`), so both hashes kept
  their literal `{}` shape; a 12-line non-recursive probe fires the same FP, and the cycle guard
  had been *masking* the identical wrong body result. #142 (PRs #280 + #281) — LSP multi-buffer
  fork dispatch, **with a size gate required at review**: the pool measured 0.66x at N=8 and
  broke even only near N=12, so it now declines below 16 (`RIGOR_LSP_POOL_MIN_BATCH`), the
  sub-threshold path being the exact computation the code already ran. #121 second slice (PR #279)
  — `Regexp.union` / `linear_time?`, plus a coverage-table reconciliation that found **12 rows**
  (8 CGI, 4 URI) marked 🔲 though already implemented. #135 checkbox 1 (PR #282) — seven giant
  engine files swept, 642 spec lines, no `lib/` change.

## Next session

- **Resume #135's giant-file tier at `analysis/runner.rb`** — it is the named boundary, not
  reached because the run hit an external limit mid-sweep. The file list and the resume point are
  on the issue; do not re-derive them.
- **Remaining `ready-for-agent`**: #147 (CLI editor-mode throughput: snapshot cache, `--also`,
  multi-buffer — it overlaps the buffer machinery #142 just changed, so read
  `BufferPoolDispatcher` + `PublishBatcher` first), #135's four remaining checkboxes, #121 as the
  ongoing P3 fold category. Its URI row closed in PR #283 (`encode_www_form` / `decode_www_form`
  implemented; `parse` / `join` re-classified 🚫 — a URI object has no `Constant`, and narrowing
  `parse`'s ten-arm union is bucket-3/P0 because it can surface a diagnostic that does not fire
  today), leaving `URI.extract` as the only open URI row. **Start every slice by probing with
  `rigor type-of`, never by reading the coverage tables** — across three slices roughly half of
  each "gap list" turned out to be already implemented or out-of-category, so the audit is the
  work, and re-classifications are first-class output.
- **`ready-for-human` wanting a design pass**: #152 (`&&`/`||` polarity gate beyond Constant-only),
  #159 (upstreaming staged ruby/rbs signature fixes — external publishing, needs the user's go).
  **#158 was re-audited 2026-08-02 and the answer is "do not build it yet"** — both preconditions
  (Layer-1 doc hygiene, and the "exhaustion-as-explanation" observability its acceptance shape
  lists) are ALREADY satisfied, so the issue is purely demand-gated and the one candidate cliff was
  refuted. The reasoning and the collection method are on the issue; the non-obvious part is that
  `BudgetTrace` counters do not cross `fork`, so a trace must run `--workers 0` or a real cliff
  reads as clean.
- **The rbs-inline upstream report stays ON HOLD by user decision** (2026-08-01; do not file
  without a fresh ask). Evidence chain: ADR-32 WD12 + `annotation_parser.rb:323-326` → `753-764`
  → rescue at `617-621` → `annotations.rb:527-536`; plus a pending one-line ADR-32 correction (its
  "upstream docs" citation points at rbs-core's `RBS::InlineParser` doc, not the rbs-inline gem's).

## What these sessions learned that is not in a commit

- **The delegation brief that works**: fixed design ("do not relitigate") + repo contract verbatim
  + gates by exit code + parent re-runs the gates independently + **"report contradictions, do not
  silently redesign"** + **"run every gate/measurement in the FOREGROUND; never end a turn while
  anything is pending"** (three background-wait stalls before that line was added; none after).
  The contradiction hatch overturned a premise on five separate tasks — it is the highest-value
  sentence in the brief.
- **For an engine FP, add "diagnose and report the root cause even if you also fix it; retreat
  rather than land a half-understood fix"** — that is what produced #271's three-ingredient
  finding instead of a plausible patch.
- **Two FPs on our own code were found by writing ordinary code, not by looking for FPs** (#271
  while wiring a cache key, #277 while writing a plugin walker). Dogfooding surfaces the class the
  project weighs heaviest; treat "I had to work around the checker" in any agent report as a
  finding to file, not an aside.
- **Do not let a measurement agent borrow the main tree's `exe/rigor` while another agent edits
  that tree** — a diagnostic `warn` landed mid-measurement during the textbringer run. Provably
  benign that time; the isolation was luck. Pin measurements to a clean checkout or sequence them.
- **Fixture lesson for oracle specs**: equalise the knowledge axis before comparing two oracles —
  #266's brute-force cross-check reported missing cross-file *knowledge* as a closure defect until
  both features were adopted in the fixture.
- **Queued-work descriptions in this repo systematically under-report what already exists.** Four
  instances now, on four different surfaces: ROADMAP prose (the L0 docs harness), an issue's
  premise (#142's "needs a persistent Environment" — already true since slice 7), an issue's
  acceptance criteria (#158's observability item — `BudgetTrace` already covers every cutoff), and
  a coverage table (#121's note marked 12 implemented CGI/URI rows as gaps). Budget one `ls` /
  `grep` / probe per claimed-missing artifact before briefing anyone; it has paid off every time.
- **A "correct but slower" result is a defect here, not a trade-off to ship.** #142's pool was
  0.66x at N=8 — squarely a realistic editor burst — and the repo had already fixed this exact
  shape once (#257's `ForkMap` pessimization). The reviewer's job is to send it back for a gate;
  the sub-threshold path being *literally the old computation* is what makes such a gate safe.
- **Salvage an interrupted agent's uncommitted work rather than re-running it**: #135 stopped
  mid-sweep on an external limit with 642 lines of good specs uncommitted in its worktree. Verify
  them yourself, commit with the boundary named, and record the resume point — re-running the
  sweep would have cost far more than reading the diff.
