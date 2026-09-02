# ADR-47 — Narrowing-driven clause reachability (`flow.unreachable-clause`)

Status: **Accepted — WD1 + WD2 + WD3a + WD5 implemented. Extends Rigor's two existing `if`/`unless` reachability rules to `case`/`when` AND `case`/`in` clauses, using the narrowing the flow engine already computes. WD5 runs the mirror direction — an `if`/`unless` arm a decidable version guard deselects is unreachable, and reports nothing. Inspired by Elixir v1.20's redundant-`case`-clause reporting; scoped to stay inside Rigor's false-positive envelope.**

**WD1 landed (v0.1.17).** `flow.unreachable-clause` fires when a `case <local>` clause's class/module-constant condition (`when String` / `when MyClass`) narrows the subject to `Type::Bot` — read back from `scope_index` (the evaluator's own per-clause `body_scope`), so the rule and the body typing cannot diverge. The single `body_scope == bot` signal covers both shapes the design names (per-clause disjointness AND prior-exhaustion) since an exhausted entry scope narrows to `bot` too. FP envelope enforced: subject must be a narrowing local, never `Dynamic` (gradual guarantee) nor already-`Bot` (dead code), class/module-constant conditions only (`when nil` / ranges / regexps / expressions excluded), clauses inside loops/blocks skipped. Per **WD4**, it ships at `:info` in lenient + balanced (the default) and `:warning` only in strict, pending the regression-corpus FP gate before any balanced→`:warning` promotion; clean (zero firings) on Rigor's own `lib` + `plugins` + `examples`.

**WD2 landed (v0.1.17).** Message precision + a dead trailing `else`. A dead `when` is now worded `:prior_exhaustion` ("already covered by an earlier `when'") vs `:disjoint` (the WD1 wording), told apart by the scope ENTERING the clause: `eval_case_when_branches` records that entry `falsey_scope` on the clause's first condition node (`on_enter`-only, no new typing; `propagate` preserves it) and the collector classifies on whether the subject was already `bot` there. A trailing `else` whose final falsey scope narrows the subject to `bot` is flagged as `:exhausted_else` — EXCEPT a defensive `else` body (a bare `raise`/`fail`/`throw`/`abort`/`exit`), skipped because it is a deliberate guard, not removable dead code. Still clean on Rigor's own corpus; same `:info`/`:warning` severity posture.

**WD3a landed (v0.1.17).** `case`/`in` (a `CaseMatchNode`) for **bare class patterns** only — `in C` / `in C => x`, whose match is exactly `C === subject` (pure `is_a?`, no deconstruction). Those narrow soundly like `when C`, so `eval_case_when_branches` now routes a bare-class `in` through `Narrowing.case_when_scopes` (body narrowed to `C`, falsey with `C` removed); every other pattern (value, array / hash / find, capture-with-deconstruction, bare variable) keeps the conservative "body = entry + bindings, falsey unchanged" shape, because deconstruction can fail even when the class test passes (removing anything from the falsey scope would be unsound). The collector flags a dead `in` clause on the same `body_scope == bot` signal, classifying disjoint vs prior-exhaustion exactly as for `when`; a non-class `in` clause can therefore only fire under prior-exhaustion (an earlier covering set), never a spurious disjoint. Clean on Rigor's own corpus. **WD4 run (v0.1.17).** Swept 16 OSS corpora (see [`docs/notes/20260605-adr47-unreachable-clause-corpus-sweep.md`](../notes/20260605-adr47-unreachable-clause-corpus-sweep.md)) — zero firings, zero false positives. A vacuous pass (no hits to triage) is not positive evidence for a louder default, so **balanced stays `:info`** (strict keeps `:warning`); promotion waits for a real firing. **Remaining:** WD3b (deconstructing / value / variable-catch-all pattern exhaustiveness — the genuinely larger, ADR-36-`is_a?`-exhaustiveness-neighbour project; do NOT infer it ad hoc; lowered priority by the zero-firing sweep).

**WD5 landed.** Version-guard arm reachability ([#627](https://github.com/rigortype/rigor/issues/627)). A guard that compares the running Ruby (or a default gem's version) against a literal is decidable, and the arm it deselects is dead on the Ruby the user is checking with — so a diagnostic there is a false positive, not a worst-case reading. `Inference::VersionGuard.verdict` decides `RUBY_VERSION <cmp> "x.y.z"` (String semantics, because that is what runs), `Gem::Version.new(a) <cmp> Gem::Version.new(b)` (both sides wrapped), `RUBY_ENGINE ==`/`!=`, and `X::VERSION` for default gems of the running Ruby; everything else keeps both arms live. `StatementEvaluator` elides the dead arm exactly as it does for `if false` (no evaluation, so no writes join past the `if`), and `CheckRules::DeadVersionGuardArms` re-asks the same pure function at diagnosis time to drop the diagnostics inside it. `flow.always-truthy-condition` deliberately does NOT fire on the guard — a version guard is intentional. Normative surface: [control-flow-analysis.md § Version-guard condition folding](../type-specification/control-flow-analysis.md#version-guard-condition-folding).

## Motivation

The Elixir v1.20 type system (see
[`docs/notes/20260604-elixir-v1.20-type-system-rigor-review.md`](../notes/20260604-elixir-v1.20-type-system-rigor-review.md))
refines the scrutinee type across `case` clauses and **reports clauses
that can never match as dead code** — a high-signal, low-false-positive
diagnostic class, because a clause the type proves unreachable is almost
always a real logic error (stale `when`, mis-ordered clauses, a type that
moved out from under a branch).

Rigor already does the hard half of this work. What it is missing is the
diagnostic on top of it, and only for `case` — `if`/`unless` are already
covered.

## What exists today

Two reachability rules, both restricted to `IfNode` / `UnlessNode`:

1. **`flow.unreachable-branch`** (v0.1.2) — fires only when the predicate
   is a **syntactic literal** (`if false`, `expr if true`, …). Points at
   the dead branch. Deliberately literal-only to avoid the inferred-
   constant false positives named in
   [`check_rules.rb:1013`](../../lib/rigor/analysis/check_rules.rb).
2. **`flow.always-truthy-condition`** — the inferred-constant counterpart.
   Fires when a non-literal predicate folds to `Type::Constant`, with a
   conservative envelope: skip predicates **inside a loop / block**
   (mutation tracking is incomplete) and skip **defensive predicate
   calls** (`nil?` / `empty?` / `zero?` / `respond_to?` / …), where
   strict-on-returns RBS routinely disagrees with a real runtime check
   (`Module#name -> String` vs. anonymous-class `nil`). See
   [`always_truthy_condition_collector.rb`](../../lib/rigor/analysis/check_rules/always_truthy_condition_collector.rb).

The flow engine **already narrows `case`**. `eval_case_when_branches`
([`statement_evaluator.rb:527`](../../lib/rigor/inference/statement_evaluator.rb))
threads a `falsey_scope` accumulator across `when` branches, and
`Narrowing.case_when_scopes`
([`narrowing.rb:338`](../../lib/rigor/inference/narrowing.rb)) returns, for
each branch, a `body_scope` (subject narrowed by the clause's truthy edge)
and a `falsey_scope` (subject narrowed by the conjunction of every prior
clause's negation). So at every `when` we already compute the subject's
type *given that no earlier clause matched* — which is exactly the fact a
reachability diagnostic needs.

Two gaps:

- **No `case` clause ever produces a reachability diagnostic.** The
  narrowing is consumed only to type branch bodies.
- **`in` (pattern-match) branches do not track exhaustiveness.**
  `branch_body_and_falsey_scopes`
  ([`statement_evaluator.rb:542`](../../lib/rigor/inference/statement_evaluator.rb))
  leaves `falsey_scope` unchanged for `InNode` ("conservative: no
  exhaustiveness tracking yet").

## The disjointness signal

A `when C` clause is unreachable when the subject's type — under the
`falsey_scope` entering that clause — is **disjoint** from `C`'s match
type. That is exactly Elixir's `dynamic()` *compatibility* test
("violation only when accepted and supplied types are disjoint"), and
Rigor already has the carrier algebra to express it.

The substrate gives the signal for free: narrowing the entry
`falsey_scope` by clause `C`'s truthy edge yields a `body_scope` whose
subject local is **`bot`** (empty intersection) precisely when `C` cannot
match. No new disjointness predicate is required — a `bot` subject local
in the computed `body_scope` *is* the unreachability proof. Two shapes
fall out:

1. **Per-clause disjointness** — subject type ∧ clause type = `bot`
   (e.g. subject narrowed to `Integer`, a later `when String`).
2. **Prior-exhaustion** — the `falsey_scope` entering the clause already
   carries a `bot` subject (every earlier clause, unioned, covered the
   subject type), so this clause and all after it are dead.

## Design

### New rule: `flow.unreachable-clause`

- **Fires on:** a `WhenNode` (and, gated, an `InNode`) inside a `CaseNode`
  / `CaseMatchNode` whose computed `body_scope` narrows the subject local
  to `bot`, OR whose entry `falsey_scope` already carries a `bot` subject.
- **Points at:** the dead clause's `statements` (the body that never
  runs), mirroring `flow.unreachable-branch`'s "squiggle on the dead
  code" placement. Skip clauses with empty bodies (no useful location),
  same as the literal rule.
- **Severity:** `warning`, matching its two `flow.*` siblings. Wire into
  all three tiers of
  [`severity_profile.rb`](../../lib/rigor/configuration/severity_profile.rb)
  (`info` / `warning` / `error`) alongside `flow.unreachable-branch`.
- **Suppression:** `# rigor:disable unreachable-clause` on the dead-clause
  line, registered in
  [`rule_catalog.rb`](../../lib/rigor/analysis/rule_catalog.rb).

### Mechanism

The narrowing is already computed in `eval_case_when_branches`; the rule
needs the per-branch `(body_scope, falsey_scope)` pair surfaced to the
diagnostic pass. Prefer **collecting at evaluation time** (a collector
analogous to `AlwaysTruthyConditionCollector`, fed the subject + narrowed
scopes) over recomputing narrowing in `check_rules`, so the rule and the
body-typing read identical narrowing and cannot diverge.

### False-positive envelope (inherited, non-negotiable)

Reuse `flow.always-truthy-condition`'s envelope verbatim — this rule is
the same risk class:

- **Subject must narrow.** `case_when_scopes` already bails to the entry
  scope unless the subject is a `LocalVariableReadNode` with a known type
  ([`narrowing.rb:364`](../../lib/rigor/inference/narrowing.rb)). No
  narrowing ⇒ no firing. This alone excludes most risky shapes.
- **Skip inside loops / blocks** — same mutation-tracking gap.
- **Skip defensive-shaped subjects / clauses** — don't fault a `when nil`
  guarding against an RBS-strict return the engine believes can't be nil.
- **Require a concrete narrowed carrier** — fire on `Nominal` / `Constant`
  / `Tuple` / disjoint unions; never on `Dynamic[T]` or an unresolved
  shape. Disjointness against `Dynamic` is never provable, so it never
  fires there — the gradual guarantee holds.

## Work-decision slices

- **WD1 — `when` disjointness (per-clause).** The narrow, high-value core:
  `when C` whose `body_scope` subject is `bot`. Literal-class `when` first
  (`when String` / `when MyClass`), the shape `case_when_scopes` already
  recognises.
- **WD2 — prior-exhaustion message precision + dead `else` (landed,
  v0.1.17).** A dead `when` now reads as `:prior_exhaustion` ("already
  covered by an earlier `when'") vs `:disjoint` (the WD1 wording), told
  apart by the scope ENTERING the clause: `eval_case_when_branches`
  records that entry `falsey_scope` on the clause's first condition node
  (`record_clause_entry_scope`, `on_enter`-only so no sub-expression is
  newly typed; `propagate` preserves it), and the collector classifies by
  whether that entry already narrowed the subject to `bot`. A trailing
  `else` whose final `falsey_scope` (already recorded on the `else` node)
  narrows the subject to `bot` is flagged too — EXCEPT a defensive
  `else` body (a bare `raise` / `fail` / `throw` / `abort` / `exit`),
  which is a deliberate guard, not removable dead code (the FP-discipline
  carve-out). No new narrowing; reads the engine's own scopes.
- **WD3a — `in` bare class patterns (landed, v0.1.17).** `in C` / `in C
  => x` match on `C === subject` (pure `is_a?`, no deconstruction), so
  they narrow soundly exactly like `when C`. `branch_body_and_falsey_scopes`
  routes a bare-class `in` through `Narrowing.case_when_scopes`
  (`bare_class_pattern_node` recognises `ConstantReadNode` /
  `ConstantPathNode` and a `CapturePatternNode` wrapping one); the
  collector handles `CaseMatchNode` + `InNode` on the same `body_scope ==
  bot` signal. This is NOT ad-hoc exhaustiveness — it reuses the existing
  sound `when` class narrowing, restricted to the one pattern shape where
  truthy AND falsey narrowing are both sound.
- **WD3b — deconstructing / value / variable-catch-all patterns
  (deferred).** Array / hash / find patterns, value patterns, and the
  `in x` catch-all need real `InNode` pattern-exhaustiveness — a larger,
  separate precision project (the deferred ADR-36 `is_a?` exhaustiveness
  is the neighbour). Do **not** ship it by inferring exhaustiveness ad
  hoc; today these keep the conservative falsey-unchanged shape, so they
  fire only when a prior bare-class clause already exhausted the subject.
- **WD4 — corpus FP gate (run, v0.1.17; balanced stays `:info`).** Swept
  16 OSS corpora (Mastodon + Redmine `app lib`; parser, rubocop-ast,
  kramdown, mail, liquid, haml, hamlit, herb, slim, oj, ox, protobuf,
  textbringer, rgl `lib`) at `--no-cache` —
  [`docs/notes/20260605-adr47-unreachable-clause-corpus-sweep.md`](../notes/20260605-adr47-unreachable-clause-corpus-sweep.md).
  **Zero firings everywhere** (GitLab FOSS aborted as too slow at the
  full-`lib` scope, not counted). Zero hits ⇒ zero false positives, but a
  *vacuous* pass is absence-of-evidence, not evidence-of-safety: with no
  real firing to triage there is no signal that a louder default is
  warranted, so balanced **stays `:info`** (strict keeps `:warning`).
  Promotion waits for a real corpus firing to inspect. The conservative
  envelope is doing its job — the catchable shape (a concrete-typed local
  matched against a disjoint / already-covered class) is one programmers
  rarely write because it is obviously redundant.

- **WD5 — version-guard arm reachability (landed).** The rules above ask
  *"which clause can never match?"*. WD5 asks the mirror question about
  `if`/`unless`: *"which arm can never run on this Ruby?"* — and answers it
  from literals rather than from narrowing.

  The trigger was `mail/lib/mail/yaml.rb:26`, surfaced by the #614 corpus
  arms. Once `::YAML` resolves to Psych rather than the lexical `Mail::YAML`
  shadow, `call.wrong-arity` fires on

  ```ruby
  if Gem::Version.new(Psych::VERSION) >= Gem::Version.new("3.1.0.pre1")
    ::YAML.safe_load(yaml, permitted_classes: permitted_classes)
  else
    ::YAML.safe_load(yaml, permitted_classes)   # Psych < 3.1 positional form
  end
  ```

  The report is *honest* against the Ruby 4 Psych signature and *wrong* for
  the person running it: that line never executes on their Ruby. This is the
  cardinal false positive — a diagnostic on code that works — and "the
  program works" outranks the worst-case static reading
  ([ADR-5](5-robustness-principle.md)). Multi-version gems carry the shape
  everywhere: `mail`, `concurrent-ruby` (`RUBY_VERSION >= '3.2'`,
  `RUBY_ENGINE == 'jruby'`), `net-ssh` (a whole `pageant.rb` of
  `RUBY_VERSION < "2.1"` arms).

  **Mechanism.** `Inference::VersionGuard.verdict` is a pure function of the
  predicate AST — no scope, no environment — so the two readers that need it
  cannot drift: `StatementEvaluator#live_branch_for_if` / `#live_branch_for_unless`
  consult it *before* the carrier-certainty verdict and elide the dead arm
  exactly as they do for `Constant[false]` (the arm is never evaluated, so
  its writes never join past the `if`), and
  `CheckRules::DeadVersionGuardArms` re-asks it at diagnosis time to drop
  the diagnostics that land inside the arm. The second half is load-bearing:
  the rule walk visits every node whether or not the evaluator typed it, so
  a call with a self-typeable receiver — a constant, a literal — still
  reports without it. That filter is paid only when a file produced
  diagnostics at all.

  **FP envelope.** The folded set is closed and small (normative in
  [control-flow-analysis.md § Version-guard condition folding](../type-specification/control-flow-analysis.md#version-guard-condition-folding)):
  the comparison follows the semantics of the spelling actually written
  (String for a bare `RUBY_VERSION` comparison — `RUBY_VERSION >= "3.10"`
  really is false on 3.9, and reproducing that is the point; `Gem::Version`
  for the wrapped form), mixed spellings and `<=>` never fold, and an
  unreadable operand keeps both arms live. `RUBY_PLATFORM` is excluded
  outright — every comparison against it depends on the platform, and the
  checking machine need not be the running one. `X::VERSION` is read only
  for default gems of the running Ruby, where the "analyzer's Ruby is the
  target's Ruby" premise (the same one `PredefinedConstantRefinements` and
  the bundled core RBS already rest on) covers it; a `Gemfile.lock`-resolved
  gem does not qualify, since the analyzer's copy and the project's can
  differ.

  **`flow.always-truthy-condition` deliberately stays silent** on the guard.
  A version guard is intentional, not a redundant condition, and firing
  there would be the same class of false positive the fix removes. It stays
  silent by construction rather than by a carve-out: the guard's own
  expression type is still `bool`, so the rule never sees a folded
  constant.

  **Not in scope, recorded:** `defined?(Ractor)` / `respond_to?` capability
  probes (a different question — "does this build have the feature", not
  "which version is this"), `!` / `&&` / `||` compositions, `case` subjects,
  and honouring a `target_ruby` that disagrees with the analyzer's own
  Ruby (the setting is a Prism *parse* version today and is not threaded to
  the inference layer).

## Rejected / deferred alternatives

- **Recompute narrowing in `check_rules`** (don't reuse the engine's
  scopes) — rejected: two narrowing paths drift, and divergence here is a
  false positive, the cardinal sin
  ([`feedback_false_positive_discipline`]). Collect at evaluation time.
- **Fire on `Dynamic[T]` subjects** — rejected: disjointness is never
  provable under gradual `Dynamic`, so a fire there is unsound *and* a
  false positive. This is the boundary Elixir's *compatibility* rule draws
  too.
- **Full pattern-match exhaustiveness for `in`** — deferred to its own
  work (WD3 + ADR-36 neighbour). Out of scope here.
- **Soundness via Elixir-style strong arrows** — not pursued. Rigor is
  deliberately unsound under the robustness principle
  ([ADR-5](5-robustness-principle.md)); this rule reports only the
  *provable* `bot` case and stays inside that envelope. Recorded for
  contrast, not adopted.

## Grounding

- [`docs/notes/20260604-elixir-v1.20-type-system-rigor-review.md`](../notes/20260604-elixir-v1.20-type-system-rigor-review.md) — the source comparison (§4-2).
- [`docs/type-specification/control-flow-analysis.md`](../type-specification/control-flow-analysis.md) — narrowing / fact-stability contract this rule reads.
- [`docs/type-specification/diagnostic-policy.md`](../type-specification/diagnostic-policy.md) — `flow.*` taxonomy + severity resolution.
- [ADR-36](36-mangrove-enum-nested-class-emission.md) — the deferred `is_a?` exhaustiveness work WD3 depends on.
