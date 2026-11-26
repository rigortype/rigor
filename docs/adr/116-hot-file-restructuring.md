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
([below](#amendment-2026-11-19--wd12s-interface-3345)). **Amended 2026-11-25** with WD9's interface and
how far WD10 goes before WD2
([below](#amendment-2026-11-25--wd9s-interface-and-how-far-wd10-goes-before-wd2-3346)). WD9 has
landed (the slices of #3387–#3397). **Re-measured 2026-11-26**: every cluster left in
`scope_indexer.rb`, with its reason
([below](#re-measure-2026-11-26--what-is-left-in-the-file)).

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

> **Qualified 2026-11-25** by [WD9's interface](#amendment-2026-11-25--wd9s-interface-and-how-far-wd10-goes-before-wd2-3346).
> `scope_indexer.rb`'s module functions read no instance variable, so the sentence above holds for
> that file only through the callback half of the rule. Two units in it call nothing back and meet
> the rule as measured; the collectors meet it once the context rules leave.

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

> **Note, 2026-11-20** ([#3367](https://github.com/rigortype/rigor/pull/3367)). An exception row is one of
> two kinds. *Drift* is a rung an entry should ask and leaves out: the row names its issue, and that
> issue's fix deletes the row, as #3358's does. *Design* is the splat index read. Recording newly
> found drift is not an amendment to this section, and S2′ recorded three more rows that way
> ([#3368](https://github.com/rigortype/rigor/issues/3368),
> [#3369](https://github.com/rigortype/rigor/issues/3369),
> [#3370](https://github.com/rigortype/rigor/issues/3370)). A second design row is one.

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

> **Note, 2026-11-20** ([#3371](https://github.com/rigortype/rigor/pull/3371)). Second entries are a
> list, not a count: each is named here, and the amendment's two (`UserMethod.infer`, and S8's
> `OverridingDef.overriding_own_def?`) become three. The third is `UserMethod.user_inference_receiver?`,
> the user-method rung's gate: a predicate on the receiver type, which the rung asks first and which
> `overriding_own_def?`, `own_send_type` and the recursion scan (`recursion_def_for`) ask outside it.
> Left in the typer it would have been the rung's fifth callback, over the cut-off, so it moved with
> the rung in S6, as `overriding_own_def?` moves with `OverridingDef` in S8, and its callers ask the
> module. `CallLadder::SECOND_ENTRIES` holds, as data, the second entries whose modules exist, with
> whether each is given the typer. One that is not given the typer is a function of its arguments
> alone: it takes neither a typer nor a scope and calls nothing back.
> `spec/rigor/inference/call_ladder/port_spec.rb` fails one that does, and the order pin counts a
> call of a second entry as asking its rung. Another second entry is named here and added there.

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

## Amendment, 2026-11-25 — WD9's interface, and how far WD10 goes before WD2 (#3346)

WD9 and WD10 are [#3346](https://github.com/rigortype/rigor/issues/3346). This section is the
interface WD5's amendment rule requires before their code moves. A design consult measured the file,
an independent critique rebuilt the call graph and applied the main slice to a scratch tree, and the
review of this amendment recounted the closure; the figures below are the latest of the three.

### What was measured

At `master` `34e513fcb`; `scope_indexer.rb`, `declaration_walk/` and `scope_indexer/` are unchanged
at `b524a28e8`. A *static census* figure is read from a Prism call graph of the file (receiverless
calls, `ScopeIndexer.x`, `send(:x)`); a call through a local alias would escape it.

- **No state in the module functions.** `scope_indexer.rb` has 772 module `def`s, none of which
  reads or writes an instance, class or global variable. Its one `TypingState` slot is the
  declared-names memo (`DECLARED_NAMES`). The nested classes (`MethodEffectResolver` and others)
  hold the file's 45 instance-variable nodes and move whole with the cluster that builds them. What
  keeps code in the file is the call graph: the #3318 rule's callback half, at most four calls back
  into what stays, decides each move.
- **The cycle is six calls.** `DeclarationWalk` calls back into `ScopeIndexer` at
  `declaration_walk/context.rb` lines 87, 111, 116, 171 and 177 and `traversal.rb` line 399. The
  closure of those six roots is 44 `def`s (29 public, 15 private), 318 lines of code, and calls
  nothing else in the file. It is called from 99 other `def`s of the file (180 sites) and from 22
  sites elsewhere: 6 in the walk, 4 under `scope_indexer/` (one of them in `certainty.rb`), and 12 in
  five files: `dependency_source_inference/walker.rb` (3), `refine_self.rb` (3),
  `module_function_state.rb` (2), `in_effect_refinements/walk.rb` (2) and
  `statement_evaluator.rb` (2).
- **The constants it reads.** `DECLARED_NAMES`, `EMPTY_NESTING`, `EMPTY_PREFIX`,
  `META_CONSTANT_WRITE_NODES`, `OBJECT_OWNER` and `RECEIVER_EVAL_CALLS`, plus the two lists
  `RECEIVER_EVAL_CALLS` is built from (`SELF_REBINDING_EVAL_CALLS`, `INSTANCE_EVAL_CALLS`).
  `EMPTY_NESTING`, `EMPTY_PREFIX`, `OBJECT_OWNER`, `RECEIVER_EVAL_CALLS` and `INSTANCE_EVAL_CALLS`
  are also read by code that does not move.
- **Applied to a scratch tree** (the closure and 7 walker-side helpers moved, every call
  requalified): `rigor check --no-cache --format json --workers 0` over
  `spec/integration/fixtures` byte-identical; `rigor coverage --config .rigor.gates.yml`'s
  `dynamic_call_count` 7,330 against 7,330 over the touched files. Precision rose by 454
  expressions, about 0.11 points on `lib`: each `Rules.` receiver is a precise expression. That is
  not a typing gain.
- **Slot order.** Under `require "rigor"` the file's slots are 85–88. Requiring the new file from
  `traversal.rb` moves slot 87 to 85. Requiring it from `scope_indexer.rb` at the end of the
  `require_relative` block at its head (line 57) keeps the order under `require "rigor"` and the
  LSP path. The file's last `require_relative` (line 13,704, `node_propagation`) is the wrong place:
  the constants `ScopeIndexer` binds back are evaluated at load and would raise `NameError`, and
  slots 87 and 88 would swap.
- **`sig/`.** `sig/rigor/inference.rbs` declares none of the 44 `def`s.
- **Which collectors are on the shared walk.** `class_cvars` (`ClassCvarsCollector`, run alone), and
  the superclass, def-nesting and member-layout tables (one run in `declaration_walk_tables`), plus
  `Reflection`'s two plugin-facing collectors. Each engine table keeps its legacy walker as the
  shadow oracle under `RIGOR_SHADOW_RULE_WALK` (27 `def`s, 558 lines). Every other collector is
  hand-written.
- **What other units call.** Four units call no context rule: the declaration signature (185
  lines), the cross-file fold (973), the seed-bundle codec (134) and the program-globals seed (101).
  The fold is not a leaf: from its four roots it is 72 `def`s exposing 26 entries, which 22 collector
  `def`s, `runner.rb` and the dependency-source builder call. The fold and the codec are the code
  [#1194](https://github.com/rigortype/rigor/issues/1194) (WD2) names.

### Decision

**WD9: `DeclarationWalk::Rules`.** The 44-`def` closure moves to
`lib/rigor/inference/declaration_walk/rules.rb` as `module_function` code: the same names, the same
positional parameters, the bodies Prism-identical apart from the requalified calls. The eight
constants and the slot move with it; `ScopeIndexer` binds its own private names to the five it still
reads, so that each list is one object. `Context` and `Traversal` call `Rules`, and the walk then
names nothing of `ScopeIndexer`. The 7 helpers the closure does not reach
(`meta_new_mixin_owner`, `meta_new_owner_under_cref`, `eval_body_def_context`,
`eval_body_singleton?`, `singleton_body_prefix`, `singleton_receiver_constant_name`,
`singleton_class_prefix`) stay with the walkers that call them. `meta_new_body_prefix`, which
nothing calls, is deleted in the same slice. `scope_indexer.rb` requires `rules.rb` at the end of
its head `require_relative` block.

- *The deletion test.* `Rules` does not pass it by ratio: 29 public entries over 15 private
  helpers, an interface of about two thirds of the module (`LeafNodes` went back at 29 of 30,
  `Composites` stayed at 15 of 29). It is admitted for the reason WD9 exists: the six calls are a
  cycle, and the closure is what breaking it takes. WD1's `CheckRules::ReceiverPredicates` (a
  predicate library most of whose functions other files call) is the precedent.
- *The frame.* No frame or callback object. A collector on the shared walk asks its `context`; a
  hand-written walker passes its own positionals. The walk allocates one `Context` per body today,
  and an unported walker handed one would allocate one per body in each of about fifteen walks.
- *The public list, pinned.* A spec pins `Rules`' public functions and exported constants as a list
  that may shrink and never grows. Its floor is 12: the walk's six roots, and the seven entries the
  five files above call, one of which (`meta_new_constant_rvalue?`) is also a root. `Rules` names
  nothing of `ScopeIndexer`, which a spec checks, so the callback cap of a module with no host is
  zero. `Rules` is marked `@api private`. An entry added to it is an amendment to this section.
- *`sig/`.* R1 adds no `sig/` rows, since none of the moved `def`s has one, and moves no provenance
  pin.
- *The ratchet.* The precision rise is reported in the slice and not tightened into the ratchet's
  floor.

**Collector moves, inside `ScopeIndexer`'s namespace.** A cluster that meets the #3318 cut-off
moves whole, behind its entry, to its own file under `scope_indexer/` as `ScopeIndexer::<Name>`:
#3311's precedent (`NodePropagation`), which read the file's constants lexically and stayed inside
the admission census's owner directory. These are the moves WD9 says it unblocks ("what lets the
per-table clusters leave"); they are not WD10's split, which changes the namespace.

- *Units with no rule calls go first.* The declaration signature and the program-globals seed call
  no context rule, so they need nothing from WD9. "Landing point" placed all that is left behind the
  rule for leaving a stateful class without measuring them; they meet it.
- *Then, after `Rules`:* the class declarations, the literal-receiver mutations and the published
  constant ivars (none calls anything left in the file), the class-variable census (one call), and
  the shared-walk tables with their recorders and shadow oracles (five calls, so that slice states
  which helpers move with it to meet the cut-off, or why the cluster stays). Moved, not ported:
  ADR-119 makes a port that is not byte-identical a lane-2 change, and a cluster behind one entry is
  the unit a later port replaces.
- *Then re-measure.* The deferred ranges, the class ivar index, the constant census, singleton
  defs, visibility, the mixin and extend tables and the method tables (about 7,000 lines) are
  decided one at a time against the cut-off. This amendment commits to none of them.

**WD10 keeps its place.** "Order and procedure" step 3 (WD9, then WD2, then WD10) stands. The fold
and the codec are WD2's: WD2 replaces their hand-written slot lists by declarations, and moving them
first would fix an interface WD2 then rewrites. The discovery namespace, and what stays in
`ScopeIndexer` at its end (`index`, `recording_evaluator`, `seed_struct_fold_safe`, the constants
`NodePropagation` reads lexically, and the table-key conventions other files read), are WD10's, after
WD2. #3346 delivers WD9 and the collector moves above, and hands WD10 on to its own issue.

### Slices, in order

1. **G0 — the producers gate learns more than one file.** `spec/support/declaration_fact_sources.rb`
   reads rule (v) from `scope_indexer.rb` and `scope_indexer/`, its roots (`ROOTS`) are names in
   `scope_indexer.rb`, and `reachable` drops a root it cannot find without failing. The file list
   becomes a table of file, module (matched as a fully qualified suffix, so `DeclarationWalk::Rules`
   never matches `CheckRules`) and that file's own roots, and a root missing from its file fails. The
   comments in `producers_spec.rb` and the support file that name the two files change with it. A
   removal mutation per new check. No `lib/` change.
2. **L1, L4 — `ScopeIndexer::DeclarationSignature` and `ScopeIndexer::ProgramGlobals`.** One pull
   request or two.
3. **R1 — `DeclarationWalk::Rules`.** Every caller of the 29 entries requalified: 180 sites in the
   file and 22 outside. `rules.rb` joins G0's table, so the seven grandfathered `producers.yml` rows
   in the closure re-key to it, the grandfathered count stays and its digest moves (#3288's
   precedent at `producers_spec.rb`). `typing_state_closure_spec.rb` lists `rules.rb`.
4. **U1–U3 — class declarations, literal-receiver mutations, published constant ivars.**
5. **U5 — the class-variable census.**
6. **U4 — the shared-walk tables, recorders and shadow oracles.**
7. **Re-measure.** A table of every cluster left in the file, each with its call count against the
   cut-off and its reason for staying or the slice that moves it. It is
   [below](#re-measure-2026-11-26--what-is-left-in-the-file).

**Every slice** carries WD12's guardrails:

- Prism body identity of each moved unit, with its substitutions listed;
- byte-identical `rigor check --no-cache --format json` at `--workers 0` and `2` on
  `lib/rigor/inference` and `spec/integration/fixtures`, base engine against head engine over the
  base tree;
- `TypingState.slots`, the same names in the same order, under `require "rigor"`, a check run, the
  file alone, the LSP path and a plugin load;
- `tool/engine_alloc_ab.rb`, three runs with their range, and a wall A/B;
- the self-typing ratchet's delta, both arms from `git archive`;
- the sig provenance pins it expects to move, stated before it starts;
- in the same pull request, every gate file that lists a moved path or name:
  `typing_state_closure_spec.rb`, `producers.yml`, `admission_census.yml`, the
  `scope_indexer.rb` row of `spec/docs/lib_file_budgets.yml` (lowered to the new size, as each WD12
  slice did; a row under 1,000 lines is removed), the code map's "Declaration discovery" row, and
  the internal specs where they name a moved method (`inference-engine.md`,
  `dependency-source-inference.md`);
- an independent review, and landing within the day.

It adds two this file needs:

- byte-identical `rigor sig-gen` over the corpus, which ADR-119's lane 1 requires of a collector
  change;
- the mirror specs of what moves (C4), and a removal mutation per new spec, as a table in the pull
  request.

Where a slice and a WD12 slice both move a numeric pin (the `sig/rigor/inference.rbs` residue, the
compared floor, the producers' grandfathered count), the pull request that lands second recounts
it; it is not merged as text.

*Done when* (#3346): the walk names nothing of `ScopeIndexer`; `Rules`' public list is pinned; the
slices above have landed or are named with the reason they stopped; and step 7's table names every
cluster left in `ScopeIndexer` with its reason, the fold and the codec as WD2's.

### Re-measure, 2026-11-26 — what is left in the file

Step 7 of "Slices, in order": every cluster left in `scope_indexer.rb` once the six slices before
it landed, each with its calls against the #3318 cut-off (at most four calls back, no
instance-variable write), its callers, and why it stays or what would move it.

**What landed.**

| Slice | Pull request | What left the file | Module functions left | Lines left |
| --- | --- | --- | --- | --- |
| G0 | [#3387](https://github.com/rigortype/rigor/pull/3387) | Nothing: the producers gate reads a table of files. | 772 | 13,704 |
| L1, L4 | [#3389](https://github.com/rigortype/rigor/pull/3389) | `DeclarationSignature` and `ProgramGlobals` | 748 | 13,400 |
| R1 | [#3390](https://github.com/rigortype/rigor/pull/3390) | `DeclarationWalk::Rules`; `meta_new_body_prefix` is deleted | 703 | 12,730 |
| U1–U3 | [#3393](https://github.com/rigortype/rigor/pull/3393) | `ClassDeclarations`, `LiteralReceiverMutations` and `PublishedConstantIvars` | 676 | 12,166 |
| U5 | [#3396](https://github.com/rigortype/rigor/pull/3396) | `ClassCvarCensus`, which calls one function back | 663 | 11,928 |
| U4 | [#3397](https://github.com/rigortype/rigor/pull/3397) | `SharedWalkTables`, which calls three back | 619 | 11,173 |

The file's budget row is 11,200, down from 13,800.

**How it was measured.** At `master` `5fd4505c9`, by the static census of "What was measured": a
Prism call graph of the file's 619 module functions. An edge is a receiverless call, `self.x`,
`ScopeIndexer.x`, or `send(:x)` / `method(:x)`. Seven Symbols in those functions spell another
function's name as a Hash key; they are not edges.

- *The cut-off.* No module function reads or writes an instance, class or global variable, so the
  callback half decides every row. The 45 instance-variable nodes are in four nested classes, each
  read by one row and named with it.
- *A row.* Its entries are chosen: a table's builder, or, for a row that is a library, each
  function another row calls. Its members follow from the graph: the entries, and every function
  they dominate (each call path to it from another row's entry passes through one of this row's).
  The 23 rows hold each of the 619 functions once. A nested class, or a constant whose value has
  a body (`MethodTables` is a `Struct` with one), counts with the one row that reads it, and so do
  the calls its methods make on the module.
- *Calls back* counts the distinct functions of other rows that a row calls. A call on a module
  that has left the file is not one.
- *Lines* counts a row's functions with the comments above them, and the constants and nested
  classes only that row reads. The seven constants WD10 keeps count with the first row, whichever
  rows read them. The rows hold 11,000 of the 11,173 lines. Of the rest, 99 are the file's frame
  (its requires, header comment, `module_function` and closing lines), and 74 are 15 constants and
  the `HookBlockSpans` module: more than one row reads each, except `EMPTY_NESTING`, which only
  modules that have left read.
- *Callers* in other files are calls on `ScopeIndexer` under `lib/`.

A *candidate* meets the cut-off behind few entries. This section commits to none: each is a slice
of its own, under "Every slice" above. [#3400](https://github.com/rigortype/rigor/issues/3400)
holds the candidate moves and the deletion in the last row.

| Cluster | Functions · lines of code · lines | Calls back | Callers | Why it stays, or what would move it |
| --- | --- | --- | --- | --- |
| `index`, `recording_evaluator`, `seed_struct_fold_safe` and the three delegators to `NodePropagation` (`propagate`, `with_unentered_evaluator`, `refined_class_name`) | 6 · 54 · 188 | 8: the builders and merges it runs | 16 files (`index`), `statement_evaluator.rb` (`refined_class_name`) | **WD10 ([#3401](https://github.com/rigortype/rigor/issues/3401)).** The per-node scope index keeps the name. Its lines count the seven constants "WD10 keeps its place" leaves with it: the three node-class lists `NodePropagation` reads lexically, and the four other files read (`TOP_LEVEL_DEF_KEY`, `DYNAMIC_TARGET_PREFIX`, `CONSTANT_MEMO`, `EMPTY_PATH_SET`). Beyond that paragraph's list, the three delegators join what stays: `index` calls two and `StatementEvaluator` the third. |
| The per-file merges over the seed: `seed_discovered_methods`, `merge_project_method_indexes`, `seed_constant_tables` and what only they call | 24 · 224 · 396 | 14: seven builders and seven merges | `index` (3 sites), `ConstantIvarValue` | **WD2 ([#1194](https://github.com/rigortype/rigor/issues/1194)).** WD2's "per-file-over-seed merge", which names `merge_project_method_indexes`. |
| The cross-file fold: its cross-file entries (`discovered_project_index_for_paths`, `scan_summary_for_paths`, …), the per-file build (`accumulate_project_index`), `fold_file_index`, `finalize_def_index` with the extends fold and the compact-header renames, and the kind and contest merges | 85 · 772 · 1,364 | 18 | four files at 9 sites (`incremental_session.rb`, `runner/project_pre_passes.rb`, `project_seed_tables.rb`, `protection/discovery_seed.rb`); the per-file merges, the methods table, the declaration artifacts | **WD2 (#1194).** "What was measured" counts 72 functions by closure from four roots. This row is cut by dominance from the fold's own entries: it adds the cross-file entries and the per-file build (24 functions), and leaves 11 of the 72 to the rows they are entries of (the header-nesting and refinement merges, `dynamic_target_key`, `replaced_visibility_mark`). |
| The header-nesting insert and merges (`add_header_nesting`, `merge_header_nestings` and six more) | 8 · 41 · 83 | 0 | the fold, the per-file merges, `SharedWalkTables` (`add_header_nesting`) | **WD2 (#1194)** for the seven merges. The insert, `add_header_nesting`, is the collector's side, not WD2's. It stays for [#3398](https://github.com/rigortype/rigor/issues/3398): apart from the bucket merge it calls, it falls out of the producers list, which is why it did not leave with U4. |
| The seed-bundle codec (`build_seed_bundle`, `bundle_to_file_index` and three more) | 5 · 73 · 134 | 0 | `discovered_project_index_incremental` | **WD2 (#1194).** |
| The constant tables: the in-source walk (`build_in_source_constants`, 9 functions), the publication census (`constant_write_census`, 22) and the write-target rules both ask (`rebound_block_self`, `self_write_name`, …, 9) | 40 · 336 · 751 | 2: `census_body_scope`, `census_nesting`. Apart, the three call 6, 6 and 1 | `index`, the per-file merges, the fold, the mixin tables; `pre_eval_constants.rb`, `ConstantIvarValue`, `SharedWalkTables` | **Candidate**, as one module behind four entries. |
| The mutated-carrier widening (`widen_mutated_constants`, `widen_mutated_cvars`, `census_mutated_type` and four more) | 7 · 71 · 129 | 0 | `index` (2 sites), `ConstantIvarValue`, `MutatedElementCensus` (2 sites) | **Candidate.** `MutatedElementCensus` calls two of them back and is called by a third. |
| The alias def-node pass (`apply_alias_def_nodes`), with `AliasMap` | 11 · 151 · 268 | 1: `follow_slot_writer` | `build_methods_and_def_nodes` | **Candidate.** One entry, called once. |
| The mixin effects and taints (`mixin_effects`, the `taint_*` families, …), which the mixin and extend walks both ask | 31 · 220 · 411 | 3: `mixin_call_view`, `lexical_self_receiver?`, `opaque_mixin_argument?` | the two walks, five functions each, through eight entries | **Candidate**, alone or with the mixin tables. |
| The declaration artifacts (`build_declaration_artifacts`) | 6 · 102 · 174 | 4: the resolver below and three of the fold's (`compact_header_renames`, `rename_compact_name`, `synthesize_namespace_prefixes`) | `index`, `pre_eval_constants.rb` | **Candidate**, at the cut-off itself. |
| The factory-call resolver (`resolve_meta_factory_call` and two helpers) | 3 · 19 · 28 | 0 | the methods table, the declaration artifacts, `SharedWalkTables` (2 sites) | **Candidate**, small. U4 weighed taking it and left it: two of its callers have nothing to do with a member layout. |
| The singleton-class sources (`record_singleton_class_sources`) | 4 · 31 · 52 | 2: `singleton_receiver_constant_name`, `surface_rewriting_call?` | the fold's per-file build | **Candidate**, small. |
| The refinement readers (`refine_target`, `refine_call?`, `refinement_table`, `merge_refinement_tables`, …) | 14 · 89 · 164 | 1: `build_methods_and_def_nodes` | ten files at 21 sites; five functions of the file and `MethodTables` | **Meets the cut-off and stays.** 11 of the 14 are entries, the shape `LeafNodes` went back for (#3319). |
| The census scope (`census_body_scope`, `census_nesting`) | 2 · 7 · 21 | 0 | the class ivar index (4 sites), the constant tables (2), `ClassCvarCensus` (2) | **Meets the cut-off and stays** unless a slice takes it: both are entries. |
| The class ivar index (`build_class_ivar_index`), with `MethodEffectResolver` and `BindingTargets` | 94 · 994 · 1,812 | 5: `census_body_scope`, `def_side`, `def_receiver_targets_lexical_self?`, `attr_macro`, `each_attr_macro_name` | `index` | **One over. Candidate** once its slice says which helper moves, as U4's did: it calls four when the census scope is not in the file. |
| The mixin tables (`mixin_tables`) | 17 · 169 · 329 | 11: the eight entries of the effects and taints, `rebound_block_self`, `mixin_call_view`, `lexical_self_receiver?` | the per-file merges, the fold | **Over.** With the effects and taints: 48 functions and four calls back. |
| The extend tables (`extend_tables`) | 34 · 359 · 590 | 20: the same eight and 12 recognisers | the per-file merges, the fold | **Over.** |
| The methods table (`build_methods_and_def_nodes`), with `MethodTables` | 131 · 1,302 · 2,271 | 44: 30 recognisers, nine refinement readers (seven of them from `MethodTables`), three of the fold's kind merges, the resolver, the alias pass | the per-file merges, the fold, the refinement readers | **Over.** Leaving, it would also drop `supersede_def_nodes` from the producers list (#3398). |
| Singleton defs (`build_singleton_def_tables`), with `SingletonDefTable` | 13 · 198 · 329 | 11, all recognisers | the per-file merges, the fold | **Over.** |
| The deferred ranges (`build_deferred_ranges`) | 11 · 199 · 303 | 6, all recognisers | the per-file merges, the fold | **Over.** |
| Visibility (`build_method_visibility_tables`), with `VisibilityTable` | 33 · 436 · 759 | 11, all recognisers | the per-file merges, the fold | **Over.** |
| The recognisers the walkers share (`literal_method_name`, `constant_receiver_candidates`, `def_side`, `mixin_call_view`, `statements_of`, …) | 38 · 239 · 435 | 0 | 96 functions of the file at 148 sites; seven files at 14 | **Stays.** 33 of the 38 are entries. The table of rejected alternatives has a module of them at 20 entries for 22. |
| `self_singleton_class?` and `def_singleton?` | 2 · 6 · 9 | 3 | none, in `lib/`, `spec/` or `tool/` | **Nothing calls them.** #3400 deletes them, as R1 deleted `meta_new_body_prefix`. |

**Read with the table.**

- *The candidates.* The seven rows marked so are 102 functions and 1,813 lines; with the class
  ivar index, the census scope and the mixin tables, 215 functions and 3,975 lines. Five `sig/`
  rows are theirs (three in the constant tables, two in the declaration artifacts), and 100 rows
  of `producers.yml` name their functions, 51 of them the class ivar index's.
- *Order.* A move lowers its neighbours' counts. With the constant tables and the resolver out,
  `SharedWalkTables` calls back one function, and the mixin tables call two once the effects and
  taints are out as well. The extend tables then call 12, all recognisers.
- *Over the cut-off.* The methods table, singleton defs, the deferred ranges, visibility and the
  extend tables each call between 6 and 30 of the 38 recognisers. With the recognisers, the mixin
  tables, the effects and taints and the alias pass they are 319 functions and 3,273 lines of code
  that call back 14: nine refinement readers, the three kind merges, the resolver and
  `rebound_block_self`. A unit of that size is WD10's question (#3401), not a collector move. Two
  recorder families in the methods table meet the cut-off without an entry of their own: the
  refine census (19 functions, two calls back, six entries from the walker) and the hook-extend
  recorders (19, two, five entries).
- *The producers gate (#3398).* Rule (v) follows a table parameter into a writer of the same file
  only. The gate's own scan was run with the calls between one row and the rest of the file cut,
  as a file boundary would cut them. Of the file's 189 rule-(v) writers, three then leave the
  list: `supersede_def_nodes`, and `merge_and_fold_extends` and `fold_per_file_extends`, which hand
  a table from the per-file merges to the fold. Every other row, the mixin, extend and visibility
  tables among them, moves whole with the list unchanged. A row taken apart does not:
  `add_header_nesting` without its bucket merge is U4's case.

*Done when* above holds with this table: the walk names nothing of `ScopeIndexer` and `Rules`'
public list is pinned (`spec/rigor/inference/declaration_walk/rules_spec.rb`), the six slices
landed, and every cluster left is named, the fold and the codec as WD2's. WD10 is handed on to
#3401.

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
| Move the cross-file fold and the seed-bundle codec out of `ScopeIndexer` ahead of WD2 (2026-11-25) | Rejected | WD2 (#1194) replaces their hand-written slot lists by declarations, so an interface fixed first is one WD2 rewrites. "Order and procedure" step 3 keeps WD9, WD2, WD10 for them. |
| Re-home the def-owner and factory-member recognisers into `DeclarationWalk::Rules` so that the shared-walk tables can leave (2026-11-25) | Rejected | It grows the list the `Rules` pin says may only shrink, to move one cluster. The cluster meets the cut-off with what moves beside it, or stays. |
| A module of the call-shape recognisers (`attr_macro`, `literal_method_name`, `statements_of`, …) for the walkers left in the file (2026-11-25) | Rejected | 20 entries for 22 `def`s, and 107 call sites to edit: the shape `LeafNodes` went back for in #3319. |
| A `Context` reader wrapping the two rule calls in `member_layouts_collector.rb` (2026-11-25) | Rejected | One caller, on the plugin-reachable `Context`, and WD9 does not need it. |

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
