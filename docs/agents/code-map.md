# Code map

Read this when planning a change, to predict which files it touches and which specs check it. It
maps `lib/rigor/`; it does not restate behaviour, which is in
[`docs/internal-spec/`](../internal-spec/README.md) and
[`docs/type-specification/`](../type-specification/README.md). Where a name does not predict its
content, the map says so, and [ADR-116](../adr/116-hot-file-restructuring.md) holds the plan to fix
it. `spec/docs/code_map_spec.rb` fails when a `lib/rigor/` directory or top-level file has no row
here, or when a path named here does not exist.

## The pipeline

A `rigor check` run goes through these stages. A change usually belongs to one of them.

1. **Configure**: `lib/rigor/configuration.rb` loads `.rigor.yml`; `lib/rigor/cli/` parses the
   command line and picks a command.
2. **Build the environment**: `lib/rigor/environment/` loads RBS (core, stdlib, gems, the project's
   `sig/`) and plugin-contributed signatures; `lib/rigor/cache/` persists it.
3. **Discover**: one pass over every project file collects declarations (classes, methods, mixins,
   constants, visibility) into the tables of `lib/rigor/scope/discovery_index.rb`. The collectors
   and the cross-file fold are in `lib/rigor/inference/scope_indexer.rb`.
4. **Type**: per file, `lib/rigor/inference/statement_evaluator.rb` walks statements and threads an
   immutable `Scope`; `lib/rigor/inference/expression_typer.rb` answers `Scope#type_of(node)`;
   calls go through `lib/rigor/inference/method_dispatcher.rb`.
5. **Check**: `lib/rigor/analysis/check_rules.rb` and `lib/rigor/analysis/check_rules/` turn typed
   nodes into diagnostics.
6. **Orchestrate and report**: `lib/rigor/analysis/runner.rb` drives stages 2–5 over the file set,
   in a pool or incrementally, and `lib/rigor/analysis/runner/` aggregates rows.

## Directories

| Path | Responsible for | Start reading at | Specs |
| --- | --- | --- | --- |
| `lib/rigor/analysis/` | Seven things that share a namespace: the rule engine, run orchestration, incremental runs and the run cache, the ADR-46 dependency graph, reachability, template units, and the diagnostic value types. See [Inside `analysis/`](#inside-analysis). | `lib/rigor/analysis/runner.rb` | `spec/rigor/analysis/` |
| `lib/rigor/ast/` | The marker for synthetic (virtual) nodes. | `lib/rigor/ast.rb` | `spec/rigor/ast/` |
| `lib/rigor/builtins/` | Imported refinement carriers and static return refinements for core and stdlib. The generated catalogues are in `data/builtins/`. | `lib/rigor/builtins/imported_refinements.rb` | `spec/rigor/builtins/` |
| `lib/rigor/cache/` | The on-disk cache store, cache descriptors and digests, the cached RBS environment, and the incremental snapshot. | `lib/rigor/cache/store.rb` | `spec/rigor/cache/` |
| `lib/rigor/cli/` | One class per command, plus each command's report and renderer. `init`, `describe` and `playground` are the exceptions: they are inside `lib/rigor/cli.rb`. | `lib/rigor/cli.rb` | `spec/rigor/cli/` |
| `lib/rigor/configuration/` | `Defaults` (`DEFAULTS` and the key-describing constants), `Coercion` (the `coerce_*` validators), `Loader` (file discovery, `includes:`, the YAML read), severity profiles and the dependency settings. | `lib/rigor/configuration.rb` | `spec/rigor/configuration/` |
| `lib/rigor/effects/` | Effect labels and summaries: scanning units, propagation, envelopes, snapshots. The CLI side is `lib/rigor/cli/effects_command.rb`; the run-time passes are in `lib/rigor/analysis/runner/`. | `lib/rigor/effects.rb` | `spec/rigor/effects/` |
| `lib/rigor/environment/` | RBS loading and queries, signature discovery (bundle, `rbs collection`, vendored), and the class registry. | `lib/rigor/environment.rb` | `spec/rigor/environment/` |
| `lib/rigor/flow_contribution/` | The value types and the merger for plugin-contributed flow facts. | `lib/rigor/flow_contribution.rb` | `spec/rigor/flow_contribution/` |
| `lib/rigor/hashing/` | The XXH3 implementation the cache digests use. | `lib/rigor/hashing/xxh3.rb` | `spec/rigor/hashing/` |
| `lib/rigor/inference/` | The typing engine and declaration discovery. See [Inside `inference/`](#inside-inference). | `lib/rigor/inference/statement_evaluator.rb` | `spec/rigor/inference/` |
| `lib/rigor/language_server/` | The LSP server: one provider per request kind, buffer tables, publishing. | `lib/rigor/language_server/server.rb` | `spec/rigor/language_server/` |
| `lib/rigor/lens/` | `rigor lens`: the `lens/v0` declaration map of the requested files, with type provenance and contract claims. | `lib/rigor/lens.rb` | `spec/rigor/lens/` |
| `lib/rigor/mcp/` | The MCP server loop. | `lib/rigor/mcp/server.rb` | `spec/rigor/mcp/` |
| `lib/rigor/plugin/` | The plugin API: the base class, manifest, loader, registry, trust and isolation, and the macro substrate. | `lib/rigor/plugin/base.rb` | `spec/rigor/plugin/` |
| `lib/rigor/protection/` | Type-protection coverage by mutation: the mutator, the oracles and the mutation cache. Its scanner is `lib/rigor/inference/protection_scanner.rb`, and its commands are the `coverage*`, `mutation*` and `protection*` files of `lib/rigor/cli/`. | `lib/rigor/protection/mutation_scanner.rb` | `spec/rigor/protection/` |
| `lib/rigor/rbs_extended/` | Parsing and checking of `%a{rigor:…}` annotations. The directive readers are in `lib/rigor/rbs_extended.rb`. | `lib/rigor/rbs_extended.rb` | `spec/rigor/rbs_extended/` |
| `lib/rigor/reflection/` | Read-only queries over a `Scope` and the environment for tools and plugins: declarations, constants, project methods. Not `lib/rigor/environment/reflection.rb`, which queries RBS only. | `lib/rigor/reflection.rb` | `spec/rigor/` (the `reflection_*_spec.rb` files) |
| `lib/rigor/runtime/` | JIT setup for the analyzer process. | `lib/rigor/runtime/jit.rb` | `spec/rigor/runtime/` |
| `lib/rigor/scope/` | The discovery tables a `Scope` carries, and `ResolutionChain`, the ancestor and method-owner resolution over them. | `lib/rigor/scope/discovery_index.rb` | `spec/rigor/scope/` |
| `lib/rigor/sig_gen/` | `rigor sig-gen`: observing calls, choosing candidates, rendering and writing RBS. | `lib/rigor/sig_gen/generator.rb` | `spec/rigor/sig_gen/` |
| `lib/rigor/source/` | Prism helpers with no typing: node location, child walking, literals, constant paths. | `lib/rigor/source.rb` | `spec/rigor/source/` |
| `lib/rigor/triage/` | `rigor triage`: clustering diagnostics and attaching hints. | `lib/rigor/triage.rb` | `spec/rigor/triage_spec.rb` |
| `lib/rigor/type/` | The type objects and their algebra. Callers build types through `lib/rigor/type/combinator.rb`, not the classes' own `new`. | `lib/rigor/type.rb` | `spec/rigor/type/` |
| `lib/rigor/type_node/` | The syntax tree of a written type, and the resolver chain plugins extend. Not `lib/rigor/ast/type_node.rb`, which is a virtual node carrying a type. | `lib/rigor/type_node.rb` | `spec/rigor/type_node/` |
| `lib/rigor/type_of_memo/` | Serving and statistics for the per-file `type_of` memo. The table is `lib/rigor/type_of_memo.rb`. | `lib/rigor/type_of_memo.rb` | `spec/rigor/type_of_memo_spec.rb` |

## Top-level files

| Path | Responsible for |
| --- | --- |
| `lib/rigor/ast.rb` | Loads `lib/rigor/ast/`. |
| `lib/rigor/bleeding_edge.rb` | The queue of changes that ship behind `bleeding_edge`. |
| `lib/rigor/ci_detector.rb` | Detects the CI provider from the environment. |
| `lib/rigor/cli.rb` | Command dispatch (`HANDLERS`), exit codes, and the commands with no class of their own (`init`, `describe`, `playground`). |
| `lib/rigor/config_audit.rb` | Findings about the configuration itself (unknown keys, dead paths). |
| `lib/rigor/config_path.rb` | Resolves a configured path against its base directory. |
| `lib/rigor/configuration.rb` | The `Configuration` class: its readers, `initialize`, `to_h`, the `with_*` siblings and the coercions that write instance state; `Configuration.load` and the other class methods delegate to `Loader`. |
| `lib/rigor/configuration_error.rb` | The error a bad configuration raises. |
| `lib/rigor/effects.rb` | Loads `lib/rigor/effects/`. |
| `lib/rigor/environment.rb` | The `Environment` object: what the engine asks about classes and signatures. |
| `lib/rigor/flow_contribution.rb` | The contribution bundle and its provenance. |
| `lib/rigor/language_server.rb` | Loads `lib/rigor/language_server/`. |
| `lib/rigor/lens.rb` | The lens document's version and span shape. |
| `lib/rigor/library_probe.rb` | Which configured library names the environment can load. |
| `lib/rigor/mcp.rb` | Loads `lib/rigor/mcp/`. |
| `lib/rigor/memo_audit.rb` | The ADR-129 audit that compares a memo hit with a fresh computation. |
| `lib/rigor/plugin.rb` | Plugin registration by gem name. |
| `lib/rigor/plugin_gap_advisory.rb` | Advises enabling a bundled plugin for a gem the project depends on. |
| `lib/rigor/project_environment.rb` | Builds the plugin-aware environment for commands other than `check`; the `check` runner and its workers call its helpers too. |
| `lib/rigor/rbs_extended.rb` | Reads `%a{rigor:…}` directives off RBS declarations. |
| `lib/rigor/reflection.rb` | The reflection facade and the constant-lookup ladder. |
| `lib/rigor/rooted_glob.rb` | A `Dir.glob` that takes its root literally. |
| `lib/rigor/run_scoped_slots.rb` | Empties run-scoped `TypingState` slots at the end of a run. |
| `lib/rigor/scope.rb` | The immutable `Scope`: local bindings, narrowing facts, and readers over the discovery tables. |
| `lib/rigor/sig_gen.rb` | Loads `lib/rigor/sig_gen/`. |
| `lib/rigor/signature_path_audit.rb` | Audits configured signature paths against bundled plugins. |
| `lib/rigor/source.rb` | Loads `lib/rigor/source/`. |
| `lib/rigor/testing.rb` | `Rigor.dump_type` and `assert_type` for fixtures. |
| `lib/rigor/triage.rb` | The triage clusters. |
| `lib/rigor/trinary.rb` | Yes / no / maybe. |
| `lib/rigor/type.rb` | Loads `lib/rigor/type/`. |
| `lib/rigor/type_node.rb` | Loads `lib/rigor/type_node/`. |
| `lib/rigor/type_of_memo.rb` | The per-file `type_of` memo table. |
| `lib/rigor/typing_state.rb` | Every thread-local slot the engine uses, declared once with its kind. |
| `lib/rigor/value_semantics.rb` | Generates `==`, `eql?` and `hash` for immutable value classes. |
| `lib/rigor/version.rb` | `Rigor::VERSION`. Only release prep edits it. |

## Inside `inference/`

About 120 files sit directly in the directory. Three of them are entry points; most of the rest
are one feature each, called from those three.

| What | Where | Notes |
| --- | --- | --- |
| Statement walking and scope threading | `lib/rigor/inference/statement_evaluator.rb` | Entry: `evaluate`. Owns assignments, control flow, loops, blocks in statement position, `def` and class bodies, pattern matching, rescue. |
| Expression typing | `lib/rigor/inference/expression_typer.rb` | Entry: `type_of`. Owns per-node typing, call typing before and after dispatch, and user-method return inference (`return_type_for`). |
| The same construct in both | both files | A construct in statement position is evaluated by `StatementEvaluator`, in value position by `ExpressionTyper`; they recurse into each other through `Scope#evaluate` and `Scope#type_of`. Block entry and compound writes exist in both (ADR-116 WD6). Check both before changing either. |
| Narrowing | `lib/rigor/inference/narrowing.rb`, `lib/rigor/inference/narrowing/` | Stateless. Predicate and type-level narrowing; smaller features are siblings such as `lib/rigor/inference/indexed_narrowing.rb`. The leaf clusters ADR-116 moved out are modules under `narrowing/` that `Narrowing` calls and that call back into it only from `Complements` (`narrow_not_refinement`) and `RegexMatch` (`narrow_nil`, `narrow_not_class`): `complements.rb` (complements, finite domains, integer-range algebra), `presence_predicates.rb` (emptiness and key presence), `class_dispatch.rb` (`narrow_class` per carrier), `regex_match.rb` (regex match predicates, capture groups). |
| Assignability | `lib/rigor/inference/acceptance.rb` | "Does this type accept that one", with reasons. |
| Method dispatch | `lib/rigor/inference/method_dispatcher.rb`, `lib/rigor/inference/method_dispatcher/` | `resolve` is the tier ladder. Most tiers are a module with `try_dispatch(CallContext)`. The user-method tiers run earlier and later, in `ExpressionTyper#call_result_type_for`. |
| Declaration discovery | `lib/rigor/inference/scope_indexer.rb`, `lib/rigor/inference/scope_indexer/`, `lib/rigor/inference/declaration_walk.rb`, `lib/rigor/inference/declaration_walk/` | Despite the name, little of `scope_indexer.rb` is the per-node scope index: `index` stays, and the walk that fills the nodes the evaluator did not visit is `scope_indexer/node_propagation.rb` (`NodePropagation`; `ScopeIndexer.propagate` delegates to it). The rest builds the project-wide discovery tables, folds them across files and encodes seed bundles. New collectors go on the shared `DeclarationWalk` where its events suffice (ADR-116 WD5). |
| Mutation, capture and floor features | siblings such as `lib/rigor/inference/mutation_widening.rb`, `lib/rigor/inference/captured_locals.rb`, `lib/rigor/inference/callee_write_census.rb` | Each file holds one feature's AST scan and rules. Where it is called from is in `statement_evaluator.rb`: there is no hook point yet, so a new feature of this kind also edits that file (ADR-116 WD8). |
| Higher-kinded types | `lib/rigor/inference/hkt_reducer.rb` and the other `hkt_*.rb` files | |
| Project monkey-patches | `lib/rigor/inference/project_patched_scanner.rb` and the other `project_patched_*.rb` files | |

## Inside `analysis/`

| Group | Files |
| --- | --- |
| Rule engine | `lib/rigor/analysis/check_rules.rb` (the orchestration only: `diagnose`, the node-collector construction and driving, the per-node rule dispatch, and the `filter_suppressed` delegators), `lib/rigor/analysis/check_rules/` (node collectors, each with its own message builder, rule ids, guards, and the modules ADR-116 WD1 moved out: `suppression.rb`, `undefined_method.rb`, `unresolved_toplevel.rb`, `rigor_testing.rb`, `always_raises.rb`, `raise_non_exception.rb`, `special_global_write.rb`, `self_undefined_method.rb`, `visibility_mismatch.rb`, `override_visibility.rb`, `override_return_widened.rb`, `nil_receiver.rb`, `wrong_arity.rb`, `override_param_narrowed.rb` (with `override_support.rb`, the ancestry walk and RBS helpers the three override rules share), `return_type.rb`, `unreachable_branch.rb`, `argument_type.rb`, and `receiver_predicates.rb`, the predicates several rules share), `lib/rigor/analysis/rule_catalog.rb` |
| Run orchestration | `lib/rigor/analysis/runner.rb`, `lib/rigor/analysis/runner/` (ADR-116 moved the run-dependency leaf rows to `dependency_rows.rb`, the pure parts of the per-file scope seed to `scope_seed.rb` and the effects sidecar's cache reads and writes to `effect_cache_entries.rb`), `lib/rigor/analysis/worker_session.rb` |
| Incremental runs and the run cache | `lib/rigor/analysis/incremental_session.rb`, `lib/rigor/analysis/run_cache_key.rb` (the key), `lib/rigor/analysis/runner/dependency_rows.rb` (the validation rows the key does not carry) |
| Dependency graph (ADR-46) | `lib/rigor/analysis/dependency_recorder.rb`, `lib/rigor/analysis/incremental.rb`. The engine records into the recorder from `lib/rigor/inference/` and `lib/rigor/scope.rb`, so it is an engine service that lives here for historical reasons. |
| Reachability (`rigor unused`) | `lib/rigor/analysis/reachability/` |
| Template units (ERB and friends) | `lib/rigor/analysis/template_units.rb` and the other `template_unit_*.rb` files |
| Diagnostic values | `lib/rigor/analysis/diagnostic.rb`, `lib/rigor/analysis/result.rb`, `lib/rigor/analysis/baseline.rb` |
| Flow facts | `lib/rigor/analysis/fact_store.rb`: the facts a `Scope` carries. Also an engine service. |

Two names occur twice. `Analysis::FactStore` holds flow facts; `Plugin::FactStore`
(`lib/rigor/plugin/fact_store.rb`) holds plugin-published facts. `lib/rigor/source/constant_path.rb` renders a
Prism constant path as a string; `lib/rigor/reflection/constant_path.rb` resolves one segment by
segment.

## To add one of these, edit all of these

Each kind below is listed by hand in several files. Miss one and the result is usually a silent
gap, not an error. ADR-116 criterion C1 is to declare each kind once; until that lands for a kind,
this is its list.

| To add | Edit |
| --- | --- |
| A check rule | `lib/rigor/analysis/check_rules/rule_ids.rb`, `lib/rigor/analysis/rule_catalog.rb`, `lib/rigor/configuration/severity_profile.rb`, `docs/manual/04-diagnostics.md`, and the rule itself where its facts are: a rule's own module under `lib/rigor/analysis/check_rules/`, entered from `call_node_diagnostics` (call-site rules) or `main_pass_node_diagnostics` (`def` and `if` rules) in `lib/rigor/analysis/check_rules.rb` (`call.undefined-method` is `undefined_method.rb`, `call.unresolved-toplevel` is `unresolved_toplevel.rb`, `call.wrong-arity` is `wrong_arity.rb`, `call.possible-nil-receiver` is `nil_receiver.rb`, `call.argument-type-mismatch` is `argument_type.rb`, `def.return-type-mismatch` is `return_type.rb`, `flow.unreachable-branch` is `unreachable_branch.rb`), a node collector under `lib/rigor/analysis/check_rules/` (wired in `build_node_collectors`, with its message builder as the collector's own `diagnostics`, called through `COLLECTOR_DIAGNOSTIC_BUILDERS`), a run-level rule in a pass under `lib/rigor/analysis/runner/` (the `effect.*` rules), an RBS-consistency rule in `lib/rigor/environment/member_consistency.rb`. `docs/type-specification/diagnostic-policy.md` when the rule's policy is specified there; about half the rule ids are. |
| A CLI command | `lib/rigor/cli.rb` (`HANDLERS` and its `run_*` method), a command class under `lib/rigor/cli/`, `lib/rigor/cli/catalogue.rb`, `docs/manual/02-cli-reference.md` |
| A configuration key | `lib/rigor/configuration/defaults.rb` (`DEFAULTS`), `lib/rigor/configuration/coercion.rb` (its `coerce_*` validator), `lib/rigor/configuration.rb` (the call in `initialize`, the reader, and `to_h`), `schemas/rigor-config.schema.json`, `docs/manual/03-configuration.md`. `to_h` is hand-written and is the run-cache key's input: a key that changes a diagnostic and is missing there serves stale cached results, and no gate checks it. A key that changes the RBS environment also goes into `lib/rigor/cache/rbs_descriptor.rb`. |
| A plugin hook | The method on `lib/rigor/plugin/base.rb` and its RBS under `sig/rigor/`; the place the engine calls it (grep an existing hook of the same kind: `narrowing_facts_for` is called from `lib/rigor/inference/statement_evaluator.rb`, `declared_members` from `lib/rigor/sig_gen/generator.rb`); `lib/rigor/plugin/registry.rb` when the engine reaches it through the registry; `lib/rigor/plugin/manifest.rb` when a plugin declares it in its manifest; `lib/rigor/analysis/plugin_fact_fingerprint.rb` when it contributes a type; `docs/internal-spec/plugin.md`, `docs/internal-spec/public-api.md` |
| A discovery table | its collector, `lib/rigor/scope/discovery_index.rb`, the merge, fold and seed-bundle code in `lib/rigor/inference/scope_indexer.rb`, `lib/rigor/inference/project_seed_tables.rb`, the reader on `lib/rigor/scope.rb`, `lib/rigor/analysis/runner.rb`, `lib/rigor/analysis/runner/project_pre_passes.rb`, `sig/rigor/scope.rbs`, and a cache schema bump (ADR-116 WD2) |
| A dispatch tier | A module under `lib/rigor/inference/method_dispatcher/` with `try_dispatch`, its `require_relative` and its position in the tier arrays of `lib/rigor/inference/method_dispatcher.rb`, `docs/internal-spec/inference-engine.md` § "Dispatch tier contract". A tier that must win before any RBS-backed answer, or run only on a miss, belongs with the `try_*` calls of `ExpressionTyper#call_result_type_for` in `lib/rigor/inference/expression_typer.rb` instead. |
| A thread-local or memo | One declaration in `lib/rigor/typing_state.rb`. No other file under `lib/rigor/` calls `Thread.current[]`. Two files keep attribution state with `thread_variable_get`/`set` (`lib/rigor/analysis/run_disclosure_credit.rb`, `lib/rigor/plugin/io_boundary.rb`); do not copy that for engine state. |

## Which spec style to write

Per-example cost differs by two orders of magnitude, so choose the cheapest style that can see the
behaviour. Measured 2026-11-17, one run each: `spec/rigor/type/combinator_spec.rb` 0.03 s for 161
examples, `spec/rigor/inference/mutation_widening_spec.rb` 0.11 s for 87, and
`spec/rigor/analysis/check_rules/special_global_write_spec.rb` 17.5 s for 45.

| Style | Cost per example | Use for |
| --- | --- | --- |
| Plain data: build types with `Type::Combinator`, or a `CallContext` with `cc(...)` from `spec/support/call_context_helpers.rb` | under 1 ms | Type algebra, acceptance, one dispatch tier, narrowing primitives, anything under `lib/rigor/source/` |
| Parse a snippet and type it against `Scope.empty` | 1–3 ms | One engine feature: a narrowing rule, a widening, a census |
| A full run through `analyze(...)` from `spec/support/runner_helpers.rb`, which a spec gets with `type: :runner` metadata | 200–400 ms | Behaviour that needs the runner: cross-file discovery, rule output and suppression, the pool, caches, incremental runs |

A spec file named for its `lib/` file is what `make verify-changed` selects by name when that file
changes. A spec named for an issue is selected only when it is itself edited or names a changed
fixture, so put a regression example in the spec of the module that owns the fix.
