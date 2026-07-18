<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward. Two recent saves: #194's "auto-wire regresses in-source
  inference" was withdrawn once root-caused (an installed-gem/checkout plugin version skew, not an
  engine bug), and the #162 tier attribution in an early memory was a `rigor type-of` artifact (that
  command builds the environment without the plugin registry — pitfall 4 in the probe-pitfalls memory).
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Where things stand

- **#162 transitive-void: the DESIGN PASS is done, implementation is next.** The ADR-100 WD4 addendum
  (`docs/adr/100-static-diagnostic-family-and-void-origins.md` § "Addendum — WD4", commit `2ffa3b40`)
  names the tier and the mechanism. **Read that addendum, not the memory prose, for the design.**
- **#194 root-caused and re-scoped** (now `bug` / `ready-for-human` / `area:plugins`). The reported
  engine regressions were **withdrawn**: they came from an **engine↔plugin version skew** — a newer
  engine (git checkout) with an older `rigortype` gem installed, where the auto-wire's
  `require "rigor-rbs-inline"` resolved to the *gem's* plugin copy, which predates the WD1 `annotated?`
  gate and synthesizes untyped skeletons for every file. #192's auto-wire introduced this silent path.
- #121 (ongoing demand-gated folds) still open, not a blocker. `[Unreleased]` holds **68** entries;
  release seal still pending and user-gated at the bump.
- `make verify` / `make docs-check` clean on master; master and `origin/master` agree.

## Next session — pick one

**Track 1 — #162 implementation slice (design settled, ready to build).** Implement the ADR-100 WD4
addendum's mechanism: a lazy per-`def_node` **VoidTail summary** (`VoidTail(def_node) → VoidOrigin |
none`), consulted at the `MethodDispatcher.dispatch` choke point so it fires **result-independently**
across BOTH serving tiers the addendum identified (RbsDispatch answering a synthesized `untyped`
skeleton under auto-wire; `ExpressionTyper#try_user_method_inference` answering a re-typed body under a
partial `sig/`). The summary must be **pure** (AST shape + RBS reflection + discovery-index only, no
expression evaluation → no dispatch re-entry, order-independent, fork-pool-safe — an eager
record-at-body-evaluation table was rejected for exactly that). Admission gate, FP envelope
(`use-of-void-value` bleeding-edge, off by default), and the corpus gate (mail/kramdown/haml/liquid
byte-identical; herb no new firings) are all in the addendum. Reuse the shipped direct-case
`void_origins` side-table + `VoidValueUseCollector` unchanged.

**Track 2 — #194 the auto-wire version-skew guard (`ready-for-human`).** #192 made the engine
`require` a bundled plugin *by gem name* every run, so a stale installed `rigortype` can silently win.
Three parts, effort-ordered (the issue comment has the full framing):

- **Split as a `ready-for-agent` slice:** print each loaded plugin's **resolved file path** in
  `rigor plugins` and in the `plugin_loader.load-error` diagnostic (the plugin's own `v0.1.0` constant
  never moves, so today both the correct and the skewed load read identically).
- **The real fix (human design call):** auto-wire should prefer the **engine's own bundled
  `plugins/`** over gem resolution — decide how the engine locates its bundled dir robustly across
  install modes (git checkout, installed `rigortype` gem, ADR-27 single-binary) without reopening the
  ADR-27/31 auto-load concerns the WD2 gate guarded.
- Follow-on: `doctor` flags "plugin loaded from a different `rigortype` installation than the engine."

## Also open, lower priority

- **#121** — ongoing FP-safe builtin/stdlib folds (demand-gated, not a release blocker).
- **Release — seal the CHANGELOG.** 68 `[Unreleased]` entries. `rigor-release-prep` is the flow;
  version bumps + `rake release` stay user-gated (AGENTS.md § Release Cadence).

## Waiting on the user / external

- The dependabot rubocop **PR #86** stays deliberately held (upstream autocorrect bug).
- **Publish the staged `ruby/rbs` upstream fix** — branch `widen-strscan-resolv-stdlib-sigs` in
  `references/rbs`; push + upstream PR are the user's action. Tracked as #159.
- The upstream `rbs-inline` RDoc fix ([soutaro/rbs-inline#249](https://github.com/soutaro/rbs-inline/pull/249))
  is open under the user's fork; nothing to do repo-side until upstream responds.
- **rigor-rs:** `rigor_rs.ruby` is reserved in our schema (ADR-99); its differential harness surfaced
  #194 and will re-pin the oracle onto the checkout plugin path.
