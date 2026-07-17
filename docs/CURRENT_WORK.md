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
  follows is what it *earns*, not what unblocks it.
- The line is **evaluation** (ADR-50): outside feedback + completing the feature set toward the
  v1.0.0 freeze. The protection ceiling is a measured floor (ADR-67 WD2 spiked and deferred — do not
  re-recommend it).
- **The cut is now decided (triaged 2026-07-17).** v0.3.0's axis is **type-inference quality**: 13
  issues. LSP/editor work moved to a new **`v0.4.x`** milestone — improved gradually across the
  series, not pinned to one cut. 27 issues stay unmilestoned; that is the healthy resting state for
  demand-gated work, not a backlog to drain.
- `make verify` and `make docs-check` clean; master and `origin/master` agree.

## Next session — implement, then release

**1. Implement the v0.3.0 set.** `gh issue list --milestone v0.3.0`. Four are `ready-for-agent`
(specified enough to start with no human context — named injection point, constraint envelope, and
the gate that proves it done): **#121** (FP-safe builtin/stdlib folds — the `rigor-type-coverage-uplift`
skill is the procedure), **#131** (Data/Struct value folding), **#155** (subclass-aware gating for
`call.self-undefined-method`), **#174** (correct ADR-94 WD2 — a docs fix, see below).

The rest need a decision before code. Three are design-first and have no carrier or mechanism today:
**#172** (`Regexp.last_match` match-success narrowing), **#126** (length-range carrier), **#152**
(widen the `&&`/`||` polarity gate past Constant-only). Two touch the ADR-50 v1.0-frozen diagnostic
vocabulary, so their rule ids and default severities are deliberate choices, not implementation
details: **#161** (a total RBS env-build failure currently exits 0 with `Dynamic[top]` project-wide
and no diagnostic) and **#162** (the `static.*` family + a `void_origins` side-table). **#120**
(mature `--incremental` toward default-capable) is the perf headline; its acceptance bar already
exists — `--verify-incremental` (incremental == full `--no-cache`, byte-identical), wired into CI.

**2. Release — and budget for the CHANGELOG.** `[Unreleased]` holds **55 bullets, 39 of them
multi-sentence**. Sealing them is the highest-value, most-skipped step of `rigor-release-prep`, it
needs cycle-wide context, and it is the one release step `make verify` cannot rescue. Measured
2026-07-17; plan for it rather than discovering it at the cut. **Version bumps and `rake release`
stay user-gated** — land entries, stop, and let the user drive the cut-over (AGENTS.md § Release
Cadence).

## The rbs-inline chain — ordering is load-bearing

Three issues, and the order is a protocol requirement rather than a preference:

**#172 → #173.** ADR-93 WD1a: the 4 `call.possible-nil-receiver` that the ADR-93 default flip
surfaces on herb are a *pre-existing* `Regexp.last_match` imprecision, masked until now by herb's
`-> untyped` sigs. Per the ADR-57 protocol an artifact is fixed at root **before** the change that
surfaces it lands, so #172 is a prerequisite of #173, not a follow-up.

**#173 is the user's call, not an agent's.** Flipping ADR-93's `require_magic_comment:` default is
the mechanical part; WD2 (default-wiring the bundled plugin) is a partial reversal of the
ADR-27/ADR-31 auto-load deferral, and its opt-out schema is open — the plugin-entry schema has no
`enabled:` key, and ADR-99 now makes the JSON schema a named source of truth. WD3 (the standalone
residual) is a second open choice. ADR-93 is still **Proposed**; accepting it is part of the work.

**#174 is a documentation fix, and the tree is the evidence.** ADR-94 WD2 claims the arity path in
`Analysis::CheckRules` does not guard `RBS::Types::UntypedFunction`. It does — `arity_eligible?` and
`argument_check_eligible?` both bail via `respond_to?(:required_keywords)`, with a comment naming the
form and calling the bail the correct conservative move. Both predate the ADR (in place by
2026-05-02; re-verified 2026-07-17). ADR-94's Status block still leads with that phantom blocker, so
it misleads anyone sizing the ADR-93 work — fix the text, do not touch the guards.

Standing context: ADR-94 records that rbs 4.0 absorbed the reader (`RBS::InlineParser`), which would
retire WD2 and WD3 outright. That migration is deferred behind the `rbs >= 3.0, < 5.0` floor
(ADR-79) and is **not** planned for v0.3.0.

## Known couplings inside the milestone

- **#130's slice 5 is blocked by #156**, which stayed unmilestoned on purpose — its own text says it
  is gated on general return-inference precision, so there is nothing to schedule there yet. v0.3.0
  carries only #130's two unblocked follow-ons (WD9 generic-instantiation comparison; RBS-only
  ancestors + `def self.` coverage). Note posted on the issue.
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
