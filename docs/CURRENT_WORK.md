<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward. Three items died of this in one week: a "live bug, do
  this first" refuted by its own repro (guarded since 2026-05-01), an "open" AR-lambda item fixed
  since 2026-05-28 (`fde760a2`), and ~40% of the old ROADMAP backlog already shipped.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Where things stand

- **v0.2.9 published 2026-07-11.** master accumulates toward **v0.3.0**. Both mandatory pieces are
  done (deprecation clearance #94, perf recalibration #95), so the cut is already shippable — what
  follows is what it *earns*.
- **v0.3.0's axis is type-inference quality** (triaged 2026-07-17): 14 issues, 7 `ready-for-agent`.
  LSP work lives in **`v0.4.x`** — improved gradually across the series, not pinned to one cut. 28
  issues stay unmilestoned; that is the healthy resting state for demand-gated work, not a queue.
- `make verify` and `make docs-check` clean; master and `origin/master` agree.

## Next session — implement, then release

**1. Implement the v0.3.0 set.** `gh issue list --milestone v0.3.0`. Seven are `ready-for-agent`.
Four were found on 2026-07-17 and are fresh, verified, and specified:

- **#176** — a **false positive**, so it outranks the rest: `arr.clear` does not widen the
  `non-empty-array` refinement, so `arr.size == 0` reports always-falsey on code that is true at
  runtime. **Being worked in a separate local session as of this writing — check before assigning.**
- **#178** — a normative-spec violation: a constant hash indexed with a non-static key folds to a
  nil-less union, where the shape tier MUST defer so the `Hash#[] -> V?` projection applies.
- **#177** — `$+` is bound to `String` on every truthy match edge but is nil when a successful
  match's groups are all optional. False-negative side; small.
- **#172** — see the rbs-inline chain below.

The other three: **#121** (FP-safe builtin/stdlib folds — the `rigor-type-coverage-uplift` skill is
the procedure), **#131** (Data/Struct value folding), **#155** (subclass-aware gating for
`call.self-undefined-method`).

The rest need a decision first. **#126** (length-range carrier) has a design pass attached whose own
recommendation is *don't build it* — thin yield, and the common upper-bound idiom mutates the
receiver inside its own guard; #176 is the prerequisite it surfaced, and stands alone. Two touch the
ADR-50 v1.0-frozen diagnostic vocabulary, so their rule ids and default severities are deliberate
choices: **#161** (a total RBS env-build failure exits 0 with `Dynamic[top]` project-wide and no
diagnostic) and **#162** (the `static.*` family + a `void_origins` side-table). **#120** (mature
`--incremental` toward default-capable) is the perf headline; its acceptance bar already exists —
`--verify-incremental` (incremental == full `--no-cache`, byte-identical), wired into CI.

**2. Release — and budget for the CHANGELOG.** `[Unreleased]` holds **56 bullets**. Sealing them is
the highest-value, most-skipped step of `rigor-release-prep`, it needs cycle-wide context, and it is
the one release step `make verify` cannot rescue. Plan for it rather than discovering it at the cut.
**Version bumps and `rake release` stay user-gated** — land entries, stop, and let the user drive the
cut-over (AGENTS.md § Release Cadence).

## The rbs-inline chain — ordering is load-bearing

**#172 → #173.** Per ADR-93 WD1a and the ADR-57 protocol, the artifact the ADR-93 default flip
surfaces on herb is fixed at root **before** the flip lands.

**#172 is `ready-for-agent`, and its original framing was wrong.** It claimed two soundness calls had
no design; both landed 2026-06-12 (`0cfa4f55`, `b6affe87`). The real gap is one recognition upgrade —
the pattern operand is matched only as a syntactic `Prism::RegularExpressionNode`, while herb's is a
constant the typer already folds to a value-pinned `Constant[Regexp]`. Validated with a throwaway
patch: herb 12 → 8 diagnostics, the −3 wins kept, four corpora byte-identical. Full brief on the
issue.

**#173 is the user's call, not an agent's.** The default flip is mechanical; WD2 (default-wiring the
bundled plugin) is a partial reversal of the ADR-27/ADR-31 auto-load deferral with an open opt-out
schema, and WD3 (the standalone residual) is a second open choice. ADR-93 is still **Proposed**.

Standing context: ADR-94 records that rbs 4.0 absorbed the reader (`RBS::InlineParser`), which would
retire WD2 and WD3 outright. Deferred behind the `rbs >= 3.0, < 5.0` floor (ADR-79); **not** planned
for v0.3.0. ADR-94's WD2 text was corrected 2026-07-17 (PR #175) — its "live crash" named the wrong
site, symptom, and trigger, though the defect was real and is now fixed.

## Decided this cycle — do not re-propose

- **#152 (widen the `&&`/`||` polarity gate) is evidence-rejected and demand-gated**, deliberately
  off v0.3.0. The measured evaluation is on the issue: zero drift across a 14-project corpus, the
  widened edges fired **once** in the whole corpus, and that firing would have made the type *wrong*
  — it rests on the #178 over-fold. `a || b` is the idiom by which an author hedges against exactly
  the optimism the lattice contains; ADR-78 WD1 drew this line once already. Re-open only on a demand
  signal, and read the issue's preconditions first. Two findings outlive the rejection: **nothing in
  the 7976-example suite pins the changed edges**, and the widening would re-create the b7c155fb
  two-typer divergence.
- **#130's slice 5 is blocked by #156**, unmilestoned on purpose — its own text says it is gated on
  general return-inference precision. v0.3.0 carries only #130's two unblocked follow-ons.
- **#162 creates the `static.*` family that #158 (v1.0.0, inference budgets) reserves its cutoffs
  under.** Family first is the right order; #158 stays demand-deferred either way.

## Waiting on the user

- **Publish the staged `ruby/rbs` upstream fix** — branch `widen-strscan-resolv-stdlib-sigs` in
  `references/rbs` (widens `StringScanner#[]`, `Resolv#initialize`); push + upstream PR are the
  user's action. Tracked as #159, deliberately unmilestoned: it cannot ship in our cut.
- The upstream `rbs-inline` RDoc fix ([soutaro/rbs-inline#249](https://github.com/soutaro/rbs-inline/pull/249))
  is open under the user's fork; nothing to do repo-side until upstream responds.
- **rigor-rs:** the reserve pipeline (ADR-99) has its first reservation — `rigor_rs.ruby` is declared
  in our schema, so the port can implement against it and its vendored copy stops rejecting its own
  key on the next submodule bump.
