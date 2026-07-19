<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward. Recent saves: the #162 tier attribution was a
  plugin-blind `rigor type-of` artifact (fixed at root by #196); the "provenance-quality next
  iteration" idea was already adjudicated spent by ADR-82's own Consequences; and the WD6
  trans-method taint concern was discharged by a direct probe (param-sourced ivars stay Dynamic —
  no FP surface, no hardening slice needed).
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Where things stand

- **The 2026-07-19 survey iteration ("typing gaps → engine improvement → perf verification") is
  complete: two slices landed.** A three-codebase protection scout (mastodon, redmine, rails core;
  raw JSON in the session scratchpad, conclusions in the ADR addenda) established that ADD_RBS is
  ~1-2% everywhere, `unsupported_syntax` is a catch-all (not real syntax gaps), and the dominant
  correctly-attributed engine gap is untyped params + param-sourced ivars.
  - **PR #201** (merged) — ADR-58 WD5: constructor massign ivar targets now credit `init_writes`,
    removing a spurious declaration-sourced `nil` that masked typed massign ivars. Corpus
    byte-identical; +21 protected sites (mastodon models +7, redmine app +14); perf flat.
    `||=` seeding measured and deferred with reason (zero protection movement).
  - **PR #202** (merged) — ADR-67 WD6: check-walk activation of call-site parameter inference
    behind the opt-in `parameter_inference:` config (off by default). Inferred-param provenance
    mark guards ALL negative in-body rules (3-piece guard: syntactic root-walk, sticky local
    taint, union join). Gate-off byte-identical + zero cost; gate-on zero new firings on six
    corpus targets + one genuine redmine FP removed; **+46 (mastodon models) / +110 (redmine app)
    protected sites**; opt-in price ≈0.9s pre-pass (+40% wall on mastodon models) — why the
    default stays off (ADR-50 gates any flip).
- **#162 and #194 are DONE and closed** (earlier today): transitive `static.value-use.void` via
  `VoidTailSummary` (ADR-100 WD4 addendum, PRs #195), probe environment parity (#196), and the
  auto-wire version-skew guard (ADR-93 WD5, PRs #197/#198/#200 — remember: merge stacked PRs
  bottom-up; #199's mis-merge was re-landed as #200).
- **v0.3.0 milestone: only #121 (demand-gated folds, non-blocker) remains open.** The user has
  started launch prep (`d88effca`, website-showcase inference-example inventory note).
- `make verify` / `make docs-check` clean on the post-merge master.

## Next session — the release seal (the launch prep signal makes this the move)

`[Unreleased]` holds **75** entries and the user is drafting v0.3.0 launch material. Run
`rigor-release-prep` up to (not including) the version bump and present the seal for approval;
version bumps + `rake release` stay user-gated (AGENTS.md § Release Cadence, single-digit version
components).

## Queued iteration follow-ups (after the release, demand-gated)

- **ADR-46 edge wiring for `parameter_inference:`** — lift the WD6c `--incremental` mutual
  exclusion by recording caller→callee-param cross-file edges.
- **WD6 pre-pass cost** — the 0.9s collector round on mastodon models is the opt-in price;
  worth a perf pass only if adoption demands it.
- **WD6 default-on** — an ADR-50 decision on accumulated evidence (mutation-oracle honesty check
  included); not before.

## Also open, lower priority

- **#121** — ongoing FP-safe builtin/stdlib folds.
- `static.value-use.top`, `static.incomplete-inference.*` (ADR-100/ADR-41/#158) stay reserved.

## Waiting on the user / external

- The dependabot rubocop **PR #86** stays deliberately held (upstream autocorrect bug).
- **Publish the staged `ruby/rbs` upstream fix** — branch `widen-strscan-resolv-stdlib-sigs` in
  `references/rbs`; push + upstream PR are the user's action. Tracked as #159.
- The upstream `rbs-inline` RDoc fix ([soutaro/rbs-inline#249](https://github.com/soutaro/rbs-inline/pull/249))
  is open under the user's fork.
- **rigor-rs:** `rigor_rs.ruby` reserved in our schema (ADR-99); harness re-pinned, battery clean.
