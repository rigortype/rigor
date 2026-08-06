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

- **v0.3.1 is released** (2026-07-29). No version bump is due — releases wait for an explicit ask.
  `make verify` is green on master at `7f7fcdd0`; no open PR of ours (the three open ones are
  dependabot, including the deliberately-held rubocop bump).
- **Closed this arc, with the record on each issue**: #260 #263 #254 #264 #134 (the Tier-2
  measurement cluster), #271 #277 (two engine FPs), #137 #269 #142 #152 #285 #290.
- **The three findings most likely to matter later**, all counter to the issue that produced them:
  - **#254** — `dependent-closure-kill-oracle` is **presumptively non-graduating**. The Mutator
    never mutates `def` signatures and callers read declarations, so a body mutation is
    cross-file-invisible on RBS-typed code *by construction*; textbringer (52 RBS files, dense
    fan-out — the predicted-favourable corpus) gave byte-identical arms.
  - **#152** — widening the `&&`/`||` polarity gate was **evaluated and declined** even though the
    corpus diff was clean, because `docs/internal-spec/inference-engine.md:251` forbids it by a
    normative MUST that names #152, and because the sole measured effect is deleting author-written
    fallbacks (70 firings, e.g. `ESCAPE_MAP[m] || m`).
  - **#286** — the census found **zero** unsound firings (Rigor's unknown carrier is `Dynamic`, not
    `Nominal[Object]`), so the tightening I proposed is dead. What it found instead is live: 125
    verdicts rest on an optimistically nil-free carrier, and `if`/`unless` elision is a **third**
    consumer of `predicate_certainty` that the spec passage does not constrain. A reproducible FP on
    master is in the issue comment.

## Next session

- **#286 is the sharpest open item** and is now ADR-shaped, not a code fix: may the `if`/`unless`
  elision rest on an optimistic nil-free carrier at all? The 2026-08-06 provenance census cut this
  from three options to **two**. "Stop the elision for non-`Constant` carriers" is **retired** — it is
  over-broad and incomplete at once: only 35 of those 134 verdicts are actually optimistic, and 12
  optimistic ones carry a `Constant` and survive it (8 are one redmine cluster where the dropped arm
  is the one that runs). What actually fires is 47 of 2,060 verdicts, 30 dropping a written arm, and
  declining exactly those is diagnostic-identical on all eleven targets **in both directions** with no
  precision regression. So: bless the status quo in the spec despite a reproducible FP whose fix
  measures as free, or decline on provenance. ADR-78 does **not** foreclose the provenance route — it
  rejected laundering a constant the engine should not have produced, not reading a deliberate value
  as proof. Harness (do not ship as-is): branch `optimistic-nil-free-provenance-census-286`.
  Censuses: `docs/notes/20260805-issue-286-*.md`, `docs/notes/20260806-issue-286-*.md`.
- **#135 checkbox 1 resumes at `analysis/check_rules.rb`** (3036 LOC, no convention spec). Scope it
  as its own arc, probably per rule-family — it is ~9× the last two files and starting it inside one
  budget produces the pile of disconnected assertions the last batch was scoped to avoid. Everything
  before it in the `analysis/` tier is swept; #135's other four checkboxes are untouched.
- **`ready-for-agent`**: #147 (**demand-gated** — its three items really are unimplemented, verified,
  but the issue waits on a concrete editor-extension author), #135's remainder, #121.
- **#121 needs a fresh candidate source.** Its whole coverage note
  (`20260522-stdlib-deterministic-module-coverage.md`) is now classified — every Math / Shellwords /
  Regexp / CGI / URI row is ✅/🔷/🚫, nothing pending. Start the next slice from a `type-scan`
  report or a real project's `Dynamic` hotspots, and **probe with `rigor type-of` rather than
  reading any table**.
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
