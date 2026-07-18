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

- **v0.3.0 nearly assembled.** #173 is **done and closed** (PR #192 auto-wire + opt-out + WD3 hint,
  ADR-93 Accepted; PR #193 fixed a File/IO `always-falsey` self-check FP found while validating).
  Milestone open: **#162** (void diagnostic — next session's focus, below) and **#121** (ongoing
  demand-gated folds, not a blocker). `[Unreleased]` holds **68** entries — the release seal is still
  pending and user-gated at the bump.
- **#194 is filed and triaged → `bug` + `needs-info`, awaiting @zonuexe.** It reports that #192's
  auto-wire regresses in-source inference (return-chain fold lost, interprocedural fold lost, a
  cross-owner singleton FP). **I could not reproduce any of it** at the issue's `b70adcb5`, at
  pre-wave `7a69f142`, or at master, with auto-wire confirmed active (rbs-inline 0.14.0,
  `require_magic_comment: false`) — the WD1 annotation-gate holds, so annotation-free files contribute
  nothing. Almost certainly an environment gap (the harness's rbs-inline version, or its oracle
  invocation). Comment asks for their rbs-inline version + exact oracle command + `rigor plugins`
  output. **Do not action #194 until the reporter replies**; when they do, move it back to
  `needs-triage` and re-evaluate. If they confirm a version whose `AnnotationParser` lets an
  annotation-free file through, the fix is gate-hardening in `Synthesizer#annotated?`.
- `make verify` / `make docs-check` clean on master; master and `origin/master` agree.

## Next session — the #162 transitive-void DESIGN PASS (ADR-100 WD4 addendum)

**Goal: produce an ADR-100 WD4 addendum that names the tier and the mechanism, so the subsequent
implementation is de-risked.** Do NOT jump straight to code — an implementation attempt this cycle was
reverted precisely because it targeted the wrong tier (details below). This is the lighter,
correctness-establishing step the user chose over implementing blind.

**What #162 wants.** The direct case shipped in #192/#187 (`static.value-use.void` fires on
`x = foo` where `foo` is author-declared `-> void`; `void_origins` side-table + the
`use-of-void-value` bleeding-edge gate, off by default). The remainder is the **transitive case**:

```ruby
class C
  #: () -> void
  def foo; end
  def bar; foo; end       # bar's own signature declares nothing
  def use; a = bar; end   # SHOULD flag static.value-use.void — void reached `a` through bar's body
end
```

**Findings from the reverted attempt (verified with `rigor type-of`, saved in
`memory/project_162_transitive_void.md` — read it first):**

1. **Wrong tier.** `infer_user_method_return` / `evaluate_body_with_returns` (the ADR-55/84 memo tier)
   are NOT exercised for a plain `a = bar` in `check`. In `ExpressionTyper#call_type_for`,
   `MethodDispatcher.dispatch` runs first and `return result if result` short-circuits, so a no-RBS
   user-instance-method return is served by **`MethodDispatcher#try_user_class_fallback`**
   (`lib/rigor/inference/method_dispatcher.rb:762`), NOT the ExpressionTyper call-site tiers
   (`try_user_method_inference` etc.) that only run after dispatch misses. The reverted patch recorded
   provenance in those ExpressionTyper tiers — they never fired.
2. **Type-propagation prerequisite.** The leaf `void → top` does not even cross the boundary as a
   TYPE: `foo`, `foo` inside `bar`, and `bar` all `type-of` as **`nil`** (their body-last expression).
   `rbs_dispatch` records the `void_origins` side-table (which fires the DIRECT diagnostic) and returns
   `top`, but the user-def / body-inference tier then WINS the type. So provenance across a method
   summary sits behind a type-precedence question too.

**Design questions the addendum must answer:**

- Where does the void-return provenance get computed and carried? Candidate: a per-`def_node`
  void-return summary populated where `try_user_class_fallback` (or whatever computes the user
  method's body-last-expr return) sees the return node is in that body's `void_origins`; consulted at
  the call site to copy the origin onto the call node's `void_origins`, so the existing
  `VoidValueUseCollector` fires unchanged. Composition (`def baz; bar; end`) should fall out of the
  same tail recording.
- Is the type-precedence gap (rbs `-> void` not winning the type over body inference) in-scope, a
  prerequisite, or orthogonal? Establish this before implementation — it may be the real work.
- FP envelope: stay behind `use-of-void-value` (off by default). Require the sole return path to be
  the void tail (no explicit non-void returns) — a method returning `top` for any other reason must
  never enter the table. The corpus gate (mail/kramdown/haml/liquid byte-identical; no new firings) is
  the acceptance check, same as #192.

Deliverable: the ADR-100 WD4 addendum (naming the tier + mechanism + FP envelope), then a scoped
implementation slice. `budget ids` (`static.incomplete-inference.*`) stay deferred to ADR-41.

## Also open, lower priority

- **#121** — ongoing FP-safe builtin/stdlib folds (demand-gated, not a release blocker).
- **Release — seal the CHANGELOG.** 68 `[Unreleased]` entries. `rigor-release-prep` is the flow;
  version bumps + `rake release` stay user-gated (AGENTS.md § Release Cadence).

## Waiting on the user / external

- **#194** — awaiting @zonuexe's harness details (above); the dependabot rubocop **PR #86** stays
  deliberately held (upstream autocorrect bug).
- **Publish the staged `ruby/rbs` upstream fix** — branch `widen-strscan-resolv-stdlib-sigs` in
  `references/rbs`; push + upstream PR are the user's action. Tracked as #159.
- The upstream `rbs-inline` RDoc fix ([soutaro/rbs-inline#249](https://github.com/soutaro/rbs-inline/pull/249))
  is open under the user's fork; nothing to do repo-side until upstream responds.
- **rigor-rs:** `rigor_rs.ruby` is reserved in our schema (ADR-99); the port implements against it,
  and its differential harness is the source of #194.
