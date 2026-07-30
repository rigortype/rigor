# ADR-67 — Parameter type inference (the M3 frontier): call-site and in-body, precision-additive only

Status: **Accepted — WD1 + WD3 + WD5 (capped fixpoint) implemented 2026-06-16; WD3
argument-shape coverage extended 2026-07-06; the `check`-walk wiring (WD6, addendum below —
its demand gate fired on a three-codebase protection scout) implemented 2026-07-19 behind the
opt-in `parameter_inference:` gate; WD2 in-body inference stays deferred.** Re-opens the algorithm-corpora
survey's "M3 — untyped-param → whole-method Dynamic: **EXCUSED, do not pursue**" verdict
on new **protection-coverage** evidence. Method / ctor parameters default to `untyped`
today (the gradual entry point); the pilot shows a param flowing into an ivar or
receiver is the **dominant remaining protection hole on real apps**. The reconciliation
with the robustness principle is the whole decision: inference may **sharpen downstream
precision** but **never tighten a diagnostic at the parameter boundary**.

The landed slice is the **substrate**: a call-site argument-union collector
(`Inference::ParameterInferenceCollector`) keyed by `[class, method, kind]`, a
`param_inferred_types` `DiscoveryIndex` side-table, and consumption in
`build_method_entry_scope` (an undeclared parameter is seeded with its inferred type;
an RBS-declared parameter wins). It runs as a **capped fixpoint** (WD5): each round
re-types the project with the previous round's inferred parameters seeded, so a parameter
passed *another* parameter is typed one hop further per round (cap 3, the `BodyFixpoint`
convention, early-stop on convergence; round 1 alone is the single-level pass). A call
site whose argument is a not-yet-typed parameter poisons the parameter *that round* (WD4),
and it may type in a later round once its own argument resolves. It is wired into
**`coverage --protection` only**: the `check` walk leaves the table empty, so its
diagnostics are byte-identical and WD1's "never fire at the parameter boundary" holds *by
construction* (an inferred type is a body local, never an RBS contract, and the boundary
rules consult RBS).

**Measured caveat (the 2026-06-16 verification, do not re-litigate):** the two ADRs cited
as the headline cases are *not* moved, even with the fixpoint. parser's `unary_num`
parameter is fed from generated `.y` value-stack code (`val[0]`, never analysed Ruby);
faraday's `match(env)` is called with `env`, itself a parameter of `call(env)` whose own
entry is reached by dynamic middleware dispatch (so the fixpoint never seeds its root).
The pass moves the metric where a user method is (transitively) called with concretely-typed
arguments. **Measured** (`coverage --protection`, `lib`): faraday 0.2129 → 0.2402 (+29
protected sites; +6 of them from the fixpoint over single-level), haml 0.3188 → 0.3842
(+105 sites; +6 from the fixpoint) — haml's `compile(node)`-style compiler chain (methods
called with constructed AST nodes) is the sweet spot, the cited `env` / `numeric` clusters
are not. The `check`-walk wiring (and with it the WD1 in-body provenance *mark*) is the
remaining follow-up, budget-gated per the cost discussion below.

**WD3 argument-shape extension (2026-07-06).** The original collector only inferred a
method whose parameter list was *entirely* required-positional
(`ParameterInferenceCollector#simple_requireds`), skipping any method with a trailing
optional / keyword / rest / block parameter — a shape common on real Rails methods
(`def f(x, opts = {}, **kw)`), so their leading required params were never inferred even
when called with concrete arguments. The collector now maps a call's leading positional
arguments to the method's **leading required** parameters (`leading_requireds`): Ruby
orders parameters requireds-first, so trailing optional / rest / keyword / block params
do not disturb the leading positional-index ↔ required-parameter mapping. A call with a
trailing keyword hash or block-pass is accepted (they occupy no positional slot); a splat
/ forwarding argument still skips the site (position becomes runtime-dependent), and a
post-rest required def (`def f(a, *b, c)`) is still skipped (its `c` maps to a trailing
arg). Soundness is unchanged — the inferred type is still the union of *resolved actual
argument types*, so it never manufactures a boundary false positive (WD1). Measured on
Mastodon app+lib: WD3 as-was contributes +190 protected sites (0.3086 → 0.3148), the
shape extension +36 more (→ 0.3160). The gain is modest because most Mastodon parameter
holes are reached by dynamic dispatch / framework callbacks (`before_action`, middleware),
which call-site inference fundamentally cannot see — the ceiling that motivates the still-
deferred WD2 (in-body structural) inference for params with no resolvable call site.

Grounding: the algorithm-corpora survey
([`docs/notes/20260612-algorithm-corpora-survey.md`](../notes/20260612-algorithm-corpora-survey.md)
M3 row — excused on *precision* grounds: leaf sort/number scripts have no call sites and
a signature-less param IS the gradual entry point); the 2026-06-16 protection-uplift pilot
([`docs/design/20260616-act-on-coverage-skill.md`](../design/20260616-act-on-coverage-skill.md)
— M3 is the top `add_a_type_here` on faraday/haml/parser, the hand-typed `compile(node)` /
`@template = template` wins); and the TypeProf-internals prior-art survey
([`docs/notes/20260531-typeprof-internals-survey.md`](../notes/20260531-typeprof-internals-survey.md)
— a param's type as "the union of every actual-argument type across all call sites").

## Context

A method / ctor parameter with no RBS signature types `untyped` (the gradual entry
point; `method_dispatcher.rb` "the key parameter is left `untyped` — the default"). Block
parameters are inferred from dispatch, but **`def` parameters are not inferred** from call
sites or in-body usage. So `def initialize(line); @line = line; end` makes `@line`
`Dynamic`, and every `@line.<method>` downstream is unprotected — distinct from
[ADR-58](58-ivar-field-typing.md), whose ivar typing is *already realized* for
concrete-write fields but cannot touch a **param-sourced** ivar (confirmed: a
concrete-write `@line = Line.new` reads `Line` and protects; a param-sourced `@line = line`
reads `Dynamic`).

The algorithm survey **excused M3** because its corpus was leaf scripts with no call sites
— there was no inference *seed*. The protection pilot changes the cost/benefit: on real
applications the call sites exist (faraday's `Connection`/`Options`, haml's compiler chain),
M3 is the #1 remaining unprotected cluster, and protection coverage is the lens that values
closing it. The standing tension is [ADR-5](5-robustness-principle.md): parameters are kept
**lenient** by decision (strict returns, lenient params), so any param typing must not turn
a wrong-typed caller into a diagnostic.

## Decision

Infer parameter types from two sources, staged, under one load-bearing criterion.

> **Criterion (reconciliation with robustness):** an inferred parameter type is
> **precision-additive only**. It sharpens *downstream* inference — the ivar the param is
> stored in, the receiver it becomes, the protection metric, constant folding — but is
> **never** consulted to reject a caller's argument. The parameter boundary stays lenient
> (ADR-5): a call passing an unexpected type is not a diagnostic. An RBS-*declared* param
> always wins over an inferred one. Inference feeds protection/folding, not param-boundary
> diagnostics.

This is what separates the proposal from a "typed parameters" regime and is why it can
proceed without breaching the robustness principle.

## Working decisions

- **WD1 — precision-additive-only contract (the robustness floor; non-negotiable).
  Implemented by construction (single-level slice).** An inferred param type can never
  escalate to a param-boundary `argument-type-mismatch` / arity firing. In the landed slice
  this holds *structurally*: the inferred type is stored only as a method-body local (via
  `build_method_entry_scope`), never injected into an RBS method definition, and the boundary
  rules fire only on RBS-declared methods — an inferred-parameter method has no RBS sig, so
  the boundary rules skip it. The explicit "inferred, not declared" provenance *mark* (the
  [ADR-58](58-ivar-field-typing.md) WD1 pattern, reused) is required only to guard *in-body*
  diagnostics once the inference feeds the `check` walk, and lands with that follow-up.
- **WD2 — in-body usage lower bound (cheapest; helps even leaf scripts).** From the param's
  calls in the method body (`arr.delete_at`, `arr.length`), derive a **structural lower
  bound** (responds-to set / interface) and let it drive protection on `arr.<method>`. No
  call sites needed, so it helps the leaf-script corpus the survey excused — but yields a
  duck/structural bound, not a nominal type.
  - **Implementation finding (2026-06-26): WD2 is blocked on a missing carrier.** The
    "structural lower bound / responds-to set / interface" it specifies has **no carrier** —
    the type zoo is entirely nominal-ish (`nominal`, `union`, `refined`, `difference`,
    `intersection`, `integer_range`, `tuple`, `hash_shape`, `struct`/`data`, …); there is no
    structural-interface / capability type to hold a responds-to set. The only cheap
    alternative is to *guess a nominal* from the in-body method names, which is fragile
    (`each` / `map` / `<<` / `size` are shared across `Array` / `Hash` / `String` / custom
    classes, so a method set rarely pins one class) and feeds `concrete_receiver?`
    (`protection_scanner.rb` — any non-`Dynamic` type counts as protected) a low-confidence
    guess, degrading the metric's meaning. **WD2 done right needs a structural-interface
    carrier first** (a new carrier + its acceptance / protection-metric handling), which is a
    larger change than the "cheapest" framing implied. Re-scoped: introduce the carrier, or
    keep WD2 deferred. The WD3 call-site path (which yields real nominals) stays the
    higher-confidence lever.
  - **Design-spike verdict (2026-07-06): keep WD2 deferred — payoff does not justify the
    carrier** ([spike note](../notes/20260706-adr67-wd2-in-body-inference-design-spike.md)).
    A pure-AST probe over mastodon/redmine/rigor-lib classifies untyped `req`+`opt` params by
    their in-body call set: **44–58% are never an in-body receiver** (param flows into an ivar
    / return / another arg → WD3 or [ADR-58](58-ivar-field-typing.md), *not* WD2's domain),
    **19–27% call only universal/duck methods** (`to_s`/`==`/`[]`/`each`… — the set pins no
    nominal), leaving a **23–29% ceiling** with any distinctive method; of that, only the *2+
    distinctive* subset (**~10% of params**) could pin a nominal. Two facts sink even that 10%:
    (i) the pinnable-looking domain params are Rails helpers whose distinctive methods are
    **AR-dynamic accessors** (`username`/`display_name` — columns/associations absent from the
    static `discovered_methods` def-scan a set-resolver would consult, so they resolve to
    nothing); (ii) a body-derived structural bound is **circular for the protection metric** —
    it marks protected exactly the sites it is built from and cannot bite a same-body typo, so
    real protection needs the check-walk dispatch that is the FP-risky path. Matches the
    provenance note's lever ranking (env-build resilience / sig-gen validity rank *above* the
    ADR-67/58 big-feature work). The re-eval trigger gains a new falsifier: WD2 is worth
    revisiting only on a codebase where the AR-attribute trap is absent (schema+plugin complete,
    or non-Rails domain-object code).
- **WD3 — call-site union (TypeProf-style; the real lever for apps). Implemented.** A
  param's inferred type = the union of resolved call-site argument types (needs ≥1 resolved
  call site). `ParameterInferenceCollector` resolves a call to its user `def` via the
  cross-file discovery index, types the positional arguments, unions them per parameter, and
  skips non-simple parameter shapes / arity mismatches / splat calls. It is whole-program-ish
  and in tension with Rigor's per-file model ([ADR-46](46-incremental-dependency-graph.md)),
  so it runs only in the `coverage --protection` command (not the `check` walk) and is
  **budget-gated** (a per-parameter union cap, `MAX_CALL_SITE_TYPES`, and the WD5 round cap),
  and is unsound under unseen call sites / dynamic dispatch → falls back to `untyped` (no
  false narrowing).
- **WD4 — soundness fallbacks.** Unseen call sites, `send`/dynamic dispatch, and
  metaprogrammed callers contribute nothing (the param stays `untyped`); a single dynamic
  caller does not widen an otherwise-precise inference into a false narrowing. The inferred
  type is an over-approximation only where the call-site set is closed.
- **WD5 — budget + termination. Implemented (capped, not true-convergent).** The call-site
  union is a worklist fixpoint: each round re-types the project with the prior round's
  inferred parameters seeded (the same `param_inferred_types` consumption path the protection
  scan uses), propagating one hop per round. Capped at `DEFAULT_ROUNDS` (3, the
  [ADR-41](41-inference-budget-design.md) budget; the `BodyFixpoint` convention) with an
  early-stop on table equality — convergence is *not* required because the table can
  oscillate at the margin (a newly resolved receiver can surface a fresh untyped-argument
  call site), and the protection metric tolerates a bounded approximation. Parses are cached
  across rounds; only re-indexing repeats. The ADR-57 run-scoped return memo is the
  forward-looking reuse for the deferred `check`-walk wiring (where callee re-typing must not
  be unbounded); the protection-only pass does not need it.

## Rejected / deferred alternatives

| Alternative | Verdict |
| --- | --- |
| Treat an inferred param as **declared** (fire on wrong-typed callers) | **Rejected** — breaches ADR-5 (parameters are lenient by decision); the criterion forbids it. |
| Keep the survey's "M3 EXCUSED, do not pursue" | **Superseded for the protection lens** — excused on *precision* (leaf scripts, no call sites); the protection pilot + real apps with call sites re-open it. |
| Full TypeProf whole-program abstract interpreter as the default | **Deferred** — Rigor is per-file/incremental (ADR-46); the call-site pass is budget-gated (WD3/WD5), not a default whole-program worklist. |
| Infer params before [ADR-58](58-ivar-field-typing.md) precision exists | **N/A — already met** — ADR-58's concrete-write ivar typing is realized, so an inferred param feeding `@x = param` immediately sharpens the read. |

## Re-evaluation triggers

Demand-gated. Proceed when **either**: (a) [ADR-63](63-type-protection-coverage.md)
protection-coverage keeps surfacing M3 as the top `add_a_type_here` across user projects
(the pilot is the first such signal); or (b) [ADR-46](46-incremental-dependency-graph.md)
incremental analysis makes the WD3 call-site pass affordable inside the per-file model.

**Trigger (a) fired, 2026-07-19.** A three-codebase protection scout (mastodon
`app/models`+`app/services`, redmine `app`+`lib`, rails activemodel/actionpack/activesupport
`lib`) put the correctly-attributed `inferred_return_untyped` mass at 20–51% of unprotected
sites everywhere, and site-level drill-down traced it overwhelmingly to untyped
`call`/`initialize`/setter parameters (with [ADR-58](58-ivar-field-typing.md) ivars as the
immediate second hop: `@options = options`). ADD_RBS was 1–2.4% on every codebase — the
holes are not missing signatures, they are this inference. The check-walk addendum below is
that follow-up.

## Addendum — WD6: check-walk activation of the WD3 table (2026-07-19, implemented)

The consumption side already ships: `StatementEvaluator#seed_inferred_param_types`
(`build_method_entry_scope`) consults `Scope#param_inferred_types`, overrides only
untyped bindings, lets RBS-declared params win, and no-ops on the empty table — which is
what the check path has been. Activation is therefore *populating the table in the check
command's discovery seed*, exactly as `coverage --protection` does
(`ParameterInferenceCollector.collect` → `seed[:param_inferred_types]`), plus the guards
this ADR always said must land with it. Four working decisions:

- **WD6a — activation, budgeted, off by default.** The check command runs the collector as
  a pre-pass into the discovery seed, **one round** (not the protection scan's three — one
  hop of call-site → param typing; multi-hop stays a protection-surface luxury until
  measured), behind a `parameter_inference:` config gate resolved **off** by every default
  profile ([ADR-50](50-release-engineering-and-stability-strategy.md) WD1: a
  diagnostics-affecting activation is a compatibility change; the gate is the discipline).
  The pre-pass runs before the pool split, so every worker sees the same frozen table —
  determinism by the same seed-before-fork contract the discovery tables use.
- **WD6b — the "inferred, not declared" mark, and the guarded rule set (the WD1 follow-up
  named at line ~114).** The seed records provenance per `(def, param)` the ADR-58-WD1 way
  (a side mark, never a carrier field). **Slice 1 guards every negative in-body rule** —
  `call.undefined-method`, arity/argument-mismatch, possible-nil — from firing on a
  receiver/value whose type is inferred-param-sourced: an open call-site set means the
  union is a lower bound, and a diagnostic against a lower bound is an FP by construction
  (the same reasoning that keeps WD1 non-negotiable at the boundary). What activation buys
  in slice 1 is *positive*: folds, narrowing, downstream propagation, protection-metric
  closure, and fewer `Dynamic` chains — not new firings. Un-guarding any rule later
  requires the mutation oracle ([ADR-63](63-type-protection-coverage.md) Tier 2) to show
  the closed-call-set case is separable, as its own measured slice.
- **WD6c — incremental stays out, explicitly.** Under `--incremental`
  ([ADR-46](46-incremental-dependency-graph.md)) the table introduces cross-file edges
  (caller's argument types → callee's body diagnostics) that the recorder does not yet
  carry; a cached file whose param seeds changed would serve stale results. Slice 1:
  `parameter_inference:` and `--incremental` are mutually exclusive (the gate refuses,
  with a message), and the edge wiring is the named follow-up before they compose.

  *Lifted 2026-07-30 (#204) — by a table diff, not edge recording.* The pre-pass is
  whole-project by design, so the incremental session recomputes the table each recheck
  and diffs it against the snapshot's stored copy (`Type#==`, the same comparison the
  collector's own fixpoint termination uses): a changed `[class, method, kind]` entry
  re-analyses the callee's file and feeds its `[file, symbol]` pair into the ADR-46
  slice-4 symbol fan-out — a seed change shifts the callee's inferred return exactly the
  way a body edit does, so it reuses the same audited dependents machinery. A missing
  invalidation edge is impossible by construction (the diff compares ground truth, not a
  recorded approximation), which is why this shape won over the caller→callee edge
  recording the follow-up first sketched: it also handles a caller *appearing* in a
  previously-unrelated file, a caller vanishing, and the fail-soft empty table (every
  stored entry reads as removed → those callees re-check) for free. A
  `parameter_inference:` toggle re-fingerprints the snapshot (configuration is part of
  the global fingerprint), so the gate state is constant across a snapshot's lifetime.
  When no file moved, the collector's inputs are unchanged and the re-collect is skipped
  — the ADR-87 null-recheck fast path stays collect-free. The table rides the snapshot
  under the ADR-89 WD2 Marshal-clean filter (a dropped entry re-checks its callee), and
  the diff's pairs deliberately bypass the WD2 behavioural-stability pruning, which
  re-evaluates returns under the OLD seeds — the wrong oracle when the seeds are what
  moved. Gate: the composition specs' full-run-oracle byte-identity plus
  `--verify-incremental`, which now runs (and seeds the subset from the baseline's own
  table).
- **WD6d — the measurement gate (the WD4-of-ADR-93 pattern).** With the gate off: the
  corpus is byte-identical by construction (empty table no-op). With the gate on:
  (1) every diagnostic delta on mail/kramdown/haml/liquid + mastodon models + redmine app
  is hand-adjudicated (expected ≈0 given WD6b guards all negative rules — any new firing
  is a guard hole, fix before landing); (2) the protection lift on the two apps is the
  reported yield; (3) the collector pre-pass cost is measured cold on the largest corpus
  target and the run stays within the perf band (≤5% wall; the pre-pass is the price, so
  report it separately); (4) `RIGOR_BUDGET_TRACE`-style visibility if the round cap bites.
  Default-on is a *separate, later* decision under ADR-50, on this evidence.
WD2 (in-body lower bound) may proceed independently and earlier — it is local and FP-safe.

**WD6 measured + implementation reality (2026-07-19).** Landed behind `parameter_inference:`
(schema-governed, resolved off by every profile); the pre-pass runs `ParameterInferenceCollector.collect`
one round into the check discovery seed (`Runner#seed_parameter_inference` → `project_scope_seed_tables`,
so both the sequential and fork-worker scopes see the same frozen table), and `parameter_inference:` +
`--incremental` is a hard refusal (WD6c). The mark is the ADR-58-WD1 side-mark reused under a distinct
`:inferred_param` kind (`Scope#with_inferred_param_mark` / `#inferred_param?`), stamped in
`build_method_entry_scope` on each seeded parameter.

*The "at minimum the direct param local" propagation scope did not survive contact with the corpus.* The
gate-on diff over the six targets initially surfaced firings across **five** negative rules, none on a
bare parameter receiver: `mail` fired `call.undefined-method` / `argument-type-mismatch` on
`vindex = codepoints[i] - HANGUL_VBASE; vindex < n` (the value flows through a *local* derived from the
param, with a `rescue` modifier unioning it), and `kramdown` / `haml` / `redmine` fired
`flow.always-truthy-condition` / `flow.unreachable-clause` on `if opts.key?(:x)` / `case obj` whose
subject is the parameter itself. The guard therefore had to be three things, all FP-safe by the same
lower-bound argument: (a) a **syntactic root-walk** (`CheckRules::InferredParamGuard.rooted?`) so a
diagnostic against any receiver/argument/subject *rooted at* an inferred parameter declines — through
index (`param[i]`), method chains (`param.foo.bar`), and value-combining forms (`a rescue b`, `&&`,
`||`); it guards `call.undefined-method`, wrong-arity, `argument-type-mismatch`, `possible-nil-receiver`,
`call.visibility-mismatch`, `flow.always-truthy-condition`, and `flow.unreachable-clause`; (b) **sticky
taint propagation** through a local write whose RHS roots at a parameter (`eval_local_write`), so
`vindex` inherits the mark — the mark deliberately does NOT drop on `with_local` (narrowing) and is
cleared only by a genuine non-param rewrite, because the `and`-narrowing between `0 <= v` and `v < n`
would otherwise strip it; (c) a **union join** for the `:inferred_param` kind (the ADR-58 kinds keep
their intersection join), because a value tainted on *either* branch of a merge is a lower bound. This
is more propagation plumbing than the addendum's "if free, take it" anticipated, but the FP mandate is
non-negotiable and each element only ever *suppresses* a diagnostic (a false negative under an opt-in
gate, never a false positive).

*Measured (six targets, `check --no-cache`).* Gate off: byte-identical to master (mail 26=26, redmine
52=52 diagnostics, confirmed against a stashed baseline). Gate on: **zero new firings** on all six after
the guard work above (every initial firing was a guard hole, fixed before landing), and one *removed*
false positive on redmine (`app/models/issue.rb:605` — `allowed_trackers.detect {|t| t.core_fields…}`
no longer fires `possible-nil-receiver`, because the inferred element type proves `t` non-nil). Protection
lift (`coverage --protection`, collector off vs on, cache cleared between A/B): mastodon `app/models`
0.3044 → 0.3122 (+46 protected sites), redmine `app` 0.3161 → 0.3219 (+110 sites). Perf (mastodon
`app/models`, cold, 3 runs): gate off ≈ 2.2 s / 161 MB, unchanged from master (≈ 2.5 s, within noise —
the gate-off guards are O(1) no-ops on an empty mark set); gate on ≈ 3.0 s / 191 MB — the one-round
collector pre-pass is ≈ 0.8 s (+37 % wall, +19 % RSS), well over the 5 % band. Per the addendum the
pre-pass is the *price* of the opt-in and is reported separately; the check walk itself is unchanged
(the byte-identical gate-off run proves it), so the cost is entirely the whole-project re-type the WD3
collector performs. Profiling that re-type (mastodon `app/models`) found ~98 % of it is the per-file
scope-index build (`ScopeIndexer.index` — the flow-sensitive typing pass the collector needs to read
each argument type), unshareable with the check walk because the two build their per-file index under
different seeds; the call-site walk that resolves callees and unions argument types is only ~2 %. A
call-name pre-filter (skip any call whose name no discovered `def` declares — ~73 % of call sites in a
Rails app — before typing its receiver) trimmed the residual and cut allocations ~8 %, table-identical.
This cost is exactly why the gate stays off by default and default-on is deferred.

## Consequences

- **Positive** — closes the dominant remaining protection hole on real applications;
  automates the pilot's single biggest hand-win (param / param-sourced-ivar typing);
  precision-additive by the criterion, so zero new diagnostics.
- **Negative** — WD3 is whole-program-ish, in tension with the per-file model (hence
  budget-gated); WD2 yields only a structural bound. The criterion (no param-boundary
  firing) means the inference buys *protection*, not *more bugs caught at the boundary* —
  by design.
- **Carry-over** — WD2 is the cheap first step (helps even leaf scripts, no call sites);
  WD3 is the app-scale lever but carries the incrementality/cost question.

## Relationship to other ADRs

- **ADR-5** — the reconciliation criterion is its direct application: params stay lenient,
  so inference feeds precision, never boundary diagnostics.
- **ADR-58** — the sibling. Ivar field typing is done; **param-sourced** ivars are *this*
  ADR's job — the explicit M3 frontier ADR-58 scoped out as gradual.
- **ADR-46** — the WD3 call-site pass's affordability depends on the incremental story.
- **ADR-41 / ADR-57** — budget/termination and the run-scoped memo infra WD5 reuses.
- **ADR-63** — the protection pilot that re-opened the excused M3 bucket.
