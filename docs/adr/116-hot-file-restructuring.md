# ADR-116 — Restructuring the engine's hot files: declare each growing kind once, walk each traversal once

Status: **Accepted, 2026-09-23 — scheduled for after the v0.4.0 cut; no slice has landed.** This
ADR fixes the direction, the three criteria, and the slice order (WD0–WD7). Each slice lands as its
own PR in the `v0.4.x` milestone. WD0–WD5 and WD7 preserve behaviour; WD6 changes it and carries
its own corpus diff.

Grounding: [`docs/notes/20260923-hot-file-churn-audit.md`](../notes/20260923-hot-file-churn-audit.md)
(the 60-day churn, growth and co-change measurement, and the mechanisms M1–M6 cited below); its
predecessor [`docs/notes/20260604-structural-repetition-audit.md`](../notes/20260604-structural-repetition-audit.md).

## Context

The goal is a codebase where a change stays local: adding one discovery table, one run-level
fact, or one check rule edits one place, and no file or function grows without bound. Locality is
also a correctness property here. Lists and traversals that are copied by hand drift apart, and the
drift has already produced wrong answers: the pool's sequential fallback drops two signature rows
that the other paths report (M2), and `ExpressionTyper` and `StatementEvaluator` bind block
parameters differently (M4).

The 60-day audit shows where the pressure lands. The 21 `lib/` files of 1,000+ lines hold 40% of
`lib/`, and 44% of `lib/`-touching PRs touched one of the top six. Methods are small (median 7–10
lines) and the classes are not (`ScopeIndexer` 441 methods, `ExpressionTyper` 273). Three mechanisms
drive the co-change:

1. **Hand-written enumerations.** The discovery-table list is written out in about ten places
   across `ScopeIndexer`, `Runner` and the cache layer; adding `prepends`
   ([#1165](https://github.com/rigortype/rigor/pull/1165)) edited eight `lib/` files (M1). A
   run-level fact is listed in four to six files; #725, #788, #801, #848, #854 and #1054 each paid
   that (M2).
2. **Duplicated traversals.** `ScopeIndexer` has 21 recursive walkers, each with its own copy of
   the `class <<`, `Class.new`-family and eval-family context rules. Applying one change to the
   cref/self model to all of them cost #1135 +2,817 lines (M3). Block evaluation is implemented in
   both `ExpressionTyper` and `StatementEvaluator`; it caused 7 of their 14 co-change PRs (M4).
3. **A lint regime that splits inside files.** Every 1,000+-line file disables
   `ClassLength`/`ModuleLength` inline; the method-level cops stay on. The result is more private
   methods in the same class ("split out … to hold its ABC budget"), never a new module.

[ADR-53](53-scope-discovery-index-separation.md) deferred the `ScopeIndexer` walker unification
(Theme B) as "demand-gated", with Track B's shadow harness as its enabling asset. #1135 is that
demand: `scope_indexer.rb` went from 4,822 to 8,317 lines in two weeks.

## Decision

Restructure the hot files along seams that own their state and have a narrow interface, in the
WD order below, starting after v0.4.0. Three criteria decide every cut.

**C1 — Declare once.** A kind whose members are added over time (a discovery table, a run-level
fact, a check rule, a `Scope` advisory side table) is declared in one place. Every stage that must
handle every member — merge, fold, bundle codec, seed, drain, replay, row assembly — iterates the
declarations instead of naming the members. *Test:* if adding one member takes edits in two or
more files that each list the kind's members, the kind needs a declaration.

**C2 — One implementation per traversal semantics.** This is ADR-53 Track B's criterion, extended
from rule collection to indexing: a separate walk, or a separate copy of a walk's context rules,
is justified only by semantics the shared one cannot express. What `self`, the cref and the nesting
are under `class`/`module`, `class <<`, a `Class.new`-family block and an eval-family block is one
model with one implementation; per-table logic plugs into it.

**C3 — Split by seam, not by size.** A cluster leaves its file when it owns its state (ivars,
thread-locals) and its calls back into the rest are few enough to name. What leaves is a module with
an interface, not the same class reopened in another file. Line count draws attention (WD0) but
never chooses the cut.

### Guardrails

- **Behaviour-preserving slices are byte-identical.** `make check`, `make check-plugins` and the
  survey-corpus diagnostics do not change. `make bench-perf` is neutral or better, and the
  per-merge allocation sweep applies.
- **Behaviour changes never ride in a move.** WD6 is its own PR with a corpus false-positive diff.
- **The public surface holds.** `Scope`'s keyed readers stay explicit methods (ADR-53 WD2). The
  `DependencyRecorder` stays the single choke point in those accessors
  ([ADR-46](46-incremental-dependency-graph.md)). The plugin API does not change.
- **Declarations are plain data plus module functions.** They must stay Marshal-clean for seed
  bundles and fork payloads, and Ractor-shareable with no closures
  ([ADR-15](15-ractor-concurrency.md)). No `define_method`-generated readers: Rigor checks itself,
  and generated readers lose their types. `SCHEMA` bumps stay manual.
- **Diagnostic row order stays explicit.** A run-level fact's declaration carries its row position,
  because `docs/type-specification/diagnostic-policy.md` fixes the order.

## Working decisions — the slices, in order

- **WD0 — File-size ratchet.** A spec gate, like [ADR-97](97-adr-index-budgets.md)'s index budgets,
  records a line budget for each `lib/` file of 1,000+ lines:
  - growing past the budget fails;
  - raising a budget is an explicit diff in the PR that needs it;
  - a new file that crosses 1,000 lines needs an entry;
  - a split lowers its file's budget.

  The inline cop disables stay; the ratchet is the control. It lands first, so the budgets exist
  before the splits shrink them.
- **WD1 — `CheckRules` by rule.** `call_node_diagnostics` (`check_rules.rb` ~L267) already calls ten
  rule entries in sequence. Each rule becomes a `check_rules/<rule>.rb` module with one entry.
  Suppression parsing (~L447–660) becomes one more module, and the shared receiver predicates
  (`lookup_method`, `concrete_class_name`, `project_defines_method?`, …) one shared module. This is
  a pure move; the largest pieces are undefined-method (~L664–1507) and argument-type (~L2621–3230).
- **WD2 — Discovery-table declarations (C1).** Each `DiscoveryIndex` table declares:
  - its empty value;
  - its per-file-over-seed merge;
  - its cross-file fold — later-wins, first-wins, nearest-first list, set union, or envelope join;
  - its seed-bundle codec — identity for plain data, `DefHandle` for def-node tables
    ([ADR-85](85-seed-bundles-and-lazy-def-node-handles.md)).

  `ScopeIndexer#merge_project_method_indexes` (~L199), `#fold_file_index` (~L6756),
  `#build_seed_bundle` (~L6871) and `#bundle_to_file_index` (~L6923) then iterate the declarations.
  `Runner` holds one discovery value in place of the ivars `#apply_discovery_result` (~L1453) copies
  and `#project_scope_seed_tables` (~L1958) re-lists. *Done when:* a new table is its collector,
  one declaration and a `SCHEMA` bump.
- **WD3 — Run-level fact registry (C1).** Each fact declares:
  - its name and empty value;
  - its merge rule — de-duplicating union, first-wins, or assignment;
  - its source — the coordinator's environment, or drained from the analysing process;
  - whether an incremental run may replay it;
  - its row builder and row position.

  `RunSnapshots` becomes a keyed store, and `DiagnosticAggregator` reads that store instead of one
  lambda per slot (`runner.rb` ~L1732). The coordinator paths call one harvest and one absorb. A
  `WorkerPayload` value replaces the four merge sites in `PoolCoordinator`, and reporters snapshot
  and absorb themselves. When a fact is collected stays with each backend: before the fork for
  #798, after the loop for #696. *Done when:* a new stream like #801 or #854 touches only its
  reporter and its row.
- **WD4 — Extract user-method return inference from `ExpressionTyper` (C3).** This is ~L1862–3527:
  resolution and the override gate, the memo, recursion guard and fixpoint, and body-scope and
  parameter binding. It owns ten thread-local keys and reaches the rest of `ExpressionTyper` only
  through `dynamic_top` and one `type_of`. `return_type_for` and `harvest_return_memo` are already
  its public face. Known blockers:
  - `return_memo_taint_spec` reads the file as text;
  - `class_graph_memo_slot_spec` sends `class_graph_buckets`, which the dispatch cluster also needs;
  - two specs pin thread-local key names;
  - `sig/rigor/inference.rbs` has an `ExpressionTyper` block to update.

  Block-return typing and the per-element folds (~L3601–4713) may then move together as a pure
  move; that is optional.
- **WD5 — One declaration-context walk for `ScopeIndexer` (C2; ADR-53 Theme B).**
  - *Design.* A context value carries the qualified prefix, the rebound self or def owner, the
    singleton-cref flag, the nesting, the default scope and nameability. One traversal owns the
    `class`/`module`, `class <<`, `Class.new`-family and eval-family rules. Each table becomes a
    collector that receives events (declaration, def, call, constant write, …) and may decline
    descent.
  - *Order.* Extract the context model first. Next, port two walkers, `walk_class_cvars` (~L1770)
    and `walk_class_superclasses` (~L4632), behind a shadow mode that asserts table equality on
    the self-check tree and the corpus. Then port the rest.
  - *Precondition.* The `RIGOR_SHADOW_RULE_WALK` harness is extended from rule collectors to
    discovery tables.
  - *Payoff.* The walkers share one traversal per file.
  - *Scope limit.* The rule walk stays separate. ADR-53's rejection of folding rule collectors into
    indexing still holds.
  - *Amendment rule.* If the event set needs a traversal contract beyond these, amend this ADR
    before porting further.
- **WD6 — One block-entry model for `ExpressionTyper` and `StatementEvaluator` (behaviour change).**
  - *Problem.* Block entry-scope construction exists three times: ET ~L3690–3726, SE ~L2984–3061,
    and the per-element folds. The jump-target scans (ET ~L3818, SE ~L1327) disagree on boundary
    nodes.
  - *Change.* Unify both into one module that both typers call. #1020 is the precedent: ET
    delegated value-position `&&`/`||` to SE.
  - *Verification.* The slice carries a corpus false-positive diff. It also updates
    `docs/type-specification/` wherever a binding rule changes.
- **WD7 — Smaller seams, taken when their file next becomes a co-change hotspot.**
  - `Scope`'s class-graph queries (~L630–1500 read only `@discovery`) move behind `DiscoveryIndex`,
    with `Scope` delegating.
  - The four identity-keyed advisory tables (`dynamic_origins`, `void_origins`,
    `plugin_typed_calls`, `optimistic_origins`) become one threaded object, so a fifth does not
    touch `initialize`, `rebuild` and `build_joined_scope`.
  - `RbsLoader`'s stateless class-level environment assembly (~L64–1410) separates from its instance
    query and failure-report surface.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| One big-bang rewrite of the hot files | Rejected | No byte-identical checkpoint between start and end, and it conflicts with every in-flight branch. |
| Enforce `ClassLength`/`ModuleLength` by removing the inline disables | Rejected | Line pressure would pick the cut. The ABC-budget splits show what that yields: more methods in the same class, not seams (C3). |
| Reopen the same class across files, or include partial modules | Rejected as an end state | Shortens files without shrinking the interface or the shared state, so nothing gains locality. |
| Metaprogrammed registries (`define_method` readers per table) | Rejected | Rigor checks itself; generated readers type as `Dynamic`, and the plugin-facing readers must stay explicit. |
| Start before v0.4.0 | Deferred (maintainer decision) | v0.4.0 carries the allocation-band work (#1046, #775, #820) and run-level row fixes (#980, #789) in these files, plus corpus diffs for type-model changes. A concurrent restructuring would confound each of those measurements and conflict with their branches. |
| Unify block evaluation inside WD4 | Rejected | It would mix a behaviour change into a move. |
| Rewrite all of `ScopeIndexer` as one generic visitor at once | Rejected | Port walker by walker behind the shadow harness instead (WD5). |

## Consequences

Positive:

- Adding a discovery table, a run-level fact or a check rule becomes a one-declaration change, and
  the drift class behind the fallback's dropped rows becomes unrepresentable.
- `ScopeIndexer`'s per-file walks fall from about twenty to one; the seed pass is the open warm-run
  lever.
- Budgets make file growth a reviewed decision rather than a side effect.

Negative:

- There will be a period of structural churn in the hottest files, and in-flight branches on them
  will conflict. Mitigation: land each slice small and early in the window, one hot file at a time.
- A registry makes "where is table X merged?" a lookup through its declaration rather than a grep
  for its name. Mitigation: one declaration file per kind.
- WD5's harness extension is real work before any payoff.

Carry-over: after WD2 and WD3, re-run the audit's co-change query. The pairs
`scope_indexer`↔`scope`↔`incremental_snapshot`↔`runner` and
`pool_coordinator`↔`worker_session`↔`diagnostic_aggregator` should fall.

## Relationship to other ADRs

- [ADR-53](53-scope-discovery-index-separation.md):
  - Track A made `DiscoveryIndex` the table carrier; WD2 and WD7 continue it.
  - Track B's walk criterion is C2's source.
  - Its Theme B deferral is partially superseded by WD5 (marked in place there).
- [ADR-52](52-compiled-plugin-contribution-dispatch.md) — its engine-owned plugin walk is the
  one-walk model WD5 applies to indexing.
- [ADR-46](46-incremental-dependency-graph.md) — the recorder choke point in the guardrails.
- [ADR-85](85-seed-bundles-and-lazy-def-node-handles.md) — the seed bundles WD2's codecs serialize.
- [ADR-15](15-ractor-concurrency.md) — the shareability constraint on declarations.
- [ADR-97](97-adr-index-budgets.md) — the budget-gate precedent for WD0.
- [ADR-4](4-type-inference-engine.md) — the `ExpressionTyper` / `StatementEvaluator` roles that WD4
  and WD6 keep.
