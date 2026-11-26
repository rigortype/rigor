# frozen_string_literal: true

require "prism"

require_relative "../scope"
require_relative "../type"
require_relative "../source/alias_names"
require_relative "../source/forwardable_delegators"
require_relative "../source/literals"
require_relative "../source/constant_path"
require_relative "object_mixins"
require_relative "../source/node_children"
require_relative "../source/node_walker"
require_relative "../source/parameter_envelope"
require_relative "../cache/file_digest"
require_relative "../typing_state"
require_relative "../memo_audit"
require_relative "../analysis/check_rules/published_constant_guard"
require_relative "anonymous_meta_class"
require_relative "census_foreign_block"
require_relative "def_handle"
require_relative "definers_index"
require_relative "fresh_frame_blocks"
require_relative "global_write_census"
require_relative "guard_rebinding"
require_relative "last_line"
require_relative "last_status"
require_relative "error_info"
require_relative "hash_lookup_mutation"
require_relative "in_effect_refinements"
require_relative "refine_census"
require_relative "refine_self"
require_relative "receiver_writer_call"
require_relative "reflective_ivar_write"
require_relative "index_write_widening"
require_relative "module_function_state"
require_relative "multi_target_binder"
require_relative "mutation_widening"
require_relative "narrowing"
require_relative "operand_effects"
require_relative "statement_evaluator"
require_relative "struct_fold_safety"
require_relative "unknown_store_widening"
require_relative "declaration_walk/traversal"
require_relative "scope_indexer/class_cvars_collector"
require_relative "scope_indexer/superclasses_collector"
require_relative "scope_indexer/def_nestings_collector"
require_relative "scope_indexer/layered_def_nestings"
require_relative "scope_indexer/mixin_accumulator"
require_relative "scope_indexer/certainty"
require_relative "scope_indexer/member_layouts_collector"
require_relative "scope_indexer/declared_ivar_types"
require_relative "scope_indexer/declared_param_writes"
require_relative "scope_indexer/constant_ivar_value"
require_relative "scope_indexer/ivar_contributions"
require_relative "scope_indexer/empty_seed"
require_relative "scope_indexer/mutated_element_census"
require_relative "scope_indexer/declaration_signature"
require_relative "scope_indexer/program_globals"
require_relative "declaration_walk/rules"
require_relative "scope_indexer/class_declarations"
require_relative "scope_indexer/literal_receiver_mutations"
require_relative "scope_indexer/published_constant_ivars"
require_relative "scope_indexer/class_cvar_census"
require_relative "scope_indexer/shared_walk_tables"
require_relative "scope_indexer/mutated_carrier_widening"
require_relative "scope_indexer/factory_call_resolver"
require_relative "scope_indexer/singleton_class_sources"
require_relative "scope_indexer/constant_tables"
require_relative "scope_indexer/alias_def_nodes"
require_relative "scope_indexer/declaration_artifacts"
require_relative "scope_indexer/mixin_effects"
require_relative "scope_indexer/mixin_tables"

module Rigor
  module Inference
    # Builds a per-node scope index for a Prism program by running `Rigor::Inference::StatementEvaluator` over the root
    # and recording the entry scope visible at every node. Expression-interior nodes the evaluator does not specialise
    # (call receivers, arguments, array/hash elements, ...) inherit their nearest statement-y ancestor's recorded scope,
    # so a downstream caller that looks up the scope for any Prism node in the tree always gets the scope that was
    # effectively visible at that point.
    #
    # The CLI commands `rigor type-of` and `rigor type-scan` consume the index so that local-variable bindings
    # established earlier in the program are visible to the typer when probing later nodes. Without the index, both
    # commands would type every node under an empty scope and miss the constant-folding / dispatch precision that Slice
    # 3 phase 2's StatementEvaluator unlocks.
    #
    # The returned object is an identity-comparing Hash:
    #
    # ```ruby
    # index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Scope.empty)
    # index[some_prism_node] #=> the Rigor::Scope visible at that node
    # ```
    #
    # Nodes that are not part of the program subtree (e.g. synthesised virtual nodes that the caller looks up after the
    # fact) yield the seeded `default_scope`. The returned Hash is mutable in principle but callers MUST treat it as
    # read-only; the indexer itself never exposes a way to update it past construction.
    # rubocop:disable-next Metrics/ModuleLength
    module ScopeIndexer
      # Issue #617 — the descriptor for a name a file writes ONLY through `||=`. It publishes nothing either,
      # and it is the memoization idiom rather than a binding while no other file memoizes the name: a
      # constant compound write keeps its memo reading beside it ({Scope#bound_constant_names}), where every
      # other form makes that write read the constant as bound. A second write of any other form in the same
      # file retracts it to {ConstantTables::CONSTANT_UNPUBLISHABLE}.
      CONSTANT_MEMO = :memo

      # Issue #668 — the census key a constant write through a base no name reaches is filed under:
      # `*::LIMIT` for `k::LIMIT = 7`. `*` is not a constant character, so the key can never collide with a
      # name a program writes, while its LAST SEGMENT is the real one — which is what the ADR-46 `constant:`
      # edge and {Analysis::Incremental.changed_constant_publications} key on, so both keep working unchanged.
      DYNAMIC_TARGET_PREFIX = "*::"

      module_function

      # No path whose contributions are all `possible` (issue #2021), the cross-file walks' default.
      EMPTY_PATH_SET = Set.new.freeze
      # The {IvarWriterCensus} entry kinds the project pre-pass tags with the file that records them.
      PATH_TAGGED_KINDS = %i[own_write own_write_type].to_set.freeze

      # Build the scope index for a Prism program subtree.
      #
      # @param root — usually a `Prism::ProgramNode`, but any
      #   subtree the caller wants the indexer to walk works.
      # @param default_scope — the scope used for the root,
      #   and the fallback returned for any Prism node not contained in
      #   `root`'s subtree.
      # @param converged_loop_recording — display-path flag —
      #   when true the evaluator re-records fixpoint-tracked loop
      #   bodies from their CONVERGED bindings so per-line probes
      #   (`rigor annotate`) reflect the post-writeback state, not the
      #   cap-N intermediate constants. Off for the check path.
      # @param widen_clauses — check-path flag (issue #1231): a rescue or
      #   `ensure` clause records the variables the `begin` body writes as
      #   `Dynamic[top]`. Off for every other reader, so parameter inference
      #   and sig-gen observe the clause's plain entry.
      # @return identity-comparing
      #   table whose default value is the seeded `default_scope`.
      #
      # `declared_ivar_types:` — whether an RBS-declared ivar type replaces the census's join of the writes (#1406).
      # `rigor sig-gen` passes false: it proposes what the code says, and reading a declaration back would make a row
      # count as generated only because it is declared.
      # `ivar_writer_scope:` — the scope whose project tables the #1154 declared-parameter credit reads to find the
      # ivar writers outside this file ({DeclaredParamWrites}); defaults to `default_scope`. `rigor sig-gen` indexes
      # each file under an unseeded scope, so it passes one carrying the project's tables.
      def index(root, default_scope:, converged_loop_recording: false, widen_clauses: false, # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
                declared_ivar_types: true, ivar_writer_scope: nil)
        # Slice A-declarations. Build the declaration overrides first so every scope handed to the StatementEvaluator
        # already carries the table; structural sharing through `Scope#with_local` / `#with_fact` / `#with_self_type`
        # propagates it across every derived scope.
        # Issue #722 residue 2 — the project's settled declaration names are the oracle the file's own
        # compact headers are re-anchored against. `discovered_class_sources` would be the more direct
        # reading, but it names files rather than settled declarations, and the fold has already applied its
        # own re-anchoring to this table.
        declared_types, discovered_classes =
          DeclarationArtifacts.build_declaration_artifacts(root, default_scope.discovered_classes.keys.to_set)
        # Merge the indexer's findings on top of whatever the base scope already carries so callers that seed cross-file
        # class knowledge (e.g. the ADR-14 `SigGen::ObservationCollector` pre-walking project `lib/` before scanning
        # `spec/`) keep their seeds alongside the per-file declarations the indexer itself discovers. Indexer-found
        # entries win on collision — same-file declarations are the most specific authority.
        merged_classes = default_scope.discovered_classes.merge(discovered_classes)
        seeded_scope = default_scope.with_discovery(
          default_scope.discovery.with(declared_types: declared_types,
                                       discovered_classes: merged_classes)
        )

        # Slice 7 phase 2. Pre-pass over every class/module body to collect the per-class ivar accumulator. Seeded after
        # declared_types so the rvalue typer in the pre-pass can see declaration overrides.
        class_ivars = DeclaredParamWrites.with_writer_scope(ivar_writer_scope) do
          build_class_ivar_index(root, seeded_scope, declared_ivar_types: declared_ivar_types)
        end
        seeded_scope = seeded_scope.with_discovery(seeded_scope.discovery.with(class_ivars: class_ivars))

        # Slice 7 phase 6. Same pre-pass shape for cvars (per class) and globals (program-wide). Globals are also
        # materialised into the top-level scope's `globals` map so reads at the top level (and in CLI probes that do not
        # enter a method body) observe the precise type without consulting the accumulator on every lookup.
        # Issue #540 — a literal-shape carrier assigned to a constant or class variable is only as good as
        # the file's OWN mutations of it: `ISPELL_STATUS = {}` with a sibling method writing
        # `ISPELL_STATUS[:key] = param` must not fold reads through the closed empty shape. One census walk
        # collects the mutated names; the two accumulators below widen their entries to the Dynamic-wrapped
        # form, contents unpinned ({MutatedCarrierWidening.census_mutated_type}), so reads stay honest without
        # licensing the negative rules.
        mutations = LiteralReceiverMutations.collect_literal_receiver_mutations(root)

        class_cvars = MutatedCarrierWidening.widen_mutated_cvars(
          ClassCvarCensus.build_class_cvar_index(root, seeded_scope), *mutations.values_at(:cvars, :cvar_elements)
        )
        seeded_scope = seeded_scope.with_discovery(seeded_scope.discovery.with(class_cvars: class_cvars))
        seeded_scope = ProgramGlobals.seed_program_globals(root, seeded_scope)

        # Slice 7 phase 9. In-source constant value tracking. Walks every ConstantWriteNode/ConstantPathWriteNode in the
        # program and types its rvalue under a scope that carries the surrounding qualified prefix as `self_type`, so
        # the rvalue typer sees in-class references resolve correctly. Multiple writes to the same qualified name union
        # via `Type::Combinator.union`.
        # Issue #352 — the per-file table merges OVER whatever the base scope already published (the
        # `pre_eval:` constant seed `Runner#project_scope_seed_tables` applies). Same-file declarations are the
        # most specific authority, exactly as `merged_classes` above resolves the same collision. Without the
        # merge, the assignment below would silently drop the project seed on every file.
        in_source_constants = MutatedCarrierWidening.widen_mutated_constants(
          ConstantTables.build_in_source_constants(root, seeded_scope),
          *mutations.values_at(:constants, :constant_elements)
        )
        seeded_scope = seed_constant_tables(seeded_scope, default_scope, in_source_constants, root)
        seeded_scope = PublishedConstantIvars.seed_published_constant_ivars(seeded_scope, root)

        # Slice 7 phase 12. In-source method discovery. Walks every class/module body for `Prism::DefNode` and
        # recognised `define_method` calls and records the introduced method names. `rigor check` consults the table to
        # suppress false positives for methods the user has defined but no RBS sig describes. Merged UNDER the
        # cross-file pre-pass seed; details: merge_project_method_indexes. One combined descent yields both the
        # discovered-methods existence table and the instance def-node table — see {#build_methods_and_def_nodes}.
        # `seed_discovered_methods` seeds the former onto the scope and returns the def-node table for
        # `merge_project_method_indexes` below.
        # ADR-119 WD3 — the file's possible contributions, classified once for both def-contribution walks.
        certainty = Certainty.possible_nodes(root)
        seeded_scope, file_tables = seed_discovered_methods(seeded_scope, default_scope, root, certainty)

        # v0.0.2 #5 + ADR-24 slice 2 — record per-instance-method def nodes, the class -> superclass map, and the
        # class/module -> included-modules map, each merged under the cross-file pre-pass seed (see below). v0.1.2 —
        # per-class table of method visibilities (`:public` / `:private` / `:protected`). The
        # `def.method-visibility-mismatch` and ADR-35 `def.override-visibility-reduced` CheckRules consult the table.
        # Seeded inside `merge_project_method_indexes` so the per-file visibilities merge OVER the cross-file project
        # seed rather than overwriting it.
        seeded_scope = merge_project_method_indexes(seeded_scope, default_scope, root, file_tables, certainty)

        table = {}.compare_by_identity
        table.default = seeded_scope

        # Last-visit-wins, not first: when `StatementEvaluator` internally re-evaluates a subtree (notably
        # `eval_begin`'s retry-edge widening pass), the LATER visit carries the corrected entry scope (e.g. a `tries`
        # widened to `Nominal[Integer]` after the rescue body's `tries += 1; retry` is observed). The diagnostic layer
        # reads `table[node]` to type predicates; the second pass's entry is the one that reflects all flow-derived
        # rebinds, so it MUST overwrite the first. ADR-48 Struct slice 3 — install the top-level fold-safe-local set so
        # a member read off a mutation-free top-level struct binding folds.
        # Issue #1358 — the file's top level runs in a frame of its own, whose match globals its blocks and closures
        # share.
        seeded_scope = seed_struct_fold_safe(seeded_scope, root).with_match_frame(root)

        evaluate = recording_evaluator(table, converged_loop_recording, widen_clauses)
        evaluate.call(root, seeded_scope)

        with_unentered_evaluator(evaluate) { propagate(root, table, seeded_scope) }
        table
      end

      # The `(node, scope, excluded = nil) ->` evaluation that records every node it visits into `table`, except the
      # nodes in `excluded`: the file's own pass, and each construct {NodePropagation#evaluate_unentered_flow}
      # evaluates in the walk after it.
      def recording_evaluator(table, converged_loop_recording, widen_clauses)
        lambda do |node, scope, excluded = nil, block_only: false|
          on_enter =
            if excluded.nil? || excluded.empty? then ->(visited, at) { table[visited] = at }
            else ->(visited, at) { table[visited] = at unless excluded.include?(visited) }
            end
          evaluator = StatementEvaluator.new(scope: scope, on_enter: on_enter, widen_clauses: widen_clauses,
                                             converged_loop_recording: converged_loop_recording)
          block_only ? evaluator.evaluate_block_of(node) : evaluator.evaluate(node)
        end
      end

      # Runs the combined methods/def-nodes descent (one walk of the file), seeds the discovered-methods existence table
      # onto `seeded_scope` (merged UNDER the cross-file pre-pass seed `default_scope` carries), and returns
      # `[scope, [file_def_nodes, file_envelopes, file_siblings]]` so the caller can thread the def-node and issue #992
      # envelope tables into {#merge_project_method_indexes} without walking the file a second time.
      #
      # ADR-119 WD3 — the file's `possible_discovered_methods` folds over the seed's by {#fold_possible_methods}, so a
      # name the file defines certainly is no longer possible and a name only the file's possible contribution
      # supplies becomes possible. The file's other siblings are returned for {#merge_project_method_indexes}.
      def seed_discovered_methods(seeded_scope, default_scope, root, certainty = Certainty.possible_nodes(root))
        file_methods, file_def_nodes, file_envelopes, file_refinements, file_siblings =
          build_methods_and_def_nodes(root, default_scope.source_path, certainty: certainty)
        seed_methods = default_scope.discovered_methods
        discovered_methods = deep_merge_class_methods(seed_methods, file_methods)
        discovery = seeded_scope.discovery.with(
          discovered_methods: discovered_methods,
          possible_discovered_methods: fold_possible_methods(
            seeded_scope.discovery.possible_discovered_methods, seed_methods,
            file_siblings[:possible_discovered_methods], file_methods
          )
        )
        # Issue #1120 — only a file that refines something pays the overlay; the cross-file seed already carries
        # every other file's refinements.
        unless file_refinements.empty?
          discovery = discovery.with(
            discovered_refinements: merge_refinement_tables(default_scope.discovered_refinements, file_refinements)
          )
        end
        [seeded_scope.with_discovery(discovery), [file_def_nodes, file_envelopes, file_siblings]]
      end

      # ADR-48 Struct slice 3 — installs the top-level fold-safe-local set ({Inference::StructFoldSafety}). Struct
      # member layouts of constant receivers are resolved through the side-table the seeded scope carries.
      def seed_struct_fold_safe(seeded_scope, root)
        seeded_scope.with_struct_fold_safe(
          StructFoldSafety.fold_safe_locals(
            root, ->(name) { seeded_scope.struct_member_layout(name)&.[](:members) }
          )
        )
      end

      # v0.0.2 #5 + ADR-24 slice 2 — seeds the three project-method indexes onto `seeded_scope`: the per-instance-method
      # def-node table, the class -> superclass map, and the class/module -> included-modules map. Each per-file table
      # is merged UNDER the cross-file `discovered_def_index_for_paths` seed carried on `default_scope` — same-file
      # declarations win per entry, the cross-file seed supplies sibling-file ancestors.
      #
      # Issue #992 — the envelope table is JOINED with the seed rather than overlaid: the seed already carries this
      # file's own contribution (identical, so the join keeps it), and a reopening in a sibling file must still
      # make a disagreeing name opaque here, which "same-file declarations win" would silently undo.
      #
      # `file_tables` is `[file_def_nodes, file_envelopes, file_siblings]` from {#seed_discovered_methods}.
      def merge_project_method_indexes(seeded_scope, default_scope, root, file_tables,
                                       certainty = Certainty.possible_nodes(root))
        # ADR-116 WD5 — the superclass, def-nesting and member-layout tables come from ONE shared walk.
        walked = SharedWalkTables.declaration_walk_tables(root, default_scope.source_path)
        def_nodes, def_nestings = merge_def_node_tables(default_scope, walked, file_tables[0])
        singleton_def_nodes, file_singleton = merge_singleton_def_nodes(default_scope, root, certainty)
        superclasses, header_nestings = merge_ancestry_tables(default_scope, walked)
        includes, prepends, *mixin_unpositioned = merge_mixin_tables(default_scope, root)
        # ADR-35 — per-file visibilities merged OVER the cross-file seed (the current file is authoritative for its own
        # classes; sibling-file ancestors are preserved from the project seed).
        method_visibilities, file_visibilities = merge_method_visibilities(default_scope, root, certainty)
        # ADR-48 — per-file Data + Struct member layouts merged OVER the cross-file seed (same-file declaration is
        # authoritative).
        data_member_layouts, struct_member_layouts = merge_member_layouts(default_scope, walked)

        # #526 — this file's extends folded against the MERGED instance def-nodes (so `extend M` sees a
        # sibling-file M through the cross-file seed). The project-wide fold in {#finalize_def_index}
        # covers cross-file CONSUMERS; this covers the file that declares the extend.
        #
        # Issue #898 — and the same walk's table is now kept, merged over the cross-file seed the way
        # `includes` is: `Narrowing` asks it what a class object's singleton ancestry holds.
        siblings = per_file_siblings(seeded_scope.discovery.sibling_tables, file_tables[0], file_tables[2],
                                     file_singleton, file_visibilities)
        extends, methods_table, unpositioned =
          merge_and_fold_extends(default_scope, root, [def_nodes, file_tables[0]],
                                 [singleton_def_nodes, file_singleton[0]], seeded_scope, siblings, mixin_unpositioned)

        seeded_scope.with_discovery(
          seeded_scope.discovery.with(
            discovered_methods: methods_table,
            discovered_def_nodes: def_nodes,
            discovered_def_nestings: def_nestings,
            discovered_singleton_def_nodes: singleton_def_nodes,
            discovered_superclasses: superclasses,
            discovered_header_nestings: header_nestings,
            discovered_includes: includes,
            discovered_prepends: prepends, discovered_extends: extends,
            unpositioned_mixins: unpositioned,
            discovered_method_visibilities: method_visibilities,
            discovered_parameter_envelopes: merge_envelope_seed(default_scope, file_tables[1]),
            data_member_layouts: data_member_layouts, struct_member_layouts: struct_member_layouts,
            discovered_deferred_ranges: merge_deferred_ranges_seed(default_scope, root),
            # ADR-119 WD1/WD3 — the seed's siblings with this file's folded in ({#per_file_siblings}: the file wins
            # every slot it writes), which the extends fold above then followed (copy on write, so the seed's
            # tables are never written).
            **siblings
          )
        )
      end

      # Returns `[merged table, [file table, file contested slots]]` ({#build_method_visibility_tables}).
      def merge_method_visibilities(default_scope, root, certainty)
        file_visibilities = build_method_visibility_tables(root, certainty: certainty)
        merged = default_scope.discovered_method_visibilities.merge(
          file_visibilities.first
        ) { |_class, cross_file, per_file| cross_file.merge(per_file) }
        [merged, file_visibilities]
      end

      # Per-file singleton def nodes merged OVER the cross-file seed (same-file declaration is
      # authoritative for its own classes, sibling-file defs are preserved).
      #
      # Returns `[merged table, [file table, file contested slots]]` ({#build_singleton_def_tables}).
      def merge_singleton_def_nodes(default_scope, root, certainty)
        file_singleton = build_singleton_def_tables(root, certainty: certainty)
        merged = default_scope.discovered_singleton_def_nodes.merge(
          file_singleton.first
        ) { |_class, cross_file, per_file| cross_file.merge(per_file) }
        [merged, file_singleton]
      end

      # ADR-119 WD3 — the per-file merge of the slot siblings, under the members' own merges: this file's
      # `def_nodes`, singleton defs and visibilities win every slot they write, so the seed's contest on those keys
      # is replaced by the file's ({#fold_slot_contests}); the envelopes are joined, so their contests union. The
      # possible methods were folded already ({#seed_discovered_methods}).
      def per_file_siblings(siblings, file_def_nodes, file_siblings, file_singleton, file_visibilities)
        file_singleton_def_nodes, file_singleton_contested = file_singleton
        # The seed's singleton contests stay ({#fold_visibility_contests}); it already holds a disagreement between
        # this file and another.
        siblings[:contested_discovered_method_visibilities] = fold_visibility_contests(
          siblings[:contested_discovered_method_visibilities], {}, *file_visibilities
        )
        siblings[:contested_discovered_def_nodes] = fold_slot_contests(
          siblings[:contested_discovered_def_nodes], file_def_nodes, file_siblings[:contested_discovered_def_nodes]
        )
        siblings[:contested_discovered_singleton_def_nodes] = fold_slot_contests(
          siblings[:contested_discovered_singleton_def_nodes], file_singleton_def_nodes, file_singleton_contested
        )
        siblings[:contested_discovered_parameter_envelopes] = union_paths(
          siblings[:contested_discovered_parameter_envelopes], file_siblings[:contested_discovered_parameter_envelopes]
        )
        siblings
      end

      # Issue #1123 — the two instance-side mixin tables, from ONE descent of this file. Each merges over
      # the cross-file seed per class, with the file under analysis as the later-loading contribution for a
      # reopened class: its `prepend`s and — since #1173, when the include table switched to the same
      # instance-ancestor search order — its `include`s are therefore NEARER than the seed's (the
      # {#accumulate_extend_lists} convention, which exists for the same ordering reason).
      def merge_mixin_tables(default_scope, root)
        file = MixinTables.mixin_tables(root)
        [
          default_scope.discovered_includes.merge(file[:includes]) do |_class, cross_file, per_file|
            (per_file + cross_file).uniq
          end,
          # ADR-129 G4 — each merged list is frozen as the per-file walk's lists are ({MixinTables.freeze_mixin_lists}).
          default_scope.discovered_prepends.merge(file[:prepends]) do |_class, cross_file, per_file|
            (per_file + cross_file).uniq.freeze
          end,
          file[:unpositioned]
        ]
      end

      # The union of `{class => {side => [names]}}` tables — how {Scope::DiscoveryIndex#unpositioned_mixins}
      # folds: an edge any contribution cannot position stays unpositioned. The per-file index folds its own
      # walk over a seed that already carries this file's edges, so the first table itself comes back unless a
      # contribution holds a name the seed lacks: the whole project table is copied only then.
      def union_unpositioned(first, *others)
        result = nil
        others.each do |table|
          table.each do |owner, sides|
            sides.each do |side, names|
              have = (result || first).dig(owner, side)
              next if have && names.all? { |name| have.include?(name) }

              result ||= first.dup
              result[owner] = (result[owner] || {}).merge(side => ((have || []) | names).freeze).freeze
            end
          end
        end
        result ? result.freeze : first
      end

      # The `extend`-edge half of {#merge_project_method_indexes}: merges this file's `extend`s over the
      # cross-file seed AND folds them against the merged def tables — the #526 fold that turns an
      # extended module's instance defs into singleton-side method entries on the extending class.
      #
      # ADR-119 WD1 — the unpositioned union (the seed's, the mixin walks' and this file's extend side) is settled
      # first, because the fold reads it to tell a certain extend edge from a listed one. `siblings` is written by
      # the fold.
      # `def_pair` and `singleton_pair` are `[merged table, this file's own]`; the merged tables are frozen once the
      # fold, their last in-place writer, is done ({#freeze_def_tables}).
      def merge_and_fold_extends(default_scope, root, def_pair, singleton_pair, seeded_scope, siblings,
                                 mixin_unpositioned)
        def_nodes = def_pair.first
        singleton_def_nodes = singleton_pair.first
        file_extends, extends, extend_unpositioned = merge_extend_tables(default_scope, root)
        unpositioned = union_unpositioned(default_scope.discovery.unpositioned_mixins, *mixin_unpositioned,
                                          extend_unpositioned)
        methods_table = fold_per_file_extends(file_extends, def_nodes, singleton_def_nodes, seeded_scope, siblings,
                                              unpositioned)
        # The fold also writes the singleton hash of each class this file `extend`s, declared there or not.
        file_extends.each_key { |owner| singleton_def_nodes[owner]&.freeze }
        freeze_def_tables(def_pair, singleton_pair)
        # #2300 — the override gate's definers index then inverts the seed once per run, not once per file.
        DefinersIndex.record_layers(def_nodes, default_scope.discovered_def_nodes)
        DefinersIndex.record_layers(singleton_def_nodes, default_scope.discovered_singleton_def_nodes)
        [extends, methods_table, unpositioned]
      end

      # Issue #1097 — this file's def / block / lambda ranges merged over the cross-file seed; the
      # ordering predicates key the table by `source_path`, so the entry must exist even on a run
      # that never built the project pre-pass. A seeded entry is only the identical walk product when
      # the pre-pass read the same bytes (a mutant analysed under a seed of the unmutated files does
      # not), so the file is always re-walked and the seed is kept only when the rows are equal — which
      # spares the project-wide Hash copy per file. Issue #1548.
      def merge_deferred_ranges_seed(default_scope, root)
        seeded = default_scope.discovered_deferred_ranges
        fresh = build_deferred_ranges(root)
        return seeded if seeded[default_scope.source_path] == fresh

        seeded.merge(default_scope.source_path => fresh)
      end

      def merge_envelope_seed(default_scope, file_envelopes)
        Source::ParameterEnvelope.merge_tables(default_scope.discovered_parameter_envelopes, file_envelopes)
      end

      # The as-written superclass table and its issue #682 header-nesting twin, each merged over the cross-file
      # seed. Returned as a pair for the same reason {#merge_def_node_tables} is: both come from ONE walk of the
      # file, so a caller cannot pair a superclass name with a nesting recorded by a different parse.
      def merge_ancestry_tables(default_scope, walked)
        [default_scope.discovered_superclasses.merge(walked.fetch(:superclasses)),
         merge_header_nestings(default_scope.discovery.discovered_header_nestings.dup,
                               walked.fetch(:header_nestings)).freeze]
      end

      # Issue #2330 — the per-file def table is read by identity: the callee-chain census memo is keyed by the
      # {Scope::DiscoveryIndex} that carries it, which is only sound while the table is never written in place.
      # Frozen after the extends fold, the last in-place writer; the seed's per-class hashes are frozen already.
      #
      # Only the per-class hashes of the classes this file declares are frozen here (the merge made or took
      # them); a seed-only class's hash was frozen by `finalize_def_index`, so walking the whole table per file is
      # needless.
      def freeze_def_tables(*pairs)
        pairs.each do |table, file_table|
          file_table.each_key { |owner| table[owner].freeze }
          table.freeze
        end
      end

      # The instance-side def-node table and its issue #681 nesting twin, each merged over the cross-file seed.
      # Returned as a pair so the two stay written together: a node the merge keeps must be the same object the
      # nesting table keys, and they are only that if both halves take the same file's walk.
      def merge_def_node_tables(default_scope, walked, file_def_nodes)
        def_nodes = default_scope.discovered_def_nodes.merge(
          file_def_nodes
        ) { |_class, cross_file, per_file| cross_file.merge(per_file) }
        [def_nodes,
         merge_def_nestings(default_scope.discovery.discovered_def_nestings, walked.fetch(:def_nestings))]
      end

      # Issue #681 — the per-file nesting table over the cross-file seed. Both are keyed by node identity, so
      # a same-file declaration and its cross-file twin are distinct keys and the layering order is immaterial.
      # Issue #1507 — layered by lookup ({LayeredDefNestings}) instead of copied: the copy was one insert per
      # `def` in the project for every analysed file. Either table alone is returned as it is when the other is
      # empty — since issue #716 a top-level `def` records its empty chain, so only a file declaring no `def` at
      # all hands back the seed itself.
      def merge_def_nestings(seed, file_nestings)
        return seed if file_nestings.empty?
        return file_nestings if seed.empty?

        LayeredDefNestings.new(file_nestings, seed)
      end

      # Issue #898 — one walk, two consumers: the raw per-file table the #526 method fold reads, and the
      # same table merged over the cross-file seed for the scope. Returned as a pair so a caller cannot
      # pair the fold with a table a different parse produced, as {#merge_ancestry_tables} is.
      def merge_extend_tables(default_scope, root)
        file = extend_tables(root)
        file_extends = file.fetch(:extends)
        # The table stores singleton-ancestor search order, so the file under analysis — the
        # later-loading contribution for a reopened class — prepends over the cross-file seed.
        merged = default_scope.discovered_extends.merge(
          file_extends
        ) { |_class, cross_file, per_file| (per_file + cross_file).uniq }
        [file_extends, merged, file.fetch(:unpositioned)]
      end

      # The per-file half of the #526 fold: mutable copies of the merged tables take the extends, and the
      # existence table (already seeded onto the scope) is rebuilt only when the fold touched it.
      def fold_per_file_extends(extends, def_nodes, singleton_def_nodes, seeded_scope, siblings, unpositioned)
        methods_table = seeded_scope.discovered_methods
        return methods_table if extends.empty?

        mutable_methods = methods_table.transform_values(&:dup)
        fold_extends_into_singleton_tables(extends, def_nodes, singleton_def_nodes, mutable_methods,
                                           siblings: siblings, unpositioned: unpositioned)
        mutable_methods
      end

      # ADR-48 — the per-file Data + Struct member-layout tables, each merged OVER the cross-file seed so a same-file
      # declaration wins for its own classes. Returned as a pair to keep {#merge_project_method_indexes} under the
      # method-size budget.
      def merge_member_layouts(default_scope, walked)
        [
          default_scope.data_member_layouts.merge(walked.fetch(:data_member_layouts)),
          default_scope.struct_member_layouts.merge(walked.fetch(:struct_member_layouts))
        ]
      end

      # Slice 7 phase 2. Builds the class-level ivar accumulator by walking every `Prism::ClassNode` /
      # `Prism::ModuleNode` body, descending into each nested `Prism::DefNode`, and typing every
      # `Prism::InstanceVariableWriteNode` rvalue under a scope that carries the appropriate `self_type` for that def
      # (singleton vs instance). The rvalue is typed with NO local bindings — the pre-pass lacks statement-level
      # threading — so `@x = 1` records `Constant[1]` but `@x = some_local + 1` records `Dynamic[Top]` (since
      # `some_local` is unbound at pre-pass time). Multiple writes to the same ivar union via `Type::Combinator.union`.
      def build_class_ivar_index(root, default_scope, declared_ivar_types: true)
        accumulator = {}
        mutated_ivars = {}
        read_before_write = {}
        init_writes = {}
        # WD3 — per class, then per method, the ivars the method definitely assigns non-nil on every completing path,
        # consulted by `dead_transient_nil_writes` so a ctor that reassigns `@x` indirectly through an unconditional
        # same-class method call (`mask!`) credits the overwrite. Built once per program here, memoised by class.
        method_assign_effects = build_method_assign_effects(root)
        # #2291 — an `@x = LIT` write reads the file's constant table, built on the first such write.
        accumulator[CONSTANT_IVAR_VALUES] = ConstantIvarValue.new(root, default_scope)
        walk_class_ivars(root, [], default_scope, accumulator, mutated_ivars,
                         read_before_write, init_writes, method_assign_effects)
        accumulator.delete(CONSTANT_IVAR_VALUES)
        reflective_opaque = accumulator.delete(REFLECTIVE_OPAQUE_CLASSES)
        singleton_writes = accumulator.delete(SINGLETON_IVAR_WRITES)
        exempt_class_body_writes!(init_writes, accumulator.delete(DEFINE_METHOD_WRITES) || {})
        merge_held_ivar_writes!(accumulator)
        record_aliased_ivar_mutations!(root, mutated_ivars)
        widen_mutated_ivar_entries!(accumulator, mutated_ivars)
        # #2170 — an ancestor's writes as this file's census types them, before its read-before-write `nil`.
        writes = instance_side_writes(accumulator, singleton_writes)
        contribute_read_before_write_nil!(accumulator, read_before_write, init_writes)
        make_reflective_classes_gradual!(accumulator, reflective_opaque)
        # #2079 / #2170 — another file's writes, and the chain's modules' and superclasses', join existing entries.
        IvarContributions.join!(accumulator, writes, default_scope)
        # An in-place mutation the file observes widens a joined value too (a same-file ancestor's String literal).
        widen_mutated_ivar_entries!(accumulator, mutated_ivars)
        # #1406 — an RBS `@x: T` or `attr_* x: T` declaration replaces the census's join of the writes.
        DeclaredIvarTypes.apply!(accumulator, default_scope) if declared_ivar_types
        accumulator.transform_values(&:freeze).freeze
      end

      # #2170 — a copy of the census entries for {IvarContributions} to join as an ancestor's own. #2931 — an ivar a
      # singleton-side `def` of the class writes is left out: its entry joins that write, which runs on the module or
      # class object and never on an includer's instance, so the join reads the file's instance-side census entries
      # for it, as another file's reader does.
      def instance_side_writes(accumulator, singleton_writes)
        accumulator.to_h do |class_name, entries|
          skipped = singleton_writes&.[](class_name)
          [class_name, skipped ? entries.except(*skipped) : entries.dup]
        end
      end

      # Folds the class-body writes {#collect_class_body_ivar_writes} held under {CLASS_BODY_WRITES} into the
      # `init_writes` exemption, except for an ivar a `define_method` block, or a `block_as_methods:` block bound to the
      # receiver's instance ({#method_body_block_call?}), of the class writes (#1768). Such an ivar had no census entry
      # before the block's writes were counted, so the exemption never applied to it; a class-body `@x = nil` writes
      # the class object's ivar and says nothing about whether an instance's `@x` is set, and exempting it would seed
      # `@x` non-nil from the block's write alone (`if @x` folding always-truthy on an instance whose `@x` is unset).
      # It keeps the read-before-write `nil` instead, which only widens.
      def exempt_class_body_writes!(init_writes, define_method_writes)
        (init_writes.delete(CLASS_BODY_WRITES) || {}).each do |class_name, ivars|
          kept = ivars - (define_method_writes[class_name] || EMPTY_GUARDED_IVARS)
          (init_writes[class_name] ||= Set.new).merge(kept)
        end
      end

      # B2.3 — finalize the read-before-write nil contribution. For each class, for each ivar where SOME method body
      # observed a read-before-write AND no `initialize` write exists for that ivar, contribute `Constant[nil]` to the
      # class-wide accumulator.
      #
      # The `initialize` filter is the soundness gate: Ruby semantics guarantee `initialize` runs first (via
      # `Class.new`), so a write there reaches every other method body's read. Read-before-write in a non-init method is
      # then NOT a nil-at-runtime case — it's just AST-order coincidence. Without this filter a normal `def initialize;
      # @x = ... end` / `def use; @x.foo end` class would have `@x` widened with nil, producing FPs at every `@x.foo`
      # call.
      def contribute_read_before_write_nil!(accumulator, read_before_write, init_writes)
        nil_t = Type::Combinator.constant_of(nil)
        read_before_write.each do |class_name, ivar_set|
          init_set = init_writes[class_name] || EMPTY_GUARDED_IVARS
          per_class = accumulator[class_name]
          next if per_class.nil?

          ivar_set.each do |ivar_name|
            # Soundness gates (in order): (1) `initialize` writes the ivar → it's set
            #     before any other method runs, so the
            #     read-before-write in a sibling method is
            #     NOT a runtime nil case.
            # (2) The accumulator has NO entry for the ivar
            #     → some write was deliberately skipped (the
            #     falsey-default `@x = nil unless @x` slice's
            #     no-seed behaviour). Adding nil here would
            #     defeat that skip and re-introduce the
            #     `Constant[nil]` FP the skip silenced.
            next if init_set.include?(ivar_name)
            next unless per_class.key?(ivar_name)

            existing = per_class[ivar_name]
            per_class[ivar_name] = Type::Combinator.union(existing, nil_t)
          end
        end
      end

      # An ivar a method RETURNS leaves the object, and every mutation of the returned reference mutates the ivar:
      # `(bucket_for(entry)[key] ||= {})[name] = row` fills whichever of `@self_rows` / `@path_rows` / `@result_rows`
      # `bucket_for` handed back. {record_ivar_mutator_call} cannot see it — the mutation's receiver is a `CallNode`,
      # not an `InstanceVariableReadNode` — so those ivars kept the empty `HashShape` their `initialize` gave them and
      # `@path_rows.empty?` folded to `Constant[true]` on a hash the class fills. Rigor's own
      # `lib/rigor/effects/plugin_facts.rb` is the worked site.
      #
      # Scope is deliberately narrow: the mutation receiver must be a SELF-call (an explicit receiver is a different
      # object), the callee must be an instance method of the same class, and only ivars in the callee's RETURN
      # position count — an ivar merely read in its body (`@rows[owner]` returns the value, not the hash) does not
      # escape. Over-recording here would widen a shape carrier that nothing mutates, which costs precision on every
      # reader in the class.
      #
      # Runs after the main walk so the returned-ivar summary is complete regardless of definition order, and gated on
      # a class actually having a returning method — the common class contributes nothing and pays one `defs` lookup.
      def record_aliased_ivar_mutations!(root, mutated_ivars)
        defs = collect_class_method_defs(root)
        returned = returned_ivars_by_method(defs)
        return if returned.empty?

        defs.each do |class_name, methods|
          per_class = returned[class_name]
          next if per_class.nil?

          methods.each_value do |def_node|
            gather_aliased_mutations(def_node.body, class_name, per_class, mutated_ivars)
          end
        end
      end

      # Per class, then per method, the ivars each method hands back, dropping the empty sets so the caller's
      # `next if per_class.nil?` skips a whole class in one lookup.
      def returned_ivars_by_method(defs)
        defs.each_with_object({}) do |(class_name, methods), acc|
          methods.each do |method_name, def_node|
            ivars = returned_ivars(def_node)
            (acc[class_name] ||= {})[method_name] = ivars unless ivars.empty?
          end
        end
      end

      # The ivars `def_node` can hand back: an explicit `return @x` anywhere in the body, and the body's tail
      # expression when it is (or resolves through branch nodes to) a bare ivar read. A tail that computes something
      # FROM an ivar (`@rows[k]`, `@rows.dup`) hands back a different object and is not an escape.
      def returned_ivars(def_node)
        body = def_node.body
        return EMPTY_IVAR_SET if body.nil?

        found = Set.new
        collect_explicit_return_ivars(body, found)
        tail_value_nodes(body).each { |node| found << node.name if node.is_a?(Prism::InstanceVariableReadNode) }
        found
      end

      def collect_explicit_return_ivars(node, found)
        return unless node.is_a?(Prism::Node)
        return if IVAR_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

        if node.is_a?(Prism::ReturnNode)
          args = node.arguments&.arguments
          found << args.first.name if args && args.size == 1 && args.first.is_a?(Prism::InstanceVariableReadNode)
        end

        node.rigor_each_child { |c| collect_explicit_return_ivars(c, found) }
      end

      # The expressions a body can evaluate to, resolving through the branch nodes whose value is a sub-expression.
      # Depth-capped for the same reason every other walk here is: a pathologically nested tail is not worth unbounded
      # recursion, and stopping early only under-collects (fewer escapes recorded, never more).
      def tail_value_nodes(node, depth = 0)
        return [] unless node.is_a?(Prism::Node)
        return [] if depth >= TAIL_VALUE_DEPTH_CAP

        children = tail_value_children(node)
        return [node] if children.nil?

        children.flat_map { |child| tail_value_nodes(child, depth + 1) }
      end

      # The children a node's own value comes from, or nil when the node IS the value. Split out from
      # {tail_value_nodes} so the recursion stays one line and this stays a lookup table.
      def tail_value_children(node)
        case node
        when Prism::StatementsNode then [node.body.last]
        when Prism::ParenthesesNode then [node.body]
        when Prism::BeginNode, Prism::ElseNode, Prism::WhenNode, Prism::InNode then [node.statements]
        when Prism::IfNode then [node.statements, node.subsequent]
        when Prism::UnlessNode then [node.statements, node.else_clause]
        when Prism::CaseNode then node.conditions + [node.else_clause]
        when Prism::OrNode, Prism::AndNode then [node.left, node.right]
        end
      end

      # Records every mutation in `node` whose receiver is a self-call to one of `per_class`'s returning methods.
      def gather_aliased_mutations(node, class_name, per_class, mutated_ivars)
        return unless node.is_a?(Prism::Node)

        mutator, receiver = mutation_target(node)
        escaped_ivars_for_receiver(receiver, per_class)&.each do |ivar_name|
          per_ivar = ((mutated_ivars[class_name] ||= {})[ivar_name] ||= Set.new)
          per_ivar << mutator
        end

        node.rigor_each_child { |c| gather_aliased_mutations(c, class_name, per_class, mutated_ivars) }
      end

      # The ivars a mutation receiver can be, when the receiver is a same-class self-call. Nil for every other shape.
      def escaped_ivars_for_receiver(receiver, per_class)
        return nil unless receiver.is_a?(Prism::CallNode) && receiver.receiver.nil?

        per_class[receiver.name]
      end

      # Walks the post-collected accumulator and widens any Tuple / HashShape / String-literal entry for an ivar that
      # observed a mutator call anywhere in the same class body. The mutation evidence comes from `gather_ivar_writes`
      # recording every `@ivar.<method>(...)` call whose method is in `MutationWidening::SHAPE_MUTATORS`.
      #
      # The widening uses `MutationWidening.widen_for_mutator` — the same primitive
      # `Inference::StatementEvaluator#eval_call` applies for per-method-body widening on a local / ivar receiver. The
      # class-level pass extends that primitive's reach so a `Tuple`-seeded ivar in `initialize` is observed as
      # `Nominal[Array]` at the entry of every OTHER method body in the class — closing the cross-method gap
      # (Redmine 6.1.2 `Redmine::Views::Builders::Structure` is the canonical worked site).
      #
      # Always-safe: the widening can only LOSE precision; the underlying nominal (`Array` / `Hash`) and the element
      # union are preserved.
      def widen_mutated_ivar_entries!(accumulator, mutated_ivars)
        accumulator.each do |class_name, ivars|
          observed = mutated_ivars[class_name]
          next if observed.nil? || observed.empty?

          ivars.each do |ivar_name, type|
            methods = observed[ivar_name]
            next if methods.nil? || methods.empty?

            ivars[ivar_name] = widen_type_for_observed_mutators(type, methods)
          end
        end
      end

      # Walks a class-ivar accumulator entry (which may be a `Union` of multiple write rvalues) and widens any `Tuple`,
      # `HashShape` or String-valued `Constant` member whose corresponding mutator family was observed against the ivar
      # somewhere in the class.
      # Class-level widening is more aggressive than the per-method-body `MutationWidening` primitive: it widens both
      # the SHAPE carrier (Tuple → Array, HashShape → Hash) AND the element types to `Dynamic[Top]`. The justification —
      # once any method mutates the ivar, its post-mutation contents are statically unknown across method boundaries, so
      # preserving the seed-write's element precision would be an unsound over-claim (e.g. `@struct = [{}]; somewhere:
      # @struct << []` makes the next read's element no longer `Constant[{}]`).
      def widen_type_for_observed_mutators(type, observed_methods)
        members = type.is_a?(Type::Union) ? type.members : [type]
        widened = members.map { |m| widen_member_for_observed_mutators(m, observed_methods) }
        Type::Combinator.union(*widened)
      end

      def widen_member_for_observed_mutators(member, observed_methods)
        case member
        when Type::Tuple
          return member unless observed_methods.any? { |m| MutationWidening::ARRAY_MUTATORS.include?(m) }

          Type::Combinator.nominal_of("Array", type_args: [Type::Combinator.untyped])
        when Type::HashShape
          if observed_methods.any? { |m| MutationWidening::HASH_MUTATORS.include?(m) }
            return Type::Combinator.nominal_of("Hash",
                                               type_args: [Type::Combinator.untyped, Type::Combinator.untyped])
          end

          widen_member_for_lookup_mutators(member, observed_methods)
        when Type::Constant then widen_constant_for_observed_mutators(member, observed_methods)
        else
          member
        end
      end

      # `@s = +"ab"` in one method and `@s << "c"` in another: without this arm the seed stayed pinned at every other
      # method's entry, and `@s == "ab"` folded always-truthy on a receiver that holds `"abc"`. A constant-folded Set
      # (`@s = Set["a"]`, then `@s.clear; @s << 1` elsewhere — issue #2294) takes the untyped floor the Tuple arm takes.
      def widen_constant_for_observed_mutators(member, observed_methods)
        if SetMutation.constant?(member)
          return member unless observed_methods.any? { |m| SetMutation::MUTATORS.include?(m) }

          return Type::Combinator.nominal_of("Set", type_args: [Type::Combinator.untyped])
        end
        return member unless StringMutation.constant?(member) &&
                             observed_methods.any? { |m| StringMutation::MUTATORS.include?(m) }

        Type::Combinator.nominal_of("String")
      end

      # A `HashShape` ivar seed some method gave a default, a default proc or identity keys, and no method stored
      # into, removed from or rewrote: its pairs are the seed's own, so it takes the per-method {HashLookupMutation}
      # widening rather than the untyped floor above — a present key keeps its value across methods, a missing one
      # stops reading `nil`.
      def widen_member_for_lookup_mutators(member, observed_methods)
        observed_methods.reduce(member) do |acc, method_name|
          next acc unless acc.is_a?(Type::HashShape)

          HashLookupMutation.widen_shape(acc, method_name) || acc
        end
      end

      # Issue #681 — the scope a census pre-pass types an rvalue under. The census walks never enter a body
      # through `StatementEvaluator`, so nothing stamped the declaration's `Module.nesting` on the scope they
      # build and `Reflection.lexical_nesting_chain` fell back to peeling `self_type`'s qualified name. That
      # peel cannot tell a compact `class Admin::Census` (nesting `[Admin::Census]`, so a bare `Post` names
      # `::Post`) from the nested spelling (nesting `[Admin::Census, Admin]`, where it names `Admin::Post`),
      # so `@post = Post.new` and `DEFAULT = Post` were recorded under the wrong class and every later read
      # answered it. The prefix these walks already thread IS the chain — `["Admin::Census"]` for the compact
      # form, `["Admin", "Census"]` for the nested one — so the fact was in hand and only the stamp was
      # missing.
      def census_body_scope(default_scope, qualified_prefix, self_type)
        default_scope.with_self_type(self_type)
                     .with_lexical_nesting(census_nesting(default_scope, qualified_prefix))
      end

      # The chain a census walk answers `Module.nesting` with: the one
      # {DeclarationWalk::Rules.scope_entering_declaration} threaded on the scope when a header was entered, and only
      # failing that the prefix-derived approximation below.
      def census_nesting(scope, qualified_prefix)
        scope&.lexical_nesting || DeclarationWalk::Rules.lexical_nesting_for_prefix(qualified_prefix)
      end

      # `def_owner` names the class a `def` leaf belongs to when `self` is rebound — a
      # meta-new block's class — while `qualified_prefix` stays the lexical cref the
      # whole time (`Module.nesting` never rebinds in a block). `[]` marks a self no
      # name covers (anonymous factory, `class <<` body), where def-keyed facts decline.
      def walk_class_ivars(node, qualified_prefix, default_scope, accumulator, mutated_ivars, # rubocop:disable Metrics/ParameterLists
                           read_before_write = nil, init_writes = nil, method_assign_effects = nil,
                           def_owner: nil, singleton_cref: false, defs_singleton: false)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          walk_ivars_declaration(node, qualified_prefix, default_scope, accumulator,
                                 mutated_ivars, read_before_write, init_writes,
                                 method_assign_effects, def_owner, singleton_cref)
          return
        when Prism::SingletonClassNode
          return walk_singleton_class_ivars(node, qualified_prefix, default_scope, accumulator,
                                            mutated_ivars, read_before_write, init_writes,
                                            method_assign_effects, def_owner, singleton_cref)
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode,
             Prism::ConstantOrWriteNode, Prism::ConstantPathOrWriteNode,
             Prism::DefNode, Prism::CallNode
          return if walk_ivars_leaf?(node, qualified_prefix, default_scope, accumulator,
                                     mutated_ivars, read_before_write, init_writes,
                                     method_assign_effects, def_owner, singleton_cref,
                                     defs_singleton: defs_singleton)
        end

        node.rigor_each_child do |child|
          walk_class_ivars(child, qualified_prefix, default_scope, accumulator,
                           mutated_ivars, read_before_write, init_writes, method_assign_effects,
                           def_owner: def_owner, singleton_cref: singleton_cref,
                           defs_singleton: defs_singleton)
        end
      end

      # The leaf arms of {#walk_class_ivars}: a `def` collects and stops, a recognised
      # meta-new write or anonymous factory call consumes its own block, and an ordinary
      # call seeds the ADR-38 initializer writes and an `attr_writer` family macro its ivar
      # writes before the ordinary child descent runs.
      # Returns true when the node — and where relevant its block — was consumed.
      def walk_ivars_leaf?(node, qualified_prefix, default_scope, accumulator, mutated_ivars, # rubocop:disable Metrics/ParameterLists
                           read_before_write, init_writes, method_assign_effects,
                           def_owner, singleton_cref, defs_singleton: false)
        case node
        when Prism::DefNode
          collect_def_ivar_writes(node, def_owner || qualified_prefix, default_scope, accumulator,
                                  mutated_ivars, read_before_write, init_writes,
                                  method_assign_effects, singleton_self: defs_singleton)
          true
        when Prism::CallNode
          return true if walk_ivars_meta_call?(node, qualified_prefix, default_scope, accumulator,
                                               mutated_ivars, read_before_write, init_writes,
                                               method_assign_effects, def_owner, singleton_cref,
                                               defs_singleton: defs_singleton)
          return true if walk_ivars_eval_call?(node, qualified_prefix, default_scope, accumulator,
                                               mutated_ivars, read_before_write, init_writes,
                                               method_assign_effects, def_owner, singleton_cref,
                                               defs_singleton: defs_singleton)

          owner = def_owner || qualified_prefix
          collect_initializer_block_ivars(node, owner, default_scope, accumulator, mutated_ivars, init_writes)
          record_attr_writer_ivars(node, owner, accumulator) if ATTR_WRITER_MACROS.include?(attr_macro(node))
          collect_define_method_block_ivars(node, owner, default_scope, accumulator, mutated_ivars)
          collect_receiver_writer_ivars(node, owner, qualified_prefix, default_scope, accumulator, mutated_ivars)
          false
        else
          walk_ivars_meta_new?(node, qualified_prefix, default_scope, accumulator,
                               mutated_ivars, read_before_write, init_writes,
                               method_assign_effects, def_owner, singleton_cref)
        end
      end

      # The `K = Class.new { … }` arm of {#walk_class_ivars}: the factory call's receiver and
      # arguments keep the enclosing context; the block's `def`-keyed facts belong to the
      # class the write names while its declarations stay lexical.
      def walk_ivars_meta_new?(node, qualified_prefix, default_scope, accumulator, mutated_ivars, # rubocop:disable Metrics/ParameterLists
                               read_before_write, init_writes, method_assign_effects,
                               def_owner, singleton_cref, defs_singleton: false)
        split = DeclarationWalk::Rules.meta_new_block_split(node, qualified_prefix, def_owner, singleton_cref)
        return false unless split

        enclosing, body, body_self = split
        enclosing.each do |part|
          walk_class_ivars(part, qualified_prefix, default_scope, accumulator,
                           mutated_ivars, read_before_write, init_writes, method_assign_effects,
                           def_owner: def_owner, singleton_cref: singleton_cref,
                           defs_singleton: defs_singleton)
        end
        if body
          walk_class_ivars(body, qualified_prefix, default_scope, accumulator,
                           mutated_ivars, read_before_write, init_writes, method_assign_effects,
                           def_owner: body_self, singleton_cref: singleton_cref)
        end
        true
      end

      # The bare `Class.new { … }`-family call arm of {#walk_class_ivars}: the block's class
      # has no name, so its `def`-keyed ivar facts walk ownerless rather than under the
      # enclosing class. Returns whether an anonymous factory block was walked.
      def walk_ivars_meta_call?(node, qualified_prefix, default_scope, accumulator, mutated_ivars, # rubocop:disable Metrics/ParameterLists
                                read_before_write, init_writes, method_assign_effects,
                                def_owner, singleton_cref, defs_singleton: false)
        return false unless DeclarationWalk::Rules.meta_new_constant_rvalue?(node) && node.block.is_a?(Prism::BlockNode)

        [node.receiver, *node.arguments&.arguments.to_a].compact.each do |part|
          walk_class_ivars(part, qualified_prefix, default_scope, accumulator,
                           mutated_ivars, read_before_write, init_writes, method_assign_effects,
                           def_owner: def_owner, singleton_cref: singleton_cref,
                           defs_singleton: defs_singleton)
        end
        if (body = node.block.body)
          walk_class_ivars(body, qualified_prefix, default_scope, accumulator,
                           mutated_ivars, read_before_write, init_writes, method_assign_effects,
                           def_owner: [], singleton_cref: singleton_cref)
        end
        true
      end

      # The eval-family arm of {#walk_class_ivars}: `def`-keyed ivar facts belong to the
      # receiver's class for `class_eval`, and to the receiver's singleton self for
      # `instance_eval` (`defs_singleton` — `X.instance_eval { def m; @x = 1 }` writes
      # `X`'s own `@x`, typed `singleton(X)` the way `def self.m` is). `self::`
      # declarations anchor on the receiver the same way.
      def walk_ivars_eval_call?(node, qualified_prefix, default_scope, accumulator, mutated_ivars, # rubocop:disable Metrics/ParameterLists
                                read_before_write, init_writes, method_assign_effects,
                                def_owner, singleton_cref, defs_singleton: false)
        split = DeclarationWalk::Rules.eval_block_split(node, qualified_prefix, def_owner, singleton_cref)
        return false unless split

        enclosing, body, body_self = split
        enclosing.each do |part|
          walk_class_ivars(part, qualified_prefix, default_scope, accumulator,
                           mutated_ivars, read_before_write, init_writes, method_assign_effects,
                           def_owner: def_owner, singleton_cref: singleton_cref,
                           defs_singleton: defs_singleton)
        end
        if body
          walk_class_ivars(body, qualified_prefix, default_scope, accumulator,
                           mutated_ivars, read_before_write, init_writes, method_assign_effects,
                           def_owner: body_self, singleton_cref: singleton_cref,
                           defs_singleton: INSTANCE_EVAL_CALLS.include?(node.name))
        end
        true
      end

      # The `class <<` arm of {#walk_class_ivars}: the expression evaluates in the enclosing
      # cref — `class << (class D; self; end)` still names `C::D` — while the body's cref is
      # the unnameable singleton class; the marker lifts only at a nameable header.
      def walk_singleton_class_ivars(node, qualified_prefix, default_scope, accumulator, # rubocop:disable Metrics/ParameterLists
                                     mutated_ivars, read_before_write, init_writes,
                                     method_assign_effects, def_owner, singleton_cref)
        walk_class_ivars(node.expression, qualified_prefix, default_scope, accumulator,
                         mutated_ivars, read_before_write, init_writes, method_assign_effects,
                         def_owner: def_owner, singleton_cref: singleton_cref)
        return unless node.body

        # A `def` below `class <<` is a singleton method — its `@x` writes are the class
        # object's own ivars, not instance-ivar facts, so the body walks ownerless.
        walk_class_ivars(node.body, qualified_prefix, default_scope, accumulator,
                         mutated_ivars, read_before_write, init_writes, method_assign_effects,
                         def_owner: [], singleton_cref: true)
      end

      # The declaration arm of {#walk_class_ivars}. Class-body level `@x = nil` writes don't
      # initialise instance ivars at runtime (the class's own singleton ivars and the instance's
      # ivars are separate stores), but they signal "the author KNOWS @x could be nil" and extend
      # the B2.3 soundness gate: an ivar with a class-body write is exempted from the
      # read-before-write nil contribution because the seed already reflects the author's
      # acknowledged nullability via the def-body writes' union. Without this exemption, code that
      # explicitly `@x = nil`s at class-body level then writes `@x = SomeClass.new` inside an
      # instance method gains an unjustified nil widening at every read. Under an unnameable cref
      # a bare/`self::` header opens `#<singleton>::Name` — the write census is skipped and the body
      # walks ownerless; nameable headers re-anchor at a real cref.
      def walk_ivars_declaration(node, qualified_prefix, default_scope, accumulator, mutated_ivars, # rubocop:disable Metrics/ParameterLists
                                 read_before_write, init_writes, method_assign_effects, def_owner, singleton_cref)
        self_decl = DeclarationWalk::Rules.self_anchored_decl_prefix(node.constant_path, def_owner)
        child_prefix = self_decl ||
                       Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
        return unless child_prefix && node.body

        child_cref = DeclarationWalk::Rules.unnameable_decl?(node, self_decl, singleton_cref)
        collect_class_body_ivar_writes(node.body, child_prefix.join("::"), init_writes) if init_writes && !child_cref
        walk_class_ivars(node.body, child_cref ? [] : child_prefix,
                         DeclarationWalk::Rules.scope_entering_declaration(default_scope, node.constant_path),
                         accumulator, mutated_ivars, read_before_write, init_writes, method_assign_effects,
                         singleton_cref: child_cref)
      end

      def collect_def_ivar_writes(def_node, qualified_prefix, default_scope, accumulator, mutated_ivars, # rubocop:disable Metrics/ParameterLists
                                  read_before_write = nil, init_writes = nil, method_assign_effects = nil,
                                  singleton_self: false)
        return if def_node.body.nil? || qualified_prefix.empty?
        # Issue #3155 — `def String.q` writes the ivars of another object.
        return if foreign_def?(def_node, qualified_prefix, false)

        class_name = qualified_prefix.join("::")
        singleton = singleton_self || def_node.receiver.is_a?(Prism::SelfNode) ||
                    def_receiver_targets_lexical_self?(def_node.receiver, qualified_prefix)
        self_type =
          if singleton
            Type::Combinator.singleton_of(class_name)
          else
            Type::Combinator.nominal_of(class_name)
          end
        body_scope = census_body_scope(default_scope, qualified_prefix, self_type)

        # C2 — transient `@x = nil` dead-write elimination. When a method body opens with an unconditional `@x = nil`
        # (defensive init) and then *definitely* reassigns `@x` to a non-nil value on every completing path (a later
        # unconditional statement-level write, OR an `if/else` whose both branches write `@x`), the opening nil is dead
        # — it can never be observed at method exit. Recording it anyway folds a spurious `nil` constituent into the
        # flow-insensitive class-ivar union, which then poisons reads in OTHER methods (e.g. ipaddr `IN4MASK ^
        # @mask_addr` rejects the resulting `Integer | nil`). The set holds the `object_id`s of the transient write
        # nodes to skip; soundness is post-domination at the top statement level, so dropping the nil never hides a real
        # runtime-nil read.
        dead_writes = dead_transient_nil_writes(def_node.body, class_name, method_assign_effects)
        # #1154 — an `@x = x` from a declared parameter records the parameter's declared type.
        declared = DeclaredParamWrites::EMPTY
        declared = DeclaredParamWrites.collect(def_node, class_name, body_scope) unless singleton
        gather_ivar_writes(def_node.body, body_scope, class_name, accumulator,
                           EMPTY_GUARDED_IVARS, mutated_ivars, dead_writes, declared)
        if singleton
          singleton_written = (accumulator[SINGLETON_IVAR_WRITES] ||= {})[class_name] ||= Set.new
          define_method_written_ivars(def_node.body, singleton_written)
        end

        # B2.3 — collect per-method evidence for the read-before-write nil contribution. The accumulator-level decision
        # ("is this ivar truly read-before-write across the class lifetime?") is finalised at
        # `contribute_read_before_write_nil!` after the whole class body has been walked, using `init_writes` as the
        # soundness gate (an ivar written in `initialize` is initialised before any other method body runs).
        collect_read_before_write_evidence(def_node, class_name, read_before_write, init_writes, default_scope)
      end

      # ADR-38 block-form: collects ivar writes from a CallNode's block body (e.g. RSpec `before { @x = … }` / `let(:x)
      # { … }`) and folds them into `init_writes`, suppressing the read-before-write nil contribution the same way a
      # def-form initializer does. The block body is always treated as an initializer (the caller has already verified
      # the method name is declared as a block_method initializer), so there is no read-before-write evidence collection
      # step here.
      def collect_block_ivar_writes(block_node, qualified_prefix, default_scope, accumulator,
                                    mutated_ivars, init_writes)
        return if block_node.body.nil? || qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        self_type = Type::Combinator.nominal_of(class_name)
        body_scope = census_body_scope(default_scope, qualified_prefix, self_type)

        gather_ivar_writes(block_node.body, body_scope, class_name, accumulator,
                           EMPTY_GUARDED_IVARS, mutated_ivars)

        seen_writes = Set.new
        read_first = Set.new
        detect_read_before_write(block_node.body, seen_writes, read_first, class_name)
        init_set = (init_writes[class_name] ||= Set.new)
        seen_writes.each { |name| init_set << name }
      end

      # The ADR-38 initializer-call arm of {#walk_class_ivars}: a block-carrying call the
      # owner class declares as a block-form initializer contributes its `@x` writes to
      # `init_writes`. No-op everywhere else.
      def collect_initializer_block_ivars(node, owner, default_scope, accumulator,
                                          mutated_ivars, init_writes)
        return unless init_writes && !owner.empty? &&
                      node.block.is_a?(Prism::BlockNode) &&
                      block_initializer?(owner.join("::"), node.name, default_scope)

        collect_block_ivar_writes(node.block, owner, default_scope,
                                  accumulator, mutated_ivars, init_writes)
      end

      # The `attr_writer` family arm of {#walk_class_ivars} (#541). A writer declaration is the class's own
      # statement that `@x` takes values from outside, so it contributes what the hand-written untyped setter
      # `def x=(v) = @x = v` does: `Dynamic[top]`. Without it `@x = nil` in `initialize` was the only write
      # the seed saw, and `if @x` folded always-falsey on a field the class declares assignable. A setter
      # call site (`obj.x = v`) stays out, as ADR-58 WD2 settles; the declaration is class-level evidence
      # in the file the walk reads. `owner` is empty where no class owns an instance-side ivar (a
      # `class << self` body), and the macro contributes nothing there.
      def record_attr_writer_ivars(node, owner, accumulator)
        return if owner.empty?

        class_name = owner.join("::")
        each_attr_macro_name(node) do |base|
          accumulate_ivar_type(accumulator, class_name, :"@#{base}", Type::Combinator.untyped)
        end
      end

      # The `define_method` arm of {#walk_class_ivars} (#1768). `define_method(:m) { … }` on the implicit
      # or `self` receiver installs its block as an instance method of `owner`, and Ruby runs the body on
      # the instance, so its `@x = …` writes are the instance's ivars exactly as a `def m` body's are —
      # `DefineMethodBlockSelf` narrows the block's `self` the same way when it is evaluated. Without this
      # arm an ivar `initialize` sets to `nil` and a `define_method` block sets to a String read as `nil`
      # in every sibling `def`. The block is typed under the instance `self`, as a def body is. Only the
      # literal-block form counts: a `define_method(:m, callable)` or `&callable` argument is not walked.
      # `owner` is empty in a `class << self` body (the call defines a class method there) and in an
      # anonymous factory body, and the block contributes nothing there. A `define_method` inside a `def`
      # body is already reached by that body's walk ({#gather_ivar_writes} enters blocks).
      #
      # An ADR-16 `block_as_methods:` call whose entry binds the receiver's instance (`get "/" do … end` in a
      # `Sinatra::Base` subclass under rigor-sinatra) takes the same arm: the plugin declares that its block runs as an
      # instance method of the receiver class, and `MacroBlockSelfType` narrows the block's `self` to that instance.
      def collect_define_method_block_ivars(node, owner, default_scope, accumulator, mutated_ivars)
        return if owner.empty?

        class_name = owner.join("::")
        return unless method_body_block_call?(node, class_name, default_scope)

        block = node.block
        return unless block.body

        body_scope = census_body_scope(default_scope, owner, Type::Combinator.nominal_of(class_name))
        gather_ivar_writes(block.body, body_scope, class_name, accumulator, EMPTY_GUARDED_IVARS, mutated_ivars)
        written = (accumulator[DEFINE_METHOD_WRITES] ||= {})[class_name] ||= Set.new
        define_method_written_ivars(block.body, written)
      end

      # Issue #2488 — the explicit-receiver arm of {#walk_class_ivars}: `E.attr_writer :w` (or through `send`) records
      # `@w` as `Dynamic[top]` on `E`, as an `attr_writer` in `E`'s body does ({#record_attr_writer_ivars}), and an
      # `E.define_method(:m) { … }` block is walked as an instance body of `E`, as one in `E`'s body is
      # ({#collect_define_method_block_ivars}). `E` resolves as a `class_eval` receiver does; an unnameable one
      # contributes nothing. A call inside a `def` is that body's to walk.
      def collect_receiver_writer_ivars(node, owner, qualified_prefix, default_scope, accumulator, mutated_ivars)
        return if ReceiverWriterCall.receiver(node).nil?

        target = DeclarationWalk::Rules.eval_receiver_prefix(node, owner, qualified_prefix,
                                                             unnameable_self: owner.empty?)
        return if target.nil? || target.empty?

        class_name = target.join("::")
        ReceiverWriterCall.writer_ivars(node).each do |ivar|
          accumulate_ivar_type(accumulator, class_name, ivar, Type::Combinator.untyped)
        end
        body = ReceiverWriterCall.define_method_block(node)&.body
        return if body.nil?

        body_scope = census_body_scope(default_scope, target, Type::Combinator.nominal_of(class_name))
        gather_ivar_writes(body, body_scope, class_name, accumulator, EMPTY_GUARDED_IVARS, mutated_ivars)
        define_method_written_ivars(body, (accumulator[DEFINE_METHOD_WRITES] ||= {})[class_name] ||= Set.new)
      end

      # The ivars a `define_method` block body writes, in any write form, outside a nested `def` / `class` / `module`.
      def define_method_written_ivars(node, acc)
        return unless node.is_a?(Prism::Node)
        return if IVAR_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

        case node
        when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode,
             Prism::InstanceVariableAndWriteNode, Prism::InstanceVariableOperatorWriteNode,
             Prism::InstanceVariableTargetNode
          acc << node.name
        end
        reflective = ReflectiveIvarWrite.literal_name(node)
        acc << reflective if reflective
        node.rigor_each_child { |child| define_method_written_ivars(child, acc) }
      end

      # ADR-38 block-form gate: true when a loaded plugin declares `method_name` a block-form initializer for
      # `class_name` (or an ancestor). Mirrors `additional_initializer?` but queries `covers_block_method?` instead of
      # `covers_method?`.
      def block_initializer?(class_name, method_name, default_scope)
        return false if class_name.nil? || default_scope.nil?

        environment = default_scope.environment
        registry = environment&.plugin_registry
        return false if registry.nil?
        return false if registry.respond_to?(:empty?) && registry.empty?
        return false unless registry.respond_to?(:additional_initializers)

        registry.additional_initializers.any? do |entry|
          entry.covers_block_method?(method_name) &&
            class_matches_constraint?(class_name, entry.receiver_constraint, environment)
        end
      rescue StandardError
        false
      end

      # Walks the method body in AST (== execution) order tracking ivar names whose first reference is a read. The set
      # is unioned into the class-wide `read_before_write` accumulator. For `initialize` def bodies, every write target
      # is unioned into `init_writes` instead — used by the finalisation step to suppress nil contribution for ivars the
      # constructor guarantees are initialised.
      def collect_read_before_write_evidence(def_node, class_name, read_before_write, init_writes, default_scope = nil)
        return if read_before_write.nil? || init_writes.nil?

        seen_writes = Set.new
        read_first = Set.new
        detect_read_before_write(def_node.body, seen_writes, read_first, class_name)

        # ADR-38 — `initialize` is the built-in initializer gate; a plugin may declare additional `def`-form initializer
        # methods (minitest `setup`, Rails `after_initialize`, DI setters) on a constrained class. Both fold their
        # writes into `init_writes`, suppressing the read-before-write nil contribution for sibling readers.
        if def_node.name == :initialize ||
           additional_initializer?(class_name, def_node.name, default_scope)
          init_set = (init_writes[class_name] ||= Set.new)
          seen_writes.each { |name| init_set << name }
          return
        end

        return if read_first.empty?

        rbw_set = (read_before_write[class_name] ||= Set.new)
        read_first.each { |name| rbw_set << name }
      end

      # ADR-38 — true when a loaded plugin declares `method_name` an additional initializer for `class_name` (or an
      # ancestor). Reads the plugin registry off the pre-pass scope's environment; the receiver-constraint match reuses
      # `Environment#class_ordering` (the same mechanism ADR-16 Tier A's `MacroBlockSelfType` uses). The whole lookup is
      # wrapped so any resolution failure degrades to "no match" — since the gate only ever SUPPRESSES a nil
      # contribution, a missed match is false-positive-safe (it merely leaves the existing nil widening in place).
      def additional_initializer?(class_name, method_name, default_scope)
        return false if class_name.nil? || default_scope.nil?

        environment = default_scope.environment
        registry = environment&.plugin_registry
        return false if registry.nil?
        return false if registry.respond_to?(:empty?) && registry.empty?
        return false unless registry.respond_to?(:additional_initializers)

        registry.additional_initializers.any? do |entry|
          entry.covers_method?(method_name) &&
            class_matches_constraint?(class_name, entry.receiver_constraint, environment)
        end
      rescue StandardError
        false
      end

      def class_matches_constraint?(class_name, constraint, environment)
        return true if class_name == constraint
        return false if environment.nil?

        ordering = environment.class_ordering(class_name, constraint)
        %i[equal subclass].include?(ordering)
      rescue StandardError
        false
      end

      IVAR_WRITE_NODES = [
        Prism::InstanceVariableWriteNode,
        Prism::InstanceVariableOrWriteNode,
        Prism::InstanceVariableAndWriteNode,
        Prism::InstanceVariableOperatorWriteNode
      ].freeze
      private_constant :IVAR_WRITE_NODES

      # Walks class-body level statements (i.e. NOT inside any nested DefNode / ClassNode / ModuleNode) and records
      # every `@x = …` write target as a class-body init. Consumed by `contribute_read_before_write_nil!` to exempt
      # ivars the author already knows might be nil (the `@x = nil` at class-body level is the canonical nullability
      # acknowledgement; the instance @x is technically a separate store, but the pragmatic intent is unambiguous).
      #
      # A literal `define_method` block is a method body, not class-body code (#1768): its writes reach the census as
      # a `def` body's do, so they must not exempt the ivar from the read-before-write `nil` either. Only its receiver
      # and arguments are walked.
      def collect_class_body_ivar_writes(node, class_name, init_writes)
        return unless node.is_a?(Prism::Node)
        return if IVAR_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

        return collect_define_method_argument_writes(node, class_name, init_writes) if define_method_block_call?(node)

        if node.is_a?(Prism::InstanceVariableWriteNode) ||
           node.is_a?(Prism::InstanceVariableOrWriteNode) ||
           node.is_a?(Prism::InstanceVariableAndWriteNode) ||
           node.is_a?(Prism::InstanceVariableOperatorWriteNode)
          ((init_writes[CLASS_BODY_WRITES] ||= {})[class_name] ||= Set.new) << node.name
        end

        node.rigor_each_child do |child|
          collect_class_body_ivar_writes(child, class_name, init_writes)
        end
      end

      # The arguments of a `define_method` block call, walked by {#collect_class_body_ivar_writes} in place of the
      # call's children so the block body stays out of the class-body init writes.
      def collect_define_method_argument_writes(node, class_name, init_writes)
        node.arguments&.arguments&.each { |arg| collect_class_body_ivar_writes(arg, class_name, init_writes) }
      end

      # A `define_method` call with a literal block on the implicit or `self` receiver: the block is an instance
      # method body of the class the walk is in (#1768).
      def define_method_block_call?(node)
        DefineMethodBlockSelf.define_method_on_lexical_self?(node) && node.block.is_a?(Prism::BlockNode)
      end

      # A call with a literal block on the implicit or `self` receiver whose block is an instance method body of
      # `class_name`, the class the walk is in (#1768): `define_method`, or a call an ADR-16 `block_as_methods:` entry
      # declares runs its block as an instance method of the receiver class ({MacroBlockSelfType}). The entry is
      # matched on `Singleton[class_name]`, the receiver such a call has in the class body, through the same
      # receiver-ancestry match the evaluator narrows the block's `self` with, so the census counts exactly the blocks
      # whose `self` is narrowed to the instance.
      #
      # The class-body walk ({#collect_class_body_ivar_writes}) still records a `block_as_methods:` block's writes as
      # class-body writes, and {#exempt_class_body_writes!} takes back every ivar such a block writes.
      def method_body_block_call?(node, class_name, scope)
        return true if define_method_block_call?(node)
        return false unless node.block.is_a?(Prism::BlockNode)
        return false unless scope && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))

        MacroBlockSelfType.runs_as_receiver_instance_method?(
          scope: scope, call_node: node, receiver_type: Type::Combinator.singleton_of(class_name)
        )
      end

      def detect_read_before_write(node, seen_writes, read_first, class_name = nil)
        return unless node.is_a?(Prism::Node)
        return if IVAR_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

        read_first << node.name if node.is_a?(Prism::InstanceVariableReadNode) && !seen_writes.include?(node.name)

        # N1 — parallel / multiple assignment (`@m, @n = [], []`). The ivar targets are `InstanceVariableTargetNode`s,
        # not `InstanceVariableWriteNode`s, so the generic descent below never records them as writes. Left unhandled,
        # an ivar written only via massign in `initialize` stays absent from `init_writes`, and
        # `contribute_read_before_write_nil!` then unions a spurious `nil` into its class-ivar seed — masking a
        # genuinely-typed `@m` (e.g. `Tuple[]`) as `T | nil` at every sibling read. The RHS runs before any
        # target is committed, so descend into `value` FIRST (an ivar read there is read-before-write), then mark every
        # ivar target as written.
        if node.is_a?(Prism::MultiWriteNode)
          detect_read_before_write(node.value, seen_writes, read_first, class_name) if node.value
          detect_multi_write_target_writes(node, seen_writes, read_first, class_name)
          return
        end

        # Descend BEFORE recording a write — `@x = @x + 1`'s RHS is an `InstanceVariableReadNode` that runs before the
        # write is committed; the read is therefore read-before-write semantically. `each_child` yields the value
        # child before the lvalue target (`compact_child_nodes` field order), matching this order.
        # #2490 — what a block whose `self` is another object reads or writes is that object's.
        each_census_child(node, class_name) do |c|
          detect_read_before_write(c, seen_writes, read_first, class_name)
        end

        seen_writes << node.name if IVAR_WRITE_NODES.any? { |klass| node.is_a?(klass) }
        # #1931 — a literal `instance_variable_set` is a write too; its value argument, read above, runs first.
        reflective = ReflectiveIvarWrite.literal_name(node)
        seen_writes << reflective if reflective
      end

      # Records each ivar target of a `MultiWriteNode` / nested `MultiTargetNode` into `seen_writes`, and descends into
      # any non-ivar target (a `CallTargetNode` / `IndexTargetNode` receiver such as `@obj.x, @y = …`) so an ivar read
      # inside a target receiver still counts as read-before-write.
      def detect_multi_write_target_writes(node, seen_writes, read_first, class_name = nil)
        targets = (node.lefts || []) + [node.rest].compact + (node.rights || [])
        targets.each do |target|
          case target
          when Prism::InstanceVariableTargetNode
            seen_writes << target.name
          when Prism::MultiTargetNode
            detect_multi_write_target_writes(target, seen_writes, read_first, class_name)
          when Prism::SplatNode
            inner = target.expression
            seen_writes << inner.name if inner.is_a?(Prism::InstanceVariableTargetNode)
          else
            detect_read_before_write(target, seen_writes, read_first, class_name)
          end
        end
      end

      IVAR_BARRIER_NODES = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode].freeze
      private_constant :IVAR_BARRIER_NODES

      # Issue #2490 — yields the children of `node` a census walk for `class_name` descends into: all of them, or only
      # those {CensusForeignBlock.census_children} keeps when `node` runs code whose `self` is another object. A nil
      # `class_name` keeps them all. A reentered `def` (#2941) is yielded as itself, so a walk that stops at a `def`
      # skips it; `def_bodies:` yields its body instead, for a walk that counts its writes. `reentry: false` (a
      # singleton-side `def`) keeps none of the reentered code.
      def each_census_child(node, class_name, def_bodies: false, reentry: true, &)
        outside = class_name && CensusForeignBlock.census_children(node, class_name, reentry: reentry)
        return node.rigor_each_child(&) unless outside

        outside.each do |child|
          child = child.body if def_bodies && child.is_a?(Prism::DefNode)
          yield child if child
        end
      end

      EMPTY_GUARDED_IVARS = Set.new.freeze

      # Shared empty result for a def that returns no ivar — the overwhelmingly common case.
      EMPTY_IVAR_SET = Set.new.freeze
      private_constant :EMPTY_IVAR_SET

      # Branch nesting a tail expression is followed through. Stopping early only UNDER-collects escapes.
      TAIL_VALUE_DEPTH_CAP = 8
      private_constant :TAIL_VALUE_DEPTH_CAP
      private_constant :EMPTY_GUARDED_IVARS

      def gather_ivar_writes(node, scope, class_name, accumulator, guarded_ivars = EMPTY_GUARDED_IVARS, # rubocop:disable Metrics/ParameterLists
                             mutated_ivars = nil, dead_writes = nil, declared = DeclaredParamWrites::EMPTY)
        return unless node.is_a?(Prism::Node)

        if node.is_a?(Prism::InstanceVariableWriteNode)
          unless dead_writes&.include?(node.object_id)
            record_ivar_write(node, scope, class_name, accumulator,
                              guarded: guarded_ivars.include?(node.name), declared: declared[node])
          end
        else
          record_compound_ivar_write(node, scope, class_name, accumulator)
          record_reflective_ivar_write(node, scope, class_name, accumulator)
        end

        # N1 — parallel / multiple assignment (`old, @cb = @cb, block`, `@i, @o, @e, @thr = Open3.popen3(cmd)`). A
        # direct `InstanceVariableWriteNode` is the only write form this collector handled, so an ivar appearing as a
        # `MultiWriteNode` target was silently dropped from the class-ivar union — leaving it to seed as pure `nil`
        # (from a sibling `@cb = nil` ctor write, or absent entirely) and false-fire `if @cb` always-falsey /
        # `@thr.alive?` undefined-for-nil. Record each ivar target with its tuple-position RHS type where the RHS is
        # array/tuple-shaped, else the unanalyzable floor (the same `Dynamic[top]` a single write to an unknown RHS
        # records — an unanalyzable multi-write means unknown, not nil).
        record_multi_write_ivars(node, scope, class_name, accumulator)
        record_binding_target_ivars(node, scope, class_name, accumulator)

        record_ivar_mutator_call(node, class_name, mutated_ivars) if mutated_ivars

        # Don't recurse into nested defs, classes, or modules; their ivars belong to their own enclosing class.
        return if IVAR_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

        if node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)
          walk_conditional_ivar_writes(node, scope, class_name, accumulator, guarded_ivars,
                                       mutated_ivars, dead_writes, declared)
          return
        end

        # #2490 — a block or `class <<` body whose `self` is another object writes that object's ivars. #2941 — a `def`
        # in it that runs on a `class_name` instance again counts its writes.
        # The reentry is for code that runs on an instance again, so a singleton-side `def` takes none.
        each_census_child(node, class_name, def_bodies: true, reentry: !scope.self_type.is_a?(Type::Singleton)) do |c|
          gather_ivar_writes(c, scope, class_name, accumulator, guarded_ivars, mutated_ivars, dead_writes, declared)
        end
      end

      # #1931 — `instance_variable_set` on `self` writes an ivar no write node shows ({ReflectiveIvarWrite}). A literal
      # name (`instance_variable_set(:@k, v)`) contributes the value's type to that ivar's entry, as `@k = v` would. A
      # name the analysis cannot read (`instance_variable_set(:"@#{k}", v)`, the options-hash constructor idiom) may
      # write any ivar of the class, so every entry of the class turns gradual once the walk ends
      # ({#make_reflective_classes_gradual!}): a reader in another method otherwise kept a write's literal (`@timeout =
      # 5` read as `5`) and reported a call on it.
      def record_reflective_ivar_write(node, scope, class_name, accumulator)
        return unless ReflectiveIvarWrite.self_write?(node)

        name = ReflectiveIvarWrite.literal_name(node)
        if name
          accumulate_ivar_type(accumulator, class_name, name, scope.type_of(ReflectiveIvarWrite.value_node(node)))
        else
          (accumulator[REFLECTIVE_OPAQUE_CLASSES] ||= Set.new) << class_name
        end
      end

      def make_reflective_classes_gradual!(accumulator, classes)
        classes&.each do |class_name|
          entries = accumulator[class_name]
          next if entries.nil?

          accumulator[class_name] = entries.transform_values { Type::Combinator.untyped }
        end
      end

      # Records `@ivar.<method>(...)` calls whose method is in `MutationWidening::SHAPE_MUTATORS` or
      # `SetMutation::MUTATORS` ({#ivar_census_mutator?}).
      # The class-ivar pre-pass uses the resulting set to widen the post-collected accumulator entries (see
      # {.widen_mutated_ivar_entries!}). Always-safe to over-collect: any name that the widening primitive declines is
      # ignored at finalization.
      def record_ivar_mutator_call(node, class_name, mutated_ivars)
        method_name, receiver = mutation_target(node)
        return if method_name.nil?
        return unless receiver.is_a?(Prism::InstanceVariableReadNode)
        return unless ivar_census_mutator?(method_name)

        per_class = (mutated_ivars[class_name] ||= {})
        per_ivar = (per_class[receiver.name] ||= Set.new)
        per_ivar << method_name
      end

      # The Set-only names (`add`, `merge`, … — issue #2294) are recorded here rather than in `SHAPE_MUTATORS`, which
      # every scan reads by name alone: there `merge` would make `Hash#merge`, which returns a new Hash, a mutation of
      # its receiver. The census is safe to over-collect, since {#widen_member_for_observed_mutators} reads each name
      # against the table of the carrier it widens.
      def ivar_census_mutator?(method_name)
        MutationWidening::SHAPE_MUTATORS.include?(method_name) || SetMutation::MUTATORS.include?(method_name)
      end

      # `[mutator name, receiver node]` for a node that mutates its receiver, `nil` otherwise.
      #
      # `@h[k] ||= v` and its `&&=` / `+=` siblings store through `[]=` but are not `[]=` CallNodes; missing them left
      # an `@h = {}` mutated only that way carrying its empty `HashShape` into every sibling method, so `@h.empty?`
      # folded to `Constant[true]` on a hash the class fills. A `Prism::IndexTargetNode` stores the same way wherever
      # it appears — a multi-assign `@h[k], x = …`, a `for @h[k] in` index, a `rescue => @h[k]` reference — and this
      # widening takes no stored value, so it counts in every position. `IndexWriteWidening::CONTENT_WRITE_NODE_CLASSES`
      # owns that list; it is spelled out here as an explicit disjunction because that is what narrows `node` to
      # something with a `#receiver` — `CONTENT_WRITE_NODE_CLASSES.any? { … }` reads as a call on `Prism::Node` and
      # Rigor rejects it, correctly.
      def mutation_target(node)
        return [node.name, node.receiver] if node.is_a?(Prism::CallNode)

        if node.is_a?(Prism::IndexOrWriteNode) || node.is_a?(Prism::IndexAndWriteNode) ||
           node.is_a?(Prism::IndexOperatorWriteNode) || node.is_a?(Prism::IndexTargetNode)
          return [IndexWriteWidening::MUTATOR, node.receiver]
        end

        nil
      end

      # Walk an `IfNode` / `UnlessNode` so writes inside the THEN body that look like defensive ivar initialisation gain
      # a `nil` union in the seeded type. Without this, `@x = v unless @x` records `Constant[v]` for `@x`, then the
      # predicate folds to that same constant and `flow.always-truthy-condition` fires against a working program.
      # Mirrors the falsey-literal skip `record_ivar_or_write` makes for `@x ||= <falsey>` — a `||=` whose rvalue
      # can only leave the ivar falsey contributes no useful precision either (#1175).
      #
      # Polarity-aware on purpose: only the THEN body picks up the guard. The ELSE branch of `if @x; ...; else; @x =
      # init; end` would otherwise be marked too — but that pattern (write @x in the else of `if @x`) is a separate
      # idiom whose surrounding reads of `@x` would then surface a nil-receiver FP. The ELSE branch is left ungarded so
      # those reads continue to type as they did before this fix.
      def walk_conditional_ivar_writes(node, scope, class_name, accumulator, guarded_ivars, # rubocop:disable Metrics/ParameterLists
                                       mutated_ivars = nil, dead_writes = nil, declared = DeclaredParamWrites::EMPTY)
        then_guards = then_body_guarded_ivars(node)
        then_guarded = then_guards.empty? ? guarded_ivars : (guarded_ivars | then_guards)

        gather_ivar_writes(node.predicate, scope, class_name, accumulator, guarded_ivars,
                           mutated_ivars, dead_writes, declared)
        if node.statements
          gather_ivar_writes(node.statements, scope, class_name, accumulator, then_guarded,
                             mutated_ivars, dead_writes, declared)
        end
        branch = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
        return unless branch

        gather_ivar_writes(branch, scope, class_name, accumulator, guarded_ivars,
                           mutated_ivars, dead_writes, declared)
      end

      # Returns the set of ivar names that, in the THEN body of this conditional, are statically known to be in a nil /
      # unset state — i.e. the body really IS the defensive-init half of the idiom. Conservative on purpose: only the
      # shapes that idiomatically express "the ivar is missing" qualify.
      #
      # For `unless P; body; end`, body runs when `P` is falsey:
      #   - `P = @x` (or `@x && other` / `@x || other`)            → @x is falsey
      #   - `P = defined?(@x)`                                     → @x is undefined
      #
      # For `if P; body; ...`, body runs when `P` is truthy:
      #   - `P = @x.nil?`                                          → @x is nil
      #   - `P = !@x` / `not @x`                                   → @x is falsey
      def then_body_guarded_ivars(node)
        names = Set.new
        if node.is_a?(Prism::UnlessNode)
          collect_truthy_test_ivars(node.predicate, names)
          collect_defined_test_ivars(node.predicate, names)
        else
          collect_nil_test_ivars(node.predicate, names)
        end
        names
      end

      def collect_truthy_test_ivars(node, names)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::InstanceVariableReadNode
          names << node.name
        when Prism::AndNode, Prism::OrNode
          collect_truthy_test_ivars(node.left, names)
          collect_truthy_test_ivars(node.right, names)
        end
      end

      def collect_defined_test_ivars(node, names)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::DefinedNode
          target = node.value
          names << target.name if target.is_a?(Prism::InstanceVariableReadNode)
        when Prism::AndNode, Prism::OrNode
          collect_defined_test_ivars(node.left, names)
          collect_defined_test_ivars(node.right, names)
        end
      end

      def collect_nil_test_ivars(node, names)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::CallNode
          receiver = node.receiver
          if receiver.is_a?(Prism::InstanceVariableReadNode) &&
             %i[nil? !].include?(node.name)
            names << receiver.name
          end
        when Prism::AndNode, Prism::OrNode
          collect_nil_test_ivars(node.left, names)
          collect_nil_test_ivars(node.right, names)
        end
      end

      # WD3 — ADR-41-style hard cap on how deep the same-class-call definite-assignment crediting recurses (the ctor
      # calls `mask!`, which could itself call another same-class helper). Cycle-guarded independently; the cap bounds
      # even acyclic chains.
      SAME_CLASS_CALL_DEPTH_CAP = 3
      private_constant :SAME_CLASS_CALL_DEPTH_CAP

      # WD3 — builds the per-class definite-assignment summary: per class, then per method, the ivars assigned non-nil
      # on every completing path. Used so a ctor's `dead_transient_nil_writes` can credit an indirect overwrite through
      # an unconditionally-called same-class method (ipaddr's `initialize` reassigns `@mask_addr` via `mask!`).
      #
      # Each method's set is computed by the same suffix definite-assignment analysis used for the ctor seed, run from
      # the method body's first statement for every ivar the method writes anywhere. Same-class calls inside a method
      # are credited transitively (depth-capped, cycle-guarded) so the resulting FLAT table is correct at depth 0 for
      # the ctor lookup.
      def build_method_assign_effects(root)
        defs = collect_class_method_defs(root)
        effects = {}
        memo = {}.compare_by_identity
        defs.each do |class_name, methods|
          methods.each do |method_name, def_node|
            assigns = method_definite_assigns(class_name, method_name, def_node, defs, effects, memo, 0)
            (effects[class_name] ||= {})[method_name] = assigns unless assigns.empty?
          end
        end
        effects.freeze
      end

      # Collects `{class_name => {method_name => DefNode}}` for every instance-method def in the program. Singleton defs
      # (`def self.x`) are excluded — the ctor-call crediting only follows instance-method calls on `self`. Last def
      # wins on redefinition.
      # `def_owner` is the meta-new override described on {#walk_methods_and_def_nodes}: inside a
      # `K = Class.new { … }` block `self` is the class the write names, so `def` leaves record under
      # it while `Module.nesting` — and therefore `prefix` — stays lexical. `[]` marks the anonymous
      # block of an unnameable write; nil (the default) leaves defs under the lexical prefix.
      def collect_class_method_defs(root, prefix = [], acc = {}, def_owner: nil, singleton_cref: false,
                                    defs_singleton: false)
        return acc unless root.is_a?(Prism::Node)

        case root
        when Prism::ClassNode, Prism::ModuleNode
          return collect_decl_method_defs(root, prefix, acc, def_owner, singleton_cref)
        when Prism::SingletonClassNode
          # The expression evaluates in the enclosing cref; the body's cref is unnameable.
          return collect_singleton_method_defs(root, prefix, acc, def_owner, singleton_cref)
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
             Prism::ConstantPathOrWriteNode
          return acc if collect_meta_new_method_defs?(root, prefix, acc, def_owner, singleton_cref)
        when Prism::DefNode
          # `defs_singleton` is the instance_eval split — `def` binds on the receiver's
          # singleton, an instance-def table this is not.
          return acc if defs_singleton

          record_collected_method_def(root, def_owner || prefix, acc)
          return acc
        when Prism::CallNode
          return acc if collect_call_method_defs?(root, prefix, acc, def_owner, singleton_cref,
                                                  defs_singleton)
        end

        root.rigor_each_child do |c|
          collect_class_method_defs(c, prefix, acc, def_owner: def_owner, singleton_cref: singleton_cref,
                                                    defs_singleton: defs_singleton)
        end
        acc
      end

      # The `def` leaf of {#collect_class_method_defs}: `def self.x` is a singleton def the
      # table does not collect; an ownerless prefix files nothing.
      def record_collected_method_def(root, rec_prefix, acc)
        (acc[rec_prefix.join("::")] ||= {})[root.name] = root unless rec_prefix.empty? || root.receiver
      end

      # The call arm of {#collect_class_method_defs}: dispatches to the anonymous meta-new and
      # eval-family handlers; any other call keeps walking its children below.
      def collect_call_method_defs?(root, prefix, acc, def_owner, singleton_cref, defs_singleton)
        collect_anonymous_meta_defs?(root, prefix, acc, def_owner, singleton_cref, defs_singleton) ||
          collect_eval_method_defs?(root, prefix, acc, def_owner, singleton_cref, defs_singleton)
      end

      # The meta-new arm of {#collect_class_method_defs}: the write's receiver and arguments
      # evaluate in the enclosing context; the block's defs belong to the class the write
      # names, its declarations to the enclosing cref.
      def collect_meta_new_method_defs?(root, prefix, acc, enclosing_owner, singleton_cref)
        call = DeclarationWalk::Rules.meta_new_block_call(root)
        return false unless call

        child_prefix = DeclarationWalk::Rules.meta_new_child_prefix(root, prefix, enclosing_owner)
        meta_ownerless = singleton_cref && !DeclarationWalk::Rules.meta_new_path_target_nameable?(root, enclosing_owner)
        [call.receiver, *call.arguments&.arguments.to_a].compact.each do |part|
          collect_class_method_defs(part, prefix, acc, def_owner: enclosing_owner,
                                                       singleton_cref: singleton_cref)
        end
        if (body = DeclarationWalk::Rules.meta_new_block_body(root))
          collect_class_method_defs(body, prefix, acc,
                                    def_owner: (meta_ownerless ? nil : child_prefix) || [],
                                    singleton_cref: singleton_cref)
        end
        true
      end

      # The bare `Class.new { … }`-family call arm of {#collect_class_method_defs}: the
      # block's class has no name, so its `def`s belong to no nameable owner — they walk
      # under the empty prefix rather than the enclosing class.
      def collect_anonymous_meta_defs?(root, prefix, acc, def_owner, singleton_cref, defs_singleton)
        return false unless DeclarationWalk::Rules.meta_new_constant_rvalue?(root) && root.block.is_a?(Prism::BlockNode)

        [root.receiver, *root.arguments&.arguments.to_a].compact.each do |part|
          collect_class_method_defs(part, prefix, acc, def_owner: def_owner,
                                                       singleton_cref: singleton_cref,
                                                       defs_singleton: defs_singleton)
        end
        if (body = root.block.body)
          collect_class_method_defs(body, prefix, acc, def_owner: [],
                                                       singleton_cref: singleton_cref)
        end
        true
      end

      # The eval-family arm of {#collect_class_method_defs}: the block's `def`s bind on the
      # receiver — a nameable receiver re-anchors the owner, a bare/`self` receiver keeps the
      # enclosing self, and a receiver that names nothing walks the body ownerless.
      def collect_eval_method_defs?(root, prefix, acc, def_owner, singleton_cref, defs_singleton)
        return false unless DeclarationWalk::Rules.receiver_eval_call?(root)

        [root.receiver, *root.arguments&.arguments.to_a].compact.each do |part|
          collect_class_method_defs(part, prefix, acc, def_owner: def_owner,
                                                       singleton_cref: singleton_cref,
                                                       defs_singleton: defs_singleton)
        end
        self_prefix = def_owner || prefix
        unnameable = DeclarationWalk::Rules.unnameable_eval_self?(false, def_owner, prefix, singleton_cref)
        eval_prefix = DeclarationWalk::Rules.eval_receiver_prefix(root, self_prefix, prefix,
                                                                  unnameable_self: unnameable) || []
        if (body = root.block.body)
          collect_class_method_defs(body, prefix, acc, def_owner: eval_prefix,
                                                       singleton_cref: singleton_cref,
                                                       defs_singleton: INSTANCE_EVAL_CALLS.include?(root.name))
        end
        true
      end

      # The class/module arm of {#collect_class_method_defs}: defs inside the body belong to
      # the declared class — `def_owner` clears — while an unnameable header below an
      # unnameable cref walks the body ownerless.
      def collect_decl_method_defs(root, prefix, acc, def_owner, singleton_cref)
        self_decl = DeclarationWalk::Rules.self_anchored_decl_prefix(root.constant_path, def_owner)
        child = self_decl || Source::ConstantPath.declaration_prefix(prefix, root.constant_path)
        if child && root.body
          # Under an unnameable cref a bare/`self::` header opens `#<singleton>::Name` —
          # ownerless; nameable headers re-anchor at a real cref.
          child_cref = DeclarationWalk::Rules.unnameable_decl?(root, self_decl, singleton_cref)
          collect_class_method_defs(root.body, child_cref ? [] : child, acc,
                                    singleton_cref: child_cref)
        end
        acc
      end

      def collect_singleton_method_defs(root, prefix, acc, def_owner, singleton_cref)
        collect_class_method_defs(root.expression, prefix, acc, def_owner: def_owner,
                                                                singleton_cref: singleton_cref)
        if root.body
          # A `def` below `class <<` is a singleton method — this table collects
          # instance defs only, so the body walks ownerless.
          collect_class_method_defs(root.body, prefix, acc, def_owner: [],
                                                            singleton_cref: true)
        end
        acc
      end

      # Computes the definite-assignment set for one method, memoised per def node. The `memo` cycle-guards: a method
      # re-entered while its own summary is in progress contributes nothing (sound under-approximation), so mutual
      # recursion terminates.
      def method_definite_assigns(class_name, _method_name, def_node, defs, effects, memo, depth)
        return Set.new if def_node.body.nil?
        return memo[def_node] if memo.key?(def_node)
        return Set.new if depth >= SAME_CLASS_CALL_DEPTH_CAP

        memo[def_node] = Set.new # in-progress sentinel (cycle guard)
        statements = top_level_statements(def_node.body)
        candidates = ivar_write_targets(def_node.body)
        # A transient `@x = nil` opener whose own method reassigns it later must still count `@x` as assigned for
        # callers, so the crediting is computed at the BUILD-time depth.
        resolver = MethodEffectResolver.new(self, class_name, defs, effects, memo, depth)
        assigns = Set.new
        candidates.each do |ivar|
          assigns << ivar if suffix_definitely_assigns_with_resolver?(statements, 0, ivar, class_name, resolver, depth)
        end
        memo[def_node] = assigns
      end

      # Every ivar this body assigns a non-nil value to ANYWHERE (the candidate set for the method's definite-assignment
      # scan).
      def ivar_write_targets(node, acc = Set.new)
        return acc unless node.is_a?(Prism::Node)

        acc << node.name if node.is_a?(Prism::InstanceVariableWriteNode) && !nil_literal_value?(node.value)
        node.rigor_each_child { |c| ivar_write_targets(c, acc) }
        acc
      end

      # Build-time variant of `suffix_definitely_assigns?` that resolves same-class calls through the lazy `resolver`
      # (which recurses into `method_definite_assigns` for not-yet-computed callees) rather than the finished flat
      # table.
      def suffix_definitely_assigns_with_resolver?(statements, from, target, class_name, resolver, depth)
        statements[from..].each do |stmt|
          outcome = statement_assignment_outcome(stmt, target, class_name, resolver, depth, nil)
          return true if outcome == :assigned
          return false if outcome == :terminates_unassigned
        end
        false
      end

      # Adapts `effects.dig(class, method)` for build-time crediting: when the callee summary is not yet in the flat
      # table, compute it on demand (depth+1) via `method_definite_assigns`.
      class MethodEffectResolver
        def initialize(indexer, class_name, defs, effects, memo, depth)
          @indexer = indexer
          @class_name = class_name
          @defs = defs
          @effects = effects
          @memo = memo
          @depth = depth
        end

        def dig(class_name, method_name)
          existing = @effects.dig(class_name, method_name)
          return existing if existing

          def_node = @defs.dig(class_name, method_name)
          return nil if def_node.nil?

          @indexer.send(:method_definite_assigns, class_name, method_name, def_node, @defs, @effects, @memo,
                        @depth + 1)
        end
      end

      # C2 — returns a Set of `object_id`s for transient `@x = nil` writes that a later statement in the same method
      # body *definitely* overwrites with a non-nil value on every completing path. Such a nil can never be the ivar's
      # value at method exit, so it must not contribute a `nil` constituent to the (flow-insensitive) class-ivar union.
      #
      # Scope is deliberately narrow and post-domination-sound:
      #   - only the top-level statement sequence of the body is
      #     considered (no writes hidden inside loops / rescue / nested
      #     conditionals count as the "definite" overwrite, except the
      #     one structured `if/else` form below);
      #   - the killing statement is either an unconditional
      #     statement-level `@x = <non-nil>`, OR an `if/else` (with a
      #     real `else`) where BOTH branches' final top-level write to
      #     `@x` is non-nil. Both shapes overwrite `@x` on every path;
      #   - only `@x = nil` literal writes are ever marked dead — a
      #     non-nil transient is left untouched (it is already
      #     precision-additive in the union).
      def dead_transient_nil_writes(body, class_name = nil, method_assign_effects = nil)
        statements = top_level_statements(body)
        return nil if statements.length < 2

        dead = nil

        statements.each_with_index do |stmt, i|
          next unless stmt.is_a?(Prism::InstanceVariableWriteNode) && nil_literal_value?(stmt.value)

          # The opening `@x = nil` is dead when every completing path of the SUFFIX after it (normal end OR early
          # `return`, never a `raise`-terminated path) definitely reassigns `@x` non-nil. The suffix analysis credits an
          # unconditionally-called same-class method's own definite assignments via `method_assign_effects`.
          if suffix_definitely_assigns?(statements, i + 1, stmt.name, class_name, method_assign_effects)
            (dead ||= Set.new) << stmt.object_id
          end
        end

        dead
      end

      def top_level_statements(body)
        return [] if body.nil?
        return body.body if body.is_a?(Prism::StatementsNode)

        [body]
      end

      def nil_literal_value?(node)
        node.is_a?(Prism::NilNode)
      end

      # True when, starting from `statements[from]`, EVERY path that completes the method (falls off the end OR hits an
      # early `return`) definitely assigns `target` a non-nil value first. Paths terminated by `raise` are not
      # completing paths and are ignored (they never observe the ivar at method exit). A path that can fall through
      # `statements` without assigning fails.
      def suffix_definitely_assigns?(statements, from, target, class_name, effects)
        statements[from..].each do |stmt|
          outcome = statement_assignment_outcome(stmt, target, class_name, effects, 0, nil)
          # The statement assigned on every continuing path -> the suffix is satisfied no matter what follows.
          return true if outcome == :assigned
          # The statement terminates control here (return/raise) and the value it carried did not assign on every path
          # -> some completing path reached exit without the assignment.
          return false if outcome == :terminates_unassigned
          # Otherwise (:falls_through_unassigned) keep scanning the remaining statements.
        end
        # Fell off the end with no definite assignment.
        false
      end

      # Classifies a single statement's effect on `target`:
      #   :assigned                 — every path through the statement
      #                               that continues OR returns assigns
      #                               `target` non-nil (suffix is done);
      #   :terminates_unassigned    — the statement ends the method
      #                               (return/raise) on some path
      #                               without a definite assignment, so
      #                               a completing path escaped;
      #   :falls_through_unassigned — control may continue past it
      #                               without the assignment (keep
      #                               scanning the suffix).
      def statement_assignment_outcome(stmt, target, class_name, effects, depth, visiting)
        case stmt
        when Prism::InstanceVariableWriteNode
          return :falls_through_unassigned if stmt.name != target

          nil_literal_value?(stmt.value) ? :falls_through_unassigned : :assigned
        when Prism::CallNode
          if unconditional_call_assigns?(stmt, target, class_name, effects, depth, visiting)
            :assigned
          else
            :falls_through_unassigned
          end
        when Prism::IfNode, Prism::UnlessNode
          conditional_assignment_outcome(stmt, target, class_name, effects, depth, visiting)
        when Prism::CaseNode
          case_assignment_outcome(stmt, target, class_name, effects, depth, visiting)
        when Prism::ReturnNode
          :terminates_unassigned
        else
          # Any other statement — including a bare `raise`/`fail`, which terminates without a completing path that
          # observes the seed nil — is neutral: control either continues or the path never reaches method exit. Keep
          # scanning the suffix.
          :falls_through_unassigned
        end
      end

      # True when a branch body (a StatementsNode / single node) definitely assigns `target` non-nil on every path that
      # completes the method through it, OR terminates every path by raise (vacuously safe — no completing path observes
      # the seed nil). Returns false if any path can complete/return without the assignment.
      def branch_definitely_assigns?(branch, target, class_name, effects, depth, visiting)
        stmts = top_level_statements(branch)
        return false if stmts.empty?

        stmts.each do |stmt|
          outcome = statement_assignment_outcome(stmt, target, class_name, effects, depth, visiting)
          return true if outcome == :assigned
          return false if outcome == :terminates_unassigned
        end
        # Reached the end of the branch without a definite assignment; safe only if the branch's last statement always
        # raises (no completing path falls out of it).
        always_raises?(stmts.last)
      end

      # `if`/`unless` is a definite assignment of `target` only when BOTH the then and else arms definitely assign (or
      # raise-out). A missing else arm means the fall-through path skips the assignment -> not definite. Modifier-form
      # `if`/`unless` (no else, single predicate'd statement) likewise.
      def conditional_assignment_outcome(node, target, class_name, effects, depth, visiting)
        else_branch = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
        return :falls_through_unassigned unless else_branch.is_a?(Prism::ElseNode)
        return :falls_through_unassigned unless node.statements

        then_ok = branch_definitely_assigns?(node.statements, target, class_name, effects, depth, visiting)
        else_ok = branch_definitely_assigns?(else_branch.statements, target, class_name, effects, depth, visiting)
        then_ok && else_ok ? :assigned : :falls_through_unassigned
      end

      # `case` is a definite assignment only when there is a real `else` clause AND every `when`/`in` body plus the else
      # body definitely assigns (or raises-out). A missing else lets an unmatched subject fall through unassigned.
      def case_assignment_outcome(node, target, class_name, effects, depth, visiting)
        else_clause = node.else_clause
        return :falls_through_unassigned unless else_clause.is_a?(Prism::ElseNode)

        branches = node.conditions.map { |c| c.respond_to?(:statements) ? c.statements : nil }
        branches << else_clause.statements
        all_ok = branches.all? do |b|
          branch_definitely_assigns?(b, target, class_name, effects, depth, visiting)
        end
        all_ok ? :assigned : :falls_through_unassigned
      end

      # True when `node` (a single statement or its last statement) is an unconditional `raise`/`fail` call that always
      # terminates the path — used to treat raise-terminated branches as non-completing (they never observe the seed
      # nil).
      def always_raises?(node)
        node = top_level_statements(node).last if node.is_a?(Prism::StatementsNode)
        return false unless node.is_a?(Prism::CallNode)
        return false unless node.receiver.nil?

        %i[raise fail].include?(node.name)
      end

      # True when `call` is an unconditional, statement-level, implicit-self (or `self.`) call to a SAME-CLASS method
      # whose definite-assignment summary includes `target`. Calls through a block, on another receiver, or to an
      # unresolved name contribute nothing (the seed nil stays).
      def unconditional_call_assigns?(call, target, class_name, effects, depth, _visiting)
        return false if effects.nil? || class_name.nil?
        return false if depth >= SAME_CLASS_CALL_DEPTH_CAP
        return false unless call.is_a?(Prism::CallNode)
        return false unless call.block.nil?
        # Implicit self (`mask!(x)`) or explicit `self.mask!(x)` only.
        return false unless call.receiver.nil? || call.receiver.is_a?(Prism::SelfNode)

        assigns = effects.dig(class_name, call.name)
        return false if assigns.nil?

        assigns.include?(target)
      end

      def record_ivar_write(node, scope, class_name, accumulator, guarded: false, declared: nil)
        rvalue_type = declared || accumulator[CONSTANT_IVAR_VALUES]&.type_of(node.value, scope) ||
                      scope.type_of(node.value)

        # `@x = nil unless @x` / `@y = false unless @y` — follow-up to the polarity-aware defensive-init guard fix
        # (defensive ivar-init with a nil / false rvalue). When the rvalue is itself a falsey
        # Constant, `union(rvalue, Constant[nil])` collapses (for `nil`) or doesn't widen the type's truthiness profile
        # (for `false`) — the predicate `unless @x` then folds to a single `Constant[nil]` / `Constant[false]` and the
        # `flow.always-truthy-condition` / `-always-falsey-` rule false-fires on the no-op-but-documented-default idiom.
        # Skip the seed contribution for this write — the sibling of `record_ivar_or_write`'s no-truthy-rvalue
        # skip for `@x ||= <falsey>` (#1175). Other writes to the same ivar still contribute; the falsey-default
        # write carries no useful precision the predicate hasn't already given us. See tdiary-core HEAD `ee40c2b`
        # `lib/tdiary/configuration.rb:157` for the worked site.
        return if guarded && falsey_constant?(rvalue_type)

        rvalue_type = EmptySeed.erase(node.value, rvalue_type)

        rvalue_type = Type::Combinator.union(rvalue_type, Type::Combinator.constant_of(nil)) if guarded
        accumulate_ivar_type(accumulator, class_name, node.name, rvalue_type)
      end

      # #1175 — compound writes. ADR-58 § WD5 deferred seeding `||=` with a reopen clause ("a corpus
      # surfaces a memo-read shape the `union(v, nil)` seed provably improves"); Rigor's own
      # `unit_scan.rb` is that shape: `@dispatch_top_level ||= true` went unrecorded, so the ivar
      # kept `Constant[false]` and `unless @dispatch_top_level` folded always-falsey.
      def record_compound_ivar_write(node, scope, class_name, accumulator)
        case node
        when Prism::InstanceVariableOrWriteNode
          record_ivar_or_write(node, scope, class_name, accumulator)
        when Prism::InstanceVariableAndWriteNode
          record_ivar_and_write(node, scope, class_name, accumulator)
        when Prism::InstanceVariableOperatorWriteNode
          record_ivar_operator_write(node, scope, class_name, accumulator)
        end
      end

      # `@x ||= v` — the memo idiom. The stored value is the old truthy value or `v`, so the rvalue
      # alone would be an honest contribution; the `nil` member stands in for the read-before-write
      # state — a `||=`-only ivar is `nil` until the first call runs the write. (That same union is
      # what the `guarded` flag adds to a plain write, and for the same reason: the flow-insensitive
      # seed has to know the predicate does not fold.) An rvalue with no truthy part is skipped outright
      # — `@x ||= false` can only leave `@x` falsey, the same "no useful precision" call the guarded
      # `@x = nil unless @x` skip makes, and `@x ||= raise "unset"` stores nothing at all. Seeded as
      # `nil`, the guard bound its own ivar, and `ExpressionTyper::Writes.compound_write_value` read
      # `truthy(nil) | bot` — an instance method that sig-gen declared `-> bot`.
      def record_ivar_or_write(node, scope, class_name, accumulator)
        rvalue_type = EmptySeed.erase(node.value, scope.type_of(node.value))
        return if Narrowing.narrow_truthy(rvalue_type).is_a?(Type::Bot)

        accumulate_ivar_type(accumulator, class_name, node.name,
                             Type::Combinator.union(rvalue_type, Type::Combinator.constant_of(nil)))
      end

      # `@x &&= v` writes only when `@x` already holds a truthy value — the ivar was made truthy by an
      # earlier write, so the rvalue is the contribution; no `nil` member (unlike `||=`, the write
      # cannot be the first thing to give the ivar a value, and a spurious nil here would fire
      # possible-nil at reads the pre-existing writes already typed).
      #
      # For the same reason the contribution counts only beside a write that can give the ivar a value,
      # so it waits under {AND_WRITE_CONTRIBUTIONS} until {#merge_held_ivar_writes!} sees the whole class:
      # that write may come later in source order. An ivar only `&&=` writes stays unseeded, the unbound
      # target `ExpressionTyper::Writes.compound_write_value` reads as `Dynamic[top]`. Seeded as the rvalue, the
      # `&&=` bound itself, and `if (@x &&= 1)` folded always-truthy on an ivar that is `nil` at runtime.
      def record_ivar_and_write(node, scope, class_name, accumulator)
        pending = (accumulator[AND_WRITE_CONTRIBUTIONS] ||= {})
        accumulate_ivar_type(pending, class_name, node.name, scope.type_of(node.value))
      end

      # `@x op= v` stores `@x op v`, so its contribution is the operator dispatched on what the class's
      # other writes store. Those writes sit in methods Ruby may call in any order, so the write waits
      # under {OPERATOR_WRITE_CONTRIBUTIONS} until {#merge_held_ivar_writes!} has them all. Dispatched on
      # the seed as the walk had it so far, a `+=` written above `@x &&= 1.5` never saw the `1.5`, `Float`
      # fell out of the seed, and `x == 2.5` folded always-falsey on a program that reaches it.
      def record_ivar_operator_write(node, scope, class_name, accumulator)
        pending = ((accumulator[OPERATOR_WRITE_CONTRIBUTIONS] ||= {})[class_name] ||= {})
        (pending[node.name] ||= []) << [node.binary_operator, scope.type_of(node.value), scope.environment]
      end

      # Folds the held `&&=` and `op=` writes into the seed once the walk has seen every write of the class.
      # An ivar only `op=` writes is seeded first, from the widened rvalues: the receiver would read as `nil`,
      # and `nil + v` raises at runtime, so the seed is unconstrained there and the rvalue is the right answer
      # for the dominant `+=` / `-=` / `|=` families. That seed counts as a write for the `&&=` merge, and the
      # `op=` results then join on top of the complete seed.
      def merge_held_ivar_writes!(accumulator)
        operator_writes = accumulator.delete(OPERATOR_WRITE_CONTRIBUTIONS) || {}
        seed_operator_only_ivars!(accumulator, operator_writes)
        merge_ivar_and_writes!(accumulator)
        merge_ivar_operator_writes!(accumulator, operator_writes)
      end

      def seed_operator_only_ivars!(accumulator, operator_writes)
        operator_writes.each do |class_name, ivars|
          ivars.each do |ivar_name, writes|
            next if accumulator.dig(class_name, ivar_name)

            rvalues = writes.map { |(_operator, rvalue_type, _environment)| rvalue_type }
            accumulate_ivar_type(accumulator, class_name, ivar_name,
                                 Type::Combinator.widen_value_pinned(Type::Combinator.union(*rvalues)))
          end
        end
      end

      # Folds the held `&&=` contributions into the seed of every ivar another write seeds, and drops the rest.
      def merge_ivar_and_writes!(accumulator)
        accumulator.delete(AND_WRITE_CONTRIBUTIONS)&.each do |class_name, ivars|
          seeded = accumulator[class_name]
          next if seeded.nil?

          ivars.each do |ivar_name, type|
            seeded[ivar_name] = Type::Combinator.union(seeded[ivar_name], type) if seeded.key?(ivar_name)
          end
        end
      end

      # The `op=` results join the complete seed. The methods run in any order, so a result is itself the
      # receiver of another held write: the dispatch repeats once per held write, which covers every chain one
      # call of each method can form, and stops early once a pass adds nothing. Not ADR-56's {BodyFixpoint}:
      # iterated to its fixed point, a lone counter's `@n += x` re-dispatched on its own `Dynamic[Integer | …]`
      # result and gained `Dynamic[top]`, and the widening pass that forces convergence dropped the `0` it
      # starts at — on nearly every counter ivar in the survey corpus. A chain that has to go on from a receiver
      # wider than {OPERATOR_CHAIN_UNION_CAP} floors to `Dynamic[top]` instead: each further pass dispatches
      # every held write on that union, and distinct tuple literals (`@a += [:s1]`, `@a += [:s2]`, …) grow it
      # by two members per write.
      def merge_ivar_operator_writes!(accumulator, operator_writes)
        operator_writes.each do |class_name, ivars|
          seeded = accumulator[class_name]
          ivars.each { |ivar_name, writes| seeded[ivar_name] = chain_operator_writes(seeded[ivar_name], writes) }
        end
      end

      def chain_operator_writes(seed, writes)
        writes.size.times do |pass|
          if pass.positive? && union_arity(Type::Combinator.widen_value_pinned(seed)) > OPERATOR_CHAIN_UNION_CAP
            return Type::Combinator.untyped
          end

          joined = Type::Combinator.union(seed, operator_write_results(seed, writes))
          break if joined == seed

          seed = joined
        end
        seed
      end

      def union_arity(type) = type.is_a?(Type::Union) ? type.members.size : 1

      # A cost guard local to this chain, not ADR-41's `union_size` budget, which stays unwired: it floors
      # silently, as {BodyFixpoint} does. Forty is the low end of the pathology band ADR-41's Slice 2a names for
      # such a valve; the widest `op=`-written ivar seed in the survey corpus has seven members.
      OPERATOR_CHAIN_UNION_CAP = 40
      private_constant :OPERATOR_CHAIN_UNION_CAP

      # The union of what each held `op=` write stores when `@x` holds `current`. The receiver is widened off
      # its value-pinned members first, or `Constant[0] + Constant[1]` would fold to a `Constant[1]` that pins
      # the ivar to one literal; the result is widened for the same reason.
      def operator_write_results(current, writes)
        receiver = Type::Combinator.widen_value_pinned(current)
        results = writes.map do |(operator, rvalue_type, environment)|
          dispatch = lambda do |type|
            MethodDispatcher.dispatch(receiver_type: type, method_name: operator, arg_types: [rvalue_type],
                                      environment: environment)
          end
          stored = dispatch.call(receiver) || partial_operator_result(receiver, rvalue_type, environment, dispatch)
          Type::Combinator.widen_value_pinned(stored)
        end
        Type::Combinator.union(*results)
      end

      # A union the dispatch declines as a whole because one member does (`nil + 1`, `:none + 1`, a `Dynamic`, a
      # class the pre-pass cannot resolve). The members it does type are dispatched together; a union with none
      # falls back to the rvalue. Declined whole, a `reset` storing `nil` beside `@x = 0.5` and `@x += 1` sent
      # the `+=` to its rvalue, `Float` left the seed, and `l > 1.0` under `l.is_a?(Float)` folded always-falsey.
      # The typed members are not dispatched one by one: a union of tuples dispatches to one `Array[…]`, member by
      # member to a tuple per chain.
      #
      # A declining member whose class the environment knows lacks the operator, so the write raises and stores
      # nothing; joined for it, the rvalue put an `Integer` no run can store beside `0.5 | Float | nil`, and a
      # sibling `def level = @x` declared `-> Float?` reported `def.return-type-mismatch`. Any other declining
      # member stores what the pre-pass cannot see, and keeps the rvalue it fell back to before. "Lacks" is
      # read from the RBS: a source monkey patch of a core operator, or an operator the RBS omits, reads as
      # raising, and so does an unwritten ivar's `nil`, which the seed does not model (`nil ^ true` is `true`).
      def partial_operator_result(receiver, rvalue_type, environment, dispatch)
        return rvalue_type unless receiver.is_a?(Type::Union)

        typed, declined = receiver.members.partition { |member| dispatch.call(member) }
        result = dispatch.call(Type::Combinator.union(*typed)) unless typed.empty?
        return rvalue_type if result.nil?
        return result if declined.all? { |member| lacks_operator?(member, environment) }

        Type::Combinator.union(result, rvalue_type)
      end

      def lacks_operator?(member, environment)
        member.is_a?(Type::Constant) || (member.is_a?(Type::Nominal) && environment.class_known?(member.class_name))
      end

      # The accumulator keys {#record_ivar_and_write} and {#record_ivar_operator_write} hold their writes under
      # until the walk ends. Every other key is a qualified class name, a String, so a Symbol can never collide
      # with one.
      AND_WRITE_CONTRIBUTIONS = :and_write_contributions
      OPERATOR_WRITE_CONTRIBUTIONS = :operator_write_contributions
      private_constant :AND_WRITE_CONTRIBUTIONS, :OPERATOR_WRITE_CONTRIBUTIONS

      # The same Symbol-key convention for two side tables the walk fills and {#build_class_ivar_index} removes
      # before anything reads class names: the ivars each class's `define_method` blocks write (in the
      # accumulator), and the class-body writes held out of `init_writes` until {#exempt_class_body_writes!}.
      DEFINE_METHOD_WRITES = :define_method_writes
      CLASS_BODY_WRITES = :class_body_writes
      # The classes a computed-name `instance_variable_set` may write any ivar of ({#record_reflective_ivar_write}).
      REFLECTIVE_OPAQUE_CLASSES = :reflective_opaque_classes
      # The census's {ConstantIvarValue}, which {#record_ivar_write} reads.
      CONSTANT_IVAR_VALUES = :constant_ivar_values
      # Issue #2931 — per class, the ivars a singleton-side `def` (`def self.x`) of it writes, which the census files
      # under the class too (#1958).
      SINGLETON_IVAR_WRITES = :singleton_ivar_writes
      private_constant :DEFINE_METHOD_WRITES, :CLASS_BODY_WRITES, :REFLECTIVE_OPAQUE_CLASSES, :CONSTANT_IVAR_VALUES,
                       :SINGLETON_IVAR_WRITES

      # Unions `type` into the class-ivar accumulator for `(class_name, ivar_name)`. Shared by the single-write and
      # multi-write (parallel-assignment) collectors.
      def accumulate_ivar_type(accumulator, class_name, ivar_name, type)
        accumulator[class_name] ||= {}
        existing = accumulator[class_name][ivar_name]
        accumulator[class_name][ivar_name] =
          existing ? Type::Combinator.union(existing, type) : type
      end

      # N1 — records each `InstanceVariableTargetNode` of a `MultiWriteNode` (parallel / multiple assignment) into the
      # class-ivar union. The per-slot type comes from `MultiTargetBinder`, the decomposition locals use (issue #1110):
      # a `Tuple` right-hand side element-wise, an `Array[T]` per slot, a union distributed over its members, a value
      # with no implicit `to_ary` as `[rhs]`, and anything else — an unanalyzable RHS such as `Open3.popen3(cmd)` — as
      # the `Dynamic[top]` floor (NOT `nil`: a multi-write we cannot decompose means the value is *unknown*, mirroring
      # what a single write to an unknown RHS records). Nested and splat targets (`(@a, @b), *@c = …`) follow the same
      # rules.
      #
      # The seed records the binder's default reading and drops its ADR-101 marks, exactly what a single
      # `@x = xs.first` write records: an `Array[T]` fixed slot seeds `T`, not `T | nil`. The table has no mark
      # channel, and a `T | nil` seed is not gated everywhere a declaration-sourced nil is — a sibling returning the
      # ivar against a declared `-> T` would fire `def.return-type-mismatch` on a correct program (ADR-5).
      #
      # The ADR-57 slot softening is the opposite case and is turned off (`soften_slots: false`): dropping the `nil`
      # of a present `X | nil` tuple slot, or a union member's bare `nil`, is honest for a local only because the
      # binder marks the name, and the seed drops the mark. Without it a sibling's `if @b` / `raise unless @b` would
      # fold on a `nil` that is reachable, so the seed keeps the genuine `X | nil` the pre-#1110 indexer kept.
      def record_multi_write_ivars(node, scope, class_name, accumulator)
        return unless node.is_a?(Prism::MultiWriteNode)

        rhs_type = scope.type_of(node.value)
        ivars = MultiTargetBinder.bind_marked(node, rhs_type, scope: scope, soften_slots: false).ivars
        # #2499 — `@a, @b = {}, []` erases each empty seed as a single write does.
        values = EmptySeed.multi_write_values(node)
        ivars.each do |name, type|
          accumulate_ivar_type(accumulator, class_name, name, EmptySeed.erase(values[name], type))
        end
      end

      # Issue #1217 — `rescue => @err` and `for @x in xs` (with `for *@x in`, `for @x, y in`) write the ivar through a
      # target node, not an `InstanceVariableWriteNode`, so the census missed them: a sibling method read the
      # constructor's `@err = nil` alone and folded `if @err` always-falsey. A rescue reference contributes the
      # exception instance type the clause names; a `for` index the `Dynamic[top]` floor, since the census does not
      # type the element, and an unknown value is honest where a missing one is not.
      def record_binding_target_ivars(node, scope, class_name, accumulator)
        names = BindingTargets.names(node, Prism::InstanceVariableTargetNode)
        return if names.empty?

        type = BindingTargets.value_type(node, scope)
        names.each { |name| accumulate_ivar_type(accumulator, class_name, name, type) }
      end

      # The names a `rescue =>` reference or a `for` index binds through a target of `target_class`, looking through
      # a splat and a multi-target index.
      module BindingTargets
        EMPTY = [].freeze
        private_constant :EMPTY

        module_function

        def names(node, target_class)
          root =
            case node
            when Prism::RescueNode then node.reference
            when Prism::ForNode then node.index
            end
          return EMPTY if root.nil?

          collect(root, target_class, [])
        end

        # What an ivar target is written with: a rescue reference's exception instance, as the in-method binding
        # types it ({ErrorInfo.rescue_exception_type}), a `for` index's `Dynamic[top]` floor.
        def value_type(node, scope)
          return Type::Combinator.untyped unless node.is_a?(Prism::RescueNode)

          ErrorInfo.rescue_exception_type(node) { |exception_node| scope.type_of(exception_node) }
        end

        def collect(target, target_class, acc)
          case target
          when target_class then acc << target.name
          when Prism::SplatNode then collect(target.expression, target_class, acc) if target.expression
          when Prism::MultiTargetNode
            [*target.lefts, target.rest, *target.rights].compact.each { |t| collect(t, target_class, acc) }
          end
          acc
        end
      end
      private_constant :BindingTargets

      def falsey_constant?(type)
        type.is_a?(Type::Constant) && (type.value.nil? || type.value == false)
      end

      # Issue #352 — folds the project-wide `pre_eval:` constant seed under this file's own table.
      # Issue #644 — merges the per-file constant table OVER the project seed and records, alongside it,
      # which of those names THIS FILE declares (as last segments). The second table is the other half of
      # `Scope#published_constant?`: a project-published constant the analysed file also assigns is one its
      # author can see, so the truthiness rules keep firing on it. Both are seeded here, where the per-file
      # table is still separable from the project seed it is about to merge over.
      # Issue #667 — the alias table rides the same census and the same gate, because it answers the third
      # half of the same question: which of THIS file's own constant names carry a value the author never
      # saw. One census call now feeds both sets.
      def seed_constant_tables(seeded_scope, default_scope, in_source_constants, root)
        merged = merge_seeded_constants(default_scope.in_source_constants, in_source_constants)
        published = default_scope.published_constant_names
        census = published.empty? ? nil : ConstantTables.constant_write_census(root)
        seeded_scope.with_discovery(
          seeded_scope.discovery.with(
            in_source_constants: merged,
            local_constant_names: local_constant_name_set(census, published),
            published_constant_alias_names: published_constant_alias_name_set(census, published)
          )
        )
      end

      # The QUALIFIED names this file assigns that the project also published, frozen. Read from the same
      # {ConstantTables.constant_write_census} the cross-file table is built from, not from the typed per-file
      # table: the typed walk cannot see a multi-assign / `self::` / operator-write target, so deriving the
      # exemption from it would be a second source of truth blind to exactly the forms the census exists to
      # catch. Gated on the project having published anything at all, so a project with no cross-file value
      # constants pays no extra walk and allocates nothing; the result is filtered to the published names, so
      # what it holds is bounded by what the exemption can ever be asked about.
      #
      # It reads the census's `declared` half rather than its keys ([#710](https://github.com/rigortype/rigor/issues/710)).
      # The two consumers want opposite answers about a write whose base nothing names: the conflict rule asks
      # "could another file's value for this name be wrong?" — yes, so the name stays censused — and this
      # exemption asks "did this file declare it?" — no, `[Foo].each { |k| k::X = 1 }` declares `Foo::X`.
      # Granting it un-withheld `flow.always-truthy-condition` for a name the file never wrote.
      def local_constant_name_set(census, published)
        return Scope::DiscoveryIndex::EMPTY.local_constant_names if census.nil?

        names = census.declared.select { |name| published.include?(name.split("::").last) }
        names.empty? ? Scope::DiscoveryIndex::EMPTY.local_constant_names : names.to_set.freeze
      end

      # Issue #667 — the last segments of the constants this file assigns straight from a constant the
      # project published and this file does NOT itself declare. `MODE2 = AppConfig::MODE` renames a foreign
      # declaration, so the local-declaration exemption releasing `MODE2` is the wrong answer: the author can
      # see the alias but not the value. The source's own foreignness is asked against the census's
      # `declared` half — the same suffix relation `Scope#published_constant?` uses — so a same-file
      # `MODE2 = MODE1` pair stays fully reportable.
      def published_constant_alias_name_set(census, published)
        return Scope::DiscoveryIndex::EMPTY.published_constant_alias_names if census.nil?

        names = census.aliases.filter_map do |target, source|
          next unless published.include?(source.split("::").last)
          next if census_declares_constant?(census.declared, source)

          target.split("::").last
        end
        names.empty? ? Scope::DiscoveryIndex::EMPTY.published_constant_alias_names : names.to_set.freeze
      end

      def census_declares_constant?(declared, reference)
        return true if declared.include?(reference)

        suffix = "::#{reference}"
        declared.any? { |name| name.end_with?(suffix) }
      end

      # Returns the per-file table unchanged (same frozen object) when nothing was seeded, so a run without `pre_eval:`
      # constants allocates and compares exactly what it did before.
      def merge_seeded_constants(seeded, per_file)
        return per_file if seeded.nil? || seeded.empty?

        seeded.merge(per_file).freeze
      end

      # {DeclarationWalk::Rules}' two lists of the block-taking calls that swap `self` for the receiver, each
      # described where it is defined and bound here so that the walkers and the rules read one object. The
      # def-owning walks split the two surfaces on {INSTANCE_EVAL_CALLS}.
      INSTANCE_EVAL_CALLS = DeclarationWalk::Rules::INSTANCE_EVAL_CALLS
      RECEIVER_EVAL_CALLS = DeclarationWalk::Rules::RECEIVER_EVAL_CALLS
      private_constant :INSTANCE_EVAL_CALLS, :RECEIVER_EVAL_CALLS

      # The sentinel for "`self` was rebound to something no class/module name reaches". A `self::BAR = …`
      # under it is DECLINED — the same answer a dynamic base takes, for the same reason.
      OPAQUE_SELF = :__rigor_opaque_self__
      private_constant :OPAQUE_SELF

      # Slice 7 phase 12 — in-source method discovery pre-pass, fused with the instance-method def-node pre-pass (v0.0.2
      # #5). One descent produces BOTH tables the per-file `index` and the cross-file pre-pass each need together:
      #
      #   - `methods`   : `{class_name => {method => :instance | :singleton}}`
      #     for every `def` / `define_method(:name)` / `attr_*` / `alias` /
      #     Data/Struct-member reader (the undefined-method existence table).
      #   - `def_nodes` : `{class_name => {method => Prism::DefNode}}` for
      #     every instance-side `def` (the inter-procedural return-inference
      #     table; singleton defs and `define_method` are intentionally
      #     skipped — `record_def_node` filters them).
      #
      # Both tables share the class / module / singleton / meta-block descent (it stops at `DefNode`), so one combined
      # walk records both accumulators instead of traversing every file twice.
      #
      # Issue #992 — and a third, `envelopes`: `{class_name => {[kind, method] => envelope}}`, the
      # {Source::ParameterEnvelope} of every name the existence table records, plus the class-wide
      # {Scope::DiscoveryIndex::ENVELOPE_MODULE_MARK} / {Scope::DiscoveryIndex::ENVELOPE_DYNAMIC_MARK} keys.
      # It is written by the SAME recorder that writes the existence table ({#record_method}), so a name the
      # walk learns from an `alias`, an `attr_*` or a `define_method` can never be missing from it: those
      # record {Source::ParameterEnvelope::OPAQUE}, and only a `def` records a real envelope.
      #
      # Issue #1120 — and a fourth, `refinements`: `{refined class => {method => [refining modules]}}`, the
      # `def`s of every `refine X do … end` body ({#record_refinement_defs}). Those are kept OUT of the first
      # three tables, which answer everywhere: a refined method exists only where a `using` is in effect.
      #
      # ADR-119 WD3 — and a fifth, the file's def-contribution siblings ({MethodTables#siblings}):
      # `possible_discovered_methods`, `contested_discovered_def_nodes` and
      # `contested_discovered_parameter_envelopes`, from the {Certainty} classification `certainty` (computed here
      # when the caller has none).
      def build_methods_and_def_nodes(root, source_path = nil, certainty: Certainty.possible_nodes(root), census: nil)
        tables = MethodTables.new({}, {}, nil, certainty, true)
        tables.root = root
        tables.census = census
        def_nodes = {}
        walk_methods_and_def_nodes(root, [], false, tables, def_nodes, source_path)
        AliasDefNodes.apply_alias_def_nodes(root, def_nodes, tables)
        [tables.existence.transform_values(&:freeze).freeze, def_nodes.transform_values(&:freeze).freeze,
         tables.envelopes.transform_values(&:freeze).freeze, freeze_refinements(tables.refinements),
         tables.siblings]
      end

      # Issue #3015 — the bodies of a concern's `included` / `prepended` / `class_methods` blocks, each with the prefix
      # of the module whose body writes it ({ScopeIndexer#concern_hook_blocks}). Ruby runs such a block on the includer
      # (or on `Owner::ClassMethods`), so a `def self.x` or `class << self` def in it is not the module's own singleton
      # method, and the walks that file one ask {#hook_block?} first. Mixed into an accumulator with a
      # `hook_block_spans` slot.
      module HookBlockSpans
        def mark_hook_blocks(blocks, owner)
          blocks.each do |block|
            (self.hook_block_spans ||= []) << [block.location.start_offset, block.location.end_offset, owner]
          end
        end

        # Whether `node` sits in a block marked for the module `owner` (a prefix).
        def hook_block?(node, owner)
          offset = node.location.start_offset
          !hook_block_spans.nil? &&
            hook_block_spans.any? { |start, stop, marked| offset >= start && offset < stop && marked == owner }
        end

        # Whether `def_node` is a `def self.x` in a block marked for the module `owner`.
        def hook_block_self_def?(def_node, owner)
          def_node.receiver.is_a?(Prism::SelfNode) && hook_block?(def_node, owner)
        end
      end

      # The accumulator {#walk_methods_and_def_nodes} threads: the existence table and its issue #992
      # envelope twin, which only {#record_method} and {#record_surface_mark} write, and the issue #1120
      # refinement table, which only {#record_refinement_defs} writes. That last one stays nil until a
      # `refine` block is seen, so a file without one allocates nothing for it.
      #
      # ADR-119 WD3 — `certainty` is the file's {Certainty} answer and `certain` whether the contribution being
      # recorded is certain ({#at} sets it before each recorder). `possible`, `contested_envelopes` and
      # `contested_def_nodes` are the siblings the recorders fill, each nil until a possible contribution writes it.
      #
      # Issue #1689 — `root` is the walked tree, and `in_effect` its {InEffectRefinements}, built the first time a
      # `refine`-shaped call asks {#refine_target_of}, so a file without one never builds it.
      #
      # ADR-121 WD7 — `census`, when an Array, collects `[start offset, outcome]` for every `refine`-shaped node the
      # walk accounts for ({ScopeIndexer.refine_census}); `refine_text` memoises the byte offsets of the `refine`
      # words in the file's text, so a file with none skips every census scan and a `def` with none is not scanned;
      # `literal_seen` holds the offsets of the refine literals a call's arguments already accounted for;
      # `source_bytes` memoises the byte offsets of the file's heredoc openers; `loose_constants` memoises
      # {ScopeIndexer.loose_constant_segments}. The module a `refine`-shaped node is charged to is what the in-effect
      # walk worked out for it ({#refine_context}).
      MethodTables = Struct.new(:existence, :envelopes, :refinements, :certainty, :certain, :possible,
                                :contested_envelopes, :contested_def_nodes, :root, :in_effect, :census,
                                :refine_text, :literal_seen, :source_bytes, :loose_constants, :block_spans,
                                :definer_history, :forwardable_extends, :hook_block_spans) do
        include HookBlockSpans

        # Issue #2006 — records, in walk order, that a definer other than an alias wrote the instance method `name`
        # of `class_name` at `node`: `def_node` for a `def`, nil for a `define_method(:x)` or an `attr_*` reader or
        # writer, and whether the write is {#certain}. {AliasDefNodes.apply_alias_def_nodes} reads the history to copy
        # what an alias's old name held at the alias, and to tell an alias a later definer replaced.
        def wrote_definer(class_name, name, node, def_node)
          entry = [node.location.start_offset, def_node, certain ? true : false].freeze
          ((self.definer_history ||= {})[[class_name, name]] ||= []) << entry
        end

        # {ScopeIndexer.module_refine_target} against this tree's {InEffectRefinements}.
        def refine_target_of(node)
          return nil if ScopeIndexer.refine_target(node).nil?

          ScopeIndexer.module_refine_target(node, in_effect_query)
        end

        # {InEffectRefinements#class_body_refine?} for a `refine` call of this tree.
        def class_body_refine?(node) = ScopeIndexer.refine_call?(node) && in_effect_query.class_body_refine?(node)

        def in_effect_query = (self.in_effect ||= InEffectRefinements.new(root))

        # Does the walked file's text name `refine` as a word? Every census scan asks first, so a file that only says
        # `refined` or `refinement` pays nothing for it.
        def mentions_refine? = !refine_offsets.empty?

        # Does the text in `[start, stop)` name `refine` as a word, or open a heredoc whose body (which follows the
        # line, and so may end after `stop`) could? A `def` that does neither is not scanned.
        def refine_in?(start, stop)
          ScopeIndexer.offset_in?(refine_offsets, start, stop) ||
            ScopeIndexer.offset_in?(self.source_bytes ||= ScopeIndexer.heredoc_offsets(root), start, stop)
        end

        # ADR-121 WD7 — the `self` the `refine`-shaped `node` runs on, as the in-effect walk worked it out
        # ({InEffectRefinements#refine_context}); a module the walk cannot name for a node it did not record.
        def refine_context(node) = in_effect_query.refine_context(node) || RefineSelf.unknown

        # The byte offsets of each `refine` word in the file's text, ascending.
        def refine_offsets
          self.refine_text ||= ScopeIndexer.refine_word_offsets(root)
        end

        # Records that the walk accounted for the `refine`-shaped `node` with `outcome` (and the module it charged),
        # when a census is taken.
        def account(node, outcome, charged = nil)
          census&.push([node.location.start_offset, outcome, charged])
        end

        # Marks a refine literal accounted for by its call, so the walk's descent does not account for it again.
        def see_literal(node) = (self.literal_seen ||= Set.new) << node.location.start_offset

        def literal_seen?(node) = !literal_seen.nil? && literal_seen.include?(node.location.start_offset)

        # A6 — the last segments of the constants this file binds by `||=` or by a literal `const_set`, which the
        # project-wide `constant_writers` a reader consults leaves out.
        def loose_constant?(segment)
          self.loose_constants ||= ScopeIndexer.loose_constant_segments(root)
          loose_constants.include?(segment)
        end

        # Issue #1820 — does `node` sit inside a block or lambda of this tree? A block's `self` may be an object even in
        # a class body or at the top level (`s.instance_eval { … }`, a `define_method` block). The spans are found once
        # per file, on the first ask.
        def in_block?(node)
          self.block_spans ||= ScopeIndexer.block_spans(root)
          offset = node.location.start_offset
          block_spans.any? { |start, stop| offset >= start && offset < stop }
        end

        # Sets {#certain} for the contribution `node` and returns the tables.
        def at(node)
          self.certain = !Certainty.possible?(certainty, node)
          self
        end

        # The `{sibling name => table}` part this walk fills, frozen, with the shared empty value for each
        # sibling nothing wrote.
        def siblings
          empty = Scope::DiscoveryIndex::EMPTY_SIBLINGS
          {
            possible_discovered_methods:
              possible ? possible.transform_values(&:freeze).freeze : empty[:possible_discovered_methods],
            contested_discovered_def_nodes:
              frozen_paths(contested_def_nodes) || empty[:contested_discovered_def_nodes],
            contested_discovered_parameter_envelopes:
              frozen_paths(contested_envelopes) || empty[:contested_discovered_parameter_envelopes]
          }.freeze
        end

        private

        def frozen_paths(set)
          return nil if set.nil? || set.empty?

          set.each(&:freeze).freeze
        end
      end

      EMPTY_REFINEMENTS = {}.freeze
      REFINEMENT_WILDCARD = Scope::DiscoveryIndex::REFINEMENT_WILDCARD
      REFINE_WORD = /\brefine\b/
      HEREDOC_OPENER = /<<[~-]?["'`A-Za-z_]/
      COMPARISON_OPERATORS = Set[:==, :!=, :===].freeze
      private_constant :EMPTY_REFINEMENTS, :REFINEMENT_WILDCARD, :REFINE_WORD, :HEREDOC_OPENER, :COMPARISON_OPERATORS

      NO_OFFSETS = [].freeze
      private_constant :NO_OFFSETS

      # The byte offsets of the `refine` words in `root`'s text (none for no tree), which `MethodTables#refine_in?`
      # matches node offsets against.
      def refine_word_offsets(root) = pattern_offsets(root, REFINE_WORD)

      # The byte offsets of the heredoc openers (`<<~ID`, `<<-ID`, `<<ID`, `<<"ID"`) in `root`'s text: a heredoc's body
      # follows its line, so it may end after the `def` that opens it.
      def heredoc_offsets(root) = pattern_offsets(root, HEREDOC_OPENER)

      def pattern_offsets(root, pattern)
        return NO_OFFSETS if root.nil?

        # Byte-wise: a file may hold bytes its encoding does not (binary `__END__` data, a stray comment byte), and a
        # regexp over such a String raises.
        binary = root.send(:source).source.b
        return NO_OFFSETS unless pattern.match?(binary)

        offsets = []
        position = 0
        while (match = pattern.match(binary, position))
          offsets << match.begin(0)
          position = match.end(0)
        end
        offsets.freeze
      end

      # The `[start, end)` byte span of every block and lambda in `root`.
      def block_spans(root)
        spans = []
        return spans if root.nil?

        Source::NodeWalker.each(root) do |node|
          next unless node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode)

          location = node.location
          spans << [location.start_offset, location.end_offset]
        end
        spans
      end

      # Is one of the ascending `offsets` in `[start, stop)`?
      def offset_in?(offsets, start, stop)
        index = offsets.bsearch_index { |offset| offset >= start }
        !index.nil? && offsets[index] < stop
      end

      # A6 — the last segments of the constants `root` binds by `||=` (`K ||= String`, `A::K ||= …`) or by a
      # `const_set` whose name is a literal (`Object.const_set(:K, String)`), and (issue #1749) by any write in a
      # `class << …` body: the project-wide constant census files a write there under no name a `refine` argument
      # spells, but a `def` in that body reads it lexically (`class << self; K = String; def setup = refine(K) {…}`).
      # Scanned only for a file with a literal-target `refine`.
      def loose_constant_segments(root)
        segments = Set.new
        Source::NodeWalker.each(root) do |node|
          case node
          when Prism::ConstantOrWriteNode then segments << node.name.to_s
          when Prism::ConstantPathOrWriteNode then segments << node.target.name.to_s
          when Prism::SingletonClassNode then singleton_constant_segments(node.body, segments)
          when Prism::CallNode
            name = node.name == :const_set && node.arguments&.arguments&.first
            segments << name.unescaped if name.is_a?(Prism::SymbolNode) || name.is_a?(Prism::StringNode)
          end
        end
        segments
      end

      # The last segment of every constant a write, an operator write or a multiple assignment target in `body` binds.
      def singleton_constant_segments(body, segments)
        return if body.nil?

        Source::NodeWalker.each(body) do |node|
          case node
          when Prism::ConstantWriteNode, Prism::ConstantTargetNode, Prism::ConstantOperatorWriteNode,
               Prism::ConstantAndWriteNode, Prism::ConstantPathTargetNode
            segments << node.name.to_s
          when Prism::ConstantPathWriteNode, Prism::ConstantPathOperatorWriteNode, Prism::ConstantPathAndWriteNode
            segments << node.target.name.to_s
          end
        end
      end

      # ADR-121 WD7 — the census gate's view of one parsed file (`root`): `[refinement table, [[start offset,
      # outcome], …]]`, one pair for every `refine`-shaped node the method walk accounted for. The outcomes are
      # `:recorded` (a literal target and block, its names recorded; also one in a module's own singleton method,
      # #1749), `:class_unknown` (a block whose target the walk cannot name), `:targets_wildcard` (a `refine` that
      # runs once a method is called, other than a module's own singleton method's, or in a block that may rebind
      # `self`, charged to its module or the wildcard), `:literal` (A3's `:refine` / eval-string literal), `:nested` (a
      # `refine` in a refine body, or in a singleton method of one), `:dsl` (where `self` is a class, #1689) and
      # `:raises` (no block, a Proc as the block, another receiver, or a computed target where `self` is `main`), and
      # `:data` (a `:refine` literal where `self` is a plain class or one of its instances), and `:inert` (issue #2203:
      # a `:refine` Symbol that is a hash key or a comparison operand, which no call reads as a method name).
      def refine_census(root)
        census = []
        refinements = build_methods_and_def_nodes(root, census: census)[3]
        [refinements, census]
      end

      # ADR-121 WD7 (issue #1814) — the refinement table one parsed file contributes: the census of
      # {#build_methods_and_def_nodes}, whose fourth table is the project walk's own (`seed_discovered_methods` and
      # `walk_def_contributions` take it from the same call), run for a caller that wants nothing else. The gem source
      # walker reads a gem file this way, so a gem module's rows carry the wildcards a project module's would
      # (`walker_walk_census_parity_spec.rb`, beside the walker's specs, holds the two to one table). A file whose text
      # never names `refine` as a word records no row, so it is not walked. `source_path` names an anonymous module's
      # row (`#<Module:<path>:L:C>`) as the project walk does, so two files' bare `Module.new` blocks never share one.
      def refinement_table(root, source_path = nil)
        return EMPTY_REFINEMENTS if refine_word_offsets(root).empty?

        build_methods_and_def_nodes(root, source_path)[3]
      end

      # Issue #1120 — a refinement table, deep-frozen; the shared empty table when nothing was recorded.
      def freeze_refinements(table)
        return EMPTY_REFINEMENTS if table.nil? || table.empty?

        table.each_value { |methods| methods.each_value(&:freeze).freeze }.freeze
      end

      # Issue #1120 — unions `overlay` into a copy of `base`, per refined class and method. Used for the per-file
      # overlay on the cross-file seed and for the project fold, so both answer the same union.
      def merge_refinement_tables(base, overlay)
        return base if overlay.nil? || overlay.empty?
        return overlay if base.nil? || base.empty?

        base.merge(overlay) do |_class_name, base_methods, overlay_methods|
          base_methods.merge(overlay_methods) { |_method, left, right| (left + right).uniq.freeze }.freeze
        end.freeze
      end

      # Issue #1120 — the constant a `refine X do … end` call refines, or nil when the call is not that shape: an
      # implicit- or `self`-receiver `refine` with one constant argument and a literal block. A computed target
      # (`refine(klass) { … }`) names no class this walk can key, so its body walks as it did before.
      def refine_target(node)
        return nil unless refine_call?(node)

        arguments = node.arguments&.arguments
        return nil unless arguments&.size == 1

        target = arguments.first
        target if target.is_a?(Prism::ConstantReadNode) || target.is_a?(Prism::ConstantPathNode)
      end

      # An implicit- or `self`-receiver `refine` call with a literal block, whatever its argument.
      def refine_call?(node)
        node.name == :refine && node.block.is_a?(Prism::BlockNode) &&
          (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
      end

      # Issue #1689 — {#refine_target}, for a call that `in_effect` (its file's {InEffectRefinements}) does not place
      # where `self` is a class. `Class` undefines `refine`, so `refine X do … end` directly in a `class` body is the
      # class's own method (a DSL), and its block walks as any other block. Every walk that treats a refine body
      # specially asks this, so the method tables, the in-effect refinements and the typer agree on which calls are
      # refine bodies.
      def module_refine_target(node, in_effect)
        target = refine_target(node)
        target unless target.nil? || in_effect.class_body_refine?(node)
      end

      # Issue #1120 — records the instance `def`s of a `refine X do … end` body as refinement methods of X, keyed by
      # the refining module (`refining`, the `self` the `refine` call runs on). X is resolved LEXICALLY
      # (`qualified_prefix`), which is where Ruby resolves the argument even inside a `Module.new { … }` block
      # whose `self` is anonymous; every name it can denote is recorded, as {#constant_receiver_candidates}
      # explains. Nothing in the body reaches the class tables: `refine String do def shout` does not give
      # `String` or the refining module a `shout` outside a `using`.
      #
      # ADR-121 WD7 (issue #1799) — the names are what {RefineCensus.read_body} reads (`def`, `alias`,
      # `alias_method`, `define_method`, `attr_*`, `undef`), and a body that may define a name it cannot spell adds a
      # names-wildcard row per target. `refining` is `""` at the top level (where Ruby raises). The body is not
      # walked any further, so the census scans it here.
      #
      # A6 — a target this file binds by `||=` or a literal `const_set` (`K ||= String; refine(K)`) names whatever value
      # the write holds, so its names go under the wildcard class, as a computed target's do.
      def record_refinement_defs(node, target, qualified_prefix, refining, tables)
        loose = tables.loose_constant?(target.name.to_s)
        tables.account(node, loose ? :class_unknown : :recorded, census_charge(refining))
        body = node.block.body
        return if body.nil?

        targets = loose ? [REFINEMENT_WILDCARD] : constant_receiver_candidates(target, qualified_prefix)
        reading = RefineCensus.read_body(body)
        refining.each do |owner|
          tables.refinements = RefineCensus.record_rows(tables.refinements, targets, reading, owner)
        end
        census_scan(body, qualified_prefix, tables, refine_body: true) if tables.mentions_refine?
      end

      # What the census records as charged for `owners`: the one module, or every name.
      def census_charge(owners) = owners.size == 1 ? owners.first : owners

      # ADR-121 WD7 — a literal-target `refine X do … end` the module-body walk reaches, charged where the in-effect
      # walk says it runs ({MethodTables#refine_context}): rows for the module it names (the walk's own name for an
      # anonymous `Module.new` block, `""` at the top level), or a targets-wildcard for that module (the wildcard
      # where it cannot be named) when it runs only once a method is called or on a module the walk cannot name.
      def record_literal_target_refine(node, target, qualified_prefix, owner_prefix, tables)
        context = tables.refine_context(node)
        here = context.here
        return record_refinement_defs(node, target, qualified_prefix, [""], tables) if here == RefineSelf::MAIN
        if context.deferred || here == REFINEMENT_WILDCARD
          return record_deferred_refine(node, RefineSelf.charged_modules(context), qualified_prefix, tables)
        end

        record_refinement_defs(node, target, qualified_prefix, census_owners(context, owner_prefix), tables)
      end

      # The modules a `refine` charged to `context` refines for; an anonymous `Module.new` block's is named by its
      # position (`owner_prefix`).
      def census_owners(context, owner_prefix)
        context.here == RefineSelf::ANONYMOUS ? [owner_prefix.join("::")] : RefineSelf.charged_modules(context)
      end

      # ADR-121 WD7 — a targets-wildcard for each of `owners`, as a `refine` that runs once a method is called records
      # (an instance `def`, a `define_method` or `define_singleton_method` block; a module's own singleton method
      # records rows instead, #1749). The body is not walked any further, so the census scans it here.
      def record_deferred_refine(node, owners, qualified_prefix, tables)
        tables.account(node, :targets_wildcard, census_charge(owners))
        owners.each { |owner| record_targets_wildcard(tables, owner) }
        body = node.block.body
        census_scan(body, qualified_prefix, tables, refine_body: true) if body && tables.mentions_refine?
      end

      # ADR-121 WD7 — a `refine`-shaped call the canonical arm ({#refine_target}) does not take: on another receiver
      # (`Module#refine` is private, so it raises), where `self` is a class (#1689's DSL), with no literal block (no
      # block raises, and so does a Proc passed as one), or with a target the walk cannot name (`refine(k)`,
      # `refine(self)`, `refine(K.dup)`). The last records the body's names under the wildcard class, so they decline
      # on every receiver, and a names-wildcard row when they are incomplete, which makes the module opaque; one that
      # runs once a method is called, or on a module the walk cannot name, records a targets-wildcard. At the top
      # level `self` is `main`, which has no `refine`.
      def account_other_refine(node, owner_prefix, tables)
        context = tables.refine_context(node)
        outcome, charged =
          if tables.class_body_refine?(node) || context.here == RefineSelf::CLASS then :dsl
          elsif !RefineCensus.self_call?(node) || !node.block.is_a?(Prism::BlockNode) ||
                context.here == RefineSelf::MAIN
            :raises
          elsif context.deferred || context.here == REFINEMENT_WILDCARD
            owners = RefineSelf.charged_modules(context)
            owners.each { |owner| record_targets_wildcard(tables, owner) }
            [:targets_wildcard, census_charge(owners)]
          else
            owners = census_owners(context, owner_prefix)
            owners.each { |owner| record_unreadable_target(node, owner, tables) }
            [:class_unknown, census_charge(owners)]
          end
        tables.account(node, outcome, charged)
      end

      def record_unreadable_target(node, owner, tables)
        tables.refinements = RefineCensus.record_rows(tables.refinements, [REFINEMENT_WILDCARD],
                                                      RefineCensus.read_body(node.block.body), owner)
      end

      # `{"*" => {"*" => [owner]}}`: some `refine` of `owner` (every module, for the wildcard) is unreadable.
      def record_targets_wildcard(tables, owner)
        tables.refinements = RefineCensus.add_row(tables.refinements || {}, REFINEMENT_WILDCARD, REFINEMENT_WILDCARD,
                                                  owner)
      end

      # ADR-121 WD7 — the census over a subtree the method walk does not descend (a `def` body, a refine body), each
      # node charged where the in-effect walk says it runs. `refine_body` says `self` is the refinement itself, where a
      # nested `refine` refines for the refinement and only makes the body's names incomplete (§2.2).
      def census_scan(node, qualified_prefix, tables, refine_body: false)
        case node
        when Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode
          refine_body = false
        when Prism::CallNode
          if (target = own_method_refine_target(node, tables))
            return record_own_method_refine(node, target, qualified_prefix, tables)
          end

          census_call(node, qualified_prefix, tables, refine_body)
        when Prism::AssocNode
          census_assoc_key(node, tables)
        when Prism::SymbolNode
          census_symbol(node, tables)
        end
        node.rigor_each_child { |child| census_scan(child, qualified_prefix, tables, refine_body: refine_body) }
      end

      # ADR-121 WD7 (issue #1749) — the target of a canonical `refine X do … end` ({#refine_target}) in a module's own
      # singleton method (`def self.x`, a `def` in the module's `class << self`, or a block there that keeps `self`),
      # else nil. `self` is the module itself there, so the call refines X for it once the method is called. Anything
      # else in a method body (an instance `def`, a `define_method` or `define_singleton_method` block, a computed
      # target, a block that may rebind `self`) charges a targets-wildcard in {#census_call}, and a `refine` in a refine
      # body is nested there, whichever method it sits in: its context ({RefineSelf.refinement_body}) is not an
      # own method's.
      def own_method_refine_target(node, tables)
        return nil if node.name != :refine

        target = tables.refine_target_of(node)
        target if target && tables.refine_context(node).own_method
      end

      # Records `node` as the refine of its module, as a `refine` in the module body is recorded, with the refined
      # class marked as that one is ({#record_refinement}). The call's block is scanned here, so {#census_scan} does
      # not descend into it.
      def record_own_method_refine(node, target, qualified_prefix, tables)
        record_refinement(node, qualified_prefix, tables)
        owners = RefineSelf.charged_modules(tables.refine_context(node))
        record_refinement_defs(node, target, qualified_prefix, owners, tables)
      end

      def census_call(node, qualified_prefix, tables, refine_body)
        census_literal_arguments(node, qualified_prefix, tables)
        return unless node.name == :refine

        context = tables.refine_context(node)
        nested = refine_body || context.here == RefineSelf::REFINEMENT
        outcome, charged =
          if tables.class_body_refine?(node) || context.here == RefineSelf::CLASS then :dsl
          elsif nested && RefineCensus.self_call?(node) then :nested
          elsif !RefineCensus.self_call?(node) || node.block.nil? || context.here == RefineSelf::MAIN then :raises
          else
            owners = RefineSelf.charged_modules(context)
            owners.each { |owner| record_targets_wildcard(tables, owner) }
            [:targets_wildcard, census_charge(owners)]
          end
        tables.account(node, outcome, charged)
      end

      # A3 — a `:refine` Symbol argument of any call, or a String argument holding `refine` of an eval, `send` or
      # method-naming call, records a targets-wildcard for the module the call runs `refine` on: the receiver of a
      # `send` or `*_eval` (each name a constant one can denote), else the module the in-effect walk says `self` is
      # there. Where `self` is a plain class or one of its instances, a literal charged to `self` is data.
      def census_literal_arguments(node, qualified_prefix, tables)
        arguments = node.arguments&.arguments
        return if arguments.nil?

        return census_compared_literal(arguments.first, tables) if COMPARISON_OPERATORS.include?(node.name)

        strings = RefineCensus.string_literal_call?(node)
        arguments.each do |argument|
          next unless RefineCensus.refine_symbol?(argument) || (strings && RefineCensus.refine_string?(argument))
          next if tables.literal_seen?(argument)

          tables.see_literal(argument)
          census_literal_argument(node, argument, qualified_prefix, tables)
        end
      end

      def census_literal_argument(call, literal, qualified_prefix, tables)
        target = RefineCensus.literal_target(call)
        context = tables.refine_context(literal)
        return tables.account(literal, :data) if target == :self && context.literal == RefineSelf::CLASS
        return tables.account(literal, :nested) if target == :self && context.literal == RefineSelf::REFINEMENT

        owners = literal_owners(call, target, RefineSelf.charged_modules(context, literal: true), qualified_prefix)
        owners.each { |owner| record_targets_wildcard(tables, owner) }
        tables.account(literal, :literal, target == :self ? census_charge(owners) : [:receiver, owners])
      end

      def literal_owners(call, target, self_modules, qualified_prefix)
        case target
        when :self then self_modules
        when :unknown then [REFINEMENT_WILDCARD]
        else
          receiver = call.receiver
          names = constant_shaped?(receiver) ? constant_receiver_candidates(receiver, qualified_prefix) : []
          names.empty? ? [REFINEMENT_WILDCARD] : names
        end
      end

      def constant_shaped?(node) = node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

      # Issue #2203 — a `:refine` Symbol a comparison reads (`node.name == :refine`, `!=`, `===`) is a value compared,
      # never a method name a call runs: it is inert (`:inert`), and records no row.
      def census_compared_literal(argument, tables)
        return unless RefineCensus.refine_symbol?(argument) && !tables.literal_seen?(argument)

        tables.see_literal(argument)
        tables.account(argument, :inert)
      end

      # Issue #2203 — a `:refine` Symbol that is a hash key (`h(x, refine: true)`, `{ refine: 1 }`, `{ :refine => 1 }`)
      # names an option, not `Module#refine`: it is inert (`:inert`), and records no row. A `:refine` value stays a
      # literal.
      def census_assoc_key(node, tables)
        key = node.key
        return unless RefineCensus.refine_symbol?(key) && !tables.literal_seen?(key)

        tables.see_literal(key)
        tables.account(key, :inert)
      end

      # A3 — a `:refine` Symbol anywhere else (`alias my_refine refine`, `%i[refine]`, a hash) names `Module#refine`
      # for code the walk cannot follow, run on the module the in-effect walk says `self` is there; where `self` is a
      # plain class or one of its instances it is data.
      def census_symbol(node, tables)
        return unless RefineCensus.refine_symbol?(node) && !tables.literal_seen?(node)

        tables.see_literal(node)
        context = tables.refine_context(node)
        return tables.account(node, :data) if context.literal == RefineSelf::CLASS
        return tables.account(node, :nested) if context.literal == RefineSelf::REFINEMENT

        owners = RefineSelf.charged_modules(context, literal: true)
        owners.each { |owner| record_targets_wildcard(tables, owner) }
        tables.account(node, :literal, census_charge(owners))
      end

      # The instance `def`s a refine body defines on the refined class: nested declarations open their own
      # scope, and a `def self.x` or a `def` inside another `def` defines nothing on it.
      def each_refinement_def(node, &)
        case node
        when Prism::DefNode
          yield node if node.receiver.nil?
          return
        when Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode
          return
        end

        node.rigor_each_child { |child| each_refinement_def(child, &) }
      end

      # The walk's single existence writer. Everything except a `def` passes no envelope and so records
      # {Source::ParameterEnvelope::OPAQUE}.
      #
      # ADR-119 WD3 — the existence table's `possible` sibling follows the contribution's certainty
      # ({MethodTables#certain}): a certain contribution removes its kind from the name's possible kind, and a
      # possible one adds its kind unless the table already answered that kind certainly. A possible contribution
      # also contests the envelope entry it joins (envelopes are joined, so one possible joiner is enough).
      def record_method(tables, class_name, method_name, kind, envelope = Source::ParameterEnvelope::OPAQUE)
        follow_method_certainty(tables, class_name, method_name, kind) unless tables.certain && tables.possible.nil?
        record_method_kind(tables.existence, class_name, method_name, kind)
        record_envelope(tables.envelopes, class_name, [kind, method_name], envelope)
        contest_envelope(tables, class_name, [kind, method_name]) unless tables.certain
      end

      # The `possible_discovered_methods` half of {#record_method}, read BEFORE the existence table is written.
      def follow_method_certainty(tables, class_name, method_name, kind)
        if tables.certain
          settle_possible_kind(tables.possible, class_name, method_name, kind)
        else
          sitting = tables.possible&.dig(class_name, method_name)
          return if kind_covers?(tables.existence[class_name]&.[](method_name), kind) && !kind_covers?(sitting, kind)

          row = ((tables.possible ||= {})[class_name] ||= {})
          row[method_name] = merge_sibling_kind(sitting, kind)
        end
      end

      # A certain contribution: `kind` leaves the name's possible kind, and an emptied row goes.
      def settle_possible_kind(possible, class_name, method_name, kind)
        row = possible[class_name]
        return if row.nil?

        remaining = without_kind(row[method_name], kind)
        return if remaining == row[method_name]

        remaining.nil? ? row.delete(method_name) : (row[method_name] = remaining)
        possible.delete(class_name) if row.empty?
      end

      # Whether a recorded kind (`:instance`, `:singleton`, `:both`, or nil) answers `kind`.
      def kind_covers?(recorded, kind)
        !recorded.nil? && (recorded == kind || recorded == Scope::DiscoveryIndex::METHOD_KIND_BOTH)
      end

      # `recorded` less `kind`: nil when nothing remains.
      def without_kind(recorded, kind)
        return nil if recorded.nil? || recorded == kind
        return recorded unless recorded == Scope::DiscoveryIndex::METHOD_KIND_BOTH

        kind == :instance ? :singleton : :instance
      end

      def contest_envelope(tables, class_name, key)
        (tables.contested_envelopes ||= Set.new) << [class_name, key]
      end

      def record_envelope(envelopes, class_name, key, envelope)
        table = (envelopes[class_name] ||= {})
        table[key] = Source::ParameterEnvelope.merge(table[key], envelope)
      end

      def record_surface_mark(tables, class_name, mark)
        record_envelope(tables.envelopes, class_name, mark, Source::ParameterEnvelope::OPAQUE)
      end

      # Merges two `class_name => { method => kind }` tables, unioning the per-class method maps (so a seeded cross-file
      # table and the current file's table combine instead of clobbering). A name recorded on both sides — an instance
      # `def` here and a `class << self` twin there — merges to {Scope::DiscoveryIndex::METHOD_KIND_BOTH} rather than
      # letting the overlay's kind win (#239).
      def deep_merge_class_methods(base, overlay)
        return overlay if base.nil? || base.empty?
        return base if overlay.empty?

        base.merge(overlay) do |_class_name, base_methods, overlay_methods|
          merge_method_kinds(base_methods, overlay_methods)
        end
      end

      # `{ method => kind }` union that promotes a kind disagreement to `METHOD_KIND_BOTH` instead of clobbering.
      def merge_method_kinds(base_methods, overlay_methods)
        base_methods.merge(overlay_methods) do |_method_name, base_kind, overlay_kind|
          base_kind == overlay_kind ? base_kind : Scope::DiscoveryIndex::METHOD_KIND_BOTH
        end
      end

      # The single write path into a `class_name => { method => kind }` existence table. Every recorder goes through
      # it so a class that defines one name on both sides keeps both facts: the table is keyed by name alone, so a
      # bare assignment silently replaced the other side's kind and `Scope#discovered_method?` then answered false for
      # a method the source plainly defines (#239).
      def record_method_kind(accumulator, class_name, method_name, kind)
        table = (accumulator[class_name] ||= {})
        recorded = table[method_name]
        table[method_name] =
          if recorded.nil? || recorded == kind
            kind
          else
            Scope::DiscoveryIndex::METHOD_KIND_BOTH
          end
      end

      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength
      # Combined methods / def-nodes descent: both tables share one class / module / singleton-class / meta-block
      # traversal that stops at `DefNode`; only the leaf actions differ (each recorded into its own accumulator). An
      # `AliasMethodNode` is not descended (its symbol-only children carry no def / class node). See
      # {#build_methods_and_def_nodes}.
      # `def_owner_prefix` overrides the prefix def-ish leaves record under — inside a
      # `*_eval` / `*_exec` block body it is the receiver's prefix while `qualified_prefix`
      # stays LEXICAL: `Module.nesting` does not change in an eval block, so `def` binds
      # to the receiver but `class` / `module` / constant writes still file under the
      # enclosing namespace. Declaration branches recurse with the override cleared —
      # inside `X.class_eval { class Inner; def h }` the def belongs to `M::Inner` again.
      # A `self::`-headed declaration inside an eval body (`class self::Inner`) is the one
      # header whose runtime target ISN'T lexical — self is the receiver there — but every
      # declaration walk ({Source::ConstantPath.pushed_nesting} callers, the evaluator among
      # them) qualifies headers against the lexical prefix uniformly. Keeping this walk on
      # the same approximation is the consistent answer; resolving it here alone would split
      # the def tables from the declaration tables they must agree with.
      def walk_methods_and_def_nodes(node, qualified_prefix, in_singleton_class, methods_acc, def_nodes_acc, # rubocop:disable Metrics/AbcSize, Metrics/ParameterLists, Metrics/PerceivedComplexity
                                     source_path = nil, def_owner_prefix = nil, singleton_cref: false,
                                     defs_singleton: false)
        return unless node.is_a?(Prism::Node)

        owner_prefix = def_owner_prefix || qualified_prefix
        case node
        when Prism::ClassNode, Prism::ModuleNode
          # Inside a `class <<` body `self` IS the singleton class — a `self::` header
          # always names `#<singleton>::Name`, which nothing can spell.
          self_base = in_singleton_class ? EMPTY_PREFIX : def_owner_prefix
          self_decl = DeclarationWalk::Rules.self_anchored_decl_prefix(node.constant_path, self_base)
          child_prefix = self_decl ||
                         Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
          if child_prefix
            # Under an unnameable cref a bare/`self::` header opens `#<singleton>::Name` —
            # a class object nothing can spell — so the body walks ownerless rather
            # than filing `C::D` facts. nameable headers re-anchor at a real cref. A
            # `self::` header under a REBOUND self (eval/meta-new body) names
            # `owner::Name` instead.
            child_cref = DeclarationWalk::Rules.unnameable_decl?(node, self_decl, singleton_cref)
            if node.is_a?(Prism::ClassNode) && node.superclass && methods_acc.mentions_refine?
              census_scan(node.superclass, qualified_prefix, methods_acc)
            end
            record_declaration_facts(node, child_prefix, methods_acc.at(node)) unless child_cref
            unless child_cref
              methods_acc.mark_hook_blocks(concern_hook_blocks(node, child_prefix), child_prefix)
              record_concern_class_methods(node, child_prefix, methods_acc, def_nodes_acc)
              record_hook_definer_calls(node, child_prefix, methods_acc)
            end
            body_prefix = child_cref ? [] : child_prefix
            if node.body
              walk_methods_and_def_nodes(node.body, body_prefix, false, methods_acc, def_nodes_acc,
                                         source_path, nil, singleton_cref: child_cref)
            end
            return
          end
        when Prism::SingletonClassNode
          # `class << self` inside an eval body opens the RECEIVER's singleton — self is
          # the eval receiver there — so the override supplies the base, not the lexical
          # prefix. `class << <non-constant>` opens a singleton the walk cannot name —
          # its body walks ownerless, keeping the singleton marker so `self::` receivers
          # still decline. The lexical cref below is unnameable in every case.
          singleton_prefix = singleton_body_prefix(node, in_singleton_class, owner_prefix,
                                                   qualified_prefix)
          tables = methods_acc.at(node)
          if !node.expression.is_a?(Prism::SelfNode) || tables.in_block?(node)
            record_singleton_body_prepends(node, qualified_prefix, tables)
          end
          record_constant_singleton_prepends(node, qualified_prefix, tables)
          walk_methods_and_def_nodes(node.expression, qualified_prefix, in_singleton_class,
                                     methods_acc, def_nodes_acc, source_path, def_owner_prefix,
                                     singleton_cref: singleton_cref,
                                     defs_singleton: defs_singleton)
          if node.body && !hook_block_singleton?(node, in_singleton_class, owner_prefix, methods_acc)
            # The body's lexical cref is unnameable AND its qualified prefix stays the
            # ENCLOSING lexical one — `class C3::CD` below `class <<` resolves `C3`
            # lexically, never against the singleton's name. `singleton_prefix` rides
            # the def-owner channel instead: `def s` still records `C3::K.s`, while
            # `[]` (an unnameable singleton) files the body's defs nowhere.
            walk_methods_and_def_nodes(node.body, qualified_prefix, true, methods_acc,
                                       def_nodes_acc, source_path, singleton_prefix,
                                       singleton_cref: true)
          end
          return
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
             Prism::ConstantPathOrWriteNode
          record_meta_superclass(node, qualified_prefix, def_owner_prefix, methods_acc.at(node))
          record_struct_same_class(node, qualified_prefix, def_owner_prefix, methods_acc.at(node))
          if (split = DeclarationWalk::Rules.meta_new_block_split(node, qualified_prefix, def_owner_prefix,
                                                                  singleton_cref))
            enclosing, body, body_self = split
            # A meta-new block rebinds only `self` — `Module.nesting` stays lexical — so
            # declarations inside keep the ENCLOSING prefix and cref, while `def`-family
            # leaves record under the class the write names. An unnameable write (bare
            # `K =` under `class <<`, or a dynamic base) gives an empty owner prefix:
            # the block's class is anonymous and its defs belong to no nameable class.
            child_prefix = DeclarationWalk::Rules.meta_new_child_prefix(node, qualified_prefix, def_owner_prefix)
            meta_ownerless = singleton_cref &&
                             !DeclarationWalk::Rules.meta_new_path_target_nameable?(node, def_owner_prefix)
            if child_prefix && !meta_ownerless
              record_meta_new_facts(DeclarationWalk::Rules.meta_new_rvalue(node), child_prefix, methods_acc.at(node))
            end
            enclosing.each do |part|
              walk_methods_and_def_nodes(part, qualified_prefix, in_singleton_class, methods_acc,
                                         def_nodes_acc, source_path, def_owner_prefix,
                                         singleton_cref: singleton_cref,
                                         defs_singleton: defs_singleton)
            end
            if body
              walk_methods_and_def_nodes(body, qualified_prefix, false, methods_acc,
                                         def_nodes_acc, source_path, body_self,
                                         singleton_cref: singleton_cref)
            end
            # No anonymous registration here: the constant IS the name, and `StatementEvaluator#eval_constant_write`
            # enters the body under it (#590) by asking THIS recognition (`DeclarationWalk::Rules.meta_new_block_body`),
            # so the two passes agree on the constant name alone.
            return
          end
        when Prism::DefNode
          # `defs_singleton` is the instance_eval split: `def`/`alias` bind on the receiver's
          # singleton while `define_method`/`attr_*` calls stay instance-side. An empty owner
          # prefix — an explicit `[]` def-owner (anonymous factory block, declined eval
          # receiver, a singleton nothing names) or any ownerless prefix under an unnameable
          # cref — is NOT top level; `record_def_node` would file the def under `<toplevel>`
          # where an implicit-self call could find a method Ruby never installed there.
          location = node.location
          if methods_acc.mentions_refine? && methods_acc.refine_in?(location.start_offset, location.end_offset)
            node.rigor_each_child { |child| census_scan(child, qualified_prefix, methods_acc) }
          end
          record_foreign_singleton_def(node, qualified_prefix, owner_prefix, methods_acc.at(node))
          return if methods_acc.hook_block_self_def?(node, owner_prefix)

          unless def_owner_prefix&.empty? || defs_singleton == :unnameable ||
                 (singleton_cref && owner_prefix.empty?)
            singleton_def = def_context(in_singleton_class, defs_singleton)
            record_def_method(node, owner_prefix, singleton_def, methods_acc.at(node))
            record_def_body_evidence(node, owner_prefix, methods_acc, singleton_def ? :singleton : :instance)
            record_def_node(node, owner_prefix, singleton_def, def_nodes_acc, methods_acc)
          end
          return
        when Prism::AliasMethodNode, Prism::UndefNode
          census_scan(node, qualified_prefix, methods_acc) if methods_acc.mentions_refine?
          unless def_owner_prefix&.empty? || defs_singleton == :unnameable ||
                 (singleton_cref && owner_prefix.empty?)
            record_alias_or_undef(node, owner_prefix, in_singleton_class || defs_singleton,
                                  methods_acc.at(node))
            if node.is_a?(Prism::AliasMethodNode) && !(in_singleton_class || defs_singleton)
              supersede_def_nodes(Array(Source::AliasNames.keyword_names(node)&.first), owner_prefix,
                                  def_nodes_acc, methods_acc.at(node))
            end
          end
          return
        when Prism::AssocNode
          census_assoc_key(node, methods_acc) if methods_acc.mentions_refine?
        when Prism::SymbolNode
          census_symbol(node, methods_acc) if methods_acc.mentions_refine?
        when Prism::CallNode
          census_literal_arguments(node, qualified_prefix, methods_acc) if methods_acc.mentions_refine?
          if DeclarationWalk::Rules.receiver_eval_call?(node)
            record_singleton_eval_definers(node, owner_prefix, in_singleton_class, methods_acc.at(node))
            record_constant_singleton_eval_defs(node, qualified_prefix, methods_acc.at(node))
            return walk_eval_methods_and_defs(node, qualified_prefix, in_singleton_class, methods_acc,
                                              def_nodes_acc, source_path, def_owner_prefix,
                                              singleton_cref: singleton_cref,
                                              defs_singleton: defs_singleton)
          end
          anonymous = record_call_node_methods(node, owner_prefix, in_singleton_class, methods_acc.at(node),
                                               source_path)
          unless in_singleton_class
            superseded = call_superseded_names(node, owner_prefix, methods_acc)
            supersede_def_nodes(superseded, owner_prefix, def_nodes_acc, methods_acc.at(node))
            note_call_definers(node, superseded, owner_prefix, methods_acc.at(node))
          end
          tables = methods_acc.at(node)
          record_singleton_prepend(node, qualified_prefix, tables,
                                   self_ok: node.name == :prepend && tables.in_block?(node))
          own_prefix = def_owner_prefix&.empty? || defs_singleton == :unnameable ? EMPTY_PREFIX : owner_prefix
          record_own_singleton_prepend(node, [own_prefix, qualified_prefix], in_singleton_class, tables)
          # Issue #1120 — a refine body's defs go to the refinement table and nowhere else.
          if (target = methods_acc.refine_target_of(node))
            return record_literal_target_refine(node, target, qualified_prefix, owner_prefix, methods_acc)
          end

          account_other_refine(node, owner_prefix, methods_acc) if node.name == :refine

          if anonymous
            walk_anonymous_meta_block(node, anonymous, qualified_prefix, in_singleton_class, methods_acc,
                                      def_nodes_acc, source_path, def_owner_prefix,
                                      singleton_cref: singleton_cref,
                                      defs_singleton: defs_singleton)
            return
          end
        end

        node.rigor_each_child do |child|
          walk_methods_and_def_nodes(child, qualified_prefix, in_singleton_class, methods_acc, def_nodes_acc,
                                     source_path, def_owner_prefix, singleton_cref: singleton_cref,
                                                                    defs_singleton: defs_singleton)
        end
      end

      # {#walk_eval_singleton_defs}'s combined-walk twin: a `*_eval` / `*_exec` block's defs,
      # `attr_*`s and metaprogrammed methods belong to the RECEIVER's class — `X.class_eval {
      # attr_reader :a }` inside `module M` records `X#a`, not `M#a`. An unnameable receiver walks
      # the body ownerless rather than guessing the lexical class. Declarations
      # inside the block stay LEXICAL — `X.class_eval { class Inner }` inside `module M`
      # opens `M::Inner`, so the body walks under `qualified_prefix` with the receiver
      # prefix supplied as the def-owner override.
      def walk_eval_methods_and_defs(node, qualified_prefix, in_singleton_class, methods_acc, # rubocop:disable Metrics/ParameterLists
                                     def_nodes_acc, source_path, def_owner_prefix = nil,
                                     singleton_cref: false, defs_singleton: false)
        if node.receiver
          walk_methods_and_def_nodes(node.receiver, qualified_prefix, in_singleton_class, methods_acc,
                                     def_nodes_acc, source_path, def_owner_prefix,
                                     singleton_cref: singleton_cref,
                                     defs_singleton: defs_singleton)
        end
        node.arguments&.arguments&.each do |arg|
          walk_methods_and_def_nodes(arg, qualified_prefix, in_singleton_class, methods_acc,
                                     def_nodes_acc, source_path, def_owner_prefix,
                                     singleton_cref: singleton_cref,
                                     defs_singleton: defs_singleton)
        end
        self_prefix = def_owner_prefix || qualified_prefix
        unnameable = DeclarationWalk::Rules.unnameable_eval_self?(in_singleton_class, def_owner_prefix,
                                                                  qualified_prefix, singleton_cref)
        eval_prefix = DeclarationWalk::Rules.eval_receiver_prefix(node, self_prefix, qualified_prefix,
                                                                  unnameable_self: unnameable) || []
        # `instance_eval` splits the two surfaces: `def`/`alias` bind on the receiver's
        # singleton (`defs_singleton`), while `define_method`/`attr_*` are calls on the
        # receiver-as-module and install INSTANCE methods — `in_singleton_class` stays off
        # for a class receiver.
        call_singleton, defs_flag = eval_body_def_context(node, in_singleton_class)
        node.block.rigor_each_child do |child|
          walk_methods_and_def_nodes(child, qualified_prefix, call_singleton, methods_acc, def_nodes_acc,
                                     source_path, eval_prefix, singleton_cref: singleton_cref,
                                                               defs_singleton: defs_flag)
        end
      end

      # `class Foo < Struct.new(:a)` members, and issue #992's module mark for a `module` declaration.
      def record_declaration_facts(node, child_prefix, tables)
        if node.is_a?(Prism::ClassNode)
          record_meta_superclass_members(node, child_prefix, tables)
          record_constructed_superclass(node.superclass, child_prefix.join("::"), tables)
        else
          record_surface_mark(tables, child_prefix.join("::"), Scope::DiscoveryIndex::ENVELOPE_MODULE_MARK)
        end
      end

      # Issue #1979 — `class K < Data.define(:a)`, `< Struct.new(:a)` or `< Class.new(Parent)`: the superclass table
      # records `nil` for K, so a subclass walk enumerates it under every class. Each constant the expression names
      # (the factory's receiver, and `Class.new`'s argument, or `Object` for none) takes a
      # `[ENVELOPE_CONSTRUCTED_KIND, name]` entry; an expression of any other shape records none.
      def record_constructed_superclass(superclass, class_name, tables)
        names = constructed_superclass_names(superclass)
        names&.each do |name|
          record_envelope(tables.envelopes, class_name, [Scope::DiscoveryIndex::ENVELOPE_CONSTRUCTED_KIND, name],
                          Source::ParameterEnvelope::OPAQUE)
        end
      end

      def constructed_superclass_names(node)
        return ["Data"] if DeclarationWalk::Rules.meta_call_with_name?(node, :Data, :define)
        return ["Struct"] if DeclarationWalk::Rules.meta_call_with_name?(node, :Struct, :new)
        return nil unless DeclarationWalk::Rules.class_new_call?(node)

        arguments = node.arguments&.arguments || []
        return %w[Class Object] if arguments.empty?
        return nil unless arguments.one?

        argument = arguments.first
        inner = if argument.is_a?(Prism::ConstantReadNode) then [argument.name.to_s]
                else constructed_superclass_names(argument)
                end
        inner && ["Class", *inner]
      end

      # The block form of a meta-new constant write: its members, and the module mark `Module.new` earns.
      # Issue #1820 — `K = Class.new(Parent)`, with or without a block, names a class whose superclass the superclass
      # table leaves out; it takes {Scope::DiscoveryIndex::ENVELOPE_META_SUPERCLASS_MARK}.
      def record_meta_superclass(node, qualified_prefix, self_base, tables)
        rvalue = DeclarationWalk::Rules.meta_new_rvalue(node)
        return unless DeclarationWalk::Rules.class_new_call?(rvalue) && !(rvalue.arguments&.arguments || []).empty?

        child_prefix = DeclarationWalk::Rules.meta_new_child_prefix(node, qualified_prefix, self_base)
        return if child_prefix.nil? || child_prefix.empty?

        record_surface_mark(tables, child_prefix.join("::"), Scope::DiscoveryIndex::ENVELOPE_META_SUPERCLASS_MARK)
      end

      # Issue #2979 — `K = Struct.new("Named", :a)`, with or without a block, binds `K` and `Struct::Named` to one class
      # object, so each name's bucket takes a `[ENVELOPE_SAME_CLASS_KIND, other]` entry and the method chain of either
      # reads the other's tables (`Scope::ResolutionChain`). Only the bare factory call qualifies: under a wrapping
      # `Class.new(Struct.new("Named", :a))` the constant names a SUBCLASS of `Struct::Named`, which already reaches it
      # as an ancestor only one way.
      def record_struct_same_class(node, qualified_prefix, self_base, tables)
        rvalue = DeclarationWalk::Rules.meta_new_rvalue(node)
        return unless DeclarationWalk::Rules.struct_new_call?(rvalue)

        named = AnonymousMetaClass.struct_class_name(rvalue)
        return if named.nil?

        child_prefix = DeclarationWalk::Rules.meta_new_child_prefix(node, qualified_prefix, self_base)
        return if child_prefix.nil? || child_prefix.empty?

        class_name = child_prefix.join("::")
        kind = Scope::DiscoveryIndex::ENVELOPE_SAME_CLASS_KIND
        record_envelope(tables.envelopes, class_name, [kind, named], Source::ParameterEnvelope::OPAQUE)
        record_envelope(tables.envelopes, named, [kind, class_name], Source::ParameterEnvelope::OPAQUE)
      end

      def record_meta_new_facts(rvalue, child_prefix, tables)
        record_meta_members(rvalue, child_prefix, tables)
        # `Module.new(&BODY)`: the body runs on the new module but cannot be read, so its surface is unknown (#1816).
        if rvalue.block.is_a?(Prism::BlockArgumentNode)
          record_surface_mark(tables, child_prefix.join("::"), Scope::DiscoveryIndex::ENVELOPE_DYNAMIC_MARK)
        end
        return unless DeclarationWalk::Rules.module_new_call?(rvalue)

        record_surface_mark(tables, child_prefix.join("::"), Scope::DiscoveryIndex::ENVELOPE_MODULE_MARK)
      end

      def record_alias_or_undef(node, qualified_prefix, in_singleton_class, tables)
        if node.is_a?(Prism::UndefNode)
          record_undef(node, qualified_prefix, tables)
        else
          record_alias_method(node, qualified_prefix, in_singleton_class, tables)
        end
      end

      # The `Prism::CallNode` leaf actions of {#walk_methods_and_def_nodes}: the `define_method` / `attr_*` macro
      # recorders, plus the {AnonymousMetaClass} name of a class-creating meta call carrying a block (nil for
      # every other call), which the caller uses to decide whether the block body needs the anonymous-class-body
      # descent.
      def record_call_node_methods(node, qualified_prefix, in_singleton_class, methods_acc, source_path)
        record_define_method(node, qualified_prefix, in_singleton_class, methods_acc) if node.name == :define_method
        record_attr_methods(node, qualified_prefix, in_singleton_class, methods_acc) if attr_macro(node)
        record_module_attr_methods(node, qualified_prefix, methods_acc) if MODULE_ATTR_MACROS.key?(node.name)
        record_forwardable_methods(node, qualified_prefix, in_singleton_class, methods_acc)
        record_alias_method_call(node, qualified_prefix, in_singleton_class, methods_acc)
        record_surface_evidence(node, qualified_prefix, methods_acc)
        record_self_definer_call(node, qualified_prefix, in_singleton_class, methods_acc)
        AnonymousMetaClass.name_for(node, source_path)
      end

      # Issue #2901 — the class-body calls on `self` that open the class to `call.undefined-method` without a name
      # this walk can read: `send(:define_method, m)` (the instance side, or the singleton side in a `class << self`
      # body), `define_singleton_method(m)` (the singleton side, outside `class << self`, where it would define on the
      # singleton's own singleton), and a call of any other name, filed as a
      # {Scope::DiscoveryIndex::ENVELOPE_BODY_CALL_KIND} entry for the reader to resolve against the class's macros.
      def record_self_definer_call(node, qualified_prefix, in_singleton_class, accumulator)
        return if qualified_prefix.empty? || !(node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))

        class_name = qualified_prefix.join("::")
        if node.name == :define_singleton_method
          record_open_singleton_definer(node, class_name, in_singleton_class, accumulator)
          record_literal_self_definer(node, class_name, in_singleton_class, accumulator)
        elsif SURFACE_SEND_CALLS.include?(node.name)
          record_sent_define_method(node, class_name, in_singleton_class, accumulator)
          record_literal_self_definer(node, class_name, in_singleton_class, accumulator)
        elsif MODULE_NEW_MIXIN_CALLS.include?(node.name)
          record_module_new_mixin(node, class_name, in_singleton_class, accumulator)
        elsif !in_singleton_class && !BODY_CALL_EXCLUDED.include?(node.name)
          key = [Scope::DiscoveryIndex::ENVELOPE_BODY_CALL_KIND, node.name]
          record_envelope(accumulator.envelopes, class_name, key, Source::ParameterEnvelope::OPAQUE)
        end
      end

      # The class-body calls this walk reads as definers of their own, or that core's `Module` answers: a project
      # macro of one of these names is not looked for.
      BODY_CALL_EXCLUDED = %i[
        define_method define_singleton_method alias_method attr_reader attr_writer attr_accessor include extend prepend
        private public protected module_function private_class_method public_class_method private_constant
        public_constant require require_relative autoload autoload_relative
      ].to_set.freeze
      private_constant :BODY_CALL_EXCLUDED

      def record_open_singleton_definer(node, class_name, in_singleton_class, accumulator)
        return if in_singleton_class || !computed_first_name?(node.arguments&.arguments)

        record_surface_mark(accumulator, class_name, Scope::DiscoveryIndex::ENVELOPE_OPEN_SINGLETON_NAMES_MARK)
      end

      def record_sent_define_method(node, class_name, in_singleton_class, accumulator)
        arguments = node.arguments&.arguments
        return unless arguments && literal_method_name(arguments.first) == :define_method
        return unless computed_first_name?(arguments.drop(1))

        record_surface_mark(accumulator, class_name, open_names_mark(in_singleton_class))
      end

      # Issue #2975 — `include(Module.new { %i[a b].each { |x| define_method(x) {} } })` mixes in a module whose body
      # runs a computed `define_method` on its own `self`, so the side the mixin lands on (the instance side, or the
      # singleton side in a `class << self` body) is open as a direct `define_method(m)` there would leave it.
      def record_module_new_mixin(node, class_name, in_singleton_class, accumulator)
        return unless module_new_definer_argument?(node)

        record_surface_mark(accumulator, class_name, open_names_mark(in_singleton_class))
      end

      MODULE_NEW_MIXIN_CALLS = %i[include prepend].to_set.freeze
      private_constant :MODULE_NEW_MIXIN_CALLS

      # Whether a mixin call's argument is a `Module.new { … }` whose body runs a computed `define_method` on the
      # module ({#runs_computed_self_definer?}).
      def module_new_definer_argument?(node)
        (node.arguments&.arguments || []).any? do |argument|
          DeclarationWalk::Rules.module_new_call?(argument) && argument.block.is_a?(Prism::BlockNode) &&
            runs_computed_self_definer?(argument.block.body)
        end
      end

      # Issue #2975 — `singleton_class.class_eval { def my_attr(*n) = n.each { |x| define_method(x) {} } }` in a class
      # body, or the same on `Const.singleton_class`, defines a class macro the eval-body walk files under no owner: the
      # method takes the singleton-side definer entry {#record_computed_definer} gives a `def self.my_attr`.
      def record_singleton_eval_definers(node, qualified_prefix, in_singleton_class, tables)
        return if in_singleton_class || !CLASS_EVAL_BLOCK_CALLS.include?(node.name)

        receiver = node.receiver
        return unless singleton_class_of_receiver?(receiver)

        current = qualified_prefix.empty? ? nil : qualified_prefix.join("::")
        owner = singleton_class_owner(node, receiver.receiver, qualified_prefix, current)
        return if owner.nil?

        body = node.block.body
        return unless body.is_a?(Prism::StatementsNode)

        body.body.each do |statement|
          next unless statement.is_a?(Prism::DefNode) && statement.receiver.nil?

          record_computed_definer(statement, owner.split("::"), tables, :singleton)
        end
      end

      CLASS_EVAL_BLOCK_CALLS = %i[class_eval module_eval class_exec module_exec].to_set.freeze
      private_constant :CLASS_EVAL_BLOCK_CALLS

      # Whether a definer's argument list starts with a name that is not a Symbol or String literal.
      def computed_first_name?(arguments)
        !arguments.nil? && !arguments.empty? && literal_method_name(arguments.first).nil?
      end

      # The `alias_method :new, :old` CallNode twin of {#record_alias_method} (#533): the NEW name joins
      # the discovered-methods table so calls to it stop reading undefined, and
      # {AliasDefNodes.apply_alias_def_nodes}'s map walk gives it the ORIGINAL def node for return inference.
      def record_alias_method_call(call_node, qualified_prefix, in_singleton_class, accumulator)
        return if qualified_prefix.empty?

        names = Source::AliasNames.alias_method_call_names(call_node)
        return if names.nil?

        kind = in_singleton_class ? :singleton : :instance
        record_method(accumulator, qualified_prefix.join("::"), names.first, kind)
      end

      # #319 — walks a `Class.new do ... end` / `Module.new do ... end` / `Struct.new(*sym) do ... end` /
      # `Data.define(*sym) do ... end` block body as the class body it is at runtime, keyed by the call site's
      # synthetic anonymous `name`; the call's other children (receiver, arguments) keep the enclosing prefix.
      # `def_owner_prefix` is the enclosing rebound self the factory call's receiver and
      # arguments still evaluate under — the block's own `self` is the anonymous class,
      # supplied to its body as the `[name]` owner, while `Module.nesting` stays lexical
      # so declarations inside it keep the enclosing prefix.
      def walk_anonymous_meta_block(call_node, name, qualified_prefix, in_singleton_class, methods_acc, # rubocop:disable Metrics/ParameterLists
                                    def_nodes_acc, source_path, def_owner_prefix = nil,
                                    singleton_cref: false, defs_singleton: false)
        record_meta_members(call_node, [name], methods_acc.at(call_node))
        call_node.rigor_each_child do |child|
          if child.equal?(call_node.block)
            body = call_node.block.body
            if body
              walk_methods_and_def_nodes(body, qualified_prefix, false, methods_acc, def_nodes_acc,
                                         source_path, [name], singleton_cref: singleton_cref)
            end
          else
            walk_methods_and_def_nodes(child, qualified_prefix, in_singleton_class, methods_acc, def_nodes_acc,
                                       source_path, def_owner_prefix,
                                       singleton_cref: singleton_cref,
                                       defs_singleton: defs_singleton)
          end
        end
      end

      # The prefix a `class <<` body's defs record under: the singleton of the class the
      # expression names, or {EMPTY_PREFIX} when nothing names it — including `class << self`
      # INSIDE a singleton body, where `self` is the singleton class and `class << self`
      # opens the singleton's OWN singleton (`#<Class:#<Class:C>>`), which nothing names.
      def singleton_body_prefix(node, in_singleton_class, self_prefix, lexical_prefix)
        return EMPTY_PREFIX if in_singleton_class && node.expression.is_a?(Prism::SelfNode)

        singleton_class_prefix(node, self_prefix, lexical_prefix) || EMPTY_PREFIX
      end

      # Resolves a `class << X` body's qualified prefix.
      #   - `class << self` keeps `qualified_prefix` (the enclosing class).
      #   - `class << Foo` inside `class Foo` collapses to the same prefix
      #     (semantically `class << self`).
      #   - `class << Foo` not nested in `class Foo` returns `[Foo]`
      #     so methods defined inside register on Foo's singleton.
      #   - `class << Foo = <expr>` (#320, the private-singleton-object
      #     idiom) is the same case: Ruby evaluates the assignment, then
      #     opens the singleton of the resulting object — which is the
      #     object `Foo` now holds — so the body's methods are reachable
      #     as `Foo.<name>` exactly as for a plain constant read.
      #   - Any other expression (variable, method call) returns nil
      #     so the walker falls through and skips the body.
      def singleton_class_prefix(node, self_prefix, lexical_prefix)
        return self_prefix if node.expression.is_a?(Prism::SelfNode)

        rendered = singleton_receiver_constant_name(node.expression)
        return nil unless rendered

        # Same lexical rule {DeclarationWalk::Rules.eval_receiver_prefix} applies: `class << Y` resolves `Y`
        # through the write site's nesting, never through the eval-derived self —
        # `class << Y` inside `M::Y.class_eval` at top level opens the TOP-LEVEL `Y`'s
        # singleton.
        DeclarationWalk::Rules.eval_constant_receiver_prefix(node, node.expression, rendered, lexical_prefix)
      end

      # The constant a `class << X` operand names, or nil when the operand is not constant-shaped. Both the
      # read spellings (`Foo`, `A::Foo`, `::Foo`) and the two constant-*write* spellings (`Foo = expr`,
      # `A::Foo = expr`) resolve to the same unqualified rendering the read branch uses, so a body opened on
      # the assignment and one opened on a later plain read land on the same table key.
      def singleton_receiver_constant_name(expression)
        case expression
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          Source::ConstantPath.qualified_name(expression)
        when Prism::ConstantWriteNode
          expression.name.to_s
        when Prism::ConstantPathWriteNode
          Source::ConstantPath.qualified_name(expression.target)
        end
      end
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength

      # `class Foo < Data.define(:a, :b)` / `class Bar < Struct.new(:x)` synthesizes reader methods (`a`, `b`, `x`) on
      # the subclass that no `def` / `attr_*` declares. Register them in the discovered-methods existence table so an
      # implicit-self read of a member inside the class body is known to exist — both for the existing undefined-method
      # suppression and for the ADR-24 slice-4 self-call recorder, which must treat a synthesized member as an existing
      # method, not an unresolved call.
      def record_meta_superclass_members(class_node, qualified_prefix, accumulator)
        record_meta_members(class_node.superclass, qualified_prefix, accumulator, allow_outer_block: false)
      end

      # The registration itself, shared with the two BLOCK forms — `Const = Struct.new(:a) do … end` from the
      # `ConstantWriteNode` branch and the anonymous `Struct.new(:a) do … end` from {#walk_anonymous_meta_block}
      # (#590). Their bodies are entered as class bodies, so a member read inside one dispatches on the struct's
      # own class and must find the reader there: a member that shadows a `Kernel` private (`lambda`) otherwise
      # falls through to `Kernel#lambda`, and `lambda.upcase` reports an undefined method on `Proc` — a wrong-type
      # diagnostic on correct code. No-op for `Class.new` / `Module.new`. A splatted member list registers its literal
      # members and opens the instance side ({#record_meta_member_names}).
      def record_meta_members(factory_call, qualified_prefix, accumulator, allow_outer_block: true)
        factory_call = FactoryCallResolver.resolve_meta_factory_call(factory_call, allow_outer_block: allow_outer_block)
        return unless factory_call

        # Issue #2968 — `K = Struct.new("Named", :a)` makes one class under two names, `K` and `Struct::Named`; the
        # members are credited on both.
        if DeclarationWalk::Rules.struct_new_call?(factory_call)
          named = AnonymousMetaClass.struct_class_name(factory_call)
        end
        [qualified_prefix.join("::"), named].compact.uniq.each do |class_name|
          record_meta_member_names(factory_call, class_name, accumulator)
        end
      end

      # Issue #2968 — a splatted member list (`Struct.new(*FIELDS)`) names members this walk cannot read, so the
      # instance side opens: no name is provably missing there.
      def record_meta_member_names(factory_call, class_name, accumulator)
        if SharedWalkTables.meta_members_open?(factory_call)
          record_surface_mark(accumulator, class_name, Scope::DiscoveryIndex::ENVELOPE_OPEN_INSTANCE_NAMES_MARK)
        end
        SharedWalkTables.meta_member_names(factory_call).each do |member|
          record_method(accumulator, class_name, member, :instance)
        end
      end

      def record_def_method(def_node, qualified_prefix, in_singleton_class, accumulator)
        return if qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        kind = def_side(def_node, qualified_prefix, in_singleton_class)
        return if kind.nil?

        record_method(accumulator, class_name, def_node.name, kind, Source::ParameterEnvelope.of(def_node))
      end

      # The side a `def`'s body evidence is filed on: a `def self.x`'s singleton side, unless the caller files it as an
      # instance method elsewhere (`receiver_side: false`, #3005's `Owner::<included>`).
      def evidence_side(def_node, side, receiver_side) = receiver_side && def_node.receiver ? :singleton : side

      # Issue #992 — the rewriting calls a METHOD BODY makes, which the declaration walk never descends into:
      # `def self.inherited(sub) = sub.class_eval { … }`, `def self.wrap_all = define_method(…)`,
      # `def decorate(obj) = obj.extend(Decorator)`. A class-body macro records the same evidence in
      # {#record_surface_evidence}; `send` is left out here because inside a body it is an ordinary call far
      # more often than a definition.
      def record_def_body_evidence(def_node, qualified_prefix, tables, side, receiver_side: true)
        return if def_node.body.nil?

        side = evidence_side(def_node, side, receiver_side)

        definer = false
        Source::NodeWalker.each(def_node.body) do |node|
          if node.is_a?(Prism::SingletonClassNode)
            record_singleton_body_prepends(node, qualified_prefix, tables)
            record_constant_singleton_prepends(node, qualified_prefix, tables, owner: true)
            next
          end
          next unless node.is_a?(Prism::CallNode)

          if node.name == :extend
            record_object_extension(node, qualified_prefix, tables)
          elsif SURFACE_EVAL_CALLS.include?(node.name) || SURFACE_NAMING_CALLS.include?(node.name)
            definer ||= computed_self_define_method?(node)
            record_body_rewrite(node, qualified_prefix, tables)
          else
            record_singleton_prepend(node, qualified_prefix, tables, self_ok: true)
          end
        end
        record_computed_definer(def_node, qualified_prefix, tables, side) if definer
        record_hook_extends(def_node, qualified_prefix, tables, side)
      end

      # Issue #2975 — an ActiveSupport::Concern-style hook, `def self.included(base) = base.extend(ClassMethods)`, puts
      # `ClassMethods` on every includer's singleton chain, which no `extend` edge of the includer records. The module
      # takes a `[ENVELOPE_HOOK_EXTEND_KIND, "ClassMethods"]` entry per constant extended on the hook's parameter, as
      # written, so `call.undefined-method` can resolve an includer's class-body macro calls against it.
      #
      # Issue #1592 — the entry also names the hook (`[ENVELOPE_HOOK_EXTEND_KIND, "ClassMethods", :included]`), so the
      # includer's singleton resolution chain draws the module only for the edge whose hook runs. Only a direct
      # statement of the hook body with constant arguments and no `return` / `next` / `break` in an earlier
      # statement is a fact the chain can place. Any other extend of the parameter anywhere in the body (nested,
      # conditional, after an early exit, or with an argument that is not a constant), a `base.send(:extend, …)`, a
      # `base.singleton_class.include` / `prepend` and a `class_eval`-family block on the parameter take a
      # `[ENVELOPE_HOOK_EXTEND_OPEN_KIND, hook]` entry instead of, or beside, the named one. Each definition also takes
      # a `[ENVELOPE_HOOK_DEF_KIND, hook, source]` entry, so a module that defines the hook twice (in two files, or
      # twice in one) is read as open: which definition Ruby keeps is load order.
      def record_hook_extends(def_node, qualified_prefix, tables, side)
        return unless side == :singleton && HOOK_EXTEND_DEFS.include?(def_node.name) && !qualified_prefix.empty?

        owner = qualified_prefix.join("::")
        hook = def_node.name
        def_key = [Scope::DiscoveryIndex::ENVELOPE_HOOK_DEF_KIND, hook, def_node.slice.split.join(" ")]
        record_envelope(tables.envelopes, owner, def_key, Source::ParameterEnvelope::OPAQUE)
        param = def_node.parameters&.requireds&.first
        return unless param.is_a?(Prism::RequiredParameterNode)

        target = ->(call) { hook_param_receiver?(call.receiver, param.name) }
        scan_hook_body(def_node.body, target, owner, tables, hook) do |node|
          hook_singleton_reshape?(node, param.name)
        end
      end

      # The shared walk of a hook body or a concern's hook block: `target` says whether a call's receiver is the
      # includer, the block says whether a call reshapes the includer's singleton some other way.
      def scan_hook_body(body, target, owner, tables, hook)
        placeable = placeable_hook_statements(body)
        Source::NodeWalker.each(body) do |node|
          if node.is_a?(Prism::CallNode) && node.name == :extend && target.call(node)
            complete = record_hook_extend_arguments(node, owner, tables, hook)
            record_hook_extend_open(owner, tables, hook) unless complete && placeable.include?(node)
          elsif (node.is_a?(Prism::CallNode) && yield(node)) || singleton_mixin_body?(node)
            record_hook_extend_open(owner, tables, hook)
          end
        end
      end

      # The direct statements of a body that run unless an earlier statement raised: those before the first
      # statement holding a `return`, `next` or `break` anywhere in it. An endless `def` has its one expression.
      def placeable_hook_statements(body)
        statements = body.is_a?(Prism::StatementsNode) ? body.body : [body].compact
        placeable = Set.new.compare_by_identity
        statements.each do |statement|
          break if exits_early?(statement)

          placeable << statement
        end
        placeable
      end

      # A `next` or `break` inside a block or lambda leaves only that block, and a lambda's `return` only the lambda;
      # a `return` inside a block leaves the hook.
      def exits_early?(node, in_block: false)
        case node
        when Prism::ReturnNode then true
        when Prism::NextNode, Prism::BreakNode then !in_block
        when Prism::LambdaNode then false
        else
          inner = in_block || node.is_a?(Prism::BlockNode)
          node.rigor_each_child { |child| return true if exits_early?(child, in_block: inner) }
          false
        end
      end

      # A `class << self` body that mixes in, anywhere under a hook body or block.
      def singleton_mixin_body?(node)
        return false unless node.is_a?(Prism::SingletonClassNode) && node.expression.is_a?(Prism::SelfNode)

        found = false
        Source::NodeWalker.each(node.body) do |child|
          found ||= child.is_a?(Prism::CallNode) && MIXIN_SELF_CALLS.include?(child.name) && child.receiver.nil?
        end
        found
      end

      MIXIN_SELF_CALLS = %i[include prepend extend].freeze
      private_constant :MIXIN_SELF_CALLS

      def hook_param_receiver?(receiver, name)
        receiver.is_a?(Prism::LocalVariableReadNode) && receiver.name == name
      end

      # A hook-body call that may mix into the parameter's singleton class without a plain `base.extend(…)`:
      # `base.send(:extend, M)` (or `__send__` / `public_send`), `base.singleton_class.include(M)` / `prepend(M)`, and a
      # `class_eval` / `instance_eval` / `module_eval`-family call on the parameter, whose block runs with it as `self`.
      def hook_singleton_reshape?(node, name)
        receiver = node.receiver
        if HOOK_SEND_CALLS.include?(node.name)
          send_extend?(node) && hook_param_receiver?(receiver, name)
        elsif HOOK_EVAL_CALLS.include?(node.name)
          hook_param_receiver?(receiver, name)
        else
          %i[include prepend].include?(node.name) && receiver.is_a?(Prism::CallNode) &&
            receiver.name == :singleton_class && hook_param_receiver?(receiver.receiver, name)
        end
      end

      HOOK_EVAL_CALLS = %i[class_eval class_exec module_eval module_exec instance_eval instance_exec].freeze
      private_constant :HOOK_EVAL_CALLS

      # `send(:extend, …)`, `__send__` or `public_send`, on whatever receiver.
      def send_extend?(node)
        first = node.arguments&.arguments&.first
        HOOK_SEND_CALLS.include?(node.name) && first.is_a?(Prism::SymbolNode) && first.unescaped == "extend"
      end

      HOOK_SEND_CALLS = %i[send __send__ public_send].freeze
      private_constant :HOOK_SEND_CALLS

      # Records each constant argument as written and answers whether every argument was one.
      def record_hook_extend_arguments(node, owner, tables, hook)
        arguments = node.arguments&.arguments || []
        complete = !arguments.empty?
        arguments.each do |argument|
          written = Source::ConstantPath.qualified_name_or_nil(argument)
          next complete = false if written.nil?

          key = [Scope::DiscoveryIndex::ENVELOPE_HOOK_EXTEND_KIND, written, hook]
          record_envelope(tables.envelopes, owner, key, Source::ParameterEnvelope::OPAQUE)
        end
        complete
      end

      def record_hook_extend_open(owner, tables, hook)
        key = [Scope::DiscoveryIndex::ENVELOPE_HOOK_EXTEND_OPEN_KIND, hook]
        record_envelope(tables.envelopes, owner, key, Source::ParameterEnvelope::OPAQUE)
      end

      HOOK_EXTEND_DEFS = %i[included prepended].to_set.freeze
      private_constant :HOOK_EXTEND_DEFS

      # Issue #2997 — a module's `included` / `prepended` hook defined by a call rather than `def self.included`:
      # `define_singleton_method(:included) { |base| base.extend(X) }` written as a statement of the module body is
      # read as {#record_hook_extends} reads the `def` (a `[ENVELOPE_HOOK_DEF_KIND, hook, source]` entry, and the
      # block body scanned with its first parameter as the includer). (`class << self; def included(base)` already
      # reaches {#record_hook_extends} as a singleton `def`.) Any other call that may define a hook takes a
      # `[ENVELOPE_HOOK_EXTEND_OPEN_KIND, hook]` entry, for each hook a non-literal name may spell: one nested in
      # a block, method or condition, one without a block of one plain parameter, `send(:define_singleton_method,
      # …)`, `singleton_class.define_method(…)`, and `define_method` in the body of `class << self`.
      def record_hook_definer_calls(node, child_prefix, methods_acc)
        return unless node.is_a?(Prism::ModuleNode) && node.body.is_a?(Prism::StatementsNode)

        owner = child_prefix.join("::")
        direct = node.body.body
        each_hook_definer(node.body, false) do |call, hooks|
          tables = methods_acc.at(call)
          param = readable_hook_parameter(call) if direct.any? { |statement| statement.equal?(call) }
          if param
            record_hook_block(call, param, owner, tables, hooks.first)
          else
            hooks.each { |hook| record_hook_extend_open(owner, tables, hook) }
          end
        end
      end

      # The entries of one readable `define_singleton_method(:hook) { |base| … }`.
      def record_hook_block(call, param, owner, tables, hook)
        def_key = [Scope::DiscoveryIndex::ENVELOPE_HOOK_DEF_KIND, hook, call.slice.split.join(" ")]
        record_envelope(tables.envelopes, owner, def_key, Source::ParameterEnvelope::OPAQUE)
        body = call.block&.body
        return if body.nil?

        target = ->(extend_call) { hook_param_receiver?(extend_call.receiver, param.name) }
        scan_hook_body(body, target, owner, tables, hook) { |inner| hook_singleton_reshape?(inner, param.name) }
      end

      # Yields each call under a module body that may define the module's `included` / `prepended`, with the hooks
      # it may define. A nested class or module body has its own self, and so has an instance `def`'s body; in a
      # `class << self` body `define_method` defines on the module and `define_singleton_method` on its singleton
      # class, and in a singleton `def`'s body `self` is the module again.
      def each_hook_definer(node, in_singleton, &)
        case node
        when Prism::ClassNode, Prism::ModuleNode then nil
        when Prism::SingletonClassNode
          each_hook_definer(node.expression, in_singleton, &)
          each_hook_definer(node.body, !in_singleton && node.expression.is_a?(Prism::SelfNode), &)
        when Prism::DefNode
          each_hook_definer(node.body, false, &) if in_singleton || node.receiver.is_a?(Prism::SelfNode)
        else
          if node.is_a?(Prism::CallNode)
            hooks = hook_definer_names(node, in_singleton)
            yield node, hooks unless hooks.nil?
          end
          node&.rigor_each_child { |child| each_hook_definer(child, in_singleton, &) }
        end
      end

      # The hooks a call may define on the module whose body runs it, or nil for a call that defines none.
      def hook_definer_names(node, in_singleton)
        name_node = hook_definer_name_node(node, in_singleton)
        return nil if name_node.nil?

        name = literal_method_name(name_node)
        return HOOK_EXTEND_DEFS.include?(name) ? [name] : nil if name

        hooks = HOOK_EXTEND_DEFS.select { |hook| hook.start_with?(literal_name_prefix(name_node)) }
        hooks.empty? ? nil : hooks
      end

      # The literal text an interpolated name starts with (`"is_"` for `"is_#{n}"`), or `""` for a name computed any
      # other way: only a hook whose name starts with it may be the one defined.
      def literal_name_prefix(node)
        return "" unless node.is_a?(Prism::InterpolatedSymbolNode) || node.is_a?(Prism::InterpolatedStringNode)

        first = node.parts.first
        first.is_a?(Prism::StringNode) ? first.unescaped : ""
      end

      # The argument naming the method a call that may define a singleton method of the module defines, or nil.
      def hook_definer_name_node(node, in_singleton)
        arguments = node.arguments&.arguments || []
        if HOOK_SEND_CALLS.include?(node.name) && self_receiver?(node.receiver)
          definer = literal_method_name(arguments.first)
          arguments[1] if definer == :define_singleton_method || (in_singleton && definer == :define_method)
        elsif singleton_definer_call?(node, in_singleton)
          arguments.first
        end
      end

      def singleton_definer_call?(node, in_singleton)
        receiver = node.receiver
        case node.name
        when :define_singleton_method then !in_singleton && self_receiver?(receiver)
        when :define_method
          (in_singleton && self_receiver?(receiver)) ||
            (receiver.is_a?(Prism::CallNode) && receiver.name == :singleton_class && self_receiver?(receiver.receiver))
        else false
        end
      end

      def self_receiver?(receiver) = receiver.nil? || receiver.is_a?(Prism::SelfNode)

      # The includer parameter of a `define_singleton_method(:hook) { |base| … }` the hook read can place: one literal
      # hook name, a literal block, and a plain first parameter. Nil for any other shape.
      def readable_hook_parameter(call)
        arguments = call.arguments&.arguments || []
        return nil unless call.name == :define_singleton_method && arguments.size == 1
        return nil unless literal_method_name(arguments.first) && call.block.is_a?(Prism::BlockNode)

        params = call.block.parameters
        param = params.parameters&.requireds&.first if params.is_a?(Prism::BlockParametersNode)
        param.is_a?(Prism::RequiredParameterNode) ? param : nil
      end

      # Issue #2986 — a module whose body runs `extend ActiveSupport::Concern` has `Concern#append_features` (or
      # `prepend_features`) extend each direct includer with `const_get(:ClassMethods)`, as #2975's hook does with its
      # constant, so the module takes a `[ENVELOPE_HOOK_EXTEND_KIND, "ClassMethods", :const_get]` entry. A
      # `class_methods do … end` block of that body is a `module_eval` of `Owner::ClassMethods`: each `def` in it is
      # also recorded on that module, with its body's evidence (a computed definer's entry among it), so the hook
      # reader resolves and reads it. The walk keeps recording the same `def` on the module itself as before. A call on
      # `self` in an `included do … end` or `prepended do … end` block takes a
      # `[ENVELOPE_HOOK_BODY_CALL_KIND, hook, name]` entry, since Ruby runs that block in the includer's class body.
      #
      # Issue #1592 — the `def` node is filed on `Owner::ClassMethods` too, so the includer's singleton resolution
      # chain, which holds that module, answers a class-side call with the `def`'s own return type.
      #
      # Issue #2997 — a `class_methods` block is read in every body of the module, not only one that runs `extend
      # ActiveSupport::Concern` itself: a reopening in another file runs it on a module that is already a concern, and
      # where it loads first Ruby raises `NoMethodError` at load, so no running program has the includer without the
      # method. The module is a concern, and its includers draw on `Owner::ClassMethods`, only when some body records
      # the concern entry.
      def record_concern_class_methods(node, child_prefix, methods_acc, def_nodes_acc)
        return unless node.is_a?(Prism::ModuleNode) && node.body.is_a?(Prism::StatementsNode)

        concern = concern_body?(node.body, child_prefix)
        owner = child_prefix.join("::")
        if concern
          key = [Scope::DiscoveryIndex::ENVELOPE_HOOK_EXTEND_KIND, "ClassMethods", :const_get]
          record_envelope(methods_acc.at(node).envelopes, owner, key, Source::ParameterEnvelope::OPAQUE)
          record_concern_dependencies(node.body.body, child_prefix, owner, methods_acc)
        end
        node.body.body.each do |statement|
          next unless statement.is_a?(Prism::CallNode) && block_statement?(statement)

          if statement.name == :class_methods
            record_class_methods_block(statement, [*child_prefix, "ClassMethods"], methods_acc, def_nodes_acc)
          elsif CONCERN_HOOK_BLOCKS.include?(statement.name)
            hook = concern ? statement.name : Scope::DiscoveryIndex::CONCERN_BLOCK_HOOKS.fetch(statement.name)
            record_concern_hook_block(statement, hook, owner, methods_acc)
            record_hook_block_singleton_defs(statement, hook, child_prefix, methods_acc, def_nodes_acc)
          end
        end
      end

      # Issue #3005 — a `def self.x` in an `included do … end` (or `prepended do … end`) block defines `x` on the
      # includer's singleton class, since Ruby runs the block in the includer's class body. Each such `def` is filed
      # as an instance method of the module's `Owner::<included>` (`<prepended>`), a name no program can spell, and
      # the module takes a `[ENVELOPE_HOOK_EXTEND_KIND, "<included>", hook]` entry, so the includer's singleton
      # resolution chain holds that module where the hook's own extends go: after the includer's singleton and any
      # module prepended to it, ahead of the concern's `ClassMethods`.
      #
      # Issue #3015 — a receiverless `def` written as a statement of a `class << self` body in the block (found with
      # {#each_class_methods_def}'s stops) is filed the same way. A `class << self` body with a statement-level
      # visibility call (`private`, `private :x`, `private def x`) may make a `def` non-public, which the module does
      # not record, so it files none of its `def`s and opens the hook instead ({#record_hook_extend_open}).
      def record_hook_block_singleton_defs(statement, hook, child_prefix, methods_acc, def_nodes_acc)
        segment = "<#{statement.name}>"
        prefix = [*child_prefix, segment]
        name = prefix.join("::")
        owner = child_prefix.join("::")
        defs = hook_block_singleton_defs(statement.block.body, owner, hook, methods_acc)
        return if defs.empty?

        defs.each do |def_node|
          record_method(methods_acc.at(def_node), name, def_node.name, :instance, Source::ParameterEnvelope.of(def_node))
          (def_nodes_acc[name] ||= {})[def_node.name] = def_node
          record_def_body_evidence(def_node, prefix, methods_acc, :instance, receiver_side: false)
        end
        key = [Scope::DiscoveryIndex::ENVELOPE_HOOK_EXTEND_KIND, segment, hook]
        record_envelope(methods_acc.at(statement).envelopes, owner, key, Source::ParameterEnvelope::OPAQUE)
      end

      # The `def`s {#record_hook_block_singleton_defs} files, opening the hook of `owner` for each `class << self` body
      # with a visibility call.
      def hook_block_singleton_defs(body, owner, hook, methods_acc)
        defs = []
        each_class_methods_def(body) { |def_node| defs << def_node if def_node.receiver.is_a?(Prism::SelfNode) }
        each_hook_block_singleton_class(body) do |singleton|
          statements = statements_of(singleton.body)
          if statements.any? { |child| singleton_body_visibility_call?(child) }
            record_hook_extend_open(owner, methods_acc.at(singleton), hook)
          else
            statements.each { |child| defs << child if child.is_a?(Prism::DefNode) && child.receiver.nil? }
          end
        end
        defs
      end

      # Issue #3015 — the `class << self` bodies of an `included` / `prepended` block, with {#each_class_methods_def}'s
      # stops.
      def each_hook_block_singleton_class(node, &)
        case node
        when Prism::SingletonClassNode then yield node if node.expression.is_a?(Prism::SelfNode)
        when *CONCERN_BLOCK_STOPS then nil
        else node&.rigor_each_child { |child| each_hook_block_singleton_class(child, &) }
        end
      end

      SINGLETON_BODY_VISIBILITY_CALLS = %i[private protected public private_class_method public_class_method].freeze
      private_constant :SINGLETON_BODY_VISIBILITY_CALLS

      def singleton_body_visibility_call?(statement)
        statement.is_a?(Prism::CallNode) && statement.receiver.nil? &&
          SINGLETON_BODY_VISIBILITY_CALLS.include?(statement.name)
      end

      def record_class_methods_block(statement, class_methods_prefix, methods_acc, def_nodes_acc)
        each_class_methods_def(statement.block&.body) do |def_node|
          record_def_method(def_node, class_methods_prefix, false, methods_acc.at(def_node))
          record_def_node(def_node, class_methods_prefix, false, def_nodes_acc)
          record_def_body_evidence(def_node, class_methods_prefix, methods_acc, :instance)
        end
      end

      # Issue #2992 — `Concern#append_features` (or `prepend_features`) of a concern `include`d (or `prepend`ed) into a
      # module that has already run `extend ActiveSupport::Concern` records it as a dependency of that module and
      # includes nothing; the module's final includer includes it. Only a constant argument of an `include` /
      # `prepend` on the module's own `self` ({#concern_dependency_arguments}) written as a statement of the body
      # AFTER the body's own `extend` is provably such a dependency: one written ahead of it, or in a reopening
      # without it, may run first and is an ordinary include.
      # Each such constant takes a `[ENVELOPE_CONCERN_DEPENDENCY_KIND, written]` entry; whether it names a concern is
      # the reader's question. One statement's constants are recorded last first: `include A, B` runs
      # `B.append_features` first, so the dependencies list it ahead, and a reader that reverses the entries to put a
      # later statement's nearer keeps one statement's in argument order, as Ruby searches them.
      def record_concern_dependencies(statements, child_prefix, owner, methods_acc)
        extend_at = statements.index { |statement| concern_extend?(statement, child_prefix) }
        statements.drop(extend_at + 1).each do |statement|
          arguments = concern_dependency_arguments(statement)
          next if arguments.nil?

          arguments.reverse_each do |argument|
            written = Source::ConstantPath.qualified_name_or_nil(argument)
            next if written.nil?

            key = [Scope::DiscoveryIndex::ENVELOPE_CONCERN_DEPENDENCY_KIND, written]
            record_envelope(methods_acc.at(statement).envelopes, owner, key, Source::ParameterEnvelope::OPAQUE)
          end
        end
      end

      # The arguments of a statement that `include`s or `prepend`s on the module's own `self`, or nil. Issue #2995 —
      # `self.include Dep` and a receiverless or `self.` `send(:include, Dep)` run the same `append_features` as a
      # bare `include Dep`, and the include walk records them as it does.
      def concern_dependency_arguments(statement)
        return nil unless statement.is_a?(Prism::CallNode) && statement.block.nil? &&
                          lexical_self_receiver?(statement.receiver)

        kind, arguments, = mixin_call_view(statement)
        arguments if MIXIN_CALL_NAMES.include?(kind)
      end

      # Issue #1592 — an `extend` on `self` in the block extends the includer as `base.extend` in a hook does, so it
      # records the same entries, named by the block's hook ({#record_hook_extends}), and any `extend` nested in the
      # block, a `class << self` mixin or a `send(:extend, …)` there is open.
      #
      # Issue #3005 — read in every body of the module, as a `class_methods` block is: in a body that does not run
      # `extend ActiveSupport::Concern` itself the entries name the block's gated hook
      # ({Scope::DiscoveryIndex::CONCERN_BLOCK_HOOKS}), which a reader takes as the plain hook only for a concern.
      def record_concern_hook_block(statement, hook, owner, methods_acc)
        body = statement.block.body
        each_self_call(body) do |call|
          entry = [Scope::DiscoveryIndex::ENVELOPE_HOOK_BODY_CALL_KIND, hook, call.name]
          record_envelope(methods_acc.at(call).envelopes, owner, entry, Source::ParameterEnvelope::OPAQUE)
        end
        return if body.nil?

        target = ->(call) { call.receiver.nil? || call.receiver.is_a?(Prism::SelfNode) }
        scan_hook_body(body, target, owner, methods_acc.at(statement), hook) { |call| send_extend?(call) }
      end

      CONCERN_HOOK_BLOCKS = %i[included prepended].to_set.freeze
      HOOK_BLOCK_CALLS = (CONCERN_HOOK_BLOCKS | [:class_methods]).freeze

      # Issue #3015 — the blocks of the `included` / `prepended` / `class_methods` statements of a module body that
      # runs `extend ActiveSupport::Concern` itself; none for any other body, whose `included` may be its own DSL. A
      # reopening without the `extend` is not read.
      def concern_hook_blocks(node, child_prefix)
        return [] unless node.is_a?(Prism::ModuleNode) && concern_body?(node.body, child_prefix)

        node.body.body.filter_map do |statement|
          statement.block if block_statement?(statement) && HOOK_BLOCK_CALLS.include?(statement.name)
        end
      end

      # Issue #3015 — whether `node` is a `class << self` in a block {HookBlockSpans#mark_hook_blocks} marked for the
      # module the walk is in: the defs of its body are not the module's own singleton methods, and the walks do not
      # file them there.
      def hook_block_singleton?(node, in_singleton_class, owner_prefix, accumulator)
        !in_singleton_class && node.expression.is_a?(Prism::SelfNode) && accumulator.hook_block?(node, owner_prefix)
      end
      private_constant :CONCERN_HOOK_BLOCKS, :HOOK_BLOCK_CALLS

      # Whether a module body runs `extend ActiveSupport::Concern` as one of its own statements (`extend Concern`
      # in a module nested in `module ActiveSupport`).
      def concern_body?(body, child_prefix)
        return false unless body.is_a?(Prism::StatementsNode)

        body.body.any? { |statement| concern_extend?(statement, child_prefix) }
      end

      # Issue #3005 — `self.extend ActiveSupport::Concern` and a receiverless or `self.` `send` / `public_send` /
      # `__send__(:extend, ActiveSupport::Concern)` run the same `extend` on the module ({#mixin_call_view}).
      def concern_extend?(statement, child_prefix)
        return false unless statement.is_a?(Prism::CallNode) && lexical_self_receiver?(statement.receiver)

        kind, arguments, = mixin_call_view(statement)
        return false unless kind == :extend

        arguments.any? do |argument|
          written = Source::ConstantPath.qualified_name_or_nil(argument)&.delete_prefix("::")
          written == "ActiveSupport::Concern" || (written == "Concern" && child_prefix.first == "ActiveSupport")
        end
      end

      # A receiverless block call (`class_methods do … end`, `included do … end`). Concern's methods take no
      # positional argument here (`class_methods` raises on one), so arguments are not looked at.
      def block_statement?(node)
        node.is_a?(Prism::CallNode) && node.receiver.nil? && node.block.is_a?(Prism::BlockNode)
      end

      # The `def`s a `class_methods` block body writes, directly or wrapped in a call (`private def x`), not those in
      # a nested `def`, class, module, singleton-class, block or lambda body, which define elsewhere or later.
      def each_class_methods_def(node, &)
        case node
        when Prism::DefNode then yield node
        when *CONCERN_BLOCK_STOPS then nil
        else node&.rigor_each_child { |child| each_class_methods_def(child, &) }
        end
      end

      # The calls on `self` (no receiver, or `self.`) an `included` / `prepended` block body makes, not those in a
      # nested `def`, class, module, singleton-class or lambda body.
      #
      # Issue #2992 — a block that keeps `self` and runs as the block body runs (`[1].each { my_c :x }`) makes its
      # calls on the includer too, so the walk enters it ({#self_call_block?}). Any other block stays out; its call's
      # receiver and arguments are still read.
      def each_self_call(node, &)
        case node
        when *SELF_CALL_STOPS then nil
        when Prism::CallNode
          yield node if node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
          if node.block.is_a?(Prism::BlockNode) && !self_call_block?(node)
            [node.receiver, node.arguments].each { |part| each_self_call(part, &) }
          else
            node.rigor_each_child { |child| each_self_call(child, &) }
          end
        else node&.rigor_each_child { |child| each_self_call(child, &) }
        end
      end

      # Whether a call's block may run on the includer while the hook block runs. Every block may, since leaving one
      # out would report the macro's names, except one that rebinds `self` ({#rebinds_self_block?}) and the calls
      # known to keep a block for later: a receiverless `lambda` / `proc` and `Proc.new`, which run it only when
      # called, and `Kernel.lambda` / `Kernel.proc`; `on_load` on any receiver, which runs it when a framework
      # component loads; and a receiverless framework callback macro (`after_save { }`), which runs it on an instance.
      #
      # Issue #3000 — the callback stop is a list of the Rails callback macros, not a `before_` / `after_` /
      # `around_` prefix: a project macro so named may yield at once (`def self.after_foo = yield`), and entering a
      # block that runs later only loses a report.
      def self_call_block?(node)
        return false if rebinds_self_block?(node)
        return false if node.name == :on_load

        receiver = node.receiver
        if receiver.nil?
          !DEFERRED_BLOCK_CALLS.include?(node.name) && !CALLBACK_MACROS.include?(node.name)
        elsif DEFERRED_BLOCK_CALLS.include?(node.name)
          !constant_named?(receiver, "Kernel")
        else
          !(node.name == :new && constant_named?(receiver, "Proc"))
        end
      end

      def constant_named?(node, name)
        Source::ConstantPath.qualified_name_or_nil(node)&.delete_prefix("::") == name
      end

      DEFERRED_BLOCK_CALLS = %i[lambda proc].freeze
      # The callback macros of ActiveModel (validations), ActiveRecord (`Callbacks::CALLBACKS`, transactions),
      # ActiveJob (callbacks, `after_discard`), AbstractController (with its `prepend_` / `append_` forms),
      # ActionMailer, ActionMailbox, ActionCable (channel, connection), ActiveSupport::CurrentAttributes and
      # ActiveSupport::Reloader, read from Rails 8.1.3.
      CALLBACK_MACROS = %i[
        before_validation after_validation
        after_initialize after_find after_touch
        before_save around_save after_save before_create around_create after_create
        before_update around_update after_update before_destroy around_destroy after_destroy
        before_commit after_commit after_rollback
        after_save_commit after_create_commit after_update_commit after_destroy_commit
        before_perform around_perform after_perform before_enqueue around_enqueue after_enqueue after_discard
        before_action around_action after_action
        prepend_before_action prepend_around_action prepend_after_action
        append_before_action append_around_action append_after_action
        before_processing around_processing after_processing
        before_reset after_reset before_class_unload after_class_unload
        before_deliver around_deliver after_deliver
        before_subscribe after_subscribe before_unsubscribe after_unsubscribe
        before_command around_command after_command
      ].to_set.freeze
      private_constant :DEFERRED_BLOCK_CALLS, :CALLBACK_MACROS

      CONCERN_BLOCK_STOPS = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode,
                             Prism::BlockNode, Prism::LambdaNode].freeze
      SELF_CALL_STOPS = (CONCERN_BLOCK_STOPS - [Prism::BlockNode]).freeze
      private_constant :CONCERN_BLOCK_STOPS, :SELF_CALL_STOPS

      # Issue #2901 — a method whose body runs a `define_method` on its own `self` with a computed name, directly or in
      # a block that keeps `self` (`def self.my_attr(*n) = n.each { |x| define_method(x) {} }`), is a class macro: a
      # class body that calls it gains members no table names. The method takes a
      # `[ENVELOPE_COMPUTED_DEFINER_KIND, side, name]` entry, which `call.undefined-method` resolves a class's body
      # calls against. A `def Other.x` (another object's method) records none, and neither does a `define_method` inside
      # a nested `def`, a class body or a block that rebinds `self` ({#rebinds_self_block?}).
      #
      # Issue #2975 — the entry carries the side the method is defined on (`:singleton` for `def self.x` or a
      # `class << self` body, `:instance` otherwise), so a body call resolves only against a macro on the side its
      # singleton chain reaches.
      def record_computed_definer(def_node, qualified_prefix, tables, side)
        return if qualified_prefix.empty?
        return unless def_node.receiver.nil? || def_node.receiver.is_a?(Prism::SelfNode)
        return unless runs_computed_self_definer?(def_node.body)

        key = [Scope::DiscoveryIndex::ENVELOPE_COMPUTED_DEFINER_KIND, side, def_node.name]
        record_envelope(tables.envelopes, qualified_prefix.join("::"), key, Source::ParameterEnvelope::OPAQUE)
      end

      def computed_self_define_method?(node)
        node.name == :define_method && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) &&
          computed_first_name?(node.arguments&.arguments)
      end

      def runs_computed_self_definer?(node)
        case node
        when Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode
          return false
        when Prism::CallNode
          return true if computed_self_define_method?(node)
          # Issue #2975 — `include(Module.new { define_method(x) {} })` on `self` puts the computed method on `self`'s
          # instance side, as a direct `define_method(x)` would.
          return true if MODULE_NEW_MIXIN_CALLS.include?(node.name) &&
                         (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) &&
                         module_new_definer_argument?(node)
          if rebinds_self_block?(node)
            return [node.receiver, node.arguments].any? do |part|
              runs_computed_self_definer?(part)
            end
          end
        end
        return false unless node.is_a?(Prism::Node)

        node.rigor_each_child { |child| return true if runs_computed_self_definer?(child) }
        false
      end

      # A call whose block runs with another `self`: a class factory (`Class.new { }`), a definer's own body
      # (`define_method(:x) { }` runs on an instance), or an eval on a receiver other than `self`.
      def rebinds_self_block?(node)
        return false unless node.block.is_a?(Prism::BlockNode)
        return true if DeclarationWalk::Rules.meta_new_constant_rvalue?(node) ||
                       SELF_DEFINER_BLOCK_CALLS.include?(node.name)

        RECEIVER_EVAL_CALLS.include?(node.name) && !(node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
      end

      SELF_DEFINER_BLOCK_CALLS = %i[define_method define_singleton_method].freeze
      private_constant :SELF_DEFINER_BLOCK_CALLS

      # Issue #1820 — `obj.singleton_class.prepend(M)`, or `prepend M` in a `class << obj` body, puts `M` ahead of
      # `obj`'s class even when the class already includes it (`prepend` re-inserts it; `extend` would not), so
      # `M`'s refinement answers first for that object. `M` takes {Scope::DiscoveryIndex::ENVELOPE_OBJECT_EXTENDED_MARK},
      # the mark an `extend` in a method body already leaves: an object of any class may carry its instance methods
      # ahead of its class's own. A `singleton_class` of `self` (and a `class << self` body, which the caller leaves
      # out) written directly in a class or module body or at the top level is the class object's or `main`'s, not an
      # instance's; in a method body or any block (`self_ok`), where `self` may be an object, it counts.
      # `singleton_body` says the call sits in a `class << obj` body.
      def record_singleton_prepend(node, qualified_prefix, tables, singleton_body: false, self_ok: false)
        return unless node.name == :prepend

        receiver = node.receiver
        singleton = singleton_body && (receiver.nil? || receiver.is_a?(Prism::SelfNode))
        singleton ||= singleton_class_call?(receiver, self_ok)
        record_object_extension(node, qualified_prefix, tables) if singleton
      end

      # Issue #2998 — a prepend to the class object's own singleton class, `prepend P` in a `class << self` body or
      # `singleton_class.prepend P` / `singleton_class.send(:prepend, P)` in the class body, files a
      # `[ENVELOPE_SINGLETON_PREPEND_KIND, "P"]` entry per constant argument, as the extends walk spells it, under the
      # owner the walk passes in. The extends walk records the same edge in `discovered_extends`, and the singleton
      # resolution chain reads the entries that match one of those edges as prepends.
      #
      # A constant receiver's `Const.singleton_class.prepend P` (or its `send` spelling) files the entry on every name
      # the constant can denote from the call site, as {#record_body_rewrite} marks it; the extends walk records that
      # edge unpositioned, so the chain's reading of it is master's and the typing read declines where they differ.
      # `prefixes` is `[owner_prefix, qualified_prefix]`: the class `self` names (empty where it names none) and the
      # lexical prefix a constant resolves against.
      #
      # Issue #3020 — an argument that names no module (`prepend(*MODS)`, `prepend helper`; {#opaque_mixin_argument?})
      # files `[ENVELOPE_SINGLETON_PREPEND_KIND, "?"]`: the extends walk lists that edge as {MixinAccumulator::UNNAMED},
      # which cannot say a prepend from an `extend`, and the chain reads the entry as a prepend region it cannot name.
      def record_own_singleton_prepend(node, prefixes, in_singleton_class, tables)
        kind, arguments, = mixin_call_view(node)
        return unless kind == :prepend

        owners = singleton_prepend_owners(node.receiver, *prefixes, in_singleton_class)
        arguments.each do |argument|
          name = Source::ConstantPath.qualified_name(argument)
          name ||= MixinAccumulator::UNNAMED if opaque_mixin_argument?(argument)
          next unless name

          key = [Scope::DiscoveryIndex::ENVELOPE_SINGLETON_PREPEND_KIND, name]
          owners.each { |owner| record_envelope(tables.envelopes, owner, key, Source::ParameterEnvelope::OPAQUE) }
        end
      end

      # The classes whose singleton a prepend call on `receiver` reaches: the enclosing class for `prepend` in its
      # `class << self` body or `singleton_class.prepend` on a bare or `self.` receiver, and every name a constant
      # receiver's `Const.singleton_class` can denote.
      def singleton_prepend_owners(receiver, owner_prefix, qualified_prefix, in_singleton_class)
        own = owner_prefix.empty? ? EMPTY_PREFIX : [owner_prefix.join("::")]
        return own if in_singleton_class && lexical_self_receiver?(receiver)
        return EMPTY_PREFIX unless singleton_class_of_receiver?(receiver)

        object = receiver.receiver
        return in_singleton_class ? EMPTY_PREFIX : own if lexical_self_receiver?(object)
        return EMPTY_PREFIX unless object.is_a?(Prism::ConstantReadNode) || object.is_a?(Prism::ConstantPathNode)

        constant_receiver_candidates(object, qualified_prefix)
      end

      def singleton_class_call?(receiver, self_ok)
        return false unless receiver.is_a?(Prism::CallNode) && receiver.name == :singleton_class
        return false unless receiver.arguments.nil?

        object = receiver.receiver
        self_ok || !(object.nil? || object.is_a?(Prism::SelfNode))
      end

      # Issue #3010 — the singleton-prepend entries of a `class << Const` body's prepends on the other names the
      # constant can denote ({#constant_singleton_owners}); the body's own walk files them under the owner. The
      # extends walk records the matching edges, unpositioned ({#record_constant_singleton_candidates}). In a method
      # body, which the methods walk does not enter, `owner:` files them under the owner too.
      def record_constant_singleton_prepends(node, qualified_prefix, tables, owner: false)
        return unless constant_singleton_class?(node)

        resolved, others = constant_singleton_owners(node, qualified_prefix)
        others = [resolved, *others] if owner
        return if others.empty? || node.body.nil?

        each_singleton_body_prepend(node.body) do |call|
          mixin_call_view(call)[1].each do |argument|
            name = Source::ConstantPath.qualified_name(argument)
            next unless name

            key = [Scope::DiscoveryIndex::ENVELOPE_SINGLETON_PREPEND_KIND, name]
            others.each { |owner| record_envelope(tables.envelopes, owner, key, Source::ParameterEnvelope::OPAQUE) }
          end
        end
      end

      def record_singleton_body_prepends(node, qualified_prefix, tables)
        return if node.body.nil?

        Source::NodeWalker.each(node.body) do |inner|
          next unless inner.is_a?(Prism::CallNode)

          record_singleton_prepend(inner, qualified_prefix, tables, singleton_body: true, self_ok: true)
        end
      end

      def record_body_rewrite(node, qualified_prefix, tables)
        receiver = node.receiver
        if receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
          constant_receiver_candidates(receiver, qualified_prefix).each do |name|
            record_surface_mark(tables, name, Scope::DiscoveryIndex::ENVELOPE_DYNAMIC_MARK)
          end
        elsif !qualified_prefix.empty?
          record_surface_mark(tables, qualified_prefix.join("::"), Scope::DiscoveryIndex::ENVELOPE_DYNAMIC_MARK)
        end
      end

      def record_object_extension(node, qualified_prefix, tables)
        (node.arguments&.arguments || []).each do |argument|
          next unless argument.is_a?(Prism::ConstantReadNode) || argument.is_a?(Prism::ConstantPathNode)

          constant_receiver_candidates(argument, qualified_prefix).each do |name|
            record_surface_mark(tables, name, Scope::DiscoveryIndex::ENVELOPE_OBJECT_EXTENDED_MARK)
          end
        end
      end

      # The side of the enclosing class `qualified_prefix` a `def` defines its method on: `:instance`, `:singleton`, or
      # nil when the def defines no method of that class.
      #
      # `in_singleton_class` is true in a `class << self` body and `:eval` in an `instance_eval` block on the class
      # ({#def_context}), whose `self` is the class itself.
      #
      # - A receiverless def lands on the instance side, or on the singleton side in either body.
      # - `def self.x` is a singleton method. `def Foo.x` inside `module Foo` (or `def Meta.init` inside `module Meta`)
      #   is the same: at the def-site the constant `Foo` is the module itself (== `self`).
      # - Issue #3155 — any other receiver (`def String.q`, `def A.z` in `A::B`, `def obj.q` on a local or a constant
      #   holding an object) is a singleton method of that object, not the enclosing class, and `def self.x` in a
      #   `class << self` body is a method of the singleton class's own singleton: nil. The def's body is still
      #   walked; only the method is not filed on the enclosing class. A constant receiver's own singleton is
      #   {#record_foreign_singleton_def}'s.
      def def_side(def_node, qualified_prefix, in_singleton_class)
        receiver = def_node.receiver
        if receiver.nil?
          in_singleton_class ? :singleton : :instance
        elsif receiver.is_a?(Prism::SelfNode)
          in_singleton_class == true ? nil : :singleton
        elsif def_receiver_targets_lexical_self?(receiver, qualified_prefix)
          :singleton
        end
      end

      # The `in_singleton_class` {#def_side} reads for a def under a walk's two flags: an `instance_eval` block's
      # `defs_singleton` (`self` is the receiver, so `def self.x` is its singleton method) unless the def is also in
      # a `class << self` body.
      def def_context(in_singleton_class, defs_singleton)
        in_singleton_class || (defs_singleton ? :eval : false)
      end

      def foreign_def?(def_node, qualified_prefix, in_singleton_class)
        def_side(def_node, qualified_prefix, in_singleton_class).nil?
      end

      # Only `Prism::ConstantReadNode` is observed in real Ruby — Prism mis-parses `def C::P.method` as `def C.P` (Ruby
      # itself rejects the form as a SyntaxError). The ConstantPathNode branch stays defensive in case Prism's grammar
      # widens.
      def def_receiver_targets_lexical_self?(receiver, qualified_prefix)
        return false if qualified_prefix.empty?

        case receiver
        when Prism::ConstantReadNode
          receiver.name.to_s == qualified_prefix.last
        when Prism::ConstantPathNode
          rendered = Source::ConstantPath.render(receiver)
          return false unless rendered

          path = rendered.split("::")
          qualified_prefix.last(path.length) == path
        else
          false
        end
      end

      # v0.0.3 A — sentinel key under which `record_def_node` files DefNodes that live outside any class / module body
      # (top-level helpers, `def`s nested inside DSL blocks like `RSpec.describe ... do; def helper; end`). Looked up by
      # `Scope#top_level_def_for` to give implicit-self calls priority over RBS dispatch when the file defines a
      # same-named local method.
      TOP_LEVEL_DEF_KEY = "<toplevel>"

      # ADR-119 WD3 — the slot follows its writer (later-wins): a certain write clears the key from
      # `contested_discovered_def_nodes` and a possible one adds it ({MethodTables#certain}, set for `def_node`).
      def record_def_node(def_node, qualified_prefix, in_singleton_class, accumulator, tables = nil)
        return unless def_side(def_node, qualified_prefix, in_singleton_class) == :instance

        class_name = qualified_prefix.empty? ? TOP_LEVEL_DEF_KEY : qualified_prefix.join("::")
        accumulator[class_name] ||= {}
        accumulator[class_name][def_node.name] = def_node
        follow_slot_writer(tables, :contested_def_nodes, [class_name, def_node.name], tables.nil? || tables.certain)
        tables&.wrote_definer(class_name, def_node.name, def_node, def_node)
        record_anonymous_body_def_as_toplevel(def_node, qualified_prefix, accumulator, tables)
      end

      # ADR-119 WD3 — a single-valued slot's contest follows the write that holds it: `certain` clears `key` from
      # the `slot` Set of `tables`, a possible write adds it. Nil `tables` (a caller with no certainty) is a no-op.
      def follow_slot_writer(tables, slot, key, certain)
        return if tables.nil?

        if certain
          set = tables[slot]
          set&.delete(key)
        else
          (tables[slot] ||= Set.new) << key
        end
      end

      # Issue #1989 — the instance method names a non-`def` definer written on the class body's self replaces:
      # each reader (and `x=` writer) an `attr_*` call declares, a literal `define_method(:x)`, and the new name of
      # an `alias_method :x, :y` call, and each instance-side name of a Forwardable delegator (#2793). A non-literal
      # name replaces nothing Rigor can name.
      def call_superseded_names(call_node, qualified_prefix, accumulator)
        if (macro = attr_macro(call_node))
          names = []
          each_attr_macro_name(call_node) do |base|
            names << base unless macro == :attr_writer
            names << :"#{base}=" unless macro == :attr_reader
          end
          names
        elsif call_node.name == :define_method
          define_method_superseded_name(call_node)
        elsif (forwarded = forwardable_superseded_names(call_node, qualified_prefix, accumulator)).any?
          forwarded
        else
          Source::AliasNames.alias_method_call_names(call_node)&.first(1) || []
        end
      end

      def define_method_superseded_name(call_node)
        return [] unless call_node.receiver.nil? || call_node.receiver.is_a?(Prism::SelfNode)

        name = literal_method_name(call_node.arguments&.arguments&.first)
        name.nil? ? [] : [name.to_sym]
      end

      # Issue #1989 — a definer that is not a `def` replaces the method an earlier `def` of the same name in this walk
      # installed: `def x = 1; attr_reader :x` answers the attr reader, so the `def` body must not type the call. The
      # slot keeps the `def` and is contested, certain definer or possible, so the readers that re-type a body
      # decline. The slot is not emptied: the file still writes it, so a sibling file's `def` of the name (which the
      # cross-file seed and the project fold would otherwise put there) cannot fill it. A `def` written after the
      # definer writes the slot again and clears the contest.
      def supersede_def_nodes(names, qualified_prefix, accumulator, tables)
        return if names.empty?

        class_name = qualified_prefix.join("::")
        slot = accumulator[class_name]
        return if slot.nil?

        names.each do |name|
          follow_slot_writer(tables, :contested_def_nodes, [class_name, name], false) if slot.key?(name)
        end
      end

      # Issue #2006 — a `define_method(:x)` or `attr_*` call is a definer the alias pass reads in source order
      # ({AliasDefNodes.apply_alias_def_nodes}). An `alias_method` call, whose new name {#call_superseded_names} also
      # lists, is itself an alias: the pass records its copy, so the history must not hold it as a definer with no
      # `def`.
      def note_call_definers(call_node, names, qualified_prefix, tables)
        return if names.empty? || qualified_prefix.empty? || call_node.name == :alias_method

        class_name = qualified_prefix.join("::")
        names.each { |name| tables.wrote_definer(class_name, name, call_node, nil) }
      end

      # #319 — a `def` inside an anonymous `Class.new` / `Module.new` body ALSO stays in the `<toplevel>` table.
      # Before the anonymous class had a name the body was walked with an empty prefix, so every such `def`
      # landed there; that is the same leniency this key already grants a `def` nested in any other DSL block
      # (see {TOP_LEVEL_DEF_KEY}), and it is what lets an implicit-self call elsewhere in the file resolve
      # against a method the anonymous module contributes to some other object's `self` — the
      # `Module.new { def start; end }` mixed into a spawned actor environment, then called from the sibling
      # `spawn(...) { start }` block. Giving the body a class of its own must not silently retract it: the call
      # resolves at runtime, and `call.unresolved-toplevel` firing on it would be a new false positive traded
      # for the ones this change retires. Never clobbers a real top-level `def` of the same name.
      def record_anonymous_body_def_as_toplevel(def_node, qualified_prefix, accumulator, tables = nil)
        return unless qualified_prefix.length == 1
        return unless Type::AnonymousClassName.match?(qualified_prefix.first)

        table = (accumulator[TOP_LEVEL_DEF_KEY] ||= {})
        return if table.key?(def_node.name)

        table[def_node.name] = def_node
        follow_slot_writer(tables, :contested_def_nodes, [TOP_LEVEL_DEF_KEY, def_node.name],
                           tables.nil? || tables.certain)
      end

      # Module-singleton call resolution (ADR-57 follow-up) — the SINGLETON-side mirror of the def-node table
      # {#build_methods_and_def_nodes} builds. Records the `Prism::DefNode` for every singleton-side method
      # (`def self.x`, `def Foo.x`, a `class << self` body, and a `module_function` method) keyed by qualified
      # class/module name → method → node, so `ExpressionTyper` can re-type the body when a `Singleton[Foo]`
      # receiver dispatches `Foo.x`. The instance-side table is kept singleton-free on purpose (its ancestor walk
      # binds `self` as `Nominal`), so the two never overlap except for `module_function` defs, which are genuinely
      # callable on both sides and so appear in both tables. Top-level singleton defs (`def self.x` outside any class
      # — `self` is `main`) are not recorded; they have no constant receiver to dispatch through.
      def build_discovered_singleton_def_nodes(root)
        build_singleton_def_tables(root).first
      end

      # ADR-119 WD3 — {#build_discovered_singleton_def_nodes} with its sibling: `[table,
      # contested_discovered_singleton_def_nodes]`, the second a frozen Set of `[class, name]` keys whose slot a
      # possible `def self.x`, `class << self` def or `module_function` copy wrote last ({Certainty} `certainty`).
      def build_singleton_def_tables(root, certainty: Certainty.possible_nodes(root))
        accumulator = SingletonDefTable.new.track(certainty)
        walk_singleton_def_nodes(root, [], false, accumulator)
        [accumulator.transform_values(&:freeze).freeze, accumulator.contested_paths]
      end

      # The singleton walk's accumulator: the `{class => {name => DefNode}}` table, plus the contested slots, which
      # follow each slot's writer ({#follow_slot_writer}'s rule).
      class SingletonDefTable < Hash
        include HookBlockSpans

        attr_accessor :hook_block_spans

        # Issue #1936 — contests the slots of `names` (every slot of `class_name` for `:all`) that an earlier write
        # filled: a later non-`def` definer replaced the `def` they hold. The slot keeps the `def`, as
        # {ScopeIndexer#supersede_def_nodes} keeps the instance one, and a later write clears the contest.
        def supersede(class_name, names)
          slot = self[class_name]
          return if slot.nil?

          (names == :all ? slot.keys : names).each do |name|
            (@contested ||= Set.new) << [class_name, name] if slot.key?(name)
          end
        end

        def track(certainty)
          @certainty = certainty
          @contested = nil
          self
        end

        # Writes the slot; `node` and `other` are the contributions the write rests on, possible when either is.
        # `possible` says the write rests on a fact the contributions do not carry (a module_function copy after a
        # reset that may not run, #1968).
        def write(class_name, name, def_node, node, other = nil, possible: false)
          (self[class_name] ||= {})[name] = def_node
          if possible || Certainty.possible?(@certainty, node) || (other && Certainty.possible?(@certainty, other))
            (@contested ||= Set.new) << [class_name, name]
          else
            @contested&.delete([class_name, name])
          end
        end

        def contested_paths
          contested = @contested
          return contested.each(&:freeze).freeze if contested && !contested.empty?

          Scope::DiscoveryIndex::EMPTY_SIBLINGS[:contested_discovered_singleton_def_nodes]
        end
      end

      # The two position-keyed per-file indexes: the def / block / lambda body ranges issue #1097's
      # `*_def_shadows_call?` predicates order a same-name def against, and the class-declaration
      # sites `record_class_sources` accumulates.
      def record_file_positions(acc, path, root, superclasses, includes, file_def_nodes)
        acc[:deferred_ranges][path] = build_deferred_ranges(root)
        record_class_sources(acc[:class_sources], path, root, superclasses, includes, file_def_nodes,
                             acc[:compact_headers])
        SingletonClassSources.record_singleton_class_sources(acc[:singleton_class_sources], path, root)
      end

      # `{name => Set[path]}` for a bundle's name list (a bundle written before the list existed has none).
      def bundle_path_sets(names, path) = (names || []).to_h { |name| [name, Set[path]] }

      # Issue #1097 — `[[start_offset, end_offset, name, kind, owner], ...]` for every `def` / block /
      # lambda body in the file. `Scope#*_def_shadows_call?` reads it to answer two execution-timing
      # questions no `"path:line"` site can: whether a call sits INSIDE a deferred form (it runs at
      # invocation time, after every class-body `def` installed) and, for an eager class-body call,
      # where the earliest same-name def OF THE SAME OWNER starts. Def rows carry the method name,
      # its `:instance` / `:singleton` / `:both` (`module_function`) kind, and the qualified owner —
      # the owner filter keeps `class A; def self.sig` from ordering `class F`'s `sig` call, and the
      # kind filter keeps `def sig` from ordering `def self.sig`'s shadow question. Block / lambda /
      # `END` rows and defs nested inside another deferred range (they install at invocation time,
      # not during the enclosing body's own eval) carry nil name / kind / owner — containment only.
      def build_deferred_ranges(root)
        ranges = []
        walk_deferred_ranges(root, [], false, false, [], ranges)
        ranges.freeze
      end

      # The deferred-ranges walk, shaped on {#walk_singleton_def_nodes}: class / module / `class <<`
      # / meta-`new` bodies go through {#walk_deferred_body}, which prescans `module_function` state;
      # every other node recurses per child. A `DefNode` records its own range AND descends — a
      # nested `def` or block inside its body is still a range the containment half needs.
      # `def_owner_prefix` is the eval-body override described on {#walk_methods_and_def_nodes}:
      # an explicit owner for def rows while declarations stay lexical (`[]` = ownerless).
      def walk_deferred_ranges(node, qualified_prefix, in_singleton_class, inside_deferred, # rubocop:disable Metrics/ParameterLists, Metrics/MethodLength
                               mf_offsets, ranges, def_owner_prefix = nil, singleton_cref: false,
                               defs_singleton: false)
        return unless node.is_a?(Prism::Node)

        # Tested by exact class (Prism's node classes have no subclasses): the three `any?` scans this
        # replaced ran a block per list member at every node ([#1507](https://github.com/rigortype/rigor/issues/1507)).
        if CLASS_BODY_NODES.include?(node.class)
          return walk_deferred_lexical_body(node, qualified_prefix, in_singleton_class,
                                            inside_deferred, mf_offsets, ranges, def_owner_prefix,
                                            singleton_cref: singleton_cref)
        end
        if META_WRITE_NODES.include?(node.class)
          return walk_deferred_meta_new(node, qualified_prefix, in_singleton_class, inside_deferred,
                                        mf_offsets, ranges, def_owner_prefix,
                                        singleton_cref: singleton_cref)
        end
        if node.is_a?(Prism::DefNode)
          return walk_deferred_def_leaf(node, qualified_prefix, in_singleton_class, inside_deferred,
                                        mf_offsets, ranges, def_owner_prefix, singleton_cref,
                                        defs_singleton)
        end
        if DEFERRED_RANGE_NODES.include?(node.class)
          # Deferred: a call inside runs at invocation / interpreter-exit time. `BEGIN`
          # (PreExecutionNode) is the opposite — eager, before the class body — and stays unlisted.
          ranges << [node.location.start_offset, node.location.end_offset, nil, nil, nil]
          return walk_deferred_children(node, qualified_prefix, in_singleton_class, true, mf_offsets,
                                        ranges, def_owner_prefix, singleton_cref: singleton_cref,
                                                                  defs_singleton: defs_singleton)
        end
        if node.is_a?(Prism::CallNode) && DeclarationWalk::Rules.receiver_eval_call?(node)
          return walk_eval_block_call(node, qualified_prefix, in_singleton_class, inside_deferred,
                                      mf_offsets, ranges, def_owner_prefix,
                                      singleton_cref: singleton_cref)
        end

        record_definer_name_row(node, ranges) if node.is_a?(Prism::CallNode)
        walk_deferred_children(node, qualified_prefix, in_singleton_class, inside_deferred,
                               mf_offsets, ranges, def_owner_prefix, singleton_cref: singleton_cref,
                                                                     defs_singleton: defs_singleton)
      end

      DEFINER_NAME_CALLS = Set[:define_method, :define_singleton_method, :alias_method].freeze
      DEFINER_SEND_CALLS = Set[:send, :__send__, :public_send].freeze
      private_constant :DEFINER_NAME_CALLS, :DEFINER_SEND_CALLS

      # Issue #2184 — a `define_method` / `define_singleton_method` / `alias_method` call with a literal (new) name,
      # on any receiver and through `send` too, records an ownerless, kindless row over the name literal: no owner or
      # side is claimed, so no ordering scan matches it and the literal contains no call. It only tells a by-name
      # reader that the project gives the name a body no def table holds. A computed name records nothing.
      def record_definer_name_row(node, ranges)
        arguments = node.arguments&.arguments || []
        if DEFINER_SEND_CALLS.include?(node.name)
          return unless DEFINER_NAME_CALLS.include?(literal_method_name(arguments.first))

          arguments = arguments.drop(1)
        end
        return unless DEFINER_NAME_CALLS.include?(node.name) || DEFINER_SEND_CALLS.include?(node.name)

        argument = arguments.first
        name = literal_method_name(argument)
        ranges << [argument.location.start_offset, argument.location.end_offset, name, nil, nil] if name
      end

      # The `def` arm of {#walk_deferred_ranges}: records the range row — singleton-side when the
      # def sits in a `class <<` body or an `instance_eval` block (`defs_singleton`) — then walks
      # the body as a deferred range.
      def walk_deferred_def_leaf(node, qualified_prefix, in_singleton_class, inside_deferred, # rubocop:disable Metrics/ParameterLists
                                 mf_offsets, ranges, def_owner_prefix, singleton_cref,
                                 defs_singleton)
        owner = defs_singleton == :unnameable ? EMPTY_PREFIX : (def_owner_prefix || qualified_prefix)
        record_deferred_def(node, owner, def_context(in_singleton_class, defs_singleton), inside_deferred,
                            mf_offsets, ranges)
        walk_deferred_children(node, qualified_prefix, in_singleton_class, true, mf_offsets,
                               ranges, def_owner_prefix, singleton_cref: singleton_cref,
                                                         defs_singleton: defs_singleton)
      end

      DEFERRED_RANGE_NODES = Set[Prism::BlockNode, Prism::LambdaNode, Prism::PostExecutionNode].freeze
      META_WRITE_NODES = Set[Prism::ConstantWriteNode, Prism::ConstantPathWriteNode,
                             Prism::ConstantOrWriteNode, Prism::ConstantPathOrWriteNode].freeze
      CLASS_BODY_NODES = Set[Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze
      private_constant :DEFERRED_RANGE_NODES, :META_WRITE_NODES, :CLASS_BODY_NODES

      def walk_deferred_children(node, qualified_prefix, in_singleton_class, inside_deferred, # rubocop:disable Metrics/ParameterLists
                                 mf_offsets, ranges, def_owner_prefix = nil, singleton_cref: false,
                                 defs_singleton: false)
        node.rigor_each_child do |child|
          walk_deferred_ranges(child, qualified_prefix, in_singleton_class, inside_deferred,
                               mf_offsets, ranges, def_owner_prefix, singleton_cref: singleton_cref,
                                                                     defs_singleton: defs_singleton)
        end
      end

      # The `class <<` arm of {#walk_deferred_lexical_body}: the expression evaluates in the
      # enclosing cref; `class << <non-constant>` opens a singleton the walk cannot name — its body
      # is walked under an empty prefix so defs record a nil owner and never join another class's
      # ordering scan (containment still answers). Inside an eval body `class << self` opens the
      # RECEIVER's singleton, so the owner override supplies the base.
      def walk_deferred_singleton_body(node, qualified_prefix, in_singleton_class, inside_deferred, # rubocop:disable Metrics/ParameterLists
                                       mf_offsets, ranges, def_owner_prefix, singleton_cref,
                                       defs_singleton)
        walk_deferred_ranges(node.expression, qualified_prefix, in_singleton_class, inside_deferred,
                             mf_offsets, ranges, def_owner_prefix, singleton_cref: singleton_cref,
                                                                   defs_singleton: defs_singleton)
        prefix = singleton_body_prefix(node, in_singleton_class,
                                       def_owner_prefix || qualified_prefix, qualified_prefix)
        return unless node.body

        # Same split as {#walk_methods_and_def_nodes}: the lexical prefix stays enclosing for
        # declarations, the singleton's name rides the def-owner channel for range owners.
        walk_deferred_body(node.body, qualified_prefix, true, inside_deferred, ranges,
                           prefix, singleton_cref: true)
      end

      def walk_deferred_lexical_body(node, qualified_prefix, in_singleton_class, inside_deferred, # rubocop:disable Metrics/ParameterLists
                                     mf_offsets, ranges, def_owner_prefix = nil, singleton_cref: false,
                                     defs_singleton: false)
        if node.is_a?(Prism::SingletonClassNode)
          return walk_deferred_singleton_body(node, qualified_prefix, in_singleton_class,
                                              inside_deferred, mf_offsets, ranges,
                                              def_owner_prefix, singleton_cref, defs_singleton)
        end

        self_decl = DeclarationWalk::Rules.self_anchored_decl_prefix(
          node.constant_path, in_singleton_class ? EMPTY_PREFIX : def_owner_prefix
        )
        child_prefix = self_decl ||
                       Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
        unless child_prefix
          walk_deferred_children(node, qualified_prefix, in_singleton_class, inside_deferred,
                                 mf_offsets, ranges, def_owner_prefix, singleton_cref: singleton_cref)
          return
        end

        # `class Foo < expr` — a superclass expression can still hide defs and deferred calls.
        if node.is_a?(Prism::ClassNode) && node.superclass
          walk_deferred_ranges(node.superclass, qualified_prefix, in_singleton_class, inside_deferred,
                               mf_offsets, ranges, def_owner_prefix, singleton_cref: singleton_cref,
                                                                     defs_singleton: defs_singleton)
        end
        # Under an unnameable cref a bare/`self::` header opens `#<singleton>::Name` — ownerless.
        child_cref = DeclarationWalk::Rules.unnameable_decl?(node, self_decl, singleton_cref)
        prefix = child_cref ? [] : child_prefix
        return unless node.body

        walk_deferred_body(node.body, prefix, false, inside_deferred, ranges, nil,
                           singleton_cref: child_cref)
      end

      def walk_deferred_meta_new(node, qualified_prefix, in_singleton_class, inside_deferred, # rubocop:disable Metrics/ParameterLists
                                 mf_offsets, ranges, def_owner_prefix = nil, singleton_cref: false,
                                 defs_singleton: false)
        call = DeclarationWalk::Rules.meta_new_block_call(node)
        unless call
          walk_deferred_children(node, qualified_prefix, in_singleton_class, inside_deferred,
                                 mf_offsets, ranges, def_owner_prefix, singleton_cref: singleton_cref,
                                                                       defs_singleton: defs_singleton)
          return
        end

        # `Const = Class.new do ... end` — the block IS the new class's body and runs eagerly, not a
        # deferred range. The rvalue's receiver / arguments still get the ordinary walk. Under an
        # unnameable cref a bare write names nothing, so the block's class walks ownerless; a
        # path write keeps the lexically-resolved name.
        child_prefix = DeclarationWalk::Rules.meta_new_child_prefix(node, qualified_prefix, def_owner_prefix)
        meta_ownerless = singleton_cref &&
                         !DeclarationWalk::Rules.meta_new_path_target_nameable?(node, def_owner_prefix)
        body_self = (meta_ownerless ? nil : child_prefix) || []
        if call.receiver
          walk_deferred_ranges(call.receiver, qualified_prefix, in_singleton_class, inside_deferred,
                               mf_offsets, ranges, def_owner_prefix, singleton_cref: singleton_cref,
                                                                     defs_singleton: defs_singleton)
        end
        call.arguments&.arguments&.each do |arg|
          walk_deferred_ranges(arg, qualified_prefix, in_singleton_class, inside_deferred, mf_offsets,
                               ranges, def_owner_prefix, singleton_cref: singleton_cref,
                                                         defs_singleton: defs_singleton)
        end
        walk_deferred_body(DeclarationWalk::Rules.meta_new_block_body(node), qualified_prefix, false, inside_deferred,
                           ranges, body_self, singleton_cref: singleton_cref)
      end

      # Body-level entry for a class / module / `class <<` / meta-`new` / eval-block body: prescans
      # the body's `module_function` state first ({ModuleFunctionState.prescan_deferred} — bare-call
      # offsets plus the retro-install and `module_function def x` rows), then walks each statement
      # with the offsets in hand. The prescan looks through nested containers (`if` / `begin` /
      # `rescue` / blocks) because a `module_function` that RAN there still flips later defs —
      # position, not statement nesting, is what orders it. It stays out of nested class / module /
      # `class <<` / def bodies, where the call would target a different module. A body nested
      # inside a deferred range installs its defs at invocation, not in place, so the prescan —
      # which exists to NAME rows for the ordering scan — is skipped there and every def records a
      # containment-only row instead.
      def walk_deferred_body(body, qualified_prefix, in_singleton_class, inside_deferred, ranges, # rubocop:disable Metrics/ParameterLists
                             def_owner_prefix = nil, singleton_cref: false, defs_singleton: false)
        owner_prefix = def_owner_prefix || qualified_prefix
        mf_offsets = []
        unless inside_deferred
          # `module_function` under an unnameable definee (`class <<` + `instance_eval`)
          # toggles the metaclass — its rows must not name the enclosing class.
          prescan_owner = defs_singleton == :unnameable ? EMPTY_PREFIX : owner_prefix
          ModuleFunctionState.prescan_deferred(body, prescan_owner, in_singleton_class, mf_offsets,
                                               ranges)
        end
        statements_of(body).each do |stmt|
          walk_deferred_ranges(stmt, qualified_prefix, in_singleton_class, inside_deferred,
                               mf_offsets, ranges, def_owner_prefix, singleton_cref: singleton_cref,
                                                                     defs_singleton: defs_singleton)
        end
      end

      # A `class_eval` / `module_eval` / `class_exec` / `module_exec` block is NOT deferred: it runs
      # eagerly during the receiver's call, as a class-ish body — its `module_function` state gets
      # its own prescan, and its defs belong to the RECEIVER's surface. A nameable receiver gives
      # the body that owner ({DeclarationWalk::Rules.eval_receiver_prefix}); anything else is walked ownerless so its
      # defs stay out of every class's ordering scan while their own ranges still answer
      # containment for deeper nesting. Other block forms stay deferred: `each` / `define_method` /
      # callbacks yield-or-store on terms syntax cannot separate, and the conservative answer there
      # is "deferred".
      def walk_eval_block_call(node, qualified_prefix, in_singleton_class, inside_deferred, # rubocop:disable Metrics/ParameterLists
                               mf_offsets, ranges, def_owner_prefix = nil, singleton_cref: false)
        if node.receiver
          walk_deferred_ranges(node.receiver, qualified_prefix, in_singleton_class, inside_deferred,
                               mf_offsets, ranges, def_owner_prefix, singleton_cref: singleton_cref)
        end
        node.arguments&.arguments&.each do |arg|
          walk_deferred_ranges(arg, qualified_prefix, in_singleton_class, inside_deferred, mf_offsets,
                               ranges, def_owner_prefix, singleton_cref: singleton_cref)
        end
        block = node.block
        # The body walks under the LEXICAL prefix — `Module.nesting` does not change in an
        # eval block — with the receiver's prefix (or ownerless `[]`) as the def-owner
        # override: `X.class_eval { class Inner }` still opens `M::Inner`. `self` inside
        # the block is the enclosing eval's receiver, so the enclosing def-owner supplies
        # the base for `self` / bare / `self::` receivers.
        self_prefix = def_owner_prefix || qualified_prefix
        unnameable = DeclarationWalk::Rules.unnameable_eval_self?(in_singleton_class, def_owner_prefix,
                                                                  qualified_prefix, singleton_cref)
        eval_prefix = DeclarationWalk::Rules.eval_receiver_prefix(node, self_prefix, qualified_prefix,
                                                                  unnameable_self: unnameable) || []
        # `instance_eval`'s `def`s bind on the receiver's singleton (`defs_singleton`) while the
        # body itself is an ordinary class-body context — `class << self` inside still opens the
        # receiver's nameable singleton, so `in_singleton_class` stays off for a class receiver.
        call_singleton, defs_flag = eval_body_def_context(node, in_singleton_class)
        block.parameters&.rigor_each_child do |child|
          walk_deferred_ranges(child, qualified_prefix, call_singleton, inside_deferred, [],
                               ranges, eval_prefix, singleton_cref: singleton_cref,
                                                    defs_singleton: defs_flag)
        end
        return unless block.body

        walk_deferred_body(block.body, qualified_prefix, call_singleton, inside_deferred, ranges,
                           eval_prefix, singleton_cref: singleton_cref,
                                        defs_singleton: defs_flag)
      end

      # Whether `def`/`alias` leaves in an eval block body bind on the receiver's SINGLETON:
      # `instance_eval`/`instance_exec` always (self IS the receiver — `def` lands on
      # `#<Class:X>`); `class_eval` only inside an already-singleton body, where the receiver's
      # own singleton is what `def` opens. A NAMED receiver under `class_eval` re-opens the
      # receiver itself, so `def` there stays instance-side.
      def eval_body_singleton?(node, in_singleton_class)
        INSTANCE_EVAL_CALLS.include?(node.name) ||
          (in_singleton_class && !DeclarationWalk::Rules.eval_named_receiver?(node))
      end

      # The two flags an eval-family block body gives a def-owning walk: the
      # `in_singleton_class` its calls on the receiver-as-module inherit (a named receiver opens
      # that class's OWN body, so `false`; a bare or `self` receiver keeps the enclosing context, so
      # `class << self; class_eval { include M }` stays a singleton-ancestor edge), and the
      # `defs_singleton` its `def`/`alias` leaves record under — `true` when they
      # bind on the receiver's singleton, `:unnameable` when that singleton is one
      # nothing names. `instance_eval` splits the surfaces for a class receiver —
      # `def` lands on `#<Class:X>` while `define_method`/`attr_*` install `X#`
      # instance methods — so `call_singleton` stays off there. Inside an
      # already-singleton body a bare/`self` `instance_eval` re-evaluates the SAME
      # singleton self, where the split inverts: calls land on the singleton's
      # instance surface exactly like `class_eval`'s (`class << S; instance_eval {
      # define_method(:m) {} }` installs `S.m`), while `def` binds on the
      # singleton's own singleton — `#<Class:#<Class:S>>` — which nothing names.
      def eval_body_def_context(node, in_singleton_class)
        eval_in_singleton = eval_body_singleton?(node, in_singleton_class)
        singleton_self_eval = INSTANCE_EVAL_CALLS.include?(node.name) &&
                              in_singleton_class && !DeclarationWalk::Rules.eval_named_receiver?(node)
        call_singleton = eval_in_singleton &&
                         (!INSTANCE_EVAL_CALLS.include?(node.name) || singleton_self_eval)
        [call_singleton, singleton_self_eval ? :unnameable : eval_in_singleton]
      end

      def record_deferred_def(def_node, qualified_prefix, in_singleton_class, inside_deferred,
                              mf_offsets, ranges)
        start = def_node.location.start_offset
        if inside_deferred
          # Issue #2184 — the def installs at invocation under a `self` the walk does not know, so the row names the
          # method but claims no owner or side.
          ranges << [start, def_node.location.end_offset, def_node.name, nil, nil]
          return
        end

        side = def_side(def_node, qualified_prefix, in_singleton_class)
        # Issue #3155 — a def on another object's singleton claims no owner or side, as a deferred one.
        return ranges << [start, def_node.location.end_offset, def_node.name, nil, nil] if side.nil?

        kind = if side == :singleton
                 :singleton
               elsif ModuleFunctionState.deferred_module_function?(mf_offsets, start)
                 :both
               else
                 :instance
               end
        owner = qualified_prefix.empty? ? nil : qualified_prefix.join("::")
        ranges << [start, def_node.location.end_offset, def_node.name, kind, owner]
      end

      # Walks every node, entering class/module/singleton-class bodies via {#walk_singleton_body} so a bare
      # `module_function` toggle threads correctly across the body's *sibling* statements (a child-by-child recursion
      # would reset it). At the top level / inside an arbitrary node there is no `module_function` state to carry, so
      # descent is a plain per-child walk.
      def walk_singleton_def_nodes(node, qualified_prefix, in_singleton_class, accumulator, # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
                                   def_owner_prefix = nil, singleton_cref: false,
                                   defs_singleton: false)
        return unless node.is_a?(Prism::Node)

        supersede_singleton_def_nodes(node, qualified_prefix, in_singleton_class, defs_singleton, accumulator,
                                      def_owner_prefix)
        if DeclarationWalk::Rules.receiver_eval_call?(node)
          return walk_eval_singleton_defs(node, qualified_prefix, in_singleton_class, accumulator,
                                          def_owner_prefix, singleton_cref: singleton_cref,
                                                            defs_singleton: defs_singleton)
        end

        case node
        when Prism::ClassNode, Prism::ModuleNode
          self_decl = DeclarationWalk::Rules.self_anchored_decl_prefix(
            node.constant_path, in_singleton_class ? EMPTY_PREFIX : def_owner_prefix
          )
          child_prefix = self_decl ||
                         Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
          if child_prefix
            # Under an unnameable cref a bare/`self::` header opens `#<singleton>::Name` —
            # ownerless like `class << <non-constant>`; nameable headers re-anchor.
            child_cref = DeclarationWalk::Rules.unnameable_decl?(node, self_decl, singleton_cref)
            body_prefix = child_cref ? [] : child_prefix
            accumulator.mark_hook_blocks(concern_hook_blocks(node, child_prefix), child_prefix) unless child_cref
            if node.body
              walk_singleton_body(node.body, body_prefix, false, accumulator, nil,
                                  singleton_cref: child_cref)
            end
            return
          end
        when Prism::SingletonClassNode
          # `class << <non-constant>` opens a singleton the walk cannot name — its body
          # walks ownerless, keeping the singleton marker so `self::` receivers still decline.
          singleton_prefix = singleton_body_prefix(node, in_singleton_class,
                                                   def_owner_prefix || qualified_prefix,
                                                   qualified_prefix)
          walk_singleton_def_nodes(node.expression, qualified_prefix, in_singleton_class,
                                   accumulator, def_owner_prefix, singleton_cref: singleton_cref,
                                                                  defs_singleton: defs_singleton)
          if node.body && !hook_block_singleton?(node, in_singleton_class, def_owner_prefix || qualified_prefix,
                                                 accumulator)
            walk_singleton_body(node.body, qualified_prefix, true, accumulator, singleton_prefix,
                                singleton_cref: true)
          end
          return
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
             Prism::ConstantPathOrWriteNode
          return if walk_singleton_meta_new?(node, qualified_prefix, accumulator, def_owner_prefix,
                                             singleton_cref)
        when Prism::DefNode
          # `:unnameable` is the `class <<` + `instance_eval` definee — the singleton's own
          # singleton — which this table cannot name either.
          owner = def_owner_prefix || qualified_prefix
          return if accumulator.hook_block_self_def?(node, owner)

          unless defs_singleton == :unnameable
            record_singleton_def_node(node, owner, def_context(in_singleton_class, defs_singleton), false, accumulator)
          end
          return
        end

        node.rigor_each_child do |child|
          walk_singleton_def_nodes(child, qualified_prefix, in_singleton_class, accumulator,
                                   def_owner_prefix, singleton_cref: singleton_cref,
                                                     defs_singleton: defs_singleton)
        end
      end

      # The meta-new arm of {#walk_singleton_def_nodes}: the block is the new class's body —
      # under an unnameable cref a bare write names nothing (ownerless walk); a path write
      # keeps the lexically-resolved name. Returns whether a block body was walked.
      def walk_singleton_meta_new?(node, qualified_prefix, accumulator, def_owner_prefix,
                                   singleton_cref)
        return false unless DeclarationWalk::Rules.meta_new_block_call(node)

        child_prefix = DeclarationWalk::Rules.meta_new_child_prefix(node, qualified_prefix, def_owner_prefix)
        meta_ownerless = singleton_cref &&
                         !DeclarationWalk::Rules.meta_new_path_target_nameable?(node, def_owner_prefix)
        body_self = (meta_ownerless ? nil : child_prefix) || []
        walk_singleton_body(DeclarationWalk::Rules.meta_new_block_body(node), qualified_prefix, false, accumulator,
                            body_self, singleton_cref: singleton_cref)
        true
      end

      # The singleton-def twin of {#walk_eval_block_call}: a `*_eval` / `*_exec` block's defs belong
      # to the RECEIVER's class, so the block body is entered under the eval owner with the matching
      # singleton flag — `X.class_eval { def self.m }` inside `module M` records `X.m`, not a phantom
      # `M.m`. An unnameable receiver walks the body ownerless rather than guessing the lexical
      # class. The block body is a class body, so it walks through
      # {#walk_singleton_body} and gets its own `module_function` threading.
      def walk_eval_singleton_defs(node, qualified_prefix, in_singleton_class, accumulator,
                                   def_owner_prefix = nil, singleton_cref: false,
                                   defs_singleton: false)
        if node.receiver
          walk_singleton_def_nodes(node.receiver, qualified_prefix, in_singleton_class, accumulator,
                                   def_owner_prefix, singleton_cref: singleton_cref,
                                                     defs_singleton: defs_singleton)
        end
        node.arguments&.arguments&.each do |arg|
          walk_singleton_def_nodes(arg, qualified_prefix, in_singleton_class, accumulator, def_owner_prefix,
                                   singleton_cref: singleton_cref,
                                   defs_singleton: defs_singleton)
        end
        self_prefix = def_owner_prefix || qualified_prefix
        unnameable = DeclarationWalk::Rules.unnameable_eval_self?(in_singleton_class, def_owner_prefix,
                                                                  qualified_prefix, singleton_cref)
        eval_prefix = DeclarationWalk::Rules.eval_receiver_prefix(node, self_prefix, qualified_prefix,
                                                                  unnameable_self: unnameable) || []
        # `instance_eval`'s `def`s bind on the receiver's singleton (`defs_singleton`) while the
        # body keeps ordinary class-body semantics for `class << self` — `in_singleton_class`
        # stays off for a class receiver so the nested `class <<` still names it.
        call_singleton, defs_flag = eval_body_def_context(node, in_singleton_class)
        body = node.block.body
        if body.is_a?(Prism::StatementsNode)
          return walk_singleton_body(body, qualified_prefix, call_singleton, accumulator,
                                     eval_prefix, singleton_cref: singleton_cref,
                                                  defs_singleton: defs_flag)
        end

        node.block.rigor_each_child do |child|
          walk_singleton_def_nodes(child, qualified_prefix, call_singleton, accumulator, eval_prefix,
                                   singleton_cref: singleton_cref,
                                   defs_singleton: defs_flag)
        end
      end

      # {DeclarationWalk::Rules}' empty `Module.nesting` chain and empty qualified prefix, bound here.
      EMPTY_NESTING = DeclarationWalk::Rules::EMPTY_NESTING
      EMPTY_PREFIX = DeclarationWalk::Rules::EMPTY_PREFIX
      private_constant :EMPTY_NESTING

      # Walks a class/module/singleton-class body's direct statements in source order, threading the
      # bare-`module_function` toggle ({ModuleFunctionState.each_singleton_sibling}): once a bare
      # `module_function` is seen, every subsequent `def` in the body registers as a singleton method. Nested
      # classes/modules/defs recurse through the general walker so the toggle stays scoped to its own body, and a
      # `module_function :a, :b` named form records through {#record_module_function_names}.
      def walk_singleton_body(body, qualified_prefix, in_singleton_class, accumulator,
                              def_owner_prefix = nil, singleton_cref: false,
                              defs_singleton: false)
        owner_prefix = def_owner_prefix || qualified_prefix
        statements = statements_of(body)
        conditional = ModuleFunctionState.conditional_clause_statements(body)
        ModuleFunctionState.each_singleton_sibling(statements, conditional) do |stmt, module_function_on, named_call|
          if named_call
            # `:unnameable` — the named defs the call copies live on the metaclass,
            # which this table cannot name either.
            record_module_function_names(stmt, owner_prefix, statements, accumulator) unless
              defs_singleton == :unnameable
            next
          end
          if stmt.is_a?(Prism::DefNode)
            # `:unnameable` is the `class <<` + `instance_eval` definee — the singleton's own
            # singleton — which this table cannot name either.
            unless defs_singleton == :unnameable
              record_singleton_def_node(stmt, owner_prefix, def_context(in_singleton_class, defs_singleton),
                                        module_function_on, accumulator)
            end
            next
          end
          walk_singleton_def_nodes(stmt, qualified_prefix, in_singleton_class, accumulator,
                                   def_owner_prefix, singleton_cref: singleton_cref,
                                                     defs_singleton: defs_singleton)
        end
      end

      # Direct statement children of a class/module body node (a `Prism::StatementsNode`, a `Prism::BeginNode` wrapping
      # one, or a lone statement). A body-level `begin`'s `rescue` / `else` / `ensure` clauses are still body-level —
      # `class F; x; rescue; def m; end; end` installs `F#m` — so their statements are included after the main list.
      # Returns an empty list for an empty body.
      def statements_of(body)
        case body
        when Prism::StatementsNode then body.body
        when Prism::BeginNode then statements_of(body.statements) + begin_clause_statements(body)
        when nil then []
        else [body]
        end
      end

      # The statement lists a `BeginNode` keeps off its main `statements`: every rescue clause (chained
      # via `subsequent`), the `else` body, and the `ensure` body.
      def begin_clause_statements(node)
        statements = []
        clause = node.rescue_clause
        while clause
          statements.concat(statements_of(clause.statements))
          clause = clause.subsequent
        end
        statements.concat(statements_of(node.else_clause.statements)) if node.else_clause
        statements.concat(statements_of(node.ensure_clause.statements)) if node.ensure_clause
        statements
      end

      # `module_function_on` is {ModuleFunctionState.each_singleton_sibling}'s: `:uncertain` writes the module
      # function's copy as possible, so the slot holds the later def, contested, rather than the def the
      # slot held before (#1968).
      def record_singleton_def_node(def_node, qualified_prefix, in_singleton_class, module_function_on, accumulator)
        side = def_side(def_node, qualified_prefix, in_singleton_class)
        declared = side == :singleton
        return unless declared || (module_function_on && side == :instance)
        return if qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        write_singleton_slot(accumulator, class_name, def_node.name, def_node, def_node,
                             possible: !declared && module_function_on == :uncertain)
      end

      # Issue #1936 — the singleton twin of {#supersede_def_nodes}: a definer that is not a `def` replaces the
      # singleton method an earlier `def self.x` of the walk installed, so the slot is contested and the typing read
      # declines instead of re-typing the replaced body. The definers, each written on the class's own singleton
      # class: `singleton_class.alias_method` / `define_method` / `remove_method` / `undef_method` / `attr_*` and its
      # `class_eval` family and `send` (bare, `self.` or a constant's `singleton_class`), `define_singleton_method`,
      # and in a `class << self` body the receiverless calls of the same names with `alias` and `undef`. Certain or
      # possible alike; a call whose rewritten names are not all literal contests every slot the owner holds so far.
      # Under an `instance_eval` split (`defs_singleton`) only `alias` and `undef` bind on the singleton; its calls
      # stay instance-side.
      def supersede_singleton_def_nodes(node, qualified_prefix, in_singleton_class, defs_singleton, accumulator,
                                        def_owner_prefix)
        return unless accumulator.is_a?(SingletonDefTable) && defs_singleton != :unnameable

        owner_prefix = def_owner_prefix || qualified_prefix
        current = owner_prefix.empty? ? nil : owner_prefix.join("::")
        owner, names =
          case node
          when Prism::AliasMethodNode, Prism::UndefNode
            [current, singleton_keyword_names(node)] if in_singleton_class || defs_singleton == true
          when Prism::CallNode
            singleton_call_target(node, qualified_prefix, current, in_singleton_class)
          end
        accumulator.supersede(owner, names) if owner && names
      end

      def singleton_keyword_names(node)
        return literal_names_or_all(node.names) if node.is_a?(Prism::UndefNode)

        names = Source::AliasNames.keyword_names(node)
        names ? names.first(1) : :all
      end

      # `[owner, names]` for a singleton definer call {#supersede_singleton_def_nodes} reads, or nil.
      def singleton_call_target(node, qualified_prefix, current, in_singleton_class)
        receiver = node.receiver
        if !in_singleton_class && singleton_class_of_receiver?(receiver)
          [singleton_class_owner(node, receiver.receiver, qualified_prefix, current), singleton_naming_call_names(node)]
        elsif receiver.nil? || receiver.is_a?(Prism::SelfNode)
          [current, in_singleton_class ? singleton_naming_call_names(node) : define_singleton_method_names(node)]
        end
      end

      # The singleton names a naming call on the singleton class replaces, `:all` where they are not all literal,
      # or nil for another call. `attr_writer` replaces only `x=`, `attr_reader` only `x`. A `class_eval`-family or
      # `send` call may replace any name, so it is `:all`.
      def singleton_naming_call_names(node)
        arguments = node.arguments&.arguments || []
        case node.name
        when *SURFACE_EVAL_CALLS, *SURFACE_SEND_CALLS then :all
        when :alias_method then literal_names_or_all(arguments.first(1))
        when :define_method then define_singleton_method_names(node, :define_method)
        when :remove_method, :undef_method then literal_names_or_all(arguments)
        when *ATTR_MACROS
          names = literal_names_or_all(arguments)
          return names if names == :all

          names.flat_map do |base|
            [(base unless node.name == :attr_writer), (:"#{base}=" unless node.name == :attr_reader)].compact
          end
        end
      end

      def define_singleton_method_names(node, call = :define_singleton_method)
        return nil unless node.name == call

        literal_names_or_all(node.arguments&.arguments&.first(1) || [])
      end

      def literal_names_or_all(arguments)
        names = arguments.map { |argument| literal_method_name(argument) }
        names.empty? || names.any?(&:nil?) ? :all : names
      end

      # One singleton slot write, through {SingletonDefTable#write} when the walk tracks certainty.
      def write_singleton_slot(accumulator, class_name, name, def_node, node, other = nil, possible: false)
        if accumulator.is_a?(SingletonDefTable)
          accumulator.write(class_name, name, def_node, node, other, possible: possible)
        else
          (accumulator[class_name] ||= {})[name] = def_node
        end
      end

      # `module_function :a, :b` retro-marks named siblings as module-functions: registers on the module's singleton
      # side each `DefNode` {ModuleFunctionState.each_singleton_copy} resolves among the body's direct `statements`.
      # Non-symbol arguments and names with no matching `def` are skipped (a miss degrades to today's `Dynamic`).
      def record_module_function_names(node, qualified_prefix, statements, accumulator)
        return if qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        ModuleFunctionState.each_singleton_copy(node, statements) do |name, def_node|
          write_singleton_slot(accumulator, class_name, name, def_node, node, def_node)
        end
      end

      # Adds one declaration site's header nesting to the per-class table, under each ancestor NAME the site
      # wrote plus one unkeyed entry.
      #
      # Issue #728 — the keyed entries are the answer proper: `Foo`'s superclass `Base` and the `Helper` a
      # rooted reopen of `Foo` includes are resolved in different crefs by Ruby, and a per-class chain can
      # only give them the same one. Two sites that write the SAME name still union, most-qualified first,
      # since one table cannot say which of two spellings a later reader meant.
      #
      # The unkeyed entry ({Scope::DiscoveryIndex::UNKEYED_HEADER_NESTING}) is that union over every
      # ancestor-naming site, and it
      # answers an ancestor name no site recorded under its own key — a mixin the includes walk attributes
      # to a class from OUTSIDE its declaration (`Recv.class_eval { include M }`), or a dynamic `include`
      # argument this walk cannot render. It is the pre-#728 answer, so such a name is unchanged rather than
      # degraded, and a shorter list there would drop an ancestor edge, the false-positive direction.
      def add_header_nesting(table, name, entries, ancestor_names)
        bucket = { Scope::DiscoveryIndex::UNKEYED_HEADER_NESTING => entries }
        ancestor_names.each { |raw| bucket[raw] = entries }
        merge_header_nesting_bucket(table, name, bucket)
      end

      # {#add_header_nesting} over a whole table, for the per-file and cross-file merges.
      def merge_header_nestings(target, incoming)
        incoming.each { |name, bucket| merge_header_nesting_bucket(target, name, bucket) }
        target
      end

      # Merges one class's bucket into the table WITHOUT mutating what is already there: a per-file table is
      # merged into a shallow `dup` of the cross-file seed, whose buckets the seed still owns.
      def merge_header_nesting_bucket(table, name, incoming)
        existing = table[name]
        return table[name] = frozen_bucket(incoming) if existing.nil?

        merged = existing.dup
        incoming.each do |raw, entries|
          previous = merged[raw]
          merged[raw] = previous.nil? ? entries.freeze : union_header_nesting(previous, entries)
        end
        table[name] = merged.freeze
      end

      def frozen_bucket(bucket)
        return bucket if bucket.frozen?

        bucket.each_value(&:freeze).freeze
      end

      # Most-qualified first, so a deeper cref is searched before a shallower one. Two entries of EQUAL depth
      # are ordered alphabetically, which is a stable tie-break and nothing more: `Other::Mixin` precedes
      # `Wrap::Mixin` for no reason Ruby would recognise. Pre-existing and left alone — the rename collision
      # that made the pick load-order-dependent is adjudicated in `Scope`, which declines rather than sorts
      # (#986).
      def union_header_nesting(existing, entries)
        # Issue #986 — the alternatives shape reaches this fold too, not just the rename pass that creates
        # it: the per-file instance path (`merge_ancestry_tables`) merges a file's plain String chains over
        # the cross-file SEED, whose bucket may already hold alternatives. A third site using the nested
        # spelling (`module Outer; class Leaf`, the Zeitwerk default) is exactly that, and unioning its
        # chain into the list split an Array. A third cref is a third alternative, so it joins them.
        if ambiguous_header_nesting?(existing) || ambiguous_header_nesting?(entries)
          return collide_header_nesting(existing, entries)
        end

        return existing if entries.all? { |entry| existing.include?(entry) }

        (existing | entries).sort_by { |entry| [-entry.split("::").size, entry] }.freeze
      end

      MIXIN_CALL_NAMES = %i[include prepend].freeze

      # A `self` argument counts as opaque, as the instance side reads it: a `Target.send(:extend, self)` written in a
      # module body reaches here with the module no table records under `Target`.
      def opaque_mixin_argument?(arg)
        Source::ConstantPath.qualified_name(arg).nil? && !DeclarationWalk::Rules.module_new_call?(arg)
      end

      MIXIN_KINDS = %i[include prepend extend].freeze
      SEND_CALL_NAMES = %i[send public_send __send__].freeze
      EXTEND_MIXIN_NAMES = %i[extend].freeze
      private_constant :MIXIN_KINDS, :SEND_CALL_NAMES, :EXTEND_MIXIN_NAMES

      # `[kind, arguments, via_send]` for a call that mixes modules in — `include` / `prepend` / `extend`, or
      # `send(:include, M)` and its `public_send` / `__send__` twins with a literal first argument — else nil.
      # A computed `send` name is not read as a mixin: it names nothing this walk could taint by.
      def mixin_call_view(node)
        return [node.name, node.arguments&.arguments || [], false] if MIXIN_KINDS.include?(node.name)
        return unless SEND_CALL_NAMES.include?(node.name)

        arguments = node.arguments&.arguments || []
        first = arguments.first
        return unless first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode)

        # By string: a name literal need not be a valid symbol in its encoding.
        kind = MIXIN_KINDS.find { |candidate| candidate.name == first.unescaped }
        [kind, arguments.drop(1), true] if kind
      end

      INSTANCE_MIXIN_NAMES = %i[include prepend].freeze
      private_constant :INSTANCE_MIXIN_NAMES

      # Issue #526 — `extend M` / `extend self` / bare `module_function`, the singleton-side siblings of
      # {MixinTables.build_discovered_includes}. `extend self` and the bare `module_function` toggle both map the
      # module's own instance defs onto its singleton (recorded as extending ITSELF); `module_function`
      # with symbol arguments already resolves through the existing recording, and the toggle's
      # order-sensitivity (only SUBSEQUENT defs become module functions) is deliberately over-approximated
      # — the extra names only suppress `undefined-method` and enable inference on calls that raise at
      # runtime, both the ADR-5-safe direction.
      #
      # Issue #915 — plus `class << self; include M; end`, the same singleton ancestor spelled through the
      # singleton-class body. It folds like an `extend` because Ruby makes it one.
      def build_discovered_extends(root)
        extend_tables(root).fetch(:extends)
      end

      # {#build_discovered_extends} and the `extend` edges whose order is not a fact ({MixinAccumulator}), from
      # one descent.
      def extend_tables(root)
        accumulator = MixinAccumulator.new
        accumulator.direct_body(MixinEffects.program_statements(root))
        walk_class_extends(root, [], nil, accumulator)
        {
          extends: accumulator.transform_values { |mods| mods.uniq.freeze }.freeze,
          unpositioned: accumulator.unpositioned
        }
      end

      def walk_class_extends(node, qualified_prefix, current_class, accumulator, in_singleton: false,
                             singleton_self: false, singleton_cref: false)
        return unless node.is_a?(Prism::Node)
        # `END { ... }` runs at interpreter exit — nothing inside it executes during the class
        # body, so its `module_function` / `extend` calls cannot reshape the singleton surface.
        return if node.is_a?(Prism::PostExecutionNode)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          return walk_extends_declaration(node, qualified_prefix, accumulator, current_class,
                                          singleton_cref)
        when Prism::SingletonClassNode
          # Issue #915 — `class << self` opens the enclosing declaration's OWN singleton, so an `include`
          # written in it is the same singleton ancestor an `extend` in the class body would add. Issue #3010 —
          # `class << Const` is followed too; `class << obj` names something this walk cannot resolve to a class.
          # Nested declarations inside the body take the `ClassNode` branch above and reset the flag with
          # their own owner, so the marker cannot leak past the singleton body it belongs to.
          return walk_extends_singleton_class(node, qualified_prefix, current_class, accumulator,
                                              in_singleton, singleton_self, singleton_cref)
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
             Prism::ConstantPathOrWriteNode
          return if walk_extends_meta_new?(node, qualified_prefix, current_class, accumulator,
                                           in_singleton, singleton_self, singleton_cref)
        when Prism::CallNode
          record_extend_call(node, qualified_prefix, current_class, accumulator, in_singleton: in_singleton)
          if DeclarationWalk::Rules.receiver_eval_call?(node)
            return walk_eval_extends_call(node, qualified_prefix, current_class, accumulator,
                                          in_singleton: in_singleton, singleton_self: singleton_self,
                                          singleton_cref: singleton_cref)
          end
          if node.block.is_a?(Prism::BlockNode) &&
             extends_block_handled?(node, qualified_prefix, current_class, accumulator,
                                    in_singleton, singleton_self, singleton_cref)
            return
          end
        end

        walk_extends_children(node, qualified_prefix, current_class, accumulator, in_singleton, singleton_self,
                              singleton_cref)
      end

      # The generic descent of {#walk_class_extends}; a hook's body walks with its parameters in scope.
      def walk_extends_children(node, qualified_prefix, current_class, accumulator, in_singleton, singleton_self,
                                singleton_cref)
        hook_params = MixinEffects.hook_def_params(node)
        if hook_params
          return accumulator.with_hook_params(hook_params) do
            walk_extends_children_plain(node, qualified_prefix, current_class, accumulator, in_singleton,
                                        singleton_self, singleton_cref)
          end
        end

        walk_extends_children_plain(node, qualified_prefix, current_class, accumulator, in_singleton, singleton_self,
                                    singleton_cref)
      end

      def walk_extends_children_plain(node, qualified_prefix, current_class, accumulator, in_singleton,
                                      singleton_self, singleton_cref)
        node.rigor_each_child do |child|
          walk_class_extends(child, qualified_prefix, current_class, accumulator,
                             in_singleton: in_singleton, singleton_self: singleton_self,
                             singleton_cref: singleton_cref)
        end
      end

      # The `class <<` arm of {#walk_class_extends}: the expression evaluates in the enclosing
      # context while the body is the singleton's — `class << self` keeps the enclosing owner
      # (its `include` is the singleton ancestor #915 folds), `class << Const` takes the class the
      # constant names (#3010), other operands walk ownerless.
      # `self` inside is the singleton — `self::` receivers decline — and the lexical cref
      # below is unnameable in every case.
      def walk_extends_singleton_class(node, qualified_prefix, current_class, accumulator,
                                       in_singleton, singleton_self, singleton_cref)
        walk_class_extends(node.expression, qualified_prefix, current_class, accumulator,
                           in_singleton: in_singleton, singleton_self: singleton_self,
                           singleton_cref: singleton_cref)
        return unless node.body
        return walk_extends_constant_singleton(node, qualified_prefix, accumulator) if constant_singleton_class?(node)

        # `class << self` keeps the owner only at the FIRST level — nested inside a
        # singleton body, `self` IS the singleton and `class << self` opens the
        # singleton's own singleton (`#<Class:#<Class:C>>`), which nothing names.
        opens_self = node.expression.is_a?(Prism::SelfNode) && !in_singleton
        accumulator.direct_body(node.body) if opens_self && accumulator.direct?(node)
        accumulator.class_body(node.body) if opens_self
        walk_class_extends(node.body, qualified_prefix, opens_self ? current_class : nil,
                           accumulator, in_singleton: opens_self,
                                        singleton_self: true, singleton_cref: true)
      end

      # Issue #3010 — `class << Const` opens the class object's own singleton class, so an `include` / `prepend` in its
      # body is a singleton mixin on `Const`, as one in `class << self` inside `Const`'s body is. The body walks with
      # the class `Const` resolves to from the lexical scope ({#constant_singleton_owners}, the class its `def`s record
      # under) as owner. Its edges are positioned only where the order is a fact: the `class <<` is a direct statement
      # of a file that declares that class, and no more-nested name the constant could denote is left. Anywhere else (a
      # method body, a conditional, another file) they are unpositioned, and a prepend also records, unpositioned, on
      # every other name the constant can denote ({#record_constant_singleton_candidates}), as #2998's
      # `Const.singleton_class.prepend P` does.
      def walk_extends_constant_singleton(node, qualified_prefix, accumulator)
        owner, others = constant_singleton_owners(node, qualified_prefix)
        if others.empty? && accumulator.direct?(node) && DeclarationWalk::Rules.eval_file_declared_names(node).include?(owner)
          accumulator.direct_body(node.body)
        end
        walk_class_extends(node.body, qualified_prefix, owner, accumulator,
                           in_singleton: true, singleton_self: true, singleton_cref: true)
        record_constant_singleton_candidates(node.body, others, accumulator)
      end

      # Each candidate class past the owner takes the body's prepends unpositioned; an argument that names no module
      # (`prepend(*MODS)`) leaves its singleton set unknown, as {MixinEffects.taint_unrecorded_mixin} reads it on the
      # owner.
      def record_constant_singleton_candidates(body, candidates, accumulator)
        return if candidates.empty?

        each_singleton_body_prepend(body) do |call|
          candidates.each do |candidate|
            next unless record_extend_targets(call, candidate, accumulator).empty?

            accumulator.taint(candidate, :extend, unnamed: true)
          end
        end
      end

      # A `class << Const` whose operand is a constant read (`class << Foo = expr` opens an object's singleton).
      def constant_singleton_class?(node)
        node.expression.is_a?(Prism::ConstantReadNode) || node.expression.is_a?(Prism::ConstantPathNode)
      end

      # `[owner, others]` for a `class << Const`: the class the constant resolves to from the lexical scope
      # ({#singleton_class_prefix}, where the body's `def`s record), and the other names it can denote from there
      # ({#constant_receiver_candidates}). `others` is empty when the constant can denote one name only, when it names
      # the enclosing class itself (`class << Foo` inside `class Foo`, which {#singleton_class_prefix} reads as
      # `class << self`), or when the owner is the innermost candidate and the file declares it ahead of the `class <<`
      # ({#declared_before?}): Ruby resolves the constant when the statement runs, so a nested class the file declares
      # later does not exist yet there.
      def constant_singleton_owners(node, qualified_prefix)
        owner = singleton_class_prefix(node, nil, qualified_prefix).join("::")
        candidates = constant_receiver_candidates(node.expression, qualified_prefix)
        # One candidate needs no re-parse: whichever statement declares it, the constant can name nothing else.
        return [owner, EMPTY_PREFIX] if candidates.size == 1 || qualified_prefix.join("::") == owner
        return [owner, EMPTY_PREFIX] if candidates.first == owner && declared_before?(node, owner)

        [owner, candidates - [owner]]
      end

      # Issue #3010 — whether `node`'s file declares `name` (a `class` / `module` declaration or a bare constant
      # write) at a statement that starts ahead of `node`. Asked only where a `class << Const` has a nested candidate
      # the file declares, so it re-parses the file rather than keep a table every file would pay for.
      def declared_before?(node, name)
        source = node.location.send(:source).source
        declaration_before?(Prism.parse(source).value, EMPTY_PREFIX, name, node.location.start_offset)
      end

      def declaration_before?(node, prefix, name, limit)
        return false unless node.is_a?(Prism::Node) && node.location.start_offset < limit

        case node
        when Prism::ClassNode, Prism::ModuleNode
          child = Source::ConstantPath.declaration_prefix(prefix, node.constant_path)
          return false if child.nil?
          return true if child.join("::") == name

          return declaration_before?(node.body, child, name, limit)
        when Prism::ConstantWriteNode
          return true if (prefix + [node.name.to_s]).join("::") == name
        when Prism::DefNode, Prism::SingletonClassNode
          # A `def` body declares no constant, and a `class <<` body's are the singleton class's.
          return false
        end
        node.rigor_each_child { |child| return true if declaration_before?(child, prefix, name, limit) }
        false
      end

      # The receiverless or `self.` `prepend` calls (direct or `send` spelling) of a `class <<` body, outside any
      # nested `def` or declaration body.
      def each_singleton_body_prepend(node, &)
        return unless node.is_a?(Prism::Node)
        return if CODE_BODY_NODES.any? { |klass| node.is_a?(klass) }

        if node.is_a?(Prism::CallNode) && lexical_self_receiver?(node.receiver) &&
           mixin_call_view(node)&.first == :prepend
          yield node
        end
        node.rigor_each_child { |child| each_singleton_body_prepend(child, &) }
      end

      # The declaration arm of {#walk_class_extends}: under an unnameable cref a bare/`self::`
      # header opens `#<singleton>::Name` — ownerless; nameable headers re-anchor at a
      # real cref.
      def walk_extends_declaration(node, qualified_prefix, accumulator, current_class,
                                   singleton_cref)
        self_decl = DeclarationWalk::Rules.self_anchored_decl_prefix(node.constant_path,
                                                                     current_class && [current_class])
        child_prefix = self_decl ||
                       Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
        return unless child_prefix && node.body

        child_cref = DeclarationWalk::Rules.unnameable_decl?(node, self_decl, singleton_cref)
        accumulator.direct_body(node.body) if accumulator.direct?(node)
        accumulator.body_statements(node.body)
        accumulator.class_body(node.body)
        walk_class_extends(node.body, child_cref ? [] : child_prefix,
                           child_cref ? nil : child_prefix.join("::"), accumulator,
                           singleton_cref: child_cref)
      end

      # The block-carrying calls of {#walk_class_extends} beyond `class_eval`-family eval:
      # `X.instance_eval { extend M }` extends X — the receiver resolution is the eval walk's
      # (only `def` rebinding differs, and defs are not this table's facts) — while a
      # `define_method` body or an unnamed `Class.new { … }`-family block runs on an object
      # nothing names, so its `extend` walks ownerless.
      def walk_extends_block_call(node, qualified_prefix, current_class, accumulator,
                                  in_singleton, singleton_self, singleton_cref)
        if %i[instance_eval instance_exec].include?(node.name)
          return walk_eval_extends_call(node, qualified_prefix, current_class, accumulator,
                                        in_singleton: in_singleton, singleton_self: singleton_self,
                                        singleton_cref: singleton_cref)
        end
        return unless node.name == :define_method || DeclarationWalk::Rules.meta_new_constant_rvalue?(node)

        walk_extends_opaque_block(node, qualified_prefix, current_class, accumulator,
                                  in_singleton, singleton_self, singleton_cref)
      end

      # What the extends walk does with a block-carrying call: `:rebound` (its own eval / `define_method` / meta-new
      # handling), `:skip` (the block runs on an object this walk cannot vouch for, as an instance's `synchronize`
      # or an `on_load` hook, or may never run: `Registry.each { … }`), or `:descend` (it provably runs once with the
      # body's `self`, #1592, and its direct statements are positioned when the call itself is).
      def extends_block_plan(node, accumulator)
        return :rebound if rebinding_extends_block?(node)
        return :skip unless runs_body_block_once?(node, accumulator)

        accumulator.direct_body(node.block.body) if accumulator.direct?(node)
        :descend
      end

      # True when {#extends_block_plan} settled the block (walked as rebound, or skipped); false leaves it to the
      # generic descent.
      def extends_block_handled?(node, qualified_prefix, current_class, accumulator, in_singleton, singleton_self,
                                 singleton_cref)
        case extends_block_plan(node, accumulator)
        when :skip
          taint_skipped_singleton_rewrites(node.block, qualified_prefix, current_class, accumulator)
          true
        when :rebound
          walk_extends_block_call(node, qualified_prefix, current_class, accumulator,
                                  in_singleton, singleton_self, singleton_cref)
          true
        else false
        end
      end

      # Issue #1906 — a block the extends walk skips may still run, and a `singleton_class` call in it, or in a `def`
      # it holds (`[1].each { D.singleton_class.alias_method :own, :other }` in a method body,
      # `to_prepare do def helper = D.singleton_class.alias_method(...) end`), reaches no mark the methods walk records
      # there. Every such call taints the side it may rewrite, as {#singleton_class_rewrite_tainted?} does for one the
      # walk visits; a constant receiver taints every name it can denote from here.
      def taint_skipped_singleton_rewrites(node, qualified_prefix, current_class, accumulator)
        return unless node.is_a?(Prism::Node)

        if node.is_a?(Prism::CallNode) && singleton_class_of_receiver?(node.receiver) && surface_rewriting_call?(node)
          skipped_rewrite_owners(node.receiver.receiver, qualified_prefix, current_class).each do |owner|
            accumulator.taint(owner, :extend)
          end
        end
        node.rigor_each_child do |child|
          taint_skipped_singleton_rewrites(child, qualified_prefix, current_class, accumulator)
        end
      end

      def skipped_rewrite_owners(object, qualified_prefix, current_class)
        return [current_class].compact if object.nil? || object.is_a?(Prism::SelfNode)
        return [] unless object.is_a?(Prism::ConstantReadNode) || object.is_a?(Prism::ConstantPathNode)

        constant_receiver_candidates(object, qualified_prefix)
      end

      ARRAY_ITERATORS = %i[each each_with_index map].freeze
      HASH_ITERATORS = %i[each each_pair each_key each_value map].freeze
      private_constant :ARRAY_ITERATORS, :HASH_ITERATORS

      # A block that provably runs at least once with the class body's `self`: the call is a statement of the
      # body itself (not nested in a `def` or another block) and either `tap` / `then` on a literal (they
      # always yield once, self preserved) or an iterator over a literal that is known non-empty (a
      # non-empty Array or Hash literal, a positive `Integer#times`, an Integer-literal Range that is not empty,
      # `upto` / `downto` in the right order). A constant or variable receiver (`Registry.each`, a lazy `map`) may
      # never yield, so it is not one. The walk then records the block's direct statements as positioned: the
      # block runs where it is written, and a repeated `extend` is idempotent (#1592).
      def runs_body_block_once?(node, accumulator)
        return false unless accumulator.body_block?(node)
        return literal_or_self?(node.receiver) if %i[tap then].include?(node.name)

        non_empty_literal_iteration?(node.name, node.receiver, node.arguments&.arguments || [])
      end

      TAP_RECEIVERS = [Prism::IntegerNode, Prism::FloatNode, Prism::StringNode, Prism::SymbolNode, Prism::ArrayNode,
                       Prism::HashNode, Prism::RangeNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode].freeze
      private_constant :TAP_RECEIVERS

      # `tap` / `then` yield once only on a receiver whose method nobody overrode: a literal. A constant or `self`
      # may define its own `tap` (`def self.tap`), a promise's `then` defers, and a receiverless call may reach a
      # class-level DSL method, so none of those is read as running.
      def literal_or_self?(receiver)
        TAP_RECEIVERS.any? { |kind| receiver.is_a?(kind) }
      end

      def non_empty_literal_iteration?(name, receiver, arguments)
        case receiver
        when Prism::ArrayNode
          ARRAY_ITERATORS.include?(name) && !receiver.elements.empty? &&
            receiver.elements.none?(Prism::SplatNode)
        when Prism::HashNode
          HASH_ITERATORS.include?(name) && !receiver.elements.empty? &&
            receiver.elements.all?(Prism::AssocNode)
        when Prism::IntegerNode then integer_iteration_runs?(name, receiver.value, arguments)
        when Prism::ParenthesesNode then non_empty_range_iteration?(name, receiver, arguments)
        else false
        end
      end

      def integer_iteration_runs?(name, value, arguments)
        limit = arguments.first
        case name
        when :times then arguments.empty? && value.positive?
        when :upto then arguments.size == 1 && limit.is_a?(Prism::IntegerNode) && value <= limit.value
        when :downto then arguments.size == 1 && limit.is_a?(Prism::IntegerNode) && value >= limit.value
        else false
        end
      end

      def positive_integer_literal?(node) = node.is_a?(Prism::IntegerNode) && node.value.positive?

      # `(1..3).each` and `(1..3).map`, and `(1..3).step(2)` with a positive literal step.
      def non_empty_range_iteration?(name, parens, arguments)
        range = parens.body.is_a?(Prism::StatementsNode) && parens.body.body.size == 1 ? parens.body.body.first : nil
        return false unless range.is_a?(Prism::RangeNode)
        return false unless range.left.is_a?(Prism::IntegerNode) && range.right.is_a?(Prism::IntegerNode)

        low = range.left.value
        high = range.right.value
        return false unless range.exclude_end? ? low < high : low <= high

        case name
        when :each, :map then arguments.empty?
        when :step then positive_integer_literal?(arguments.first) && arguments.size == 1
        else false
        end
      end

      # Whether {#walk_extends_block_call} owns this block-carrying call. Any other block (`[1].each { extend M }`,
      # `included do extend M end`) keeps the enclosing `self`, so the generic descent walks it (#1592).
      def rebinding_extends_block?(node)
        INSTANCE_EVAL_CALLS.include?(node.name) || node.name == :define_method || DeclarationWalk::Rules.meta_new_constant_rvalue?(node)
      end

      # A block whose `self` is an object this walk cannot name — a `define_method` body (its
      # self is the receiver's instance at call time) or an unnamed `Class.new { … }`-family
      # block — walks ownerless with an unnameable self, while the call's receiver and
      # arguments stay in the enclosing context.
      def walk_extends_opaque_block(node, qualified_prefix, current_class, accumulator,
                                    in_singleton, singleton_self, singleton_cref)
        if node.receiver
          walk_class_extends(node.receiver, qualified_prefix, current_class, accumulator,
                             in_singleton: in_singleton, singleton_self: singleton_self,
                             singleton_cref: singleton_cref)
        end
        node.arguments&.arguments&.each do |arg|
          walk_class_extends(arg, qualified_prefix, current_class, accumulator,
                             in_singleton: in_singleton, singleton_self: singleton_self,
                             singleton_cref: singleton_cref)
        end
        node.block.rigor_each_child do |child|
          walk_class_extends(child, qualified_prefix, nil, accumulator,
                             singleton_self: true, singleton_cref: singleton_cref)
        end
      end

      # `K = Class.new { extend M }` extends the block's class — the nameable `K`, or ownerless
      # when the write lands on an unnameable cref — never the enclosing one. Returns whether a
      # meta-new block body was found (the write's other children are left to the caller).
      def walk_extends_meta_new?(node, qualified_prefix, current_class, accumulator, in_singleton,
                                 singleton_self, singleton_cref)
        call = DeclarationWalk::Rules.meta_new_block_call(node)
        return false unless call

        meta_owner = MixinEffects.meta_new_mixin_owner(node, qualified_prefix, singleton_cref,
                                                       current_class && [current_class])
        # The block rebinds only `self` — `Module.nesting` stays lexical — so the cref
        # flag passes through unchanged, matching the includes twin.
        body_cref = singleton_cref
        # The factory call's receiver and arguments evaluate in the ENCLOSING context;
        # the block is the class body of the class the write names.
        if call.receiver
          walk_class_extends(call.receiver, qualified_prefix, current_class, accumulator,
                             in_singleton: in_singleton, singleton_self: singleton_self,
                             singleton_cref: singleton_cref)
        end
        call.arguments&.arguments&.each do |arg|
          walk_class_extends(arg, qualified_prefix, current_class, accumulator,
                             in_singleton: in_singleton, singleton_self: singleton_self,
                             singleton_cref: singleton_cref)
        end
        if (body = DeclarationWalk::Rules.meta_new_block_body(node))
          walk_class_extends(body, qualified_prefix, meta_owner, accumulator,
                             singleton_cref: body_cref)
        end
        true
      end

      # `X.class_eval { ... }` runs the block as X's class body — its `extend` / `module_function`
      # calls land on X's singleton surface, not the enclosing class's. An unnameable receiver
      # declines to ownerless rather than filing the body's calls under the lexical class. A
      # bare or `self` receiver keeps the enclosing self — `class << self`'s eval block opens
      # the singleton's own body, so `include` inside is still the singleton-side edge — while
      # a receiver that names nothing keeps the self marker so `self::` receivers inside
      # decline instead of re-anchoring to the lexical class.
      def walk_eval_extends_call(node, qualified_prefix, current_class, accumulator, in_singleton:,
                                 singleton_self: false, singleton_cref: false)
        unnameable = singleton_self || (singleton_cref && current_class.nil?)
        eval_class = eval_receiver_name(node, qualified_prefix, current_class&.split("::"),
                                        unnameable_self: unnameable)
        # `instance_eval` keeps the instance-mixin channel for a class receiver:
        # `include`/`extend` inside are calls on the receiver-as-module (`X.instance_eval
        # { include M }` is `X.include(M)`, an include edge), not singleton mixins. Inside
        # an already-singleton body a bare/`self` `instance_eval` re-evaluates the SAME
        # singleton self — `class << S; instance_eval { include M }` mixes M into
        # `#<Class:S>`, the same singleton-ancestor edge a `class_eval` there produces —
        # while `def`/`alias` bind on the singleton's own singleton either way.
        eval_in_singleton = eval_body_singleton?(node, in_singleton) &&
                            (!INSTANCE_EVAL_CALLS.include?(node.name) ||
                             (in_singleton && !DeclarationWalk::Rules.eval_named_receiver?(node)))
        if node.receiver
          walk_class_extends(node.receiver, qualified_prefix, current_class, accumulator,
                             in_singleton: in_singleton, singleton_self: singleton_self,
                             singleton_cref: singleton_cref)
        end
        node.arguments&.arguments&.each do |arg|
          walk_class_extends(arg, qualified_prefix, current_class, accumulator,
                             in_singleton: in_singleton, singleton_self: singleton_self,
                             singleton_cref: singleton_cref)
        end
        # The block's self is the receiver — nameable only when the receiver resolved. A bare
        # or `self` receiver keeps the enclosing self's (un)nameability instead.
        child_unnameable = DeclarationWalk::Rules.eval_named_receiver?(node) ? eval_class.nil? : unnameable
        node.block.rigor_each_child do |child|
          walk_class_extends(child, qualified_prefix, eval_class, accumulator,
                             in_singleton: eval_in_singleton, singleton_self: child_unnameable,
                             singleton_cref: singleton_cref)
        end
      end

      # The class a `*_eval` / `*_exec` block body opens — the nameable receiver, or nil when the
      # receiver is not nameable ({DeclarationWalk::Rules.eval_receiver_prefix} spelled as a name). `self_prefix` is the
      # enclosing body's self — the owner the extends walk already tracks — so a `self` / bare /
      # `self::` receiver inside an eval body names the enclosing eval's class.
      def eval_receiver_name(node, qualified_prefix, self_prefix = nil, unnameable_self: false)
        # A nil `self_prefix` means the enclosing self names nothing — `class << obj`, an
        # ownerless eval or `#<singleton>::D` body. Substituting the lexical prefix there would
        # file the body's edges under a class `self` never is, so the receiver declines.
        prefix = DeclarationWalk::Rules.eval_receiver_prefix(node, self_prefix || EMPTY_PREFIX, qualified_prefix,
                                                             unnameable_self: unnameable_self)
        prefix && !prefix.empty? ? prefix.join("::") : nil
      end

      # Inside a `class << self` body the mixin calls are the singleton-side ones and `extend` is not:
      # `class << self; extend M; end` puts M on the singleton's OWN singleton, one level further out than
      # anything this table describes, and `module_function` in a singleton body is not the scope toggle
      # {#build_discovered_extends} over-approximates. So the two arms are disjoint rather than additive.
      # Inside `class << self` the instance walk is ownerless, so this walk also keeps the instance-side taints
      # (`base.include X` in a hook written there).
      def record_extend_call(node, qualified_prefix, current_class, accumulator, in_singleton: false)
        return record_module_function(node, current_class, accumulator, in_singleton) if node.name == :module_function

        MixinEffects.taint_opaque_eval(node, current_class, accumulator)
        return if singleton_class_rewrite_tainted?(node, qualified_prefix, current_class, accumulator,
                                                   in_singleton: in_singleton)

        kind, arguments, via_send = mixin_call_view(node)
        if kind.nil?
          # Inside `class << self` a computed `include` / `prepend` reaches the singleton side; an `extend` reaches the
          # singleton's own singleton, which nothing names.
          kinds = in_singleton ? INSTANCE_MIXIN_NAMES : EXTEND_MIXIN_NAMES
          return MixinEffects.taint_computed_mixin_send(node, current_class, accumulator, kinds, :extend,
                                                        in_singleton: in_singleton)
        end

        effects = MixinEffects.mixin_effects(node, kind, qualified_prefix, current_class, accumulator,
                                             in_singleton: in_singleton)
                              .select { |_owner, side| side == :extend || in_singleton }
        return if effects.empty?
        # A `send` spelling is recorded only on the lexical `self` (#2995); `Const.send(:extend, M)` stays a taint.
        return if (!via_send || lexical_self_receiver?(node.receiver)) &&
                  singleton_mixin_recorded?(node, kind, qualified_prefix, current_class, accumulator, in_singleton)

        # Issue #2991 — as in {MixinTables.record_mixin_call}: an unrecorded instance-side call (a hook's
        # `base.include M` written in `class << self`) lists its names, or the unnamed marker.
        MixinEffects.taint_unrecorded_mixin(node, kind, arguments, effects, accumulator)
      end

      # Issue #1752 — a call that rewrites a singleton class reached through `singleton_class` (`singleton_class.
      # class_eval { def x }`, `singleton_class.send(:define_method, :x)`, `Const.singleton_class.prepend(M)`,
      # `Const.singleton_class.send(:include, M)`) puts methods or modules on that singleton class that no edge
      # records, so its singleton side is unpositioned: the owner is the enclosing class for a bare or `self.`
      # receiver, else the constant. True when the call was handled here (taint, or a recorded `include` / `prepend`).
      #
      # Issue #1906 — a naming call with literal names ({#singleton_class_named_call?}) marks only its names instead,
      # but only where it is a direct statement (a top-level statement, or one of a direct declaration body or of a
      # block that runs there once): there the methods walk records those marks under the same owner. In a method
      # body, a hook or a conditional it may run on a receiver or at a time the marks cannot place, so it still taints.
      def singleton_class_rewrite_tainted?(node, qualified_prefix, current_class, accumulator, in_singleton: false)
        receiver = node.receiver
        return false unless singleton_class_of_receiver?(receiver) && surface_rewriting_call?(node)
        return false if singleton_class_named_call?(node) && accumulator.direct?(node)

        owner = singleton_class_owner(node, receiver.receiver, qualified_prefix, current_class)
        return false if owner.nil?

        # Inside `class << self` a bare `singleton_class` is the singleton's own singleton, one level up from the
        # owner's extend side, so that call stays a taint.
        up_level = in_singleton && lexical_self_receiver?(receiver.receiver)
        if !up_level && singleton_class_include_recorded?(node, owner, accumulator)
          record_prepend_candidates(node, receiver.receiver, qualified_prefix, owner, accumulator)
          return true
        end

        # Issue #2994 — an `include` / `prepend` whose argument names no module (`singleton_class.include(*MODS)`)
        # leaves the owner's singleton set unknown, as {MixinEffects.taint_unrecorded_mixin} reads an `extend(*EMODS)`.
        accumulator.taint(owner, :extend, unnamed: unnamed_singleton_include?(node))
        true
      end

      def unnamed_singleton_include?(node)
        INSTANCE_MIXIN_NAMES.include?(node.name) &&
          (node.arguments&.arguments || []).any? { |arg| opaque_mixin_argument?(arg) }
      end

      # Issue #2094 — `Float.singleton_class.include(Ext)` (or `prepend`, which the extend table cannot order, so the
      # edge is unpositioned as every receiver-form edge is) puts `Ext` on the singleton side as `Float.extend(Ext)`
      # does, the fold #915 gives `class << self; include M`. A `send` spelling or an argument that is not a constant
      # stays a taint.
      #
      # Issue #2998 — a prepend, spelt directly or as `send(:prepend, P)`, is recorded, and the methods walk files it as
      # a singleton prepend ({#record_own_singleton_prepend}). One on the enclosing class's own `singleton_class` (a
      # bare or `self.` receiver) runs where it is written, as `prepend P` in `class << self` does, so a direct
      # statement of the body is positioned; a constant receiver's stays unpositioned.
      def singleton_class_include_recorded?(node, owner, accumulator)
        kind, sent, = mixin_call_view(node)
        prepend = kind == :prepend
        arguments = prepend ? sent : node.arguments&.arguments || []
        return false unless prepend || node.name == :include
        return false if arguments.empty? || arguments.any? { |arg| Source::ConstantPath.qualified_name(arg).nil? }

        positioned = prepend && lexical_self_receiver?(node.receiver.receiver)
        !record_extend_targets(node, owner, accumulator, positioned: positioned).empty?
      end

      # Issue #2998 — a constant receiver's `Const.singleton_class.prepend P` also records the edge, unpositioned, under
      # every other name the constant can denote from the call site, the names the methods walk files its
      # singleton-prepend entry under ({#singleton_prepend_owners}): which class Ruby reaches is not a fact here, so
      # each candidate's typing read declines where the prepend could answer.
      def record_prepend_candidates(node, object, qualified_prefix, owner, accumulator)
        return unless mixin_call_view(node)&.first == :prepend
        return unless object.is_a?(Prism::ConstantReadNode) || object.is_a?(Prism::ConstantPathNode)

        (constant_receiver_candidates(object, qualified_prefix) - [owner]).each do |candidate|
          record_extend_targets(node, candidate, accumulator)
        end
      end

      # A bare or `self.` receiver: the lexical `self`.
      def lexical_self_receiver?(receiver)
        receiver.nil? || receiver.is_a?(Prism::SelfNode)
      end

      # A bare, `self.` or constant receiver's `singleton_class` call.
      def singleton_class_of_receiver?(receiver)
        receiver.is_a?(Prism::CallNode) && receiver.name == :singleton_class && receiver.arguments.nil?
      end

      # An `attr_*`, `alias_method`, `define_method` or `remove_method` on a singleton class
      # (`singleton_class.attr_accessor :conf`, `singleton_class.alias_method :o2, :own`) rewrites only the names it
      # spells, so it makes those names' singleton envelopes opaque and contested ({#record_singleton_class_names}) and
      # leaves the rest of the singleton side readable. One whose rewritten name is not a literal Symbol or String
      # (`attr_accessor(*KEYS)`, `alias_method name, :own`, `define_method(sym)`), and any other surface call there
      # (`class_eval`, `send`, `prepend`), still taints the side: the own-definer read would otherwise answer the body
      # Ruby replaced (`definer_resolution_witness_spec.rb`).
      def singleton_class_named_call?(node)
        !singleton_class_rewritten_names(node).nil?
      end

      # Issue #1906 — the names a singleton-class call rewrites, or nil where it is not one of the naming forms or
      # does not spell every rewritten name as a literal. `alias_method` rewrites its new name (the aliased one keeps
      # its body), `define_method` its first argument, `remove_method` and `attr_*` every argument.
      def singleton_class_rewritten_names(node)
        arguments = node.arguments&.arguments || []
        rewritten = case node.name
                    when :alias_method, :define_method then arguments.first(1)
                    when :remove_method then arguments
                    else ATTR_MACROS.include?(node.name) && arguments
                    end
        return nil if !rewritten || arguments.empty? || !arguments.all? { |argument| literal_argument?(node, argument) }

        rewritten.map { |argument| literal_method_name(argument) }
      end

      # `define_method(:x, body)` takes a body that is not a name; every other argument must be a literal name.
      def literal_argument?(node, argument)
        return true if node.name == :define_method && !argument.equal?(node.arguments.arguments.first)

        !literal_method_name(argument).nil?
      end

      def singleton_class_owner(node, object, qualified_prefix, current_class)
        return current_class if object.nil? || object.is_a?(Prism::SelfNode)

        rendered = Source::ConstantPath.qualified_name_or_nil(object)
        return nil if rendered.nil?
        return rendered if Source::ConstantPath.rooted?(object) || qualified_prefix.empty?

        DeclarationWalk::Rules.eval_constant_receiver_prefix(node, object, rendered, qualified_prefix).join("::")
      end

      # The bare `module_function` toggle: the module extends itself. A direct statement only.
      def record_module_function(node, current_class, accumulator, in_singleton)
        return unless current_class && node.receiver.nil? && !in_singleton && ModuleFunctionState.extends_self?(node)

        (accumulator[current_class] ||= []) << current_class
        accumulator.note(node, current_class, :extend, [current_class], complete: true)
      end

      # Records the singleton-side edges of a receiverless or `self.` `extend` (or, inside `class << self`,
      # `include` / `prepend`), and of their `send` spellings (#2995). False when it recorded nothing.
      def singleton_mixin_recorded?(node, kind, qualified_prefix, current_class, accumulator, in_singleton)
        unless lexical_self_receiver?(node.receiver)
          return receiver_extend_recorded?(node, kind, qualified_prefix, accumulator)
        end
        return false unless current_class
        return false unless in_singleton ? MIXIN_CALL_NAMES.include?(kind) : kind == :extend

        !record_extend_targets(node, current_class, accumulator).empty?
      end

      # Issue #2094 — the receiver form, `Float.extend(Ext)`: the singleton twin of #1722's `Integer.include(Ext)`,
      # filed under the class the constant receiver names ({MixinEffects.prepend_call_receiver}) and, like that form,
      # unpositioned wherever it is written ({MixinAccumulator#note}). A `self` argument names the receiver, not the
      # enclosing class, so a call with one stays a taint. A constant receiver names the same class inside
      # `class << self`, so the walk's singleton flag does not matter here.
      def receiver_extend_recorded?(node, kind, qualified_prefix, accumulator)
        return false if kind != :extend
        return false if (node.arguments&.arguments || []).any?(Prism::SelfNode)

        owner = MixinEffects.prepend_call_receiver(node, qualified_prefix)
        return false if owner.nil?

        !record_extend_targets(node, owner, accumulator).empty?
      end

      # The table stores search order, not call order: a later `extend` statement prepends its module
      # (`extend A; extend B` → singleton ancestors `[B, A]`) while the arguments of a single
      # `extend A, B` keep call order (`[A, B]`). Prepending each call's argument list preserves both,
      # and consumers iterating the list forward read the same order the singleton ancestry searches.
      #
      # The arguments are {#mixin_call_view}'s, so a `send(:extend, M)` (#2995) reads `M` and not its name literal.
      # `positioned` says a receiver-form call still runs where it is written ({#singleton_class_include_recorded?}).
      def record_extend_targets(node, current_class, accumulator, positioned: false)
        targets = []
        arguments = mixin_call_view(node)[1]
        arguments.each do |arg|
          target = arg.is_a?(Prism::SelfNode) ? current_class : Source::ConstantPath.qualified_name(arg)
          targets << target if target
        end
        return targets if targets.empty?

        list = (accumulator[current_class] ||= [])
        # A repeated `extend` keeps the table position it always had (the later statement's: the freeze `uniq`s
        # the nearest-first list), which is not Ruby's (Ruby skips the repeat and keeps the first, #1573), and
        # the folded singleton tables read that order. The order is not a fact, so the singleton side is named
        # unpositioned and the chain settles to the readers' own answer.
        accumulator.taint(current_class, :extend) if targets.any? { |target| list.include?(target) }
        list.unshift(*targets)
        accumulator.note(node, current_class, :extend, targets, complete: targets.size == arguments.size,
                                                                positioned: positioned)
        targets
      end

      # The materialization half of #526: for every `C extends M`, M's INSTANCE defs become C's
      # SINGLETON defs — existence (so `C.helper` stops firing undefined-method) and def nodes (so
      # call-site return inference runs with `self = Singleton[C]`, which is what Ruby binds). A name C
      # already defines on its own singleton wins (`||=`); an extend target with no discovered defs
      # contributes nothing (RBS-module extends stay on the dispatch tiers).
      #
      # ADR-119 WD1 — the copy follows its siblings, which this writes (copy on write; a table the caller passed
      # is never mutated). `unpositioned` is the project's `unpositioned_mixins`; an edge it lists, or taints
      # with "*", is not a fact, so what it copies is `possible`:
      #
      # - a slot the copy WROTE is contested when the edge is listed or the source slot is contested (a slot some
      #   other copy wrote was decided by that copy, which the `||=` lets win);
      # - the singleton name is `possible` when the edge is listed or the source name is possible on the instance
      #   side, unless C's singleton already answers it certainly (never `:both` from here: the instance side is
      #   not touched);
      # - a certain copy makes the singleton name certain, so `:singleton` leaves the name's possible kind.
      #
      # A contested source with a certain edge contests the slot and leaves the name certain: a value-only
      # contest does not make the name possible.
      def fold_extends_into_singleton_tables(extends, def_nodes, singleton_def_nodes, methods, siblings:,
                                             unpositioned:)
        owned = {}.compare_by_identity
        extends.each do |class_name, mods|
          listed_mods = unpositioned.dig(class_name, :extend)
          mods.each do |mod_name|
            resolved, source_defs = extend_source_defs(def_nodes, class_name, mod_name)
            next if source_defs.nil?

            # An inner table inherited unchanged from a frozen seed must be thawed before the fold writes.
            target = singleton_def_nodes[class_name]
            target = singleton_def_nodes[class_name] = (target ? target.dup : {}) if target.nil? || target.frozen?
            listed = extend_edge_listed?(listed_mods, mod_name)
            source_defs.each do |method_name, def_node|
              wrote = target[method_name].nil?
              target[method_name] ||= def_node
              certain_before = singleton_name_certain?(methods, siblings, class_name, method_name)
              record_method_kind(methods, class_name, method_name, :singleton)
              follow_extend_siblings(siblings, owned, [class_name, resolved, method_name],
                                     wrote: wrote, listed: listed, certain_before: certain_before)
            end
          end
        end
      end

      # Whether `unpositioned_mixins` lists the extend edge to `mod_name` (or taints the whole side).
      def extend_edge_listed?(listed_mods, mod_name)
        !listed_mods.nil? && (listed_mods.include?(mod_name) || listed_mods.include?(MixinAccumulator::WILDCARD))
      end

      # Whether `class_name`'s singleton already answers `method_name` through a certain fact: the existence table
      # covers the singleton side and the `possible` copy does not.
      def singleton_name_certain?(methods, siblings, class_name, method_name)
        return false unless covers_singleton?(methods.dig(class_name, method_name))

        !covers_singleton?(siblings[:possible_discovered_methods].dig(class_name, method_name))
      end

      SINGLETON_KINDS = [:singleton, Scope::DiscoveryIndex::METHOD_KIND_BOTH].freeze
      INSTANCE_KINDS = [:instance, Scope::DiscoveryIndex::METHOD_KIND_BOTH].freeze
      private_constant :SINGLETON_KINDS, :INSTANCE_KINDS

      def covers_singleton?(kind)
        SINGLETON_KINDS.include?(kind)
      end

      # The sibling half of one copied name; see {#fold_extends_into_singleton_tables}. `names` is
      # `[extender, resolved source module, method name]`.
      def follow_extend_siblings(siblings, owned, names, wrote:, listed:, certain_before:)
        class_name, resolved, method_name = names
        contested_source = !siblings[:contested_discovered_def_nodes].empty? &&
                           siblings[:contested_discovered_def_nodes].include?([resolved, method_name])
        if wrote && (listed || contested_source)
          own_sibling_table(siblings, owned, :contested_discovered_singleton_def_nodes) << [class_name, method_name]
        end
        if listed || source_name_possible?(siblings, resolved, method_name)
          return if certain_before

          row = (own_sibling_table(siblings, owned, :possible_discovered_methods)[class_name] ||= {})
          row[method_name] = merge_sibling_kind(row[method_name], :singleton)
        else
          strip_possible_singleton(siblings, owned, class_name, method_name)
        end
      end

      def source_name_possible?(siblings, resolved, method_name)
        INSTANCE_KINDS.include?(siblings[:possible_discovered_methods].dig(resolved, method_name))
      end

      def merge_sibling_kind(sitting, arriving)
        sitting.nil? || sitting == arriving ? arriving : Scope::DiscoveryIndex::METHOD_KIND_BOTH
      end

      # A certain copy: `:singleton` leaves the `possible` kind (`:both` becomes `:instance`), and an emptied row goes.
      def strip_possible_singleton(siblings, owned, class_name, method_name)
        return unless covers_singleton?(siblings[:possible_discovered_methods].dig(class_name, method_name))

        possible = own_sibling_table(siblings, owned, :possible_discovered_methods)
        row = possible[class_name]
        if row[method_name] == :singleton
          row.delete(method_name)
          possible.delete(class_name) if row.empty?
        else
          row[method_name] = :instance
        end
      end

      # The sibling `key` as a table this fold owns: the first write copies it (a Set, or a Hash of Hashes) and
      # keeps the copy in `siblings`, so a table shared with a seed, a bundle or an empty constant is never written.
      def own_sibling_table(siblings, owned, key)
        table = siblings.fetch(key)
        return table if owned.key?(table)

        copy = table.is_a?(Set) ? table.dup : table.transform_values(&:dup)
        owned[copy] = true
        siblings[key] = copy
      end

      # `extend CustomSig` inside `module Outer; class F` stores the as-written name, while
      # `def_nodes` keys the module's defs as `Outer::CustomSig`. Walk the enclosing namespaces
      # innermost-first so the fold finds the same module Ruby constant-lookup would. Returns
      # `[the key the defs were found under, the defs]`, or nil.
      def extend_source_defs(def_nodes, class_name, mod_name)
        found = def_nodes[mod_name]
        return [mod_name, found] if found
        return nil if mod_name.nil? || mod_name.start_with?("::")

        parts = class_name.to_s.split("::")
        while parts.size > 1
          parts.pop
          key = "#{parts.join('::')}::#{mod_name}"
          found = def_nodes[key]
          return [key, found] if found
        end
        nil
      end

      VISIBILITY_MODIFIERS = %i[public private protected].freeze

      # v0.1.2 — per-class method-visibility table for the `def.method-visibility-mismatch` CheckRule.
      #
      # Tracks three visibility-changing forms ({#apply_visibility_call}):
      #
      # - **Modifier blocks**: a bare `private` / `protected` / `public` call inside a class body (also written
      #   `self.private`, `send(:private)` or with a block) switches the "current default" visibility for every
      #   subsequent `def` and `attr_*` member until another modifier flips it again.
      # - **Named-argument form**: `private :foo, :bar` or `private %i[foo bar]` (or the same with `protected` /
      #   `public`) marks specific names already recorded under the class.
      # - **Wrap-around form** (#1911, #1819, #1633): `private def foo` and `private attr_reader :foo` record the
      #   members with the call's visibility and leave the default alone.
      #
      # A `module_function` call takes each form as `private` does (#1569): Ruby makes the instance copy private.
      #
      # Top-level (no surrounding class) defs do not contribute — Ruby's top-level visibility nuances (private at
      # top-level marks the method on `Object`) are out of scope for v0.1.2.
      def build_discovered_method_visibilities(root)
        build_method_visibility_tables(root).first
      end

      # ADR-119 WD3 — the visibility table and its `contested_discovered_method_visibilities` sibling, from ONE walk
      # over the file's {Certainty} classification `certainty`: `[table, contested key paths]`. The recorded values
      # are {#build_discovered_method_visibilities}'s; a slot is contested when its last writer is ({VisibilityTable}).
      def build_method_visibility_tables(root, certainty: Certainty.possible_nodes(root))
        accumulator = VisibilityTable.new.track(certainty)
        walk_method_visibilities(root, [], false, :public, accumulator)
        [accumulator.transform_values(&:freeze).freeze, accumulator.contested_paths]
      end

      # The bare calls that set the running default visibility of the body they run in: the modifiers and
      # `module_function`, which {#walk_method_visibilities} applies as `private` on the instance side
      # ({ModuleFunctionState.instance_visibility}, #1569).
      VISIBILITY_TOGGLES = (VISIBILITY_MODIFIERS + %i[module_function]).freeze

      # The `{class => {name => visibility}}` accumulator of {#walk_method_visibilities}, which also carries the
      # ADR-119 WD3 state of the slots it writes. A slot is contested when the write that holds it is possible: a
      # `def` or a named target (`private :x`) the {Certainty} classification reads as possible, or a `def` written
      # after an UNCERTAIN bare toggle of its body. A toggle is uncertain when it is possible itself or when the walk
      # does not carry it into the body's running default: one under any child of the body that is not its
      # statement list (`if c then private end`, `begin private end`, a block, `(private)`), since Ruby applies a
      # bare toggle there to the body's later `def`s while the walk keeps the default it had. A certain toggle
      # written directly in the body settles the default again. A named target does not read the running default,
      # so a toggle does not contest it. A certain write clears the slot's contest.
      class VisibilityTable < Hash
        include HookBlockSpans

        attr_accessor :hook_block_spans

        # The bare toggles the walk has met so far; a body's statement loop compares it around each child.
        attr_accessor :toggles
        # Whether the running default of the body being walked rests on an uncertain toggle.
        attr_accessor :uncertain
        # The file's {Certainty} answer.
        attr_reader :certainty

        def track(certainty)
          @certainty = certainty
          @contested = nil
          @toggles = 0
          @uncertain = false
          self
        end

        # Records that `node` wrote the `[class_name, name]` slot; `toggled` when the write reads the running
        # default (a `def`).
        def wrote(class_name, name, node, toggled:)
          if Certainty.possible?(@certainty, node) || (toggled && @uncertain)
            (@contested ||= Set.new) << [class_name, name].freeze
          else
            @contested&.delete([class_name, name])
          end
        end

        # Issue #2013 — contests the instance slot of `name`, recorded or not, and marks the contest as a
        # replacement's ({ScopeIndexer.replaced_visibility_mark}): a `define_method(:name)` or an alias gave the name
        # a visibility the walk does not read, and another file may record the slot. A later certain write in this
        # walk clears the contest ({#wrote}) and leaves the mark, which then only keeps a contest another file puts on
        # the slot: the fold declines more, never reports more, and file order is not load order there either.
        def contest_replaced(class_name, name)
          contest_slot(class_name, name)
          contest_slot(class_name, ScopeIndexer.replaced_visibility_mark(name))
        end

        # Contests the `[class_name, name]` slot, recorded or not: a visibility call changed it in a way the walk
        # cannot read (`private def self.x` reaching an instance `x`).
        def contest_slot(class_name, name)
          (@contested ||= Set.new) << [class_name, name].freeze
        end

        # Contests every slot of `class_name` on `side` recorded so far (`private(*names)` may name any of them).
        # Issue #1984 — on the singleton side it also contests the class's wildcard slot
        # ({ScopeIndexer::SINGLETON_WILDCARD_SLOT}): the names may be ones another file records.
        def contest_class(class_name, side = :instance)
          self[class_name]&.each_key do |slot|
            contest_slot(class_name, slot) if slot.is_a?(Array) == (side == :singleton)
          end
          contest_slot(class_name, SINGLETON_WILDCARD_SLOT) if side == :singleton
        end

        # Issue #1984 — records `visibility` in the slot of `name` on `side` ({ScopeIndexer.visibility_slot}) and
        # settles its contest as {#wrote} does.
        def write(class_name, name, side, visibility, node, toggled:)
          slot = ScopeIndexer.visibility_slot(name, side)
          (self[class_name] ||= {})[slot] = visibility
          wrote(class_name, slot, node, toggled: toggled)
        end

        # Runs the block with the running default uncertain, so a `def` it records is contested.
        def uncertainly
          saved = @uncertain
          @uncertain = true
          yield
        ensure
          @uncertain = saved
        end

        # Runs the block as a fresh body (a class or module, `class << self`, a meta-new or eval block), whose
        # default starts certain and whose toggles do not reach the enclosing body.
        def body
          saved_toggles = @toggles
          saved_uncertain = @uncertain
          @uncertain = false
          yield
        ensure
          @toggles = saved_toggles
          @uncertain = saved_uncertain
        end

        def contested_paths
          contested = @contested
          return Scope::DiscoveryIndex::EMPTY_SIBLINGS[:contested_discovered_method_visibilities] if contested.nil?
          return Scope::DiscoveryIndex::EMPTY_SIBLINGS[:contested_discovered_method_visibilities] if contested.empty?

          contested.freeze
        end
      end

      # A bare toggle ({VISIBILITY_TOGGLES}): a visibility call ({#visibility_call_parts}) with no arguments.
      def bare_visibility_toggle?(node)
        parts = visibility_call_parts(node)
        !parts.nil? && parts.last.empty?
      end

      # Whether a visibility call with these arguments may set the running default: none at all, or a splat that
      # may expand to none (`private(*[])` is a bare `private`).
      def visibility_toggle_arguments?(arguments)
        arguments.empty? || arguments.any?(Prism::SplatNode)
      end

      VISIBILITY_SEND_CALLS = %i[send __send__].freeze
      EMPTY_VISIBILITY_ARGUMENTS = [].freeze
      private_constant :VISIBILITY_SEND_CALLS, :EMPTY_VISIBILITY_ARGUMENTS

      # Issue #1633 — `[name, arguments]` for a call Ruby runs as one of {VISIBILITY_TOGGLES} on the body's self:
      # written receiverless or on `self` (`self.private`), or sent with a literal name (`send(:private, :x)`,
      # `__send__(:private)`). A block is ignored, as `Module#private` ignores it (`private {}` is a bare
      # `private`). nil for any other call.
      def visibility_call_parts(node)
        return nil unless node.is_a?(Prism::CallNode)
        return nil unless node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)

        name = node.name
        arguments = node.arguments&.arguments || EMPTY_VISIBILITY_ARGUMENTS
        if VISIBILITY_SEND_CALLS.include?(name)
          name = Source::Literals.symbol_or_string(arguments.first)
          arguments = arguments.drop(1)
        end
        VISIBILITY_TOGGLES.include?(name) ? [name, arguments] : nil
      end

      # Issue #1592 — a concern's `class_methods do … end` block is a `module_eval` of `Owner::ClassMethods`, whose
      # visibility starts public: its `def`s' visibilities are recorded on that module too, as its `def`s are.
      # Issue #2997 — in every body of the module, as {#record_concern_class_methods} reads its `def`s.
      def walk_class_methods_visibilities(node, child_prefix, accumulator)
        return unless node.is_a?(Prism::ModuleNode) && node.body.is_a?(Prism::StatementsNode)

        node.body.body.each do |statement|
          next unless statement.is_a?(Prism::CallNode) && block_statement?(statement) &&
                      statement.name == :class_methods && statement.block.body

          accumulator.body do
            walk_method_visibilities(statement.block.body, [*child_prefix, "ClassMethods"], false, :public, accumulator)
          end
        end
      end

      # rubocop:disable-next Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Metrics/AbcSize
      def walk_method_visibilities(node, qualified_prefix, in_singleton_class, current_visibility, accumulator, # rubocop:disable Metrics/ParameterLists
                                   def_owner_prefix = nil, singleton_cref: false,
                                   defs_singleton: false)
        return current_visibility unless node.is_a?(Prism::Node)

        owner_prefix = def_owner_prefix || qualified_prefix
        case node
        when Prism::ClassNode, Prism::ModuleNode
          self_decl = DeclarationWalk::Rules.self_anchored_decl_prefix(
            node.constant_path, in_singleton_class ? EMPTY_PREFIX : def_owner_prefix
          )
          child_prefix = self_decl ||
                         Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
          if child_prefix
            # Under an unnameable cref a bare/`self::` header opens `#<singleton>::Name` —
            # ownerless; nameable headers re-anchor at a real cref.
            child_cref = DeclarationWalk::Rules.unnameable_decl?(node, self_decl, singleton_cref)
            body_prefix = child_cref ? [] : child_prefix
            accumulator.mark_hook_blocks(concern_hook_blocks(node, child_prefix), child_prefix) unless child_cref
            if node.body
              accumulator.body do
                walk_method_visibilities(node.body, body_prefix, false, :public,
                                         accumulator, nil, singleton_cref: child_cref)
              end
              walk_class_methods_visibilities(node, child_prefix, accumulator) unless child_cref
            end
            return current_visibility
          end
        when Prism::SingletonClassNode
          walk_visibility_singleton_class(node, qualified_prefix, in_singleton_class, current_visibility,
                                          accumulator, def_owner_prefix, singleton_cref,
                                          defs_singleton: defs_singleton)
          return current_visibility
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
             Prism::ConstantPathOrWriteNode
          if (split = DeclarationWalk::Rules.meta_new_block_split(node, qualified_prefix, def_owner_prefix,
                                                                  singleton_cref))
            enclosing, body, body_self = split
            enclosing.each do |part|
              walk_method_visibilities(part, qualified_prefix, in_singleton_class,
                                       current_visibility, accumulator, def_owner_prefix,
                                       singleton_cref: singleton_cref,
                                       defs_singleton: defs_singleton)
            end
            if body
              accumulator.body do
                walk_method_visibilities(body, qualified_prefix, false, :public,
                                         accumulator, body_self,
                                         singleton_cref: singleton_cref)
              end
            end
            return current_visibility
          end
        when Prism::DefNode
          return current_visibility if accumulator.hook_block_self_def?(node, owner_prefix)

          contest_foreign_singleton_visibility(node, qualified_prefix, owner_prefix, in_singleton_class, accumulator)
          record_def_visibility(node, owner_prefix, visibility_side(in_singleton_class, defs_singleton),
                                current_visibility, accumulator)
          return current_visibility
        when Prism::CallNode
          record_constant_class_method_calls(node, qualified_prefix, accumulator)
          if DeclarationWalk::Rules.receiver_eval_call?(node)
            walk_eval_visibilities(node, qualified_prefix, in_singleton_class, current_visibility,
                                   accumulator, def_owner_prefix, singleton_cref: singleton_cref,
                                                                  defs_singleton: defs_singleton)
            return current_visibility
          end
          if AnonymousMetaClass.block_form_receiver(node)
            walk_anonymous_meta_visibilities(node, qualified_prefix, in_singleton_class, current_visibility,
                                             accumulator, def_owner_prefix, singleton_cref: singleton_cref,
                                                                            defs_singleton: defs_singleton)
            return current_visibility
          end
          if (parts = visibility_call_parts(node))
            accumulator.toggles += 1 if visibility_toggle_arguments?(parts.last)
            # A `module_function` call is applied as a `private` one (#1569): it makes the instance copy private.
            visibility = parts.first
            visibility = ModuleFunctionState.instance_visibility unless VISIBILITY_MODIFIERS.include?(visibility)
            # Issue #1984 — inside `class << self` (or a `class_eval` on the singleton class) the call marks the
            # SINGLETON methods, recorded under their `[:singleton, name]` slots. `module_function` is no method of
            # a singleton class, so it is walked as any other call there. The `owner_prefix` check is a guard: an
            # ownerless body (the top level, an anonymous factory block) records nothing, and its calls walk as
            # any other call.
            # An `instance_eval` body's call (`:eval`) runs on the receiver as a module: the instance side.
            side = visibility_side(in_singleton_class, defs_singleton)
            side = :instance if side == :eval
            if side && !owner_prefix.empty? && (side == :instance || VISIBILITY_MODIFIERS.include?(parts.first))
              return apply_visibility_call(node, visibility, parts.last, owner_prefix, current_visibility, accumulator,
                                           side: side, defs_singleton: defs_singleton) do |argument|
                walk_method_visibilities(argument, qualified_prefix, in_singleton_class, current_visibility,
                                         accumulator, def_owner_prefix, singleton_cref: singleton_cref,
                                                                        defs_singleton: defs_singleton)
              end
            end
          end
          if !in_singleton_class && !owner_prefix.empty?
            class_method_parts = class_method_visibility_parts(node)
            if class_method_parts
              apply_class_method_visibility(node, *class_method_parts, owner_prefix, accumulator) do |argument|
                walk_method_visibilities(argument, qualified_prefix, in_singleton_class, current_visibility,
                                         accumulator, def_owner_prefix, singleton_cref: singleton_cref,
                                                                        defs_singleton: defs_singleton)
              end
              return current_visibility
            end
            contest_singleton_rewrites(node, owner_prefix, accumulator)
          end
          side = visibility_side(in_singleton_class, defs_singleton)
          if %i[instance singleton].include?(side)
            record_attr_visibility(node, owner_prefix, current_visibility, accumulator, toggled: true, side: side)
            contest_replaced_visibility(replaced_by_call(node), owner_prefix, accumulator, side: side)
          end
        when Prism::AliasMethodNode
          side = visibility_side(in_singleton_class, defs_singleton)
          if %i[instance singleton].include?(side)
            contest_replaced_visibility(Array(Source::AliasNames.keyword_names(node)&.first), owner_prefix,
                                        accumulator, side: side)
          end
          return current_visibility
        end

        # Statement-position StatementsNode preserves left-to-right visibility flow; everything else recurses with the
        # entry visibility unchanged.
        #
        # ADR-119 WD3 — the statement loop also settles whether the running default is uncertain
        # ({VisibilityTable}): a bare toggle written here sets it from its own certainty, and any other statement
        # under which the walk met a toggle makes it uncertain.
        if node.is_a?(Prism::StatementsNode)
          local_visibility = current_visibility
          node.rigor_each_child do |child|
            toggles = accumulator.toggles
            local_visibility = walk_method_visibilities(child, qualified_prefix, in_singleton_class,
                                                        local_visibility, accumulator, def_owner_prefix,
                                                        singleton_cref: singleton_cref,
                                                        defs_singleton: defs_singleton)
            if bare_visibility_toggle?(child)
              accumulator.uncertain = Certainty.possible?(accumulator.certainty, child)
            elsif accumulator.toggles != toggles
              accumulator.uncertain = true
            end
          end
        else
          node.rigor_each_child do |child|
            walk_method_visibilities(child, qualified_prefix, in_singleton_class, current_visibility,
                                     accumulator, def_owner_prefix, singleton_cref: singleton_cref,
                                                                    defs_singleton: defs_singleton)
          end
        end
        current_visibility
      end

      # `class << <non-constant>` opens a singleton the walk cannot name — its body
      # walks ownerless, keeping the singleton marker so `self::` receivers still decline.
      # The lexical cref below is unnameable in every case.
      def walk_visibility_singleton_class(node, qualified_prefix, in_singleton_class, current_visibility,
                                          accumulator, def_owner_prefix, singleton_cref,
                                          defs_singleton: false) # rubocop:disable Metrics/ParameterLists
        singleton_prefix = singleton_body_prefix(node, in_singleton_class,
                                                 def_owner_prefix || qualified_prefix,
                                                 qualified_prefix)
        walk_method_visibilities(node.expression, qualified_prefix, in_singleton_class,
                                 current_visibility, accumulator, def_owner_prefix,
                                 singleton_cref: singleton_cref,
                                 defs_singleton: defs_singleton)
        return unless node.body
        return if hook_block_singleton?(node, in_singleton_class, def_owner_prefix || qualified_prefix, accumulator)

        accumulator.body do
          walk_method_visibilities(node.body, qualified_prefix, true, :public, accumulator,
                                   singleton_prefix, singleton_cref: true)
        end
      end

      # A `Class.new` / `Module.new` / `Struct.new` / `Data.define` block no constant write names
      # ({DeclarationWalk::Rules.meta_new_block_split} takes the named ones): `klass = Class.new do … end`,
      # `@k = Struct.new(:a) do … end`, `register(Class.new do … end)` or a bare `Data.define(:a) do … end`. Its body is
      # the anonymous class's, so it walks as a fresh body with no owner and records nothing for the enclosing class;
      # the receiver and the arguments are walked where they stand.
      def walk_anonymous_meta_visibilities(node, qualified_prefix, in_singleton_class, current_visibility,
                                           accumulator, def_owner_prefix, singleton_cref:, defs_singleton:) # rubocop:disable Metrics/ParameterLists
        [node.receiver, *node.arguments&.arguments].each do |part|
          walk_method_visibilities(part, qualified_prefix, in_singleton_class, current_visibility, accumulator,
                                   def_owner_prefix, singleton_cref: singleton_cref, defs_singleton: defs_singleton)
        end
        accumulator.body do
          walk_method_visibilities(node.block.body, qualified_prefix, false, :public, accumulator,
                                   EMPTY_PREFIX, singleton_cref: singleton_cref)
        end
      end

      # The eval-block arm of {#walk_method_visibilities}: the block is a fresh class body under
      # the receiver's def-owner — visibility starts at `:public`, and nothing inside it leaks
      # back to this body's modifier state. An unnameable receiver walks the body ownerless;
      # declarations inside stay lexical.
      def walk_eval_visibilities(node, qualified_prefix, in_singleton_class, current_visibility,
                                 accumulator, def_owner_prefix = nil, singleton_cref: false,
                                 defs_singleton: false) # rubocop:disable Metrics/ParameterLists
        if node.receiver
          walk_method_visibilities(node.receiver, qualified_prefix, in_singleton_class,
                                   current_visibility, accumulator, def_owner_prefix,
                                   singleton_cref: singleton_cref,
                                   defs_singleton: defs_singleton)
        end
        return if singleton_class_eval_walked?(node, qualified_prefix, in_singleton_class, accumulator,
                                               def_owner_prefix, singleton_cref, defs_singleton)

        node.arguments&.arguments&.each do |arg|
          walk_method_visibilities(arg, qualified_prefix, in_singleton_class, current_visibility,
                                   accumulator, def_owner_prefix, singleton_cref: singleton_cref,
                                                                  defs_singleton: defs_singleton)
        end
        self_prefix = def_owner_prefix || qualified_prefix
        unnameable = DeclarationWalk::Rules.unnameable_eval_self?(in_singleton_class, def_owner_prefix,
                                                                  qualified_prefix, singleton_cref)
        eval_prefix = DeclarationWalk::Rules.eval_receiver_prefix(node, self_prefix, qualified_prefix,
                                                                  unnameable_self: unnameable) || []
        # `instance_eval`'s `def`s are singleton-side (`defs_singleton` — skipped by the
        # instance-visibility table), while `public`/`private` are calls on the
        # receiver-as-module and stay instance-side (`in_singleton_class` off) for a class
        # receiver.
        call_singleton, defs_flag = eval_body_def_context(node, in_singleton_class)
        accumulator.body do
          node.block.rigor_each_child do |child|
            walk_method_visibilities(child, qualified_prefix, call_singleton, :public, accumulator,
                                     eval_prefix, singleton_cref: singleton_cref,
                                                  defs_singleton: defs_flag)
          end
        end
      end

      # Issue #1984 — `singleton_class.class_eval do … end` in a class body (or `module_eval` / `class_exec` /
      # `module_exec`) runs its block as a `class << self` body does: its `def`s and visibility calls land on the
      # class's singleton slots. True when it walked the block so.
      def singleton_class_eval_walked?(node, qualified_prefix, in_singleton_class, accumulator,
                                       def_owner_prefix, singleton_cref, defs_singleton)
        return false if in_singleton_class || defs_singleton || INSTANCE_EVAL_CALLS.include?(node.name)
        return false unless own_singleton_class?(node.receiver) && node.arguments.nil?

        owner_prefix = def_owner_prefix || qualified_prefix
        return false if owner_prefix.empty?

        if node.block.body
          accumulator.body do
            walk_method_visibilities(node.block.body, qualified_prefix, true, :public, accumulator, owner_prefix,
                                     singleton_cref: singleton_cref)
          end
        end
        true
      end

      # Issue #1984 — the slot a contest stands on for every singleton name of a class: a call that may make any of
      # them public (`K.public_class_method(*names)`, `K.singleton_class.class_eval { … }`).
      SINGLETON_WILDCARD_SLOT = %i[singleton *].freeze

      # Issue #2013 — the mark a contested instance slot `name` carries in `contested_discovered_method_visibilities`
      # when a `define_method(:name)` or an alias replaced the method: `[:replaced, name]`. No reader asks for it; it
      # keeps the slot's contest when another file's write of the slot folds later ({#fold_visibility_contests}),
      # since file order is not load order.
      def self.replaced_visibility_mark(name) = [:replaced, name].freeze

      # Issue #1984 — a class method visibility call written on a constant (`K.public_class_method(:x)`,
      # `K.send(:public_class_method, :x)`), anywhere: each literal name is recorded public on every class the
      # constant may name, so a reopening's or another file's `private_class_method` disagrees with it and is
      # contested. A `K.private_class_method` is not read (the rule only declines more where it is missing). Any call
      # on `K.singleton_class` (`send(:public, :x)`, `class_eval { … }`), or a `public_class_method` whose names are
      # not literal, contests every singleton name of the class.
      def record_constant_class_method_calls(node, qualified_prefix, accumulator)
        receiver = node.receiver
        if singleton_class_of_receiver?(receiver) && constant_receiver?(receiver.receiver)
          each_constant_class(receiver.receiver, qualified_prefix) do |class_name|
            accumulator.contest_class(class_name, :singleton)
          end
          return
        end
        names = constant_public_class_method_names(node)
        return if names.nil?

        each_constant_class(receiver, qualified_prefix) do |class_name|
          next accumulator.contest_class(class_name, :singleton) if names.any?(&:nil?)

          names.each do |method_name|
            accumulator.write(class_name, method_name, :singleton, :public, node, toggled: false)
          end
        end
      end

      # The names a `K.public_class_method(…)` (or `K.send(:public_class_method, …)`) call on a constant names, a nil
      # for each one that is not a literal; nil for any other call.
      def constant_public_class_method_names(node)
        return nil unless constant_receiver?(node.receiver)

        name = node.name
        arguments = node.arguments&.arguments || EMPTY_VISIBILITY_ARGUMENTS
        if VISIBILITY_SEND_CALLS.include?(name) || name == :public_send
          name = Source::Literals.symbol_or_string(arguments.first)
          arguments = arguments.drop(1)
        end
        return nil unless name == :public_class_method

        arguments.flat_map { |arg| arg.is_a?(Prism::ArrayNode) ? arg.elements : [arg] }
                 .map { |arg| Source::Literals.symbol_or_string(arg) }
      end

      def constant_receiver?(node)
        node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
      end

      def each_constant_class(receiver, qualified_prefix, &)
        constant_receiver_candidates(receiver, qualified_prefix).each(&)
      end

      # Issue #1984 — the side a body's members land on: `:singleton` in a `class << self` body or a `class_eval` on
      # the singleton class, `:eval` in an `instance_eval` body on a class (its `def`s are singleton methods, its
      # visibility calls instance-side), `:instance` in a class body, and nil where the singleton cannot be named.
      def visibility_side(in_singleton_class, defs_singleton)
        return defs_singleton == :unnameable ? nil : :singleton if in_singleton_class
        return :eval if defs_singleton

        :instance
      end

      # Issue #1984 — the key of `name`'s slot in a class's visibility table: the name on the instance side,
      # `[:singleton, name]` on the singleton side (the envelope table's spelling).
      def visibility_slot(name, side)
        side == :singleton ? [:singleton, name].freeze : name
      end

      # Records the visibility a `def` gets ({#visibility_side} `side`):
      #
      # - a receiverless `def` takes `current_visibility` on its side; `toggled` when that is the running default
      #   (a statement), false for one a visibility call wraps;
      # - issue #1984 — `def self.x` (or `def K.x` in `K`'s body) is a public singleton method whatever the running
      #   default is (`private; def self.x` is public), and writes nothing in a singleton body (it defines a method
      #   of the singleton's singleton);
      # - an `instance_eval` body's `def` (`:eval`) replaces a singleton method with a visibility the walk does not
      #   read, so its singleton slot is contested.
      def record_def_visibility(def_node, qualified_prefix, side, current_visibility, accumulator, toggled: true)
        return if side.nil? || qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        if side == :eval
          accumulator.contest_slot(class_name, visibility_slot(def_node.name, :singleton))
        elsif def_node.receiver.nil?
          accumulator.write(class_name, def_node.name, side, current_visibility, def_node, toggled: toggled)
        elsif side == :instance && self_singleton_def?(def_node, qualified_prefix)
          accumulator.write(class_name, def_node.name, :singleton, :public, def_node, toggled: false)
        end
      end

      def self_singleton_def?(def_node, qualified_prefix)
        def_node.receiver.is_a?(Prism::SelfNode) || def_receiver_targets_lexical_self?(def_node.receiver,
                                                                                       qualified_prefix)
      end

      # Issue #1984 — `def Other.x` whose receiver is not the lexical self (`def_owner`) makes `Other.x` public in
      # whatever order the files load, so each class the constant may name has its singleton slot contested.
      def contest_foreign_singleton_visibility(def_node, qualified_prefix, def_owner, in_singleton_class, accumulator)
        receiver = def_node.receiver
        return unless receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
        return if !in_singleton_class && def_receiver_targets_lexical_self?(receiver, def_owner)

        constant_receiver_candidates(receiver, qualified_prefix).each do |name|
          accumulator.contest_slot(name, visibility_slot(def_node.name, :singleton))
        end
      end

      # Applies one `private` / `protected` / `public` call ({#visibility_call_parts}) written on the body's self
      # and returns the running default after it. `side` is the side its names land on: `:singleton` in a
      # `class << self` body (issue #1984), `:instance` elsewhere.
      #
      # - no arguments — the call's visibility becomes the default for subsequent defs.
      # - `private :foo, :bar`, `private %i[foo bar]` — back-patch the named methods in the accumulator; the
      #   default does NOT change for this form.
      # - Issues #1911, #1819, #1633 — `private def foo` (endless or not) and `private attr_reader :foo` define
      #   the members with the call's visibility, whatever the running default is (`private; public def foo` is
      #   public); `private def self.foo` changes the method `foo` of the side, if one exists, so its slot is
      #   contested, and defines a public singleton `foo` (a singleton-singleton one in a `class << self` body).
      # - a splat (`private(*names)`) may name any member or none (a bare toggle), so the class's slots on the side
      #   this file wrote so far are contested, and the statement loop reads the default after it as uncertain
      #   ({#visibility_toggle_arguments?}).
      # - any other argument (`private memoize def foo`, `private delegate(...)`) is walked with the default
      #   uncertain, so a `def` under it is contested: the call's visibility reaches it through a return value
      #   the walk does not read.
      #
      # `walk` walks an argument the call does not consume itself.
      def apply_visibility_call(call_node, name, args, qualified_prefix, current_visibility, accumulator, # rubocop:disable Metrics/ParameterLists
                                side: :instance, defs_singleton: false, &walk)
        return name if args.empty?

        class_name = qualified_prefix.join("::")
        accumulator.contest_class(class_name, side) if args.any?(Prism::SplatNode)
        args.each do |arg|
          apply_visibility_argument(arg, name, call_node, qualified_prefix, accumulator,
                                    side: side, defs_singleton: defs_singleton, &walk)
        end
        current_visibility
      end

      def apply_visibility_argument(arg, name, call_node, qualified_prefix, accumulator, side:, defs_singleton:, &walk)
        case arg
        when Prism::DefNode
          if arg.receiver.nil?
            def_side = side == :instance && defs_singleton ? :eval : side
            record_def_visibility(arg, qualified_prefix, def_side, name, accumulator, toggled: false)
          else
            accumulator.contest_slot(qualified_prefix.join("::"), visibility_slot(arg.name, side))
            record_def_visibility(arg, qualified_prefix, defs_singleton ? :eval : side, name, accumulator,
                                  toggled: false)
          end
        when Prism::SymbolNode, Prism::StringNode, Prism::ArrayNode
          apply_named_visibility(arg, name, qualified_prefix, call_node, accumulator, side: side, &walk)
        else
          # An `instance_eval` body's wrapped attr is walked like any other argument and records nothing.
          if !defs_singleton && attr_visibility_call?(arg)
            record_attr_visibility(arg, qualified_prefix, name, accumulator, toggled: false, side: side)
          else
            accumulator.uncertainly { walk.call(arg) }
          end
        end
      end

      # `private :foo` / `private "foo"` / `private %i[foo bar]`: each literal name the call's visibility. An array
      # element that is not a literal name is walked like any other argument.
      def apply_named_visibility(arg, visibility, qualified_prefix, call_node, accumulator, side: :instance, &walk)
        elements = arg.is_a?(Prism::ArrayNode) ? arg.elements : [arg]
        class_name = qualified_prefix.join("::")
        elements.each do |element|
          name = visibility_target_name(element)
          next accumulator.uncertainly { walk.call(element) } if name.nil?

          accumulator.write(class_name, name, side, visibility, call_node, toggled: false)
        end
      end

      def visibility_target_name(arg)
        Source::Literals.symbol_or_string(arg)
      end

      CLASS_METHOD_VISIBILITIES = { private_class_method: :private, public_class_method: :public }.freeze
      private_constant :CLASS_METHOD_VISIBILITIES

      # Issue #1984 — `[visibility, arguments]` for a `private_class_method` / `public_class_method` call written on
      # the body's self, in the spellings {#visibility_call_parts} reads (receiverless, `self.`, `send` with a
      # literal name); nil for any other call.
      def class_method_visibility_parts(node)
        return nil unless node.is_a?(Prism::CallNode)
        return nil unless node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)

        name = node.name
        arguments = node.arguments&.arguments || EMPTY_VISIBILITY_ARGUMENTS
        if VISIBILITY_SEND_CALLS.include?(name)
          name = Source::Literals.symbol_or_string(arguments.first)
          arguments = arguments.drop(1)
        end
        visibility = CLASS_METHOD_VISIBILITIES[name]
        visibility && [visibility, arguments]
      end

      # Issue #1984 — applies `private_class_method` / `public_class_method` to the class's singleton slots. It sets
      # no running default (with no arguments it does nothing). A literal name (`:x`, `"x"`, `[:x]`) and a wrapped
      # `def self.x` take the call's visibility; a wrapped receiverless `def x` defines an instance method (walked as
      # a statement) and names the singleton `x` the walk does not see, as does any other receiver, so that slot is
      # contested; a splat or any other argument may name any singleton method, so every singleton slot the file
      # wrote so far for the class is contested, and the argument is walked.
      def apply_class_method_visibility(call_node, visibility, args, qualified_prefix, accumulator, &walk)
        class_name = qualified_prefix.join("::")
        args.each do |arg|
          case arg
          when Prism::DefNode
            if arg.receiver && self_singleton_def?(arg, qualified_prefix)
              accumulator.write(class_name, arg.name, :singleton, visibility, call_node, toggled: false)
            else
              walk.call(arg)
              accumulator.contest_slot(class_name, visibility_slot(arg.name, :singleton))
            end
          when Prism::SymbolNode, Prism::StringNode, Prism::ArrayNode
            apply_named_visibility(arg, visibility, qualified_prefix, call_node, accumulator, side: :singleton) do |el|
              accumulator.contest_class(class_name, :singleton)
              walk.call(el)
            end
          else
            accumulator.contest_class(class_name, :singleton)
            walk.call(arg)
          end
        end
      end

      SINGLETON_DEFINING_CALLS = %i[define_singleton_method].freeze
      private_constant :SINGLETON_DEFINING_CALLS

      # Issue #1984 — calls in a class body that change a singleton method's visibility in a way the walk does not
      # read, so the singleton slots they may reach are contested: `define_singleton_method(:x)` (a fresh public
      # method; a computed name contests every singleton slot of the class), and any call on `singleton_class`
      # (`singleton_class.send(:public, :x)`, `singleton_class.define_method(:x)`), whose literal arguments name
      # the slots and whose other arguments may name any.
      def contest_singleton_rewrites(node, qualified_prefix, accumulator)
        on_singleton_class = own_singleton_class?(node.receiver)
        return unless on_singleton_class || node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
        return unless on_singleton_class || SINGLETON_DEFINING_CALLS.include?(node.name)

        class_name = qualified_prefix.join("::")
        arguments = node.arguments&.arguments || EMPTY_VISIBILITY_ARGUMENTS
        arguments = arguments.first(1) if SINGLETON_DEFINING_CALLS.include?(node.name)
        arguments.each do |argument|
          name = Source::Literals.symbol_or_string(argument)
          if name
            accumulator.contest_slot(class_name, visibility_slot(name, :singleton))
          else
            accumulator.contest_class(class_name, :singleton)
          end
        end
      end

      # `singleton_class` or `self.singleton_class`: the body's own singleton class.
      def own_singleton_class?(receiver)
        singleton_class_of_receiver?(receiver) && (receiver.receiver.nil? || receiver.receiver.is_a?(Prism::SelfNode))
      end

      # Issue #1989 — the names a `define_method(:x)` or an `alias_method :x, :y` call replaces. An `attr_*` call is
      # not among them: it writes its members' slots itself ({#record_attr_visibility}).
      def replaced_by_call(call_node)
        return define_method_superseded_name(call_node) if call_node.name == :define_method

        Source::AliasNames.alias_method_call_names(call_node)&.first(1) || []
      end

      # Issue #1989 — a `define_method` or an alias that replaces a method gives the name a visibility the walk
      # does not read (the running default for `define_method`, the old name's for an alias), so the slot is
      # contested rather than left asserting the replaced `def`'s. Issue #1984 — the slot is contested whether or
      # not this file recorded it, since another file may have; issue #2013 — on the instance side too, with the
      # mark that keeps the contest when that file's write folds later ({VisibilityTable#contest_replaced}).
      def contest_replaced_visibility(names, qualified_prefix, accumulator, side: :instance)
        return if names.empty? || qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        names.each do |name|
          if side == :singleton
            accumulator.contest_slot(class_name, visibility_slot(name, side))
          else
            accumulator.contest_replaced(class_name, name)
          end
        end
      end

      # Issue #1911 — an `attr_reader` / `attr_writer` / `attr_accessor` call written on the body's self records
      # each member it defines (`x`, `x=`) with `visibility`: the running default for a statement (`toggled`), the
      # wrapping call's for `private attr_accessor :x`, which Ruby applies to the `[:x, :x=]` the macro returns.
      # A non-literal name (`attr_reader(*FIELDS)`) records nothing; a call that is no such macro records nothing.
      def record_attr_visibility(call_node, qualified_prefix, visibility, accumulator, toggled:, side: :instance)
        macro = attr_macro(call_node)
        return if macro.nil? || qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        each_attr_macro_name(call_node) do |base|
          members = []
          members << base unless macro == :attr_writer
          members << :"#{base}=" unless macro == :attr_reader
          members.each do |member|
            accumulator.write(class_name, member, side, visibility, call_node, toggled: toggled)
          end
        end
      end

      # An `attr_reader` / `attr_writer` / `attr_accessor` call on the body's self ({#attr_macro},
      # {#record_attr_visibility}). Ruby 4.0.5 gives every spelling the running default visibility.
      def attr_visibility_call?(node)
        !attr_macro(node).nil?
      end

      # Registers the alias name in the `discovered_methods` table so `undefined-method` diagnostics are not emitted for
      # calls to the aliased name. The kind mirrors the surrounding class context (instance inside a regular class body,
      # singleton inside `class << self`).
      def record_alias_method(alias_node, qualified_prefix, in_singleton_class, accumulator)
        return if qualified_prefix.empty?
        return unless alias_node.new_name.is_a?(Prism::SymbolNode)

        class_name = qualified_prefix.join("::")
        new_name = alias_node.new_name.unescaped.to_sym
        kind = in_singleton_class ? :singleton : :instance
        record_method(accumulator, class_name, new_name, kind)
        # Issue #992 — the aliased name too: `alias f_without_x f` is how a later redefinition of `f`
        # wraps the original, so `f` is not one `def` any more whatever this file's `def f` says.
        return unless alias_node.old_name.is_a?(Prism::SymbolNode)

        record_method_envelope_opaque(accumulator, class_name, alias_node.old_name.unescaped.to_sym)
      end

      # Issue #992 — `undef f` removes a method the envelope table would otherwise still describe.
      def record_undef(undef_node, qualified_prefix, tables)
        return if qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        undef_node.names.each do |name|
          method_name = literal_method_name(name)
          next unless method_name

          record_method_envelope_opaque(tables, class_name, method_name)
          record_removed_name(tables, class_name, method_name)
        end
      end

      REMOVING_CALLS = %i[remove_method undef_method].to_set.freeze
      private_constant :REMOVING_CALLS

      # Issue #1820 — `undef f`, `remove_method :f` or `undef_method :f` on the class, as its own entry beside the
      # opaque envelopes: an `attr_*` or `define_method` records an opaque envelope too, so only this says the name
      # is gone.
      def record_removed_name(tables, class_name, method_name)
        record_envelope(tables.envelopes, class_name, [Scope::DiscoveryIndex::ENVELOPE_REMOVED_KIND, method_name],
                        Source::ParameterEnvelope::OPAQUE)
      end

      # Both kinds, and the envelope table only: the evidence says something rewrites the name, not which
      # side it lives on, and it is not evidence that the name EXISTS, so the existence table is untouched.
      def record_method_envelope_opaque(tables, class_name, method_name)
        %i[instance singleton].each do |kind|
          record_envelope(tables.envelopes, class_name, [kind, method_name], Source::ParameterEnvelope::OPAQUE)
          contest_envelope(tables, class_name, [kind, method_name]) unless tables.certain
        end
      end

      # The receiverless class-body calls whose symbol arguments are never a method being rewritten, so they
      # may name a method without making its envelope opaque. Deliberately short: a macro missing from it
      # costs a check on that one name, while a wrapping macro wrongly listed here (`memoize :f`,
      # `def_delegator :@x, :f`) would leave a `def`'s envelope standing for a method that no longer has it.
      NAME_NEUTRAL_MACROS = %i[
        private public protected module_function private_class_method public_class_method
        private_constant public_constant require require_relative autoload autoload_relative
      ].to_set.freeze
      private_constant :NAME_NEUTRAL_MACROS

      # The calls that rewrite a class's method table in ways no literal argument names: `class_eval` and
      # friends run code (a heredoc or a block) against the class, `define_method` / `alias_method` /
      # `remove_method` with a computed name, the `send` family, and a mixin whose argument is not a
      # constant.
      SURFACE_EVAL_CALLS = %i[class_eval module_eval class_exec module_exec instance_eval instance_exec].to_set.freeze
      SURFACE_NAMING_CALLS = %i[
        define_method define_singleton_method alias_method remove_method undef_method
      ].to_set.freeze
      SURFACE_SEND_CALLS = %i[send __send__ public_send].to_set.freeze
      SURFACE_MIXIN_CALLS = %i[include prepend extend].to_set.freeze
      # A project's own mixin helper — GitLab's `prepend_mod_with("IntegrationsHelper")` prepends a module
      # from the `ee/` tree the analysed paths may not reach, which can redefine any method of the class.
      SURFACE_MIXIN_HELPER = /(?:\A|_)(?:include|prepend|extend)(?:_|\z)/
      private_constant :SURFACE_EVAL_CALLS, :SURFACE_NAMING_CALLS, :SURFACE_SEND_CALLS, :SURFACE_MIXIN_CALLS,
                       :SURFACE_MIXIN_HELPER

      # Issue #992 — the evidence a class-body call leaves about a method table that a `def` alone does not
      # describe. Recorded into the envelope table only, never the existence table:
      #
      # - a receiverless call from {SURFACE_EVAL_CALLS}, a {SURFACE_NAMING_CALLS} call whose name is computed,
      #   a {SURFACE_SEND_CALLS} call, or a mixin of a non-constant marks the lexical class
      #   {Scope::DiscoveryIndex::ENVELOPE_DYNAMIC_MARK};
      # - the same calls on a constant receiver (`Widget.include(M)`, a `Widget.class_eval "…"` string
      #   eval — the BLOCK form's defs attribute to the receiver and never reach this method) mark every
      #   name that constant can denote from here;
      # - any other receiverless call makes the envelope of every method a literal argument names opaque —
      #   `memoize :f`, `def_delegator :@x, :f`, `alias_method :g, :f` — unless it is {NAME_NEUTRAL_MACROS}.
      def record_surface_evidence(node, qualified_prefix, tables)
        receiver = node.receiver
        if receiver.nil? || receiver.is_a?(Prism::SelfNode)
          record_self_surface_evidence(node, qualified_prefix, tables)
        elsif receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
          return unless surface_rewriting_call?(node)

          constant_receiver_candidates(receiver, qualified_prefix).each do |name|
            record_surface_mark(tables, name, Scope::DiscoveryIndex::ENVELOPE_DYNAMIC_MARK)
          end
          record_constant_singleton_definer(node, receiver, qualified_prefix, tables)
        elsif singleton_class_of_receiver?(receiver) && singleton_class_named_call?(node)
          record_singleton_class_names(node, receiver.receiver, qualified_prefix, tables)
        end
      end

      # Issue #1752 — the names a {#singleton_class_named_call?} rewrites on its singleton class's owner, each
      # singleton envelope opaque and contested: the evidence the refinement typer reads as a rewritten singleton name.
      def record_singleton_class_names(node, object, qualified_prefix, tables)
        current_class = qualified_prefix.empty? ? nil : qualified_prefix.join("::")
        owner = singleton_class_owner(node, object, qualified_prefix, current_class)
        return if owner.nil?

        singleton_class_rewritten_names(node).each do |method_name|
          # `attr_writer :x` defines `x=` alone (#1936), so `x` keeps its own `def`.
          names = node.name == :attr_writer ? [] : [method_name]
          names << :"#{method_name}=" if %i[attr_writer attr_accessor].include?(node.name)
          names.each do |name|
            record_envelope(tables.envelopes, owner, [:singleton, name], Source::ParameterEnvelope::OPAQUE)
            # Contested even where the call is certain: the slot's `def` is not the body Ruby runs, so the
            # own-definer read declines on the name rather than answering it.
            contest_envelope(tables, owner, [:singleton, name])
          end
        end
      end

      # Issue #1752 — `def Const.x` whose receiver is not the lexical `self` (written at the top level or in another
      # class's body) defines `Const`'s singleton method, which no table files under `Const`: its singleton name's
      # envelope turns opaque, the evidence the refinement typer reads as a rewritten singleton name.
      def record_foreign_singleton_def(node, qualified_prefix, owner_prefix, tables)
        receiver = node.receiver
        return unless receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
        return if def_receiver_targets_lexical_self?(receiver, owner_prefix)

        constant_receiver_candidates(receiver, qualified_prefix).each do |name|
          record_object_singleton(tables, name, node.name)
        end
      end

      # Issue #3016 — `Const.define_singleton_method(:x) { … }` with a literal name defines `x` on `Const`'s object, and
      # is filed as {#record_foreign_singleton_def} files `def Const.x`: an opaque singleton envelope on every name the
      # constant can denote. A computed name may define any name, so it marks each candidate with the singleton side's
      # open-names mark instead, as a computed `define_method` on a constant marks the instance side.
      def record_constant_singleton_definer(node, receiver, qualified_prefix, tables)
        names = define_singleton_method_names(node)
        return if names.nil?

        candidates = constant_receiver_candidates(receiver, qualified_prefix)
        if names == :all
          candidates.each do |owner|
            record_surface_mark(tables, owner, Scope::DiscoveryIndex::ENVELOPE_OPEN_SINGLETON_NAMES_MARK)
          end
          return
        end

        candidates.product(names) do |owner, name|
          record_envelope(tables.envelopes, owner, [:singleton, name], Source::ParameterEnvelope::OPAQUE)
          record_envelope(tables.envelopes, owner, [Scope::DiscoveryIndex::ENVELOPE_OBJECT_SINGLETON_KIND, name],
                          Source::ParameterEnvelope::OPAQUE)
        end
      end

      # A `def Const.x` written outside `Const`'s body, or one in a `Const.singleton_class.class_eval` block: the opaque
      # `[:singleton, x]` envelope, contested unless certain, and the
      # {Scope::DiscoveryIndex::ENVELOPE_OBJECT_SINGLETON_KIND} entry the class-object path reads (#3018).
      def record_object_singleton(tables, owner, method_name)
        record_envelope(tables.envelopes, owner, [:singleton, method_name], Source::ParameterEnvelope::OPAQUE)
        contest_envelope(tables, owner, [:singleton, method_name]) unless tables.certain
        record_envelope(tables.envelopes, owner, [Scope::DiscoveryIndex::ENVELOPE_OBJECT_SINGLETON_KIND, method_name],
                        Source::ParameterEnvelope::OPAQUE)
      end

      # Issue #3018 — `Const.singleton_class.class_eval { def x … }` (or `module_eval` / `class_exec` / `module_exec`)
      # defines `x` on `Const`'s object, as `def Const.x` does, and is filed as {#record_foreign_singleton_def} files
      # that def ({#record_object_singleton}) on every name the constant can denote. The eval-body walk files these
      # defs under no owner, since the receiver is a call. Every receiverless `def` in the block counts, one under a
      # conditional included, as {#each_refinement_def} yields them: not one under a `class` / `module` / `class <<`
      # body, which opens another definee, nor one inside another `def`, which installs only when that runs.
      # `instance_eval` on the singleton class is not filed: its defs land on the singleton class's own singleton (Ruby
      # 4.0.5 raises NoMethodError on `Const.x` there).
      def record_constant_singleton_eval_defs(node, qualified_prefix, tables)
        return unless CLASS_EVAL_BLOCK_CALLS.include?(node.name)

        receiver = node.receiver
        return unless singleton_class_of_receiver?(receiver)

        body = node.block.body
        return if body.nil?

        # A bare, `self` or local receiver of `singleton_class` renders no constant, so it yields no candidate.
        candidates = constant_receiver_candidates(receiver.receiver, qualified_prefix)
        each_refinement_def(body) do |def_node|
          candidates.each { |owner| record_object_singleton(tables, owner, def_node.name) }
        end
      end

      def record_self_surface_evidence(node, qualified_prefix, tables)
        return if qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        if dynamic_surface_call?(node)
          record_surface_mark(tables, class_name, Scope::DiscoveryIndex::ENVELOPE_DYNAMIC_MARK)
        elsif node.name == :refine
          # Issue #1689 — a `refine` where `self` is a class is the class's own method, and refines nothing.
          record_refinement(node, qualified_prefix, tables) unless tables.class_body_refine?(node)
        elsif !NAME_NEUTRAL_MACROS.include?(node.name)
          record_named_arguments_opaque(node, class_name, tables)
        end
      end

      def record_named_arguments_opaque(node, class_name, tables)
        (node.arguments&.arguments || []).each do |argument|
          # `memoize def f(a)` wraps the def it is handed exactly as `memoize :f` does.
          method_name = argument.is_a?(Prism::DefNode) ? argument.name : literal_method_name(argument)
          next unless method_name

          record_method_envelope_opaque(tables, class_name, method_name)
          record_removed_name(tables, class_name, method_name) if REMOVING_CALLS.include?(node.name)
        end
      end

      # `refine Widget do def f(a, b) … end end` redefines `Widget#f` in every file that says `using`, so `Widget`
      # takes {Scope::DiscoveryIndex::ENVELOPE_REFINED_MARK}; the block's `def`s go to the refinement table.
      def record_refinement(node, qualified_prefix, tables)
        target = node.arguments&.arguments&.first
        return unless target.is_a?(Prism::ConstantReadNode) || target.is_a?(Prism::ConstantPathNode)

        constant_receiver_candidates(target, qualified_prefix).each do |name|
          record_surface_mark(tables, name, Scope::DiscoveryIndex::ENVELOPE_REFINED_MARK)
        end
      end

      def surface_rewriting_call?(node)
        SURFACE_EVAL_CALLS.include?(node.name) || SURFACE_NAMING_CALLS.include?(node.name) ||
          SURFACE_SEND_CALLS.include?(node.name) || ATTR_MACROS.include?(node.name) || surface_mixin_call?(node)
      end

      def surface_mixin_call?(node)
        SURFACE_MIXIN_CALLS.include?(node.name) || SURFACE_MIXIN_HELPER.match?(node.name.to_s)
      end

      # Issue #2995 — a `send` / `public_send` / `__send__` of `:include`, `:prepend` or `:extend` is that mixin call,
      # which the mixin walk records as the bare call, so it is judged by its own arguments as the bare call is.
      def dynamic_surface_call?(node)
        return true if SURFACE_EVAL_CALLS.include?(node.name)

        if SURFACE_SEND_CALLS.include?(node.name)
          kind, arguments, = mixin_call_view(node)
          return kind.nil? || dynamic_mixin_arguments?(arguments)
        end

        arguments = node.arguments&.arguments || []
        if SURFACE_NAMING_CALLS.include?(node.name)
          arguments.empty? || literal_method_name(arguments.first).nil?
        elsif surface_mixin_call?(node)
          dynamic_mixin_arguments?(arguments)
        else
          false
        end
      end

      def dynamic_mixin_arguments?(arguments)
        arguments.any? do |argument|
          !(argument.is_a?(Prism::ConstantReadNode) || argument.is_a?(Prism::ConstantPathNode) ||
            argument.is_a?(Prism::SelfNode))
        end
      end

      # Every qualified name a constant receiver written inside `qualified_prefix` can denote, innermost
      # first: the walk runs before any scope exists, so it cannot resolve the constant, and over-marking a
      # same-named class elsewhere only withholds a check.
      def constant_receiver_candidates(receiver, qualified_prefix)
        written = Source::ConstantPath.qualified_name(receiver)
        return [] if written.nil?
        return [written.delete_prefix("::")] if written.start_with?("::")

        qualified_prefix.length.downto(1).map { |i| (qualified_prefix[0, i] + [written]).join("::") } << written
      end

      def record_define_method(call_node, qualified_prefix, in_singleton_class, accumulator)
        return if call_node.arguments.nil? || call_node.arguments.arguments.empty?

        method_name = literal_method_name(call_node.arguments.arguments.first)
        receiver = call_node.receiver
        if method_name && (receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode))
          return record_constant_define_method(call_node, receiver, method_name, qualified_prefix, accumulator)
        end
        return if qualified_prefix.empty?
        if method_name.nil?
          return record_open_define_method(call_node, qualified_prefix, in_singleton_class,
                                           accumulator)
        end

        # A receiver other than a constant may still be `self` (`[self, k].each { |c| c.define_method(:x) {} }`), so
        # the name stays on the class the walk places the call in.
        record_method(accumulator, qualified_prefix.join("::"), method_name,
                      in_singleton_class ? :singleton : :instance)
      end

      # Issue #2975 — `Other.define_method(:x)` defines `Other#x`, whichever class body or side it is written in: the
      # constant resolves as a `class << Other` operand does ({#singleton_class_owner}), and the enclosing class
      # records nothing.
      def record_constant_define_method(call_node, receiver, method_name, qualified_prefix, accumulator)
        owner = singleton_class_owner(call_node, receiver, qualified_prefix, nil)
        record_method(accumulator, owner, method_name, :instance) if owner
      end

      # Issue #2975 — the literal twins of {#record_self_definer_call}'s computed definers on `self`:
      # `send(:define_method, :x)` records `x` where a direct `define_method(:x)` there would, and
      # `define_singleton_method(:x)` records the class object's `x`. In a `class << self` body the latter defines on
      # the singleton's own singleton, which nothing names, so it records nothing.
      def record_literal_self_definer(node, class_name, in_singleton_class, accumulator)
        arguments = node.arguments&.arguments
        return if arguments.nil? || arguments.empty?

        if node.name == :define_singleton_method
          name = literal_method_name(arguments.first)
          record_method(accumulator, class_name, name, :singleton) if name && !in_singleton_class
        elsif literal_method_name(arguments.first) == :define_method && arguments.length > 1
          name = literal_method_name(arguments[1])
          record_method(accumulator, class_name, name, in_singleton_class ? :singleton : :instance) if name
        end
      end

      # Issue #2793 — a `define_method` on `self` whose name is not a literal defines a method this walk cannot name,
      # on the side and owner a literal one would record under (the walk's placement: a `Class.new { }` or
      # `Struct.new { }` body is its own class's, an eval body its receiver's, a `class << self` body the singleton
      # side), so that side reads as open to `call.undefined-method`.
      #
      # Issue #2901 — on a constant receiver (`Other.define_method(m)`) it defines instance methods of that constant's
      # class, whichever side the call sits on: each class the constant can denote from here opens its instance side
      # ({#constant_receiver_candidates}), and the enclosing class does not. Any other receiver opens nothing.
      def record_open_define_method(call_node, qualified_prefix, in_singleton_class, accumulator)
        receiver = call_node.receiver
        if receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
          constant_receiver_candidates(receiver, qualified_prefix).each do |name|
            record_surface_mark(accumulator, name, Scope::DiscoveryIndex::ENVELOPE_OPEN_INSTANCE_NAMES_MARK)
          end
        elsif receiver.nil? || receiver.is_a?(Prism::SelfNode)
          record_surface_mark(accumulator, qualified_prefix.join("::"), open_names_mark(in_singleton_class))
        end
      end

      # The side's open-names mark a computed definer on `self` records: the singleton side in a `class << self` body.
      def open_names_mark(in_singleton_class)
        if in_singleton_class
          Scope::DiscoveryIndex::ENVELOPE_OPEN_SINGLETON_NAMES_MARK
        else
          Scope::DiscoveryIndex::ENVELOPE_OPEN_INSTANCE_NAMES_MARK
        end
      end

      # The `attr_*` accessor macros that introduce methods Rigor must treat as source-declared. Without this, a class
      # that defines an accessor with `attr_reader :x` AND carries RBS that omits `x` (a common gap — the project ships
      # an incomplete `sig/`) fires a false `call.undefined-method` on `obj.x`, because the undefined-method rule only
      # suppressed `def` / `define_method` / `alias_method`-discovered methods. `attr_reader` defines readers,
      # `attr_writer` writers (`x=`), `attr_accessor` both.
      ATTR_MACROS = %i[attr_reader attr_writer attr_accessor].freeze
      # The subset that defines a writer, which the class-ivar pass counts as a write ({#record_attr_writer_ivars}).
      ATTR_WRITER_MACROS = %i[attr_writer attr_accessor].freeze

      def record_attr_methods(call_node, qualified_prefix, in_singleton_class, accumulator)
        return if qualified_prefix.empty?

        kind = in_singleton_class ? :singleton : :instance
        macro = attr_macro(call_node)
        reader = macro != :attr_writer
        writer = macro != :attr_reader
        class_name = qualified_prefix.join("::")
        each_attr_macro_name(call_node) do |base|
          record_method(accumulator, class_name, base, kind) if reader
          record_method(accumulator, class_name, :"#{base}=", kind) if writer
        end
        return unless attr_macro_computed?(call_node)

        # Issue #2901 — `attr_accessor(*NAMES)` defines members this walk cannot name, so its side opens.
        record_surface_mark(accumulator, class_name, open_names_mark(in_singleton_class))
      end

      # Whether an `attr_*` call ({#attr_macro}) passes a name argument that is not a Symbol or String literal.
      def attr_macro_computed?(call_node)
        arguments = call_node.arguments&.arguments
        return false if arguments.nil?

        arguments = arguments.drop(1) if SURFACE_SEND_CALLS.include?(call_node.name)
        arguments.any? { |arg| literal_method_name(arg).nil? }
      end

      # Yields each name an `attr_*` call declares ({#attr_macro}): a Symbol or String literal argument. A
      # non-literal one (`attr_writer(*names)`, `send(:attr_writer, name)`) names nothing Rigor can read.
      def each_attr_macro_name(call_node)
        return if attr_macro(call_node).nil? || call_node.arguments.nil?

        arguments = call_node.arguments.arguments
        arguments = arguments.drop(1) if SURFACE_SEND_CALLS.include?(call_node.name)
        arguments.each do |arg|
          base = literal_method_name(arg)
          yield base unless base.nil?
        end
      end

      # Issue #2097 — the {ATTR_MACROS} entry a call declares members with on the lexical class, or nil. The
      # call is on the body's self, implicitly or as `self.` (`self.attr_accessor :x`), and names the macro
      # directly or as the literal first argument of `send` / `public_send` / `__send__`
      # (`send(:attr_accessor, :x)`); the same spellings `SigGen::Generator#attr_writer_names` reads. Any
      # other receiver defines on another object.
      def attr_macro(call_node)
        return nil unless call_node.is_a?(Prism::CallNode)
        return nil unless call_node.receiver.nil? || call_node.receiver.is_a?(Prism::SelfNode)
        return call_node.name if ATTR_MACROS.include?(call_node.name)
        return nil unless SURFACE_SEND_CALLS.include?(call_node.name)

        macro = literal_method_name(call_node.arguments&.arguments&.first)
        macro if ATTR_MACROS.include?(macro)
      end

      # Issue #736 — the module-level accessor macros, which introduce methods on BOTH sides of the class.
      # ActiveSupport defines them on `Module`, so every class and module body can use them, and Rails codebases
      # do: `mattr_accessor` / `cattr_accessor` (an alias of it) and `class_attribute` account for 92 false
      # `call.undefined-method` on redmine the moment any `sig/` declares the class — invisible before that,
      # because an undeclared receiver is not a receiver the rule can speak about.
      #
      # The value is `[reader, writer, predicate]`. `class_attribute` also defines `x?` on both sides.
      #
      # Recognising ActiveSupport's spellings in the engine's own walk is a deliberate exception to "steer
      # metaprogramming toward the plugin API": the consumer that has to see these is the cross-file
      # `discovered_methods` table (`finalize_def_index` keeps accessor-introduced names there precisely
      # because they are not monkey-patches), and no plugin surface reaches it — the ADR-16 synthetic-method
      # tier feeds the DISPATCHER, which `Analysis::CheckRules` does not consult. A name table is the smallest
      # thing that works; a plugin-supplied one can replace it whenever that surface exists.
      MODULE_ATTR_MACROS = Ractor.make_shareable(
        {
          mattr_reader: [true, false, false], mattr_writer: [false, true, false],
          mattr_accessor: [true, true, false], cattr_reader: [true, false, false],
          cattr_writer: [false, true, false], cattr_accessor: [true, true, false],
          class_attribute: [true, true, true]
        }
      )

      # Both kinds, unconditionally. `instance_accessor: false` (and its `instance_reader:` /
      # `instance_writer:` / `instance_predicate:` siblings) narrows the real surface, and honouring them here
      # would buy a missed detection on a shape nobody writes by accident — this table's only consumer is a
      # SUPPRESSION, where over-recording costs a diagnostic that would have fired on working code anyway.
      def record_module_attr_methods(call_node, qualified_prefix, accumulator)
        return if qualified_prefix.empty?
        return unless call_node.receiver.nil? # only the implicit-self macro defines on the lexical class
        return if call_node.arguments.nil?

        reader, writer, predicate = MODULE_ATTR_MACROS.fetch(call_node.name)
        class_name = qualified_prefix.join("::")
        call_node.arguments.arguments.each do |arg|
          base = literal_method_name(arg)
          next if base.nil?

          record_both_kinds(accumulator, class_name, base) if reader
          record_both_kinds(accumulator, class_name, :"#{base}=") if writer
          record_both_kinds(accumulator, class_name, :"#{base}?") if predicate
        end
      end

      # Issue #2793 — the `extend` that decides the side of an {Source::ForwardableDelegators::AMBIGUOUS} macro
      # (`def_delegators`, `def_delegator`, `delegate`): `Forwardable` makes them instance methods,
      # `SingleForwardable` singleton methods.
      FORWARDABLE_MODULES = { Forwardable: :instance, SingleForwardable: :singleton }.freeze

      # Issue #2793 — a Forwardable delegator macro defines its literal names as methods, which join the existence
      # table so `call.undefined-method` stops firing on them (their return types stay unknown: the envelope is
      # opaque and no `def` node backs them). The side is the macro's own, or, for an ambiguous macro, the side
      # of the `extend` this walk met earlier in the body: singleton under a lone `extend SingleForwardable`,
      # instance otherwise (a class extended in another file or by a superclass is far likelier `Forwardable`).
      # Inside `class << self` the macro defines on the singleton class. A name the syntax hides
      # (`def_delegators :@x, *NAMES`) marks the class {Scope::DiscoveryIndex::ENVELOPE_OPEN_NAMES_MARK}.
      def record_forwardable_methods(call_node, qualified_prefix, in_singleton_class, accumulator)
        return if qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        note_forwardable_extend(call_node, class_name, accumulator) unless in_singleton_class
        delegation = Source::ForwardableDelegators.of(call_node)
        return if delegation.nil?

        kind = forwardable_side(delegation, class_name, in_singleton_class, accumulator)
        delegation.names.each { |name| record_method(accumulator, class_name, name, kind) }
        return unless delegation.open?

        record_surface_mark(accumulator, class_name, Scope::DiscoveryIndex::ENVELOPE_OPEN_NAMES_MARK)
      end

      def note_forwardable_extend(call_node, class_name, accumulator)
        return unless call_node.name == :extend && call_node.receiver.nil?

        (call_node.arguments&.arguments || []).each do |argument|
          side = FORWARDABLE_MODULES[forwardable_module_name(argument)]
          next if side.nil?

          ((accumulator.forwardable_extends ||= {})[class_name] ||= Set.new) << side
        end
      end

      def forwardable_module_name(node)
        case node
        when Prism::ConstantReadNode then node.name
        when Prism::ConstantPathNode then node.parent.nil? ? node.name : nil
        end
      end

      def forwardable_side(delegation, class_name, in_singleton_class, accumulator)
        return :singleton if in_singleton_class
        return delegation.side unless delegation.side == Source::ForwardableDelegators::AMBIGUOUS

        extended = accumulator.forwardable_extends&.[](class_name)
        extended == Set[:singleton] ? :singleton : :instance
      end

      # The instance names a Forwardable macro defines, for {#call_superseded_names}: a delegator written after a
      # `def` of the name replaces it. Asked only outside `class << self`, and a macro whose side settles to the
      # singleton (`extend SingleForwardable; def_delegators :@x, :size`) leaves an instance `def size` standing.
      def forwardable_superseded_names(call_node, qualified_prefix, accumulator)
        delegation = Source::ForwardableDelegators.of(call_node)
        return [] if delegation.nil? || qualified_prefix.empty?

        side = forwardable_side(delegation, qualified_prefix.join("::"), false, accumulator)
        side == :instance ? delegation.names : []
      end

      def record_both_kinds(accumulator, class_name, method_name)
        record_method(accumulator, class_name, method_name, :instance)
        record_method(accumulator, class_name, method_name, :singleton)
      end

      def literal_method_name(node)
        Source::Literals.symbol_or_string(node)
      end

      # Walks every file in `paths` (each path is parsed once with `Prism.parse_file`) and returns the unioned
      # project-wide `discovered_classes` Hash: `{qualified_name => Singleton[…]}`, which seeds each file's
      # `default_scope.discovered_classes` so that lexical constant lookup in one file resolves a `class Foo` declared
      # in a sibling file. The runner's pre-pass now gets it from {#discovered_project_index_for_paths}; this is the
      # classes-only walk. Per-file collisions are last-write-wins (matches the existing in-file merge
      # semantics). Parse failures fail-soft to an empty contribution. The `buffer` argument, when present, redirects
      # reads for the bound logical path to the buffer's physical path so editor-mode pre-passes see the in-flight
      # bytes.
      #
      # Modules are registered on the same terms as classes, matching `DeclarationArtifacts.record_declarations`'
      # per-file behaviour (ADR-57 WD3). An earlier revision excluded them, fearing an undiscovered `M.x` would fall
      # through to `Kernel#x`; the exclusion was retired once measurement showed Kernel's private instance methods
      # (`select`, `puts`, `load`, …) resolve to nothing on a `Singleton[M]` receiver, and that a project-side
      # `def self.x` body wins over the lenient `Singleton[Object]` fallback anyway. The residual leak is `Class`-only
      # (`M.new`, `M.superclass`), which mistypes only code that raises `NoMethodError` at runtime.
      #
      def discovered_classes_for_paths(paths, buffer: nil)
        accumulator = {}
        paths.each do |path|
          physical = buffer ? buffer.resolve(path) : path
          source = File.read(physical)
          root = Prism.parse(source, filepath: path).value
          file_classes = {}
          ClassDeclarations.collect_class_decls(root, [], file_classes)
          accumulator.merge!(file_classes) # all or nothing: an overflow above contributes none of this file (#2455)
        rescue StandardError, SystemStackError => e
          raise if uncontainable_overflow?(e)

          # Skip files that fail to parse or read; the per-file analyzer surfaces the parse error separately.
          next
        end
        synthesize_namespace_prefixes(accumulator).freeze
      end

      # ADR-24 slice 2 — cross-file companion to `discovered_classes_for_paths`. Walks every project file once and
      # returns both the merged `discovered_def_nodes` table (a class reopened across files has its method tables
      # merged) and the merged class -> superclass-name map. The engine consults these so an implicit-self call inside a
      # subclass resolves against a superclass `def` declared in a sibling file (`Mastodon::CLI::Accounts` calling a
      # helper defined in `Mastodon::CLI::Base`).
      #
      # The returned `def_sources` map mirrors `def_nodes` but stores a `"path:line"` String per `(class_name,
      # method_name)` instead of the `Prism::DefNode`. A `Prism::Location` does not expose its source file through
      # public API, so the source site is captured here, in the pre-pass loop that still holds `path`.
      # `CheckRules::UndefinedMethod.diagnostic` consults the seeded copy to name the defining file when a project
      # monkey-patch on a core/stdlib/gem class is called cross-file (ADR-17). First write wins, matching `def_nodes`'
      # own merge order.
      #
      # @return
      #   `{ def_nodes:, def_sources:, superclasses:, includes:, class_sources: }`
      def discovered_def_index_for_paths(paths, buffer: nil)
        acc = new_def_index_accumulator
        paths.each do |path|
          physical = buffer ? buffer.resolve(path) : path
          root = Prism.parse(File.read(physical), filepath: path).value
          fold_file_index(acc, build_file_index(path, root)) # all or nothing per file (#2455)
        rescue DeclarationWalk::ContractError
          raise # a broken walk contract, not an unreadable file: skipping it would hide the failure
        rescue StandardError, SystemStackError => e
          raise if uncontainable_overflow?(e)

          # Skip files that fail to parse or read; the per-file analyzer surfaces the parse error separately.
          next
        end
        finalize_def_index(acc)
      end

      # B1 / ADR-89 WD1 (incremental propagation gates) — parses `paths` ONCE and returns the merged def-index
      # (as {#discovered_def_index_for_paths}), each file's comment-stripped {#code_fingerprint} (B1), AND each
      # file's {DeclarationSignature} (ADR-89 WD1 — the per-def SIGNATURE shape that replaces the per-def body
      # fingerprint, so a body edit that leaves every signature equal is declaration-stable). The incremental
      # session drives the fingerprint / class-declaration change detection off `def_index` and the
      # declaration-stability skip decision off `declaration_signatures`, so a changed file is parsed once for
      # all of them (recon §2 dedup). A per-file live index (built + folded, exactly as
      # {#discovered_project_index_incremental}'s changed-file branch) yields the live def nodes the signature
      # reads their parameter structure from. Issue #1120 — and each file's own refinement table, which the merged
      # def-index cannot attribute back to a file, so the session can diff it against the file's seed bundle.
      # Issue #1459 — and each file's {#defined_method_names}, diffed the same way. Issue #2134 — and each file's
      # {#visibility_entries}. Issue #2158 — and each file's `global_write_census`.
      # @return `{ def_index:, code_fingerprints:, declaration_signatures:, refinements:, defined_method_names:,
      #   visibility_entries:, global_write_census: }`.
      def scan_summary_for_paths(paths, buffer: nil)
        acc = new_def_index_accumulator
        code_fingerprints = {}
        declaration_signatures = {}
        per_file = { refinements: {}, defined_method_names: {}, visibility_entries: {}, global_write_census: {} }
        paths.each do |path|
          physical = buffer ? buffer.resolve(path) : path
          source = File.read(physical)
          parsed = Prism.parse(source, filepath: path)
          file_index = build_file_index(path, parsed.value)
          fold_file_index(acc, file_index)
          code_fingerprints[path] = code_fingerprint(source, parsed.comments)
          declaration_signatures[path] = DeclarationSignature.declaration_signature(file_index)
          file_summary(file_index).each { |key, table| per_file[key][path] = table unless table.nil? }
        rescue DeclarationWalk::ContractError
          raise # a broken walk contract, not an unreadable file: skipping it would hide the failure
        rescue StandardError, SystemStackError => e
          raise if uncontainable_overflow?(e)

          next
        end
        { def_index: finalize_def_index(acc), code_fingerprints: code_fingerprints,
          declaration_signatures: declaration_signatures, **per_file }
      end

      # One file's tables {#scan_summary_for_paths} hands the session to diff against the file's seed bundle (nil for
      # a table the file does not have).
      def file_summary(file_index)
        { refinements: file_index[:refinements], defined_method_names: defined_method_names(file_index),
          visibility_entries: visibility_entries(file_index), global_write_census: file_index[:global_write_census] }
      end

      # Issue #1459 — every method name one file's index defines, on any class or module and either side: the keys of
      # `methods` (which also carries an `attr_*`, `alias` or `define_method` name) and of the instance and singleton
      # def-node tables. A single file's `methods` already holds its `def` names, since `subtract_def_methods` runs only
      # on the merged accumulator; the def-node tables are read as well so the census reads exactly the tables
      # `BlockCallTiming.project_defines_anywhere?` reads. Takes a live file index or a seed bundle, which hold the
      # same three keys.
      def defined_method_names(file_index)
        names = Set.new
        %i[methods def_nodes singleton_def_nodes].each do |key|
          file_index[key]&.each_value { |table| names.merge(table.keys) }
        end
        # Issue #2184 — a named deferred-range row with no side (a `def` in a block, a `define_singleton_method`) is a
        # definition no table above holds.
        file_index[:deferred_ranges]&.each_value { |rows| rows.each { |row| names << row[2] if row[2] && row[3].nil? } }
        names.freeze
      end

      # Issue #2134 — one file's contributions to the visibility table and its contested sibling, as a Set of
      # `[class, slot, visibility]` entries and `[:contested, class, slot]` contests, where a slot is a method name or
      # `[:singleton, name]`. Takes a live file index or a seed bundle, which hold the same keys.
      #
      # Issue #2161 — and a `[:module_function, owner, name]` entry for each of the file's deferred-range rows that
      # `DefinerResolution.module_function_row?` counts (a named def row whose kind is not `:instance`): a module
      # function's singleton copy is public whatever its instance slot says, so the row is a visibility fact the
      # table itself does not hold.
      def visibility_entries(file_index)
        entries = Set.new
        file_index[:method_visibilities]&.each do |class_name, table|
          table.each { |slot, visibility| entries << [class_name, slot, visibility] }
        end
        contested = (file_index[:siblings] || {})[:contested_discovered_method_visibilities]
        contested&.each { |(class_name, slot)| entries << [:contested, class_name, slot] }
        add_module_function_entries(file_index[:deferred_ranges], entries)
        entries.freeze
      end

      def add_module_function_entries(deferred_ranges, entries)
        deferred_ranges&.each_value do |rows|
          rows.each do |(_start, _finish, name, kind, owner)|
            entries << [:module_function, owner, name] if name && owner && kind != :instance
          end
        end
      end

      # B1 — the SHA-256 of `source` with every comment's byte range excised (a line comment ends before its
      # newline, so the newline is KEPT: stripping it preserves the line count, hence every def's start line
      # and the whole engine bundle). Two revisions of a file that differ ONLY in comment text therefore share
      # a code fingerprint — the signal the bundle-equality gate uses to prove a changed file's *code* (and so
      # every code-derived cross-file fact the engine and code-reading plugins produce from it) is unchanged.
      # A comment that adds or removes a LINE shifts subsequent code, so the fingerprint changes (the gate then
      # conservatively keeps the file's dependents — a line shift can move a def the ADR-17 diagnostic names).
      def code_fingerprint(source, comments)
        bytes = source.b
        return Digest::SHA256.hexdigest(bytes) if comments.empty?

        result = +"".b
        cursor = 0
        comments.sort_by { |comment| comment.location.start_offset }.each do |comment|
          loc = comment.location
          result << bytes.byteslice(cursor, loc.start_offset - cursor) if loc.start_offset > cursor
          cursor = loc.end_offset if loc.end_offset > cursor
        end
        result << bytes.byteslice(cursor, bytes.bytesize - cursor)
        Digest::SHA256.hexdigest(result)
      end

      # Combined single-parse cross-file pre-pass used by the project-wide runner pre-pass
      # ({Analysis::Runner::ProjectPrePasses#discover}). {#discovered_classes_for_paths} and
      # {#discovered_def_index_for_paths} each `Prism.parse` every project file independently; this walks the
      # project ONCE, parsing each file a single time and driving BOTH collectors over the same tree, then
      # returns `{ classes:, def_index: }`. Each file is parsed, collected, and dropped before the next
      # iteration, so no more than one AST is held alive at a time (peak RSS stays flat on large projects).
      #
      # Error degradation is identical to the two independent loops it replaces: a read / parse failure (the
      # rescue's real target) contributes nothing to either table.
      #
      # @param uncertain — issue #2021: the paths whose every method contribution is `possible`
      #   ({Certainty.every_contribution}).
      def discovered_project_index_for_paths(paths, buffer: nil, uncertain: EMPTY_PATH_SET)
        classes = {}
        acc = new_def_index_accumulator
        paths.each do |path|
          physical = buffer ? buffer.resolve(path) : path
          root = Prism.parse(File.read(physical), filepath: path).value
          # All or nothing per file, as the incremental loop below: both tables are built in isolation and folded only
          # once the whole file walked, so a file that overflows the stack contributes none of either (#2455).
          file_classes = {}
          ClassDeclarations.collect_class_decls(root, [], file_classes)
          file_index = if uncertain.include?(path)
                         without_written_slots(build_file_index(path, root, uncertain: true), acc)
                       else
                         build_file_index(path, root)
                       end
          fold_file_index(acc, file_index)
          classes.merge!(file_classes)
        rescue DeclarationWalk::ContractError
          raise # a broken walk contract, not an unreadable file: skipping it would hide the failure
        rescue StandardError, SystemStackError => e
          raise if uncontainable_overflow?(e)

          # Skip files that fail to parse or read; the per-file analyzer surfaces the parse error separately.
          next
        end
        finalize_project_index(classes, acc)
      end

      # #2455 — a `SystemStackError` raised from C (`Prism.parse` of a source nested near its own cap) has no
      # backtrace and leaves the process unable to survive a second one, so it is not contained: it keeps the
      # run-level abort.
      def uncontainable_overflow?(error)
        error.is_a?(SystemStackError) && error.backtrace.nil?
      end

      # The shared tail of the two whole-project discovery walks: settles the def-index and re-anchors the
      # `classes` table it accumulated beside it.
      def finalize_project_index(classes, acc)
        def_index = finalize_def_index(acc)
        { classes: rename_compact_classes(classes, def_index[:compact_header_renames]).freeze,
          def_index: def_index }
      end

      # Issue #722 residue 2 — the `classes` table is accumulated beside the def-index rather than inside it,
      # so it is re-anchored here from the renames the fold settled. The value is rebuilt, not moved: it is a
      # `Singleton[…]` of the key, and a moved key with the old singleton inside would type `Outer::Leaf` as
      # `Wrap::Outer::Leaf` at every reference.
      def rename_compact_classes(classes, renames)
        return classes if renames.nil? || renames.empty?

        classes.each_with_object({}) do |(name, type), out|
          renamed = rename_compact_name(renames, name)
          out[renamed] = renamed == name ? type : Type::Combinator.singleton_of(renamed)
        end
      end

      # ADR-85 WD2 — the incremental cross-file discovery pass. The bundle-driven twin of
      # {#discovered_project_index_for_paths}: instead of parsing + walking every file, it folds each file's
      # cached per-file *seed bundle* (plain-data tables + `(node_id, name, fingerprint)` def-node handles),
      # re-walking ONLY the files whose current digest does not match their cached bundle (changed / added).
      # Rebuilds in canonical file order — the sound reconstruction (the merged tables are Set-union / later-wins
      # / whole-project-finalize, so a changed file cannot be delta-patched, only re-folded in place; recon Q2).
      #
      # Returns `{ classes:, def_index:, bundles: }` — `bundles` is the CURRENT per-file bundle set (cached ones
      # reused, changed ones refreshed, removed ones absent) so the caller persists the up-to-date snapshot.
      # A re-walked file's methods stay LIVE `Prism::DefNode`s in the returned index (no on-demand re-parse for
      # a file we just walked); an unchanged file's methods are {DefHandle}s the accessor choke points resolve
      # lazily. On a cold run (`seed_bundles` empty) every file is re-walked, so the index is entirely live —
      # identical to {#discovered_project_index_for_paths} — while the bundles are built for the next run.
      #
      # @param paths — project file paths, in canonical order.
      # @param seed_bundles — the prior run's per-file bundles, keyed by logical path.
      # @return `{ classes:, def_index:, bundles: }`.
      # @param uncertain — issue #2021: as {#discovered_project_index_for_paths}. Such a file is always re-walked and
      #   keeps no bundle, since a bundle does not record that its contributions were all possible.
      def discovered_project_index_incremental(paths, seed_bundles:, buffer: nil, uncertain: EMPTY_PATH_SET) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        classes = {}
        acc = new_def_index_accumulator
        bundles = {}
        paths.each do |path|
          physical = buffer ? buffer.resolve(path) : path
          digest = Cache::FileDigest.hexdigest(physical)
          walked = uncertain.include?(path)
          # A walked file neither reuses nor stores a bundle. Both are guards no spec separates: no bundle is ever
          # stored for a walked file, so the reuse guard matters only if a path changes role within one session.
          cached = walked ? nil : seed_bundles[path]
          if cached && cached[:digest] == digest
            bundles[path] = cached
            classes.merge!(cached[:classes])
            fold_file_index(acc, bundle_to_file_index(cached, path))
          else
            source = File.read(physical)
            parsed = Prism.parse(source, filepath: path)
            root = parsed.value
            file_index = build_file_index(path, root, uncertain: walked)
            file_classes = {}
            ClassDeclarations.collect_class_decls(root, [], file_classes)
            fingerprint = code_fingerprint(source, parsed.comments)
            bundles[path] = build_seed_bundle(file_index, file_classes, digest, fingerprint) unless walked
            classes.merge!(file_classes)
            fold_file_index(acc, walked ? without_written_slots(file_index, acc) : file_index)
          end
        rescue DeclarationWalk::ContractError
          raise # a broken walk contract, not an unreadable file: skipping it would hide the failure
        rescue StandardError, SystemStackError => e
          raise if uncontainable_overflow?(e)

          # Skip files that fail to parse / read; the per-file analyzer surfaces the parse error separately.
          next
        end
        finalize_project_index(classes, acc).merge(bundles: bundles)
      end

      # Builds ONE file's isolated def-index contribution (live `Prism::DefNode`s) by folding it into a fresh
      # accumulator — recon Q2(a)'s "constructible in isolation" property. Shared by the cold-baseline bundle
      # build and the incremental changed-file re-walk.
      def build_file_index(path, root, uncertain: false)
        file_acc = new_def_index_accumulator
        accumulate_project_index(file_acc, path, root, uncertain: uncertain)
        file_acc
      end

      # Issue #2021 — the single-valued slot tables an `uncertain` file writes, each with its contest sibling.
      UNCERTAIN_SLOT_TABLES = {
        def_nodes: :contested_discovered_def_nodes,
        singleton_def_nodes: :contested_discovered_singleton_def_nodes,
        method_visibilities: :contested_discovered_method_visibilities,
        parameter_envelopes: :contested_discovered_parameter_envelopes
      }.freeze

      # Issue #2021 — an `uncertain` file's isolated index without the slots `acc` already holds. The walked files fold
      # after every other discovered file, so `acc` holds what the configured (certain) files wrote: a walked reopening
      # of such a class adds the names it defines (existence) and leaves each written def node, visibility and
      # envelope, and its contest, as the certain writer left it. Without this, the walked file's possible write was
      # the slot's last and contested it, and `rigor check lib/user.rb plug/x.rb` withheld what `rigor check
      # lib/user.rb` reports. A slot no earlier file wrote is taken, contested.
      def without_written_slots(file_index, acc)
        siblings = (file_index[:siblings] || {}).dup
        tables = UNCERTAIN_SLOT_TABLES.to_h do |table, sibling|
          written = acc[table]
          kept = {}
          (file_index[table] || {}).each do |class_name, entries|
            sitting = written[class_name]
            entries = entries.reject { |key, _| sitting.key?(key) } if sitting
            kept[class_name] = entries unless entries.empty?
          end
          contests = siblings[sibling]
          siblings[sibling] = contests.select { |class_name, key| kept[class_name]&.key?(key) }.to_set if contests
          [table, kept]
        end
        file_index.merge(tables).merge(siblings: siblings)
      end

      # ADR-85 WD2 — folds a single file's isolated def-index contribution into the cross-file accumulator,
      # applying EXACTLY the merge semantics {#accumulate_project_index} applies incrementally (def_nodes
      # later-wins, def_sources first-wins, includes / class_sources accumulate, everything else later-wins).
      # Polymorphic over the def-node value: a re-walked file's `file_index` carries live nodes; a cached
      # bundle's carries {DefHandle}s. The merges never deref the value, so both fold identically.
      def fold_file_index(acc, file_index)
        fold_siblings(acc, file_index)
        fold_def_tables(acc, file_index)
        # Issue #992 — a pre-23 seed bundle carries no envelopes; the SCHEMA bump makes such a blob a cold
        # rebuild, and an absent table only ever withholds a check.
        fold_parameter_envelopes(acc, file_index[:parameter_envelopes] || {})
        # Issue #681 — a re-walked file contributes live nodes and their chains together. A file restored from
        # a seed bundle contributes NO entry here and cannot: this table is keyed by node identity, and the
        # only object a bundle has is a {DefHandle}. Issue #707 — the chain travels ON the handle instead, and
        # {DefNodeResolver} re-attaches it to the node it mints, so both paths answer the same chain for the
        # same body without either one keying a table by an object the other never sees.
        acc[:def_nestings].merge!(file_index[:def_nestings] || {})
        # Issue #1097 — keyed by file path, so the merge is a plain union (a bundle-restored file
        # contributes exactly the ranges its cold walk recorded).
        acc[:deferred_ranges].merge!(file_index[:deferred_ranges] || {})
        fold_refinements(acc, file_index[:refinements])
        # Issue #1367 — a union, so the fold is order-independent; a pre-29 bundle carries no key.
        acc[:global_write_census].merge(file_index[:global_write_census] || GlobalWriteCensus::EMPTY)
        fold_ancestry_tables(acc, file_index)
        fold_constant_tables(acc, file_index)
      end

      # ADR-119 WD1 — the `possible_*` / `contested_*` siblings of {Scope::DiscoveryIndex::SIBLINGS}, carried as ONE
      # `{sibling name => table}` Hash (`acc[:siblings]`) through the accumulator, the fold, the compact-header
      # rename, the finalize and the seed bundle, so no copy path names a sibling and none can drop one. A pre-36
      # bundle carries the empty siblings of the walk before WD3's producers, and the SCHEMA bump makes such a blob
      # a cold rebuild. Called BEFORE the file's members fold, because the `possible` rule reads the accumulator's
      # member as it stood ({#fold_file_siblings}).
      def fold_siblings(acc, file_index)
        fold_file_siblings(acc, file_index[:siblings] || {},
                           methods: file_index[:methods], def_nodes: file_index[:def_nodes],
                           singleton_def_nodes: file_index[:singleton_def_nodes],
                           method_visibilities: file_index[:method_visibilities])
      end

      # ADR-119 WD3 — folds one file's siblings into the accumulator under each member's own fold, so the result is
      # the same in any file order and a bundle-served file folds as its live walk would:
      #
      # - `possible_discovered_methods` by {#fold_possible_methods} against `acc[:methods]` before this file's
      #   `methods` join it;
      # - the def-node and visibility slots follow their writer, as the members fold later-wins: the file's contests
      #   replace the accumulator's on every key the file writes ({#fold_slot_contests});
      # - every other sibling (the joined envelopes' contests among them) by union.
      def fold_file_siblings(acc, siblings, methods:, def_nodes:, singleton_def_nodes:, method_visibilities: {})
        target = acc[:siblings]
        siblings.each do |name, table|
          target[name] =
            case name
            when :possible_discovered_methods
              fold_possible_methods(target.fetch(name), acc[:methods], table, methods)
            when :contested_discovered_def_nodes then fold_slot_contests(target.fetch(name), def_nodes, table)
            when :contested_discovered_singleton_def_nodes
              fold_slot_contests(target.fetch(name), singleton_def_nodes, table)
            when :contested_discovered_method_visibilities
              fold_visibility_contests(target.fetch(name), acc[:method_visibilities], method_visibilities, table)
            else union_sibling_value(target.fetch(name), table)
            end
        end
      end

      # ADR-119 WD3 — the `possible_discovered_methods` fold, per name and side: `P' = (P − C_f) ∪ (P_f − C)`,
      # where `C = member − P` is what the accumulator (or seed) answers certainly and `C_f = member_f − P_f` what
      # the file does. A side some contribution supplies certainly is never possible, whatever the order the files
      # fold in. Returns `possible` itself when nothing changes; otherwise a copy (the rows are copied once).
      def fold_possible_methods(possible, members, file_possible, file_members)
        result = strip_file_certain(possible, file_possible, file_members)
        add_file_possible(result, possible, members, file_possible)
      end

      # `P − C_f`: `possible` less the sides the file answers certainly; `possible` itself when nothing goes.
      def strip_file_certain(possible, file_possible, file_members)
        result = possible
        possible.each do |class_name, row|
          file_row = file_members[class_name]
          next if file_row.nil?

          row.each do |method_name, kind|
            certain = kind_minus(file_row[method_name], file_possible.dig(class_name, method_name))
            remaining = kind_minus(kind, certain)
            next if remaining == kind

            result = possible.transform_values(&:dup) if result.equal?(possible)
            remaining.nil? ? result[class_name].delete(method_name) : (result[class_name][method_name] = remaining)
          end
          result.delete(class_name) if result[class_name].empty?
        end
        result
      end

      # `∪ (P_f − C)`: the file's possible sides the accumulator (`members` less `possible`) does not answer
      # certainly. Copies `result` first when it is still `possible`.
      def add_file_possible(result, possible, members, file_possible)
        file_possible.each do |class_name, row|
          row.each do |method_name, kind|
            added = kind_minus(kind, kind_minus(members.dig(class_name, method_name),
                                                possible.dig(class_name, method_name)))
            next if added.nil?

            merged = merge_sibling_kind(result.dig(class_name, method_name), added)
            next if merged == result.dig(class_name, method_name)

            result = possible.transform_values(&:dup) if result.equal?(possible)
            (result[class_name] ||= {})[method_name] = merged
          end
        end
        result
      end

      # The sides of `kind` that `removed` does not cover (nil when none); either may be nil.
      def kind_minus(kind, removed)
        return kind if removed.nil? || kind.nil?
        return nil if removed == Scope::DiscoveryIndex::METHOD_KIND_BOTH || removed == kind

        kind == Scope::DiscoveryIndex::METHOD_KIND_BOTH ? without_kind(kind, removed) : kind
      end

      # ADR-119 WD3 — a single-valued slot's contests after a later-wins fold: the slots the file writes take the
      # file's contests (`file_contested`), every other key keeps the accumulator's (`sitting`). `file_slots` is the
      # file's `{class => {name => value}}` table. Returns `sitting` itself when nothing changes.
      def fold_slot_contests(sitting, file_slots, file_contested)
        stale = sitting.empty? ? nil : sitting.select { |class_name, name| file_slots[class_name]&.key?(name) }
        return sitting if (stale.nil? || stale.empty?) && file_contested.empty?

        result = stale.nil? || stale.empty? ? sitting.dup : sitting - stale
        result.merge(file_contested)
      end

      # The visibility table's {#fold_slot_contests}, where `recorded` is the table the file folds into as it stood.
      # Issue #1984 — a singleton slot (`[:singleton, name]`) does not follow its writer: file order is not load
      # order, so two files that give it different visibilities (`private_class_method :x` here,
      # `class << self; public :x; end` in a reopening) leave it contested, and a contest on it stays whichever
      # file folds later. The instance slots fold as before, except (issue #2013) one whose contest carries a
      # replacement's mark ({ScopeIndexer.replaced_visibility_mark}): a `define_method` or an alias in one file and a
      # `private def` in another leave the visibility to load order, so that contest stays too.
      def fold_visibility_contests(sitting, recorded, file_slots, file_contested)
        stale = sitting.select do |class_name, name|
          !name.is_a?(Array) && file_slots[class_name]&.key?(name) &&
            !sitting.include?([class_name, ScopeIndexer.replaced_visibility_mark(name)])
        end
        disagreeing = singleton_visibility_disagreements(recorded, file_slots)
        return sitting if stale.empty? && file_contested.empty? && disagreeing.empty?

        (sitting - stale).merge(file_contested).merge(disagreeing)
      end

      def singleton_visibility_disagreements(recorded, file_slots)
        file_slots.flat_map do |class_name, table|
          sitting = recorded[class_name]
          next [] if sitting.nil?

          table.filter_map do |slot, visibility|
            [class_name, slot] if slot.is_a?(Array) && sitting.key?(slot) && sitting[slot] != visibility
          end
        end
      end

      def union_paths(sitting, arriving)
        return sitting if arriving.empty?
        return arriving if sitting.empty?

        sitting | arriving
      end

      # The union of two sibling tables or entries. A Hash merges per key and a Set or Array unions; two scalars
      # that disagree are a `discovered_methods`-style kind and combine to `:both`, as {#merge_method_kinds} does.
      def union_sibling_value(sitting, arriving)
        return arriving if sitting.nil? || sitting.empty?
        return sitting if arriving.nil? || arriving.empty?

        case sitting
        when Hash then sitting.merge(arriving) { |_key, left, right| union_sibling_value(left, right) }
        when Set, Array then sitting | arriving
        else sitting == arriving ? sitting : Scope::DiscoveryIndex::METHOD_KIND_BOTH
        end
      end

      # The sibling tables keyed by file path rather than by class name, which a compact-header rename leaves alone
      # exactly as it leaves the `deferred_ranges` member alone.
      SIBLINGS_KEYED_BY_PATH = %i[possible_discovered_deferred_ranges].freeze
      private_constant :SIBLINGS_KEYED_BY_PATH

      # {#apply_compact_header_renames!} for the siblings: a class-keyed Hash re-keys (colliding keys union), and a
      # Set of key paths renames each path's first element, the class.
      def rename_siblings(siblings, renames)
        siblings.to_h do |name, table|
          next [name, table] if SIBLINGS_KEYED_BY_PATH.include?(name) || table.empty?

          renamed = case table
                    when Set then table.to_set { |path| [rename_compact_name(renames, path.first), *path.drop(1)] }
                    else rename_sibling_hash(table, renames)
                    end
          [name, renamed]
        end
      end

      def rename_sibling_hash(table, renames)
        table.each_with_object({}) do |(class_name, entry), out|
          renamed = rename_compact_name(renames, class_name)
          out[renamed] = out.key?(renamed) ? union_sibling_value(out[renamed], entry) : entry
        end
      end

      def freeze_siblings(siblings)
        siblings.each_value { |table| freeze_sibling_table(table) }
        siblings.freeze
      end

      def freeze_sibling_table(table)
        table.each_value { |entry| freeze_sibling_table(entry) } if table.is_a?(Hash)
        table.each { |entry| entry.freeze if entry.is_a?(Array) } if table.is_a?(Set)
        table.freeze
      end

      # Issue #1120 — a union, so the fold is order-independent and a bundle-served file folds exactly as its live
      # walk would. The slot stays nil until some file refines something (see {#finalize_def_index}).
      def fold_refinements(acc, file_refinements)
        return if file_refinements.nil? || file_refinements.empty?

        acc[:refinements] = merge_refinement_tables(acc[:refinements], file_refinements)
      end

      # Issue #644 — the census folds per (name, path), so a re-folded file replaces exactly its own
      # contribution and the fold stays order-independent. `|| {}` keeps it total over a pre-#644 seed
      # bundle, which carries no census.
      def fold_constant_tables(acc, file_index)
        (file_index[:constant_writes] || {}).each do |name, by_path|
          (acc[:constant_writes][name] ||= {}).merge!(by_path)
        end
      end

      # def_nodes / singleton_def_nodes / method_visibilities / methods fold class-nested later-wins;
      # def_sources / singleton_def_sources fold first-wins ({#fold_def_sources}).
      def fold_def_tables(acc, file_index)
        file_index[:def_nodes].each { |cn, methods| (acc[:def_nodes][cn] ||= {}).merge!(methods) }
        file_index[:singleton_def_nodes].each { |cn, methods| (acc[:singleton_def_nodes][cn] ||= {}).merge!(methods) }
        file_index[:method_visibilities].each { |cn, table| (acc[:method_visibilities][cn] ||= {}).merge!(table) }
        file_index[:methods].each { |cn, table| acc[:methods][cn] = merge_method_kinds(acc[:methods][cn] || {}, table) }
        fold_def_sources(acc, :def_sources, file_index[:def_sources])
        fold_def_sources(acc, :singleton_def_sources, file_index[:singleton_def_sources])
      end

      # Issue #992 — joins one file's envelope table into the cross-file accumulator, in place. The join is
      # commutative and idempotent, so the fold is order-independent and a bundle-served file folds exactly
      # as its live walk would.
      def fold_parameter_envelopes(acc, file_envelopes)
        target = acc[:parameter_envelopes]
        file_envelopes.each do |class_name, entries|
          bucket = target[class_name] = (target[class_name] || {}).dup
          entries.each { |key, envelope| bucket[key] = Source::ParameterEnvelope.merge(bucket[key], envelope) }
        end
      end

      # A `"path:line"` source table (instance or singleton) is first-file-wins per `(class, method)` (`||=`),
      # matching `merge_discovered_defs`.
      def fold_def_sources(acc, key, file_sources)
        file_sources.each do |cn, methods|
          target = (acc[key][cn] ||= {})
          methods.each { |method_name, source| target[method_name] ||= source }
        end
      end

      # superclasses later-wins; includes / class_sources accumulate; member layouts later-wins.
      def fold_ancestry_tables(acc, file_index)
        acc[:superclasses].merge!(file_index[:superclasses])
        # Issue #682 — a pre-#682 seed bundle carries no header nestings; the SCHEMA bump makes such a blob a
        # cold rebuild, but default so any in-flight fold stays total and simply peels for those classes.
        merge_header_nestings(acc[:header_nestings], file_index[:header_nestings] || {})
        fold_mixin_lists(acc, file_index)
        file_index[:class_sources].each { |cn, files| (acc[:class_sources][cn] ||= Set.new).merge(files) }
        (file_index[:singleton_class_sources] || {}).each do |cn, files|
          (acc[:singleton_class_sources][cn] ||= Set.new).merge(files)
        end
        # Issue #722 residue 2 — a pre-#722 seed bundle carries no candidates; the SCHEMA bump makes such a
        # blob a cold rebuild, but default so any in-flight fold stays total.
        acc[:compact_headers].merge!(file_index[:compact_headers] || {})
        acc[:data_member_layouts].merge!(file_index[:data_member_layouts])
        acc[:struct_member_layouts].merge!(file_index[:struct_member_layouts])
      end

      # The three module-list tables of one file, each folded under its own table's contract: all three
      # now fold nearest-first — `includes` since #1173 (the instance-ancestor search order its consumers
      # read), `prepends` and `extends` since their ordering fixes. Split out of {#fold_ancestry_tables}
      # to hold its ABC budget.
      def fold_mixin_lists(acc, file_index)
        accumulate_include_lists(acc[:includes], file_index[:includes])
        # Issue #1123 — a pre-#1123 seed bundle carries no prepends; the SCHEMA bump makes such a blob a
        # cold rebuild, but default so any in-flight fold stays total. An absent table only means the walk
        # resolves the class as it did before the ordering fix, which is this table's empty state.
        accumulate_prepend_lists(acc[:prepends], file_index[:prepends] || {})
        accumulate_extend_lists(acc[:extends], file_index[:extends] || {})
        accumulate_unpositioned(acc[:unpositioned_mixins], file_index[:unpositioned_mixins] || {})
      end

      # The `extends` half stores singleton-ancestor search order ({#record_extend_targets}), so a file
      # scanned later contributes NEARER entries for a reopened class — prepend, matching the
      # per-statement convention. `includes` shares the shape since #1173, when its table switched to
      # instance-ancestor search order too ({MixinTables.write_mixin_targets}).
      def accumulate_extend_lists(target, additions)
        additions.each { |cn, mods| target[cn] = (mods + (target[cn] || [])).uniq }
      end

      # Issue #1173 — the same near-side accumulation for the includes table, which now stores
      # instance-ancestor search order for the same reason the extends table stores singleton-ancestor
      # order: a file scanned later contributes NEARER includes for a reopened class. Shared with
      # {#accumulate_extend_lists}' shape deliberately.
      def accumulate_include_lists(target, additions)
        additions.each { |cn, mods| target[cn] = (mods + (target[cn] || [])).uniq }
      end

      # Issue #1123 — the same near-side accumulation for the prepends table, which stores
      # instance-ancestor search order for the same reason the extends table stores singleton-ancestor
      # order ({MixinTables.record_mixin_call}): a file scanned later contributes NEARER prepends for a reopened
      # class. Shared with {#accumulate_extend_lists}' shape deliberately — the two tables answer the
      # `prepend` question on the two sides of the class object, and both fold nearest-first.
      def accumulate_prepend_lists(target, additions)
        additions.each { |cn, mods| target[cn] = (mods + (target[cn] || [])) }
      end

      # ADR-85 WD2 — converts a file's live single-file index + its class table into a Marshal-clean seed
      # bundle: the plain-data tables verbatim, the def-node tables re-expressed as `[node_id, name,
      # fingerprint]` triples (the path is the bundle key), the class-source names (path implicit), and the
      # content digest that gates the bundle's reuse.
      def build_seed_bundle(file_index, file_classes, digest, code_fingerprint) # rubocop:disable Metrics/AbcSize -- one read per bundle slot
        {
          digest: digest,
          # B1 — the comment-stripped code fingerprint, so a recheck can prove this file's edit was
          # comment-only and skip its dependents.
          code_fingerprint: code_fingerprint,
          # ADR-89 WD1 — the per-def SIGNATURE-shape declaration signature (bodies excluded, def lines kept),
          # so a recheck can prove this file's body edit changed no declaration and skip its ancestry /
          # file-level dependents. Computed from the same live `file_index` the bundle is built from, so the
          # value stored here equals the one a later recheck recomputes for an unchanged declaration.
          declaration_signature: DeclarationSignature.declaration_signature(file_index),
          classes: file_classes,
          extends: file_index[:extends],
          def_nodes: live_defs_to_bundle(file_index[:def_nodes], file_index[:def_nestings]),
          singleton_def_nodes: live_defs_to_bundle(file_index[:singleton_def_nodes], file_index[:def_nestings]),
          def_sources: file_index[:def_sources],
          singleton_def_sources: file_index[:singleton_def_sources],
          superclasses: file_index[:superclasses],
          # Issue #682 — plain `{class name => Array[String]}` data, so the bundle stays Marshal-clean and a
          # warm incremental file resolves its ancestor names the way a cold walk of it does.
          header_nestings: file_index[:header_nestings],
          # Issue #1173 — plain `{class name => Array[String]}` data in instance-ancestor search order
          # (prepends first, then nearest-first includes), so the bundle stays Marshal-clean and a warm
          # incremental file orders its mixins the way a cold walk of it does.
          includes: file_index[:includes],
          # Issue #1123 — plain `{class name => Array[String]}` data in instance-ancestor search order, so
          # the bundle stays Marshal-clean and a warm incremental file orders its prepends the way a cold
          # walk of it does.
          prepends: file_index[:prepends],
          # The mixin edges whose order is not a fact — plain `{class name => Array[String]}` data, so the
          # bundle stays Marshal-clean and a warm file flags the edges its cold walk flags.
          unpositioned_mixins: file_index[:unpositioned_mixins],
          method_visibilities: file_index[:method_visibilities],
          methods: file_index[:methods],
          # Issue #992 — plain `{class name => {[kind, name] => [min, max, required_keywords] | :opaque}}`
          # data, so the bundle stays Marshal-clean and a warm file joins the envelopes its cold walk records.
          parameter_envelopes: file_index[:parameter_envelopes],
          class_source_names: file_index[:class_sources].keys,
          singleton_class_source_names: (file_index[:singleton_class_sources] || {}).keys,
          # Issue #722 residue 2 — plain data, so the bundle stays Marshal-clean and a warm incremental file
          # re-anchors its compact headers the way a cold walk of it does.
          compact_headers: file_index[:compact_headers],
          # Issue #644 — the file's publication census (`name => [literal] | :unpublishable`; the path is
          # the bundle key). Plain data, so the bundle stays Marshal-clean.
          constant_writes: file_index[:constant_writes].transform_values { |by_path| by_path.values.first },
          data_member_layouts: file_index[:data_member_layouts],
          struct_member_layouts: file_index[:struct_member_layouts],
          # Issue #1097 — plain `[Integer, Integer, Symbol, Symbol, String]` rows, so the bundle
          # stays Marshal-clean.
          deferred_ranges: file_index[:deferred_ranges],
          # Issue #1120 — plain `{String => {Symbol => Array[String]}}` data (nil when the file refines
          # nothing), so the bundle stays Marshal-clean.
          refinements: file_index[:refinements],
          # Issue #1367 — the file's {GlobalWriteCensus}, a Set of frozen Arrays, which Marshal round-trips.
          global_write_census: file_index[:global_write_census],
          # ADR-119 WD1 — `{sibling name => table}`, plain Hashes, Sets and rows, so the bundle stays Marshal-clean.
          siblings: file_index[:siblings]
        }
      end

      # ADR-85 WD2 — reconstitutes a cached bundle into a single-file index {#fold_file_index} folds: the
      # def-node triples become {DefHandle}s bound to this file's `path`, and the class-source names become a
      # `{name => Set[path]}` table (the shape `accumulate_project_index` produces).
      def bundle_to_file_index(bundle, path) # rubocop:disable Metrics/AbcSize -- one read per bundle slot
        {
          def_nodes: bundle_defs_to_handles(bundle[:def_nodes], path),
          singleton_def_nodes: bundle_defs_to_handles(bundle[:singleton_def_nodes], path),
          def_sources: bundle[:def_sources],
          # ADR-85 schema 7 — a pre-7 bundle lacks this key; the SCHEMA bump loads it as a clean cold rebuild,
          # but default to `{}` so any in-flight fold stays total.
          singleton_def_sources: bundle[:singleton_def_sources] || {},
          superclasses: bundle[:superclasses],
          header_nestings: bundle[:header_nestings] || {},
          includes: bundle[:includes],
          # Issue #1123 — a pre-#1123 bundle lacks the key; the SCHEMA bump loads it as a clean cold
          # rebuild, but default to `{}` so any in-flight fold stays total.
          prepends: bundle[:prepends] || {},
          # #526 — pre-extends bundles lack the key; default `{}` keeps the fold total.
          extends: bundle[:extends] || {},
          # A pre-32 bundle lacks the key; the SCHEMA bump rebuilds it cold, and the fold defaults it anyway.
          unpositioned_mixins: bundle[:unpositioned_mixins],
          method_visibilities: bundle[:method_visibilities],
          methods: bundle[:methods],
          parameter_envelopes: bundle[:parameter_envelopes] || {},
          class_sources: bundle_path_sets(bundle[:class_source_names], path),
          singleton_class_sources: bundle_path_sets(bundle[:singleton_class_source_names], path),
          compact_headers: bundle[:compact_headers] || {},
          # Issue #644 — a pre-#644 bundle carries no census; the SCHEMA bump makes such a blob a cold
          # rebuild, but default so any in-flight fold stays total.
          constant_writes: (bundle[:constant_writes] || {}).transform_values { |descriptor| { path => descriptor } },
          data_member_layouts: bundle[:data_member_layouts],
          struct_member_layouts: bundle[:struct_member_layouts],
          # Issue #1097 — a pre-24 bundle lacks the key; the SCHEMA bump makes such a blob a cold
          # rebuild, but default so any in-flight fold stays total.
          deferred_ranges: bundle[:deferred_ranges] || {},
          # Issue #1120 — absent from a pre-28 bundle, which the SCHEMA bump rebuilds cold.
          refinements: bundle[:refinements],
          # Issue #1367 — absent from a pre-29 bundle, which the SCHEMA bump rebuilds cold.
          global_write_census: bundle[:global_write_census] || GlobalWriteCensus::EMPTY,
          # ADR-119 WD1 — absent from a pre-35 bundle, which the SCHEMA bump rebuilds cold.
          siblings: bundle[:siblings] || Scope::DiscoveryIndex::EMPTY_SIBLINGS
        }
      end

      # `{class => {method => Prism::DefNode}}` → `{class => {method => [node_id, name, fingerprint,
      # nesting]}}`. Issue #707 — `nestings` is this file's identity-keyed `{DefNode => Module.nesting}` table,
      # read here while the live nodes are still in hand, because it is the LAST moment the two can be paired:
      # the bundle's reader has only the row. Issue #716 — `[]` for a top-level def, which records the empty
      # chain; nil only for a def no declaration walk reached.
      def live_defs_to_bundle(defs, nestings)
        defs.transform_values do |methods|
          methods.transform_values do |node|
            [node.node_id, node.name.to_s, Digest::SHA256.hexdigest(node.location.slice), nestings[node]]
          end
        end
      end

      # `{class => {method => [node_id, name, fingerprint, nesting]}}` → `{class => {method => DefHandle}}`
      # for `path`.
      def bundle_defs_to_handles(defs, path)
        defs.transform_values do |methods|
          methods.transform_values do |(node_id, name, fingerprint, nesting)|
            DefHandle.new(path: path, node_id: node_id, name: name, fingerprint: fingerprint, nesting: nesting)
          end
        end
      end

      # The empty per-run accumulator the def-index passes fold each file into.
      def new_def_index_accumulator
        { def_nodes: {}, def_nestings: {}.compare_by_identity,
          singleton_def_nodes: {}, def_sources: {}, singleton_def_sources: {},
          superclasses: {}, header_nestings: {}, includes: {}, prepends: {}, extends: {}, unpositioned_mixins: {},
          method_visibilities: {},
          methods: {},
          deferred_ranges: {},
          parameter_envelopes: {}, class_sources: {}, singleton_class_sources: {},
          # Issue #722 residue 2 — compact-header re-anchor candidates, adjudicated in {#finalize_def_index}.
          compact_headers: {},
          constant_writes: {},
          data_member_layouts: {}, struct_member_layouts: {},
          # Issue #1367 — the project's {GlobalWriteCensus}.
          global_write_census: Set.new,
          # ADR-119 WD1 — the pair siblings, `{sibling name => table}` (see {#fold_siblings}).
          siblings: Scope::DiscoveryIndex::EMPTY_SIBLINGS.dup }
      end

      # Post-processes and freezes a fully-folded def-index accumulator.
      def finalize_def_index(acc)
        # Issue #722 residue 2 — settle the compact-header keys FIRST: every whole-project pass below reads
        # class-keyed tables, and the renames are only knowable now that `class_sources` spans the project.
        renames = compact_header_renames(acc[:compact_headers] || {}, acc[:class_sources].keys.to_set)
        apply_compact_header_renames!(acc, renames) unless renames.empty?
        acc[:compact_header_renames] = renames
        # Issue #644 — resolve the cross-file constant-reassignment rule here, where the whole project's
        # write census is known, and turn the surviving literals into their published `Type::Constant`.
        acc[:constant_values], acc[:constant_sources] = finalize_constant_writes(acc[:constant_writes])
        # ADR-119 WD1 — the two passes below rewrite `def_nodes`, `singleton_def_nodes` and `methods`, and each carries
        # its sibling along. `subtract_def_methods` drops `def`-declared names from `methods`, and
        # {#subtract_sibling_methods!} applies the same drop to `possible_discovered_methods`. The extends fold copies
        # an extended module's instance defs onto the extender's singleton, and follows the siblings the same way (a
        # copy is possible or contested when its edge is listed in `unpositioned_mixins` or its source was).
        fold_project_extends(acc)
        # Cross-file method suppression is for the project's OWN accessors (attr_* / define_method / alias) — NOT for
        # plain `def`s. A cross-file `def` on a class is exactly the ADR-17 monkey-patch case the undefined-method rule
        # deliberately surfaces (fire + def-site annotation, nudging `pre_eval:`), so dropping the `def`-declared names
        # keeps that contract intact while still letting `attr_reader :x` in one file suppress a false undefined-method
        # for `obj.x` in another.
        acc[:methods] = subtract_def_methods(acc[:methods], acc[:def_nodes])
        subtract_sibling_methods!(acc)
        finalize_call_surface_tables(acc)
        %i[def_nodes singleton_def_nodes def_sources singleton_def_sources includes prepends
           method_visibilities methods parameter_envelopes class_sources constant_sources deferred_ranges].each do |key|
          acc[key].each_value(&:freeze)
        end
        acc.transform_values(&:freeze)
      end

      # The project-wide extends fold over the accumulator's tables and siblings.
      def fold_project_extends(acc)
        fold_extends_into_singleton_tables(acc[:extends], acc[:def_nodes], acc[:singleton_def_nodes], acc[:methods],
                                           siblings: acc[:siblings], unpositioned: acc[:unpositioned_mixins])
      end

      # The two whole-project tables only call rules read: the issue #992 envelope table gains its project-wide
      # key, and the issue #1120 refinement table, nil until some file refines something, settles to a frozen one.
      def finalize_call_surface_tables(acc)
        acc[:parameter_envelopes][Scope::DiscoveryIndex::ENVELOPE_PROJECT_WIDE] ||= {}
        acc[:refinements] = freeze_refinements(acc[:refinements])
        acc[:global_write_census] = acc[:global_write_census].freeze
        acc[:unpositioned_mixins].each_value { |sides| sides.each_value(&:freeze).freeze }
        freeze_siblings(acc[:siblings])
      end

      # Removes, per class, the method names that have a project `def` node, leaving only
      # accessor/alias/define_method-introduced methods in the cross-file suppression table.
      #
      # `def_nodes` is the INSTANCE-side table, so a name recorded on both sides keeps its singleton half: that half
      # comes from a `def self.x` / `class << self` definition this rule never covered, and dropping it whole would
      # reintroduce #239's false `call.undefined-method` across files.
      def subtract_def_methods(methods, def_nodes)
        methods.each_with_object({}) do |(class_name, table), out|
          defs = def_nodes[class_name] || {}
          kept = table.each_with_object({}) do |(method_name, kind), acc|
            next acc[method_name] = kind unless defs.key?(method_name)

            acc[method_name] = :singleton if kind == Scope::DiscoveryIndex::METHOD_KIND_BOTH
          end
          out[class_name] = kept unless kept.empty?
        end
      end

      # ADR-119 WD1 — the `possible` copy of `methods` loses the INSTANCE half of a name that has a project `def`
      # (`:instance` goes, `:both` becomes `:singleton`), so `possible_discovered_methods` stays a subset of its
      # member after the rule above. A `:singleton` entry stays: the `def` is the instance side, and the member
      # keeps the name's singleton half. Only that sibling is rewritten.
      def subtract_sibling_methods!(acc)
        possible = acc[:siblings][:possible_discovered_methods]
        return if possible.nil?

        acc[:siblings] =
          acc[:siblings].merge(possible_discovered_methods: subtract_sibling_instance_defs(possible, acc[:def_nodes]))
      end

      def subtract_sibling_instance_defs(possible, def_nodes)
        possible.each_with_object({}) do |(class_name, table), out|
          defs = def_nodes[class_name] || {}
          kept = table.each_with_object({}) do |(method_name, kind), acc|
            next acc[method_name] = kind unless defs.key?(method_name)

            acc[method_name] = :singleton unless kind == :instance
          end
          out[class_name] = kept unless kept.empty?
        end
      end

      # Folds one file's class-keyed indexes into the cross-file accumulator. `method_visibilities` (ADR-35) is
      # collected here so the override-visibility-reduced rule can read an ancestor's visibility declared in a sibling
      # file.
      def accumulate_project_index(acc, path, root, uncertain: false)
        # One combined descent yields both the methods existence table and the def-node table; the latter is also
        # consumed by `record_class_sources`, so a def-dense file is walked once here instead of three times (methods +
        # def-nodes ×2). See {#build_methods_and_def_nodes}.
        file_methods, file_def_nodes, file_envelopes, file_refinements, file_singleton_def_nodes, certainty =
          walk_def_contributions(acc, path, root, uncertain: uncertain)
        merge_discovered_defs(acc[:def_nodes], acc[:def_sources], path, file_def_nodes)
        fold_parameter_envelopes(acc, file_envelopes)
        fold_refinements(acc, file_refinements)
        # Issue #681 — node-identity keyed, so this is a flat union: no two files can contribute the same key.
        walked = SharedWalkTables.declaration_walk_tables(root, path)
        acc[:def_nestings].merge!(walked.fetch(:def_nestings))
        # ADR-46 slice 4 (singleton) — record the singleton-side `"path:line"` sources alongside the nodes,
        # the exact mirror of the instance-side `merge_discovered_defs`, so a class/singleton-method body edit
        # produces a changed `"Class.method"` fingerprint pair (and its call sites a symbol edge) instead of
        # silently degrading to the file's full ancestry closure.
        merge_discovered_defs(acc[:singleton_def_nodes], acc[:singleton_def_sources], path,
                              file_singleton_def_nodes)
        superclasses = walked.fetch(:superclasses)
        acc[:superclasses].merge!(superclasses)
        merge_header_nestings(acc[:header_nestings], walked.fetch(:header_nestings))
        ancestry_keys = fold_file_mixin_tables(acc, root)
        record_file_positions(acc, path, root, superclasses, ancestry_keys, file_def_nodes)
        merge_constant_literal_tables(acc, root, path)
        merge_class_keyed_index_tables(acc, root, file_methods, certainty)
        merge_member_layout_tables(acc, walked)
      end

      # The two def-contribution walks of {#accumulate_project_index}, over ONE {Certainty} classification, with the
      # file's siblings folded into the accumulator BEFORE its members join it (ADR-119 WD3: the `possible` rule
      # reads the accumulator's member as it stood). Returns `[methods, def_nodes, envelopes, refinements,
      # singleton_def_nodes, certainty]`, the classification passed on for the visibility walk.
      def walk_def_contributions(acc, path, root, uncertain: false)
        certainty = uncertain ? Certainty.every_contribution(root) : Certainty.possible_nodes(root)
        file_methods, file_def_nodes, file_envelopes, file_refinements, file_siblings =
          build_methods_and_def_nodes(root, path, certainty: certainty)
        file_singleton_def_nodes, file_singleton_contested = build_singleton_def_tables(root, certainty: certainty)
        fold_file_siblings(acc, file_siblings.merge(contested_discovered_singleton_def_nodes: file_singleton_contested),
                           methods: file_methods, def_nodes: file_def_nodes,
                           singleton_def_nodes: file_singleton_def_nodes)
        [file_methods, file_def_nodes, file_envelopes, file_refinements, file_singleton_def_nodes, certainty]
      end

      # Issue #1123 — this file's three instance- / singleton-side module lists, folded into the
      # accumulator, plus the class keys its ancestry edges are attributed to: a prepend table can name a
      # class this file never DECLARES (`Base.prepend(Loud)` written beside `Base`'s body), and that call IS
      # an ancestry edge of `Base`, so ADR-46 must attribute the class to this file or a reader of `Base`
      # would not depend on the file whose edit moves `Base`'s MRO. The include LISTS themselves are
      # unchanged — only the key set the attribution reads widens. Split out of
      # {#accumulate_project_index} to hold its ABC budget.
      def fold_file_mixin_tables(acc, root)
        mixin = MixinTables.mixin_tables(root)
        extend_side = extend_tables(root)
        accumulate_include_lists(acc[:includes], mixin[:includes])
        accumulate_prepend_lists(acc[:prepends], mixin[:prepends])
        accumulate_extend_lists(acc[:extends], extend_side[:extends])
        accumulate_unpositioned(acc[:unpositioned_mixins], mixin[:unpositioned])
        accumulate_unpositioned(acc[:unpositioned_mixins], extend_side[:unpositioned])
        mixin[:includes].merge(mixin[:prepends]) { |_cn, included_mods, _prepends| included_mods }
      end

      # {Scope::DiscoveryIndex#unpositioned_mixins} folds by union, so the fold is order-independent and a
      # bundle-served file folds exactly as its live walk would.
      def accumulate_unpositioned(target, additions)
        additions.each do |class_name, sides|
          sitting = (target[class_name] ||= {})
          sides.each { |side, names| sitting[side] = sitting.key?(side) ? (sitting[side] | names) : names.dup }
        end
      end

      # Issue #644 — folds one file's publication census into the cross-file accumulator, keyed by
      # (name, path) (kept out of {#accumulate_project_index} to hold its ABC budget). The conflict rule that
      # makes the fold order irrelevant runs at {#finalize_constant_writes}. Issue #1367 — the same walk carries the
      # file's {GlobalWriteCensus}, so the project pre-pass needs no descent of its own for it.
      def merge_constant_literal_tables(acc, root, path)
        census = ConstantTables.constant_write_census(root)
        census.writes.each do |name, descriptor|
          (acc[:constant_writes][name] ||= {})[path] = descriptor
        end
        acc[:global_write_census].merge(attribute_own_writes(census.write_census.census, path))
      end

      # #1154 — tags each `[:own_write, class, ivar]` entry with the file that records it, so a reader of the merged
      # census can tell a second file writing the same ivar of the same class (`UnseenIvarWriters`).
      # Issue #2079 — and each `[:own_write_type, class, ivar, value]` entry, which {IvarContributions} reads.
      def attribute_own_writes(census, path)
        return census unless census.any? { |entry| PATH_TAGGED_KINDS.include?(entry.first) }

        census.to_set { |entry| PATH_TAGGED_KINDS.include?(entry.first) ? [*entry, path].freeze : entry }
      end

      # Folds one file's Data + Struct member-layout tables into the cross-file accumulator (kept out of
      # {#accumulate_project_index} to hold its ABC budget).
      def merge_member_layout_tables(acc, walked)
        acc[:data_member_layouts].merge!(walked.fetch(:data_member_layouts))
        acc[:struct_member_layouts].merge!(walked.fetch(:struct_member_layouts))
      end

      # Folds the per-class method-visibility and method-existence tables of one file into the cross-file accumulator
      # (kept out of {#accumulate_project_index} to hold its ABC budget). `file_methods` is the existence table from the
      # combined methods/def-nodes descent.
      #
      # ADR-119 WD3 — the visibility slots fold later-wins, so their contests follow the file that wrote them
      # ({#fold_slot_contests}), as the def-node slots' do.
      def merge_class_keyed_index_tables(acc, root, file_methods, certainty)
        file_visibilities, file_contested = build_method_visibility_tables(root, certainty: certainty)
        siblings = acc[:siblings]
        siblings[:contested_discovered_method_visibilities] = fold_visibility_contests(
          siblings[:contested_discovered_method_visibilities], acc[:method_visibilities], file_visibilities,
          file_contested
        )
        file_visibilities.each do |class_name, table|
          (acc[:method_visibilities][class_name] ||= {}).merge!(table)
        end
        file_methods.each do |class_name, table|
          acc[:methods][class_name] = merge_method_kinds(acc[:methods][class_name] || {}, table)
        end
      end

      # ADR-46 slice 1 — accumulates, per qualified user class/module name, the set of files that declare it. A class's
      # declaration shape (its body `def`s, its `class Foo < Bar` superclass, its `include`s) lives wherever the class
      # is opened, so every file that contributes a def / superclass / include for a name is a source of that name's
      # ancestry edges. {Scope#superclass_of} / {Scope#includes_of} record this set when resolving the edge during
      # dependency recording (ADR-46). The class-declaration walk ({ClassDeclarations.collect_class_decls}) catches
      # bodyless / def-less reopenings the other three builders miss.
      def record_class_sources(class_sources, path, root, superclasses, includes, file_def_nodes, compacts = nil)
        names = Set.new
        ClassDeclarations.collect_class_decls(root, [], decls = {}, compacts)
        names.merge(decls.keys)
        names.merge(superclasses.keys)
        names.merge(includes.keys)
        names.merge(file_def_nodes.keys)
        names.each { |name| (class_sources[name] ||= Set.new) << path }
      end

      # The last segment a wildcard census key stands for, or nil for an ordinary qualified name.
      def dynamic_target_segment(name)
        name.delete_prefix(DYNAMIC_TARGET_PREFIX) if name.start_with?(DYNAMIC_TARGET_PREFIX)
      end

      # Issue #644 — materialises the published table and the write attribution from the folded census.
      #
      # A name publishes only when exactly ONE file writes it and that write is a literal. Two files writing
      # the same qualified name is a cross-file reassignment whose winner is load order, so the name stays
      # `Dynamic[top]` — the type it already had, and the widest there is. The rule runs at finalize (not at
      # fold time) so the fold stays order-independent, which is what lets the ADR-85 incremental path re-fold
      # a changed file's contribution in place.
      #
      # A {DYNAMIC_TARGET_PREFIX} key is not a name and never publishes; it is expanded by
      # {#apply_dynamic_target_writes} into a retraction over the names it could have written.
      #
      # @return the value table and the table of source paths per name.
      def finalize_constant_writes(writes)
        values = {}
        sources = {}
        dynamic = {}
        writes.each do |name, by_path|
          segment = dynamic_target_segment(name)
          next dynamic[segment] = by_path.keys.to_set if segment

          sources[name] = by_path.keys.to_set
          next unless by_path.size == 1

          descriptor = by_path.values.first
          values[name] = Type::Combinator.constant_of(descriptor.first) if descriptor.is_a?(Array)
        end
        apply_dynamic_target_writes(values, sources, dynamic)
        [values, sources]
      end

      # Issue #668 — expands each wildcard census key. `k::LIMIT = 7` can create `Anything::LIMIT`, so it
      # retracts every censused name whose last segment is `LIMIT` and joins the writing file to that name's
      # attribution; the bare `LIMIT` is retracted along with the rest, being the one name the analyzer
      # cannot rule out either (`k` may be `Object`). Over-retracting makes readers gradual, which is the
      # direction the census's whole decline list takes; leaving a name published that a dynamic write may
      # already have replaced is the single failure the census exists to prevent.
      #
      # The wildcard key survives into the attribution so a producer with no censused name of its own — a
      # `pre_eval:` publication for a file outside `paths:` — can still see the conflict
      # ({Analysis::Runner::ScopeSeed.merged_seed_constants}).
      def apply_dynamic_target_writes(values, sources, dynamic)
        return if dynamic.empty?

        sources.each do |name, paths|
          writers = dynamic[name.split("::").last]
          next if writers.nil?

          paths.merge(writers)
          values.delete(name)
        end
        dynamic.each { |segment, paths| sources[ConstantTables.dynamic_target_key(segment)] = paths }
      end

      # Merges one file's `class → method → DefNode` map into the cross-file `def_nodes` index and records each method's
      # first- seen `"path:line"` definition site in `def_sources` (ADR-17 — the un-registered-project-patch signal
      # `call.undefined-method` and `rigor triage` key on).
      def merge_discovered_defs(def_nodes, def_sources, path, file_def_nodes)
        file_def_nodes.each do |class_name, methods|
          (def_nodes[class_name] ||= {}).merge!(methods)
          sources = (def_sources[class_name] ||= {})
          methods.each do |method_name, def_node|
            sources[method_name] ||= "#{path}:#{def_node.location&.start_line || 1}"
          end
        end
      end

      # Issue #722 residue 2 — the whole-project adjudication of {ClassDeclarations}' compact-header candidates:
      # `{name the walk recorded => name Ruby actually reopens}`.
      #
      # A candidate moves only when the project ANSWERS BOTH halves of Ruby's lookup: the namespace the
      # nesting would supply (`Wrap::Outer`) is declared nowhere, and the top level the segment falls through
      # to (`Outer`) IS declared. The second half is the false-positive bound, not a convenience — a
      # `Wrap::Outer` that merely never appears in project source (a gem, an RBS-only class) is a namespace
      # that DOES exist at runtime, and re-anchoring on its absence would answer with a wrong class where
      # today's mis-keying only answers with silence.
      #
      # `declared_names` is the RAW declared set (`class_sources`), never the table
      # {#synthesize_namespace_prefixes} has run over: that synthesis invents `Wrap::Outer` from
      # `Wrap::Outer::Leaf` itself, so consulting it would make every candidate look already-resolved.
      def compact_header_renames(compacts, declared_names)
        compacts.each_with_object({}) do |(recorded, (required_namespace, reanchored)), out|
          next if declared_names.include?(required_namespace)
          next unless declared_names.include?(reanchored.split("::").first)

          out[recorded] = reanchored
        end
      end

      # Rewrites `name` when it is, or is nested under, a re-anchored compact header. Nested declarations
      # ride the same move: `class Outer::Leaf` inside `module Wrap` carrying a `class Inner` filed the inner
      # class under `Wrap::Outer::Leaf::Inner`, and it reopens `::Outer::Leaf::Inner` for the same reason.
      def rename_compact_name(renames, name)
        return name if renames.empty?

        string = name.to_s
        renamed = renames[string]
        return renamed if renamed

        renames.each do |recorded, reanchored|
          return "#{reanchored}#{string[recorded.length..]}" if string.start_with?("#{recorded}::")
        end
        string
      end

      # Re-keys one class-keyed table. A rename lands a declaration on a key the table may ALREADY hold —
      # which is the whole point: `class Outer::Leaf` written twice, once at the top level and once inside
      # `module Wrap`, is one class with both bodies. So the arriving contribution is COMBINED with the
      # sitting one under the table's own fold semantics rather than replacing it; a plain `transform_keys`
      # dropped the top-level body's methods outright.
      def rekey_class_table(table, renames)
        table.each_with_object({}) do |(name, value), out|
          renamed = rename_compact_name(renames, name)
          sitting = out[renamed]
          out[renamed] = sitting.nil? ? value : combine_rekeyed_entries(sitting, value)
        end
      end

      # {#rekey_class_table} for `unpositioned_mixins`: two bodies landing on one key keep BOTH sides' names,
      # where the Hash arm of {#combine_rekeyed_entries} would replace one side's list with the other's.
      def rekey_unpositioned(table, renames)
        table.each_with_object({}) do |(name, sides), out|
          out.merge!(rename_compact_name(renames, name) => sides) do |_key, sitting, arriving|
            sitting.merge(arriving) { |_side, a, b| a | b }
          end
        end
      end

      def rekey_parameter_envelopes(table, renames)
        table.each_with_object({}) do |(name, entries), out|
          out.merge!(rename_compact_name(renames, name) => entries) do |_key, sitting, arriving|
            sitting.merge(arriving) { |_entry, a, b| Source::ParameterEnvelope.merge(a, b) }
          end
        end
      end

      # Issue #986 — `header_nestings` is re-keyed here rather than through {#rekey_class_table} for two
      # reasons, and both have to happen in this one pass.
      #
      # Its value is a BUCKET (`raw ancestor name → chain`, plus the unkeyed union), not a chain: mapping
      # the bucket itself turned every entry into a `[raw, chain]` pair rendered as a string, and the next
      # per-file merge ({#merge_header_nesting_bucket}) and every `Scope#recorded_header_nesting` lookup
      # then raised on an Array where a Hash was expected — an internal analyzer error on every file of a
      # project with one compact header (#984).
      #
      # And when a rename lands two buckets on ONE key — `class Outer::Leaf` written at the top level and
      # again as a compact header inside `module Wrap`, which is one class with both bodies — the colliding
      # chains MUST go through the table's own fold. {#combine_rekeyed_entries}' Hash arm replaced the
      # sitting chain for a raw name BOTH sites wrote (each site's `include Mixin` records under the raw key
      # `"Mixin"`), so which cref the ancestor name was resolved in depended on which file folded first:
      # top-then-compact answered `Wrap::Mixin`, compact-then-top answered `::Mixin`. Unioning is the answer
      # `merge_header_nestings` already gives two same-name sites of a class that needed no rename, and the
      # one the internal spec states.
      #
      # Entries are renamed BEFORE the merge so the union's most-qualified-first sort ranks settled names.
      def rekey_header_nestings(table, renames)
        table.each_with_object({}) do |(name, bucket), out|
          renamed = bucket.transform_values do |chain|
            chain.map { |entry| rename_compact_name(renames, entry) }
          end
          merge_renamed_header_bucket(out, rename_compact_name(renames, name), renamed)
        end
      end

      # {#merge_header_nesting_bucket} for the rename collision. The UNKEYED entry is the per-class union by
      # definition — the pre-#728 answer for a name no site recorded — so it keeps unioning. A KEYED entry is
      # the cref of the site that wrote that exact name, and the two sides are two different sites, so
      # unioning their chains would hand each site's ancestor the other's namespace: `Wrap::Mixin` sorts
      # ahead of `::Mixin`, and the ancestor-name resolution takes the first known class as the sole
      # resolution, so the top-level site's `include Mixin` silently became the `Wrap` one. That is not just
      # a wrong class, it is a FALSE POSITIVE source — the two modules' same-named methods can differ in
      # arity, and `call.wrong-arity` then fires on a correct program.
      #
      # So the two chains are kept side by side as ALTERNATIVES and the choice is deferred to `Scope`, which
      # knows which names the project declares: it resolves each alternative and declines only when they
      # name two DIFFERENT project classes. A collision whose alternatives agree, or where only one of them
      # resolves at all, is unchanged.
      def merge_renamed_header_bucket(table, name, incoming)
        existing = table[name]
        return table[name] = frozen_bucket(incoming) if existing.nil?

        merged = existing.dup
        incoming.each do |raw, entries|
          previous = merged[raw]
          merged[raw] =
            if previous.nil? then entries.freeze
            elsif raw == Scope::DiscoveryIndex::UNKEYED_HEADER_NESTING then union_header_nesting(previous, entries)
            else collide_header_nesting(previous, entries)
            end
        end
        table[name] = merged.freeze
      end

      # One keyed entry's side-by-side combine. Two sites that recorded the SAME chain collapse back to that
      # chain, so the alternatives shape appears only where the crefs really disagree.
      def collide_header_nesting(previous, entries)
        alternatives = header_nesting_alternatives(previous) | header_nesting_alternatives(entries)
        return alternatives.first.freeze if alternatives.one?

        alternatives.each(&:freeze).freeze
      end

      # Issue #986 — the re-anchored bucket, also filed under the name the declaration was written with.
      #
      # A body written INSIDE the compact header does not see the rename: its `self_type` is the per-node
      # `Singleton[Wrap::Outer::Leaf]` (§531 keeps `declaration_prefix` per-node on purpose), and the
      # per-file ancestry tables `merge_ancestry_tables` lays over the seed are keyed the same way, with
      # this site's chain alone. So `include Mixin` resolved to `Wrap::Mixin` outright for every call in
      # that body — the collision's false positive, inside the declaration that causes it.
      #
      # The alias hands the un-renamed key the SAME bucket the re-anchored one got, which is the honest
      # answer: they are one class, and the file's own chain then merges into the alternatives rather than
      # standing alone. It is added only for a name the rename pass moved, and only to this table, so no
      # name gains a declaration it did not have.
      def alias_renamed_header_nestings(table, renames)
        renames.each do |recorded, reanchored|
          bucket = table[reanchored]
          table[recorded] = bucket if bucket && !table.key?(recorded)
        end
        table
      end

      def header_nesting_alternatives(entries)
        ambiguous_header_nesting?(entries) ? entries : [entries]
      end

      def ambiguous_header_nesting?(entries)
        Scope::DiscoveryIndex.ambiguous_header_nesting?(entries)
      end

      # The per-shape combine {#rekey_class_table} applies. Every class-keyed table's value is a Hash of
      # per-member entries keyed by `"path:line"` or by member name, a Set or Array of names, or a single
      # scalar fact (a superclass name, a member layout). The Set / Array arm unions; the Hash arm is
      # later-wins per key, which is what the two contributions of one class want when their keys are
      # distinct sites and is harmless when a key repeats with an equal value; a scalar keeps the entry
      # already sitting, matching the first-wins fold `class_sources` uses.
      #
      # A value whose per-key entries must FOLD rather than be replaced does not belong here: see
      # {#rekey_parameter_envelopes} (#992) and {#rekey_header_nestings} (#986).
      def combine_rekeyed_entries(sitting, arriving)
        case sitting
        when Hash then sitting.merge(arriving)
        when Set, Array then sitting | arriving
        else sitting
        end
      end

      # Applies {#compact_header_renames} to every class-keyed table of a folded def-index accumulator, plus
      # the nesting chains whose entries are class names. Runs before {#finalize_def_index}'s own whole-project
      # passes so those see the settled keys.
      def apply_compact_header_renames!(acc, renames)
        %i[def_nodes singleton_def_nodes def_sources singleton_def_sources superclasses
           includes prepends extends method_visibilities methods class_sources data_member_layouts
           struct_member_layouts constant_writes].each do |key|
          acc[key] = rekey_class_table(acc[key], renames)
        end
        acc[:unpositioned_mixins] = rekey_unpositioned(acc[:unpositioned_mixins], renames)
        acc[:siblings] = rename_siblings(acc[:siblings], renames)
        # Issue #992 — the envelope table cannot take {#combine_rekeyed_entries}' later-wins Hash merge: two
        # bodies of one class landing on the same key are exactly the reopening whose disagreement must
        # make a name opaque.
        acc[:parameter_envelopes] = rekey_parameter_envelopes(acc[:parameter_envelopes], renames)
        renamed_nestings = rekey_header_nestings(acc[:header_nestings], renames)
        acc[:header_nestings] = alias_renamed_header_nestings(renamed_nestings, renames)
        acc[:def_nestings].transform_values! do |chain|
          chain&.map { |entry| rename_compact_name(renames, entry) }
        end
      end

      # Issue #528 — every proper prefix of a discovered COMPACT class name is a namespace module that
      # provably exists at runtime, even when no `module X` declaration is anywhere in the source
      # (Zeitwerk derives it from the directory: mastodon writes `class Api::V1::AccountsController`
      # and never `module Api`). Registering the prefixes lets a bare `Api` read — and the inner
      # ConstantReadNodes of every resolving constant path — type as the namespace singleton instead of
      # falling to the unresolved fallback (~500 sites on mastodon). An explicitly-declared name always
      # wins: prefixes never overwrite an existing entry.
      def synthesize_namespace_prefixes(discovered)
        additions = {}
        discovered.each_key do |full|
          next unless full.include?("::")

          segments = full.split("::")
          (1...segments.size).each do |keep|
            prefix = segments.first(keep).join("::")
            next if discovered.key?(prefix) || additions.key?(prefix)

            additions[prefix] = Type::Combinator.singleton_of(prefix)
          end
        end
        return discovered if additions.empty?

        discovered.merge(additions)
      end

      # The per-node propagation lives in {NodePropagation}; these three delegate to it. {#index} calls {#propagate} and
      # {#with_unentered_evaluator}; {StatementEvaluator} calls {#refined_class_name}.
      def propagate(node, table, parent_scope) = NodePropagation.propagate(node, table, parent_scope)

      def with_unentered_evaluator(evaluate, &) = NodePropagation.with_unentered_evaluator(evaluate, &)

      def refined_class_name(target, scope) = NodePropagation.refined_class_name(target, scope)

      # Read by {NodePropagation}, lexically. This one stayed because {#each_singleton_body_prepend} uses it too; the
      # next two stayed so that the node-class lists do not make the moved module a declaration producer.
      CODE_BODY_NODES = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze
      private_constant :CODE_BODY_NODES

      SELF_OPENING_BODIES = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze
      private_constant :SELF_OPENING_BODIES

      CLASS_BODY_DEF_BARRIERS = [
        Prism::BlockNode, Prism::LambdaNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode
      ].freeze
      private_constant :CLASS_BODY_DEF_BARRIERS
    end
  end
end

# Last, so that the typing-state slot it declares keeps its place after the ones the module body above declares.
require_relative "scope_indexer/node_propagation"
