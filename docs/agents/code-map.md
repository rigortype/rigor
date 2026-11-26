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
| Statement walking and scope threading | `lib/rigor/inference/statement_evaluator.rb` | Entry: `evaluate`. Owns assignments, control flow, loops, blocks in statement position, `def` and class bodies, pattern matching, rescue. Two clusters ADR-116 moved out are plain modules under `statement_evaluator/` that take the evaluator and the state they read as arguments: `pattern_bindings.rb` (`PatternBindings`: `rescue` reference binding, `case/in`, `=>` and `in` patterns, named-capture `=~`) and `def_arguments_and_assertions.rb` (`DefArgumentsAndAssertions`: `def` as a call argument, RSpec matcher narrowing, RBS::Extended and plugin post-return facts). They call back `StatementEvaluator#sub_eval`, `#widen_index_target`, `#widen_attribute_write` and `#eval_def`, public and marked `@api private` for that. |
| Expression typing | `lib/rigor/inference/expression_typer.rb` | Entry: `type_of`. Owns the dispatch table, most per-node typers, call typing before and after dispatch, and user-method return inference (`return_type_for`). Two clusters ADR-116 moved out are plain modules under `expression_typer/` that take the typer and the state they read as arguments: `composites.rb` (`Composites`: hash, array, range, interpolation and pass-through nodes) and `writes.rb` (`Writes`: assignments and compound writes in value position) — each reached through a one-line private delegator of the same name that `PRISM_DISPATCH` names — and `per_element_assemblers.rb` (`PerElementAssemblers`: the per-element block-fold assemblers and their table). `Composites` calls back `ExpressionTyper#type_of`; `Writes` calls back `#type_of`, `#dynamic_top` and `#resolve_constant_name` (the last two public and marked `@api private` for that). |
| The same construct in both | both files | A construct in statement position is evaluated by `StatementEvaluator`, in value position by `ExpressionTyper`; they recurse into each other through `Scope#evaluate` and `Scope#type_of`. Block entry and compound writes exist in both (ADR-116 WD6). Check both before changing either. |
| Narrowing | `lib/rigor/inference/narrowing.rb`, `lib/rigor/inference/narrowing/` | Stateless. Predicate and type-level narrowing; smaller features are siblings such as `lib/rigor/inference/indexed_narrowing.rb`. The leaf clusters ADR-116 moved out are modules under `narrowing/` that `Narrowing` calls and that call back into it only from `Complements` (`narrow_not_refinement`) and `RegexMatch` (`narrow_nil`, `narrow_not_class`): `complements.rb` (complements, finite domains, integer-range algebra), `presence_predicates.rb` (emptiness and key presence), `class_dispatch.rb` (`narrow_class` per carrier), `regex_match.rb` (regex match predicates, capture groups). |
| Assignability | `lib/rigor/inference/acceptance.rb` | "Does this type accept that one", with reasons. |
| Method dispatch | `lib/rigor/inference/method_dispatcher.rb`, `lib/rigor/inference/method_dispatcher/` | `resolve_site(context)` is the tier ladder, written as the order the tiers are asked in, behind the nil-receiver guard and the optional-count split. Two entries end in it: `dispatch_site(context)` for a caller that built the `CallContext` (it adds the transitive-void record and the trace event), and `resolve`, the keyword entry of a tier that dispatches again. `dispatch` is `dispatch_site` behind one `CallContext.build`. Every tier is a module with `try_dispatch(CallContext)`. Outside the precise band (`dispatch_precise_tiers`) and the `BoundMethod` backward fold ahead of it, `resolve_site` asks a tier through a tier array, or by a call where it records something after the answer. The dispatcher is one rung of the call ladder (next row): what answers before any tier here, or only after all of them decline, is a rung of `ExpressionTyper`. |
| Call-typing order | `lib/rigor/inference/call_ladder.rb` | `CallLadder::RUNGS` declares the order `ExpressionTyper` types a call in: one row per rung, the dispatcher among them, each naming the entries that ask it (a call, the read of a compound index write, a literal `send`'s target). `ENTRIES` names the methods each entry is written in (the typer's, or a rung module's for a sequence inside a rung), and `EXCEPTIONS` the sequences that depart from the rows: drift, each against the issue whose fix deletes its row, and one design. `PORT` is what a rung module under `call_ladder/` may call on the typer it is given, `REENTRY` the typer methods public only for that, `PUBLIC_CALLBACKS` the ones that were public already (`type_of`), `SECOND_ENTRIES` what a rung module exposes beside `try_call`, and `DISPATCHER_INTERIOR` the dispatcher's entries the typer and the rung modules do not ask. The engine does not load the file: `spec/rigor/inference/call_ladder_spec.rb` reads the typer and the rung modules with Prism (`spec/support/call_ladder_pin.rb`) and fails where code and tables disagree, and `spec/rigor/inference/call_ladder/port_spec.rb` and `reentry_spec.rb` hold the port (`spec/support/call_ladder_port.rb`). The rule is `docs/internal-spec/inference-engine.md` § "The call ladder". |
| Declaration discovery | `lib/rigor/inference/scope_indexer.rb`, `lib/rigor/inference/scope_indexer/`, `lib/rigor/inference/declaration_walk.rb`, `lib/rigor/inference/declaration_walk/` | Despite the name, little of `scope_indexer.rb` is the per-node scope index: `index` stays, and the walk that fills the nodes the evaluator did not visit is `scope_indexer/node_propagation.rb` (`NodePropagation`; `ScopeIndexer.propagate` delegates to it). The rest builds the project-wide discovery tables, folds them across files and encodes seed bundles. Five units ADR-116 WD9 moved out whole are modules under `scope_indexer/`, each behind its one function and none calling back into `scope_indexer.rb`: `declaration_signature.rb` (`DeclarationSignature.declaration_signature`, a file's ADR-89 declaration signature), `program_globals.rb` (`ProgramGlobals.seed_program_globals`, the program-global pre-pass of `index`), `class_declarations.rb` (`ClassDeclarations.collect_class_decls`, the cross-file class table of one file), `literal_receiver_mutations.rb` (`LiteralReceiverMutations.collect_literal_receiver_mutations`, the #540 census of the constants and class variables a file mutates in place) and `published_constant_ivars.rb` (`PublishedConstantIvars.seed_published_constant_ivars`, the #667 census of the instance variables seeded from a published constant). The last three ask `DeclarationWalk::Rules` for each declaration context. A sixth, `class_cvar_census.rb` (`ClassCvarCensus.build_class_cvar_index`, the class-variable census behind the `class_cvars` table), calls nothing back and asks `CensusScope.census_body_scope` (below): its collector on the shared walk, `class_cvars_collector.rb`, calls three more of its functions (`collect_def_cvar_writes`, `collect_body_cvar_writes`, `finished_cvar_census`), and the walker that collector replaced stays in it as the shadow oracle. A seventh, `shared_walk_tables.rb` (`SharedWalkTables.declaration_walk_tables`, the superclass, header-nesting, def-nesting and member-layout tables one shared walk builds), calls back one function (`ScopeIndexer.add_header_nesting`): its collectors on the shared walk (`superclasses_collector.rb`, `member_layouts_collector.rb`, `def_nestings_collector.rb`) call its four recorders, `cvar_hierarchy.rb` its `recorded_ancestor_name`, and `scope_indexer.rb` its two readers of a factory call's member list (`meta_member_names`, `meta_members_open?`); the walkers those collectors replaced stay in it as the shadow oracles. Three smaller ones followed ([#3400](https://github.com/rigortype/rigor/issues/3400)). `mutated_carrier_widening.rb` (`MutatedCarrierWidening`, the #540 widening of the constants and class variables a file mutates in place) has four functions another file calls, `widen_mutated_constants` and `widen_mutated_cvars` from `scope_indexer.rb` (the first from `constant_ivar_value.rb` too) and `census_mutated_type` and `census_unpinned_content` from `mutated_element_census.rb`, and `factory_call_resolver.rb` (`FactoryCallResolver.resolve_meta_factory_call`, the `Data.define` or `Struct.new` call an expression unwinds to) is asked by `scope_indexer.rb` and `shared_walk_tables.rb`; neither calls back. `singleton_class_sources.rb` (`SingletonClassSources.record_singleton_class_sources`, the constants whose singleton side a file writes to without declaring them) calls back two recognisers, `ScopeIndexer.singleton_receiver_constant_name` and `surface_rewriting_call?`. Then the constant tables: `constant_tables.rb` (`ConstantTables`, the typed in-source constant table, the #644 publication census and the write-target rules both ask) has four functions another file calls, `build_in_source_constants` (from `scope_indexer.rb`, `constant_ivar_value.rb` and `pre_eval_constants.rb`), `constant_write_census` and `dynamic_target_key` (from `scope_indexer.rb`) and `rebound_block_self` (from `scope_indexer.rb` and `shared_walk_tables.rb`), calls nothing back and asks `CensusScope.census_body_scope` and `census_nesting` (below). Then two units behind one function each: `alias_def_nodes.rb` (`AliasDefNodes.apply_alias_def_nodes`, the post-pass of the methods table that gives the new name of each `alias` and `alias_method` the `def` node its old name held at the alias, with the `AliasMap` it fills) is called once, from `ScopeIndexer.build_methods_and_def_nodes`, and calls back one function, `ScopeIndexer.follow_slot_writer`; `declaration_artifacts.rb` (`DeclarationArtifacts.build_declaration_artifacts`, the identity table of a file's `class` / `module` headers and the classes the file declares) is called from `ScopeIndexer.index` and `pre_eval_constants.rb`, and calls back three functions of the cross-file fold, `ScopeIndexer.compact_header_renames`, `rename_compact_name` and `synthesize_namespace_prefixes`. Then the mixin tables, as two modules: `mixin_effects.rb` (`MixinEffects`, what the include walk and the extend walk both ask about a call that mixes a module in or may: the ancestry sides it reshapes, and the taint of an owner side for a call the tables cannot hold) has eight functions another file calls, `program_statements`, `taint_unrecorded_mixin`, `taint_computed_mixin_send`, `mixin_effects`, `hook_def_params`, `taint_opaque_eval`, `prepend_call_receiver` and `meta_new_mixin_owner`, each from `mixin_tables.rb` and from the extend walk left in `scope_indexer.rb`, and calls back three recognisers, `ScopeIndexer.opaque_mixin_argument?`, `mixin_call_view` and `lexical_self_receiver?`; `mixin_tables.rb` (`MixinTables.mixin_tables`, the include and prepend tables of one file, with the edges whose order is not a fact) is called from `ScopeIndexer.merge_mixin_tables` and `fold_file_mixin_tables`, asks `MixinEffects` and `ConstantTables.rebound_block_self`, and calls back two of those recognisers, `ScopeIndexer.mixin_call_view` and `lexical_self_receiver?`. Then the class ivar index, with the census scope it asks for: `census_scope.rb` (`CensusScope`, the scope a census pre-pass types a body's rvalues under) has two functions, `census_body_scope` and `census_nesting`, called from `class_ivar_index.rb`, `class_cvar_census.rb` and `constant_tables.rb`, and calls nothing back; `class_ivar_index.rb` (`ClassIvarIndex.build_class_ivar_index`, the per-class table of instance-variable types behind `class_ivars`, with the `MethodEffectResolver` of its definite-assignment summary, and the `IVAR_BARRIER_NODES` and `BindingTargets` that `class_cvar_census.rb` reads too) is called once, from `ScopeIndexer.index`, and calls back four recognisers, `ScopeIndexer.def_side`, `def_receiver_targets_lexical_self?`, `each_attr_macro_name` and `attr_macro`. The declaration-context rules, what a `class` / `module` header, a `K = Class.new { … }`-family write and an eval-family block make of `self` and the cref, are `declaration_walk/rules.rb` (`DeclarationWalk::Rules`, ADR-116 WD9): the walk's `Context`, the hand-written walkers left in `scope_indexer.rb` and every other file that asks a rule call it as `DeclarationWalk::Rules.x`, and it names nothing of `ScopeIndexer`. Its functions callable from outside and its exported constants are pinned by `spec/rigor/inference/declaration_walk/rules_spec.rb` as a list that does not grow; adding one is an amendment to ADR-116. New collectors go on the shared `DeclarationWalk` where its events suffice (ADR-116 WD5). |
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
| A dispatch tier | A module under `lib/rigor/inference/method_dispatcher/` with `try_dispatch`, its `require_relative` and its position in `lib/rigor/inference/method_dispatcher.rb` (a tier array, walked by `first_tier_answer`, when nothing in `resolve_site` follows its answer; a call in `resolve_site` when a record on the scope or the reporter does), its `try_dispatch` row in `sig/rigor/inference.rbs`, `docs/internal-spec/inference-engine.md` § "Dispatch tier contract". A tier that must win before any RBS-backed answer, or run only on a miss, is not a dispatch tier but a call-typing rung (next row). |
| A call-typing rung | Its row in `CallLadder::RUNGS` (`lib/rigor/inference/call_ladder.rb`), at its position in the order, naming the entries that ask it; its call at that position in each of those entries' methods, in `lib/rigor/inference/expression_typer.rb` or a rung module (`CallLadder::ENTRIES` names them); and its body: a module under `lib/rigor/inference/call_ladder/` whose entry is `try_call(site, typer)` (`refined.rb`, `literal_send.rb`, `top_level_def.rb`, `overriding_def.rb`, `user_method.rb` and `project_singleton.rb`), or a private method of the typer, the row saying why (`in_typer_because`). `spec/rigor/inference/call_ladder_spec.rb` fails a rung asked with no row, out of the rows' order, or by an entry its row does not name, and its message names the edit that settles it. A rung an entry should ask and does not yet is a row in `CallLadder::EXCEPTIONS` naming its issue. A body that moves out of the typer ([ADR-116](../adr/116-hot-file-restructuring.md) § "Amendment, 2026-11-19 — WD12's interface") changes its row's `home` and `asked_as`, which is where the spec takes the spelling of the call from, and brings: the module's `require_relative` in the typer; its `self?.` rows in `sig/rigor/inference.rbs`, with `typer` declared `ExpressionTyper`; its spec under `spec/rigor/inference/call_ladder/`; each typer method it calls back (at most four, or the rung stays): one public already named in `CallLadder::PUBLIC_CALLBACKS`, any other made public `@api private` in the typer's one `public` statement and named in `CallLadder::REENTRY`; and a `CallLadder::SECOND_ENTRIES` row, named in the amendment, for anything else it exposes. `spec/rigor/inference/call_ladder/port_spec.rb` fails a call on the typer outside `CallLadder::PORT`, code the module types another way (a typer of its own, `typer.scope.type_of`, a `const_get`), and an entry no table names, and `reentry_spec.rb` a re-entry point called from anywhere else. |
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
