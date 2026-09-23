# Hot-file churn audit — where the engine's change pressure lands (2026-09-23)

Status: research note, no design commitments; the decisions it grounds are
[ADR-116](../adr/116-hot-file-restructuring.md). Observations taken against Rigor 0.3.9 at `master`
`16889728`. The window is the 492 first-parent merge commits of the 60 days to 2026-09-23; 363 of
them touched `lib/`.

Predecessor: [`20260604-structural-repetition-audit.md`](20260604-structural-repetition-audit.md),
whose Theme B (the `scope_indexer.rb` walker unification) was deferred by
[ADR-53](../adr/53-scope-discovery-index-separation.md) as demand-gated.

## Method

```sh
git log --first-parent master --merges --since="60 days ago" --format=%H > merges.txt
while read h; do git diff --numstat "$h^1" "$h" | sed "s|^|$h |"; done < merges.txt > pr_files.txt
# per-file PR count and churn: awk over pr_files.txt; co-change: pairs of hot files per merge
# hottest methods: git diff with `*.rb diff=ruby`, counting the `def` in each hunk header
```

Method and class sizes come from a Prism walk over each file (`DefNode` line spans, nested
`ClassNode` / `ModuleNode` spans).

## Concentration

| File | Lines | PRs | Churn | Defs | Median def |
| --- | --- | --- | --- | --- | --- |
| `inference/expression_typer.rb` | 4,713 | 55 | 3,026 | 273 | 7 |
| `inference/scope_indexer.rb` | 8,317 | 49 | 7,616 | 441 | 9 |
| `analysis/runner.rb` | 2,330 | 39 | 1,395 | 120 | 8 |
| `analysis/check_rules.rb` | 3,746 | 38 | 1,127 | 200 | 9 |
| `inference/statement_evaluator.rb` | 3,995 | 34 | 1,558 | 248 | 9 |
| `scope.rb` | 1,883 | 32 | 1,151 | 154 | 4 |
| `environment/rbs_loader.rb` | 2,843 | 29 | 2,047 | 147 | 10 |
| `analysis/runner/pool_coordinator.rb` | 1,120 | 22 | 908 | 43 | 8 |
| `inference/method_dispatcher/rbs_dispatch.rb` | 1,428 | 22 | 1,127 | 64 | 10 |
| `cache/incremental_snapshot.rb` | 356 | 19 | 277 | — | — |
| `inference/narrowing.rb` | 3,307 | 18 | 873 | 214 | 9 |

- The 21 `lib/` files of 1,000+ lines hold 40% of `lib/`'s 121,217 lines. 161 of the 363
  `lib/`-touching PRs (44%) touched at least one of the top six.
- Methods are small; classes are not. The bloat is at file and class grain, not function grain.
- Every one of the 21 files carries an inline `Metrics/ClassLength` or `Metrics/ModuleLength`
  disable, so the class-size cops bind nothing there. The method-level cops (`AbcSize`,
  `MethodLength`) stay on, and comments record the result — for example
  `scope_indexer.rb`'s `fold_mixin_lists`, "Split out of `fold_ancestry_tables` to hold its ABC
  budget." The pressure produces more private methods inside the same class.
- Method-level outliers do exist: `MethodDispatcher#resolve` 184 lines (71 code),
  `Runner#initialize` 163, `PoolCoordinator#analyze_files_in_pool` 159,
  `ScopeIndexer#walk_methods_and_def_nodes` 126, `CheckRules.undefined_method_diagnostic` 106.

## Growth

| File | 06-15 | 07-25 | 08-25 | 09-10 | 09-23 |
| --- | --- | --- | --- | --- | --- |
| `scope_indexer.rb` | 2,740 | 2,783 | 2,937 | 4,822 | 8,317 |
| `expression_typer.rb` | 3,068 | 2,947 | 3,019 | 4,518 | 4,713 |
| `statement_evaluator.rb` | 3,364 | 3,073 | 3,124 | 3,480 | 3,995 |
| `runner.rb` | 1,030 | 1,233 | 1,752 | 2,104 | 2,330 |
| `scope.rb` | 831 | 886 | 990 | 1,570 | 1,883 |

[#1135](https://github.com/rigortype/rigor/pull/1135) (the Sorbet `sig` DSL) added 2,817 net lines
to `scope_indexer.rb`. Its commit subjects show why: "Decline unnameable selves and crefs across
the remaining scope walks", "Split singleton self from singleton cref in scope discovery walks",
"Attribute eval-block bodies to the receiver across the discovery walks".

## Co-change

| PRs | Pair |
| --- | --- |
| 15 | `scope_indexer.rb` ↔ `scope.rb` |
| 14 | `cache/incremental_snapshot.rb` ↔ `scope_indexer.rb` |
| 14 | `expression_typer.rb` ↔ `statement_evaluator.rb` |
| 12 | `runner.rb` ↔ `scope_indexer.rb` |
| 12 | `expression_typer.rb` ↔ `scope.rb` |
| 12 | `runner/pool_coordinator.rb` ↔ `worker_session.rb` |
| 10 | `runner.rb` ↔ `runner/pool_coordinator.rb` |
| 10 | `check_rules.rb` ↔ `expression_typer.rb` |
| 9 | `runner/diagnostic_aggregator.rb` ↔ `runner/pool_coordinator.rb` |

## Mechanisms

### M1 — the discovery-table list is written out by hand in about ten places

Adding the `prepends` table ([#1165](https://github.com/rigortype/rigor/pull/1165)) edited eight
`lib/` files — `scope_indexer.rb`, `scope.rb`, `scope/discovery_index.rb`, `runner.rb`,
`runner/project_pre_passes.rb`, `cache/incremental_snapshot.rb`, `cache/descriptor.rb`,
`protection/discovery_seed.rb` — and `sig/rigor/scope.rbs`. The lists:

- `Scope::DiscoveryIndex` fields (`scope/discovery_index.rb` ~L13).
- `ScopeIndexer#merge_project_method_indexes` (~L199), `#fold_file_index` and its `fold_*`
  helpers (~L6756–6865), `#build_seed_bundle` (~L6871), `#bundle_to_file_index` (~L6923).
- `Runner#initialize` (~L401–433), `#apply_discovery_result` (~L1453, 21 `@project_*` ivars copied
  one by one), `#project_scope_seed_tables` (~L1958).
- `accumulate_include_lists`, `accumulate_prepend_lists`, and `accumulate_extend_lists` have
  identical bodies.

### M2 — the run-level fact list is written out by hand in four to six places

A run-level fact (one about the run, not a file) is drained by the worker
(`worker_session.rb` ~L279–296), replayed by the coordinator (`pool_coordinator.rb` ~L935–1006),
stored in `RunSnapshots` (declared three times, ~L18–61), read by the aggregator through one lambda
per slot (`runner.rb` ~L1732), rendered (`diagnostic_aggregator.rb` ~L818–928), ordered
(`runner.rb` ~L1137–1165), and — when replayable — serialized (`incremental_snapshot.rb` ~L188,
~L303–345). PRs that paid this: #725, #788, #801, #848, #854, #978, #1054. Six coordinator paths
write the signature-state slots separately; the sequential fallback (`pool_coordinator.rb` ~L906)
copies three of the five and omits `synthesized_namespaces` and `conformance_results` — found by
reading, handed to a separate fix.

### M3 — `ScopeIndexer` has 21 recursive walkers, each with its own context rules

Each walker (`walk_class_ivars`, `walk_class_cvars`, `walk_class_superclasses`,
`walk_class_includes`, `walk_class_extends`, `walk_method_visibilities`,
`walk_constant_write_census`, `collect_class_alias_map`, …) re-implements the same arms: `class` /
`module` declaration, `class <<` (20 `when Prism::SingletonClassNode` arms in the file), the
`K = Class.new { … }` family, and the `class_eval` / `instance_eval` family. Shared helpers exist
(`meta_new_block_split` 11 uses, `eval_block_split` 6, `decl_body_context` 6), but the four to
seven arm methods per walker are copied: compare `walk_class_cvars` (~L1770–1884) with
`walk_class_superclasses` (~L4632–4735). A change to the cref/self model is applied 21 times; #1135
is that cost.

### M4 — `ExpressionTyper` holds five clusters; block evaluation is duplicated with `StatementEvaluator`

| Cluster | Lines | Note |
| --- | --- | --- |
| Per-node `type_of_*` handlers | ~361–1240 | |
| Call dispatch, receiver resolution | ~1241–1861 | |
| User-method return inference | ~1862–3527 | Owns ten thread-local keys; reaches the rest only through `dynamic_top` and one `type_of` |
| Block return typing | ~3601–4062 | Coupled to the next cluster through four methods and the threading flag |
| Per-element / inject / hash-shape block folds | ~4063–4713 | |

Seven of the 14 `expression_typer.rb` ↔ `statement_evaluator.rb` PRs changed block evaluation
(#340, #620, #852, #865, #1030, #1103, #1106). Block entry-scope construction exists three times
(ET ~L3690–3726, SE ~L2984–3061, the per-element folds) and has drifted: SE binds `|x; y|`
block-locals to nil and ET does not; ET's argument types expand `...` and `**h` and SE's do not.
The jump-target scans (ET ~L3818, SE ~L1327) disagree on boundary nodes. ET also types
`h[k] += v`, `||=`, `&&=` as the right-hand side alone (dispatch table ~L132) where SE computes the
stored value — handed to a separate fix.

### M5 — `CheckRules` is ten rules in one module

`call_node_diagnostics` (~L267) calls ten rule entries in sequence. Each rule is a contiguous block:
undefined-method ~L664–1507 (the hottest method in the file, 9 PR hunks), wrong-arity ~L1508–1752,
nil-receiver ~L1753–1970, raise rules ~L2087–2328, argument-type ~L2621–3230, return-type
~L3231–3365, overrides ~L3366–3746; suppression parsing is ~L447–660. `check_rules/` already holds
the collectors.

### M6 — `Scope` and `RbsLoader`

- `Scope`'s most-hunked methods are `initialize` (12), `rebuild` (12), and `build_joined_scope` (8):
  each new field is written in all three. Four identity-keyed advisory tables (`dynamic_origins`,
  `void_origins`, `plugin_typed_calls`, `optimistic_origins`) share one contract — threaded by
  reference, excluded from `==`/`hash`. The class-graph queries (~L630–1500: `discovered_method?`,
  `user_def_for`, `superclass_of`, `includes_of`, the ancestor walks, header-nesting resolution)
  read only `@discovery`.
- `RbsLoader`'s class-level environment assembly (~L64–1410) is stateless and carries every hot
  method (`build_env_for` 9 hunks, `add_virtual_rbs` 5); the instance side (~L1413–2843) is the query
  surface plus ~450 lines of definition-build failure reporting.
