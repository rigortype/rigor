# ADR-116 — Restructuring the engine's hot files: declare each growing kind once, walk each traversal once

Status: **Accepted, 2026-09-23; WD5 amended 2026-09-27 (context-rule variants, below).** WD0 (#1192) and WD1 (#1193) have landed.
WD5 is in progress. Its first slice (#1517: the discovery-table shadow harness, the context model,
`class_cvars`) and its second (#1522: the superclass tables, with the first variants) put two tables
on the walk. Its third (#1527: the def-nesting and member-layout tables) makes the walk shared: it
builds five tables in one run per file. This ADR fixes the direction, the three criteria, and the
slice order (WD0–WD7). Each slice lands as its own PR in the `v0.4.x` milestone, tracked by
#1192–#1199 (WD0–WD7). WD0–WD5 and WD7 preserve behaviour; WD6 changes it and carries its own corpus
diff. **Amended 2026-11-17** after a re-measurement: criterion C4 and slices WD8–WD13 are added
([below](#amendment-2026-11-17--what-the-re-measurement-added)). **Campaign closed 2026-11-18** at the pure
moves; the slices not yet started are separate design tasks
([below](#landing-point-2026-11-18--the-pure-moves-are-done-the-rest-is-design)). **Amended 2026-11-19**
with WD12's interface, the first of those designs: the call-typing order as one declared ladder
([below](#amendment-2026-11-19--wd12s-interface-3345)).

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

- **WD0 — File-size ratchet (#1192).** A spec gate, like [ADR-97](97-adr-index-budgets.md)'s index
  budgets, records a line budget for each `lib/` file of 1,000+ lines:
  - growing past the budget fails;
  - raising a budget is an explicit diff in the PR that needs it;
  - a new file that crosses 1,000 lines needs an entry;
  - a split lowers its file's budget.

  The inline cop disables stay; the ratchet is the control. It lands first, so the budgets exist
  before the splits shrink them.
  WD0 has landed: the gate is `spec/docs/lib_file_budgets_spec.rb`, its budgets are in
  `spec/docs/lib_file_budgets.yml`. A budget is a multiple of 100 that is at least its file's line count and less than 200 above it,
  not the exact count: a bucket keeps in-flight PRs on one file from editing the same row. The rows
  start at the smallest such multiple; growth inside a bucket is not gated. The rule and its reasons
  are in the gate's header.
- **WD1 — `CheckRules` by rule (#1193).** `call_node_diagnostics` (`check_rules.rb` ~L267) already
  calls ten rule entries in sequence. Each rule becomes a `check_rules/<rule>.rb` module with one entry.
  Suppression parsing (~L447–660) becomes one more module, and the shared receiver predicates
  (`lookup_method`, `concrete_class_name`, `project_defines_method?`, …) one shared module. This is
  a pure move; the largest pieces are undefined-method (~L664–1507) and argument-type (~L2621–3230).
  Landed 2026-11-17 in five slices (#3290, #3294, #3301, #3306 and #3308): `check_rules.rb` now holds only
  the orchestration (`diagnose`, the node-collector construction and driving, the per-node dispatch
  and the suppression delegators); every rule is its own module under `check_rules/`.
- **WD2 — Discovery-table declarations (C1; #1194).** Each `DiscoveryIndex` table declares:
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
- **WD3 — Run-level fact registry (C1; #1195).** Each fact declares:
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
- **WD4 — Extract user-method return inference from `ExpressionTyper` (C3; #1196).** This is
  ~L1862–3527: resolution and the override gate, the memo, recursion guard and fixpoint, and
  body-scope and parameter binding. It owns ten thread-local keys and reaches the rest of
  `ExpressionTyper` only through `dynamic_top` and one `type_of`. `return_type_for` and
  `harvest_return_memo` are already its public face. Known blockers:
  - `return_memo_taint_spec` reads the file as text;
  - `class_graph_memo_slot_spec` sends `class_graph_buckets`, which the dispatch cluster also needs;
  - two specs pin thread-local key names;
  - `sig/rigor/inference.rbs` has an `ExpressionTyper` block to update.

  Block-return typing and the per-element folds (~L3601–4713) may then move together as a pure
  move; that is optional.
- **WD5 — One declaration-context walk for `ScopeIndexer` (C2; ADR-53 Theme B; #1197).**
  - *Design.* A context value carries the qualified prefix, the rebound self or def owner, the
    singleton-cref flag, the nesting, the default scope and nameability. One traversal owns the
    `class`/`module`, `class <<`, `Class.new`-family and eval-family rules. Each table becomes a
    collector that receives events (declaration, def, call, constant write, …) and may decline
    descent.
  - *Order.* Extract the context model first. Next, port two walkers, `walk_class_cvars` (~L1973)
    and `walk_class_superclasses` (~L5079), behind a shadow mode that asserts table equality on
    the self-check tree and the corpus. Then port the rest.
  - *Precondition.* The `RIGOR_SHADOW_RULE_WALK` harness is extended from rule collectors to
    discovery tables. *Harness contract (amended with #1522):* a divergence in a file's own index
    reports as an error row on the file. A divergence in the cross-file project pre-pass aborts the
    run. The pre-pass loops skip a file they cannot read or parse, and the run-result cache path
    falls back to an uncached run on an error. Both let `DeclarationWalk::ContractError` through: a
    divergence or a collector naming a variant no rule has. Skipping the file would hide the failure
    and drop the file from the project index, and the fallback would report the false positives of a
    run without one.
  - *Payoff.* The walkers share one traversal per file.
  - *Scope limit.* The rule walk stays separate. ADR-53's rejection of folding rule collectors into
    indexing still holds.
  - *Amendment rule.* If the event set needs a traversal contract beyond these, amend this ADR
    before porting further.
  - *Variants (amendment, 2026-09-27; maintainer decision on #1197).* The walkers do not share one
    set of context rules. Building #1517 found 12 categories of disagreement. Bare factory blocks
    alone are handled five ways, and `walk_class_superclasses` walks one as an ordinary call where
    `walk_class_cvars` rebinds `self` to an unnamed class. A port reproduces its walker byte for
    byte, so where a walker departs from the walk's rule, the walk implements that departure once, as
    a named **variant** of the rule, and the collector names the variant it follows.
    - Each variant is documented where it is declared: the disagreement, which legacy walker it
      reproduces, and the convergence item that retires it.
    - Collectors that name different variants of one rule still share the traversal. The walk goes
      once through the parts every variant walks under the same context. It goes through a subtree
      once per variant in use only where the variants give that subtree different contexts.
    - Converging the variants is separate, behaviour-changing work: one PR per category, each with a
      corpus diff, tracked in #1521. It does not hold up the ports, and a port never converges a
      variant.
    - Not chosen: fixing every disagreement before porting. That would put 12 behaviour changes in
      front of the walk merge, which is the wall lever.
    - `class_cvars` follows the walk's rules and names none. Carrying both nesting chains, the census
      scope's and the ancestry one, is not a variant: both are fields of the context value above.
    - *Mechanism (slice 2, #1522, the `walk_class_superclasses` port).*
      - `DeclarationWalk::RULE_VARIANTS` lists each rule a collector may depart from, with its
        variants; the first is the walk's own. A collector class names its departures in `VARIANTS`,
        and the walk and the collector both read them through the class. A name no rule has raises
        `DeclarationWalk::UnknownVariant`, a `ContractError` (see the harness contract above).
      - `factory_block` is a traversal rule. `:unnamed_self` is the walk's arm; `:ordinary_call` walks a
        bare factory block as any call (#1521 item 8). In a run that mixes the two, the walk visits
        the factory call's receiver and arguments once, for every collector, because both variants
        walk them under the same context. It forks only at the block: the `:unnamed_self` collectors
        walk its body with an unnamed `self`, and the `:ordinary_call` ones walk the whole block under
        the enclosing context. Every collector sees exactly the events, in order, of a run of its own.
      - `anonymous_class_path` is a value rule: `Context#anonymous_class_path(variant)` answers it.
        `:whole_file` is the walk's rule; `:outside_class_bodies` drops the path inside class/module,
        meta-new and eval-family bodies but not in `class <<` (#1521 item 11). It needed two context
        fields, `source_path` and a `class_body` latch. No event was added.
    - *The first shared walk (slice 3, #1527).*
      - `ScopeIndexer.declaration_walk_tables` runs three collectors in one walk of a file:
        `SuperclassesCollector`, `DefNestingsCollector` (for `walk_def_nestings`) and
        `MemberLayoutsCollector` (for `walk_data_member_layouts` and `walk_struct_member_layouts`,
        which applied the same rules in two walks). It builds five tables: superclasses, header
        nestings, def nestings, and the `Data` and `Struct` member layouts.
      - Both production sites read those tables from that walk: the per-file index
        (`merge_project_method_indexes`) and the project pre-pass (`accumulate_project_index`).
        Before this slice, each site walked the file four times for them. Nothing in `lib` calls the
        standalone builders any longer. They stay for the specs, which compare each collector run alone
        against the shared run. Under `RIGOR_SHADOW_RULE_WALK`, each table is still checked against its
        legacy walker.
      - `unrendered_header` is a new traversal rule. It covers a `class` / `module` header that renders
        no name, which only a parse error produces (`class foo`, or a `module` keyword followed by a
        `def`). `:children` is the walk's rule, `walk_class_superclasses`': walk every child under the
        enclosing context. `:skip` walks nothing below the header (the member-layout walkers).
        `:body_with_lost_nesting` walks only the body, under `Context#lost_header_body`
        (`walk_def_nestings`). That context makes `self` the class again. It keeps the nesting chain
        below an unnameable cref and loses it (nil) elsewhere, and only a `self::` header below a
        rebound `self` grows it again (#1521 item 3). `Context#nesting` answers nil both for a lost
        chain and for one the caller does not track. The context keeps the two apart: only a lost chain
        grows again, and an untracked one stays nil everywhere.
      - `lexical_prefix` is a new value rule, and the traversal consults it. It picks the prefix that
        meta-new and eval-family splits resolve against, and `Context#lexical_prefix(variant)` answers
        it. `:prefix` is the walk's rule. `:nesting_head` is `walk_def_nestings`': the innermost
        nesting entry split into segments. The two differ below a compact header (`["Admin::W"]`
        against `["Admin", "W"]`) and below an unnameable cref (`[]` against the enclosing entry)
        (#1521 item 1). When a run mixes the two, the walk splits a rebound body a second time with the
        head. If the two owners agree, it walks the body once for everyone. If they differ, it walks
        the body once per owner, and each collector goes down only with its own group.
      - No event was added. Multi-collector runs now build the collector subsets they need lazily and
        memoise them per run: a collector alone, the run without one collector, and the run split by
        variant. Asking the collectors allocates nothing, so a node costs no object where no collector
        declines, or where one does and its remainder is already memoised. A decline inside a variant
        fork's group of three or more, or two declines at one node, copies one Array.
      - *Acceptance.* Every table stays equal, under the strict `Shadow` comparer, to what its legacy
        walker builds. At landing this held for 67,137 files (this repo, the survey corpora and gitlab)
        and 12,000 fuzzed programs, and `RIGOR_SHADOW_RULE_WALK` keeps checking it.
      - The other walkers that `merge_project_method_indexes` and the pre-pass call stay on their
        legacy walkers for now. Each needs a traversal contract beyond these events, so porting one
        requires amending this ADR first (the amendment rule above).
        - `walk_class_includes` (includes and prepends) rebinds the owner at every block through
          `rebound_block_self`, including `define_method` and non-constant receivers as opaque. It
          resolves eval receivers as written and walks block parameters.
        - `walk_class_extends` skips `END { }`. Its `in_singleton` depth flag keeps the owner only
          for the first `class << self`. It does not walk a block-carrying call outside its own arms
          at all: receiver, arguments and block are all skipped.
        - `walk_method_visibilities` and `walk_singleton_def_nodes` thread state from one sibling
          statement to the next: the default visibility, and the `module_function` toggle. A
          per-node event cannot carry that state.
- **WD6 — One block-entry model for `ExpressionTyper` and `StatementEvaluator` (behaviour change;
  #1198).**
  - *Problem.* Block entry-scope construction exists three times: ET ~L3690–3726, SE ~L2984–3061,
    and the per-element folds. The jump-target scans (ET ~L3818, SE ~L1327) disagree on boundary
    nodes.
  - *Change.* Unify both into one module that both typers call. #1020 is the precedent: ET
    delegated value-position `&&`/`||` to SE.
  - *Verification.* The slice carries a corpus false-positive diff. It also updates
    `docs/type-specification/` wherever a binding rule changes.
- **WD7 — Smaller seams, taken when their file next becomes a co-change hotspot (#1199).**
  - `Scope`'s class-graph queries (~L630–1500 read only `@discovery`) move behind `DiscoveryIndex`,
    with `Scope` delegating.
  - The four identity-keyed advisory tables (`dynamic_origins`, `void_origins`,
    `plugin_typed_calls`, `optimistic_origins`) become one threaded object, so a fifth does not
    touch `initialize`, `rebuild` and `build_joined_scope`.
  - `RbsLoader`'s stateless class-level environment assembly (~L64–1410) separates from its instance
    query and failure-report surface.

## Amendment, 2026-11-17 — what the re-measurement added

Eight weeks after acceptance the files this ADR targets had grown, not shrunk. Only WD3 had closed;
WD5 was partly ported, as the status paragraph records.

| File | 2026-09-23 | 2026-11-17 |
| --- | --- | --- |
| `inference/scope_indexer.rb` | 8,317 | 14,181 |
| `inference/statement_evaluator.rb` | 3,995 | 10,343 |
| `inference/expression_typer.rb` | 4,713 | 7,279 |
| `analysis/check_rules.rb` | 3,746 | 5,228 |
| `scope.rb` | 1,883 | 3,207 |

Of the 665 first-parent merges that touched `lib/` in the 60 days to 2026-11-17, 293 (44%) touched
one of the first three files. The method is the churn audit's; the numbers were taken at `master`
`0a843c261`. A reference count below is a `grep` for the name over the files named, outside comments. The line numbers in the working decisions above are from September and are stale: find
a cluster by its method names.

The direction, C1–C3 and the guardrails stand. The re-measurement found four things they do not
cover.

1. **Nothing stopped the growth.** WD0 was the control and had not landed. It lands first, before
   any other slice here.
2. **The growth is wiring, not traversal.** A floor, census or widening feature puts its AST scan in
   a sibling file under `inference/` (135 files were added there in the window), and leaves in
   `StatementEvaluator` the decision of which statement kinds call it. `StatementEvaluator` names 62
   of the modules that sit beside it in `inference/`, at 379 sites outside comments (`CapturedLocals`
   at 51, `MutationWidening` at 21). In `ScopeIndexer` the `walk_*` methods are a minority of each
   unported walker cluster and the fact-recording logic is the rest, so WD5 removes the copies of
   the context rules but little of the volume.
3. **Names do not predict content.** About 5% of `scope_indexer.rb` is the per-node scope index
   (`index`, `propagate`); the rest is project-wide declaration discovery, and `module_function`
   makes each of its roughly 800 methods public, and files outside `inference/scope_indexer/` call
   more than forty of them. `inference/` and `scope/` name `Analysis::DependencyRecorder` about 185
   times, against the layering. The
   dispatch tier order is split between `ExpressionTyper#call_result_type_for` and
   `MethodDispatcher#resolve`, in two tier shapes.
4. **The specs do not follow the modules.** 310 of 686 `lib/` files have no same-named spec, and 345
   of 721 spec files under `spec/rigor/` name no `lib/` file. An example that runs the whole runner
   costs 200–400 ms, one that types a snippet against `Scope.empty` 1–3 ms, and one on plain data
   under 1 ms (the runs are in the code map); about 90 of the 126 spec files under `spec/rigor/analysis/` use the runner, including all
   282 examples of `runner_check_rules_spec.rb`, although `CheckRules` is a stateless module.

### C4 — A module that leaves takes its specs with it

A slice that moves a cluster into a module also gives that module a spec named for it, in the
cheapest style that can see its behaviour (the three styles are in
[`docs/agents/code-map.md`](../agents/code-map.md)). The examples that pinned the cluster through
the runner move there when they can be rewritten against the module's interface without losing
what they check, and stay where they are otherwise. *Test:* after the slice, editing the module
selects its spec in `make verify-changed` by the mirror rule, and that spec fails when the module's
behaviour is broken.

C4 is why splitting alone does not shorten the edit loop: the cost is in the example style and in
which specs an edit selects, not in file size. #3277 adds the tier that runs only the selected
specs.

### Added slices

Pure moves, each byte-identical under the guardrails and independent of the others. Each was
measured on 2026-11-17 as already self-contained: its out-calls can be named.

- **WD1** stands as written. `check_rules.rb` shares about ten helpers between rules
  (`concrete_class_name`, `lookup_method`, `receiver_signature`, `trustworthy_signature`,
  `strip_root`, …); they become the shared module WD1 names. Each collector's message builder moves
  next to its collector.
- **WD4 and WD7** stand. Further candidates of the same kind: `ExpressionTyper`'s plain per-node
  typers, which call only `type_of` and `dynamic_top`; `StatementEvaluator`'s pattern-matching and
  rescue binding, its class-body and method-entry scope, and its def-argument and assertion
  clusters; `Narrowing`'s leaf clusters; `Runner`'s run key and dependency descriptor, its seed
  tables, and its effect-cache serve and store; `Configuration`'s validators, defaults and loader;
  `ScopeIndexer.propagate`.

Slices that need a design before they start. Each amends this ADR with its interface first, as WD5's
amendment rule requires.

- **WD8 — A statement-kind hook point for `StatementEvaluator` (C1 applied to wiring).** A flow
  feature declares which statement kinds it attaches to and what it does to the scope there, and
  `StatementEvaluator` iterates the declarations at each kind. *Done when:* a new floor or census
  feature is its own file and one declaration. *Open:* the features do not share one shape today
  (some rewrite the scope after a statement, some gate a narrowing, some run a census before the
  walk), and the order they run in matters; the design has to find the kinds and say which features
  stay hand-wired. It follows the declaration guardrail: plain data and module functions, no
  generated methods.
- **WD9 — The declaration-context rules leave `ScopeIndexer`.** A small set of methods
  (`unnameable_decl?`, `self_anchored_decl_prefix`, the `meta_new_*` family, `eval_receiver_prefix`,
  `unnameable_eval_self?`, …) is called from most of the walker clusters, and
  `DeclarationWalk::Context` calls back into them, so the walk and the indexer depend on each other.
  They move to the walk's side. This is WD5's "extract the context model first", finished, and it
  is what lets the per-table clusters leave.
- **WD10 — `ScopeIndexer` splits by responsibility.** The per-node scope index keeps the name. The
  declaration collectors, the cross-file fold and the seed-bundle codec become a discovery namespace.
  The methods other files call today are the starting inventory for its interface, not the
  interface. It follows WD2 and WD9. Path-keyed gates
  move in the same PR: the `scope_indexer.rb` entry of
  `spec/rigor/declaration_facts/producers.yml` is 326 lines.
- **WD11 — The engine's services leave `analysis/`.** `DependencyRecorder`, the flow `FactStore` and
  the rule guards that `inference/` calls move below the engine, so that `inference/` and `scope/`
  no longer reference `Analysis`. A rename with no behaviour change, but it touches about 190 sites,
  so it lands alone.
- **WD12 — One dispatch ladder (C1).** The tier order is declared in one place, including the tiers
  that run from `ExpressionTyper#call_result_type_for` today. Most tiers already share
  `try_dispatch(CallContext)`; whether the rest can take that shape is the design question.
  *Interface (amendment, 2026-11-19; #3345):* they take the same `CallContext` and the typer beside
  it, as `try_call(site, typer)`; the order is one table that a spec holds the code to
  ([below](#amendment-2026-11-19--wd12s-interface-3345)).
- **WD13 — C1 for the remaining hand-listed kinds:** a rule id, a CLI command, a
  configuration key and a plugin hook. The lists are in the code map. Each kind is its own slice,
  taken when its files next become a co-change hotspot, as WD7 is.

### Order and procedure

1. WD0, the quick tier of `verify-changed` (#3277) and the code map (#3278), which move no code.
2. The pure moves, WD1 first. Up to three run at a time on different files. Each is small-model lane
   work: the contract is byte-identical output, and the review checks that nothing but the location
   changed.
3. WD9, then WD2, then WD10; WD8 as soon as its design is accepted, since it is the largest lever on
   `StatementEvaluator`'s growth. WD11–WD13 as they become hotspots.

A slice on one of the six hottest files is announced before it starts and lands within the day:
about fifteen PRs merge a day, and a move that stays open collides with each of them. Feature
lanes on that file wait for it or rebase onto it.

## Landing point, 2026-11-18 — the pure moves are done; the rest is design

The maintainer closed the restructuring campaign at this line on 2026-11-18.

**Landed.** Step 1 and step 2 of "Order and procedure": WD0, the quick tier, the code map, and eleven
pure moves. `check_rules.rb` went from 5,228 lines to 363, `configuration.rb` from 1,335 to 527,
`narrowing.rb` from 4,180 to 2,989, `runner.rb` from 3,066 to 2,818, `scope_indexer.rb` from 14,173
to 13,704, `statement_evaluator.rb` from 10,335 to 9,476, and `expression_typer.rb` from 7,269 to
6,592. `spec/docs/lib_file_budgets.yml` holds each file at its new size.

**Not part of the campaign any more.** Step 3 — WD8, WD9, WD2, WD10 and WD11–WD13. What is left in
`scope_indexer.rb`, `statement_evaluator.rb` and `expression_typer.rb` does not pass the rule for
leaving a stateful class (it writes an instance variable, or reads state that changes during the
walk), so taking it out is a decomposition of that class, not a move. Each of those slices is its
own design task with its own issue (#3344 for `StatementEvaluator`, #3345 for `ExpressionTyper`,
#3346 for `ScopeIndexer`; #3286 for what remains of `Runner`) and starts when its design is accepted, not because this ADR lists it.

> **Qualified 2026-11-19** by [WD12's interface](#amendment-2026-11-19--wd12s-interface-3345), "Filed
> outside WD12". One cluster of `expression_typer.rb` was not measured for the sentence above: block
> typing and the receiver folds, which a static census puts one callback over the rule.
> [#3359](https://github.com/rigortype/rigor/issues/3359) decides whether it moves.

**Owed under this ADR and since landed.** #3289 (#3349): the quick tier's directory mirror was capped by a count
of spec files, which stopped selecting a directory's specs once it grew past the cap; it is now a time
budget read from `tool/spec_costs.tsv`.

A file at its budget is the signal to look for a seam, not to raise the number: new logic that has a
seam goes into its own file from the start (`inference/loop_store_sites.rb` is the first case).

## Amendment, 2026-11-19 — WD12's interface (#3345)

WD12 asked whether the tiers that run from `ExpressionTyper#call_result_type_for` can take the
dispatcher's `try_dispatch(CallContext)` shape. They take the same value and need the typer beside
it. This section is the interface WD5's amendment rule requires before any of WD12's code moves
([#3345](https://github.com/rigortype/rigor/issues/3345)). Below, the *ladder* is the order in which a
call is typed; a *rung* is one step of it in the typer, a *tier* one step inside the dispatcher, and
the *site* is the `CallContext` of one call.

### What was measured

At `master` `bc791f6d9`. A *static census* figure is read from a syntactic call graph of the class;
a call made through a local alias would escape it.

- **Who answers.** One `--workers=0` check of `lib/rigor/inference` typed 1,058,027 calls. Indexed
  narrowing answered 0.47% of them ahead of the ladder. The rungs ahead of the dispatcher answered
  0.11%, the dispatcher 45.09% and the rungs behind it 54.33%.
- **The order changes rarely and is copied by hand.** Of the 113 first-parent merges that touched
  `expression_typer.rb` from 2026-09-19 to 2026-11-17, 3 edited the order in `call_result_type_for`
  (#1747, #1811 and #1836, all for [ADR-121](121-ruby-refinement-typing.md)). The typer writes the
  order in full once, for a call (`call_result_type_for`, continued in `dispatch_miss_result`), and
  writes three shorter copies of it:
  - the read of `c[k] += v` (`implicit_index_read_type`): overriding def, dispatcher, user method,
    project singleton;
  - the same read under a splat index (`splat_index_read_type`): the overriding-def check, then the
    dispatcher;
  - a literal `send`'s target (`try_literal_send`): dispatcher, user method, project singleton.

  The copies have drifted. The index read leaves out refined dispatch, so `h[:a]` honours a
  refinement of `[]` and `h[:a] += v` does not (probed; #3358).
- **What a rung reads.** Every argument the ten rungs around the dispatcher take is a `CallContext`
  field. Beyond those they read the typer: `type_of`, body inference (which reads the node being
  typed), re-entry into the ladder with another receiver, and the fallback that records on the tracer.
- **The dispatcher.** 27 tier modules already have `try_dispatch(CallContext)`. Twelve more tiers
  are calls to eleven private functions of `method_dispatcher.rb`, whose inputs are `CallContext`
  fields and two parameters of `resolve`. That file is 1,880 lines against a budget of 1,900;
  `expression_typer.rb` is 6,592 against 6,600.
- **The per-node typers.** `PRISM_DISPATCH` has 136 rows naming 60 handlers, and 2 of the 113
  merges changed a row. `type_of` ran 3,682,018 times in the census run.

### Decision

The order is rarely edited, so the table is not there to save edits. It ends the drift between the
hand-made copies, and it gives the next rung a home outside a file that is 8 lines under its budget.

**Scope.** WD12 is the call-typing order. The typer's rungs are declared as rows, the dispatcher
one of them; the dispatcher's interior order stays `MethodDispatcher`'s own. Three neighbours are
outside it.

- *The per-node typers get no seam*, although #3345 is titled for them. `PRISM_DISPATCH` is already
  their one declaration, so C1's test does not fire. A module of them is all entries (`LeafNodes`
  was 29 entries for 30 methods, and went back in #3319), and a second hop per node would be paid on
  `type_of`, the hottest call in the engine.
- *The result adjustments around the ladder stay hand-written in the typer*: safe navigation, the
  `each_with_object` memo, `find` / `detect` narrowing, an attribute write answering its right-hand
  side, and the widenings in `call_dispatch_type_for`. They transform an answer; none gives one.
- *Indexed and method-chain narrowing stays ahead of the ladder, in the typer.* It answers before the
  operands are typed, so no site exists yet.

**One declaration, and a spec that holds the code to it.**
`Rigor::Inference::CallLadder::RUNGS`, in `lib/rigor/inference/call_ladder.rb`, is plain frozen
data: one row per rung, in order, with the entries that ask it (`call`, `index_read`,
`send_target`). The dispatcher is one row, asked by all three; its interior order is not in
`RUNGS`. No method is generated from the table, and no rung is wrapped in an adapter to fit it.

A spec reads the typer's code with Prism and fails unless the rung calls appear in the order, and
in the subsets, that the table declares. It covers every place where the typer writes a sequence of
two or more rungs: `call_result_type_for` with `dispatch_miss_result`, `implicit_index_read_type`,
`splat_index_read_type` and the sub-ladder in `try_literal_send`. The index read's missing rung is a
named exception row, which #3358's fix deletes. The splat index read is a second named exception,
not a fourth entry: it asks `OverridingDef`'s gate (`overriding_own_def?`, answering `dynamic_top`)
in place of the rung, then the dispatcher, because a splat index has no positional argument types
for the rung to bind, and the spec checks that sequence against an exception row that says so, so a
later change to it fails. The row names the typer's `overriding_own_def?` until S8, and
`OverridingDef`'s gate entry after. A place that asks one rung is not an order and is not checked:
`own_send_type`, which asks user-method inference alone, and the calls that only dispatch
(`attribute_compound_read_type`, `call_operator_write_type_for` and the 11 other call sites of
`MethodDispatcher.dispatch` in `lib/`).

**A rung module.** A rung becomes a module under `call_ladder/` whose entry is
`try_call(site, typer)`, in the pull request that moves its body and not before. The entry is not
named `try_dispatch`: a tier takes the site alone and must not type anything.

- *`typer` is the frame.* The rung receives the walking `ExpressionTyper`, which already exists, so
  nothing is allocated for it. It calls only the names in `CallLadder::PORT`; a spec checks every
  call a rung makes on the typer against that list, `send` included. It reads the scope as
  `typer.scope`: the first rung slice makes `ExpressionTyper#scope` public and a `PORT` member, and
  `sig/` already declares it `-> Scope`. `CallContext#scope` is `untyped` there, and reading it
  would add `Dynamic` call sites against the self-typing ratchet. `sig/` declares `typer` as
  `ExpressionTyper`, and declares each `try_call`.
- *`site` is the call.* It is built once per site with `CallContext.build`, the one place the field
  list is enumerated. A literal `send`'s target is a site of its own: the inner name and arguments,
  no block. The index read's `call_node` is the write node, so a rung takes the method name from
  `site.method_name`, and a spec pins that.
- *Two invariants.* `site.scope` equals `typer.scope`: where a typer is swapped
  (`rebound_operand_typer`, `typer_under`), the site is rebuilt. And the `TypingState` slots pushed
  and popped during the walk are read where they are used, never captured into a site.
- *Re-entry.* The typer methods a rung calls back into (`call_result_type_for`,
  `call_dispatch_type_for`, `infer_user_method_return`, …) become public in the slice whose rung
  first needs them. Every `PORT` member a slice makes public is `@api private`, `scope` included. A
  spec restricts callers of the re-entry points to `call_ladder/`: the typer's cursor is valid only
  inside a `type_of` walk.
- *What may move.* A rung moves only when it meets the #3318 cut-off (it writes no typer ivar and
  calls back at most four typer methods) and the deletion test (its interface is smaller than what
  it hides). A rung that needs a fifth callback stays in the typer and is named with that count.
  `CallLadder::PORT`, the spec that checks a rung's calls against it and the spec that restricts
  the re-entry points' callers are created in the first rung slice, S6.
- *A second entry.* A rung module may expose a second named entry when a caller outside the rung
  asks part of it with arguments that differ from the site's. Each is named here, and there are
  two. `UserMethod.infer` takes its arguments as positionals; `OverridingDef` and the receiver's own
  `send` (`own_send_type`) ask it with their own arguments in place of the site's.
  `OverridingDef.overriding_own_def?` is that rung's gate, which the typer's `splat_index_read_type`
  asks. S8 moves the gate with the rung, so it is neither copied nor a `PORT` member.

**The dispatcher.** Its twelve private tiers become eleven `try_dispatch(context)` modules under
`method_dispatcher/`: plugin contribution, HKT builtin return, static refinement, synthetic method,
project-patched, dependency source, discovered method, synthesized stub, user-class ancestor
fallback, meta introspection and composite receiver. They are stateless `module_function` code, so
the pure-move rule applies unchanged.

- *Project-patched stays one module.* It is asked twice, for the receiver's own class and through
  its ancestors, and is one function today; the module keeps the `through_ancestors:` parameter.
- *Where a module is asked.* One with no bookkeeping after its answer joins an array at its own
  position (a new one where straight-line calls with bookkeeping surround it); `PRECISE_TIERS_HEAD`
  and `PRECISE_TIERS_TAIL` are such arrays today. One whose answer `resolve` follows with
  bookkeeping (the plugin-typed sink, the RBS boundary cross, the origin of a `Dynamic` answer)
  stays a straight-line call in `resolve`, in order.
- *`dispatch_site`.* After the moves, `MethodDispatcher.dispatch_site(context)` takes a site its
  caller built; `resolve` builds the context and delegates to `resolve_site`, so no pre-check is
  copied. The moves come first because they free the file's budget, and `dispatch_site` raises none.

**State, for `ExpressionTyper` only.** Its state is four kinds, and each reaches a rung one way.

| Kind | In the typer | How a rung gets it |
| --- | --- | --- |
| Frame identity | `@scope`, `@tracer`, `@operand_types`: assigned in `initialize`, inherited by a derived typer | The three are the typer's frame identity, so a collaborator that needs all three takes the typer. |
| Cursor | `@typing_node`: rewritten by `type_of`, also set in `initialize` and copied into a derived typer | Through the typer, never as a value. The index read enters on a fresh typer whose cursor is unset, while its site's node is the write node. |
| Ambient `TypingState` | Memos, which are caches; `YIELD_VALUE`, `FORWARDED_ARGS`, `THREADED_BLOCK_BODY` and `INFERENCE_GUARD`, which are cursors | Read at the point of use. |
| Per-site values | Receiver, method name, arguments, block type | One `CallContext`, built once. |

Whether the same kinds describe `StatementEvaluator` is WD8's question and is left to
[#3344](https://github.com/rigortype/rigor/issues/3344); its lazily written per-walker caches look
like a fifth.

### Slices, in order

Each slice has an id for its pull requests to cite. The ids are neither consecutive nor in numeric
order: S2′ replaces a first S2 that wrapped every rung in an adapter, two slices are dropped, and
the rung moves are ordered by what each calls. The method and line counts are static census
figures.

1. **S0 — `CallContext` becomes a plain frozen class.** Independent of the rest. As a `Data` a
   build costs about 2.3 objects more: 109,006,674 allocations against 105,955,562 on
   `lib/rigor/inference` (−2.80%), output identical. `docs/internal-spec/inference-engine.md`
   § "Dispatch tier contract" calls the context "a `Data`" and changes with it.
2. **D1–Dn — the dispatcher's twelve private tiers become eleven modules**, in two or three
   pure-move pull requests.
3. **S1 — `dispatch_site`.** The same section's "`dispatch` MUST build the context once" gains
   `dispatch_site`.
4. **S2′ — `call_ladder.rb`: `RUNGS` and the order-pin spec.** No rung moves, and nothing becomes
   public. The code map's "Method dispatch" and "A dispatch tier" rows, which say where a tier that
   must win before RBS or run only on a miss belongs, point at `RUNGS` and the pin spec.
5. **S6 — `UserMethod`** (10 methods, 104 code lines), the first rung module.
6. **S5 — `ProjectSingleton`** (23 methods, 206 code lines).
7. **S7 — `LiteralSend`** (3 methods, 31 code lines), which may ride in S5's pull request. Its
   sub-ladder asks user-method and project-singleton inference, so it follows both and needs no
   temporary `PORT` member.
8. **S8 — `OverridingDef` and `TopLevelDef`** (about 12 methods, 90 code lines).
   `overriding_own_def?` moves with `OverridingDef` as its second entry.
9. **S4 — `Refined`** (12 methods, 107 code lines), only with a plan for the self-typing ratchet.
   Its re-entry per union member may stay in the typer.

**Dropped.** S3 (`DynamicReceiver` and `NonNilRetry`: 3 methods, 28 code lines) and S9
(`Unresolved`: 6 methods, 71 code lines). Each makes a typer method public
(`call_dispatch_type_for`; `fallback_for`) to hide that little, the shape `Constants` went back for
in #3319. They stay in the typer, and their rows say so. `ReceiverBlockFolds` stays too: its 27
methods call back 8 of block typing's, the cluster #3359 decides.

**Every slice** claims no behaviour change and carries:

- Prism body identity for the code it moves, apart from the substitutions it lists;
- byte-identical `rigor check --no-cache --format json` at `--workers 0` and `2`;
- `tool/engine_alloc_ab.rb` against the merge base;
- the self-typing ratchet's delta, base against head
  ([`measurement.md`](../agents/measurement.md) § "The self-typing ratchet");
- the movement it expects in the sig provenance pins of `spec/rigor/sig_gen/provenance_spec.rb`
  (`SIG_PROVENANCE_RESIDUE`, `SIG_PROVENANCE_PARAMETER_ONLY`, `SIG_PARAMETER_SHAPE_COMPARED_FLOOR`),
  stated before it starts;
- the gate files that list a path it moves, in the same pull request:
  `typing_state_closure_spec.rb`, `producers.yml`, `admission_census.yml`, `lib_file_budgets.yml`,
  the code map, and the internal spec where it names a moved method;
- an independent review, and landing within the day.

*Done when:* a new call-typing rung is one file under `call_ladder/`, one row in `RUNGS`, and one
call in the typer's ladder, which the pin spec rejects if it disagrees with the row; no call-typing
order, a sequence of two or more rungs, is written out twice without the pin spec checking it; and
every rung left in the typer is named with its reason.

### Filed outside WD12

- [#3358](https://github.com/rigortype/rigor/issues/3358) — `c[k] += v` ignores a refined `[]`. It
  is a behaviour fix with its own corpus diff, so it rides in no WD12 slice.
- [#3359](https://github.com/rigortype/rigor/issues/3359) — block typing and the receiver folds: 82
  methods and about 1,640 lines, the file's most edited region. By static census the cluster reads
  no instance variable, reads `scope`, and calls back five typer methods, one more than the four the
  rule for leaving a stateful class allows (#3318). "Landing point" above was written without
  measuring it.

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
| A new top-down module design for the whole of `lib/rigor/` (2026-11-17) | Rejected | The measured faults are local: three files, one missing hook point, one misnamed namespace, one inverted dependency. A global re-layout would move the files that are already well placed and well mirrored (`type/`, `cache/`, `plugin/`), and collide with every open branch. |
| Split the hot files to make the specs fast (2026-11-17) | Rejected as a goal | `scope_indexer.rb` alone has 53 `require_relative` lines, so a module split out of it still loads the engine, and the time is in runner-style examples. C4 and the quick tier address the loop; the splits address locality. |
| A `typer` field on `CallContext`, so that every rung is a `try_dispatch(context)` tier (2026-11-19) | Rejected | Every dispatcher tier, and every other caller of `MethodDispatcher.dispatch`, would get a way to recurse into typing. The dispatcher must not touch the tracer (`docs/internal-spec/inference-engine.md` § "Method Dispatch Boundary"), and a field makes that unenforceable. |
| A port or frame object handed to each rung (2026-11-19) | Rejected | One more object for each call that reaches the ladder (nearly all of the census run's 1,058,027), or a second long-lived object whose lifetime must match the typer's. The typer already exists; `PORT` and its spec make what a rung sees of it narrow. |
| The typer walks `RUNGS` at run time (`CallLadder.answer`) (2026-11-19) | Rejected | The self-check types a straight-line call to a declared `try_call`, and reads `rungs[index]` as `Dynamic`. The order-pin spec gives the same single declaration without a megamorphic call on the hot path. |
| Wrap each rung in an adapter onto its typer method before any body moves (2026-11-19) | Rejected | Ten three-line adapters that `send` into the typer are an indirection layer with nothing behind it, which is why `LeafNodes` went back in #3319. The order-pin spec gives the one declaration without them, and makes nothing public. |

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
