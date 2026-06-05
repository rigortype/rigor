# ADR-24 — Implicit-self method-call resolution

Status: **Accepted, 2026-05-20 (slice 4 gated — separate FP evaluation
required). Slices 1+3 implemented 2026-05-20, slice 2 implemented
2026-05-21. Slice 4 attempt 1 (check-rules reimplementation) prototyped
and reverted 2026-06-05 — 135 false positives on Rigor's own `lib`. Slice
4a (the evaluation-time recorder) + the `call.self-undefined-method` rule
(standalone-class gate, shipped `:off`) implemented 2026-06-05 — mini-corpus
467→15 recorder misses, attempt-1 FP classes to zero, the rule FP-clean on
Rigor's own `lib` (and it caught a real latent bug). The external WD4
corpus FP gate (before default-on) + gate widening to superclass/include
chains remain. See slice 4 below.**

Records the project's decision to resolve implicit-self method calls
(a call written with no explicit receiver, inside a method body)
against the enclosing class/module's method set — its own
definitions, its ancestors, and cross-file project classes — so the
resolved method's inferred return type and parameter contract become
visible at the call site. Today such calls type as `Dynamic[top]`,
which is a foundational precision gap.

## Context

Confirmed empirically with `rigor type-of` against
`def nr; raise "x"; end`:

| Call site | inferred type of `nr` |
| --- | --- |
| top level (`w = nr`) | `bot` ✓ |
| inside another method (`def g; v = nr; end`) | `Dynamic[top]` ✗ |

A top-level call resolves to the top-level `def`; **a call from
inside a method body does not resolve** — rigor types it
`Dynamic[top]` and never sees the callee's inferred return type or
parameter contract.

This is not a corner case. It is the root cause of the largest
false-positive cluster found in the
[`docs/notes/20260519-oss-library-survey.md`](../notes/20260519-oss-library-survey.md)
Mastodon survey. The pattern, from `lib/mastodon/cli/accounts.rb`:

```ruby
def modify(username)
  user = Account.find_local(username)&.user
  fail_with_message 'No user with such username' if user.nil?
  user.role_id = role.id   # 40+ `possible-nil-receiver` diagnostics here
  user.save
  ...
end
```

`fail_with_message` is a guard helper whose body is `raise
Thor::Error, message` — it always diverges, so the engine *would*
infer its return type as `bot`. A `bot`-returning call in
`helper(...) if user.nil?` is a terminating guard exactly like
`raise ... if user.nil?` — the fall-through observes `user`
non-`nil`. But `fail_with_message` is an implicit-self call inside
`#modify`, so it types `Dynamic`, not `bot`; the guard is invisible;
`user` stays `User | nil`; every subsequent `user.<x>` is a
`possible-nil-receiver` false positive. One file, 42 of them.

More broadly, *every* `self`-method call in a project loses its
return type and parameter contract — chained inference degrades to
`Dynamic`, and genuine arity / argument-type bugs on `self`-calls go
uncaught. The guard-helper cluster is simply the most visible
symptom.

The pieces to fix this mostly exist already:

- The cross-file class-discovery pre-pass populates the project
  class registry.
- The engine carries a `self_type` for module-mixin contexts.
- Method return-type inference works (the top-level `type-of`
  result above proves it).

What is missing is the wiring: an implicit-self call site does not
ask "what is `self` here, and does that class — or an ancestor —
define this method?".

## Decision

The engine resolves an implicit-self call inside a method body
against the enclosing definition's `self` type:

1. Determine `self` at the call site — an *instance* of the lexically
   enclosing `class`/`module` for an instance method (`def m`), the
   *singleton* for a singleton method (`def self.m` / `class <<
   self`).
2. Resolve the call name against that type's method set: the
   enclosing class's own definitions, then its ancestors — superclass
   chain and included modules — drawing on both project-discovered
   classes (cross-file) and RBS-known ancestors.
3. On a hit, the call site adopts the resolved method's inferred
   return type and parameter contract, exactly as a call with an
   explicit, known receiver already does.
4. On a miss, the call stays `Dynamic[top]` — today's behaviour
   preserved (WD3).

The change is **precision-additive** for v1: it only ever replaces a
`Dynamic[top]` with a more precise type. It does NOT, in v1, newly
emit `call.undefined-method` for an *unresolved* self-call (WD4) —
that is a separate, gated decision because Ruby's metaprogramming
makes "unresolved" a weak signal for "bug".

## Working decisions

### WD1 — Resolution scope: enclosing class + ancestors, cross-file

The resolution target is the full ancestor chain of `self`'s class,
not just the same file or the same class body. `fail_with_message`
lives in `Mastodon::CLI::Base`; the call is in a subclass in another
file. Resolution consults the cross-file project class registry and
RBS ancestors. A self-call that resolves only because the whole
project was analysed is the common case, not the exception.

### WD2 — `self` is instance-typed for `def m`, singleton for `def self.m`

Inside `def m` the receiver of an implicit-self call is an *instance*
of the enclosing class; inside `def self.m` / `class << self` it is
the *singleton*. The two have different method sets (instance vs
class methods). Resolution uses the matching set. This reuses the
engine's existing `self_type` rather than inventing a parallel
notion.

### WD3 — Unresolved self-calls stay `Dynamic[top]`

A self-call whose name resolves to no known method keeps today's
`Dynamic[top]` type. Ruby methods are routinely defined by
`define_method`, `method_missing`, `attr_*`, and framework DSLs
(ActiveRecord attributes / associations, `delegate`, …). Treating
"not statically found" as "does not exist" would be wrong far more
often than right. Leniency on uncertain dispatch is the
[ADR-5](5-robustness-principle.md) robustness principle applied to
`self`-dispatch.

### WD4 — `undefined-method` on a resolved-closed self-call is a SEPARATE, gated decision

Once self-calls resolve, the engine *could* emit
`call.undefined-method` / `call.wrong-arity` / argument-type
diagnostics for a self-call that resolves-but-mismatches, or for one
that does not resolve on a class with no metaprogramming escape
hatch. That is genuine bug-catching value — but on a
metaprogramming-dense codebase (every Rails model) it is also a
large new false-positive surface. v1 of this ADR does **not** open
it. It is slice 4, gated behind its own evaluation: only flag when
the receiver class is confidently *closed* (every method statically
known; no `method_missing` / `respond_to_missing?` / dynamic
definition; not an RBS-`untyped`-tainted ancestor). Until then,
self-call resolution is purely a precision uplift.

### WD5 — Project method summaries, computed with a bounded pass

To hand a caller the callee's return type, the engine needs a
per-method summary — `(class, method, kind) → return type +
parameter contract` — computed once and consulted at self-call
sites, rather than re-analysing the callee per call. Mutual
recursion (`A` calls `B` calls `A`) is bounded per
[`inference-budgets.md`](../type-specification/inference-budgets.md):
a summary still being computed resolves to `Dynamic[top]` for that
cycle rather than diverging. The existing project-scan pre-pass and
its cache (ADR-6) are the natural home; this may extend the
synthetic-method index or add a sibling project-method-summary
index.

### WD6 — `bot` branches narrow control flow

A self-call that resolves to a `bot`-returning method (a guard
helper that always `raise`s / `exit`s) only pays off if the flow
analysis then treats `helper(...) if x.nil?` as a terminating guard.
Today `eval_if` / `eval_unless` detect a terminating branch
*syntactically* — a hardcoded `EXIT_CALL_NAMES`
(`raise`/`throw`/`exit`/`abort`/`fail`) matched by call name. This
ADR generalises it: a branch whose *inferred type is `Bot`* is a
terminating branch, regardless of how it is spelled. The branch type
is already computed by `eval_if`; the change is to OR it into the
exit test. (A prototype of this generalisation was written and
reverted during the cluster-1b investigation — correct, but inert
until WD1–WD5 make the guard call resolve to `bot` in the first
place. It belongs here, as slice 3, specced alongside the rest.)

### WD7 — Budgets and caching

Resolution and summary computation add analysis work. Both stay
within the [`inference-budgets.md`](../type-specification/inference-budgets.md)
envelope; cross-file resolution rides the existing class-discovery
pre-pass and the ADR-6 cache. A self-call that would exceed the
budget falls back to `Dynamic[top]` (WD3) — never to a slower
unbounded walk.

## Consequences

### Positive

- The Mastodon nil-receiver FP cluster (≈42 in one file, and more
  elsewhere) closes once a guard helper's `bot` return is visible
  (WD1 + WD5 + WD6).
- *Every* `self`-call gains its real return type — chained inference
  on `self`-methods stops degrading to `Dynamic`. Precision uplift
  well beyond the guard-helper case.
- The `bot`-branch flow generalisation (WD6) makes guard clauses
  through *any* diverging helper narrow correctly, not just the five
  built-in exit calls.

### Negative

- New analysis cost (WD7) — bounded, cached, fail-soft.
- Mutual recursion needs the bounded-summary handling (WD5);
  done wrong it would diverge or mis-cache.
- WD4 is deliberately left closed. Users will reasonably ask "why
  doesn't rigor catch this typo'd `self`-call?" — the answer
  (metaprogramming leniency) must be documented, and slice 4 is the
  place that question gets re-opened.

### Carry-over

- Slice 4 (`undefined-method` on closed-class self-calls) is
  deferred, not rejected.
- **[ADR-34](34-toplevel-unresolved-self-call-default.md) (2026-05-29)**
  carves out the toplevel slice of WD4 as a separate decision:
  unresolved implicit-self calls at toplevel (no enclosing `def` /
  `class` / `module`) warn by default once ADR-17's `pre_eval:`
  escape hatch is in place. The class-body / `def`-body case this
  ADR's WD4 left closed stays closed; ADR-34 explicitly does not
  re-open it.

## Implementation slicing (proposed)

Demand-driven; no slice scheduled by this ADR.

### Slice 1 — same-class self-call resolution — IMPLEMENTED 2026-05-20

Resolve an implicit-self call against the enclosing class's *own*
instance method definitions and the file's top-level defs; adopt the
resolved method's inferred return type. No ancestors yet, no new
diagnostics.

**As shipped.** The wiring gap was small: `discovered_def_nodes` —
the per-class / top-level `method → DefNode` table built by
`ScopeIndexer` and consulted by the engine's existing
inter-procedural resolution (`Scope#user_def_for` /
`#top_level_def_for`) — was carried into top-level call-site scopes
but NOT into the fresh scope built for every class / method body
(`StatementEvaluator#build_fresh_body_scope`). Carrying it activates
resolution inside method bodies.

Two deviations from the slice sketch, both forced by measurement:

- **Conservative adoption gate.** Adopting *every* resolved return
  type unconditionally regressed `rigor check lib` from clean by 16
  diagnostics — a resolved precise type (`Nominal[Manifest]`, an
  imprecise `Hash` shape, `nil`) makes downstream strict checks
  (`undefined-method`, argument-type, flow-folding) fire on
  *pre-existing* callee-return-inference imprecisions that were
  masked while the self-call stayed `Dynamic[top]`. So
  `ExpressionTyper#adoptable_self_call_result?` gates adoption:
  inside a class body (`scope.self_type` set) the resolved type is
  adopted only when it is `Bot`; at top-level / DSL-block scope
  (`self_type` nil — the pre-slice-1 surface) it is adopted
  unchanged. The `Bot` case is the ADR's motivating bug and is
  provably FP-free (a `Bot` result can only enable correct
  terminating-branch narrowing). General non-`Bot` adoption inside
  class bodies is deferred until callee-return inference is precise
  enough — its own follow-up, gated by re-evaluation trigger 1.
- **Recursion guard re-keyed (WD5).** The `infer_user_method_return`
  guard keyed on `(receiver, method, arg_types)`; once self-calls
  resolved, mutual recursion through a `module_function` module
  (`Acceptance#accepts` → `accepts_one` → `accepts_dynamic` →
  `accepts`) recursed unboundedly whenever the carried argument
  types differed level-to-level — a `SystemStackError`. The guard is
  now keyed on `(receiver, method)`: a method whose summary is still
  being computed resolves to `Dynamic[top]` for that cycle, exactly
  as WD5 prescribes. No separate per-method summary index was added
  — the existing per-call re-walk under the (now correct) guard is
  the slice-1 mechanism; a memoised summary index stays a WD7
  performance follow-up.

### Slice 2 — ancestors + cross-file — IMPLEMENTED 2026-05-21

Extend resolution to the superclass chain and included modules,
across project files (the class-discovery registry) and RBS-known
ancestors.

**As shipped.** `ExpressionTyper#try_user_method_inference`, on a
same-class `user_def_for` miss, walks the user-class superclass
chain (`resolve_user_def_through_ancestors`). The chain is followed
through a new `Scope#discovered_superclasses` map — `class →
superclass-name AS WRITTEN`. The as-written name is resolved to a
qualified class at the call site by `resolve_ancestor_class_name`,
which follows `Module.nesting` constant lookup (raw name under each
enclosing namespace of the subclass, innermost first). Cross-file
resolution rides a new project pre-pass,
`ScopeIndexer.discovered_def_index_for_paths`, which walks every
project file once and returns the merged `discovered_def_nodes`
table plus the merged superclass map; `Runner` seeds both onto each
file scope exactly as it already seeds cross-file
`discovered_classes`. The walk is depth-capped (20) and
cycle-guarded.

**Included / prepended modules** were added in a follow-up the same
day (2026-05-21). `ScopeIndexer.build_discovered_includes` records,
per class / module, the modules it `include`s / `prepend`s
(constant arguments only). The cross-file
`discovered_def_index_for_paths` returns the include map alongside
the def-node and superclass maps; `Runner` seeds it via
`Scope#discovered_includes` / `#includes_of`.
`resolve_user_def_through_ancestors` is a breadth-first walk over
the full user-class ancestor set — included / prepended modules
(transitive) first, then the superclass — cycle-guarded and
node-count-capped (100). `extend` is NOT tracked: it adds singleton
methods, out of scope for the instance-side chain.

Scope deviations from the slice sketch:

- **RBS-known ancestors are NOT walked here.** The
  `MethodDispatcher` RBS tier runs *before*
  `try_user_method_inference` and already resolves methods on
  RBS-known ancestors; the user-class walk simply stops when an
  ancestor name resolves to no project-discovered class / module.
  So "and RBS-known ancestors" is satisfied by the existing
  dispatch ordering, not by new code in the walk.

Adoption stays gated by slice 1's `adoptable_self_call_result?`
(inside a class body only a `Bot` return is adopted), so the FP
profile is unchanged from slice 1: an ancestor guard helper
resolves to `bot` and narrows (with slice 3); non-`Bot` ancestor
returns stay `Dynamic[top]`. Fixtures:
`spec/integration/fixtures/inherited_guard.rb` (superclass,
same-file) + `included_module_guard.rb` (mixin, same-file) + two
cross-file `Runner` specs.

### Slice 3 — `bot`-branch flow narrowing (WD6) — IMPLEMENTED 2026-05-20

Generalise `eval_if` / `eval_unless` terminating-branch detection
from the syntactic `EXIT_CALL_NAMES` list to "branch inferred type
is `Bot`". Guard clauses through a diverging helper now narrow.

**As shipped.** `StatementEvaluator#branch_terminates?(branch_node,
branch_type)` ORs the existing syntactic `branch_unconditionally_exits?`
with `branch_type.is_a?(Type::Bot)`. The branch type is already
computed by `eval_if` / `eval_unless` (`then_type` / `else_type`), so
both early-return-narrowing tests in each just swap
`branch_unconditionally_exits?` for `branch_terminates?` — no extra
evaluation. Implemented out of slice order, alongside slice 1,
because the two compose directly: slice 1 makes a same-class /
top-level guard helper resolve to `bot`, and slice 3 makes that
`bot` narrow the fall-through. The ancestor-helper case (the
Mastodon `fail_with_message` cluster) still awaits slice 2.
Integration fixture: `spec/integration/fixtures/bot_branch_guard.rb`.

A follow-up (2026-05-21) extended the same generalisation to
`eval_and_or`: `&&` / `||` carried an independent syntactic
`branch_unconditionally_exits?` check, so `x = src or fail_now`
(divergent helper rather than a bare `raise`) did not narrow.
`eval_and_or` now evaluates the RHS first and uses
`branch_terminates?`, so a `Bot`-typed RHS narrows the LHS to its
surviving edge. Fixture: `spec/integration/fixtures/or_guard_narrowing.rb`.

### Slice 4 (gated — separate decision) — diagnostics on closed-class self-calls

`call.undefined-method` / `call.wrong-arity` / argument-type on a
self-call when the receiver class is confidently closed (WD4). Gated
behind its own false-positive evaluation on metaprogramming-dense
codebases.

**Attempt 1 (2026-06-05) — prototyped and reverted; the check-rules
reimplementation route is unsound.** A `call.self-undefined-method`
rule was implemented entirely in `CheckRules`: for an implicit-self
call inside an instance-method body, fire when the enclosing class is
"confidently closed" and the name resolves to nothing. The closedness
gate was deliberately ultra-conservative — a project class with **no
project superclass, no includes**, no `method_missing` /
`respond_to_missing?`, and not plugin-`open_receivers:` (ADR-26) — and
resolution checked the class's own `def`s, its `discovered_methods`
table, its own RBS surface (`Reflection.instance_method_definition`),
and the `Object` / `Kernel` surface. Targeted specs (8) all passed.

**Then the mandatory mini-corpus gate (run the rule over Rigor's own
`lib`) produced 135 false positives on clean code.** The leak classes,
all real methods the rule could not see from `CheckRules`:

- **`module_function` modules** — `Inference::Narrowing` (31),
  `Type::Combinator` (24): sibling self-calls (`case_when_scopes`
  calling `analyse`) where `self` types to `Nominal[Module]` but the
  module's `module_function` defs are not where the check-rules
  resolution looked.
- **`Data.define` / `Struct.new` classes** — `GemResolver::Resolved`,
  `RuleCatalog::Entry`, `CoverageReport`, …: the synthesized member
  accessors (`gem_name`, `id`, `total`) are real methods that the
  ad-hoc `Reflection` probe did not resolve.
- **Template-method modules / value-semantics** — `CLI::Renderable`
  (`render_text` is abstract, implemented by includers),
  `ValueSemantics::ClassMethods`: methods that exist only through a
  mixin contract the closedness gate's "no includes" check does not
  capture from the *callee* side.

**Conclusion: do NOT reimplement self-call resolution in `CheckRules`.**
The engine *already* resolves every one of these correctly for
precision (ADR-24 slices 1–2: `module_function`, synthesized accessors,
ancestor walks) — the FPs came purely from a second, weaker resolution
path in the rule diverging from the engine's real one. The correct
design (the ADR-46 / ADR-47 lesson, "collect at evaluation time, never
recompute") is an **evaluation-time recorder**: at the single point
where the engine's own self-call resolution falls through to
`Dynamic[top]` (`ExpressionTyper#try_user_method_inference` miss + the
dispatcher RBS-tier miss), record the unresolved call node; then
`CheckRules` only applies the closedness gate + corpus FP triage. That
reuses the engine's actual method set, so `module_function` /
`Data.define` / mixin methods never reach the rule as "unresolved."
This is more surgery (a recorder threaded through the dispatch
choke-point, like `DependencyRecorder`), and still needs the WD4 corpus
gate before any default-on — but it is the only route that respects the
false-positive discipline. The reverted prototype's specs + the 135-FP
breakdown are the evidence for the next attempt.

**Slice 4a (2026-06-05) — the evaluation-time recorder, LANDED, off by
default, no rule yet.** `Analysis::SelfCallResolutionRecorder` records, at
the single engine choke-point where an implicit-self call exhausts every
resolution tier (`ExpressionTyper#call_type_for` → `fallback_for`), the
calls that resolve to nothing. Opt-in via `Runner.new(record_self_calls:
true)`; a normal run pays one integer read (`active?`) and records
nothing. Purely observational — diagnostics are byte-identical.

The decisive design correction over attempt 1: the choke-point fires on a
*type* miss, which over-captures methods that **exist** but whose return
the engine can't infer — the very `module_function` siblings
(`Narrowing`, `Combinator`) that drove attempt-1's FPs. So the recorder
gates on the engine's own **existence** signals before recording:
`resolve_user_def_through_ancestors` (def existence, ancestor-aware) plus
`Scope#discovered_method?` under **both** `:instance` and `:singleton`
(`module_function` records its defs `:singleton`). Recording reuses the
engine's real resolution — the "collect, don't recompute" lesson — so a
name resolvable any way a project signal can see it never reaches the
recorder.

A companion `ScopeIndexer` fix registers `class X < Data.define(:a, …)` /
`< Struct.new(:a, …)` synthesized member readers in the discovered-methods
existence table (`record_meta_superclass_members`) — they have no `def` /
`attr_*` declaration, so without this they read as unresolved.

**Mini-corpus measurement (Rigor's own `lib`, 265 files):** raw recorder
467 misses → **15** after the existence guard + member registration, and
the attempt-1 FP classes go to **zero** (`Narrowing` 31→0, `Combinator`
24→0). The residual 15 are exactly the predicted irreducibly-hard cases,
none of them typos: `attr_reader(*CONSTANT)` splat accessors
(`FlowContribution`, names not statically decidable), template-method
modules whose method is implemented by includers (`CLI::Renderable`), and
mixin-contract method sets (`ValueSemantics::ClassMethods`). These define
the closed-class gate the rule slice still needs: exclude modules /
mixin-contract receivers and classes with a splat-attr or
`Data`/`Struct`-without-member-modelling shape. A block-form
`Const = Data.define(:a) do … end` member reads `self` as `Object` (the
engine does not rebind `self` to the constant for meta-block methods), so
that over-capture lands under `Object` — never confidently closed — and
the gate filters it for free.

**Slice 4 rule (2026-06-05) — `call.self-undefined-method`, LANDED,
shipped `:off`.** A `CheckRules` collector (`self_undefined_method_-
diagnostics`) consumes the recorder snapshot (threaded per-file through
`Runner#analyze_file_body` → `CheckRules.diagnose(self_call_misses:)`,
recording active only when the rule resolves to a firing severity) and
applies ONLY the closedness policy — it never recomputes resolution. The
v1 gate is the most conservative confidently-closed shape: a **standalone
project class** — no superclass and no `include`/`prepend`, so its in-file
method surface is complete — that is not a `module` (mixin contract),
defines no `method_missing`, has no dynamic `attr_*(*splat)` accessor
(`SelfClosednessScanner`, a one-pass AST scan over the same file), and is
not an ADR-26 open receiver. This subsumes the residual-15: modules and
splat-attr / `Data`/`Struct` classes are all excluded, the latter also by
the no-superclass clause.

Validated on Rigor's own `lib`: the rule fires **zero** false positives —
and caught one real latent bug (`BlockParameterBinder#bind_trailing_-
positionals` called an undefined `required_name`, so `|a, *b, c|`-shaped
block params raised `NoMethodError`; fixed). It is authored `:warning` but
mapped to `:off` in every profile; `severity_overrides:` opts in.

**Remaining:** the external WD4 corpus FP gate before any default-on, then
widening the gate to superclass / include chains (each requires the
engine to confirm the full ancestor chain resolved — record that
completeness at the recorder, the same "collect, don't recompute" route).

## Re-evaluation triggers

1. **Slice 1/2 measurably regress analysis wall-time** beyond the
   `inference-budgets.md` envelope → tighten WD7, push more work into
   the cache / pre-pass.
2. **Demand for slice 4** (users wanting typo detection on
   `self`-calls) outweighs the metaprogramming-FP risk on a
   representative survey → schedule slice 4 with the closed-class
   gate.
3. **A method-summary cycle is observed mis-cached** → revisit the
   WD5 bounded-pass / fixed-point handling.

## References

- [ADR-4](4-type-inference-engine.md) — the inference engine this
  resolution plugs into.
- [ADR-5](5-robustness-principle.md) — leniency on uncertain
  dispatch (WD3 / WD4).
- [ADR-6](6-cache-persistence-backend.md) — the cache the summary
  index rides on (WD5 / WD7).
- [`docs/type-specification/control-flow-analysis.md`](../type-specification/control-flow-analysis.md)
  — the narrowing surface WD6 extends.
- [`docs/type-specification/inference-budgets.md`](../type-specification/inference-budgets.md)
  — the budget envelope (WD5 / WD7).
- [`docs/notes/20260519-oss-library-survey.md`](../notes/20260519-oss-library-survey.md)
  — the Mastodon survey whose largest FP cluster this ADR closes.
