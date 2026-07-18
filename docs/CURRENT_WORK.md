<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward. Two recent saves: #194's "auto-wire regresses in-source
  inference" was withdrawn once root-caused (an installed-gem/checkout plugin version skew, not an
  engine bug), and the #162 tier attribution in an early memory was a `rigor type-of` artifact —
  since fixed at the root by #196, which gave the probes check's plugin-aware environment.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Where things stand

- **#162 is DONE and closed.** The ADR-100 WD4 addendum (`2ffa3b40`) named the two serving tiers and
  the mechanism; PR #195 (merged, `2c7b68e5`) implemented it: transitive `static.value-use.void` via
  the lazy, pure, per-def `Inference::VoidTailSummary`, consulted result-independently from the
  `MethodDispatcher.dispatch` wrapper. Corpus gate mail/kramdown/haml/liquid byte-identical, zero new
  bleeding-edge firings; still behind `use-of-void-value` (off by default). Promotion to a default
  profile is a separate, evidence-gated decision (ADR-50 WD1).
- **PR #196 (merged, `48a26c20`) fixed the probe/check environment asymmetry** that had misled the
  #162 design: `type-of` / `type-scan` / `trace` / `annotate` now build the plugin-aware environment
  through `CLI::ProbeEnvironment` (loader-only — no producer-plugin pre-pass), so probes see ADR-93
  auto-wire synthesis. `coverage_scan` was deliberately left (measurement surface, baselines would
  shift).
- **v0.3.0 milestone: only #121 (ongoing demand-gated folds, not a blocker) remains open.** The
  release seal is the real remaining work: `[Unreleased]` holds **70** entries; `rigor-release-prep`
  is the flow; version bumps + `rake release` stay user-gated (AGENTS.md § Release Cadence).
- **#194 (auto-wire version skew): designed and implemented, awaiting merge.** The user chose the
  uniform rule — ALL engine-bundled plugins anchor to the engine, not just the auto-wired one —
  recorded as the ADR-93 WD5 addendum (`8e75fa9f`); the three slices are the stacked PRs below.
  (Background: a stale installed `rigortype`'s plugin copy, predating the WD1 `annotated?` gate,
  could silently win gem-name resolution whenever the engine ran without its own gemspec
  activation.)
- `make verify` / `make docs-check` clean on the post-merge master; master and `origin/master` agree.

## Next session — merge the #194 stack, then the release seal

**The #194 wave is implemented as three stacked PRs, verified and CI-green, awaiting the user's
merge in order #197 → #198 → #199** (each PR body states its base; #199 carries `Closes #194`):

- **#197** (`194-plugin-resolved-path`) — slice 1: resolved-path visibility in `rigor plugins`
  (text + JSON `"path"`) and `(loaded from <path>)` on post-require load-error diagnostics.
  Adds the `Registry#resolved_gem_paths` public reader (API-drift snapshot updated).
- **#198** (`194-bundled-plugin-anchor`) — slice 2, the fix, per the **ADR-93 WD5 addendum**
  (`8e75fa9f`): every engine-bundled plugin is required by its engine-anchored absolute path
  (`Loader.bundled_plugin_path`), gem-name fallback when absent; the `requirer` seam widens to
  name-or-path.
- **#199** (`194-doctor-plugin-skew`) — slice 3: `doctor` warns when a bundled plugin resolved
  outside the engine's tree. **One open call:** it reports at `:warn` (deliberate deviation from
  #116's `:fail` — path comparison is fuzzier than a lockfile parse and must not flip CI); flip to
  `:fail` is one line if preferred.

After the merge: **the release seal.** `[Unreleased]` will hold 73 entries; `rigor-release-prep`
is the flow; version bumps + `rake release` stay user-gated (AGENTS.md § Release Cadence).

## Also open, lower priority

- **#121** — ongoing FP-safe builtin/stdlib folds (demand-gated, not a release blocker).
- The `static.value-use.top` sibling diagnostic and the `static.incomplete-inference.*` budget ids
  stay reserved (ADR-100 / ADR-41 / #158) — do not start them without a demand signal.

## Waiting on the user / external

- The dependabot rubocop **PR #86** stays deliberately held (upstream autocorrect bug).
- **Publish the staged `ruby/rbs` upstream fix** — branch `widen-strscan-resolv-stdlib-sigs` in
  `references/rbs`; push + upstream PR are the user's action. Tracked as #159.
- The upstream `rbs-inline` RDoc fix ([soutaro/rbs-inline#249](https://github.com/soutaro/rbs-inline/pull/249))
  is open under the user's fork; nothing to do repo-side until upstream responds.
- **rigor-rs:** `rigor_rs.ruby` is reserved in our schema (ADR-99); its differential harness surfaced
  #194 and will re-pin the oracle onto the checkout plugin path.
