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
  `make verify` is green on master at `9229d2a2`, verified on the INTEGRATED tree after each of this
  arc's two parallel batches (see the collision below for why that matters).
- **Landed this arc**: #303 (PR #304, argument-position `[T]` binding) · #121's final fold slice
  (PR #305, and #121 is now CLOSED — six passes, zero queued work) · #307 (mutation-harness `SpecMap`
  directory convention) · #306 (PR #314) · #313 (PR #327) · #324 (PR #328) · #308 (PR #312) and its
  repair (PR #315) · the #135 checkbox-1 specs, waves 1 and 2 (PRs #309/#310/#311/#314/#325/#326 —
  136 examples, 54 survivors closed).
- **`check_rules.rb` had never been type-checked**, and that is the arc's largest finding. Its own doc
  comment quotes `` `# rigor:disable-file all` `` in backticks, and the suppression patterns matched
  anywhere inside a comment, so the documentation file-suppressed the 3,063-line file that defines
  the rules. Found by an impossible measurement — the mutation recon's `DiagnosticOracle` killed
  **0 of 914** there against 24/24 on a control. Fixed by anchoring every marker pattern to the start
  of the comment (#306); the file is now provably live (poisoning a `Diagnostic.from_name_loc` call
  surfaces six errors). **A structurally impossible measurement is a finding, never a zero to report.**
- **#313 closed (PR #327), and its diagnosis overturned all three of the issue's premises** — worth
  knowing because the issue was mine and each premise sounded right. The single-operand form was
  never protected by the exclusion at all (it is silent only through a *syntactic* `.nil?` skip in
  the collector, so `if UNIFORM[key]` on a uniform-valued table fired with no composition involved);
  the branch elision was laundered too and that is the damaging half (`x.nil? ? "missing" : "found"`
  typed `"found"`, deleting the arm a miss takes); and a `Constant`-only gate is not the protection
  the spec assumed, because a uniform-valued table reads as a lone `Constant` — `[UNIFORM[k] || 9]`
  typed `[1]`. **That last one lives only on the `ExpressionTyper` path**; the statement path keeps
  the union, which is why a first probe reads clean. #152 was not the regression point: it landed no
  code. `OptimisticOrigin.resolve` now owns the judgment for all three consumers.
- **Two correct-in-isolation PRs collided and turned master red.** PR #310 pinned #308's
  then-current broken behaviour; PR #312 fixed #308. Disjoint files, no conflict, both green, red on
  merge. Two habits follow: a spec pinning known-wrong behaviour MUST carry an in-place "flip this
  when #N is fixed" comment (PR #310's did — the repair was one line), and **after merging a parallel
  batch, run the suite on the integrated master**, which is the only place such a collision surfaces.

## Next session

- **`check_rules.rb` is DONE: 100 % fused protection, zero survivors** — the re-measure landed
  (`docs/notes/20260809-check-rules-mutation-remeasure.md`). The recon's 70 de-noised survivors split
  56 killed by the now-live type axis and 18 by waves 1–2's examples, with **none surviving both**, so
  **no wave 3**. Note the number is not the interesting part: 100 % is also the shape a broken harness
  takes, which is why the note carries negative controls (an identity mutant and an env-gated poison
  both correctly report SURVIVED) and an independent second-seed run. Every earlier funnel figure on
  #135 is superseded. `--site all` (~914 sites ≈ 6.1 h of rspec) stays unmeasured — ~745 sites, with
  the per-family inventory in the note, since it was in no issue comment.
- **#135's remaining work is the OTHER giant files** the issue body lists that PRs #282/#287/#289 did
  not sweep, plus its four untouched checkboxes. `check_rules.rb` needs nothing further.
- **`ready-for-agent`**: #329 (write the ADR-58 provenance contract into the binding corpus — it now
  governs four rules and is stated normatively nowhere, which is precisely how #324's drift happened),
  #147 (**demand-gated** — its three items really are unimplemented, verified, but the issue waits on
  a concrete editor-extension author), #135's remainder.
- **The spec suite leaks `Dir.mktmpdir` directories** into `/tmp/nix-shell.*` (`rigor-spec-{cache,
  workspace,sig}-*`, `rigor-scanner-spec-*`, `rigor-plugin-spec-cache-*`, `rigor-mutant-*`). One
  `make test` leaves ~25 entries / ~86 MB; a fused mutation census leaves ~1 GB. 1,482 stale dirs had
  accumulated and produced a real `Errno::ENOSPC` mid-session, which fails specs in a shape that reads
  as unrelated flake. The durable fix is block-form `Dir.mktmpdir`; until then, sweep stale
  `/tmp/nix-shell.*` dirs whose entries are all `rigor-`-prefixed.
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
- **A structurally impossible measurement is a finding, never a zero to report.** `DiagnosticOracle`
  killing 0 of 914 mutants against 24/24 on a control is not a protection figure — it is the tell
  that the subject was not being checked at all (#306). The same instinct inverts: **100 % is also
  the shape a broken harness takes**, so the re-measure that reported it had to carry negative
  controls (an identity mutant and an env-gated poison, both correctly SURVIVED) before the number
  meant anything. Neither extreme is evidence until the instrument can produce the opposite answer.
- **A spec that deliberately pins known-wrong behaviour is a dependency on that behaviour staying
  wrong.** It MUST carry an in-place "flip this when #N is fixed" comment. PR #310's did, #308 was
  fixed independently, the two collided on merge and turned master red, and the comment made the
  repair one line. Before briefing parallel agents, check the open issues for anything that would
  invalidate a premise one of them is about to encode.
- **Ask the provenance question in ONE place.** #324 was two rules spelling the same ADR-58 lookup
  differently and drifting apart. The fix's value is the shared predicate, not the widening — and
  #329 exists because the contract it encodes is still stated normatively nowhere.
- **The gate's exit code, not the pipeline's.** `make docs-check | tail -2` reports `tail`'s status;
  I pushed a handoff that failed its own line-cap gate that way. Check gates unpiped.
