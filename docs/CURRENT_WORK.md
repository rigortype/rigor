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

- **v0.3.0 is nearly assembled.** PRs #175 #179–#187 all merged; the CI cache-validation follow-ons
  (#188–#191, `cache.validation: auto` strict-in-CI) landed after them. Milestone open:
  **#173** (rbs-inline auto-wire — now in **PR #192**, see below), **#162** (void diagnostic:
  transitive / ancestor-fallback case + budget ids remain), **#121** (ongoing fold category,
  demand-gated). `[Unreleased]` holds ~96 bullets — sealing them is the release step `make verify`
  cannot rescue; budget for it.
- **PR #192 is open and awaiting review** ([link](https://github.com/rigortype/rigor/pull/192)):
  ADR-93 WD2 + WD3 — auto-wire the bundled `rigor-rbs-inline` plugin from `Configuration.load` when
  the upstream library is resolvable, the `enabled: false` opt-out (new `pluginEntry` schema key),
  and the WD3 `rbs.coverage.inline-annotations-unsynthesized` `:info` for standalone installs. ADR-93
  moved to **Accepted**. Verified this session: `make verify` (8098 ex, 0 fail), `make docs-check`
  (270), corpus gate (mail/kramdown/haml/liquid byte-identical; herb keeps its −3 wins). On merge,
  #173 closes and only #162 + #121 remain on the milestone.
- **Known pre-existing self-check FP** (NOT introduced by PR #192; reproduces on `master` with the
  branch stashed): `make check` emits `lib/rigor/cli/doctor_command.rb:279:26: warning: condition is
  always falsey` — `rubygems_sourced_rigortype?` can genuinely return `true`, so this is an inference
  FP. `make check` exits 0 (warnings don't fail the gate), which is why it went unnoticed, but
  AGENTS.md wants check clean. Fix at root (engine), never by editing doctor_command.rb. Spawned as a
  background task this session.

## Next session — in this order

**1. Review/merge PR #192** (the #173 auto-wire). Note at review: `spec_helper` pins
`Configuration.rbs_inline_library_resolvable?` off suite-wide (mirroring the `RIGOR_CI_DETECT` pin) —
left live, auto-wire would inject the plugin into nearly every in-process `rigor check`, and the
suite's `Plugin.unregister!` + require-once semantics would surface a spurious
`plugin_loader.load-error` against the emptied registry (a suite artifact — a real `rigor` process
loads it cleanly, verified e2e). Specs that exercise the auto-wire tag `:rbs_inline_autowire`.

**2. #162 remainder** — the void diagnostic's base case landed in #187 (`static.value-use.void`,
direct-dispatch only). What remains: the transitive / ancestor-fallback case (ADR-100 WD4) and the
budget ids. Engine-side precision work.

**3. Release — seal the CHANGELOG.** ~96 `[Unreleased]` bullets. The `rigor-release-prep` skill is
the flow; **version bumps and `rake release` stay user-gated** — land entries, stop, and let the
user drive the cut-over (AGENTS.md § Release Cadence).

## Decided this cycle — do not re-litigate

- **ADR-93 fully resolved** (PR #192): WD1 flip (#186), WD2 auto-wire + `enabled: false` opt-out,
  WD3 `:info` hint. The opt-out shape (`pluginEntry.enabled`) was maintainer-decided 2026-07-18 over
  a dedicated top-level key and a `disable_plugins:` list.
- **#152** (widen `&&`/`||` polarity) evidence-rejected, demand-gated, off the milestone. **#126**
  (length-range carrier): its own design pass says don't build; demand-gated. **#120**
  (`--incremental` default): opt-in this cut; the one human call left is ADR-45-cache vs incremental
  precedence. **#178** closed as intended behaviour (`5d5a9359`). **#155** already-implemented since
  `01491c63`.
- **#130 deferred remainder** (RBS-only ancestors + singleton) needs a corpus FP-acceptance decision
  first — it would fire on user overrides of library methods. Slice 5 stays blocked by #156.

## Waiting on the user

- **Review/merge PR #192** (rbs-inline auto-wire, above) and the dependabot rubocop **PR #86** stays
  deliberately held (upstream autocorrect bug).
- **Publish the staged `ruby/rbs` upstream fix** — branch `widen-strscan-resolv-stdlib-sigs` in
  `references/rbs`; push + upstream PR are the user's action. Tracked as #159.
- The upstream `rbs-inline` RDoc fix ([soutaro/rbs-inline#249](https://github.com/soutaro/rbs-inline/pull/249))
  is open under the user's fork; nothing to do repo-side until upstream responds.
- **rigor-rs:** `rigor_rs.ruby` is reserved in our schema (ADR-99); the port implements against it.
