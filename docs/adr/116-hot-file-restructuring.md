# ADR-116 — Restructuring the engine's hot files: declare each growing kind once, walk each traversal once

Status: **Accepted, 2026-09-23; WD5 amended 2026-09-27 (context-rule variants, below).** WD0 (#1192) and WD1 (#1193) have landed.
WD5 is in progress. Its first slice (#1517: the discovery-table shadow harness, the context model,
`class_cvars`) and its second (#1522: the superclass tables, with the first variants) put two tables
on the walk. Its third (#1527: the def-nesting and member-layout tables) makes the walk shared: it
builds five tables in one run per file. This ADR fixes the direction, the three criteria, and the
slice order (WD0–WD7). Each slice lands as its own PR in the `v0.4.x` milestone, tracked by
#1192–#1199 (WD0–WD7). WD0–WD5 and WD7 preserve behaviour; WD6 changes it and carries its own corpus
diff. **Amended 2026-11-17** after a re-measurement: criterion C4 and slices WD8–WD13 are added
([below](#amendment-2026-11-17--what-the-re-measurement-added)).

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
  Landed 2026-11-17 in five slices (#3290, #3294, #3301, #3306 and #PRNUM): `check_rules.rb` now holds only
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
