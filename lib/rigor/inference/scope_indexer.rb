# frozen_string_literal: true

require "prism"

require_relative "../scope"
require_relative "../type"
require_relative "../source/constant_path"
require_relative "../source/node_children"
require_relative "../source/node_walker"
require_relative "../source/parameter_envelope"
require_relative "../cache/file_digest"
require_relative "../analysis/check_rules/published_constant_guard"
require_relative "anonymous_meta_class"
require_relative "def_handle"
require_relative "fresh_frame_blocks"
require_relative "hash_lookup_mutation"
require_relative "index_write_widening"
require_relative "multi_target_binder"
require_relative "mutation_widening"
require_relative "narrowing"
require_relative "statement_evaluator"
require_relative "struct_fold_safety"
require_relative "unknown_store_widening"

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
    # fact) yield the `default_scope`. The returned Hash is mutable in principle but callers MUST treat it as read-only;
    # the indexer itself never exposes a way to update it past construction.
    # rubocop:disable-next Metrics/ModuleLength
    module ScopeIndexer
      # Issue #644 — the census descriptor for a constant write that publishes no value: an unfoldable or
      # non-literal rvalue, an operator / multi-assign / dynamic-path form, or a name this file writes twice.
      # A Symbol, so it is distinguishable from a `[literal]` descriptor by class alone and rides the ADR-85
      # seed bundle through `Marshal` unchanged.
      CONSTANT_UNPUBLISHABLE = :unpublishable

      # Issue #617 — the descriptor for a name a file writes ONLY through `||=`. It publishes nothing either,
      # and it is the memoization idiom rather than a binding while no other file memoizes the name: a
      # constant compound write keeps its memo reading beside it ({Scope#bound_constant_names}), where every
      # other form makes that write read the constant as bound. A second write of any other form in the same
      # file retracts it to {CONSTANT_UNPUBLISHABLE}.
      CONSTANT_MEMO = :memo

      # Issue #668 — the census key a constant write through a base no name reaches is filed under:
      # `*::LIMIT` for `k::LIMIT = 7`. `*` is not a constant character, so the key can never collide with a
      # name a program writes, while its LAST SEGMENT is the real one — which is what the ADR-46 `constant:`
      # edge and {Analysis::Incremental.changed_constant_publications} key on, so both keep working unchanged.
      DYNAMIC_TARGET_PREFIX = "*::"

      module_function

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
      # @return identity-comparing
      #   table whose default value is `default_scope`.
      # The no-op re-anchoring table (#722 residue 2): shared so the overwhelmingly common
      # nothing-to-re-anchor walk allocates none.
      EMPTY_RENAMES = {}.freeze

      def index(root, default_scope:, converged_loop_recording: false) # rubocop:disable Metrics/AbcSize
        # Slice A-declarations. Build the declaration overrides first so every scope handed to the StatementEvaluator
        # already carries the table; structural sharing through `Scope#with_local` / `#with_fact` / `#with_self_type`
        # propagates it across every derived scope.
        # Issue #722 residue 2 — the project's settled declaration names are the oracle the file's own
        # compact headers are re-anchored against. `discovered_class_sources` would be the more direct
        # reading, but it is seeded only under `--record-dependencies`; this table is the one every run
        # carries, and the fold has already applied its own re-anchoring to it.
        declared_types, discovered_classes =
          build_declaration_artifacts(root, default_scope.discovered_classes.keys.to_set)
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
        class_ivars = build_class_ivar_index(root, seeded_scope)
        seeded_scope = seeded_scope.with_discovery(seeded_scope.discovery.with(class_ivars: class_ivars))

        # Slice 7 phase 6. Same pre-pass shape for cvars (per class) and globals (program-wide). Globals are also
        # materialised into the top-level scope's `globals` map so reads at the top level (and in CLI probes that do not
        # enter a method body) observe the precise type without consulting the accumulator on every lookup.
        # Issue #540 — a literal-shape carrier assigned to a constant or class variable is only as good as
        # the file's OWN mutations of it: `ISPELL_STATUS = {}` with a sibling method writing
        # `ISPELL_STATUS[:key] = param` must not fold reads through the closed empty shape. One census walk
        # collects the mutated names; the two accumulators below widen their entries to the Dynamic-wrapped
        # form, contents unpinned ({#census_mutated_type}), so reads stay honest without licensing the negative rules.
        literal_mutations = collect_literal_receiver_mutations(root)

        class_cvars = widen_mutated_cvars(build_class_cvar_index(root, seeded_scope), literal_mutations[:cvars])
        seeded_scope = seeded_scope.with_discovery(seeded_scope.discovery.with(class_cvars: class_cvars))
        program_globals = build_program_global_index(root, seeded_scope)
        seeded_scope = seeded_scope.with_discovery(seeded_scope.discovery.with(program_globals: program_globals))
        program_globals.each { |name, type| seeded_scope = seeded_scope.with_global(name, type) }

        # Slice 7 phase 9. In-source constant value tracking. Walks every ConstantWriteNode/ConstantPathWriteNode in the
        # program and types its rvalue under a scope that carries the surrounding qualified prefix as `self_type`, so
        # the rvalue typer sees in-class references resolve correctly. Multiple writes to the same qualified name union
        # via `Type::Combinator.union`.
        # Issue #352 — the per-file table merges OVER whatever the base scope already published (the
        # `pre_eval:` constant seed `Runner#project_scope_seed_tables` applies). Same-file declarations are the
        # most specific authority, exactly as `merged_classes` above resolves the same collision. Without the
        # merge, the assignment below would silently drop the project seed on every file.
        in_source_constants = widen_mutated_constants(
          build_in_source_constants(root, seeded_scope), literal_mutations[:constants]
        )
        seeded_scope = seed_constant_tables(seeded_scope, default_scope, in_source_constants, root)
        seeded_scope = seed_published_constant_ivars(seeded_scope, root)

        # Slice 7 phase 12. In-source method discovery. Walks every class/module body for `Prism::DefNode` and
        # recognised `define_method` calls and records the introduced method names. `rigor check` consults the table to
        # suppress false positives for methods the user has defined but no RBS sig describes. Merged UNDER the
        # cross-file pre-pass seed; details: merge_project_method_indexes. One combined descent yields both the
        # discovered-methods existence table and the instance def-node table — see {#build_methods_and_def_nodes}.
        # `seed_discovered_methods` seeds the former onto the scope and returns the def-node table for
        # `merge_project_method_indexes` below.
        seeded_scope, file_def_nodes, file_envelopes = seed_discovered_methods(seeded_scope, default_scope, root)

        # v0.0.2 #5 + ADR-24 slice 2 — record per-instance-method def nodes, the class -> superclass map, and the
        # class/module -> included-modules map, each merged under the cross-file pre-pass seed (see below). v0.1.2 —
        # per-class table of method visibilities (`:public` / `:private` / `:protected`). The
        # `def.method-visibility-mismatch` and ADR-35 `def.override-visibility-reduced` CheckRules consult the table.
        # Seeded inside `merge_project_method_indexes` so the per-file visibilities merge OVER the cross-file project
        # seed rather than overwriting it.
        seeded_scope = merge_project_method_indexes(seeded_scope, default_scope, root, file_def_nodes, file_envelopes)

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

        on_enter = ->(node, scope) { table[node] = scope }
        StatementEvaluator.new(scope: seeded_scope, on_enter: on_enter,
                               converged_loop_recording: converged_loop_recording).evaluate(root)

        propagate(root, table, seeded_scope)
        table
      end

      # Runs the combined methods/def-nodes descent (one walk of the file), seeds the discovered-methods existence table
      # onto `seeded_scope` (merged UNDER the cross-file pre-pass seed `default_scope` carries), and returns `[scope,
      # file_def_nodes, file_envelopes]` so the caller can thread the def-node and issue #992 envelope tables into
      # {#merge_project_method_indexes} without walking the file a second time.
      def seed_discovered_methods(seeded_scope, default_scope, root)
        file_methods, file_def_nodes, file_envelopes = build_methods_and_def_nodes(root, default_scope.source_path)
        discovered_methods = deep_merge_class_methods(default_scope.discovered_methods, file_methods)
        scope = seeded_scope.with_discovery(seeded_scope.discovery.with(discovered_methods: discovered_methods))
        [scope, file_def_nodes, file_envelopes]
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
      def merge_project_method_indexes(seeded_scope, default_scope, root, file_def_nodes, file_envelopes)
        def_nodes, def_nestings = merge_def_node_tables(default_scope, root, file_def_nodes)
        singleton_def_nodes = merge_singleton_def_nodes(default_scope, root)
        superclasses, header_nestings = merge_ancestry_tables(default_scope, root)
        includes, prepends = merge_mixin_tables(default_scope, root)
        # ADR-35 — per-file visibilities merged OVER the cross-file seed (the current file is authoritative for its own
        # classes; sibling-file ancestors are preserved from the project seed).
        method_visibilities = default_scope.discovered_method_visibilities.merge(
          build_discovered_method_visibilities(root)
        ) { |_class, cross_file, per_file| cross_file.merge(per_file) }
        # ADR-48 — per-file Data + Struct member layouts merged OVER the cross-file seed (same-file declaration is
        # authoritative).
        data_member_layouts, struct_member_layouts = merge_member_layouts(default_scope, root)

        # #526 — this file's extends folded against the MERGED instance def-nodes (so `extend M` sees a
        # sibling-file M through the cross-file seed). The project-wide fold in {#finalize_def_index}
        # covers cross-file CONSUMERS; this covers the file that declares the extend.
        #
        # Issue #898 — and the same walk's table is now kept, merged over the cross-file seed the way
        # `includes` is: `Narrowing` asks it what a class object's singleton ancestry holds.
        extends, methods_table = merge_and_fold_extends(default_scope, root, def_nodes,
                                                        singleton_def_nodes, seeded_scope)

        seeded_scope.with_discovery(
          seeded_scope.discovery.with(
            discovered_methods: methods_table,
            discovered_def_nodes: def_nodes,
            discovered_def_nestings: def_nestings,
            discovered_singleton_def_nodes: singleton_def_nodes,
            discovered_superclasses: superclasses,
            discovered_header_nestings: header_nestings,
            discovered_includes: includes,
            discovered_prepends: prepends,
            discovered_extends: extends,
            discovered_method_visibilities: method_visibilities,
            discovered_parameter_envelopes: merge_envelope_seed(default_scope, file_envelopes),
            data_member_layouts: data_member_layouts,
            struct_member_layouts: struct_member_layouts,
            discovered_deferred_ranges: merge_deferred_ranges_seed(default_scope, root)
          )
        )
      end

      # Per-file singleton def nodes merged OVER the cross-file seed (same-file declaration is
      # authoritative for its own classes, sibling-file defs are preserved).
      def merge_singleton_def_nodes(default_scope, root)
        default_scope.discovered_singleton_def_nodes.merge(
          build_discovered_singleton_def_nodes(root)
        ) { |_class, cross_file, per_file| cross_file.merge(per_file) }
      end

      # Issue #1123 — the two instance-side mixin tables, from ONE descent of this file. Each merges over
      # the cross-file seed per class, with the file under analysis as the later-loading contribution for a
      # reopened class: its `prepend`s and — since #1173, when the include table switched to the same
      # instance-ancestor search order — its `include`s are therefore NEARER than the seed's (the
      # {#accumulate_extend_lists} convention, which exists for the same ordering reason).
      def merge_mixin_tables(default_scope, root)
        file = mixin_tables(root)
        [
          default_scope.discovered_includes.merge(file[:includes]) do |_class, cross_file, per_file|
            (per_file + cross_file).uniq
          end,
          default_scope.discovered_prepends.merge(file[:prepends]) do |_class, cross_file, per_file|
            (per_file + cross_file).uniq
          end
        ]
      end

      # The `extend`-edge half of {#merge_project_method_indexes}: merges this file's `extend`s over the
      # cross-file seed AND folds them against the merged def tables — the #526 fold that turns an
      # extended module's instance defs into singleton-side method entries on the extending class.
      def merge_and_fold_extends(default_scope, root, def_nodes, singleton_def_nodes, seeded_scope)
        file_extends, extends = merge_extend_tables(default_scope, root)
        methods_table = fold_per_file_extends(file_extends, def_nodes, singleton_def_nodes, seeded_scope)
        [extends, methods_table]
      end

      # Issue #1097 — this file's def / block / lambda ranges merged over the cross-file seed; the
      # ordering predicates key the table by `source_path`, so the entry must exist even on a run
      # that never built the project pre-pass. When the pre-pass DID run the entry is already the
      # identical walk product — keep it instead of re-walking the AST.
      def merge_deferred_ranges_seed(default_scope, root)
        seeded = default_scope.discovered_deferred_ranges
        return seeded if seeded.key?(default_scope.source_path)

        seeded.merge(default_scope.source_path => build_deferred_ranges(root))
      end

      def merge_envelope_seed(default_scope, file_envelopes)
        Source::ParameterEnvelope.merge_tables(default_scope.discovered_parameter_envelopes, file_envelopes)
      end

      # The as-written superclass table and its issue #682 header-nesting twin, each merged over the cross-file
      # seed. Returned as a pair for the same reason {#merge_def_node_tables} is: both come from ONE walk of the
      # file, so a caller cannot pair a superclass name with a nesting recorded by a different parse.
      def merge_ancestry_tables(default_scope, root)
        file_superclasses, file_header_nestings = build_superclass_tables(root, default_scope.source_path)
        [default_scope.discovered_superclasses.merge(file_superclasses),
         merge_header_nestings(default_scope.discovery.discovered_header_nestings.dup,
                               file_header_nestings).freeze]
      end

      # The instance-side def-node table and its issue #681 nesting twin, each merged over the cross-file seed.
      # Returned as a pair so the two stay written together: a node the merge keeps must be the same object the
      # nesting table keys, and they are only that if both halves take the same file's walk.
      def merge_def_node_tables(default_scope, root, file_def_nodes)
        def_nodes = default_scope.discovered_def_nodes.merge(
          file_def_nodes
        ) { |_class, cross_file, per_file| cross_file.merge(per_file) }
        [def_nodes,
         merge_def_nestings(default_scope.discovery.discovered_def_nestings, build_def_nestings(root))]
      end

      # Issue #681 — the per-file nesting table over the cross-file seed. Both are keyed by node identity, so
      # a same-file declaration and its cross-file twin are distinct keys and the merge order is immaterial;
      # the copy exists only so the seed stays frozen. Skipped when the file declares no `def` at all — since
      # issue #716 a top-level `def` records its empty chain, so a file of plain top-level helpers no longer
      # takes that path and pays one copy of the seed, the same as any file that declares a method.
      def merge_def_nestings(seed, file_nestings)
        return seed if file_nestings.empty?
        return file_nestings if seed.empty?

        merged = {}.compare_by_identity
        merged.merge!(seed)
        merged.merge!(file_nestings)
        merged.freeze
      end

      # Issue #898 — one walk, two consumers: the raw per-file table the #526 method fold reads, and the
      # same table merged over the cross-file seed for the scope. Returned as a pair so a caller cannot
      # pair the fold with a table a different parse produced, as {#merge_ancestry_tables} is.
      def merge_extend_tables(default_scope, root)
        file_extends = build_discovered_extends(root)
        # The table stores singleton-ancestor search order, so the file under analysis — the
        # later-loading contribution for a reopened class — prepends over the cross-file seed.
        merged = default_scope.discovered_extends.merge(
          file_extends
        ) { |_class, cross_file, per_file| (per_file + cross_file).uniq }
        [file_extends, merged]
      end

      # The per-file half of the #526 fold: mutable copies of the merged tables take the extends, and the
      # existence table (already seeded onto the scope) is rebuilt only when the fold touched it.
      def fold_per_file_extends(extends, def_nodes, singleton_def_nodes, seeded_scope)
        methods_table = seeded_scope.discovered_methods
        return methods_table if extends.empty?

        mutable_methods = methods_table.transform_values(&:dup)
        fold_extends_into_singleton_tables(extends, def_nodes, singleton_def_nodes, mutable_methods)
        mutable_methods
      end

      # ADR-48 — the per-file Data + Struct member-layout tables, each merged OVER the cross-file seed so a same-file
      # declaration wins for its own classes. Returned as a pair to keep {#merge_project_method_indexes} under the
      # method-size budget.
      def merge_member_layouts(default_scope, root)
        [
          default_scope.data_member_layouts.merge(build_data_member_layouts(root)),
          default_scope.struct_member_layouts.merge(build_struct_member_layouts(root))
        ]
      end

      # Slice 7 phase 2. Builds the class-level ivar accumulator by walking every `Prism::ClassNode` /
      # `Prism::ModuleNode` body, descending into each nested `Prism::DefNode`, and typing every
      # `Prism::InstanceVariableWriteNode` rvalue under a scope that carries the appropriate `self_type` for that def
      # (singleton vs instance). The rvalue is typed with NO local bindings — the pre-pass lacks statement-level
      # threading — so `@x = 1` records `Constant[1]` but `@x = some_local + 1` records `Dynamic[Top]` (since
      # `some_local` is unbound at pre-pass time). Multiple writes to the same ivar union via `Type::Combinator.union`.
      def build_class_ivar_index(root, default_scope)
        accumulator = {}
        mutated_ivars = {}
        read_before_write = {}
        init_writes = {}
        # WD3 — per-class summary of `{class_name => {method_name => Set<ivar names definitely assigned non-nil on every
        # completing path>}}`, consulted by `dead_transient_nil_writes` so a ctor that reassigns `@x` indirectly through
        # an unconditional same-class method call (`mask!`) credits the overwrite. Built once per program here, memoised
        # by class.
        method_assign_effects = build_method_assign_effects(root)
        walk_class_ivars(root, [], default_scope, accumulator, mutated_ivars,
                         read_before_write, init_writes, method_assign_effects)
        merge_held_ivar_writes!(accumulator)
        record_aliased_ivar_mutations!(root, mutated_ivars)
        widen_mutated_ivar_entries!(accumulator, mutated_ivars)
        contribute_read_before_write_nil!(accumulator, read_before_write, init_writes)
        accumulator.transform_values(&:freeze).freeze
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

      # `{class_name => {method_name => Set<ivar name>}}` for methods that hand an ivar back, dropping the empty sets
      # so the caller's `next if per_class.nil?` skips a whole class in one lookup.
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
      # `Nominal[Array]` at the entry of every OTHER method body in the class — closing the cross-method gap noted in
      # ROADMAP § Future cycles / Type-language / engine ("Tuple / HashShape widening for ivar-seeded literals after
      # mutation"; Redmine 6.1.2 `Redmine::Views::Builders::Structure` is the canonical worked site).
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
        when Type::Constant
          # `@s = +"ab"` in one method and `@s << "c"` in another: without this arm the seed stayed pinned at every
          # other method's entry, and `@s == "ab"` folded always-truthy on a receiver that holds `"abc"`.
          return member unless StringMutation.constant?(member) &&
                               observed_methods.any? { |m| StringMutation::MUTATORS.include?(m) }

          Type::Combinator.nominal_of("String")
        else
          member
        end
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

      # The chain a census walk answers `Module.nesting` with: the one {#scope_entering_declaration} threaded
      # on the scope when a header was entered, and only failing that the prefix-derived approximation below.
      def census_nesting(scope, qualified_prefix)
        scope&.lexical_nesting || lexical_nesting_for_prefix(qualified_prefix)
      end

      # The scope a census walk threads into the body a `class` / `module` header opens: the scope it already
      # threads, carrying that body's real `Module.nesting`.
      #
      # Issue #708 — the qualified prefix stopped being sufficient to DERIVE that chain. A rooted header
      # RESETS the prefix (`class ::Rooted` inside `module Outer` prefixes `["Rooted"]`), so `Outer` is absent
      # from it entirely and no function of the prefix alone recovers it, while Ruby keeps `Outer` on the
      # ladder as a live rung. `Source::ConstantPath.pushed_nesting` — the one function both declaration walks
      # already push with — has that case right, so the chain travels on the scope these walks thread anyway
      # rather than through every walk's parameter list, and stays a single owner ([#652](https://github.com/rigortype/rigor/issues/652)).
      def scope_entering_declaration(default_scope, constant_path)
        return default_scope if default_scope.nil?

        chain = Source::ConstantPath.pushed_nesting(default_scope.lexical_nesting || EMPTY_NESTING,
                                                    constant_path)
        chain ? default_scope.with_lexical_nesting(chain) : default_scope
      end

      # Ruby's `Module.nesting` for a body enclosed by `qualified_prefix`, innermost first: each entry is the
      # prefix truncated at one declaration, joined, so the compact spelling contributes exactly one entry and
      # the nested spelling one per `class` / `module` keyword.
      #
      # **This is an approximation, and only correct when no ROOTED header encloses the body** — a rooted
      # header resets the prefix without resetting Ruby's nesting, so the entries beneath the reset are not
      # in the prefix to be truncated out of it (#708). It remains the answer for a caller that threaded no
      # chain, where it is what the code did before and never a new firing; the walks that reach a body
      # thread the real chain via {#scope_entering_declaration}.
      def lexical_nesting_for_prefix(qualified_prefix)
        (1..qualified_prefix.size).map { |n| qualified_prefix.first(n).join("::") }.reverse.freeze
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
      # call seeds the ADR-38 initializer writes before the ordinary child descent runs.
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

          collect_initializer_block_ivars(node, def_owner || qualified_prefix, default_scope,
                                          accumulator, mutated_ivars, init_writes)
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
        split = meta_new_block_split(node, qualified_prefix, def_owner, singleton_cref)
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
        return false unless meta_new_constant_rvalue?(node) && node.block.is_a?(Prism::BlockNode)

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
        split = eval_block_split(node, qualified_prefix, def_owner, singleton_cref)
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
        self_decl = self_anchored_decl_prefix(node.constant_path, def_owner)
        child_prefix = self_decl ||
                       Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
        return unless child_prefix && node.body

        child_cref = unnameable_decl?(node, self_decl, singleton_cref)
        collect_class_body_ivar_writes(node.body, child_prefix.join("::"), init_writes) if init_writes && !child_cref
        walk_class_ivars(node.body, child_cref ? [] : child_prefix,
                         scope_entering_declaration(default_scope, node.constant_path), accumulator,
                         mutated_ivars, read_before_write, init_writes, method_assign_effects,
                         singleton_cref: child_cref)
      end

      def collect_def_ivar_writes(def_node, qualified_prefix, default_scope, accumulator, mutated_ivars, # rubocop:disable Metrics/ParameterLists
                                  read_before_write = nil, init_writes = nil, method_assign_effects = nil,
                                  singleton_self: false)
        return if def_node.body.nil? || qualified_prefix.empty?

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
        gather_ivar_writes(def_node.body, body_scope, class_name, accumulator,
                           EMPTY_GUARDED_IVARS, mutated_ivars, dead_writes)

        # B2.3 — collect per-method evidence for the read-before- write nil contribution. The accumulator-level decision
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
        detect_read_before_write(block_node.body, seen_writes, read_first)
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
        detect_read_before_write(def_node.body, seen_writes, read_first)

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
      def collect_class_body_ivar_writes(node, class_name, init_writes)
        return unless node.is_a?(Prism::Node)
        return if IVAR_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

        if node.is_a?(Prism::InstanceVariableWriteNode) ||
           node.is_a?(Prism::InstanceVariableOrWriteNode) ||
           node.is_a?(Prism::InstanceVariableAndWriteNode) ||
           node.is_a?(Prism::InstanceVariableOperatorWriteNode)
          (init_writes[class_name] ||= Set.new) << node.name
        end

        node.rigor_each_child do |child|
          collect_class_body_ivar_writes(child, class_name, init_writes)
        end
      end

      def detect_read_before_write(node, seen_writes, read_first)
        return unless node.is_a?(Prism::Node)
        return if IVAR_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

        read_first << node.name if node.is_a?(Prism::InstanceVariableReadNode) && !seen_writes.include?(node.name)

        # N1 — parallel / multiple assignment (`@m, @n = [], []`). The ivar targets are `InstanceVariableTargetNode`s,
        # not `InstanceVariableWriteNode`s, so the generic descent below never records them as writes. Left unhandled,
        # an ivar written only via massign in `initialize` stays absent from `init_writes`, and
        # `contribute_read_before_write_nil!` then unions a spurious `nil` into its class-ivar seed — masking a
        # genuinely-typed `@m` (e.g. `Tuple[]`) as `T | nil` at every sibling read. The RHS runs before any target is
        # committed, so descend into `value` FIRST (an ivar read there is read-before-write), then mark every ivar
        # target as written.
        if node.is_a?(Prism::MultiWriteNode)
          detect_read_before_write(node.value, seen_writes, read_first) if node.value
          detect_multi_write_target_writes(node, seen_writes, read_first)
          return
        end

        # Descend BEFORE recording a write — `@x = @x + 1`'s RHS is an `InstanceVariableReadNode` that runs before the
        # write is committed; the read is therefore read-before-write semantically. `each_child` yields the value
        # child before the lvalue target (`compact_child_nodes` field order), matching this order.
        node.rigor_each_child do |c|
          detect_read_before_write(c, seen_writes, read_first)
        end

        seen_writes << node.name if IVAR_WRITE_NODES.any? { |klass| node.is_a?(klass) }
      end

      # Records each ivar target of a `MultiWriteNode` / nested `MultiTargetNode` into `seen_writes`, and descends into
      # any non-ivar target (a `CallTargetNode` / `IndexTargetNode` receiver such as `@obj.x, @y = …`) so an ivar read
      # inside a target receiver still counts as read-before-write.
      def detect_multi_write_target_writes(node, seen_writes, read_first)
        targets = (node.lefts || []) + [node.rest].compact + (node.rights || [])
        targets.each do |target|
          case target
          when Prism::InstanceVariableTargetNode
            seen_writes << target.name
          when Prism::MultiTargetNode
            detect_multi_write_target_writes(target, seen_writes, read_first)
          when Prism::SplatNode
            inner = target.expression
            seen_writes << inner.name if inner.is_a?(Prism::InstanceVariableTargetNode)
          else
            detect_read_before_write(target, seen_writes, read_first)
          end
        end
      end

      IVAR_BARRIER_NODES = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode].freeze
      private_constant :IVAR_BARRIER_NODES

      EMPTY_GUARDED_IVARS = Set.new.freeze

      # Shared empty result for a def that returns no ivar — the overwhelmingly common case.
      EMPTY_IVAR_SET = Set.new.freeze
      private_constant :EMPTY_IVAR_SET

      # Branch nesting a tail expression is followed through. Stopping early only UNDER-collects escapes.
      TAIL_VALUE_DEPTH_CAP = 8
      private_constant :TAIL_VALUE_DEPTH_CAP
      private_constant :EMPTY_GUARDED_IVARS

      def gather_ivar_writes(node, scope, class_name, accumulator, guarded_ivars = EMPTY_GUARDED_IVARS,
                             mutated_ivars = nil, dead_writes = nil)
        return unless node.is_a?(Prism::Node)

        if node.is_a?(Prism::InstanceVariableWriteNode)
          unless dead_writes&.include?(node.object_id)
            record_ivar_write(node, scope, class_name, accumulator,
                              guarded: guarded_ivars.include?(node.name))
          end
        else
          record_compound_ivar_write(node, scope, class_name, accumulator)
        end

        # N1 — parallel / multiple assignment (`old, @cb = @cb, block`, `@i, @o, @e, @thr = Open3.popen3(cmd)`). A
        # direct `InstanceVariableWriteNode` is the only write form this collector handled, so an ivar appearing as a
        # `MultiWriteNode` target was silently dropped from the class-ivar union — leaving it to seed as pure `nil`
        # (from a sibling `@cb = nil` ctor write, or absent entirely) and false-fire `if @cb` always-falsey /
        # `@thr.alive?` undefined-for-nil. Record each ivar target with its tuple-position RHS type where the RHS is
        # array/tuple-shaped, else the unanalyzable floor (the same `Dynamic[top]` a single write to an unknown RHS
        # records — an unanalyzable multi-write means unknown, not nil).
        record_multi_write_ivars(node, scope, class_name, accumulator)

        record_ivar_mutator_call(node, class_name, mutated_ivars) if mutated_ivars

        # Don't recurse into nested defs, classes, or modules; their ivars belong to their own enclosing class.
        return if IVAR_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

        if node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)
          walk_conditional_ivar_writes(node, scope, class_name, accumulator, guarded_ivars,
                                       mutated_ivars, dead_writes)
          return
        end

        node.rigor_each_child do |c|
          gather_ivar_writes(c, scope, class_name, accumulator, guarded_ivars, mutated_ivars, dead_writes)
        end
      end

      # Records `@ivar.<method>(...)` calls whose method is in `MutationWidening::SHAPE_MUTATORS`.
      # The class-ivar pre-pass uses the resulting set to widen the post-collected accumulator entries (see
      # {.widen_mutated_ivar_entries!}). Always-safe to over- collect: any name that the widening primitive declines is
      # ignored at finalization.
      def record_ivar_mutator_call(node, class_name, mutated_ivars)
        method_name, receiver = mutation_target(node)
        return if method_name.nil?
        return unless receiver.is_a?(Prism::InstanceVariableReadNode)
        return unless MutationWidening::SHAPE_MUTATORS.include?(method_name)

        per_class = (mutated_ivars[class_name] ||= {})
        per_ivar = (per_class[receiver.name] ||= Set.new)
        per_ivar << method_name
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
      def walk_conditional_ivar_writes(node, scope, class_name, accumulator, guarded_ivars,
                                       mutated_ivars = nil, dead_writes = nil)
        then_guards = then_body_guarded_ivars(node)
        then_guarded = then_guards.empty? ? guarded_ivars : (guarded_ivars | then_guards)

        gather_ivar_writes(node.predicate, scope, class_name, accumulator, guarded_ivars,
                           mutated_ivars, dead_writes)
        if node.statements
          gather_ivar_writes(node.statements, scope, class_name, accumulator, then_guarded,
                             mutated_ivars, dead_writes)
        end
        branch = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
        return unless branch

        gather_ivar_writes(branch, scope, class_name, accumulator, guarded_ivars,
                           mutated_ivars, dead_writes)
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
      # WD3 — ADR-41-style hard cap on how deep the same-class-call definite-assignment crediting recurses (the ctor
      # calls `mask!`, which could itself call another same-class helper). Cycle-guarded independently; the cap bounds
      # even acyclic chains.
      SAME_CLASS_CALL_DEPTH_CAP = 3
      private_constant :SAME_CLASS_CALL_DEPTH_CAP

      # WD3 — builds the per-class definite-assignment summary `{class_name => {method_name => Set<ivar names assigned
      # non-nil on every completing path>}}`. Used so a ctor's `dead_transient_nil_writes` can credit an indirect
      # overwrite through an unconditionally-called same-class method (ipaddr's `initialize` reassigns `@mask_addr` via
      # `mask!`).
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
        call = meta_new_block_call(root)
        return false unless call

        child_prefix = meta_new_child_prefix(root, prefix, enclosing_owner)
        meta_ownerless = singleton_cref && !meta_new_path_target_nameable?(root, enclosing_owner)
        [call.receiver, *call.arguments&.arguments.to_a].compact.each do |part|
          collect_class_method_defs(part, prefix, acc, def_owner: enclosing_owner,
                                                       singleton_cref: singleton_cref)
        end
        if (body = meta_new_block_body(root))
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
        return false unless meta_new_constant_rvalue?(root) && root.block.is_a?(Prism::BlockNode)

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
        return false unless receiver_eval_call?(root)

        [root.receiver, *root.arguments&.arguments.to_a].compact.each do |part|
          collect_class_method_defs(part, prefix, acc, def_owner: def_owner,
                                                       singleton_cref: singleton_cref,
                                                       defs_singleton: defs_singleton)
        end
        self_prefix = def_owner || prefix
        unnameable = unnameable_eval_self?(false, def_owner, prefix, singleton_cref)
        eval_prefix = eval_receiver_prefix(root, self_prefix, prefix,
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
        self_decl = self_anchored_decl_prefix(root.constant_path, def_owner)
        child = self_decl || Source::ConstantPath.declaration_prefix(prefix, root.constant_path)
        if child && root.body
          # Under an unnameable cref a bare/`self::` header opens `#<singleton>::Name` —
          # ownerless; nameable headers re-anchor at a real cref.
          child_cref = unnameable_decl?(root, self_decl, singleton_cref)
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

      def record_ivar_write(node, scope, class_name, accumulator, guarded: false)
        rvalue_type = scope.type_of(node.value)

        # `@x = nil unless @x` / `@y = false unless @y` — follow-up to the polarity-aware defensive-init guard fix
        # (ROADMAP § Future cycles — "Defensive ivar-init with nil / false rvalue"). When the rvalue is itself a falsey
        # Constant, `union(rvalue, Constant[nil])` collapses (for `nil`) or doesn't widen the type's truthiness profile
        # (for `false`) — the predicate `unless @x` then folds to a single `Constant[nil]` / `Constant[false]` and the
        # `flow.always-truthy-condition` / `-always-falsey-` rule false-fires on the no-op-but-documented-default idiom.
        # Skip the seed contribution for this write — the sibling of `record_ivar_or_write`'s no-truthy-rvalue
        # skip for `@x ||= <falsey>` (#1175). Other writes to the same ivar still contribute; the falsey-default
        # write carries no useful precision the predicate hasn't already given us. See tdiary-core HEAD `ee40c2b`
        # `lib/tdiary/configuration.rb:157` for the worked site.
        return if guarded && falsey_constant?(rvalue_type)

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
      # `nil`, the guard bound its own ivar, and `ExpressionTyper#compound_write_value` read
      # `truthy(nil) | bot` — an instance method that sig-gen declared `-> bot`.
      def record_ivar_or_write(node, scope, class_name, accumulator)
        rvalue_type = scope.type_of(node.value)
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
      # target `ExpressionTyper#compound_write_value` reads as `Dynamic[top]`. Seeded as the rvalue, the
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
        ivars.each { |name, type| accumulate_ivar_type(accumulator, class_name, name, type) }
      end

      def falsey_constant?(type)
        type.is_a?(Type::Constant) && (type.value.nil? || type.value == false)
      end

      # Slice 7 phase 6 — class-cvar pre-pass. Same shape as the ivar pre-pass but collects
      # `Prism::ClassVariableWriteNode` writes inside ANY def body (instance or singleton) of the enclosing class,
      # because Ruby cvars are shared across both facets. The resulting table is seeded into both instance and singleton
      # method bodies through `Scope#class_cvars_for`.
      def build_class_cvar_index(root, default_scope)
        accumulator = {}
        walk_class_cvars(root, [], default_scope, accumulator)
        accumulator.transform_values(&:freeze).freeze
      end

      # `def_owner` names the class a `def` leaf's cvar writes belong to when `self` is
      # rebound — see {#walk_class_ivars}. `[]` marks a self no name covers.
      def walk_class_cvars(node, qualified_prefix, default_scope, accumulator, def_owner: nil,
                           singleton_cref: false)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          return if walk_cvars_declaration?(node, qualified_prefix, default_scope, accumulator,
                                            def_owner, singleton_cref)
        when Prism::SingletonClassNode
          # The expression evaluates in the enclosing cref; the body's cref is the
          # unnameable singleton class — the marker lifts only at a nameable header.
          walk_class_cvars(node.expression, qualified_prefix, default_scope, accumulator,
                           def_owner: def_owner, singleton_cref: singleton_cref)
          if node.body
            # `self` below `class <<` is the singleton class — `self::`-anchored receivers
            # decline; `@@x` keeps the lexical cref either way, so the body walks ownerless.
            walk_class_cvars(node.body, qualified_prefix, default_scope, accumulator,
                             def_owner: [], singleton_cref: true)
          end
          return
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode,
             Prism::ConstantOrWriteNode, Prism::ConstantPathOrWriteNode
          return if walk_cvars_meta_new?(node, qualified_prefix, default_scope, accumulator,
                                         def_owner, singleton_cref)
        when Prism::DefNode
          # `@@x` inside a `def` resolves through the LEXICAL cref — `Module.nesting` is the
          # same inside a meta-new or eval block, so `def_owner` (the rebound self) must not
          # feed this: `K = Class.new { def m = @@x }` inside `class C` writes `C::@@x`.
          collect_def_cvar_writes(node, qualified_prefix, default_scope, accumulator)
          return
        when Prism::CallNode
          return if walk_cvars_meta_call?(node, qualified_prefix, default_scope, accumulator,
                                          def_owner, singleton_cref)
          return if walk_cvars_eval_call?(node, qualified_prefix, default_scope, accumulator,
                                          def_owner, singleton_cref)
        end

        node.rigor_each_child do |child|
          walk_class_cvars(child, qualified_prefix, default_scope, accumulator,
                           def_owner: def_owner, singleton_cref: singleton_cref)
        end
      end

      # The `K = Class.new { … }` arm of {#walk_class_cvars}: the block's `def` cvar
      # writes belong to the class the write names; its declarations stay lexical.
      def walk_cvars_meta_new?(node, qualified_prefix, default_scope, accumulator,
                               def_owner, singleton_cref)
        split = meta_new_block_split(node, qualified_prefix, def_owner, singleton_cref)
        return false unless split

        enclosing, body, body_self = split
        enclosing.each do |part|
          walk_class_cvars(part, qualified_prefix, default_scope, accumulator,
                           def_owner: def_owner, singleton_cref: singleton_cref)
        end
        if body
          walk_class_cvars(body, qualified_prefix, default_scope, accumulator,
                           def_owner: body_self, singleton_cref: singleton_cref)
        end
        true
      end

      # The class/module arm of {#walk_class_cvars}: under an unnameable cref a
      # bare/`self::` header opens `#<singleton>::Name` — ownerless; nameable headers
      # re-anchor at a real cref.
      def walk_cvars_declaration?(node, qualified_prefix, default_scope, accumulator,
                                  def_owner, singleton_cref)
        ctx = decl_body_context(node, qualified_prefix, def_owner, singleton_cref)
        return false unless ctx

        _self_decl, child_prefix, child_cref = ctx
        return true unless node.body

        walk_class_cvars(node.body, child_cref ? [] : child_prefix,
                         scope_entering_declaration(default_scope, node.constant_path), accumulator,
                         singleton_cref: child_cref)
        true
      end

      # The bare `Class.new { … }`-family call arm of {#walk_class_cvars}: the block's
      # `def` cvar writes belong to an unnameable class.
      def walk_cvars_meta_call?(node, qualified_prefix, default_scope, accumulator,
                                def_owner, singleton_cref)
        return false unless meta_new_constant_rvalue?(node) && node.block.is_a?(Prism::BlockNode)

        [node.receiver, *node.arguments&.arguments.to_a].compact.each do |part|
          walk_class_cvars(part, qualified_prefix, default_scope, accumulator,
                           def_owner: def_owner, singleton_cref: singleton_cref)
        end
        if (body = node.block.body)
          walk_class_cvars(body, qualified_prefix, default_scope, accumulator,
                           def_owner: [], singleton_cref: singleton_cref)
        end
        true
      end

      # The eval-family arm of {#walk_class_cvars}: the block's `self` is the receiver for
      # `self::` declarations (`X.class_eval { class self::D; def m = @@x }` reads
      # `X::D::@@x`), while `@@x` writes inside `def`s keep the lexical cref either way.
      def walk_cvars_eval_call?(node, qualified_prefix, default_scope, accumulator,
                                def_owner, singleton_cref)
        split = eval_block_split(node, qualified_prefix, def_owner, singleton_cref)
        return false unless split

        enclosing, body, body_self = split
        enclosing.each do |part|
          walk_class_cvars(part, qualified_prefix, default_scope, accumulator,
                           def_owner: def_owner, singleton_cref: singleton_cref)
        end
        if body
          walk_class_cvars(body, qualified_prefix, default_scope, accumulator,
                           def_owner: body_self, singleton_cref: singleton_cref)
        end
        true
      end

      def collect_def_cvar_writes(def_node, qualified_prefix, default_scope, accumulator)
        return if def_node.body.nil? || qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        body_scope = census_body_scope(default_scope, qualified_prefix,
                                       Type::Combinator.nominal_of(class_name))
        gather_cvar_writes(def_node.body, body_scope, class_name, accumulator)
      end

      def gather_cvar_writes(node, scope, class_name, accumulator)
        return unless node.is_a?(Prism::Node)

        record_cvar_write(node, scope, class_name, accumulator) if node.is_a?(Prism::ClassVariableWriteNode)
        return if IVAR_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

        node.rigor_each_child { |c| gather_cvar_writes(c, scope, class_name, accumulator) }
      end

      def record_cvar_write(node, scope, class_name, accumulator)
        rvalue_type = scope.type_of(node.value)
        accumulator[class_name] ||= {}
        existing = accumulator[class_name][node.name]
        accumulator[class_name][node.name] =
          existing ? Type::Combinator.union(existing, rvalue_type) : rvalue_type
      end

      # Slice 7 phase 6 — program-global pre-pass. Globals are process-wide so the accumulator is a flat `Hash[Symbol,
      # Type::t]` populated from every `Prism::GlobalVariableWriteNode` in the program (top-level AND inside method
      # bodies). The same accumulator is seeded into every method body and the top-level scope.
      def build_program_global_index(root, default_scope)
        accumulator = {}
        gather_global_writes(root, default_scope, accumulator)
        accumulator.freeze
      end

      def gather_global_writes(node, scope, accumulator)
        return unless node.is_a?(Prism::Node)

        record_global_write(node, scope, accumulator) if node.is_a?(Prism::GlobalVariableWriteNode)
        node.rigor_each_child { |c| gather_global_writes(c, scope, accumulator) }
      end

      def record_global_write(node, scope, accumulator)
        rvalue_type = scope.type_of(node.value)
        existing = accumulator[node.name]
        accumulator[node.name] =
          existing ? Type::Combinator.union(existing, rvalue_type) : rvalue_type
      end

      # Slice 7 phase 9 — in-source constant value pre-pass. Walks the entire program (top-level AND inside class /
      # module / def bodies) for `Prism::ConstantWriteNode` and `Prism::ConstantPathWriteNode`, types each rvalue, and
      # accumulates by qualified name. Constants defined inside a class body are qualified with the surrounding class
      # path; a constant written via a path resolves its own namespace through the enclosing nesting first
      # ({#constant_path_write_key}) — which is where this walk and the
      # [#644](https://github.com/rigortype/rigor/issues/644) publication census below stopped agreeing about
      # a path write's name.
      def build_in_source_constants(root, default_scope)
        accumulator = {}
        walk_constant_writes(root, [], default_scope, accumulator)
        accumulator.freeze
      end

      # Issue #540 — the mutation census behind the two wideners. Walks the whole tree once, tracking the
      # lexical class/module prefix, and records every node that MUTATES a constant-read or
      # class-variable-read receiver: the `Index{Or,And,Operator}Write` family, and a CallNode whose name
      # is a known in-place mutator (`MutationWidening`'s tables) or a plain attribute/index writer
      # (`name=` / `[]=`). Non-mutating reads never register, so `VERSION`-style constants keep their fold.
      #
      # @return `:constants` — a Set of candidate qualified names (each mutation
      #   contributes every lexical-resolution candidate, `A::B::C` outward to bare `C`, mirroring how the
      #   reads resolve); `:cvars` — `{class_name => Set[Symbol]}`.
      def collect_literal_receiver_mutations(root)
        census = { constants: Set.new, cvars: Hash.new { |h, k| h[k] = Set.new } }
        walk_literal_receiver_mutations(root, [], census, EMPTY_NESTING)
        census
      end

      # `def_owner` names the class a `def` leaf's cvar mutations belong to when `self`
      # is rebound — see {#walk_class_ivars}; `[]` marks a self no name covers.
      def walk_literal_receiver_mutations(node, qualified_prefix, census, nesting = EMPTY_NESTING,
                                          def_owner: nil, singleton_cref: false)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          return if walk_literal_mutation_declaration?(node, qualified_prefix, census, nesting,
                                                       def_owner, singleton_cref)
        when Prism::SingletonClassNode
          # The expression evaluates in the enclosing cref; the body's cref is the
          # unnameable singleton class — the marker lifts only at a nameable header.
          return walk_singleton_literal_mutations(node, qualified_prefix, census, nesting,
                                                  def_owner, singleton_cref)
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode,
             Prism::ConstantOrWriteNode, Prism::ConstantPathOrWriteNode
          return if walk_literal_mutation_meta_new?(node, qualified_prefix, census, nesting,
                                                    def_owner, singleton_cref)
        when Prism::CallNode
          return if walk_literal_mutation_meta_call?(node, qualified_prefix, census, nesting,
                                                     def_owner, singleton_cref)
          return if walk_literal_mutation_eval_call?(node, qualified_prefix, census, nesting,
                                                     def_owner, singleton_cref)

          record_literal_receiver_mutation(node, qualified_prefix, nesting, census)
        else
          record_literal_receiver_mutation(node, qualified_prefix, nesting, census)
        end

        node.rigor_each_child do |child|
          walk_literal_receiver_mutations(child, qualified_prefix, census, nesting,
                                          def_owner: def_owner, singleton_cref: singleton_cref)
        end
      end

      # The `K = Class.new { … }` arm of {#walk_literal_receiver_mutations}: the block's
      # `def`-level cvar mutations belong to the class the write names; its declarations
      # stay lexical.
      def walk_literal_mutation_meta_new?(node, qualified_prefix, census, nesting,
                                          def_owner, singleton_cref)
        split = meta_new_block_split(node, qualified_prefix, def_owner, singleton_cref)
        return false unless split

        enclosing, body, body_self = split
        enclosing.each do |part|
          walk_literal_receiver_mutations(part, qualified_prefix, census, nesting,
                                          def_owner: def_owner, singleton_cref: singleton_cref)
        end
        if body
          walk_literal_receiver_mutations(body, qualified_prefix, census, nesting,
                                          def_owner: body_self, singleton_cref: singleton_cref)
        end
        true
      end

      # The eval-family arm of {#walk_literal_receiver_mutations}: `self::` declarations anchor
      # on the receiver (`X.class_eval { class self::D }` opens `X::D`), while bare `@@x` and
      # `X` receivers keep their lexical answers — `def_owner` rides the declaration channel
      # only.
      def walk_literal_mutation_eval_call?(node, qualified_prefix, census, nesting,
                                           def_owner, singleton_cref)
        split = eval_block_split(node, qualified_prefix, def_owner, singleton_cref)
        return false unless split

        enclosing, body, body_self = split
        enclosing.each do |part|
          walk_literal_receiver_mutations(part, qualified_prefix, census, nesting,
                                          def_owner: def_owner, singleton_cref: singleton_cref)
        end
        if body
          walk_literal_receiver_mutations(body, qualified_prefix, census, nesting,
                                          def_owner: body_self, singleton_cref: singleton_cref)
        end
        true
      end

      # The class/module arm of {#walk_literal_receiver_mutations}: under an unnameable
      # cref a bare/`self::` header opens `#<singleton>::Name` — ownerless, and the rung
      # nothing can spell never reaches the chain; nameable headers re-anchor.
      def walk_literal_mutation_declaration?(node, qualified_prefix, census, nesting,
                                             def_owner, singleton_cref)
        ctx = decl_body_context(node, qualified_prefix, def_owner, singleton_cref)
        return false unless ctx

        self_decl, child_prefix, child_cref = ctx
        child_nesting =
          if child_cref
            nesting
          elsif self_decl
            [self_decl.join("::"), *nesting].freeze
          else
            Source::ConstantPath.pushed_nesting(nesting, node.constant_path) || nesting
          end
        return true unless node.body

        walk_literal_receiver_mutations(node.body, child_cref ? [] : child_prefix, census,
                                        child_nesting, singleton_cref: child_cref)
        true
      end

      # The bare `Class.new { … }`-family call arm of {#walk_literal_receiver_mutations}:
      # the block's `def`-level mutations belong to an unnameable class.
      def walk_literal_mutation_meta_call?(node, qualified_prefix, census, nesting,
                                           def_owner, singleton_cref)
        return false unless meta_new_constant_rvalue?(node) && node.block.is_a?(Prism::BlockNode)

        [node.receiver, *node.arguments&.arguments.to_a].compact.each do |part|
          walk_literal_receiver_mutations(part, qualified_prefix, census, nesting,
                                          def_owner: def_owner, singleton_cref: singleton_cref)
        end
        if (body = node.block.body)
          walk_literal_receiver_mutations(body, qualified_prefix, census, nesting,
                                          def_owner: [], singleton_cref: singleton_cref)
        end
        true
      end

      def walk_singleton_literal_mutations(node, qualified_prefix, census, nesting,
                                           def_owner, singleton_cref)
        walk_literal_receiver_mutations(node.expression, qualified_prefix, census, nesting,
                                        def_owner: def_owner, singleton_cref: singleton_cref)
        return unless node.body

        # `def` below `class <<` is a singleton method — `self` is the singleton class, so
        # `self::`-anchored receivers and writes decline; the body walks ownerless.
        walk_literal_receiver_mutations(node.body, qualified_prefix, census, nesting,
                                        def_owner: [], singleton_cref: true)
      end

      # Two parameters because the two arms key on two DIFFERENT TABLES, not because the values differ:
      # `nesting.first` and `qualified_prefix.join("::")` are in fact always equal, since
      # `.declaration_prefix` and `.pushed_nesting` branch on the same `rooted?` and qualify against the same
      # parent. `qualified_prefix` is what a class variable must key on because it is the join key with
      # `build_class_cvar_index`, which derives its own key from the same `declaration_prefix` — so the two
      # tables agree by construction. `nesting` is what a constant name must resolve through because the
      # ladder walks every rung, not just the innermost, and a rooted header drops the outer rungs from the
      # prefix while Ruby keeps them ([#708](https://github.com/rigortype/rigor/issues/708)).
      def record_literal_receiver_mutation(node, qualified_prefix, nesting, census)
        receiver = mutating_receiver_of(node)
        return if receiver.nil?

        case receiver
        when Prism::ConstantReadNode
          constant_mutation_candidates(receiver.name.to_s, nesting, census[:constants])
        when Prism::ConstantPathNode
          path_mutation_candidates(receiver, nesting, census[:constants])
        when Prism::ClassVariableReadNode
          census[:cvars][qualified_prefix.join("::")] << receiver.name unless qualified_prefix.empty?
        end
      end

      # The lexical candidates a PATH spelling reaches, for the same reason the bare arm takes them:
      # `Holder::TABLE[:k] = 1` inside `module Admin` mutates whatever `Holder::TABLE` resolves to there,
      # and since [#690](https://github.com/rigortype/rigor/issues/690) the write accumulator keys that
      # entry `Admin::Holder::TABLE`. Recording only the as-written name left the mutated constant matched
      # by nothing and its closed empty shape intact — the very fold #540 exists to retract. Over-recording
      # only widens, which is the direction this census is allowed to err in.
      #
      # A ROOTED receiver is the one spelling that reaches no lexical candidate at all, so widening them is
      # not erring in the allowed direction but discarding precision the code hands over
      # ([#703](https://github.com/rigortype/rigor/issues/703)): `::Table::ROWS[k] = 1` names the top-level
      # constant unconditionally, so the sibling `Admin::Table::ROWS` a bare spelling would also reach is
      # untouched and keeps its empty-shape fold. This is the exemption #690 established on the WRITE side
      # ({#constant_path_write_key}), which the two arms have to agree on: the strict render drops the root
      # marker, so the rooted and unrooted spellings are indistinguishable by name alone.
      def path_mutation_candidates(receiver, nesting, into)
        full = Source::ConstantPath.qualified_name_or_nil(receiver)
        return if full.nil?

        return into << full if Source::ConstantPath.rooted?(receiver)

        constant_mutation_candidates(full, nesting, into)
      end

      # The receiver a node mutates, or nil when the node is not a mutation.
      def mutating_receiver_of(node)
        case node
        when Prism::IndexOrWriteNode, Prism::IndexAndWriteNode, Prism::IndexOperatorWriteNode
          node.receiver
        when Prism::CallNode
          return nil if node.receiver.nil?
          return node.receiver if node.attribute_write?
          return node.receiver if MutationWidening::SHAPE_MUTATORS.include?(node.name)

          nil
        end
      end

      # Every lexical-resolution candidate for a bare constant name written at `nesting`, innermost first
      # — `["A::B", "A"]` + `C` yields `A::B::C`, `A::C`, `C` — so the widener matches whichever form the
      # write accumulator recorded.
      #
      # Issue #708 — this reads Ruby's `Module.nesting`, which the enclosing qualified prefix used to be a
      # faithful stand-in for. It stopped being one when a rooted header gained the power to RESET that
      # prefix: a bare `TABLE[:k] = 1` inside `class ::Rooted` in `module Outer` mutates `Outer::TABLE`, and
      # candidates built from the reset prefix never name it, so the closed shape was never widened and
      # `Outer::TABLE.empty?` folded to `true` on a table the program fills.
      def constant_mutation_candidates(base_name, nesting, into)
        nesting.each { |entry| into << "#{entry}::#{base_name}" }
        into << base_name
      end

      def widen_mutated_constants(accumulator, mutated_names)
        return accumulator if mutated_names.empty?

        widened = accumulator.dup
        mutated_names.each do |name|
          existing = widened[name]
          next if existing.nil?

          widened[name] = census_mutated_type(existing)
        end
        widened.freeze
      end

      def widen_mutated_cvars(accumulator, mutated_by_class)
        return accumulator if mutated_by_class.empty?

        widened = accumulator.dup
        mutated_by_class.each do |class_name, names|
          table = widened[class_name]
          next if table.nil?

          updated = table.dup
          names.each do |cvar|
            existing = updated[cvar]
            next if existing.nil?

            updated[cvar] = census_mutated_type(existing)
          end
          widened[class_name] = updated.freeze
        end
        widened.freeze
      end

      # The type a mutated constant or class variable is read as. The census records the NAME a call mutated and not
      # the call, so it cannot say what was stored, and `Dynamic` alone does not say it either: a read resolves through
      # the static facet's RBS projection, where a closed `HashShape` answers its known values for any key, a `Tuple`
      # its known elements for any index and an `Array[1 | 2]` `1 | 2`. `H = { a: 1 }; H.default = 0` read `H[:b]` as
      # `1`, and `T = { a: 1 }; T[:b] = 2` read `T[:b]` as `1` too, so `== 0` / `== 2` folded always-falsey.
      #
      # Each carrier member of the facet therefore stops claiming its contents are complete: a shape reopens
      # (`extra_keys: :open`), whose projection carries a `Dynamic[top]` arm beside the known values, a tuple becomes
      # the `Array` of its elements plus the same arm, and an `Array` / `Hash` nominal with a value-pinned type
      # argument gains the arm on every type argument, as the unknown-store seam gives it. A class-level nominal
      # (`Hash.new(0)`'s `Hash[Dynamic[top], Integer]`) is left alone: a store of the same class keeps it true, and
      # the arm would silence `COUNTS[k].upcase`. A read still answers the known values (every key's, since the
      # projection is not keyed) beside the arm, which is what keeps a stored or rewritten value from folding. An
      # entry already `Dynamic` is unpinned through its facet, so a carrier an RBS overload join wrapped is not left
      # pinned.
      def census_mutated_type(type)
        type = type.static_facet if type.is_a?(Type::Dynamic)
        members = type.is_a?(Type::Union) ? type.members : [type]
        Type::Combinator.dynamic(Type::Combinator.union(*members.map { |member| census_unpinned_carrier(member) }))
      end

      # A `Difference` / `Refined` member drops to its unpinned base: a mutation can falsify the removed value or the
      # refinement as well (`clear` empties a `non-empty-array`).
      def census_unpinned_carrier(member)
        case member
        when Type::HashShape then HashLookupMutation.open_shape(member) || member
        when Type::Tuple
          Type::Combinator.nominal_of(
            "Array", type_args: [Type::Combinator.union(*member.elements, Type::Combinator.untyped)]
          )
        when Type::Nominal
          UnknownStoreWidening.value_pinned_collection?(member) ? UnknownStoreWidening.gradual_content(member) : member
        when Type::Difference, Type::Refined then census_unpinned_carrier(member.base)
        else member
        end
      end

      # Issue #352 — folds the project-wide `pre_eval:` constant seed under this file's own table. Returns the
      # per-file table unchanged (same frozen object) when nothing was seeded, so a run without `pre_eval:`
      # constants allocates and compares exactly what it did before.
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
        census = published.empty? ? nil : constant_write_census(root)
        seeded_scope.with_discovery(
          seeded_scope.discovery.with(
            in_source_constants: merged,
            local_constant_names: local_constant_name_set(census, published),
            published_constant_alias_names: published_constant_alias_name_set(census, published)
          )
        )
      end

      # The QUALIFIED names this file assigns that the project also published, frozen. Read from the same
      # {#constant_write_census} the cross-file table is built from, not from the typed per-file
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

      # Issue #667 — `{class name => Set[ivar name]}` for an ivar whose class-ivar seed is a copy of a
      # foreign published constant (`@mode = AppConfig::MODE` in `initialize`). The cross-method half of the
      # copy provenance: the write and the `@mode == :production` that reads it sit in different method
      # bodies, so no flow edge connects them and the fact has to be censused per class, exactly as the
      # ADR-58 nil seed it rides beside is. Runs only when the project published something.
      def seed_published_constant_ivars(seeded_scope, root)
        return seeded_scope if seeded_scope.published_constant_names.empty?

        table = {}
        walk_published_constant_ivars(root, [], seeded_scope, table)
        return seeded_scope if table.empty?

        seeded_scope.with_discovery(
          seeded_scope.discovery.with(published_constant_ivars: table.transform_values(&:freeze).freeze)
        )
      end

      # `def_owner` names the class a `def` leaf's ivar writes belong to when `self` is
      # rebound — see {#walk_class_ivars}; `[]` marks a self no name covers.
      def walk_published_constant_ivars(node, qualified_prefix, scope, table, def_owner: nil,
                                        singleton_cref: false)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          return if walk_published_ivar_declaration?(node, qualified_prefix, scope, table,
                                                     def_owner, singleton_cref)
        when Prism::SingletonClassNode
          # The expression evaluates in the enclosing cref; the body's cref is unnameable.
          return walk_singleton_published_ivars(node, qualified_prefix, scope, table,
                                                def_owner, singleton_cref)
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode,
             Prism::ConstantOrWriteNode, Prism::ConstantPathOrWriteNode
          return if walk_published_ivar_meta_new?(node, qualified_prefix, scope, table,
                                                  def_owner, singleton_cref)
        when Prism::CallNode
          return if walk_published_ivar_eval_call?(node, qualified_prefix, scope, table,
                                                   def_owner, singleton_cref)
        else
          return if walk_published_ivar_leaf?(node, qualified_prefix, scope, table, def_owner)
        end

        node.rigor_each_child do |child|
          walk_published_constant_ivars(child, qualified_prefix, scope, table,
                                        def_owner: def_owner, singleton_cref: singleton_cref)
        end
      end

      # The remaining leaf arms of {#walk_published_constant_ivars}: a `def self.…` body writes the
      # singleton's ivars, which take no instance seed at all; an ivar write seeds the owner row.
      # Returns true when the node was consumed and its children must not be walked.
      def walk_published_ivar_leaf?(node, qualified_prefix, scope, table, def_owner)
        return !node.receiver.nil? if node.is_a?(Prism::DefNode)
        return false unless node.is_a?(Prism::InstanceVariableWriteNode)

        record_published_constant_ivar(node, def_owner || qualified_prefix, scope, table)
        true
      end

      # The `K = Class.new { … }` arm of {#walk_published_constant_ivars}: the block's `def`
      # ivar writes belong to the class the write names; its declarations stay lexical.
      def walk_published_ivar_meta_new?(node, qualified_prefix, scope, table, def_owner,
                                        singleton_cref)
        split = meta_new_block_split(node, qualified_prefix, def_owner, singleton_cref)
        return false unless split

        enclosing, body, body_self = split
        enclosing.each do |part|
          walk_published_constant_ivars(part, qualified_prefix, scope, table,
                                        def_owner: def_owner, singleton_cref: singleton_cref)
        end
        if body
          walk_published_constant_ivars(body, qualified_prefix, scope, table,
                                        def_owner: body_self, singleton_cref: singleton_cref)
        end
        true
      end

      # The eval-family arm of {#walk_published_constant_ivars}: the receiver's `self` anchors
      # `self::` declarations and owns the block's class-body-level `@x` seeds the way the
      # enclosing class owns this body's.
      def walk_published_ivar_eval_call?(node, qualified_prefix, scope, table, def_owner,
                                         singleton_cref)
        split = eval_block_split(node, qualified_prefix, def_owner, singleton_cref)
        return false unless split

        enclosing, body, body_self = split
        enclosing.each do |part|
          walk_published_constant_ivars(part, qualified_prefix, scope, table,
                                        def_owner: def_owner, singleton_cref: singleton_cref)
        end
        if body
          walk_published_constant_ivars(body, qualified_prefix, scope, table,
                                        def_owner: body_self, singleton_cref: singleton_cref)
        end
        true
      end

      # The class/module arm of {#walk_published_constant_ivars}: under an unnameable
      # cref a bare/`self::` header opens `#<singleton>::Name` — ownerless; nameable
      # headers re-anchor at a real cref.
      def walk_published_ivar_declaration?(node, qualified_prefix, scope, table,
                                           def_owner, singleton_cref)
        ctx = decl_body_context(node, qualified_prefix, def_owner, singleton_cref)
        return false unless ctx

        _self_decl, child_prefix, child_cref = ctx
        return true unless node.body

        walk_published_constant_ivars(node.body, child_cref ? [] : child_prefix, scope, table,
                                      singleton_cref: child_cref)
        true
      end

      def walk_singleton_published_ivars(node, qualified_prefix, scope, table, def_owner,
                                         singleton_cref)
        walk_published_constant_ivars(node.expression, qualified_prefix, scope, table,
                                      def_owner: def_owner, singleton_cref: singleton_cref)
        return unless node.body

        # `def` below `class <<` defines singleton methods — their `@x` writes are the
        # class object's own ivars, not instance-ivar seeds — so the body walks ownerless.
        walk_published_constant_ivars(node.body, qualified_prefix, scope, table,
                                      def_owner: [], singleton_cref: true)
      end

      # The class-ivar accumulator (already seeded when this runs) is the pre-gate: an ivar whose seed is not
      # a `Type::Constant` can never fold a predicate, so there is nothing for the mark to withhold and the
      # guard's one interprocedural hop is not worth paying for it.
      def record_published_constant_ivar(node, qualified_prefix, scope, table)
        return if qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        return unless scope.class_ivars_for(class_name)[node.name].is_a?(Type::Constant)
        return unless Analysis::CheckRules::PublishedConstantGuard.rooted?(node.value, scope)

        (table[class_name] ||= Set.new) << node.name
      end

      def merge_seeded_constants(seeded, per_file)
        return per_file if seeded.nil? || seeded.empty?

        seeded.merge(per_file).freeze
      end

      # Issue #705 — the block-taking calls that swap `self` for the RECEIVER: Ruby evaluates the block with
      # the receiver as `self` and leaves `Module.nesting` untouched, so `self::BAR = …` inside one names the
      # receiver's `BAR` while a bare `BAR = …` in the same block still names the enclosing namespace's.
      SELF_REBINDING_EVAL_CALLS = %i[class_eval module_eval class_exec module_exec].freeze
      private_constant :SELF_REBINDING_EVAL_CALLS

      # …and the one whose block `self` this walk cannot name even when the receiver names a
      # class: a `define_method` body runs on the receiver's INSTANCE at call time, an object
      # nothing in the source names, so a `self::` write inside it is declined — gradual for
      # the case where the instance is a class or module, and no guess for the rest.
      OPAQUE_SELF_BLOCK_CALLS = %i[define_method].freeze
      private_constant :OPAQUE_SELF_BLOCK_CALLS

      # `instance_eval` / `instance_exec` rebind `self` to the receiver exactly as `class_eval`
      # does — `X.instance_eval { self::BAR = 1 }` writes `X::BAR` — but the default definee moves
      # to the receiver's SINGLETON instead of the receiver: `X.instance_eval { def m }` installs
      # `X.m`, while `define_method`/`attr_*` inside (method calls on the receiver-as-module)
      # still install `X#m`. The def-owning walks split the two surfaces on this list.
      INSTANCE_EVAL_CALLS = %i[instance_eval instance_exec].freeze
      RECEIVER_EVAL_CALLS = (SELF_REBINDING_EVAL_CALLS + INSTANCE_EVAL_CALLS).freeze
      private_constant :INSTANCE_EVAL_CALLS, :RECEIVER_EVAL_CALLS

      # The sentinel for "`self` was rebound to something no class/module name reaches". A `self::BAR = …`
      # under it is DECLINED — the same answer a dynamic base takes, for the same reason.
      OPAQUE_SELF = :__rigor_opaque_self__
      private_constant :OPAQUE_SELF

      # The owner whose constants the census spells BARE — `Object`'s constants are the top-level ones.
      OBJECT_OWNER = "Object"
      private_constant :OBJECT_OWNER

      def walk_constant_writes(node, qualified_prefix, default_scope, accumulator, self_owner = nil,
                               singleton_cref: false)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::SingletonClassNode
          return walk_singleton_class_writes(node, qualified_prefix, default_scope, accumulator,
                                             self_owner, singleton_cref)
        when Prism::ClassNode, Prism::ModuleNode
          return if walk_typed_declaration?(node, qualified_prefix, default_scope, accumulator,
                                            self_owner, singleton_cref)
        when Prism::ConstantWriteNode
          # A bare write under an unnameable cref — anywhere lexically below `class <<`,
          # including inside an eval or `Class.new` block, since `Module.nesting` never
          # rebinds — lands on that cref's constant table, a name nothing else can
          # produce, so it declines rather than filing under the enclosing class.
          unless singleton_cref
            record_constant_write(node, qualified_prefix, default_scope, accumulator,
                                  qualified_write_name(qualified_prefix, node.name.to_s), self_owner)
          end
          return
        when Prism::ConstantPathWriteNode
          full = constant_path_write_key(node.target, qualified_prefix, default_scope, self_owner)
          record_constant_write(node, qualified_prefix, default_scope, accumulator, full, self_owner) if full
          return
        end

        walk_constant_write_children(node, qualified_prefix, default_scope, accumulator, self_owner,
                                     singleton_cref)
      end

      # `self` inside a `class <<` body is the singleton: `self`-anchored and bare write
      # targets land on its constant table (unnameable, so both decline), and the body is
      # entered with an OPAQUE self so a `self::`-anchored eval receiver declines — the
      # read raises NameError at runtime unless the constant lives on that singleton.
      def walk_singleton_class_writes(node, qualified_prefix, default_scope, accumulator,
                                      self_owner, singleton_cref)
        walk_constant_writes(node.expression, qualified_prefix, default_scope, accumulator,
                             self_owner, singleton_cref: singleton_cref)
        return unless node.body

        walk_constant_writes(node.body, qualified_prefix, default_scope, accumulator,
                             OPAQUE_SELF, singleton_cref: true)
      end

      # The class/module arm of {#walk_constant_writes}. Under an unnameable cref a
      # bare/`self::` declaration pushes `#<singleton>::Name` — still unnameable — so the body
      # keeps the OPAQUE self, the cref flag, and the ENCLOSING prefix: `child_prefix`'s
      # `C::D` would seed `C::D::Foo` write candidates no program can produce, and the only
      # nameable rungs below are the enclosing ones. A nameable header re-anchors at a
      # nameable cref. Returns whether the declaration's body was walked.
      def walk_typed_declaration?(node, qualified_prefix, default_scope, accumulator, self_owner,
                                  singleton_cref)
        self_base = rebound_self_base(self_owner)
        self_base = [] if self_base == OPAQUE_SELF
        self_decl = self_anchored_decl_prefix(node.constant_path, self_base)
        child_prefix = self_decl ||
                       Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
        return false unless child_prefix && node.body

        child_cref = unnameable_decl?(node, self_decl, singleton_cref)
        child_scope = if child_cref
                        default_scope
                      else
                        scope_entering_declaration(default_scope, node.constant_path)
                      end
        walk_constant_writes(node.body, child_cref ? qualified_prefix : child_prefix, child_scope,
                             accumulator, child_cref ? OPAQUE_SELF : nil, singleton_cref: child_cref)
        true
      end

      # The self a `self::`-anchored eval receiver resolves against, given the enclosing
      # body's self — an eval block's own receiver. A String owner splits into its constant
      # segments; an OPAQUE or nil self passes through unchanged — an OPAQUE self stays
      # opaque either way.
      def rebound_self_base(owner)
        owner.is_a?(String) ? owner.split("::") : owner
      end

      # Whether `self` in this position names nothing a `self::` receiver or write target
      # can resolve against: inside `class <<` (self is the singleton), under a self an
      # eval declined to name (an explicit empty def-owner), or anywhere below an
      # unnameable lexical cref without an eval-derived self — a `class D` nested in
      # `class <<` reopens `#<Class:C>::D`, a real class object nothing can spell. A
      # nameable eval owner still answers: `Foo.class_eval { self::X = }` inside
      # `class <<` resolves `Foo::X`.
      def unnameable_eval_self?(in_singleton_class, def_owner_prefix, qualified_prefix, singleton_cref)
        return true if in_singleton_class
        return true if def_owner_prefix && def_owner_prefix.empty?

        singleton_cref && (def_owner_prefix || qualified_prefix).empty?
      end

      # Recursion into `node`'s children, swapping `self` for the ONE child a self-rebinding call evaluates
      # under a different receiver — its block. Every other child, and every child of a node that rebinds
      # nothing, keeps the `self` it was reached under.
      #
      # The block is identified by its CLASS rather than by identity against `CallNode#block`. These walks
      # recurse over every node kind, so `node` here is the whole `Prism::Node` union and reading a member
      # only a call carries off it is exactly the shape Rigor's own check rejects. The test is equivalent:
      # `rebound` is non-nil only where {#rebound_block_self} already saw a `Prism::BlockNode` in the `block`
      # field, and no other child of a call can be one — a receiver is an expression, arguments sit under
      # `ArgumentsNode`, and a `&blk` pass-through is a `BlockArgumentNode`.
      def walk_constant_write_children(node, qualified_prefix, default_scope, accumulator, self_owner,
                                       singleton_cref)
        rebound = rebound_block_self(node, qualified_prefix, default_scope, nil,
                                     rebound_self_base(self_owner))
        node.rigor_each_child do |child|
          rebinds_self = rebound && child.is_a?(Prism::BlockNode)
          owner = rebinds_self ? rebound : self_owner
          # A self-rebinding block moves `self` but not `Module.nesting` — the cref flag
          # passes through unchanged, so a bare write inside `Foo.class_eval { … }`
          # under `class <<` still lands on the singleton's table and declines.
          walk_constant_writes(child, qualified_prefix, default_scope, accumulator, owner,
                               singleton_cref: singleton_cref)
        end
      end

      # Issue #705 — the class or module `self` names inside `node`'s BLOCK, or nil when `node` opens no
      # block that rebinds `self` (an ordinary block keeps the `self` it closed over, so a `self::BAR = …`
      # there is still the enclosing declaration's and every walk below this stays as it was).
      #
      # {OPAQUE_SELF} where the new `self` reaches no class or module name: a `class_eval` receiver that is
      # not a static constant path, an {OPAQUE_SELF_BLOCK_CALLS} body, and a `Class.new { … }` /
      # `Module.new` / `Struct.new` / `Data.define` block no enclosing constant write names. Declining there
      # costs a resolution the engine never had; naming the LEXICAL enclosure instead is the guess that fires,
      # because it is the one name Ruby is guaranteed NOT to have written.
      #
      # `meta_owner` is the name such a write DOES give the block's class, threaded one hop down by the
      # caller ({#meta_new_block_owner}) ([#710](https://github.com/rigortype/rigor/issues/710)). It is
      # supplied only by the publication census; the typed walk returns at a `ConstantWriteNode` without
      # descending into its rvalue, so no `self::` write inside one reaches that walk at all.
      def rebound_block_self(node, qualified_prefix, default_scope = nil, meta_owner = nil,
                             self_prefix = nil)
        return nil unless node.is_a?(Prism::CallNode) && node.block.is_a?(Prism::BlockNode)
        return OPAQUE_SELF if OPAQUE_SELF_BLOCK_CALLS.include?(node.name)
        return meta_owner || OPAQUE_SELF if meta_new_constant_rvalue?(node)
        return nil unless RECEIVER_EVAL_CALLS.include?(node.name)

        eval_receiver_self(node.receiver, qualified_prefix, default_scope, self_prefix)
      end

      # Issue #710 — the qualified name a `Klass = Class.new { … }` gives the block's class, or nil when
      # `node` is not that form. Ruby names the constructed class after the constant it is first assigned to,
      # so `self::X = 7` in the block writes `Klass::X` and nothing about it is opaque. The recognition is
      # {#meta_new_block_body}'s, shared with the block-as-method walk.
      #
      # A constant PATH write (`N::Made = Class.new { … }`) keeps the opaque answer even though that recognition
      # now takes it ([#703](https://github.com/rigortype/rigor/issues/703)). This census keys a path write AS
      # WRITTEN ({#constant_path_write_name}) rather than through the nesting, so naming the block's class here
      # would publish a `self::X = …` inside it under a name Ruby does not give it; declining suppresses the
      # name instead, which is the gradual direction. Moving it belongs with moving the census's own path key.
      #
      # Issue #963 — the `||=` spellings keep the opaque answer for the same reason the path spelling does. This
      # census records every or-write UNPUBLISHABLE (the constant may already hold something else), so naming the
      # block's class here would publish `Const::X` under a name the census has just declined to publish itself.
      # The `.freeze` spelling is a plain `ConstantWriteNode` and is taken; its tail is threaded through by
      # {#walk_constant_write_census}.
      def meta_new_block_owner(node, qualified_prefix)
        return nil unless node.is_a?(Prism::ConstantWriteNode) && meta_new_block_body(node)

        qualified_write_name(qualified_prefix, node.name.to_s)
      end

      # The `self` a `Recv.class_eval { … }` block runs under. An implicit or literal `self` receiver leaves
      # `self` where it was — nil, so nothing about the walk changes. A static constant path resolves the way
      # a path write's own namespace resolves ({#resolved_write_namespace}); anything else is opaque. A nil
      # `default_scope` is the publication census, which has no class knowledge to resolve through and keys a
      # path AS WRITTEN, so the receiver keeps its spelling there too.
      def eval_receiver_self(receiver, qualified_prefix, default_scope, self_prefix = nil)
        return nil if receiver.nil? || receiver.is_a?(Prism::SelfNode)

        # `self::X` anchors to the enclosing self — `self_prefix` carries the eval-derived
        # owner inside an eval body, so `Y.class_eval { self::X.class_eval { include T } }`
        # still resolves `Y::X`; outside one it is the lexical prefix either way. An
        # unnameable enclosing self keeps the answer opaque.
        if (tail = self_anchored_tail(receiver))
          return OPAQUE_SELF if self_prefix == OPAQUE_SELF

          prefix = self_prefix || qualified_prefix
          return collapse_object_owner(prefix + tail).join("::")
        end

        name = Source::ConstantPath.qualified_name_or_nil(receiver)
        return OPAQUE_SELF if name.nil?
        return name if default_scope.nil? || qualified_prefix.empty? || Source::ConstantPath.rooted?(receiver)

        resolved_write_namespace(name, qualified_prefix, default_scope)
      end

      # Issue #690 — `enclosing_prefix` is the lexical declaration prefix the write SITS UNDER, `full` the
      # qualified name it WRITES. The two coincide for a bare `BAR = …` and diverge for a `Foo::BAR = …`,
      # which is why they are separate parameters. One parameter served both roles, so the path form had to
      # pass it EMPTY to keep the caller-supplied name intact — and that lost the key's qualification and the
      # rvalue's lexical context together, in the same argument.
      #
      # Issue #705 — and the rvalue needs BOTH halves of the context separately as well, because a
      # `class_eval` block moves one and not the other. `Module.nesting` stays lexical, so a bare `Post` in
      # `Other.class_eval { … }` inside `module Admin` is still `Admin::Post`; `self` becomes the RECEIVER, so
      # `self` and an implicit-self call in the same block answer on `Other`. Reading the self type off
      # `enclosing_prefix` typed `self::REF = self` as `singleton(Admin)` and `self::V = build` through
      # `Admin.build` — wrong on correct code, and reachable at a reader the moment the key stopped being a
      # guess. `self_owner` is a String exactly when the walk resolved a rebound `self`.
      def record_constant_write(node, enclosing_prefix, default_scope, accumulator, full, self_owner = nil)
        owner = self_owner.is_a?(String) ? self_owner : enclosing_prefix.join("::")
        body_scope = default_scope
        unless owner.empty?
          body_scope = census_body_scope(default_scope, enclosing_prefix, Type::Combinator.singleton_of(owner))
        end
        rvalue_type = meta_new_constant_type(node, full) || body_scope.type_of(node.value)
        existing = accumulator[full]
        accumulator[full] = existing ? Type::Combinator.union(existing, rvalue_type) : rvalue_type
      end

      # The accumulator key for a `Foo::BAR = …`. Ruby resolves the path's NAMESPACE through the nesting at
      # the write site, so `Holder::DEFAULT = …` inside `module Admin` names `Admin::Holder::DEFAULT`
      # whenever `Admin::Holder` is a class or module some source declares. Filing the entry under the
      # as-written spelling put it where no read of the resolved name reaches it: a read spelled
      # `Admin::Holder::DEFAULT` answered `Dynamic[top]`, and the in-namespace spelling fell past the
      # qualified rung of the lexical ladder to the bare one, hit the mis-keyed entry, and got a top-level
      # constant of the same name — `call.undefined-method` on correct code ([#690](https://github.com/rigortype/rigor/issues/690)).
      #
      # Two static forms keep the as-written key because their namespace is not the enclosing one: a write at
      # the top level, and a rooted `::Foo::BAR`, which names the top level by definition. Re-qualifying a
      # namespace the code does not name would file the entry under a guess.
      #
      # A target that renders no static path is NOT a third such form, and must not be handled by rendering
      # it leniently. `self::BAR = …` names whatever `self` is at that point — the enclosing declaration in
      # an ordinary body, the receiver inside a `class_eval` block ([#705](https://github.com/rigortype/rigor/issues/705)),
      # which is why `self_owner` travels with the walk rather than being read off `qualified_prefix`. Any
      # other dynamic base (`klass::BAR`) is attributable to no namespace at all and is DECLINED:
      # `qualified_name`'s lenient render drops the dynamic segment and yields the bare trailing name, so
      # recording it filed a value under a name the write never touched — and once the rvalue is typed under
      # the enclosing nesting, that bare key outranks an RBS top-level constant declaration and hands every
      # reader of the top-level name a receiver Ruby never names there.
      def constant_path_write_key(target, qualified_prefix, default_scope, self_owner = nil)
        return Source::ConstantPath.qualified_name(target) if Source::ConstantPath.rooted?(target)

        written = Source::ConstantPath.qualified_name_or_nil(target)
        return dynamic_base_write_key(target, qualified_prefix, self_owner) if written.nil?
        return written if qualified_prefix.empty?

        namespace, _, base = written.rpartition("::")
        return written if namespace.empty?

        "#{resolved_write_namespace(namespace, qualified_prefix, default_scope)}::#{base}"
      end

      # The key for a path write whose base is not a static constant path: the name `self` carries for a
      # `self::BAR = …`, and nil — decline to record the write at all — for every other dynamic base.
      def dynamic_base_write_key(target, qualified_prefix, self_owner = nil)
        return nil unless (tail = self_anchored_tail(target))

        self_write_name(qualified_prefix, self_owner, tail.join("::"))
      end

      # The qualified name a `self::BAR = …` writes. `self_owner` is nil in the ordinary case — `self` is the
      # enclosing declaration, so the write takes the key a bare `BAR = …` in the same body takes — a class or
      # module name where a `class_eval`-family block rebound `self` to one, and {OPAQUE_SELF} where it
      # rebound `self` to something unnameable, which declines the write (nil) rather than filing it under a
      # namespace Ruby did not touch ([#705](https://github.com/rigortype/rigor/issues/705)).
      #
      # `Object` is the one owner that is not a namespace of its own: its constants ARE the top-level ones, and
      # every other census key spells those bare. Keying `Object::T` would file the write beside a sibling's
      # plain `T = 2` instead of on top of it, so the conflict between them goes undetected and one of the two
      # values publishes — the direction this whole issue is about.
      def self_write_name(qualified_prefix, self_owner, base)
        return qualified_write_name(qualified_prefix, base) if self_owner.nil?
        return nil if self_owner.equal?(OPAQUE_SELF)
        return base if self_owner == OBJECT_OWNER

        "#{self_owner}::#{base}"
      end

      # The namespace of a `Foo::BAR = …`, resolved the way a READ of the same spelling resolves it: the
      # first `<nesting entry>::Foo` that names a known class or module, innermost first, and the as-written
      # name when none does. Only class/module knowledge participates — a value constant owns no constants —
      # and the ancestor rung {Reflection.resolve_constant_type} walks is deliberately skipped, so a
      # namespace no source declares keeps the key it has today rather than moving to a guess.
      def resolved_write_namespace(namespace, qualified_prefix, scope)
        census_nesting(scope, qualified_prefix).each do |entry|
          candidate = "#{entry}::#{namespace}"
          return candidate if known_namespace?(candidate, scope)
        end
        namespace
      end

      # True when `name` is a class or module some source declares: a project declaration in
      # `discovered_classes` or an RBS-known class object. The [#528](https://github.com/rigortype/rigor/issues/528)
      # synthesized namespace prefixes reach that table for THIS FILE only — the runner's cross-file seed
      # (`discovered_project_index_for_paths`) returns `collect_class_decls`'s raw declarations without the
      # synthesis its sibling `discovered_classes_for_paths` applies — so a namespace known only through ANOTHER
      # file's COMPACT declaration (`class Admin::Holder::Inner`) does not move the key, where an explicit
      # `module Admin; class Holder` there does. Under-resolution, the direction this probe may err in.
      #
      # The RBS half needs no dependency edge — the loaded signature set is part of the run fingerprint — but
      # both project answers do; see {#record_namespace_probe}.
      def known_namespace?(name, scope)
        if scope.discovered_classes.key?(name)
          record_namespace_probe(name, scope, hit: true)
          return true
        end

        environment = scope.environment
        return true if !environment.nil? && !environment.singleton_for_name(name).nil?

        record_namespace_probe(name, scope, hit: false)
        false
      end

      # ADR-46 — the key this census files a path write under is a function of ANOTHER file's class
      # declarations, and no edge the READER records covers it: a reference's negative key is
      # `class:<last segment>` of the name that failed to resolve, whereas here the write's key moves because
      # a MIDDLE segment appeared (`Holder::DEFAULT` inside `module Admin` starts naming
      # `Admin::Holder::DEFAULT` the moment some file declares `Admin::Holder`). Both directions therefore
      # need their own edge, recorded where the probe happens: a POSITIVE one on the file declaring the
      # namespace we resolved through, so deleting it moves the key back, and a NEGATIVE `class:` one on
      # every candidate that missed, so declaring it later moves the key forward. Without them a warm
      # incremental run serves a cached answer computed against a namespace that has since appeared. Gated on
      # the recorder, which is off on every ordinary run.
      def record_namespace_probe(name, scope, hit:)
        return unless Analysis::DependencyRecorder.active?

        if hit
          scope.discovered_class_sources[name]&.each { |site| Analysis::DependencyRecorder.read_site(site) }
        else
          Analysis::DependencyRecorder.read_missing(:class, name.split("::").last)
        end
      end

      # Survey item (e): when the rvalue is a recognised `Module.new do ... end` / `Class.new do ... end` /
      # `Struct.new(*sym) do ... end` / `Data.define(*sym) do ... end` form, type the named constant as
      # `Singleton[<full>]` so the discovered-method table registered under `full` becomes reachable through
      # singleton-side dispatch (`Const.[]=` etc.). Returns nil for non-meta-new rvalues so the caller falls back to the
      # default `body_scope.type_of(node.value)` shape.
      def meta_new_constant_type(node, full)
        return nil unless meta_new_block_body(node)

        Type::Combinator.singleton_of(full)
      end

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
      # `walk_methods` and `walk_def_nodes` had byte-identical class / module / singleton / meta-block descents (both
      # stop at `DefNode`), so a single combined walk records both accumulators at once instead of traversing every file
      # twice.
      #
      # Issue #992 — and a third, `envelopes`: `{class_name => {[kind, method] => envelope}}`, the
      # {Source::ParameterEnvelope} of every name the existence table records, plus the class-wide
      # {Scope::DiscoveryIndex::ENVELOPE_MODULE_MARK} / {Scope::DiscoveryIndex::ENVELOPE_DYNAMIC_MARK} keys.
      # It is written by the SAME recorder that writes the existence table ({#record_method}), so a name the
      # walk learns from an `alias`, an `attr_*` or a `define_method` can never be missing from it: those
      # record {Source::ParameterEnvelope::OPAQUE}, and only a `def` records a real envelope.
      def build_methods_and_def_nodes(root, source_path = nil)
        tables = MethodTables.new({}, {})
        def_nodes = {}
        walk_methods_and_def_nodes(root, [], false, tables, def_nodes, source_path)
        apply_alias_def_nodes(root, def_nodes)
        [tables.existence.transform_values(&:freeze).freeze, def_nodes.transform_values(&:freeze).freeze,
         tables.envelopes.transform_values(&:freeze).freeze]
      end

      # The accumulator {#walk_methods_and_def_nodes} threads: the existence table and its issue #992
      # envelope twin, which only {#record_method} and {#record_surface_mark} write.
      MethodTables = Struct.new(:existence, :envelopes)

      # The walk's single existence writer. Everything except a `def` passes no envelope and so records
      # {Source::ParameterEnvelope::OPAQUE}.
      def record_method(tables, class_name, method_name, kind, envelope = Source::ParameterEnvelope::OPAQUE)
        record_method_kind(tables.existence, class_name, method_name, kind)
        record_envelope(tables.envelopes, class_name, [kind, method_name], envelope)
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
      # Combined `walk_methods` + `walk_def_nodes` descent. The two walks had identical class / module / singleton-class
      # / meta-block traversals and both stopped at `DefNode`; the only divergences are leaf actions (recorded into the
      # right accumulator) and the original `walk_methods` returning at `AliasMethodNode` (its symbol-only children
      # carry no def / class node, so not descending them is byte-identical for `def_nodes` too). See
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
          self_decl = self_anchored_decl_prefix(node.constant_path, self_base)
          child_prefix = self_decl ||
                         Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
          if child_prefix
            # Under an unnameable cref a bare/`self::` header opens `#<singleton>::Name` —
            # a class object nothing can spell — so the body walks ownerless rather
            # than filing `C::D` facts. nameable headers re-anchor at a real cref. A
            # `self::` header under a REBOUND self (eval/meta-new body) names
            # `owner::Name` instead.
            child_cref = unnameable_decl?(node, self_decl, singleton_cref)
            record_declaration_facts(node, child_prefix, methods_acc) unless child_cref
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
          walk_methods_and_def_nodes(node.expression, qualified_prefix, in_singleton_class,
                                     methods_acc, def_nodes_acc, source_path, def_owner_prefix,
                                     singleton_cref: singleton_cref,
                                     defs_singleton: defs_singleton)
          if node.body
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
          if (split = meta_new_block_split(node, qualified_prefix, def_owner_prefix, singleton_cref))
            enclosing, body, body_self = split
            # A meta-new block rebinds only `self` — `Module.nesting` stays lexical — so
            # declarations inside keep the ENCLOSING prefix and cref, while `def`-family
            # leaves record under the class the write names. An unnameable write (bare
            # `K =` under `class <<`, or a dynamic base) gives an empty owner prefix:
            # the block's class is anonymous and its defs belong to no nameable class.
            child_prefix = meta_new_child_prefix(node, qualified_prefix, def_owner_prefix)
            meta_ownerless = singleton_cref &&
                             !meta_new_path_target_nameable?(node, def_owner_prefix)
            record_meta_new_facts(meta_new_rvalue(node), child_prefix, methods_acc) if child_prefix && !meta_ownerless
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
            # enters the body under it (#590) by asking THIS recognition (`meta_new_block_body`), so the two passes
            # agree on the constant name alone.
            return
          end
        when Prism::DefNode
          # `defs_singleton` is the instance_eval split: `def`/`alias` bind on the receiver's
          # singleton while `define_method`/`attr_*` calls stay instance-side. An empty owner
          # prefix — an explicit `[]` def-owner (anonymous factory block, declined eval
          # receiver, a singleton nothing names) or any ownerless prefix under an unnameable
          # cref — is NOT top level; `record_def_node` would file the def under `<toplevel>`
          # where an implicit-self call could find a method Ruby never installed there.
          unless def_owner_prefix&.empty? || defs_singleton == :unnameable ||
                 (singleton_cref && owner_prefix.empty?)
            singleton_def = in_singleton_class || defs_singleton
            record_def_method(node, owner_prefix, singleton_def, methods_acc)
            record_def_body_evidence(node, owner_prefix, methods_acc)
            record_def_node(node, owner_prefix, singleton_def, def_nodes_acc)
          end
          return
        when Prism::AliasMethodNode, Prism::UndefNode
          unless def_owner_prefix&.empty? || defs_singleton == :unnameable ||
                 (singleton_cref && owner_prefix.empty?)
            record_alias_or_undef(node, owner_prefix, in_singleton_class || defs_singleton,
                                  methods_acc)
          end
          return
        when Prism::CallNode
          if receiver_eval_call?(node)
            return walk_eval_methods_and_defs(node, qualified_prefix, in_singleton_class, methods_acc,
                                              def_nodes_acc, source_path, def_owner_prefix,
                                              singleton_cref: singleton_cref,
                                              defs_singleton: defs_singleton)
          end
          anonymous = record_call_node_methods(node, owner_prefix, in_singleton_class, methods_acc, source_path)
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
        unnameable = unnameable_eval_self?(in_singleton_class, def_owner_prefix, qualified_prefix,
                                           singleton_cref)
        eval_prefix = eval_receiver_prefix(node, self_prefix, qualified_prefix,
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
        else
          record_surface_mark(tables, child_prefix.join("::"), Scope::DiscoveryIndex::ENVELOPE_MODULE_MARK)
        end
      end

      # The block form of a meta-new constant write: its members, and the module mark `Module.new` earns.
      def record_meta_new_facts(rvalue, child_prefix, tables)
        record_meta_members(rvalue, child_prefix, tables)
        return unless module_new_call?(rvalue)

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
        record_attr_methods(node, qualified_prefix, in_singleton_class, methods_acc) if ATTR_MACROS.include?(node.name)
        record_module_attr_methods(node, qualified_prefix, methods_acc) if MODULE_ATTR_MACROS.key?(node.name)
        record_alias_method_call(node, qualified_prefix, in_singleton_class, methods_acc)
        record_surface_evidence(node, qualified_prefix, methods_acc)
        AnonymousMetaClass.name_for(node, source_path)
      end

      # The `alias_method :new, :old` CallNode twin of {#record_alias_method} (#533): the NEW name joins
      # the discovered-methods table so calls to it stop reading undefined, and
      # {#apply_alias_def_nodes}'s map walk gives it the ORIGINAL def node for return inference.
      def record_alias_method_call(call_node, qualified_prefix, in_singleton_class, accumulator)
        return if qualified_prefix.empty?

        names = alias_method_call_names(call_node)
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
        record_meta_members(call_node, [name], methods_acc)
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

        # Same lexical rule {eval_receiver_prefix} applies: `class << Y` resolves `Y`
        # through the write site's nesting, never through the eval-derived self —
        # `class << Y` inside `M::Y.class_eval` at top level opens the TOP-LEVEL `Y`'s
        # singleton.
        eval_constant_receiver_prefix(node, node.expression, rendered, lexical_prefix)
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

      # v0.1.2 — when a `Const = Data.define(*sym) do ... end` / `Const = Struct.new(*sym) do ... end` constant write
      # carries a block, the block body holds method overrides whose canonical class is `Const`. Survey item (e)
      # extended the recognition to `Const = Module.new do ... end` and `Const = Class.new(?super) do ... end` — the
      # ADR-16 Tier A "block-as-method" idiom at constant-write position. Returns the block body node (a
      # `Prism::StatementsNode`) when the rvalue matches; nil otherwise. Used by `walk_methods` / `walk_def_nodes` to
      # push `Const` onto the qualified prefix before recursing.
      #
      # Issue [#703](https://github.com/rigortype/rigor/issues/703) — a PATH write is the same idiom.
      # `Holder::Thing = Struct.new(:a) do … end` inside a module is ordinary Ruby, and declining it here lost the
      # factory registration, the member layout and the block's own defs together: the constant answered
      # `singleton(Struct)` and its instance `Struct`, a class RBS knows, so every member read and every override
      # call fired `call.undefined-method` on code Ruby runs. The name the write gives the class is
      # {#meta_new_child_prefix}'s, so every walk that pushes it agrees.
      #
      # Issue [#963](https://github.com/rigortype/rigor/issues/963) — the spelling of the WRITE and the tail of the
      # rvalue are both incidental to the idiom, and both were load-bearing here. `Const = Struct.new(:a) do … end`
      # was recognised while `Const ||= Struct.new(:a) do … end` and `Const = Struct.new(:a) do … end.freeze` were
      # not, so the same body was walked as a class body in one spelling and left in the enclosing scope in the
      # other two. {#meta_new_block_call} owns both unwrappings; every walk asks it, so no spelling can be
      # recognised by one pass and missed by another.
      def meta_new_block_body(node)
        meta_new_block_call(node)&.block&.body
      end

      # The class-creating call a constant write's rvalue ultimately is, or nil when the write is not the idiom.
      # The single recognition point for {#meta_new_block_body} and every caller that needs the CALL rather than
      # its body — `StatementEvaluator#eval_constant_write` enters the block through it, so the evaluator and the
      # index cannot disagree about which node opened the class body.
      def meta_new_block_call(node)
        rvalue = meta_new_rvalue(node)
        return nil unless rvalue.is_a?(Prism::CallNode) && meta_new_constant_rvalue?(rvalue)

        rvalue
      end

      # The four constant-write spellings that name the class their rvalue creates. `Const ||= …` is the
      # define-once idiom: where the constant is unset — the case the program is written for — Ruby evaluates the
      # rvalue and names the class `Const`, exactly as the plain write does. `&&=` and the operator writes are NOT
      # here: neither names a freshly created class.
      #
      # The six whole-tree walks that recognise the idiom spell these four classes out in their `when` arms rather
      # than splatting this list: `when *ARRAY` copies the array on EVERY evaluation, and the arms are evaluated once
      # per AST node per walk, which cost `rigor check lib` about 2.3M allocations (+10%) when they were splatted.
      # This list is for the `is_a?` scans; keep the arms and the list in step.
      META_CONSTANT_WRITE_NODES = [
        Prism::ConstantWriteNode,
        Prism::ConstantPathWriteNode,
        Prism::ConstantOrWriteNode,
        Prism::ConstantPathOrWriteNode
      ].freeze
      private_constant :META_CONSTANT_WRITE_NODES

      # The rvalue a recognised constant write assigns, with the two value-preserving wrappers stripped: a
      # `.freeze` tail (`Struct.new(:a) do … end.freeze` — `Module#freeze` returns the receiver, so the constant
      # still holds the class the call created) and a `Const = Const || Struct.new(…)` guard, the long spelling of
      # `||=`. Nil when `node` is not a constant write at all.
      def meta_new_rvalue(node)
        return nil unless META_CONSTANT_WRITE_NODES.any? { |kind| node.is_a?(kind) }

        unwrap_freeze_tail(unwrap_or_guard(node, node.value))
      end

      # `Const = Const || <rvalue>` carries the same meaning as `Const ||= <rvalue>`, and only when the guarded
      # name is the constant being written: `A = B || Struct.new(:x)` may hold `B`, whose class `A` does not name.
      def unwrap_or_guard(node, value)
        return value unless value.is_a?(Prism::OrNode)

        written = meta_constant_write_name(node)
        return value if written.nil?

        Source::ConstantPath.qualified_name_or_nil(value.left) == written ? value.right : value
      end

      # A `.freeze` tail, repeated (`freeze.freeze` is legal and idempotent). Only the receiverful, argumentless,
      # blockless call is unwrapped — anything else is a different method that may return a different object.
      # `&.freeze` is declined with them: its value is the receiver OR nil, and a rule that answers "the constant
      # holds the class the factory made" must not be stated over a shape whose value can be nil.
      def unwrap_freeze_tail(value)
        value = value.receiver while freeze_tail?(value)
        value
      end

      def freeze_tail?(value)
        value.is_a?(Prism::CallNode) && value.name == :freeze && !value.safe_navigation? &&
          value.receiver && value.arguments.nil? && value.block.nil?
      end

      # The name a recognised constant write assigns, as written (`Const`, `Holder::Thing`). Used only to compare
      # a `Const = Const || …` guard against its own target.
      def meta_constant_write_name(node)
        case node
        when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode then node.name.to_s
        when Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode
          Source::ConstantPath.qualified_name_or_nil(node.target)
        end
      end

      # The qualified prefix a meta-new constant write names its class under, given the lexical prefix the write
      # sits in — the segments every scope-free pre-pass pushes before descending into the block, and the key
      # {#record_meta_new_constant?} files the discovered class under. Nil for a target that is neither form.
      #
      # A PATH write takes exactly what a compact `class Holder::Thing` header at the same position takes
      # ({Source::ConstantPath.declaration_prefix}), rooted reset included. These pre-passes run before any scope
      # exists, so the namespace cannot be resolved the way {#constant_path_write_key} resolves it for the typed
      # table — but the two land on the same name anyway, because registering `Admin::Holder::Thing` here is what
      # makes `Admin::Holder` a namespace {#resolved_write_namespace} knows.
      #
      # Where the namespace is NOT under the enclosure — a top-level `Loner` written as `Loner::Made = Struct.new(…)`
      # inside `module Admin` — that qualification is a guess, and {#synthesize_namespace_prefixes} then answers a
      # read of `Loner` there with the `Admin::Loner` it invented. That is the same answer the equivalent
      # `class Loner::Made` header has always produced, from the same two functions: the two spellings of one
      # declaration stay consistent rather than one of them carrying a second approximation of its own.
      #
      # Issue #963 — `Const ||= …` names its class exactly as `Const = …` does, so the two or-write spellings take
      # the branch of the write shape they are the conditional form of.
      # `self_base` names the rebound self for a `self::`-anchored target — inside a
      # meta-new block `self` is the class the write names, so `self::X = Class.new`
      # opens `K::X`, not the lexical `X`.
      def meta_new_child_prefix(node, qualified_prefix, self_base = nil)
        case node
        when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode
          qualified_prefix + [node.name.to_s]
        when Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode
          target = node.target
          if self_anchored_tail(target)
            # A `self::` target anchors on the rebound self when one is named; nil
            # `self_base` means `self` IS the lexical enclosure, so the lenient render
            # is the right name — `self::S = Class.new` inside `class C` is `C::S`.
            self_anchored_decl_prefix(target, self_base) ||
              (self_base.nil? &&
               Source::ConstantPath.declaration_prefix(qualified_prefix, target))
          else
            # Any other base must render a real constant path — `var::K = Class.new`
            # writes whatever `var` holds, a class no source spelling reaches, so the
            # lenient `declaration_prefix` render (`C::K`) would be a name the write
            # never produced.
            Source::ConstantPath.qualified_name_or_nil(target) &&
              Source::ConstantPath.declaration_prefix(qualified_prefix, target)
          end
        end
      end

      # {#meta_new_child_prefix} for the walks that only care about a write carrying a BLOCK — nil where the rvalue
      # opens none, so a block-less `Thing = Struct.new(:a)` keeps falling through to the ordinary child descent.
      def meta_new_body_prefix(node, qualified_prefix, self_base = nil)
        meta_new_block_body(node) && meta_new_child_prefix(node, qualified_prefix, self_base)
      end

      # The three contexts a `K = Class.new { … }`-shaped write hands its children: the
      # factory call's receiver and arguments evaluate in the ENCLOSING self and cref —
      # the write has not landed yet — while the block body's `self` is the class the
      # write names (`child_prefix`, or `[]` when the write names nothing below an
      # unnameable cref or a dynamic base) and its `Module.nesting` stays lexical.
      # Returns `[enclosing_parts, body, body_self]`; nil when the rvalue opens no
      # recognised meta-new block. `self_base` names a rebound enclosing self for a
      # `self::` write target.
      def meta_new_block_split(node, qualified_prefix, self_base, singleton_cref)
        call = meta_new_block_call(node)
        return nil unless call

        child_prefix = meta_new_child_prefix(node, qualified_prefix, self_base)
        body_self =
          if singleton_cref && !meta_new_path_target_nameable?(node, self_base)
            []
          else
            child_prefix || []
          end
        enclosing = [call.receiver, *call.arguments&.arguments.to_a].compact
        [enclosing, meta_new_block_body(node), body_self]
      end

      # The three values an eval-family block gives a leaf walk: the receiver and arguments
      # that keep the enclosing context, the block body, and the rebound self's prefix —
      # `[]` when the receiver names nothing. `def`-family leaves and `self::` declarations
      # anchor on the third value while `Module.nesting` stays lexical, so the walk keeps
      # `qualified_prefix` for declarations and swaps only the def-owner channel.
      def eval_block_split(node, qualified_prefix, self_owner, singleton_cref)
        return nil unless receiver_eval_call?(node)

        self_prefix = self_owner || qualified_prefix
        unnameable = unnameable_eval_self?(false, self_owner, qualified_prefix,
                                           singleton_cref)
        eval_prefix = eval_receiver_prefix(node, self_prefix, qualified_prefix,
                                           unnameable_self: unnameable) || []
        # An unnameable enclosing self — a `class <<` body, an ownerless eval or factory
        # block — means a bare/`self`/`self::` receiver names nothing these leaf tables can
        # key on; `eval_receiver_prefix` still answers `self_prefix` for the bare form, so
        # the ownerless marker is applied here.
        eval_prefix = EMPTY_PREFIX if unnameable && !eval_named_receiver?(node)
        [[node.receiver, *node.arguments&.arguments.to_a].compact, node.block.body, eval_prefix]
      end

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
      # diagnostic on correct code. No-op for `Class.new` / `Module.new` and for a factory whose members are not
      # literal Symbols (nothing to register).
      def record_meta_members(factory_call, qualified_prefix, accumulator, allow_outer_block: true)
        factory_call = resolve_meta_factory_call(factory_call, allow_outer_block: allow_outer_block)
        return unless factory_call

        members = meta_member_names(factory_call)
        return if members.empty?

        class_name = qualified_prefix.join("::")
        members.each { |member| record_method(accumulator, class_name, member, :instance) }
      end

      # Unwinds nested single-parent `Class.new(...)` calls to a root `Struct.new(...)` / `Data.define(...)`.
      # A nested wrapper or factory block is declined because its method overrides belong to the intermediate
      # superclass and cannot be attributed to the outer class's reader-override guard.
      def resolve_meta_factory_call(call_node, allow_outer_block: true)
        wrapped = false
        while class_new_call?(call_node)
          return nil if intermediate_factory_block?(call_node, wrapped, allow_outer_block)

          arguments = call_node.arguments&.arguments
          return nil unless arguments&.one?

          call_node = arguments.first
          wrapped = true
        end
        return nil unless meta_factory_call?(call_node)
        return nil if intermediate_factory_block?(call_node, wrapped, allow_outer_block)

        call_node
      end

      def intermediate_factory_block?(call_node, wrapped, allow_outer_block)
        (wrapped || !allow_outer_block) && !call_node.block.nil?
      end

      def meta_factory_call?(call_node)
        data_define_call?(call_node) || struct_new_call?(call_node)
      end

      # The Symbol member names of a `Data.define(*Symbol)` / `Struct.new(*Symbol [, keyword_init:])` call. For
      # `Struct.new` the trailing `keyword_init:` hash is stripped by {#struct_new_positionals}; a leading
      # String class name is NOT stripped, so `Struct.new("Name", :a) do` registers no members and the body
      # is entered under the anonymous name (consistent between passes). `Data.define` args are all Symbols.
      def meta_member_names(call_node)
        raw = call_node.arguments&.arguments || []
        symbols = struct_new_call?(call_node) ? (struct_new_positionals(raw) || []) : raw
        symbols.filter_map { |arg| arg.unescaped.to_sym if arg.is_a?(Prism::SymbolNode) }
      end

      def record_def_method(def_node, qualified_prefix, in_singleton_class, accumulator)
        return if qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        singleton = def_singleton?(def_node, qualified_prefix, in_singleton_class)
        kind = singleton ? :singleton : :instance
        record_method(accumulator, class_name, def_node.name, kind, Source::ParameterEnvelope.of(def_node))
      end

      # Issue #992 — the rewriting calls a METHOD BODY makes, which the declaration walk never descends into:
      # `def self.inherited(sub) = sub.class_eval { … }`, `def self.wrap_all = define_method(…)`,
      # `def decorate(obj) = obj.extend(Decorator)`. A class-body macro records the same evidence in
      # {#record_surface_evidence}; `send` is left out here because inside a body it is an ordinary call far
      # more often than a definition.
      def record_def_body_evidence(def_node, qualified_prefix, tables)
        return if def_node.body.nil?

        Source::NodeWalker.each(def_node.body) do |node|
          next unless node.is_a?(Prism::CallNode)

          if node.name == :extend
            record_object_extension(node, qualified_prefix, tables)
          elsif SURFACE_EVAL_CALLS.include?(node.name) || SURFACE_NAMING_CALLS.include?(node.name)
            record_body_rewrite(node, qualified_prefix, tables)
          end
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

      # `def Foo.bar` inside `module Foo` (or `def Meta.init` inside `module Meta`) is semantically equivalent to `def
      # self.bar`: at the def-site, the runtime value of the constant `Foo` is the module itself (== `self`). Recognise
      # the form so the method registers as singleton on the enclosing class.
      #
      # The cross-class form `def Bar.baz` inside `module Foo` — where the receiver names a constant other than the
      # enclosing class — is not supported at this slice; falls through to `:instance` (current behaviour) rather than
      # silently re-routing the registration.
      def def_singleton?(def_node, qualified_prefix, in_singleton_class)
        return true if def_node.receiver.is_a?(Prism::SelfNode) || in_singleton_class

        def_receiver_targets_lexical_self?(def_node.receiver, qualified_prefix)
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

      def record_def_node(def_node, qualified_prefix, in_singleton_class, accumulator)
        return if def_singleton?(def_node, qualified_prefix, in_singleton_class)

        class_name = qualified_prefix.empty? ? TOP_LEVEL_DEF_KEY : qualified_prefix.join("::")
        accumulator[class_name] ||= {}
        accumulator[class_name][def_node.name] = def_node
        record_anonymous_body_def_as_toplevel(def_node, qualified_prefix, accumulator)
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
      def record_anonymous_body_def_as_toplevel(def_node, qualified_prefix, accumulator)
        return unless qualified_prefix.length == 1
        return unless Type::AnonymousClassName.match?(qualified_prefix.first)

        table = (accumulator[TOP_LEVEL_DEF_KEY] ||= {})
        table[def_node.name] ||= def_node
      end

      # Module-singleton call resolution (ADR-57 follow-up) — the SINGLETON-side mirror of `build_discovered_def_nodes`.
      # Records the `Prism::DefNode` for every singleton-side method (`def self.x`, `def Foo.x`, a `class << self` body,
      # and a `module_function` method) keyed by qualified class/module name → method → node, so `ExpressionTyper` can
      # re-type the body when a `Singleton[Foo]` receiver dispatches `Foo.x`. The instance-side table is kept
      # singleton-free on purpose (its ancestor walk binds `self` as `Nominal`), so the two never overlap except for
      # `module_function` defs, which are genuinely callable on both sides and so appear in both tables. Top-level
      # singleton defs (`def self.x` outside any class — `self` is `main`) are not recorded; they have no constant
      # receiver to dispatch through.
      def build_discovered_singleton_def_nodes(root)
        accumulator = {}
        walk_singleton_def_nodes(root, [], false, accumulator)
        accumulator.transform_values(&:freeze).freeze
      end

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
      # The two position-keyed per-file indexes: the def / block / lambda body ranges issue #1097's
      # `*_def_shadows_call?` predicates order a same-name def against, and the class-declaration
      # sites `record_class_sources` accumulates.
      def record_file_positions(acc, path, root, superclasses, includes, file_def_nodes)
        acc[:deferred_ranges][path] = build_deferred_ranges(root)
        record_class_sources(acc[:class_sources], path, root, superclasses, includes, file_def_nodes,
                             acc[:compact_headers])
      end

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
      def walk_deferred_ranges(node, qualified_prefix, in_singleton_class, inside_deferred, # rubocop:disable Metrics/ParameterLists
                               mf_offsets, ranges, def_owner_prefix = nil, singleton_cref: false,
                               defs_singleton: false)
        return unless node.is_a?(Prism::Node)

        if CLASS_BODY_NODES.any? { |kind| node.is_a?(kind) }
          return walk_deferred_lexical_body(node, qualified_prefix, in_singleton_class,
                                            inside_deferred, mf_offsets, ranges, def_owner_prefix,
                                            singleton_cref: singleton_cref)
        end
        if META_WRITE_NODES.any? { |kind| node.is_a?(kind) }
          return walk_deferred_meta_new(node, qualified_prefix, in_singleton_class, inside_deferred,
                                        mf_offsets, ranges, def_owner_prefix,
                                        singleton_cref: singleton_cref)
        end
        if node.is_a?(Prism::DefNode)
          return walk_deferred_def_leaf(node, qualified_prefix, in_singleton_class, inside_deferred,
                                        mf_offsets, ranges, def_owner_prefix, singleton_cref,
                                        defs_singleton)
        end
        if DEFERRED_RANGE_NODES.any? { |kind| node.is_a?(kind) }
          # Deferred: a call inside runs at invocation / interpreter-exit time. `BEGIN`
          # (PreExecutionNode) is the opposite — eager, before the class body — and stays unlisted.
          ranges << [node.location.start_offset, node.location.end_offset, nil, nil, nil]
          return walk_deferred_children(node, qualified_prefix, in_singleton_class, true, mf_offsets,
                                        ranges, def_owner_prefix, singleton_cref: singleton_cref,
                                                                  defs_singleton: defs_singleton)
        end
        if node.is_a?(Prism::CallNode) && receiver_eval_call?(node)
          return walk_eval_block_call(node, qualified_prefix, in_singleton_class, inside_deferred,
                                      mf_offsets, ranges, def_owner_prefix,
                                      singleton_cref: singleton_cref)
        end

        walk_deferred_children(node, qualified_prefix, in_singleton_class, inside_deferred,
                               mf_offsets, ranges, def_owner_prefix, singleton_cref: singleton_cref,
                                                                     defs_singleton: defs_singleton)
      end

      # The `def` arm of {#walk_deferred_ranges}: records the range row — singleton-side when the
      # def sits in a `class <<` body or an `instance_eval` block (`defs_singleton`) — then walks
      # the body as a deferred range.
      def walk_deferred_def_leaf(node, qualified_prefix, in_singleton_class, inside_deferred, # rubocop:disable Metrics/ParameterLists
                                 mf_offsets, ranges, def_owner_prefix, singleton_cref,
                                 defs_singleton)
        owner = defs_singleton == :unnameable ? EMPTY_PREFIX : (def_owner_prefix || qualified_prefix)
        record_deferred_def(node, owner, in_singleton_class || defs_singleton, inside_deferred,
                            mf_offsets, ranges)
        walk_deferred_children(node, qualified_prefix, in_singleton_class, true, mf_offsets,
                               ranges, def_owner_prefix, singleton_cref: singleton_cref,
                                                         defs_singleton: defs_singleton)
      end

      DEFERRED_RANGE_NODES = [Prism::BlockNode, Prism::LambdaNode, Prism::PostExecutionNode].freeze
      META_WRITE_NODES = [Prism::ConstantWriteNode, Prism::ConstantPathWriteNode,
                          Prism::ConstantOrWriteNode, Prism::ConstantPathOrWriteNode].freeze
      CLASS_BODY_NODES = [Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze
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

        self_decl = self_anchored_decl_prefix(node.constant_path,
                                              in_singleton_class ? EMPTY_PREFIX : def_owner_prefix)
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
        child_cref = unnameable_decl?(node, self_decl, singleton_cref)
        prefix = child_cref ? [] : child_prefix
        return unless node.body

        walk_deferred_body(node.body, prefix, false, inside_deferred, ranges, nil,
                           singleton_cref: child_cref)
      end

      def walk_deferred_meta_new(node, qualified_prefix, in_singleton_class, inside_deferred, # rubocop:disable Metrics/ParameterLists
                                 mf_offsets, ranges, def_owner_prefix = nil, singleton_cref: false,
                                 defs_singleton: false)
        call = meta_new_block_call(node)
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
        child_prefix = meta_new_child_prefix(node, qualified_prefix, def_owner_prefix)
        meta_ownerless = singleton_cref && !meta_new_path_target_nameable?(node, def_owner_prefix)
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
        walk_deferred_body(meta_new_block_body(node), qualified_prefix, false, inside_deferred, ranges,
                           body_self, singleton_cref: singleton_cref)
      end

      # Body-level entry for a class / module / `class <<` / meta-`new` / eval-block body: prescans
      # the body's `module_function` state first ({#collect_module_function_state} — bare-call
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
          collect_module_function_state(body, prescan_owner, in_singleton_class, mf_offsets,
                                        ranges)
        end
        statements_of(body).each do |stmt|
          walk_deferred_ranges(stmt, qualified_prefix, in_singleton_class, inside_deferred,
                               mf_offsets, ranges, def_owner_prefix, singleton_cref: singleton_cref,
                                                                     defs_singleton: defs_singleton)
        end
      end

      # The `module_function` prescan over one body's subtree: bare-call offsets (defs starting after
      # one are module functions), a `:singleton` row at each `module_function :name` call — the
      # retro-install happens AT THE CALL, not the def — and a `:both` / `:singleton` row for a
      # `module_function def x` argument. Nested class / module / `class <<` / def bodies are skipped:
      # `module_function` there targets a different module. An `END` body is skipped too — it runs at
      # interpreter exit, after every def — and so is a `*_eval` / `*_exec` block, whose `self`
      # rebinds to the receiver's module. Blocks, lambdas and control-flow containers are entered —
      # their `self` is still this module, so the call really can toggle.
      def collect_module_function_state(node, qualified_prefix, in_singleton_class, mf_offsets, ranges)
        return unless node.is_a?(Prism::Node)
        return if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode) ||
                  node.is_a?(Prism::SingletonClassNode) || node.is_a?(Prism::DefNode) ||
                  node.is_a?(Prism::PostExecutionNode)

        if node.is_a?(Prism::CallNode)
          if module_function_toggle?(node)
            return collect_module_function_call(node, qualified_prefix, in_singleton_class,
                                                mf_offsets, ranges)
          end
          if receiver_eval_call?(node)
            return collect_eval_call_state(node, qualified_prefix, in_singleton_class, mf_offsets,
                                           ranges)
          end
        end

        node.rigor_each_child do |child|
          collect_module_function_state(child, qualified_prefix, in_singleton_class, mf_offsets, ranges)
        end
      end

      # The prescan's eval arm: a `*_eval` / `*_exec` block's self rebinds to the receiver's module,
      # so only the call's receiver and arguments keep this module's `module_function` context.
      def collect_eval_call_state(node, qualified_prefix, in_singleton_class, mf_offsets, ranges)
        if node.receiver
          collect_module_function_state(node.receiver, qualified_prefix, in_singleton_class,
                                        mf_offsets, ranges)
        end
        node.arguments&.arguments&.each do |arg|
          collect_module_function_state(arg, qualified_prefix, in_singleton_class, mf_offsets,
                                        ranges)
        end
      end

      # The wider form: any call whose block rebinds `self` to the receiver — `instance_eval` and
      # `instance_exec` included. Walks that read `self`-anchored facts use this gate; walks that
      # own `def` leaves additionally split on {INSTANCE_EVAL_CALLS}, whose `def`s bind on the
      # receiver's singleton rather than the receiver.
      def receiver_eval_call?(node)
        node.block.is_a?(Prism::BlockNode) && RECEIVER_EVAL_CALLS.include?(node.name)
      end

      def collect_module_function_call(node, qualified_prefix, in_singleton_class, mf_offsets, ranges)
        if bare_module_function?(node)
          mf_offsets << node.location.start_offset
        else
          owner = qualified_prefix.empty? ? nil : qualified_prefix.join("::")
          node.arguments&.arguments&.each do |arg|
            if arg.is_a?(Prism::DefNode)
              kind = def_singleton?(arg, qualified_prefix, in_singleton_class) ? :singleton : :both
              ranges << [arg.location.start_offset, arg.location.end_offset, arg.name, kind, owner]
            elsif (name = symbol_argument_name(arg))
              ranges << [node.location.start_offset, node.location.end_offset, name, :singleton, owner]
            else
              collect_module_function_state(arg, qualified_prefix, in_singleton_class, mf_offsets,
                                            ranges)
            end
          end
        end
        return unless node.block

        collect_module_function_state(node.block, qualified_prefix, in_singleton_class, mf_offsets,
                                      ranges)
      end

      # A `class_eval` / `module_eval` / `class_exec` / `module_exec` block is NOT deferred: it runs
      # eagerly during the receiver's call, as a class-ish body — its `module_function` state gets
      # its own prescan, and its defs belong to the RECEIVER's surface. A nameable receiver gives
      # the body that owner ({#eval_receiver_prefix}); anything else is walked ownerless so its
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
        unnameable = unnameable_eval_self?(in_singleton_class, def_owner_prefix, qualified_prefix,
                                           singleton_cref)
        eval_prefix = eval_receiver_prefix(node, self_prefix, qualified_prefix,
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

      # The owner an eval-family block body evaluates under, given the enclosing body's SELF
      # prefix — `def_owner_prefix || qualified_prefix` at the call sites, because `self`
      # inside an eval body is the enclosing eval's receiver, not the lexical class — and the
      # LEXICAL prefix, which answers the constant-receiver case: constant lookup in an eval
      # body stays lexical, so `Y.class_eval` written inside `M::Y.class_eval` at top level
      # re-opens the TOP-LEVEL `Y`, never `M::Y` again (a class is not a member of its own
      # constant table). A bare or `self` receiver keeps the enclosing self — `class_eval`'s
      # self IS the block's self — and a constant receiver names its own class, the same
      # convention {singleton_class_prefix} applies to `class <<`. A receiver that renders no
      # static path — a variable, a call, a dynamic-base `expr::Bar` — is DECLINED like
      # {constant_path_write_key} declines dynamic write targets: `qualified_name`'s lenient
      # render would drop the dynamic segment and file the body's defs under a class the eval
      # never opened.
      def eval_receiver_prefix(node, self_prefix, lexical_prefix, unnameable_self: false)
        receiver = node.receiver
        return self_prefix if receiver.nil? || receiver.is_a?(Prism::SelfNode)

        # `self::Foo` / `self::Foo::Bar` names the enclosing self's path — the same
        # resolution {constant_path_write_key} gives a `self::` write target. When the
        # enclosing self names nothing ({#unnameable_eval_self?}) the read raises
        # NameError at runtime unless the constant lives on that self — so the receiver
        # declines rather than filing the body under the lexical class.
        if (tail = self_anchored_tail(receiver))
          return nil if unnameable_self

          return collapse_object_owner(self_prefix + tail)
        end

        rendered = Source::ConstantPath.qualified_name_or_nil(receiver)
        return nil unless rendered

        eval_constant_receiver_prefix(node, receiver, rendered, lexical_prefix)
      end

      # The tail of {#eval_receiver_prefix} once the receiver renders a static
      # constant name — also the `class << Y` operand's resolution
      # ({#singleton_class_prefix}), which follows the same lexical rule.
      #
      # A `::`-rooted receiver names the top level — `::B` inside `class A::B`
      # is still `B`, so the root check precedes both the self-reopen shortcut
      # and the lexical walk ({Source::ConstantPath}'s contract: callers doing
      # Ruby's lexical constant lookup MUST consult `rooted?` out of band). An
      # unqualified (or partially-qualified) receiver then resolves through
      # `Module.nesting` — `X` inside `class S` names `S::X` whenever that
      # constant exists — so the first `<nesting entry>::X` the file declares
      # wins, innermost first, and the as-written name stands when no rung
      # declares it: the same `<entry>::<first segment>` walk
      # {resolved_write_namespace} performs for a `Foo::BAR = …` namespace,
      # against the same segment-approximation {lexical_nesting_for_prefix}
      # gives when no scope carries the real chain. A `S::X` declared only in
      # ANOTHER file still resolves as-written — the set
      # {#eval_file_declared_names} consults is the defining file's own answer,
      # matching the `in_source_constants` limitation {resolved_write_namespace}
      # documents.
      def eval_constant_receiver_prefix(node, path_node, rendered, lexical_prefix)
        # `class << ::X = expr` spells its root on the write's target, not the
        # write node itself.
        path_node = path_node.target if path_node.is_a?(Prism::ConstantPathWriteNode)
        return rendered.split("::") if Source::ConstantPath.rooted?(path_node)
        return rendered.split("::") if lexical_prefix.empty?
        return lexical_prefix if lexical_prefix.last == rendered

        segments = rendered.split("::")
        declared = eval_file_declared_names(node)
        lexical_nesting_for_prefix(lexical_prefix).each do |entry|
          candidate = "#{entry}::#{segments.first}"
          return candidate.split("::") + segments[1..] if declared.include?(candidate)
        end
        segments
      end

      # The file's declared-constant oracle {eval_constant_receiver_prefix}
      # consults: every class/module declaration plus constant write the file
      # contains, expanded to every enclosing prefix (declaring `S::A::B`
      # proves `S::A` exists). Memoized on the `Prism::Source` every node's
      # location shares — threading the set through the dozen eval-consuming
      # walks would dwarf the resolution it feeds, so the one re-parse this
      # needs happens once per file. The memo lives in an ivar ON the source
      # (rather than a WeakMap keyed on it): the entry's lifetime is the
      # parse's own, nothing mutable sits in a constant, and a worker parsing
      # the same text gets its own source and its own set.
      def eval_file_declared_names(node)
        source = node.location.send(:source)
        source.instance_variable_get(:@rigor_declared_names) ||
          source.instance_variable_set(:@rigor_declared_names, begin
            names = Set.new
            collect_declared_constant_names(Prism.parse(source.source).value, [], names)
            names.freeze
          end)
      end

      # The walk behind {eval_file_declared_names}: every qualified constant
      # name a declaration introduces, `class`/`module`/`class <<` bodies and
      # `Const = …` writes alike. Deliberately NOT {collect_class_decls} —
      # that walk resolves eval receivers through {eval_receiver_prefix},
      # which consults this oracle and would reenter it mid-build; this one
      # never asks the question it feeds. `def` bodies cannot contain constant
      # declarations (a `class`/`X =` inside one is a SyntaxError), so they
      # are skipped outright. Under an unnameable cref (`class <<`, an
      # anonymous factory block) bare and `self::` declarations name nothing —
      # the same refusal the discovery walks make — while explicit-base paths
      # still re-anchor lexically.
      def collect_declared_constant_names(node, qualified_prefix, names, unnameable_cref: false)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          return collect_declared_class_decl(node, qualified_prefix, names, unnameable_cref)
        when Prism::SingletonClassNode
          collect_declared_constant_names(node.expression, qualified_prefix, names,
                                          unnameable_cref: unnameable_cref)
          return collect_declared_constant_names(node.body, qualified_prefix, names,
                                                 unnameable_cref: true)
        when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode,
             Prism::ConstantAndWriteNode, Prism::ConstantOperatorWriteNode
          return collect_declared_bare_write(node, qualified_prefix, names, unnameable_cref)
        when Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode,
             Prism::ConstantPathAndWriteNode, Prism::ConstantPathOperatorWriteNode
          return collect_declared_path_write(node, qualified_prefix, names, unnameable_cref)
        when Prism::ConstantTargetNode
          add_declared_name(names, (qualified_prefix + [node.name.to_s]).join("::")) unless unnameable_cref
          return
        when Prism::DefNode
          return
        when Prism::CallNode
          return if collect_declared_anonymous_factory?(node, qualified_prefix, names,
                                                        unnameable_cref)
        end
        node.compact_child_nodes.each do |child|
          collect_declared_constant_names(child, qualified_prefix, names,
                                          unnameable_cref: unnameable_cref)
        end
      end

      # The `class`/`module` arm of {collect_declared_constant_names}: the
      # header's own qualified name plus the body under it.
      def collect_declared_class_decl(node, qualified_prefix, names, unnameable_cref)
        prefix = declared_constant_path_prefix(node.constant_path, qualified_prefix,
                                               unnameable_cref)
        add_declared_name(names, prefix.join("::")) if prefix
        if node.is_a?(Prism::ClassNode)
          collect_declared_constant_names(node.superclass, qualified_prefix, names,
                                          unnameable_cref: unnameable_cref)
        end
        collect_declared_constant_names(node.body, prefix || qualified_prefix, names,
                                        unnameable_cref: unnameable_cref)
      end

      # The bare `CONST =` arm of {collect_declared_constant_names}: the write
      # lands on the enclosing cref, so an unnameable one declines the name.
      def collect_declared_bare_write(node, qualified_prefix, names, unnameable_cref)
        prefix = qualified_prefix + [node.name.to_s]
        add_declared_name(names, prefix.join("::")) unless unnameable_cref
        collect_rvalue_declared_names(node.value, prefix, qualified_prefix, names,
                                      unnameable_cref)
      end

      # The `Path::CONST =` arm of {collect_declared_constant_names}.
      def collect_declared_path_write(node, qualified_prefix, names, unnameable_cref)
        prefix = declared_constant_write_prefix(node.target, qualified_prefix,
                                                unnameable_cref)
        add_declared_name(names, prefix.join("::")) if prefix
        collect_rvalue_declared_names(node.value, prefix || qualified_prefix,
                                      qualified_prefix, names, unnameable_cref)
      end

      # The unnamed-factory arm of {collect_declared_constant_names}: a
      # `Class.new`/`Module.new`/`Data.define`/`Struct.new` block's cref is the
      # anonymous class — declarations inside name nothing these tables carry.
      # (An eval-family block is NOT special here: `Module.nesting` does not
      # change, so `class Y` inside `X.class_eval` still declares under the
      # lexical prefix — the generic child walk covers it.)
      def collect_declared_anonymous_factory?(node, qualified_prefix, names, unnameable_cref)
        return false unless meta_new_constant_rvalue?(node) && node.block

        node.compact_child_nodes.each do |child|
          next if child.equal?(node.block)

          collect_declared_constant_names(child, qualified_prefix, names,
                                          unnameable_cref: unnameable_cref)
        end
        collect_declared_constant_names(node.block, qualified_prefix, names,
                                        unnameable_cref: true)
        true
      end

      # The rvalue half of {collect_declared_constant_names}'s write arm: a
      # `Const = <factory> do … end` block's cref is the new class, so the block
      # declares under the WRITTEN prefix; the call's other children and any
      # non-factory rvalue keep the enclosing context.
      def collect_rvalue_declared_names(value, written_prefix, qualified_prefix, names,
                                        unnameable_cref)
        if value.is_a?(Prism::CallNode) && meta_new_constant_rvalue?(value) && value.block
          value.compact_child_nodes.each do |child|
            next if child.equal?(value.block)

            collect_declared_constant_names(child, qualified_prefix, names,
                                            unnameable_cref: unnameable_cref)
          end
          collect_declared_constant_names(value.block, written_prefix, names,
                                          unnameable_cref: unnameable_cref)
        else
          collect_declared_constant_names(value, qualified_prefix, names,
                                          unnameable_cref: unnameable_cref)
        end
      end

      # The qualified prefix a `class`/`module` header declares: a `::`-rooted
      # path re-anchors at the top level; a bare or `self::` path under an
      # unnameable cref names nothing; every explicit base re-anchors
      # lexically — the same split {declaration_prefix} gives the discovery
      # walks.
      def declared_constant_path_prefix(path, qualified_prefix, unnameable_cref)
        return Source::ConstantPath.qualified_name_or_nil(path)&.split("::") if Source::ConstantPath.rooted?(path)
        return nil if unnameable_cref &&
                      (path.is_a?(Prism::ConstantReadNode) || self_anchored_tail(path))

        Source::ConstantPath.declaration_prefix(qualified_prefix, path)
      end

      # The qualified name a `Path::CONST =` write declares — the write walk's
      # own convention: `::`-rooted and `self::`-anchored paths resolve first,
      # every other base files AS WRITTEN (`S2::C = 2` inside `class S` keys
      # `S2::C`, matching {constant_path_write_key}'s as-written fallback
      # rather than the header rule's lexical re-anchor).
      def declared_constant_write_prefix(path, qualified_prefix, unnameable_cref)
        return Source::ConstantPath.qualified_name_or_nil(path)&.split("::") if Source::ConstantPath.rooted?(path)

        if (tail = self_anchored_tail(path))
          return nil if unnameable_cref

          return qualified_prefix + tail
        end
        Source::ConstantPath.qualified_name_or_nil(path)&.split("::")
      end

      # Every enclosing prefix of a declared name joins the oracle — a file
      # that declares `S::A::B` necessarily has `S` and `S::A` to declare it
      # under, so `A::B.class_eval` inside `class S` resolves `S::A::B`.
      def add_declared_name(names, qualified_name)
        segments = qualified_name.split("::")
        segments.each_index { |i| names << segments.first(i + 1).join("::") }
      end

      # The constant segments under a `self::`-anchored path — `self::A::B` → `["A", "B"]` —
      # or nil for every other base (`::`-rooted, constant, or dynamic).
      def self_anchored_tail(node)
        return nil unless node.is_a?(Prism::ConstantPathNode)

        segments = []
        current = node
        while current.is_a?(Prism::ConstantPathNode)
          segments.unshift(current.name.to_s)
          current = current.parent
        end
        current.is_a?(Prism::SelfNode) ? segments : nil
      end

      # `Object`'s constants ARE the top-level constants — every discovery table keys them
      # bare, the same collapse {self_write_name} applies — so a `self::`-anchored path
      # rooted at `Object` drops the segment rather than filing under a name nothing else
      # produces.
      def collapse_object_owner(prefix)
        prefix.first == OBJECT_OWNER ? prefix[1..] : prefix
      end

      # Whether an eval-family call's block rebinds `self` to the receiver spelled in source — false
      # for the bare and `self`-receiver forms, whose block keeps the ENCLOSING self (including the
      # singleton class inside `class << self`).
      def eval_named_receiver?(node)
        !(node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
      end

      # The `in_singleton_class` flag an eval-family block body inherits: a named receiver opens
      # that class's OWN body (`false`), while a bare or `self` receiver stays in whatever context
      # the enclosing body already is — `class << self; class_eval { … }` opens the singleton's
      # body, so `include` inside is still a singleton-ancestor edge.
      # Whether `def`/`alias` leaves in an eval block body bind on the receiver's SINGLETON:
      # `instance_eval`/`instance_exec` always (self IS the receiver — `def` lands on
      # `#<Class:X>`); `class_eval` only inside an already-singleton body, where the receiver's
      # own singleton is what `def` opens. A NAMED receiver under `class_eval` re-opens the
      # receiver itself, so `def` there stays instance-side.
      def eval_body_singleton?(node, in_singleton_class)
        INSTANCE_EVAL_CALLS.include?(node.name) ||
          (in_singleton_class && !eval_named_receiver?(node))
      end

      # The two flags an eval-family block body gives a def-owning walk: the
      # `in_singleton_class` its calls on the receiver-as-module inherit, and the
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
                              in_singleton_class && !eval_named_receiver?(node)
        call_singleton = eval_in_singleton &&
                         (!INSTANCE_EVAL_CALLS.include?(node.name) || singleton_self_eval)
        [call_singleton, singleton_self_eval ? :unnameable : eval_in_singleton]
      end

      def record_deferred_def(def_node, qualified_prefix, in_singleton_class, inside_deferred,
                              mf_offsets, ranges)
        start = def_node.location.start_offset
        if inside_deferred
          ranges << [start, def_node.location.end_offset, nil, nil, nil]
          return
        end

        kind = if def_singleton?(def_node, qualified_prefix, in_singleton_class)
                 :singleton
               elsif mf_offsets.any? { |offset| offset < start }
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
      def walk_singleton_def_nodes(node, qualified_prefix, in_singleton_class, accumulator, # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
                                   def_owner_prefix = nil, singleton_cref: false,
                                   defs_singleton: false)
        return unless node.is_a?(Prism::Node)
        if node.is_a?(Prism::CallNode) && receiver_eval_call?(node)
          return walk_eval_singleton_defs(node, qualified_prefix, in_singleton_class, accumulator,
                                          def_owner_prefix, singleton_cref: singleton_cref,
                                                            defs_singleton: defs_singleton)
        end

        case node
        when Prism::ClassNode, Prism::ModuleNode
          self_decl = self_anchored_decl_prefix(node.constant_path,
                                                in_singleton_class ? EMPTY_PREFIX : def_owner_prefix)
          child_prefix = self_decl ||
                         Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
          if child_prefix
            # Under an unnameable cref a bare/`self::` header opens `#<singleton>::Name` —
            # ownerless like `class << <non-constant>`; nameable headers re-anchor.
            child_cref = unnameable_decl?(node, self_decl, singleton_cref)
            body_prefix = child_cref ? [] : child_prefix
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
          if node.body
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
          unless defs_singleton == :unnameable
            record_singleton_def_node(node, def_owner_prefix || qualified_prefix,
                                      in_singleton_class || defs_singleton, false, accumulator)
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
        return false unless meta_new_block_call(node)

        child_prefix = meta_new_child_prefix(node, qualified_prefix, def_owner_prefix)
        meta_ownerless = singleton_cref &&
                         !meta_new_path_target_nameable?(node, def_owner_prefix)
        body_self = (meta_ownerless ? nil : child_prefix) || []
        walk_singleton_body(meta_new_block_body(node), qualified_prefix, false, accumulator,
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
        unnameable = unnameable_eval_self?(in_singleton_class, def_owner_prefix, qualified_prefix,
                                           singleton_cref)
        eval_prefix = eval_receiver_prefix(node, self_prefix, qualified_prefix,
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

      EMPTY_NESTING = [].freeze

      # The empty qualified prefix. Distinct from {EMPTY_NESTING} only in what it MEANS: the two are handed
      # to different parameters, and this cycle spent a blocker on a prefix and a nesting sharing a name.
      EMPTY_PREFIX = [].freeze
      private_constant :EMPTY_NESTING

      # Issue #681 — `{Prism::DefNode => Module.nesting}` for every `def` the file declares inside a class or
      # module body, keyed by node IDENTITY so the answer follows the DECLARATION rather than the class a
      # call happens to dispatch on. `Inference::ExpressionTyper#build_user_method_body_scope` rebuilds a
      # callee's body scope from the RECEIVER'S TYPE alone when it needs that callee's return, so unlike the
      # census scopes (#692) there is no prefix in hand to stamp: recording the chain where the declaration is
      # indexed is what makes the re-walk and the declaration walk agree BY CONSTRUCTION, which is the
      # argument #685 used to make {Reflection.lexical_nesting_chain} the single owner.
      #
      # Keyed on the def node and not on `(class, method)` because an inherited body is re-walked with the
      # SUBCLASS as receiver: `class Admin::CompactBase` declares `make`, `module Admin; class Child <
      # CompactBase` calls it, and the bare `Post` inside `make` names `::Post` — the constant the compact
      # declaration that OWNS the body reaches, not the one the receiver's spelling would suggest.
      #
      # A separate descent rather than a leaf of the fused methods/def-nodes walk: it needs the CHAIN
      # threaded, which the fused walk does not carry (a singleton-class body and a `Class.new` block body
      # both push a qualified prefix while pushing no `Module.nesting` entry), and threading a second value
      # through that walk and its anonymous-block twin exceeds their parameter budget. It stops at every
      # `Prism::DefNode`, so a def-dense file pays only the declaration spine.
      def build_def_nestings(root)
        accumulator = {}.compare_by_identity
        walk_def_nestings(root, EMPTY_NESTING, accumulator)
        accumulator.freeze
      end

      # Records `nesting` for every `def` reachable from `node`. Only a `class` / `module` keyword pushes an
      # entry (qualified against the entry already on top, so a compact `class Admin::X` contributes ONE);
      # every other body — a singleton class, a `Class.new` / `Module.new` block, any other block — inherits
      # the chain unchanged, because Ruby pushes no cref for them.
      #
      # Issue #716 — a top-level `def` records the EMPTY chain, and that is a recorded answer rather than the
      # absence of one. Ruby's `Module.nesting` in a top-level body IS `[]`, so `def helper = Post.new` names
      # `::Post` wherever it is later called from; recording nothing left
      # {Reflection.lexical_nesting_chain} peeling the CALLER's qualified name, which answered `Admin::Post`
      # for a call made from inside `module Admin`. The table is keyed by node identity and populated only by
      # this walk, so "present with `[]`" (walked, and top level) stays distinguishable from "absent" (no
      # declaration walk built this scope — a plugin-constructed scope, an anonymous `Class.new` re-entered
      # through `Scope#evaluate`), which keeps the peel where it is still the only available answer.
      # `self_base` names a rebound `self` for `self::`-anchored headers — a meta-new
      # block's class; `[]` marks a self no name covers.
      def walk_def_nestings(node, nesting, accumulator, self_base: nil, singleton_cref: false)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          return walk_def_nesting_declaration(node, nesting, accumulator, self_base,
                                              singleton_cref)
        when Prism::SingletonClassNode
          # The expression evaluates in the enclosing cref; the body's cref is unnameable —
          # and `self` below it is the singleton class, which `self::` headers decline on.
          walk_def_nestings(node.expression, nesting, accumulator,
                            self_base: self_base, singleton_cref: singleton_cref)
          if node.body
            walk_def_nestings(node.body, nesting, accumulator,
                              self_base: EMPTY_PREFIX, singleton_cref: true)
          end
          return
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
             Prism::ConstantPathOrWriteNode
          return if walk_def_nesting_meta_new?(node, nesting, accumulator, self_base,
                                               singleton_cref)
        when Prism::DefNode
          accumulator[node] = nesting unless nesting.nil?
          return
        when Prism::CallNode
          return if walk_def_nesting_eval?(node, nesting, accumulator, self_base, singleton_cref)
        end

        node.rigor_each_child do |child|
          walk_def_nestings(child, nesting, accumulator,
                            self_base: self_base, singleton_cref: singleton_cref)
        end
      end

      # The class/module arm of {#walk_def_nestings}: under an unnameable cref a
      # bare/`self::` header pushes `#<singleton>::Name` — a rung nothing can spell — so
      # the chain keeps what it had rather than filing a fabricated `C::D`; nameable
      # headers re-anchor at a real cref.
      def walk_def_nesting_declaration(node, nesting, accumulator, self_base, singleton_cref)
        return unless node.body

        self_decl = self_anchored_decl_prefix(node.constant_path, self_base)
        child_cref = unnameable_decl?(node, self_decl, singleton_cref)
        child_nesting =
          if child_cref
            nesting
          elsif self_decl
            [self_decl.join("::"), *nesting].freeze
          else
            Source::ConstantPath.pushed_nesting(nesting, node.constant_path)
          end
        walk_def_nestings(node.body, child_nesting, accumulator, singleton_cref: child_cref)
      end

      # The meta-new arm of {#walk_def_nestings}: the block rebinds only `self` — a
      # `self::` header inside anchors on the class the write names (`K::SX` below
      # `K = Class.new`), while `Module.nesting`, the table's payload, stays lexical.
      def walk_def_nesting_meta_new?(node, nesting, accumulator, self_base, singleton_cref)
        split = meta_new_block_split(node, nesting_lexical_prefix(nesting), self_base,
                                     singleton_cref)
        return false unless split

        enclosing, body, body_self = split
        enclosing.each do |part|
          walk_def_nestings(part, nesting, accumulator, self_base: self_base,
                                                        singleton_cref: singleton_cref)
        end
        if body
          walk_def_nestings(body, nesting, accumulator, self_base: body_self,
                                                        singleton_cref: singleton_cref)
        end
        true
      end

      # The eval-family arm of {#walk_def_nestings}: `self` rebinds to the receiver for
      # `self::` headers while `Module.nesting` stays lexical. `instance_eval` belongs
      # here too — it moves `self` for constant anchoring even though its `def`s bind
      # on the receiver's singleton.
      def walk_def_nesting_eval?(node, nesting, accumulator, self_base, singleton_cref)
        return false unless node.block.is_a?(Prism::BlockNode) &&
                            RECEIVER_EVAL_CALLS.include?(node.name)

        [node.receiver, *node.arguments&.arguments.to_a].compact.each do |part|
          walk_def_nestings(part, nesting, accumulator, self_base: self_base,
                                                        singleton_cref: singleton_cref)
        end
        lexical = nesting_lexical_prefix(nesting)
        self_prefix = self_base || lexical
        unnameable = unnameable_eval_self?(false, self_base, lexical, singleton_cref)
        eval_self = eval_receiver_prefix(node, self_prefix, lexical,
                                         unnameable_self: unnameable) || []
        if (body = node.block.body)
          walk_def_nestings(body, nesting, accumulator, self_base: eval_self,
                                                        singleton_cref: singleton_cref)
        end
        true
      end

      # The innermost lexical cref a def-nesting rung list names, as a prefix array — the
      # shape {meta_new_child_prefix} and {eval_receiver_prefix} take.
      def nesting_lexical_prefix(nesting)
        nesting&.first ? nesting.first.split("::") : []
      end

      # Walks a class/module/singleton-class body's direct statements in source order, threading the
      # bare-`module_function` toggle: once a bare `module_function` is seen, every subsequent `def` in the body
      # registers as a singleton method. Nested classes/modules/defs and `module_function :a, :b` named forms recurse /
      # record through the general walker so the toggle stays scoped to its own body.
      def walk_singleton_body(body, qualified_prefix, in_singleton_class, accumulator,
                              def_owner_prefix = nil, singleton_cref: false,
                              defs_singleton: false)
        owner_prefix = def_owner_prefix || qualified_prefix
        module_function_on = false
        statements_of(body).each do |stmt|
          if stmt.is_a?(Prism::CallNode) && module_function_toggle?(stmt)
            if bare_module_function?(stmt)
              module_function_on = true
            else
              # `:unnameable` — the named defs the call copies live on the metaclass,
              # which this table cannot name either.
              record_module_function_names(stmt, owner_prefix, body, accumulator) unless
                defs_singleton == :unnameable
            end
            next
          end
          if stmt.is_a?(Prism::DefNode)
            # `:unnameable` is the `class <<` + `instance_eval` definee — the singleton's own
            # singleton — which this table cannot name either.
            unless defs_singleton == :unnameable
              record_singleton_def_node(stmt, owner_prefix, in_singleton_class || defs_singleton,
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

      def record_singleton_def_node(def_node, qualified_prefix, in_singleton_class, module_function_on, accumulator)
        singleton = def_singleton?(def_node, qualified_prefix, in_singleton_class) || module_function_on
        return unless singleton
        return if qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        (accumulator[class_name] ||= {})[def_node.name] = def_node
      end

      # A bare `module_function` (no arguments) flips every following `def` in the module body to module-function
      # (instance + singleton) mode.
      def module_function_toggle?(node)
        node.name == :module_function && node.receiver.nil?
      end

      def bare_module_function?(node)
        node.arguments.nil? || node.arguments.arguments.empty?
      end

      # `module_function :a, :b` retro-marks named siblings (defined earlier OR later in the same body) as
      # module-functions. Resolves each symbol-literal argument against the body's own `def`s and registers the matching
      # `DefNode` on the module's singleton side. Non-symbol arguments and names with no matching `def` are skipped (a
      # miss degrades to today's `Dynamic`, never a false resolution).
      def record_module_function_names(node, qualified_prefix, body, accumulator)
        return if qualified_prefix.empty?

        defs_by_name = statements_of(body).each_with_object({}) do |stmt, acc|
          acc[stmt.name] = stmt if stmt.is_a?(Prism::DefNode) && stmt.receiver.nil?
        end
        class_name = qualified_prefix.join("::")
        node.arguments&.arguments&.each do |arg|
          name = symbol_argument_name(arg)
          def_node = name && defs_by_name[name]
          (accumulator[class_name] ||= {})[name] = def_node if def_node
        end
      end

      # The Symbol value of a `:name` / `"name"` literal argument, or nil.
      def symbol_argument_name(arg)
        arg.unescaped.to_sym if arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode)
      end

      # ADR-24 slice 2 — per-class table mapping a fully qualified user class to its superclass name AS WRITTEN at the
      # `class Foo < Bar` declaration. Only constant superclasses are recorded (`class Foo < Struct.new(...)` and other
      # non-constant superclasses produce no entry). The as-written name is resolved to a qualified class at the call
      # site against the nesting the declaration's HEADER sits in — see {Scope#ancestor_name_candidates}, which reads
      # the second table this walk builds.
      #
      # Issue #682 — `header_nestings` maps the same qualified class name to that nesting: `Module.nesting` where the
      # `class` / `module` KEYWORD is written, which is the body's chain minus the declaration's own entry. It is
      # recorded here, with the walk's prefix in hand, because it is unrecoverable afterwards: `class Admin::Widget`
      # and `module Admin; class Widget` render the identical `"Admin::Widget"`, and an ancestor name is resolved in
      # the enclosing cref — `[]` for the first spelling, `["Admin"]` for the second. A class reopened under two
      # spellings keeps the LAST one walked, matching how `superclasses` itself merges.
      #
      # @return the `[superclasses, header_nestings]` pair
      def build_superclass_tables(root, source_path = nil)
        accumulator = { superclasses: {}, header_nestings: {} }
        walk_class_superclasses(root, [], accumulator, source_path)
        [accumulator[:superclasses].freeze, accumulator[:header_nestings].freeze]
      end

      # `self_base` names a rebound `self` for `self::`-anchored headers — a meta-new
      # block's class; `[]` marks a self no name covers.
      def walk_class_superclasses(node, qualified_prefix, accumulator, source_path = nil,
                                  nesting = EMPTY_NESTING, self_base: nil, singleton_cref: false)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::CallNode
          return if walk_superclass_eval_call?(node, qualified_prefix, accumulator, source_path,
                                               nesting, self_base, singleton_cref)

          record_anonymous_meta_superclass(node, accumulator[:superclasses], source_path)
        when Prism::ClassNode, Prism::ModuleNode
          return if walk_superclass_declaration?(node, qualified_prefix, accumulator, nesting,
                                                 self_base, singleton_cref)
        when Prism::SingletonClassNode
          # The expression evaluates in the enclosing cref; the body's cref is unnameable.
          return walk_singleton_superclasses(node, qualified_prefix, accumulator, source_path,
                                             nesting, self_base, singleton_cref)
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode,
             Prism::ConstantOrWriteNode, Prism::ConstantPathOrWriteNode
          return if walk_superclass_meta_new?(node, qualified_prefix, accumulator, source_path,
                                              nesting, self_base, singleton_cref)
        end

        node.rigor_each_child do |child|
          walk_class_superclasses(child, qualified_prefix, accumulator, source_path, nesting,
                                  self_base: self_base, singleton_cref: singleton_cref)
        end
      end

      # The eval-family arm of {#walk_class_superclasses}: `self::` headers anchor on the
      # receiver — `X.class_eval { class self::D < S }` files `X::D`'s ancestry — while bare
      # headers and the nesting rungs stay lexical.
      def walk_superclass_eval_call?(node, qualified_prefix, accumulator, source_path, nesting,
                                     self_base, singleton_cref)
        split = eval_block_split(node, qualified_prefix, self_base, singleton_cref)
        return false unless split

        enclosing, body, body_self = split
        enclosing.each do |part|
          walk_class_superclasses(part, qualified_prefix, accumulator, source_path, nesting,
                                  self_base: self_base, singleton_cref: singleton_cref)
        end
        if body
          walk_class_superclasses(body, qualified_prefix, accumulator, nil, nesting,
                                  self_base: body_self, singleton_cref: singleton_cref)
        end
        true
      end

      # The `K = Class.new { … }` arm of {#walk_class_superclasses}: the block's `self` is the
      # class the write names; its declarations stay lexical.
      def walk_superclass_meta_new?(node, qualified_prefix, accumulator, source_path, nesting,
                                    self_base, singleton_cref)
        split = meta_new_block_split(node, qualified_prefix, self_base, singleton_cref)
        return false unless split

        enclosing, body, body_self = split
        enclosing.each do |part|
          walk_class_superclasses(part, qualified_prefix, accumulator, source_path, nesting,
                                  self_base: self_base, singleton_cref: singleton_cref)
        end
        if body
          walk_class_superclasses(body, qualified_prefix, accumulator, nil, nesting,
                                  self_base: body_self, singleton_cref: singleton_cref)
        end
        true
      end

      # The class/module arm of {#walk_class_superclasses}: under an unnameable cref a
      # bare/`self::` header opens `#<singleton>::Name` — ancestry/nesting facts for it
      # would publish under a `C::D` MRI never creates, so they are skipped and the body
      # walks ownerless; nameable headers re-anchor at a real cref.
      def walk_superclass_declaration?(node, qualified_prefix, accumulator, nesting,
                                       self_base, singleton_cref)
        ctx = decl_body_context(node, qualified_prefix, self_base, singleton_cref)
        return false unless ctx

        self_decl, child_prefix, child_cref = ctx
        record_declaration_ancestry(node, nesting, child_prefix, accumulator) unless child_cref
        child_nesting =
          if child_cref
            nesting
          elsif self_decl
            [self_decl.join("::"), *nesting].freeze
          else
            Source::ConstantPath.pushed_nesting(nesting, node.constant_path) || nesting
          end
        return true unless node.body

        walk_class_superclasses(node.body, child_cref ? [] : child_prefix, accumulator, nil,
                                child_nesting, singleton_cref: child_cref)
        true
      end

      def walk_singleton_superclasses(node, qualified_prefix, accumulator, source_path, nesting,
                                      self_base, singleton_cref)
        walk_class_superclasses(node.expression, qualified_prefix, accumulator, source_path,
                                nesting, self_base: self_base, singleton_cref: singleton_cref)
        return unless node.body

        # `self` below `class <<` is the singleton class — `self::` headers decline.
        walk_class_superclasses(node.body, qualified_prefix, accumulator, source_path,
                                nesting, self_base: EMPTY_PREFIX, singleton_cref: true)
      end

      # One declaration's two ancestry facts: the as-written superclass name (classes only), and the
      # `Module.nesting` its header is written in. `nesting` is the chain in force OUTSIDE the header — the
      # header is evaluated before the body is entered, so the declaration's own entry is not on the ladder
      # its superclass name walks — which is why the walk pushes only when it recurses into the body. The
      # chain is threaded rather than derived from the enclosing prefix because a rooted header resets that
      # prefix without resetting Ruby's nesting ([#708](https://github.com/rigortype/rigor/issues/708)).
      def record_declaration_ancestry(node, nesting, child_prefix, accumulator)
        full = child_prefix.join("::")
        names = declared_ancestor_names(node)
        add_header_nesting(accumulator[:header_nestings], full, nesting, names) if names
        return unless node.is_a?(Prism::ClassNode)

        accumulator[:superclasses][full] = recorded_ancestor_name(node.superclass) if node.superclass
      end

      # Issue #722 residue 1 / #637 — the recorded ancestor name, carrying the ROOTED marker when the site
      # wrote one. `Source::ConstantPath.qualified_name` renders segments only, so `class Rooted < ::Base`
      # recorded the same `"Base"` a bare `< Base` does, and the resolver then walked the enclosing nesting
      # and answered `A::Base` — a class Ruby never looks at, on a spelling whose whole point is that it
      # does not.
      #
      # The marker rides the existing table's VALUE rather than a new table. It is still a String, so the
      # per-file index, the cross-file fold and the ADR-85 seed bundle carry it unchanged; the three
      # resolvers that read it strip and anchor. `IncrementalSnapshot::SCHEMA` is bumped anyway, because an
      # older blob's un-rooted value is indistinguishable from "not rooted" and a warm run would keep the
      # pre-fix answer for every unchanged file.
      def recorded_ancestor_name(node)
        name = Source::ConstantPath.qualified_name(node)
        return name if name.nil? || !Source::ConstantPath.rooted?(node)

        "::#{name}"
      end

      # The ancestor names this declaration SITE writes — the superclass in its header, and every mixin
      # argument in its own body — or nil when the site writes none. Only a site that writes one
      # contributes a header nesting, and the names are what key it: Ruby resolves each ancestor name in
      # the cref of the site that WROTE it, and a class's sites need not agree on that cref.
      #
      # Issue #708's review: a per-CLASS union of every site's chain is wrong for a rooted reopen inside
      # another namespace. `class ::Foo; def extra = 1; end` written in `module Outer` contributed `["Outer"]`
      # to `Foo`, and the ancestor rung then resolved `Foo`'s superclass `Base` as `Outer::Base` — a class
      # Ruby never looks at, ahead of the right one, on a site that named no ancestor at all. A site that
      # writes no ancestor name has no ancestor for its cref to govern, so it has nothing to say here.
      #
      # Issue #728: dropping those sites was necessary and not sufficient. When the rooted reopen genuinely
      # names a mixin — `class ::Foo; include Helper; end` in `module Outer` — the site is recorded, and a
      # per-class union then hands its `["Outer"]` to `Foo`'s superclass `Base` as well, which is the same
      # `Outer::Base` on the same repro. Keying by the written name is what separates them: `Base` resolves
      # in the empty chain of the top-level site that wrote `< Base`, `Helper` in the `["Outer"]` chain of
      # the site that wrote `include Helper`, which is what Ruby does for each independently.
      #
      # This keeps what the union was FOR. It was added because last-writer-wins let one rails TEST file
      # reopening `ActiveRecord::Relation` compactly beat the library declaration, costing the class all nine
      # of its `include`d modules; that reopen writes no ancestor name either, so it contributes nothing
      # rather than winning — the protection comes from the recording rule instead of from a merge rule.
      #
      # The mixin scan counts only a call whose `self` is the declaration itself, so it stops at every
      # construct that rebinds `self`: a nested `class` / `module` (that body's calls belong to the nested
      # class), a `class << self` body, and a block `#rebound_block_self` classifies as rebinding — the
      # `Class.new` / `Module.new` / `Struct.new` / `Data.define` and `class_eval` family. An `include`
      # written in any of those attaches to something other than this class, so treating it as this site's
      # ancestor name reinstates exactly the defect above with a different spelling. {#walk_class_includes}
      # classifies the same shapes the same way since [#749](https://github.com/rigortype/rigor/pull/749),
      # so the two walks agree on which site owns a mixin.
      #
      # It stays structural rather than exhaustive: `self.include M` and `send(:include, M)` are recorded by
      # neither walk, so the class's ancestry agrees. `Recv.class_eval { include M }` is the one shape where
      # they diverge in the surviving direction — the includes walk names `Recv`, this one cannot see the
      # site from `Recv`'s own declaration — and that is what {#add_header_nesting}'s unkeyed entry answers.
      def declared_ancestor_names(node)
        names = []
        superclass = node.is_a?(Prism::ClassNode) ? node.superclass : nil
        if superclass
          recorded = recorded_ancestor_name(superclass)
          names << recorded if recorded
        end
        body = node.body
        mixin = body ? collect_mixin_names(body, names) : false
        return names if superclass || mixin

        nil
      end

      # Appends each mixin argument this body names to `names`, and answers whether it writes a mixin call
      # at all — a `include some_method` writes one while naming nothing renderable, and the site still owns
      # a chain for the names it does write. Arguments are rendered exactly as {#record_mixin_call} renders
      # them, so a name recorded here is the same String the includes table stores and the resolver asks for.
      def collect_mixin_names(node, names)
        return false unless node.is_a?(Prism::Node)
        return false if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode) ||
                        node.is_a?(Prism::SingletonClassNode)

        found = mixin_call?(node)
        record_mixin_names(node, names) if found
        rebinds = rebound_block_self(node, EMPTY_PREFIX)
        node.rigor_each_child do |child|
          next if rebinds && child.is_a?(Prism::BlockNode)

          found = true if collect_mixin_names(child, names)
        end
        found
      end

      def mixin_call?(node)
        node.is_a?(Prism::CallNode) && node.receiver.nil? && MIXIN_CALL_NAMES.include?(node.name)
      end

      def record_mixin_names(node, names)
        node.arguments&.arguments&.each do |arg|
          mod = Source::ConstantPath.qualified_name(arg)
          names << mod if mod
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

      # #319 — `Class.new(Parent) do ... end` names its superclass in the first positional. Recording it under the
      # call site's anonymous name keeps `Parent`'s surface reachable from the block body (whose `self_type` is now
      # `Singleton[<anonymous>]`) and from an instance of the resulting class, so giving the anonymous class an
      # identity does not cost the inheritance the old `Singleton[Parent]` answer carried for free.
      def record_anonymous_meta_superclass(call_node, accumulator, source_path)
        return unless AnonymousMetaClass.block_form_receiver(call_node) == :Class

        arg = call_node.arguments&.arguments&.first
        return if arg.nil?

        # Issue #722 residue 1 — deliberately NOT marked rooted here, unlike the `class X < ::Parent`
        # header. Marking it changed nothing observable: `Made = Class.new(::Base)` inside a namespace that
        # shadows `Base` still resolved the shadow, so the anonymous class's ancestry is reached by a path
        # that does not read this value, and shipping a marker no resolver honours would be a change with
        # no gate. The residue stays on #722 with that finding attached.
        superclass = Source::ConstantPath.qualified_name(arg)
        return if superclass.nil?

        name = AnonymousMetaClass.name_for(call_node, source_path)
        accumulator[name] = superclass if name
      end

      # ADR-48 — per qualified class name -> ordered `Data.define` member-name list, for both the named-subclass form
      # (`class Point < Data.define(:x, :y)`) and the constant-assigned form (`Point = Data.define(:x, :y)`). Only
      # `Data.define` is recorded: `Struct.new` instances are mutable, so member-value folding would be unsound (the
      # Struct follow-up is deferred — see ADR-48 § "Struct follow-up"). Consumed by
      # {Inference::MethodDispatcher::DataFolding} via {Scope#data_member_layout}.
      def build_data_member_layouts(root)
        accumulator = {}
        walk_data_member_layouts(root, [], accumulator)
        accumulator.freeze
      end

      # `self_base` names a rebound `self` for `self::`-anchored declarations and write
      # targets — a meta-new block's class; `[]` marks a self no name covers.
      def walk_data_member_layouts(node, qualified_prefix, accumulator, self_base: nil,
                                   singleton_cref: false)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          return walk_layout_declaration(node, qualified_prefix, accumulator, self_base,
                                         singleton_cref, :data)
        when Prism::SingletonClassNode
          # The expression evaluates in the enclosing cref; the body's cref is unnameable.
          return walk_singleton_member_layouts(node, qualified_prefix, accumulator,
                                               :walk_data_member_layouts, self_base,
                                               singleton_cref)
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
             Prism::ConstantPathOrWriteNode
          # A meta-new constant write under an unnameable cref lands on the singleton's own
          # table unless it is a path write — declining a bare target rather than keying
          # the block's class by the lexical prefix.
          unless singleton_cref && !meta_new_path_target_nameable?(node, self_base)
            child_prefix = meta_new_child_prefix(node, qualified_prefix, self_base)
          end
          record_data_member_layout(accumulator, child_prefix, meta_new_rvalue(node)) if child_prefix
          return if walk_data_layout_meta_new?(node, qualified_prefix, accumulator,
                                               self_base, singleton_cref)
        when Prism::CallNode
          return if walk_member_layout_eval_call?(node, qualified_prefix, accumulator,
                                                  self_base, singleton_cref,
                                                  :walk_data_member_layouts)
        end

        node.rigor_each_child do |child|
          walk_data_member_layouts(child, qualified_prefix, accumulator,
                                   self_base: self_base, singleton_cref: singleton_cref)
        end
      end

      # The `K = Data.define { … }`-family arm of {#walk_data_member_layouts}: the
      # factory call's receiver and arguments keep the enclosing context; the block's
      # `self` is the class the write names.
      def walk_data_layout_meta_new?(node, qualified_prefix, accumulator, self_base,
                                     singleton_cref)
        split = meta_new_block_split(node, qualified_prefix, self_base, singleton_cref)
        return false unless split

        enclosing, body, body_self = split
        enclosing.each do |part|
          walk_data_member_layouts(part, qualified_prefix, accumulator,
                                   self_base: self_base, singleton_cref: singleton_cref)
        end
        if body
          walk_data_member_layouts(body, qualified_prefix, accumulator,
                                   self_base: body_self, singleton_cref: singleton_cref)
        end
        true
      end

      # The class/module-declaration arm shared by the member-layout walks: a `class` header can
      # itself be a `Data.define`/`Struct.new` subclass, and under an unnameable cref a bare/`self::`
      # header opens `#<singleton>::Name` — the record is skipped and the body walks ownerless;
      # nameable headers re-anchor at a real cref.
      def walk_layout_declaration(node, qualified_prefix, accumulator, self_base,
                                  singleton_cref, kind)
        self_decl = self_anchored_decl_prefix(node.constant_path, self_base)
        child_prefix = self_decl ||
                       Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
        return unless child_prefix

        child_cref = unnameable_decl?(node, self_decl, singleton_cref)
        if node.is_a?(Prism::ClassNode) && !child_cref
          record = kind == :data ? :record_data_member_layout : :record_struct_member_layout
          send(record, accumulator, child_prefix, node.superclass, allow_outer_block: false)
        end
        return unless node.body

        walk = kind == :data ? :walk_data_member_layouts : :walk_struct_member_layouts
        send(walk, node.body, child_cref ? [] : child_prefix, accumulator,
             singleton_cref: child_cref)
      end

      # Records `qualified -> [members]` when `expr` is a `Data.define(*Symbol)` call with at least one literal-Symbol
      # member.
      def record_data_member_layout(accumulator, qualified_parts, expr, allow_outer_block: true)
        expr = resolve_meta_factory_call(expr, allow_outer_block: allow_outer_block)
        return unless expr && data_define_call?(expr)

        members = meta_member_names(expr)
        return if members.empty?

        accumulator[qualified_parts.join("::")] = members.freeze
      end

      # ADR-48 Struct follow-up — the `Struct.new(...)` sibling of {#build_data_member_layouts}. A separate, additive
      # table so the existing `Data.define` value-shape contract (a bare `[Symbol]`) is untouched: a Struct entry
      # carries `{ members:, keyword_init: }` because the dispatcher needs the flag to fold the matching `.new` call
      # form (positional vs keyword) without manufacturing a wrong map.
      def build_struct_member_layouts(root)
        accumulator = {}
        walk_struct_member_layouts(root, [], accumulator)
        accumulator.freeze
      end

      def walk_struct_member_layouts(node, qualified_prefix, accumulator, self_base: nil,
                                     singleton_cref: false)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          return walk_layout_declaration(node, qualified_prefix, accumulator, self_base,
                                         singleton_cref, :struct)
        when Prism::SingletonClassNode
          # The expression evaluates in the enclosing cref; the body's cref is unnameable.
          return walk_singleton_member_layouts(node, qualified_prefix, accumulator,
                                               :walk_struct_member_layouts, self_base,
                                               singleton_cref)
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
             Prism::ConstantPathOrWriteNode
          # A meta-new constant write under an unnameable cref lands on the singleton's own
          # table unless it is a path write — declining a bare target rather than keying
          # the block's class by the lexical prefix.
          unless singleton_cref && !meta_new_path_target_nameable?(node, self_base)
            child_prefix = meta_new_child_prefix(node, qualified_prefix, self_base)
          end
          record_struct_member_layout(accumulator, child_prefix, meta_new_rvalue(node)) if child_prefix
          return if walk_struct_layout_meta_new?(node, qualified_prefix, accumulator,
                                                 self_base, singleton_cref)
        when Prism::CallNode
          return if walk_member_layout_eval_call?(node, qualified_prefix, accumulator,
                                                  self_base, singleton_cref,
                                                  :walk_struct_member_layouts)
        end

        node.rigor_each_child do |child|
          walk_struct_member_layouts(child, qualified_prefix, accumulator,
                                     self_base: self_base, singleton_cref: singleton_cref)
        end
      end

      # The `K = Struct.new { … }`-family arm of {#walk_struct_member_layouts}: the
      # factory call's receiver and arguments keep the enclosing context; the block's
      # `self` is the class the write names.
      def walk_struct_layout_meta_new?(node, qualified_prefix, accumulator, self_base,
                                       singleton_cref)
        split = meta_new_block_split(node, qualified_prefix, self_base, singleton_cref)
        return false unless split

        enclosing, body, body_self = split
        enclosing.each do |part|
          walk_struct_member_layouts(part, qualified_prefix, accumulator,
                                     self_base: self_base, singleton_cref: singleton_cref)
        end
        if body
          walk_struct_member_layouts(body, qualified_prefix, accumulator,
                                     self_base: body_self, singleton_cref: singleton_cref)
        end
        true
      end

      # The eval-family arm shared by the two member-layout walks: the call's receiver and
      # arguments keep the enclosing context while the block body's `self` is the receiver —
      # a named receiver re-anchors `self::` headers to a real class even under `class <<`;
      # a bare/`self` receiver keeps the enclosing (possibly unnameable) self.
      def walk_member_layout_eval_call?(node, qualified_prefix, accumulator, self_base,
                                        singleton_cref, walk)
        return false unless receiver_eval_call?(node)

        [node.receiver, *node.arguments&.arguments.to_a].compact.each do |part|
          send(walk, part, qualified_prefix, accumulator,
               self_base: self_base, singleton_cref: singleton_cref)
        end
        unnameable = unnameable_eval_self?(false, self_base, qualified_prefix, singleton_cref)
        eval_self = eval_receiver_prefix(node, self_base || qualified_prefix, qualified_prefix,
                                         unnameable_self: unnameable) || []
        if (body = node.block.body)
          send(walk, body, qualified_prefix, accumulator,
               self_base: eval_self, singleton_cref: singleton_cref)
        end
        true
      end

      # The `class <<` arm shared by the two member-layout walks: the expression evaluates in
      # the enclosing cref while the body's cref is the unnameable singleton class.
      def walk_singleton_member_layouts(node, qualified_prefix, accumulator, walk, self_base,
                                        singleton_cref)
        send(walk, node.expression, qualified_prefix, accumulator,
             self_base: self_base, singleton_cref: singleton_cref)
        return unless node.body

        # `self` below `class <<` is the singleton class — `self::` headers decline.
        send(walk, node.body, qualified_prefix, accumulator,
             self_base: EMPTY_PREFIX, singleton_cref: true)
      end

      # Records `qualified -> { members:, keyword_init: }` when `expr` is a `Struct.new(*Symbol [, keyword_init:
      # <bool>])` call with at least one literal-Symbol member.
      def record_struct_member_layout(accumulator, qualified_parts, expr, allow_outer_block: true)
        expr = resolve_meta_factory_call(expr, allow_outer_block: allow_outer_block)
        return unless expr && struct_new_call?(expr)

        members = meta_member_names(expr)
        return if members.empty?

        accumulator[qualified_parts.join("::")] = {
          members: members.freeze,
          keyword_init: struct_new_keyword_init?(expr)
        }.freeze
      end

      # True when a `Struct.new` call carries `keyword_init: true` as a literal in its trailing keyword hash. A
      # non-literal value (or its absence) reads as `false` — the conservative positional default.
      def struct_new_keyword_init?(call_node)
        args = call_node.arguments&.arguments || []
        last = args.last
        return false unless last.is_a?(Prism::KeywordHashNode)

        last.elements.any? do |assoc|
          assoc.is_a?(Prism::AssocNode) &&
            assoc.key.is_a?(Prism::SymbolNode) && assoc.key.unescaped == "keyword_init" &&
            assoc.value.is_a?(Prism::TrueNode)
        end
      end

      MIXIN_CALL_NAMES = %i[include prepend].freeze

      # ADR-24 slice 2 — per-class/module table mapping a fully qualified user class or module to the list of module
      # names it `include`s / `prepend`s, AS WRITTEN at the mixin call (`include Foo` / `include Foo::Bar`). Only
      # constant arguments are recorded; dynamic mixins (`include some_method`) produce no entry. The names are
      # spelled as written but ordered in instance-ancestor SEARCH order since #1173: prepended modules first
      # (Ruby puts them ahead of the class itself), then includes nearest-first (`include A; include B` searches
      # B first; `include A, B` keeps `["A", "B"]`). `prepend` is ALSO recorded in its own
      # {#build_discovered_prepends} table, which is what tells the two apart at `def`-priority level. `extend` is NOT
      # tracked (it adds singleton methods; ADR-24 slice 2 resolves the instance-side chain).
      def build_discovered_includes(root)
        mixin_tables(root).fetch(:includes)
      end

      # Issue #1123 — `{qualified class or module name => [module names it `prepend`s, as written]}`,
      # stored in instance-ancestor SEARCH order: a later `prepend` statement puts its module NEARER than
      # an earlier one (`prepend A; prepend B` searches B before A) while the arguments of ONE
      # `prepend A, B` keep call order — exactly the convention {#record_extend_targets} documents for
      # `extend`, and the order `Scope#user_def_through_ancestors`'s prepend wedge consumes. Ruby inserts a
      # prepended module, and its own ancestry, immediately BEFORE the class that prepends it, so these
      # names outrank the class's own `def`s; without the kind recorded separately from {#build_discovered_includes}
      # there was nothing to order on and `prepend` was silently an `include`.
      def build_discovered_prepends(root)
        mixin_tables(root).fetch(:prepends)
      end

      # One descent, both instance-side mixin tables: the walk classifies each mixin call it sees, so the
      # two tables cost one walk rather than two. Each value is frozen and de-duplicated per class, as the
      # single-table builder always did.
      def mixin_tables(root)
        accumulator = {}
        walk_class_includes(root, [], nil, accumulator)
        {
          includes: freeze_mixin_lists(accumulator, :include),
          prepends: freeze_mixin_lists(accumulator, :prepend)
        }
      end

      # The `{include: [...], prepend: [...]}`-valued accumulator {#mixin_tables} fills is keyed by class
      # first and kind second, because one walk feeds both tables; this projects one kind out of it. A class
      # with no names of that kind is DROPPED rather than stored as an empty list, which is the shape the
      # single-table builder always had (consumers take the absence of an entry as "mixes nothing in").
      #
      # Issue #1173 — the `:include` projection prepends the `:prepend` names: a prepended module sits
      # ahead of the class ITSELF in the runtime ancestry, and therefore ahead of every include, so the
      # instance-ancestor search order this table now keeps is `prepends ++ includes`. Both buckets
      # already store nearest-first (see {#write_mixin_targets}), so the concat preserves MRO.
      def freeze_mixin_lists(accumulator, kind)
        accumulator.each_with_object({}) do |(class_name, kinds), out|
          names = mixin_names_for(kinds, kind).uniq.freeze
          out[class_name] = names unless names.empty?
        end.freeze
      end

      # One bucket's frozen list: `:include` is every instance-side mixin in search order (prepends
      # first), `:prepend` the wedge table alone.
      def mixin_names_for(kinds, kind)
        if kind == :include
          (kinds[:prepend] || []) + (kinds[:include] || [])
        else
          kinds[kind] || []
        end
      end

      def walk_class_includes(node, qualified_prefix, current_class, accumulator,
                              singleton_self: false, singleton_cref: false)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          return if walk_includes_declaration?(node, qualified_prefix, current_class, accumulator,
                                               singleton_cref)
        when Prism::SingletonClassNode
          # Issue #728 — `class << self; include M; end` mixes M into the SINGLETON: it contributes class
          # methods, not the instance surface this table feeds. Descending with no owner keeps any nested
          # declaration walked (a `ClassNode` child sets its own owner) while the mixin calls in the
          # singleton body record nothing, which is what `extends` is for — and since #915 the extend walk
          # does take them, so the form is recorded rather than dropped. `self` inside is
          # the singleton — a `self::` receiver below raises NameError at runtime, so it
          # declines rather than resolving against the enclosing class. The `class <<`
          # EXPRESSION itself evaluates in the enclosing context, so it walks without
          # either marker.
          return walk_singleton_class_includes(node, qualified_prefix, current_class, accumulator,
                                               singleton_self, singleton_cref)
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
             Prism::ConstantPathOrWriteNode
          return if walk_includes_meta_new?(node, qualified_prefix, current_class, accumulator,
                                            singleton_self, singleton_cref)
        when Prism::CallNode
          record_mixin_call(node, qualified_prefix, current_class, accumulator)
          return walk_mixin_call_children(node, qualified_prefix, current_class, accumulator,
                                          singleton_self, singleton_cref)
        end

        node.rigor_each_child do |child|
          walk_class_includes(child, qualified_prefix, current_class, accumulator,
                              singleton_self: singleton_self, singleton_cref: singleton_cref)
        end
      end

      # The class/module arm of {#walk_class_includes}: under an unnameable cref a
      # bare/`self::` header opens `#<singleton>::Name` — ownerless; nameable headers
      # re-anchor at a real cref.
      def walk_includes_declaration?(node, qualified_prefix, current_class, accumulator,
                                     singleton_cref)
        ctx = decl_body_context(node, qualified_prefix, current_class && [current_class],
                                singleton_cref)
        return false unless ctx
        return true unless node.body

        _self_decl, child_prefix, child_cref = ctx
        walk_class_includes(node.body, child_cref ? [] : child_prefix,
                            child_cref ? nil : child_prefix.join("::"), accumulator,
                            singleton_cref: child_cref)
        true
      end

      # The `class <<` arm of {#walk_class_includes}: the expression evaluates in the enclosing
      # context while the body is the singleton's — ownerless here (`extends` owns its mixins),
      # with `self` unnameable and an unnameable cref.
      def walk_singleton_class_includes(node, qualified_prefix, current_class, accumulator,
                                        singleton_self, singleton_cref)
        walk_class_includes(node.expression, qualified_prefix, current_class, accumulator,
                            singleton_self: singleton_self, singleton_cref: singleton_cref)
        return unless node.body

        walk_class_includes(node.body, qualified_prefix, nil, accumulator,
                            singleton_self: true, singleton_cref: true)
      end

      # `K = Class.new { include T }` mixes T into the block's class — the nameable `K`, or
      # ownerless when the write lands on an unnameable cref. Returns whether a meta-new block
      # body was found (the write's other children are left to the caller).
      def walk_includes_meta_new?(node, qualified_prefix, current_class, accumulator, singleton_self,
                                  singleton_cref)
        call = meta_new_block_call(node)
        return false unless call

        meta_owner = meta_new_mixin_owner(node, qualified_prefix, singleton_cref,
                                          current_class && [current_class])
        # The block rebinds only `self` — `Module.nesting` stays lexical — so the cref
        # flag passes through unchanged: a nested `class Inner` under `class <<` still
        # lands on the singleton's table, while mixin leaves attribute to `meta_owner`.
        body_cref = singleton_cref
        # The factory call's receiver and arguments evaluate in the ENCLOSING context —
        # `K = Class.new(X.class_eval { include T })` still mixes T into X — while the
        # block is the class body of the class the write names.
        if call.receiver
          walk_class_includes(call.receiver, qualified_prefix, current_class, accumulator,
                              singleton_self: singleton_self, singleton_cref: singleton_cref)
        end
        call.arguments&.arguments&.each do |arg|
          walk_class_includes(arg, qualified_prefix, current_class, accumulator,
                              singleton_self: singleton_self, singleton_cref: singleton_cref)
        end
        if (body = call.block&.body)
          walk_class_includes(body, qualified_prefix, meta_owner, accumulator,
                              singleton_cref: body_cref)
        end
        true
      end

      # Issue #728 — a block that REBINDS `self` owns the mixin calls written in it, and this walk used to
      # hand them to the lexically enclosing declaration. `Thing = Class.new { include Taggable }` inside
      # `class Outer` registered `Taggable` on `Outer`, so `Outer.new.tag` typed `:tagged` where MRI raises
      # `NoMethodError` — a wrong answer, not a wider one. The classification is
      # {#rebound_block_self}, the same one #721 gave its own mixin scan.
      #
      # `Recv.class_eval { include M }` resolves to `Recv` and now records there, which it never did before
      # (the block's owner was the lexical enclosure, so at the top level the include was simply dropped).
      # An OPAQUE rebinding — `Class.new` / `Module.new` / a non-constant `class_eval` receiver — records
      # nothing: the class exists but this walk cannot name it, and naming the lexical enclosure instead is
      # the one answer Ruby is guaranteed not to have written.
      def walk_mixin_call_children(node, qualified_prefix, current_class, accumulator, singleton_self,
                                   singleton_cref)
        # `self` is unnameable whenever the singleton marker is set OR the body is ownerless
        # under an unnameable cref (`class D` inside `class <<`, a declined eval body) — a
        # `self::` receiver inside either raises NameError or resolves on a table nothing
        # names, so it declines rather than re-anchoring to the lexical class.
        unnameable_self = singleton_self || (singleton_cref && current_class.nil?)
        rebound = rebound_block_self(node, qualified_prefix, nil, nil,
                                     rebound_self_base(unnameable_self ? OPAQUE_SELF : current_class))
        node.rigor_each_child do |child|
          rebinds_self = rebound && child.is_a?(Prism::BlockNode)
          owner =
            if rebinds_self
              rebound == OPAQUE_SELF ? nil : rebound
            else
              current_class
            end
          # A rebound block's own self is the receiver again — nameable only when the rebound
          # is; an OPAQUE rebound keeps the self unnameable — but `Module.nesting` never
          # rebinds, so the unnameable-cref marker crosses the block unchanged.
          child_unnameable = rebinds_self ? rebound == OPAQUE_SELF : unnameable_self
          walk_class_includes(child, qualified_prefix, owner, accumulator,
                              singleton_self: child_unnameable, singleton_cref: singleton_cref)
        end
      end

      # A receiverless `include Foo` / `prepend Foo` written in a declaration body contributes both tables;
      # the receiver form (`Base.prepend(Loud)`, issue #1123) does too — a call form puts the module in the
      # class's instance ancestry exactly as the declaration form does, so `discovered_includes` must carry
      # it or the set-shaped consumers (arity, visibility, undefined-method suppression) would answer
      # differently for the two spellings of one edge.
      def record_mixin_call(node, qualified_prefix, current_class, accumulator)
        return unless mixin_call_recorded?(node, current_class)

        targets = node.arguments&.arguments&.filter_map { |arg| Source::ConstantPath.qualified_name(arg) }
        return if targets.nil? || targets.empty?

        owner = node.receiver.nil? ? current_class : prepend_call_receiver(node, qualified_prefix)
        return if owner.nil?

        write_mixin_targets(accumulator, owner, targets, prepend: node.name == :prepend)
      end

      # Issue #1123 — one class's contribution to the two tables. A prepended module lands in BOTH: the
      # include list is the SET of modules a class carries (arity, visibility, reflection and constant-scope
      # consumers read it that way), while the prepend table adds the ORDER and the KIND.
      #
      # Issue #1173 — `include` now stores instance-ancestor SEARCH order too, the same convention
      # `prepend` already keeps: each statement's argument list lands as one unit (`include A, B` keeps
      # `["A", "B"]`, the order Ruby searches them) AHEAD of the earlier statements' (`include A;
      # include B` searches B first). Call order was never a semantic — it is where this list happened
      # to be written — and every order-sensitive consumer (the BFS mixin step, the external-ancestor
      # walk, override visibility) reads nearer-first. A re-`include` of an already-carried name is a
      # runtime no-op (`Module#append_features` is skipped when the module is already an ancestor), so
      # a present target does not re-position itself. The prepend names still join the include list at
      # freeze time — ahead of every include, where Ruby puts them.
      def write_mixin_targets(accumulator, owner, targets, prepend:)
        bucket = accumulator[owner] ||= {}
        if prepend
          (bucket[:prepend] ||= []).unshift(*targets)
        else
          list = (bucket[:include] ||= [])
          list.unshift(*targets.reject { |target| list.include?(target) })
        end
      end

      # Whether a mixin call contributes to the tables at all: a receiverless `include` / `prepend` needs an
      # enclosing declaration to file the edge under, and the RECEIVER form is recorded for `prepend` only
      # — `Base.include(Loud)` is deliberately still unrecorded. Nothing needs it (this issue orders
      # `prepend`, and the receiver form of `include` has no ordering question to answer) while recording
      # it would widen what every consumer says about a class, which is scope this change does not own.
      def mixin_call_recorded?(node, current_class)
        return false unless MIXIN_CALL_NAMES.include?(node.name)
        return !current_class.nil? if node.receiver.nil?

        node.name == :prepend
      end

      # Issue #1123 — the class a `Recv.prepend(M)` call form targets, as the qualified name the prepend
      # table is keyed by, or nil when the receiver names no static class. The receiver is a constant READ
      # at the call site, so it resolves in the `Module.nesting` the call is written in — the same rule (and
      # the same helper) `class_eval` receivers follow: `::B` names the top level wherever it is written, an
      # unqualified `X` is `<nesting entry>::X` for the innermost entry the FILE declares, and the
      # as-written name stands when no rung declares it. A receiver that names no project class keys a table
      # entry nothing reads, which is the same silence as not recording it at all.
      def prepend_call_receiver(node, lexical_prefix)
        receiver = node.receiver
        return nil if receiver.is_a?(Prism::SelfNode)

        rendered = Source::ConstantPath.qualified_name_or_nil(receiver)
        return nil if rendered.nil?
        return rendered if Source::ConstantPath.rooted?(receiver) || lexical_prefix.empty?

        eval_constant_receiver_prefix(node, receiver, rendered, lexical_prefix).join("::")
      end

      # Issue #526 — `extend M` / `extend self` / bare `module_function`, the singleton-side siblings of
      # {#build_discovered_includes}. `extend self` and the bare `module_function` toggle both map the
      # module's own instance defs onto its singleton (recorded as extending ITSELF); `module_function`
      # with symbol arguments already resolves through the existing recording, and the toggle's
      # order-sensitivity (only SUBSEQUENT defs become module functions) is deliberately over-approximated
      # — the extra names only suppress `undefined-method` and enable inference on calls that raise at
      # runtime, both the ADR-5-safe direction.
      #
      # Issue #915 — plus `class << self; include M; end`, the same singleton ancestor spelled through the
      # singleton-class body. It folds like an `extend` because Ruby makes it one.
      def build_discovered_extends(root)
        accumulator = {}
        walk_class_extends(root, [], nil, accumulator)
        accumulator.transform_values { |mods| mods.uniq.freeze }.freeze
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
          # written in it is the same singleton ancestor an `extend` in the class body would add. Only the
          # `self` form is followed: `class << obj` names something this walk cannot resolve to a class.
          # Nested declarations inside the body take the `ClassNode` branch above and reset the flag with
          # their own owner, so the marker cannot leak past the singleton body it belongs to.
          return walk_extends_singleton_class(node, qualified_prefix, current_class, accumulator,
                                              in_singleton, singleton_self, singleton_cref)
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
             Prism::ConstantPathOrWriteNode
          return if walk_extends_meta_new?(node, qualified_prefix, current_class, accumulator,
                                           in_singleton, singleton_self, singleton_cref)
        when Prism::CallNode
          record_extend_call(node, current_class, accumulator, in_singleton: in_singleton)
          if receiver_eval_call?(node)
            return walk_eval_extends_call(node, qualified_prefix, current_class, accumulator,
                                          in_singleton: in_singleton, singleton_self: singleton_self,
                                          singleton_cref: singleton_cref)
          end
          if node.block.is_a?(Prism::BlockNode)
            return walk_extends_block_call(node, qualified_prefix, current_class, accumulator,
                                           in_singleton, singleton_self, singleton_cref)
          end
        end

        node.rigor_each_child do |child|
          walk_class_extends(child, qualified_prefix, current_class, accumulator,
                             in_singleton: in_singleton, singleton_self: singleton_self,
                             singleton_cref: singleton_cref)
        end
      end

      # The `class <<` arm of {#walk_class_extends}: the expression evaluates in the enclosing
      # context while the body is the singleton's — `class << self` keeps the enclosing owner
      # (its `include` is the singleton ancestor #915 folds), other operands walk ownerless.
      # `self` inside is the singleton — `self::` receivers decline — and the lexical cref
      # below is unnameable in every case.
      def walk_extends_singleton_class(node, qualified_prefix, current_class, accumulator,
                                       in_singleton, singleton_self, singleton_cref)
        walk_class_extends(node.expression, qualified_prefix, current_class, accumulator,
                           in_singleton: in_singleton, singleton_self: singleton_self,
                           singleton_cref: singleton_cref)
        return unless node.body

        # `class << self` keeps the owner only at the FIRST level — nested inside a
        # singleton body, `self` IS the singleton and `class << self` opens the
        # singleton's own singleton (`#<Class:#<Class:C>>`), which nothing names.
        opens_self = node.expression.is_a?(Prism::SelfNode) && !in_singleton
        walk_class_extends(node.body, qualified_prefix, opens_self ? current_class : nil,
                           accumulator, in_singleton: opens_self,
                                        singleton_self: true, singleton_cref: true)
      end

      # The declaration arm of {#walk_class_extends}: under an unnameable cref a bare/`self::`
      # header opens `#<singleton>::Name` — ownerless; nameable headers re-anchor at a
      # real cref.
      def walk_extends_declaration(node, qualified_prefix, accumulator, current_class,
                                   singleton_cref)
        self_decl = self_anchored_decl_prefix(node.constant_path, current_class && [current_class])
        child_prefix = self_decl ||
                       Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
        return unless child_prefix && node.body

        child_cref = unnameable_decl?(node, self_decl, singleton_cref)
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
        return unless node.name == :define_method || meta_new_constant_rvalue?(node)

        walk_extends_opaque_block(node, qualified_prefix, current_class, accumulator,
                                  in_singleton, singleton_self, singleton_cref)
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
        call = meta_new_block_call(node)
        return false unless call

        meta_owner = meta_new_mixin_owner(node, qualified_prefix, singleton_cref,
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
        if (body = call.block&.body)
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
                             (in_singleton && !eval_named_receiver?(node)))
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
        child_unnameable = eval_named_receiver?(node) ? eval_class.nil? : unnameable
        node.block.rigor_each_child do |child|
          walk_class_extends(child, qualified_prefix, eval_class, accumulator,
                             in_singleton: eval_in_singleton, singleton_self: child_unnameable,
                             singleton_cref: singleton_cref)
        end
      end

      # The class a `*_eval` / `*_exec` block body opens — the nameable receiver, or nil when the
      # receiver is not nameable ({#eval_receiver_prefix} spelled as a name). `self_prefix` is the
      # enclosing body's self — the owner the extends walk already tracks — so a `self` / bare /
      # `self::` receiver inside an eval body names the enclosing eval's class.
      def eval_receiver_name(node, qualified_prefix, self_prefix = nil, unnameable_self: false)
        # A nil `self_prefix` means the enclosing self names nothing — `class << obj`, an
        # ownerless eval or `#<singleton>::D` body. Substituting the lexical prefix there would
        # file the body's edges under a class `self` never is, so the receiver declines.
        prefix = eval_receiver_prefix(node, self_prefix || EMPTY_PREFIX, qualified_prefix,
                                      unnameable_self: unnameable_self)
        prefix && !prefix.empty? ? prefix.join("::") : nil
      end

      # Inside a `class << self` body the mixin calls are the singleton-side ones and `extend` is not:
      # `class << self; extend M; end` puts M on the singleton's OWN singleton, one level further out than
      # anything this table describes, and `module_function` in a singleton body is not the scope toggle
      # {#build_discovered_extends} over-approximates. So the two arms are disjoint rather than additive.
      def record_extend_call(node, current_class, accumulator, in_singleton: false)
        return unless current_class && node.receiver.nil?

        if in_singleton
          record_extend_targets(node, current_class, accumulator) if MIXIN_CALL_NAMES.include?(node.name)
          return
        end

        case node.name
        when :extend then record_extend_targets(node, current_class, accumulator)
        when :module_function
          (accumulator[current_class] ||= []) << current_class if bare_module_function?(node)
        end
      end

      # The table stores search order, not call order: a later `extend` statement prepends its module
      # (`extend A; extend B` → singleton ancestors `[B, A]`) while the arguments of a single
      # `extend A, B` keep call order (`[A, B]`). Prepending each call's argument list preserves both,
      # and consumers iterating the list forward read the same order the singleton ancestry searches.
      def record_extend_targets(node, current_class, accumulator)
        targets = []
        node.arguments&.arguments&.each do |arg|
          target = arg.is_a?(Prism::SelfNode) ? current_class : Source::ConstantPath.qualified_name(arg)
          targets << target if target
        end
        (accumulator[current_class] ||= []).unshift(*targets) unless targets.empty?
      end

      # The materialization half of #526: for every `C extends M`, M's INSTANCE defs become C's
      # SINGLETON defs — existence (so `C.helper` stops firing undefined-method) and def nodes (so
      # call-site return inference runs with `self = Singleton[C]`, which is what Ruby binds). A name C
      # already defines on its own singleton wins (`||=`); an extend target with no discovered defs
      # contributes nothing (RBS-module extends stay on the dispatch tiers).
      def fold_extends_into_singleton_tables(extends, def_nodes, singleton_def_nodes, methods)
        extends.each do |class_name, mods|
          mods.each do |mod_name|
            source_defs = extend_source_defs(def_nodes, class_name, mod_name)
            next if source_defs.nil?

            # An inner table inherited unchanged from a frozen seed must be thawed before the fold writes.
            target = singleton_def_nodes[class_name]
            target = singleton_def_nodes[class_name] = (target ? target.dup : {}) if target.nil? || target.frozen?
            source_defs.each do |method_name, def_node|
              target[method_name] ||= def_node
              record_method_kind(methods, class_name, method_name, :singleton)
            end
          end
        end
      end

      # `extend CustomSig` inside `module Outer; class F` stores the as-written name, while
      # `def_nodes` keys the module's defs as `Outer::CustomSig`. Walk the enclosing namespaces
      # innermost-first so the fold finds the same module Ruby constant-lookup would.
      def extend_source_defs(def_nodes, class_name, mod_name)
        found = def_nodes[mod_name]
        return found if found
        return nil if mod_name.nil? || mod_name.start_with?("::")

        parts = class_name.to_s.split("::")
        while parts.size > 1
          parts.pop
          found = def_nodes["#{parts.join('::')}::#{mod_name}"]
          return found if found
        end
        nil
      end

      VISIBILITY_MODIFIERS = %i[public private protected].freeze

      # v0.1.2 — per-class method-visibility table for the `def.method-visibility-mismatch` CheckRule.
      #
      # Tracks two visibility-changing forms:
      #
      # - **Modifier blocks**: a bare `private` / `protected` /
      #   `public` call inside a class body switches the
      #   "current default" visibility for every subsequent
      #   `def` until another modifier flips it again.
      # - **Named-argument form**: `private :foo, :bar` (or
      #   the same with `protected` / `public`) marks specific
      #   names already-recorded under the class. Symbol-only
      #   args are recognised; `private def foo; end` (the
      #   wrap-around form) is not yet — it would need
      #   tracking the def-call's return-value visibility,
      #   which is a separate slice.
      #
      # Top-level (no surrounding class) defs do not contribute — Ruby's top-level visibility nuances (private at
      # top-level marks the method on `Object`) are out of scope for v0.1.2.
      def build_discovered_method_visibilities(root)
        accumulator = {}
        walk_method_visibilities(root, [], false, :public, accumulator)
        accumulator.transform_values(&:freeze).freeze
      end

      # rubocop:disable-next Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Metrics/AbcSize
      def walk_method_visibilities(node, qualified_prefix, in_singleton_class, current_visibility, accumulator, # rubocop:disable Metrics/ParameterLists
                                   def_owner_prefix = nil, singleton_cref: false,
                                   defs_singleton: false)
        return current_visibility unless node.is_a?(Prism::Node)

        owner_prefix = def_owner_prefix || qualified_prefix
        case node
        when Prism::ClassNode, Prism::ModuleNode
          self_decl = self_anchored_decl_prefix(node.constant_path,
                                                in_singleton_class ? EMPTY_PREFIX : def_owner_prefix)
          child_prefix = self_decl ||
                         Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
          if child_prefix
            # Under an unnameable cref a bare/`self::` header opens `#<singleton>::Name` —
            # ownerless; nameable headers re-anchor at a real cref.
            child_cref = unnameable_decl?(node, self_decl, singleton_cref)
            body_prefix = child_cref ? [] : child_prefix
            if node.body
              walk_method_visibilities(node.body, body_prefix, false, :public,
                                       accumulator, nil, singleton_cref: child_cref)
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
          if (split = meta_new_block_split(node, qualified_prefix, def_owner_prefix, singleton_cref))
            enclosing, body, body_self = split
            enclosing.each do |part|
              walk_method_visibilities(part, qualified_prefix, in_singleton_class,
                                       current_visibility, accumulator, def_owner_prefix,
                                       singleton_cref: singleton_cref,
                                       defs_singleton: defs_singleton)
            end
            if body
              walk_method_visibilities(body, qualified_prefix, false, :public,
                                       accumulator, body_self,
                                       singleton_cref: singleton_cref)
            end
            return current_visibility
          end
        when Prism::DefNode
          record_def_visibility(node, owner_prefix, in_singleton_class || defs_singleton,
                                current_visibility, accumulator)
          return current_visibility
        when Prism::CallNode
          if receiver_eval_call?(node)
            walk_eval_visibilities(node, qualified_prefix, in_singleton_class, current_visibility,
                                   accumulator, def_owner_prefix, singleton_cref: singleton_cref,
                                                                  defs_singleton: defs_singleton)
            return current_visibility
          end
          # The visibility table is instance-side only — `private :x` inside `class <<`
          # (or a receiver-eval body that re-evaluates a singleton self) marks the
          # SINGLETON method, which this table cannot express.
          updated = if in_singleton_class
                      current_visibility
                    else
                      apply_visibility_call(node, owner_prefix, current_visibility, accumulator)
                    end
          return updated unless updated.equal?(current_visibility)
        end

        # Statement-position StatementsNode preserves left-to-right visibility flow; everything else recurses with the
        # entry visibility unchanged.
        if node.is_a?(Prism::StatementsNode)
          local_visibility = current_visibility
          node.rigor_each_child do |child|
            local_visibility = walk_method_visibilities(child, qualified_prefix, in_singleton_class,
                                                        local_visibility, accumulator, def_owner_prefix,
                                                        singleton_cref: singleton_cref,
                                                        defs_singleton: defs_singleton)
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

        walk_method_visibilities(node.body, qualified_prefix, true, :public, accumulator,
                                 singleton_prefix, singleton_cref: true)
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
        node.arguments&.arguments&.each do |arg|
          walk_method_visibilities(arg, qualified_prefix, in_singleton_class, current_visibility,
                                   accumulator, def_owner_prefix, singleton_cref: singleton_cref,
                                                                  defs_singleton: defs_singleton)
        end
        self_prefix = def_owner_prefix || qualified_prefix
        unnameable = unnameable_eval_self?(in_singleton_class, def_owner_prefix, qualified_prefix,
                                           singleton_cref)
        eval_prefix = eval_receiver_prefix(node, self_prefix, qualified_prefix,
                                           unnameable_self: unnameable) || []
        # `instance_eval`'s `def`s are singleton-side (`defs_singleton` — skipped by the
        # instance-visibility table), while `public`/`private` are calls on the
        # receiver-as-module and stay instance-side (`in_singleton_class` off) for a class
        # receiver.
        call_singleton, defs_flag = eval_body_def_context(node, in_singleton_class)
        node.block.rigor_each_child do |child|
          walk_method_visibilities(child, qualified_prefix, call_singleton, :public, accumulator,
                                   eval_prefix, singleton_cref: singleton_cref,
                                                defs_singleton: defs_flag)
        end
      end

      def record_def_visibility(def_node, qualified_prefix, in_singleton_class, current_visibility, accumulator)
        return if def_node.receiver.is_a?(Prism::SelfNode) || in_singleton_class
        return if qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        accumulator[class_name] ||= {}
        accumulator[class_name][def_node.name] = current_visibility
      end

      # Recognises modifier calls on the implicit-self receiver inside a class body. Returns the (possibly updated)
      # current visibility:
      #
      # - `private` / `public` / `protected` (no args) —
      #   switch the running default for subsequent defs.
      # - `private :foo, :bar` — back-patch the named methods
      #   in the accumulator. Returns `current_visibility`
      #   unchanged because the running default does NOT
      #   change for this form.
      def apply_visibility_call(call_node, qualified_prefix, current_visibility, accumulator)
        return current_visibility unless call_node.receiver.nil?
        return current_visibility unless VISIBILITY_MODIFIERS.include?(call_node.name)
        return current_visibility if qualified_prefix.empty?

        args = call_node.arguments&.arguments || []
        if args.empty?
          call_node.name
        else
          apply_named_visibility(args, qualified_prefix, call_node.name, accumulator)
          current_visibility
        end
      end

      def apply_named_visibility(args, qualified_prefix, visibility, accumulator)
        class_name = qualified_prefix.join("::")
        args.each do |arg|
          name = visibility_target_name(arg)
          next if name.nil?

          accumulator[class_name] ||= {}
          accumulator[class_name][name] = visibility
        end
      end

      def visibility_target_name(arg)
        return arg.unescaped.to_sym if arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode)

        nil
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
          record_method_envelope_opaque(tables, class_name, method_name) if method_name
        end
      end

      # Both kinds, and the envelope table only: the evidence says something rewrites the name, not which
      # side it lives on, and it is not evidence that the name EXISTS, so the existence table is untouched.
      def record_method_envelope_opaque(tables, class_name, method_name)
        %i[instance singleton].each do |kind|
          record_envelope(tables.envelopes, class_name, [kind, method_name], Source::ParameterEnvelope::OPAQUE)
        end
      end

      # The receiverless class-body calls whose symbol arguments are never a method being rewritten, so they
      # may name a method without making its envelope opaque. Deliberately short: a macro missing from it
      # costs a check on that one name, while a wrapping macro wrongly listed here (`memoize :f`,
      # `def_delegator :@x, :f`) would leave a `def`'s envelope standing for a method that no longer has it.
      NAME_NEUTRAL_MACROS = %i[
        private public protected module_function private_class_method public_class_method
        private_constant public_constant require require_relative autoload
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
        end
      end

      def record_self_surface_evidence(node, qualified_prefix, tables)
        return if qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        if dynamic_surface_call?(node)
          record_surface_mark(tables, class_name, Scope::DiscoveryIndex::ENVELOPE_DYNAMIC_MARK)
        elsif node.name == :refine
          record_refinement(node, qualified_prefix, tables)
        elsif !NAME_NEUTRAL_MACROS.include?(node.name)
          (node.arguments&.arguments || []).each do |argument|
            # `memoize def f(a)` wraps the def it is handed exactly as `memoize :f` does.
            method_name = argument.is_a?(Prism::DefNode) ? argument.name : literal_method_name(argument)
            record_method_envelope_opaque(tables, class_name, method_name) if method_name
          end
        end
      end

      # `refine Widget do def f(a, b) … end end` redefines `Widget#f` in every file that says `using`, and this
      # walk records the block's `def`s on the refining module instead.
      def record_refinement(node, qualified_prefix, tables)
        target = node.arguments&.arguments&.first
        return unless target.is_a?(Prism::ConstantReadNode) || target.is_a?(Prism::ConstantPathNode)

        constant_receiver_candidates(target, qualified_prefix).each do |name|
          record_surface_mark(tables, name, Scope::DiscoveryIndex::ENVELOPE_DYNAMIC_MARK)
        end
      end

      def surface_rewriting_call?(node)
        SURFACE_EVAL_CALLS.include?(node.name) || SURFACE_NAMING_CALLS.include?(node.name) ||
          SURFACE_SEND_CALLS.include?(node.name) || ATTR_MACROS.include?(node.name) || surface_mixin_call?(node)
      end

      def surface_mixin_call?(node)
        SURFACE_MIXIN_CALLS.include?(node.name) || SURFACE_MIXIN_HELPER.match?(node.name.to_s)
      end

      def dynamic_surface_call?(node)
        return true if SURFACE_EVAL_CALLS.include?(node.name) || SURFACE_SEND_CALLS.include?(node.name)

        arguments = node.arguments&.arguments || []
        if SURFACE_NAMING_CALLS.include?(node.name)
          arguments.empty? || literal_method_name(arguments.first).nil?
        elsif surface_mixin_call?(node)
          arguments.any? do |argument|
            !(argument.is_a?(Prism::ConstantReadNode) || argument.is_a?(Prism::ConstantPathNode) ||
              argument.is_a?(Prism::SelfNode))
          end
        else
          false
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

      # Post-pass over the `def_nodes` accumulator: for every `alias` declaration inside a class body, if the original
      # method name maps to a `Prism::DefNode`, register the new name pointing to the same node so inter-procedural
      # return-type inference works for the aliased name.
      def apply_alias_def_nodes(root, accumulator)
        alias_map = collect_class_alias_map(root, [], {})
        alias_map.each do |class_name, aliases|
          class_defs = accumulator[class_name]
          next unless class_defs

          aliases.each do |new_name, old_name|
            def_node = class_defs[old_name]
            next unless def_node.is_a?(Prism::DefNode)

            (accumulator[class_name] ||= {})[new_name] = def_node
          end
        end
      end

      # Builds a map `{class_name => {new_name_sym => old_name_sym}}` by walking the tree for `AliasMethodNode` nodes
      # inside class bodies. `leaf_owner` is the meta-new override: inside `K = Class.new { … }` the
      # block's aliases bind on the class the write names — it overrides `qualified_prefix`, which
      # keeps naming the enclosing lexical cref for declarations.
      def collect_class_alias_map(node, qualified_prefix, accumulator, leaf_owner = nil,
                                  singleton_cref: false, defs_singleton: false)
        return accumulator unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          return collect_alias_map_declaration(node, qualified_prefix, accumulator, leaf_owner,
                                               singleton_cref)
        when Prism::SingletonClassNode
          return collect_alias_map_singleton(node, qualified_prefix, accumulator, leaf_owner,
                                             singleton_cref)
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
             Prism::ConstantPathOrWriteNode
          return accumulator if collect_alias_map_meta_new?(node, qualified_prefix, accumulator,
                                                            leaf_owner, singleton_cref)
        when Prism::AliasMethodNode, Prism::CallNode
          return accumulator if record_alias_leaf?(node, qualified_prefix, accumulator,
                                                   leaf_owner, singleton_cref,
                                                   defs_singleton: defs_singleton)
          return accumulator if collect_alias_map_block_call?(node, qualified_prefix, accumulator,
                                                              leaf_owner, singleton_cref)
        end

        node.rigor_each_child do |child|
          collect_class_alias_map(child, qualified_prefix, accumulator, leaf_owner,
                                  singleton_cref: singleton_cref,
                                  defs_singleton: defs_singleton)
        end
        accumulator
      end

      # The alias-leaf arm of {#collect_class_alias_map}: inside a `class <<` body the alias binds
      # on the singleton — the map files nothing; a re-anchored declaration below it clears the
      # flag again, and a meta-new block's `leaf_owner` re-anchors it onto the named class.
      # Returns true when the leaf was consumed (AliasMethodNode always; a recognised
      # `alias_method` call), false when the node is an ordinary call to keep walking.
      def record_alias_leaf?(node, qualified_prefix, accumulator, leaf_owner, singleton_cref,
                             defs_singleton: false)
        rec_prefix = leaf_owner || qualified_prefix
        if node.is_a?(Prism::AliasMethodNode)
          # `defs_singleton` is the instance_eval split: the `alias` keyword binds on the
          # receiver's singleton, while `alias_method` — a call on the receiver-as-module —
          # stays instance-side and still records.
          unless defs_singleton || (singleton_cref && leaf_owner.nil?)
            record_alias_map_entry(node, rec_prefix, accumulator)
          end
          return true
        end
        return false unless node.is_a?(Prism::CallNode)

        # `alias_method :new, :old` — the CallNode twin of the `alias` keyword (#533; liquid's i18n
        # `t` alias was the corpus case). Unlike AliasMethodNode a call's children can carry further
        # class bodies (`Class.new do … end`), so the walk continues below it either way.
        names = alias_method_call_names(node)
        if names && !rec_prefix.empty? && !(singleton_cref && leaf_owner.nil?)
          (accumulator[rec_prefix.join("::")] ||= {})[names.first] = names.last
        end
        false
      end

      # The rebinding-block call arm of {#collect_class_alias_map}: an anonymous meta-new call
      # (`Class.new { … }` no write names) files its block's aliases nowhere, and an eval-family
      # call binds them on the receiver — a nameable receiver re-anchors the owner while a
      # receiver that names nothing, or an unnameable self below `class <<`, walks ownerless.
      def collect_alias_map_block_call?(node, qualified_prefix, accumulator, leaf_owner,
                                        singleton_cref)
        return false unless node.is_a?(Prism::CallNode) && node.block.is_a?(Prism::BlockNode)

        if meta_new_constant_rvalue?(node)
          block_owner = []
        elsif receiver_eval_call?(node)
          self_prefix = leaf_owner || qualified_prefix
          unnameable = unnameable_eval_self?(false, leaf_owner, qualified_prefix,
                                             singleton_cref)
          block_owner = eval_receiver_prefix(node, self_prefix, qualified_prefix,
                                             unnameable_self: unnameable) || []
        else
          return false
        end

        [node.receiver, *node.arguments&.arguments.to_a].compact.each do |part|
          collect_class_alias_map(part, qualified_prefix, accumulator, leaf_owner,
                                  singleton_cref: singleton_cref)
        end
        if (body = node.block.body)
          collect_class_alias_map(body, qualified_prefix, accumulator, block_owner,
                                  singleton_cref: singleton_cref,
                                  defs_singleton: INSTANCE_EVAL_CALLS.include?(node.name))
        end
        true
      end

      # The meta-new arm of {#collect_class_alias_map}: the write's receiver and arguments keep
      # the enclosing context; the block's aliases bind on the class the write names, or file
      # nothing when the write is unnameable below an unnameable cref.
      def collect_alias_map_meta_new?(node, qualified_prefix, accumulator, leaf_owner,
                                      singleton_cref)
        call = meta_new_block_call(node)
        return false unless call

        child_prefix = meta_new_child_prefix(node, qualified_prefix, leaf_owner)
        meta_ownerless = singleton_cref && !meta_new_path_target_nameable?(node, leaf_owner)
        [call.receiver, *call.arguments&.arguments.to_a].compact.each do |part|
          collect_class_alias_map(part, qualified_prefix, accumulator, leaf_owner,
                                  singleton_cref: singleton_cref)
        end
        if (body = meta_new_block_body(node))
          collect_class_alias_map(body, qualified_prefix, accumulator,
                                  (meta_ownerless ? nil : child_prefix) || [],
                                  singleton_cref: singleton_cref)
        end
        true
      end

      # `[new_name, old_name]` for an implicit-self `alias_method` call with two literal symbol /
      # string arguments, or nil. A variable-named alias is runtime data and stays unrecorded.
      def alias_method_call_names(call_node)
        return nil unless call_node.name == :alias_method && call_node.receiver.nil?

        args = call_node.arguments&.arguments
        return nil unless args && args.size == 2

        new_name = literal_method_name(args[0])
        old_name = literal_method_name(args[1])
        return nil if new_name.nil? || old_name.nil?

        [new_name, old_name]
      end

      # The class/module arm of {#collect_class_alias_map}: under an unnameable cref a
      # bare/`self::` header opens `#<singleton>::Name` — the map files nothing for it;
      # a rooted or explicit-base header re-anchors at a nameable prefix.
      def collect_alias_map_declaration(node, qualified_prefix, accumulator, leaf_owner,
                                        singleton_cref)
        self_decl = self_anchored_decl_prefix(node.constant_path, leaf_owner)
        child_prefix = self_decl ||
                       Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
        return accumulator unless child_prefix

        child_cref = unnameable_decl?(node, self_decl, singleton_cref)
        if node.body
          collect_class_alias_map(node.body, child_cref ? [] : child_prefix, accumulator,
                                  singleton_cref: child_cref)
        end
        accumulator
      end

      # The `class <<` arm of {#collect_class_alias_map}: the expression evaluates in the
      # enclosing context (`class << (class D; self; end)` → `C::D`), while the body is a
      # singleton context the map files nothing for directly — a nameable declaration
      # inside still re-anchors through the flag.
      def collect_alias_map_singleton(node, qualified_prefix, accumulator, leaf_owner,
                                      singleton_cref)
        collect_class_alias_map(node.expression, qualified_prefix, accumulator, leaf_owner,
                                singleton_cref: singleton_cref)
        if node.body
          # `self` below `class <<` is the singleton class — `self::`-anchored receivers
          # decline; a named eval receiver still re-anchors to a real class.
          collect_class_alias_map(node.body, qualified_prefix, accumulator, [],
                                  singleton_cref: true)
        end
        accumulator
      end

      def record_alias_map_entry(alias_node, qualified_prefix, accumulator)
        return if qualified_prefix.empty?
        return unless alias_node.new_name.is_a?(Prism::SymbolNode) && alias_node.old_name.is_a?(Prism::SymbolNode)

        class_name = qualified_prefix.join("::")
        new_name = alias_node.new_name.unescaped.to_sym
        old_name = alias_node.old_name.unescaped.to_sym
        (accumulator[class_name] ||= {})[new_name] = old_name
      end

      def record_define_method(call_node, qualified_prefix, in_singleton_class, accumulator)
        return if qualified_prefix.empty?
        return if call_node.arguments.nil? || call_node.arguments.arguments.empty?

        first_arg = call_node.arguments.arguments.first
        method_name = literal_method_name(first_arg)
        return if method_name.nil?

        class_name = qualified_prefix.join("::")
        record_method(accumulator, class_name, method_name, in_singleton_class ? :singleton : :instance)
      end

      # The `attr_*` accessor macros that introduce methods Rigor must treat as source-declared. Without this, a class
      # that defines an accessor with `attr_reader :x` AND carries RBS that omits `x` (a common gap — the project ships
      # an incomplete `sig/`) fires a false `call.undefined-method` on `obj.x`, because the undefined-method rule only
      # suppressed `def` / `define_method` / `alias_method`-discovered methods. `attr_reader` defines readers,
      # `attr_writer` writers (`x=`), `attr_accessor` both.
      ATTR_MACROS = %i[attr_reader attr_writer attr_accessor].freeze

      def record_attr_methods(call_node, qualified_prefix, in_singleton_class, accumulator)
        return if qualified_prefix.empty?
        return unless call_node.receiver.nil? # only the implicit-self macro defines on the lexical class
        return if call_node.arguments.nil?

        kind = in_singleton_class ? :singleton : :instance
        reader = call_node.name != :attr_writer
        writer = call_node.name != :attr_reader
        class_name = qualified_prefix.join("::")
        call_node.arguments.arguments.each do |arg|
          base = literal_method_name(arg)
          next if base.nil?

          record_method(accumulator, class_name, base, kind) if reader
          record_method(accumulator, class_name, :"#{base}=", kind) if writer
        end
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
      MODULE_ATTR_MACROS = {
        mattr_reader: [true, false, false], mattr_writer: [false, true, false],
        mattr_accessor: [true, true, false], cattr_reader: [true, false, false],
        cattr_writer: [false, true, false], cattr_accessor: [true, true, false],
        class_attribute: [true, true, true]
      }.freeze
      Ractor.make_shareable(MODULE_ATTR_MACROS)

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

      def record_both_kinds(accumulator, class_name, method_name)
        record_method(accumulator, class_name, method_name, :instance)
        record_method(accumulator, class_name, method_name, :singleton)
      end

      def literal_method_name(node)
        return nil unless node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)

        node.unescaped&.to_sym
      end

      # Walks every file in `paths` (each path is parsed once with `Prism.parse_file`) and returns the unioned
      # project-wide `discovered_classes` Hash: `{qualified_name => Singleton[…]}`. Used by `Analysis::Runner` to seed
      # each file's `default_scope.discovered_classes` so that lexical constant lookup in one file resolves a `class
      # Foo` declared in a sibling file. Per-file collisions are last-write-wins (matches the existing in-file merge
      # semantics). Parse failures fail-soft to an empty contribution. The `buffer` argument, when present, redirects
      # reads for the bound logical path to the buffer's physical path so editor-mode pre-passes see the in-flight
      # bytes.
      #
      # Modules are registered on the same terms as classes, matching `record_declarations`' per-file behaviour (ADR-57
      # WD3). An earlier revision excluded them, fearing an undiscovered `M.x` would fall through to `Kernel#x`; the
      # exclusion was retired once measurement showed Kernel's private instance methods (`select`, `puts`, `load`, …)
      # resolve to nothing on a `Singleton[M]` receiver, and that a project-side `def self.x` body wins over the lenient
      # `Singleton[Object]` fallback anyway. The residual leak is `Class`-only (`M.new`, `M.superclass`), which mistypes
      # only code that raises `NoMethodError` at runtime.
      #
      def discovered_classes_for_paths(paths, buffer: nil)
        accumulator = {}
        paths.each do |path|
          physical = buffer ? buffer.resolve(path) : path
          source = File.read(physical)
          root = Prism.parse(source, filepath: path).value
          collect_class_decls(root, [], accumulator)
        rescue StandardError
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
      # `CheckRules#undefined_method_diagnostic` consults the seeded copy to name the defining file when a project
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
          accumulate_project_index(acc, path, root)
        rescue StandardError
          # Skip files that fail to parse or read; the per-file analyzer surfaces the parse error separately.
          next
        end
        finalize_def_index(acc)
      end

      # B1 / ADR-89 WD1 (incremental propagation gates) — parses `paths` ONCE and returns the merged def-index
      # (as {#discovered_def_index_for_paths}), each file's comment-stripped {#code_fingerprint} (B1), AND each
      # file's {#declaration_signature} (ADR-89 WD1 — the per-def SIGNATURE shape that replaces the per-def body
      # fingerprint, so a body edit that leaves every signature equal is declaration-stable). The incremental
      # session drives the fingerprint / class-declaration change detection off `def_index` and the
      # declaration-stability skip decision off `declaration_signatures`, so a changed file is parsed once for
      # all of them (recon §2 dedup). A per-file live index (built + folded, exactly as
      # {#discovered_project_index_incremental}'s changed-file branch) yields the live def nodes the signature
      # reads their parameter structure from.
      # @return `{ def_index:, code_fingerprints:, declaration_signatures: }`.
      def scan_summary_for_paths(paths, buffer: nil)
        acc = new_def_index_accumulator
        code_fingerprints = {}
        declaration_signatures = {}
        paths.each do |path|
          physical = buffer ? buffer.resolve(path) : path
          source = File.read(physical)
          parsed = Prism.parse(source, filepath: path)
          file_index = build_file_index(path, parsed.value)
          fold_file_index(acc, file_index)
          code_fingerprints[path] = code_fingerprint(source, parsed.comments)
          declaration_signatures[path] = declaration_signature(file_index)
        rescue StandardError
          next
        end
        { def_index: finalize_def_index(acc), code_fingerprints: code_fingerprints,
          declaration_signatures: declaration_signatures }
      end

      # ADR-89 WD1 — a per-file digest of every cross-file DECLARATION surface an ancestry / file-level
      # dependent consumes, EXCLUDING method bodies (which only symbol dependents consume, via the ADR-46
      # symbol edges the change-detection already fingerprints per method). A body edit that touches no
      # signature leaves this equal, so the session drops the file's ancestry / file-level dependents; an
      # arity / visibility / added-or-removed-method / ancestry / member-layout edit moves it. Deliberately
      # SYNTACTIC (parameter structure from the def node, not inferred types).
      #
      # It captures, from a single file's live def-index: declared class/module names, superclass + include
      # ancestry, Data/Struct member layouts, the accessor/alias/define_method existence table, per-method
      # visibilities, and per method (instance + singleton) its name, parameter signature, AND def-start LINE.
      # The line is load-bearing for soundness: a body edit that SHIFTS a later def's line moves the ADR-17
      # `project_definition_site` a `call.undefined-method` consumer embeds, so a line shift must invalidate
      # the declaration (the file's dependents re-check) — this is why the signature is a superset of B1's
      # comment-stripped code fingerprint on line-moving edits, and strictly more permissive only on
      # same-line body edits (a local rename, an internal literal), which is the collapse WD1 exists for.
      def declaration_signature(file_index)
        parts = []
        append_ancestry_signature(parts, file_index)
        append_constant_signature(parts, file_index)
        append_declaration_tables(parts, file_index)
        append_def_signatures(parts, file_index[:def_nodes], "#")
        append_def_signatures(parts, file_index[:singleton_def_nodes], ".")
        append_envelope_signature(parts, file_index[:parameter_envelopes] || {})
        Digest::SHA256.hexdigest(parts.join("\x00"))
      end

      # Issue #992 — the joined envelope table is a declaration surface the per-def signatures above cannot
      # reconstruct: they keep the LAST `def` of a name, and they see neither a second `def` with another
      # shape nor a `memoize :f` beside it, either of which moves a dependent's `call.wrong-arity` verdict.
      def append_envelope_signature(parts, envelopes)
        envelopes.sort_by { |cn, _| cn.to_s }.each do |class_name, entries|
          entries.map { |key, envelope| "a:#{class_name}#{key.inspect}=#{envelope.inspect}" }.sort.each do |part|
            parts << part
          end
        end
      end

      # Issue #644 — the cross-file VALUE-constant surface. Load-bearing for soundness, not precision: a
      # file's published constants are a declaration-level fact its file-level dependents consume, so
      # `FOO = :sym` becoming `FOO = :other` MUST move this signature or the reader would be declaration-
      # stable, dropped from the closure, and served the pre-edit `:sym`. Both halves are here: the write
      # NAMES (an added / removed / renamed assignment) and the published VALUES (a same-name value edit).
      def append_constant_signature(parts, file_index)
        parts.concat((file_index[:constant_writes] || {}).sort.map do |name, by_path|
          "k:#{name}=#{constant_descriptor_signature(by_path.values.first)}"
        end)
      end

      # `[literal]` renders its value, a `||=`-only name `||`, and an unpublishable write `?`. All three halves
      # matter: a write appearing or vanishing moves the signature, and so does the same name's value or
      # memo status changing.
      def constant_descriptor_signature(descriptor)
        return descriptor.first.inspect if descriptor.is_a?(Array)

        descriptor == CONSTANT_MEMO ? "||" : "?"
      end

      # The class-declaration + ancestry + member-layout surface of the declaration signature (declared class
      # names, superclass / include ancestry, Data/Struct member layouts). Kept out of
      # {#declaration_signature} to hold its ABC budget.
      def append_ancestry_signature(parts, file_index)
        parts.concat(file_index[:class_sources].keys.sort_by(&:to_s).map { |cn| "c:#{cn}" })
        parts.concat(sorted_by_class(file_index[:superclasses]).map { |cn, sc| "s:#{cn}<#{sc}" })
        parts.concat(sorted_by_class(file_index[:includes]).map do |cn, mods|
          "i:#{cn}=#{Array(mods).map(&:to_s).sort.join(',')}"
        end)
        parts.concat(sorted_by_class(file_index[:data_member_layouts]).map { |cn, l| "d:#{cn}=#{l.inspect}" })
        parts.concat(sorted_by_class(file_index[:struct_member_layouts]).map { |cn, l| "t:#{cn}=#{l.inspect}" })
      end

      # A class-keyed table's pairs sorted by class name (stringified) for a deterministic signature.
      def sorted_by_class(table)
        table.sort_by { |cn, _| cn.to_s }
      end

      # The method-existence and visibility surfaces of the declaration signature (kept out of
      # {#declaration_signature} to hold its ABC budget). Both are consumed cross-file — the existence table
      # by undefined-method suppression, the visibilities by the ADR-35 override-visibility rule.
      def append_declaration_tables(parts, file_index)
        file_index[:methods].sort_by { |cn, _| cn.to_s }.each do |cn, table|
          table.sort_by { |m, _| m.to_s }.each { |m, kind| parts << "e:#{cn}##{m}=#{kind}" }
        end
        file_index[:method_visibilities].sort_by { |cn, _| cn.to_s }.each do |cn, table|
          table.sort_by { |m, _| m.to_s }.each { |m, vis| parts << "v:#{cn}##{m}=#{vis}" }
        end
      end

      # Appends one def-node table's per-method signature entries (name + parameter structure + def-start
      # line) under `separator` (`#` instance / `.` singleton). Nodes here are always LIVE (both call sites —
      # {#scan_summary_for_paths} and {#build_seed_bundle} — pass a freshly parsed single-file index), so the
      # parameter structure and location are read directly.
      def append_def_signatures(parts, defs, separator)
        defs.sort_by { |cn, _| cn.to_s }.each do |class_name, methods|
          methods.sort_by { |m, _| m.to_s }.each do |method_name, node|
            parts << "m:#{class_name}#{separator}#{method_name}#{parameter_signature(node)}@#{def_start_line(node)}"
          end
        end
      end

      # ADR-89 WD1 — a compact, order-preserving descriptor of a def node's parameter STRUCTURE: each
      # parameter's kind (required / optional / rest / post / keyword-required / keyword-optional /
      # keyword-rest / block / forwarding) and name, plus default-PRESENCE (implied by the optional kinds).
      # Names are included for all parameter positions: soundness-first (a keyword-name change is Liskov-
      # visible to overriders; a positional-name change is rare and only over-conservatively keeps a
      # dependent). Not the inferred parameter TYPE — this gate is deliberately syntactic.
      def parameter_signature(node)
        return "()" unless node.respond_to?(:parameters)

        params = node.parameters
        return "()" if params.nil?

        parts = []
        parts.concat(labelled_params(params.requireds, "r"))
        parts.concat(labelled_params(params.optionals, "o"))
        parts.concat(labelled_params(params.posts, "p"))
        parts.concat(labelled_params(params.keywords) { |p| keyword_param_kind(p) })
        parts.concat(rest_param_parts(params))
        "(#{parts.join(',')})"
      end

      # The `<kind>:<name>` labels for a list of parameter nodes (nil → none). `kind` is a fixed String or a
      # block computing it per node (for the keyword-required / keyword-optional split).
      def labelled_params(nodes, kind = nil)
        (nodes || []).map { |p| "#{kind || yield(p)}:#{param_label(p)}" }
      end

      # The single rest / keyword-rest / block parameter labels (each present at most once).
      def rest_param_parts(params)
        parts = []
        parts << "*:#{param_label(params.rest)}" if params.rest
        parts << "**:#{param_label(params.keyword_rest)}" if params.keyword_rest
        parts << "&:#{param_label(params.block)}" if params.block
        parts
      end

      def keyword_param_kind(param)
        param.is_a?(Prism::OptionalKeywordParameterNode) ? "ko" : "kr"
      end

      # A parameter node's name, or a class-tagged sentinel for the nameless / destructuring forms
      # (`MultiTargetNode`, an anonymous `*` / `**` / `&`, `NoKeywordsParameterNode`, `ForwardingParameterNode`).
      def param_label(param)
        return "" if param.nil?

        param.respond_to?(:name) && param.name ? param.name.to_s : param.class.name.split("::").last
      end

      # The 1-based start line of a live def node (the `project_definition_site` an ADR-17 consumer embeds).
      def def_start_line(node)
        node.respond_to?(:location) ? node.location.start_line : 0
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
      # rescue's real target) contributes nothing to either table. The subset-scoped callers
      # ({IncrementalSession}, `coverage --protection`) keep calling the individual methods unchanged.
      def discovered_project_index_for_paths(paths, buffer: nil)
        classes = {}
        acc = new_def_index_accumulator
        paths.each do |path|
          physical = buffer ? buffer.resolve(path) : path
          root = Prism.parse(File.read(physical), filepath: path).value
          collect_class_decls(root, [], classes)
          accumulate_project_index(acc, path, root)
        rescue StandardError
          # Skip files that fail to parse or read; the per-file analyzer surfaces the parse error separately.
          next
        end
        finalize_project_index(classes, acc)
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
      def discovered_project_index_incremental(paths, seed_bundles:, buffer: nil)
        classes = {}
        acc = new_def_index_accumulator
        bundles = {}
        paths.each do |path|
          physical = buffer ? buffer.resolve(path) : path
          digest = Cache::FileDigest.hexdigest(physical)
          cached = seed_bundles[path]
          if cached && cached[:digest] == digest
            bundles[path] = cached
            classes.merge!(cached[:classes])
            fold_file_index(acc, bundle_to_file_index(cached, path))
          else
            source = File.read(physical)
            parsed = Prism.parse(source, filepath: path)
            root = parsed.value
            file_index = build_file_index(path, root)
            file_classes = {}
            collect_class_decls(root, [], file_classes)
            bundles[path] = build_seed_bundle(file_index, file_classes, digest,
                                              code_fingerprint(source, parsed.comments))
            classes.merge!(file_classes)
            fold_file_index(acc, file_index)
          end
        rescue StandardError
          # Skip files that fail to parse / read; the per-file analyzer surfaces the parse error separately.
          next
        end
        finalize_project_index(classes, acc).merge(bundles: bundles)
      end

      # Builds ONE file's isolated def-index contribution (live `Prism::DefNode`s) by folding it into a fresh
      # accumulator — recon Q2(a)'s "constructible in isolation" property. Shared by the cold-baseline bundle
      # build and the incremental changed-file re-walk.
      def build_file_index(path, root)
        file_acc = new_def_index_accumulator
        accumulate_project_index(file_acc, path, root)
        file_acc
      end

      # ADR-85 WD2 — folds a single file's isolated def-index contribution into the cross-file accumulator,
      # applying EXACTLY the merge semantics {#accumulate_project_index} applies incrementally (def_nodes
      # later-wins, def_sources first-wins, includes / class_sources accumulate, everything else later-wins).
      # Polymorphic over the def-node value: a re-walked file's `file_index` carries live nodes; a cached
      # bundle's carries {DefHandle}s. The merges never deref the value, so both fold identically.
      def fold_file_index(acc, file_index)
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
        fold_ancestry_tables(acc, file_index)
        fold_constant_tables(acc, file_index)
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
      end

      # The `extends` half stores singleton-ancestor search order ({#record_extend_targets}), so a file
      # scanned later contributes NEARER entries for a reopened class — prepend, matching the
      # per-statement convention. `includes` shares the shape since #1173, when its table switched to
      # instance-ancestor search order too ({#write_mixin_targets}).
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
      # order ({#record_mixin_call}): a file scanned later contributes NEARER prepends for a reopened
      # class. Shared with {#accumulate_extend_lists}' shape deliberately — the two tables answer the
      # `prepend` question on the two sides of the class object, and both fold nearest-first.
      def accumulate_prepend_lists(target, additions)
        additions.each { |cn, mods| target[cn] = (mods + (target[cn] || [])).uniq }
      end

      # ADR-85 WD2 — converts a file's live single-file index + its class table into a Marshal-clean seed
      # bundle: the plain-data tables verbatim, the def-node tables re-expressed as `[node_id, name,
      # fingerprint]` triples (the path is the bundle key), the class-source names (path implicit), and the
      # content digest that gates the bundle's reuse.
      def build_seed_bundle(file_index, file_classes, digest, code_fingerprint)
        {
          digest: digest,
          # B1 — the comment-stripped code fingerprint, so a recheck can prove this file's edit was
          # comment-only and skip its dependents.
          code_fingerprint: code_fingerprint,
          # ADR-89 WD1 — the per-def SIGNATURE-shape declaration signature (bodies excluded, def lines kept),
          # so a recheck can prove this file's body edit changed no declaration and skip its ancestry /
          # file-level dependents. Computed from the same live `file_index` the bundle is built from, so the
          # value stored here equals the one a later recheck recomputes for an unchanged declaration.
          declaration_signature: declaration_signature(file_index),
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
          method_visibilities: file_index[:method_visibilities],
          methods: file_index[:methods],
          # Issue #992 — plain `{class name => {[kind, name] => [min, max, required_keywords] | :opaque}}`
          # data, so the bundle stays Marshal-clean and a warm file joins the envelopes its cold walk records.
          parameter_envelopes: file_index[:parameter_envelopes],
          class_source_names: file_index[:class_sources].keys,
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
          deferred_ranges: file_index[:deferred_ranges]
        }
      end

      # ADR-85 WD2 — reconstitutes a cached bundle into a single-file index {#fold_file_index} folds: the
      # def-node triples become {DefHandle}s bound to this file's `path`, and the class-source names become a
      # `{name => Set[path]}` table (the shape `accumulate_project_index` produces).
      def bundle_to_file_index(bundle, path)
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
          method_visibilities: bundle[:method_visibilities],
          methods: bundle[:methods],
          parameter_envelopes: bundle[:parameter_envelopes] || {},
          class_sources: bundle[:class_source_names].to_h { |name| [name, Set[path]] },
          compact_headers: bundle[:compact_headers] || {},
          # Issue #644 — a pre-#644 bundle carries no census; the SCHEMA bump makes such a blob a cold
          # rebuild, but default so any in-flight fold stays total.
          constant_writes: (bundle[:constant_writes] || {}).transform_values { |descriptor| { path => descriptor } },
          data_member_layouts: bundle[:data_member_layouts],
          struct_member_layouts: bundle[:struct_member_layouts],
          # Issue #1097 — a pre-24 bundle lacks the key; the SCHEMA bump makes such a blob a cold
          # rebuild, but default so any in-flight fold stays total.
          deferred_ranges: bundle[:deferred_ranges] || {}
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
          superclasses: {}, header_nestings: {}, includes: {}, prepends: {}, extends: {}, method_visibilities: {},
          methods: {},
          deferred_ranges: {},
          parameter_envelopes: {}, class_sources: {},
          # Issue #722 residue 2 — compact-header re-anchor candidates, adjudicated in {#finalize_def_index}.
          compact_headers: {},
          constant_writes: {},
          data_member_layouts: {}, struct_member_layouts: {} }
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
        fold_extends_into_singleton_tables(acc[:extends], acc[:def_nodes], acc[:singleton_def_nodes], acc[:methods])
        # Cross-file method suppression is for the project's OWN accessors (attr_* / define_method / alias) — NOT for
        # plain `def`s. A cross-file `def` on a class is exactly the ADR-17 monkey-patch case the undefined-method rule
        # deliberately surfaces (fire + def-site annotation, nudging `pre_eval:`), so dropping the `def`-declared names
        # keeps that contract intact while still letting `attr_reader :x` in one file suppress a false undefined-method
        # for `obj.x` in another.
        acc[:methods] = subtract_def_methods(acc[:methods], acc[:def_nodes])
        acc[:parameter_envelopes][Scope::DiscoveryIndex::ENVELOPE_PROJECT_WIDE] ||= {}
        %i[def_nodes singleton_def_nodes def_sources singleton_def_sources includes prepends method_visibilities
           methods parameter_envelopes class_sources constant_sources deferred_ranges].each do |key|
          acc[key].each_value(&:freeze)
        end
        acc.transform_values(&:freeze)
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

      # Folds one file's class-keyed indexes into the cross-file accumulator. `method_visibilities` (ADR-35) is
      # collected here so the override-visibility-reduced rule can read an ancestor's visibility declared in a sibling
      # file.
      def accumulate_project_index(acc, path, root)
        # One combined descent yields both the methods existence table and the def-node table; the latter is also
        # consumed by `record_class_sources`, so a def-dense file is walked once here instead of three times (methods +
        # def-nodes ×2). See {#build_methods_and_def_nodes}.
        file_methods, file_def_nodes, file_envelopes = build_methods_and_def_nodes(root, path)
        merge_discovered_defs(acc[:def_nodes], acc[:def_sources], path, file_def_nodes)
        fold_parameter_envelopes(acc, file_envelopes)
        # Issue #681 — node-identity keyed, so this is a flat union: no two files can contribute the same key.
        acc[:def_nestings].merge!(build_def_nestings(root))
        # ADR-46 slice 4 (singleton) — record the singleton-side `"path:line"` sources alongside the nodes,
        # the exact mirror of the instance-side `merge_discovered_defs`, so a class/singleton-method body edit
        # produces a changed `"Class.method"` fingerprint pair (and its call sites a symbol edge) instead of
        # silently degrading to the file's full ancestry closure.
        merge_discovered_defs(acc[:singleton_def_nodes], acc[:singleton_def_sources], path,
                              build_discovered_singleton_def_nodes(root))
        superclasses, header_nestings = build_superclass_tables(root, path)
        acc[:superclasses].merge!(superclasses)
        merge_header_nestings(acc[:header_nestings], header_nestings)
        ancestry_keys = fold_file_mixin_tables(acc, root)
        record_file_positions(acc, path, root, superclasses, ancestry_keys, file_def_nodes)
        merge_constant_literal_tables(acc, root, path)
        merge_class_keyed_index_tables(acc, root, file_methods)
        merge_member_layout_tables(acc, root)
      end

      # Issue #1123 — this file's three instance- / singleton-side module lists, folded into the
      # accumulator, plus the class keys its ancestry edges are attributed to: a prepend table can name a
      # class this file never DECLARES (`Base.prepend(Loud)` written beside `Base`'s body), and that call IS
      # an ancestry edge of `Base`, so ADR-46 must attribute the class to this file or a reader of `Base`
      # would not depend on the file whose edit moves `Base`'s MRO. The include LISTS themselves are
      # unchanged — only the key set the attribution reads widens. Split out of
      # {#accumulate_project_index} to hold its ABC budget.
      def fold_file_mixin_tables(acc, root)
        mixin = mixin_tables(root)
        accumulate_include_lists(acc[:includes], mixin[:includes])
        accumulate_prepend_lists(acc[:prepends], mixin[:prepends])
        accumulate_extend_lists(acc[:extends], build_discovered_extends(root))
        mixin[:includes].merge(mixin[:prepends]) { |_cn, included_mods, _prepends| included_mods }
      end

      # Issue #644 — folds one file's publication census into the cross-file accumulator, keyed by
      # (name, path) (kept out of {#accumulate_project_index} to hold its ABC budget). The conflict rule that
      # makes the fold order irrelevant runs at {#finalize_constant_writes}.
      def merge_constant_literal_tables(acc, root, path)
        constant_writes_for_file(root).each do |name, descriptor|
          (acc[:constant_writes][name] ||= {})[path] = descriptor
        end
      end

      # Folds one file's Data + Struct member-layout tables into the cross-file accumulator (kept out of
      # {#accumulate_project_index} to hold its ABC budget).
      def merge_member_layout_tables(acc, root)
        acc[:data_member_layouts].merge!(build_data_member_layouts(root))
        acc[:struct_member_layouts].merge!(build_struct_member_layouts(root))
      end

      # Folds the per-class method-visibility and method-existence tables of one file into the cross-file accumulator
      # (kept out of {#accumulate_project_index} to hold its ABC budget). `file_methods` is the existence table from the
      # combined methods/def-nodes descent.
      def merge_class_keyed_index_tables(acc, root, file_methods)
        build_discovered_method_visibilities(root).each do |class_name, table|
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
      # dependency recording (ADR-46). The class-declaration walk (`collect_class_decls`) catches bodyless / def-less
      # reopenings the other three builders miss.
      def record_class_sources(class_sources, path, root, superclasses, includes, file_def_nodes, compacts = nil)
        names = Set.new
        collect_class_decls(root, [], decls = {}, compacts)
        names.merge(decls.keys)
        names.merge(superclasses.keys)
        names.merge(includes.keys)
        names.merge(file_def_nodes.keys)
        names.each { |name| (class_sources[name] ||= Set.new) << path }
      end

      # Issue #644 — the cross-file VALUE-constant pre-pass, the twin of {#record_class_sources} for plain
      # constant ASSIGNMENTS. Returns one file's **publication census**: `{qualified name => descriptor}`,
      # where the descriptor is `[literal]` (a publishable frozen scalar), {CONSTANT_MEMO}, or
      # {CONSTANT_UNPUBLISHABLE}.
      #
      # EVERY constant write is censused, whatever its rvalue and whatever its form, because the census is
      # four things at once and only the first cares about the value:
      #
      # 1. the published table ({#finalize_constant_writes}: a name publishes only when exactly one file
      #    writes it and that write is a literal),
      # 2. the attribution the ADR-46 positive edge reads,
      # 3. the producer whose per-file DIFF re-checks readers on an incremental run
      #    ({Analysis::Incremental.changed_constant_publications}), and
      # 4. the writes a constant compound write finds its binding among when its plain read resolves nothing
      #    ({Scope#bound_constant_names}), which is why a `||=`-only name carries its own descriptor.
      #
      # A write the census cannot see does not merely lose precision — it silently bypasses the conflict rule
      # and publishes a value the program does not have. That is why the operator / multi-assign / chained /
      # `self::` forms below are censused as unpublishable rather than skipped.
      #
      # **Why the publishable set is only Symbol / Integer / Float.** Publishing turns `Dynamic[top]` into a
      # real type at every reader in the project, which is precisely where a wrong answer becomes a diagnostic
      # on correct code (AGENTS.md § "Implementation Guidelines"), so the recognised set is the one whose
      # precision is worth that risk.
      #
      # - `String` / `Array` / `Hash` literals are MUTABLE. A sibling file's `PATH << "/x"` or `LIST.push(...)`
      #   moves the value this table pinned, and only the DECLARING file's `widen_mutated_constants` census can
      #   see such a mutation. The composite two additionally carry the `HashShape` / `Tuple` hazard
      #   {PreEvalConstants} documents (a closed `HashShape` makes `CONFIG.fetch(:b)` fire; a `Tuple` routes
      #   through `ShapeDispatch` instead of the RBS overload a call site relied on).
      # - `nil` declines for {PreEvalConstants}' reason: at declaration position it is a placeholder for a
      #   value assigned later far more often than it is a genuine `NilClass`.
      # - `true` / `false` DO publish. They are branched on rather than dispatched to, so the value would fuel
      #   `flow.always-truthy-condition` at every `if FEATURE_FLAG` in another file; that is withheld at the
      #   rule instead ({Analysis::CheckRules::PublishedConstantGuard}), which is the repo's own answer to a
      #   value that is real but must not be concluded from, and it keeps the treatment of every published
      #   kind the same.
      #
      # Everything else — a method call, a constant alias, `ENV[...]`, a `Data.define` — is not a literal, so
      # the reader keeps today's `Dynamic[top]`. Declining is always the safe answer.
      #
      # A name written TWICE in one file is unpublishable too, which is what makes a conditional
      # `X = :a if c` / `X = :b` pair gradual rather than pinned to whichever arm the walk saw first.
      def constant_writes_for_file(root) = constant_write_census(root).writes

      # The tables one file's publication census fills in a single walk, carried together so the walk's two
      # `self`-tracking parameters stay within the signature budget. `writes` is the census itself; `seen`
      # the names already recorded, so a repeat write retracts whatever either rvalue was; `declared` the
      # subset whose write NAMES its target, which is the only half {Scope#local_constant_names} may exempt
      # ([#710](https://github.com/rigortype/rigor/issues/710)).
      # `aliases` is `{qualified target name => the constant reference its rvalue names}` for the one
      # unpublishable rvalue shape whose provenance is still knowable ([#667](https://github.com/rigortype/rigor/issues/667)):
      # a plain `MODE2 = AppConfig::MODE`. The census cannot publish a VALUE for it — resolving the source
      # is the typed walk's job, not this syntactic one — but it can record that the name is a rename of
      # another, which is all the withholding guard needs.
      CensusTables = Data.define(:writes, :seen, :declared, :aliases)
      private_constant :CensusTables

      def constant_write_census(root)
        tables = CensusTables.new(writes: {}, seen: Set.new, declared: Set.new, aliases: {})
        walk_constant_write_census(root, [], tables)
        tables
      end

      # Mirrors {#walk_constant_writes}'s traversal for the forms it shares — the lexical class/module prefix
      # qualifies a bare `ConstantWriteNode` — and extends it to the four forms that walk misses, each
      # censused as unpublishable: an operator / `&&=` /
      # `||=` constant write, a `ConstantTargetNode` under a `MultiWriteNode` (`A, B = :x, :y`), a `self::X =`
      # whose target renders no qualified name, and the inner write of a chain (`C = D = :x`), which is why a
      # `ConstantWriteNode` descends into its own rvalue instead of returning.
      def walk_constant_write_census(node, qualified_prefix, tables, self_owner = nil, meta_owner = nil,
                                     singleton_cref: false)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::SingletonClassNode
          return walk_census_singleton_class(node, qualified_prefix, tables, self_owner,
                                             meta_owner, singleton_cref)
        when Prism::ClassNode, Prism::ModuleNode
          return walk_census_declaration(node, qualified_prefix, tables, self_owner, meta_owner,
                                         singleton_cref)
        else
          census_constant_write(node, qualified_prefix, tables, self_owner, singleton_cref: singleton_cref)
        end

        rebound = rebound_block_self(node, qualified_prefix, nil, meta_owner,
                                     rebound_self_base(self_owner))
        # A `ConstantWriteNode`'s only child is its rvalue, so this reaches exactly the call whose block the
        # constant names — and nil everywhere else, leaving every other descent as it was.
        #
        # Issue #963 — except where a `.freeze` tail sits BETWEEN the two. The write names the class one hop
        # further down than it used to, so the name is carried through the tail rather than dropped at it;
        # otherwise the factory call arrives with no owner and {#rebound_block_self} answers {OPAQUE_SELF},
        # suppressing every `self::X = …` the block publishes. Only a tail passes the name on: a nil
        # `child_meta_owner` at any other node still means "this node names nothing".
        # Under an unnameable cref only a definite path write (`::K`, `C::K`) still names
        # its class; a bare `Klass = Class.new` keeps the opaque self instead of a
        # fabricated lexical owner.
        child_meta_owner =
          if singleton_cref
            meta_new_owner_under_cref(node, qualified_prefix)
          else
            meta_new_block_owner(node, qualified_prefix)
          end
        child_meta_owner ||= meta_owner unless unwrap_freeze_tail(node).equal?(node)
        node.rigor_each_child do |child|
          rebinds_self = rebound && child.is_a?(Prism::BlockNode)
          owner = rebinds_self ? rebound : self_owner
          # `Module.nesting` never rebinds — the cref flag passes through a self-rebinding
          # block unchanged while `self` (and `self::` resolution) follows the receiver.
          walk_constant_write_census(child, qualified_prefix, tables, owner, child_meta_owner,
                                     singleton_cref: singleton_cref)
        end
      end

      # Under an unnameable cref a bare/`self::` header pushes `#<singleton>::Name` — still
      # unnameable — so the body keeps the OPAQUE self and the cref flag; nameable
      # headers re-anchor at a real cref.
      def walk_census_declaration(node, qualified_prefix, tables, self_owner, meta_owner,
                                  singleton_cref)
        rebound_self = meta_owner || self_owner
        self_base =
          case rebound_self
          when String then [rebound_self]
          when Symbol then [] # OPAQUE_SELF — a `self::` header names nothing
          end
        self_decl = self_anchored_decl_prefix(node.constant_path, self_base)
        child_prefix = self_decl ||
                       Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
        return unless child_prefix && node.body

        child_cref = unnameable_decl?(node, self_decl, singleton_cref)
        # The body keeps the enclosing prefix, not `child_prefix`: `#<singleton>::D` is a
        # real cref rung, but the only NAMEABLE rungs below it are the enclosing ones —
        # `Foo::BAR` inside resolves through `C::Foo`/`::Foo`, never a spelled `C::D::Foo`.
        walk_constant_write_census(node.body, child_cref ? qualified_prefix : child_prefix, tables,
                                   child_cref ? OPAQUE_SELF : nil, singleton_cref: child_cref)
      end

      # `self` inside a `class <<` body is the singleton: `self`-anchored and bare write
      # targets land on its constant table (unnameable, so both decline) and a
      # `self::`-anchored eval receiver raises NameError at runtime, so the body is entered
      # with an OPAQUE self. The lexical cref below it is unnameable too — the flag only
      # lifts at a `::`-rooted class/module header.
      def walk_census_singleton_class(node, qualified_prefix, tables, self_owner, meta_owner,
                                      singleton_cref)
        walk_constant_write_census(node.expression, qualified_prefix, tables, self_owner,
                                   meta_owner, singleton_cref: singleton_cref)
        return unless node.body

        walk_constant_write_census(node.body, qualified_prefix, tables, OPAQUE_SELF,
                                   meta_owner, singleton_cref: true)
      end

      # Censuses `node` when it is any constant-assigning form. Only a plain `ConstantWriteNode` /
      # `ConstantPathWriteNode` can contribute a VALUE; every other form is recorded unpublishable, which
      # suppresses publication of the name exactly as a second file's write would.
      # Writes inside a `class <<` body (`singleton_cref`) to a bare or `self`-anchored
      # target land on the singleton's own constant table — a name nothing else can
      # produce — so they record nothing rather than fabricating an enclosing-class name
      # or a wildcard retraction for a constant they cannot touch.
      def census_constant_write(node, qualified_prefix, tables, self_owner = nil,
                                singleton_cref: false)
        case node
        when Prism::ConstantWriteNode
          return if singleton_cref

          record_constant_write_census(qualified_write_name(qualified_prefix, node.name.to_s),
                                       constant_literal_value(node.value), tables,
                                       alias_of: constant_alias_source(node.value))
        when Prism::ConstantPathWriteNode
          return if singleton_cref && singleton_self_write?(node.target, self_owner)

          record_constant_write_census(constant_path_write_name(node.target, qualified_prefix, self_owner),
                                       constant_path_write_literal(node, self_owner), tables,
                                       nameable: nameable_write_target?(node.target, self_owner),
                                       alias_of: constant_alias_source(node.value))
        when Prism::ConstantOperatorWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode
          return if singleton_cref

          record_constant_write_census(qualified_write_name(qualified_prefix, node.name.to_s), nil, tables,
                                       memo: node.is_a?(Prism::ConstantOrWriteNode))
        when Prism::ConstantPathOperatorWriteNode, Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode
          census_path_write(node, qualified_prefix, tables, self_owner, singleton_cref: singleton_cref)
        when Prism::MultiWriteNode
          census_multi_write_constants(node, qualified_prefix, tables, self_owner, singleton_cref: singleton_cref)
        end
      end

      def census_path_write(node, qualified_prefix, tables, self_owner, singleton_cref: false)
        return if singleton_cref && singleton_self_write?(node.target, self_owner)

        record_constant_write_census(constant_path_write_name(node.target, qualified_prefix, self_owner),
                                     nil, tables,
                                     nameable: nameable_write_target?(node.target, self_owner),
                                     memo: node.is_a?(Prism::ConstantPathOrWriteNode))
      end

      # A `self`-anchored write target under a self the walk cannot name — inside `class <<`
      # the read raises NameError or lands on the singleton's table, never on a constant the
      # census could spell, so it declines rather than laying a wildcard retraction down.
      def singleton_self_write?(target, self_owner)
        self_owner == OPAQUE_SELF && !self_anchored_tail(target).nil?
      end

      # `A, B = :x, :y` and `A, *rest = …`. A destructured element's value is a projection of the right-hand
      # side, which this syntactic walk does not evaluate, so every constant target is censused unpublishable.
      def census_multi_write_constants(node, qualified_prefix, tables, self_owner = nil,
                                       singleton_cref: false)
        targets = node.lefts + node.rights
        targets << node.rest if node.rest
        targets.each do |target|
          case target
          when Prism::ConstantTargetNode
            next if singleton_cref

            record_constant_write_census(qualified_write_name(qualified_prefix, target.name.to_s), nil, tables)
          when Prism::ConstantPathTargetNode
            next if singleton_cref && singleton_self_write?(target, self_owner)

            record_constant_write_census(constant_path_write_name(target, qualified_prefix, self_owner),
                                         nil, tables, nameable: nameable_write_target?(target, self_owner))
          end
        end
      end

      # The qualified name a constant-path write targets, for the PUBLICATION census only. `Foo::BAR = …`
      # renders as written — deliberately NOT what {#constant_path_write_key} answers for the typed table,
      # which resolves the namespace through the enclosing nesting
      # ([#690](https://github.com/rigortype/rigor/issues/690)). Moving this one changes which name a value
      # publishes to the whole project, an over-suppression question with its own safety story, so the two
      # censuses key a path write differently until that is settled.
      # `self::BAR = …` names whatever `self` is at that point, which the walk carries in `self_owner`
      # ([#705](https://github.com/rigortype/rigor/issues/705)) — the enclosing lexical namespace in an
      # ordinary body, the receiver inside a `class_eval` block, and the constant a `Klass = Class.new { … }`
      # assigns the block's class to ({#meta_new_block_owner}). Where that `self` is {OPAQUE_SELF}, and for
      # any other dynamic receiver (`klass::BAR = …`), the target is "some class, then `::BAR`" and the name
      # falls back to the WILDCARD {DYNAMIC_TARGET_PREFIX} key, which {#finalize_constant_writes} expands
      # into a retraction of every censused name with that last segment
      # ([#668](https://github.com/rigortype/rigor/issues/668)). The bare last segment — the pre-#668
      # fallback — was the single name such a write can never create, so filing it there suppressed the one
      # name the form cannot touch and left published every name it can. The VALUE is what such a write must
      # not contribute either ({#constant_path_write_literal}), and the fallback name is withheld from the
      # local-declaration exemption ({#local_constant_name_set}).
      def constant_path_write_name(target, qualified_prefix, self_owner = nil)
        full = Source::ConstantPath.qualified_name_or_nil(target)
        return full if full

        base = target.name&.to_s
        return nil if base.nil?
        return dynamic_target_key(base) unless (tail = self_anchored_tail(target))

        self_write_name(qualified_prefix, self_owner, tail.join("::")) || dynamic_target_key(base)
      end

      def dynamic_target_key(segment) = "#{DYNAMIC_TARGET_PREFIX}#{segment}"

      # The last segment a wildcard census key stands for, or nil for an ordinary qualified name.
      def dynamic_target_segment(name)
        name.delete_prefix(DYNAMIC_TARGET_PREFIX) if name.start_with?(DYNAMIC_TARGET_PREFIX)
      end

      # The publishable literal a path write contributes — none, whenever its base is not statically
      # nameable ([#705](https://github.com/rigortype/rigor/issues/705)). `[Foo].each { |k| k::X = 1 }`
      # renders under the wildcard key, and publishing `1` there handed every reader of a project `X` a value
      # the program never has: `X == 2` folded to `false`, and in the WRITING file — where
      # `Scope#local_constant_names` exempts the name from #644's withholding guard —
      # `flow.always-truthy-condition` then fired on correct code.
      #
      # The NAME still enters the census, because a decline means opposite things in the two censuses. In the
      # typed one, recording no type is gradual. Here, recording nothing would leave ANOTHER file's value for
      # the name trusted — silence is the risky direction, and the census's own gradual answer is to say the
      # name was touched and no value for it is safe.
      def constant_path_write_literal(node, self_owner)
        return nil unless nameable_write_target?(node.target, self_owner)

        constant_literal_value(node.value)
      end

      # True when the census can name what the write targets: a static constant path, or a `self::BAR` whose
      # `self` the walk resolved to a class or module.
      def nameable_write_target?(target, self_owner)
        return true if Source::ConstantPath.qualified_name_or_nil(target)
        return false unless self_anchored_tail(target)

        !self_owner.equal?(OPAQUE_SELF)
      end

      def qualified_write_name(qualified_prefix, base_name)
        qualified_prefix.empty? ? base_name : "#{qualified_prefix.join('::')}::#{base_name}"
      end

      # Records one censused write. `seen` carries the names this file has already written, so a repeat write
      # retracts the publishable descriptor whatever either rvalue was — neither arm of an in-file
      # reassignment is ever published, and the name still counts as written.
      #
      # `nameable` is false only for the wildcard fallback {#constant_path_write_name} takes when nothing
      # names the write's base. Such a key belongs in `writes` — another file's value for a name it reaches
      # is not to be trusted — and NOT in `declared`, which answers the opposite question
      # ([#710](https://github.com/rigortype/rigor/issues/710)). The two are separate tables rather than one
      # richer descriptor because a name can be written both ways in one file, and then the file DID declare
      # it however the two writes are ordered.
      #
      # `memo` marks a `||=` write, which files {CONSTANT_MEMO} for as long as every write of the name in this
      # file is one.
      def record_constant_write_census(full, literal, tables, nameable: true, alias_of: nil, memo: false)
        return if full.nil?

        tables.declared << full if nameable
        first_write = tables.seen.add?(full)
        tables.writes[full] = census_descriptor(tables.writes[full], first_write, literal, memo)
        record_constant_alias_census(full, alias_of, tables, first_write && nameable)
      end

      def census_descriptor(previous, first_write, literal, memo)
        return literal || (memo ? CONSTANT_MEMO : CONSTANT_UNPUBLISHABLE) if first_write

        memo && previous == CONSTANT_MEMO ? CONSTANT_MEMO : CONSTANT_UNPUBLISHABLE
      end

      # Issue #667 — a name written TWICE is not an alias of anything the walk can name, exactly as it is
      # unpublishable above; the `delete` is what retracts a first write's record when the second arrives.
      def record_constant_alias_census(full, alias_of, tables, keep)
        if keep && alias_of
          tables.aliases[full] = alias_of
        else
          tables.aliases.delete(full)
        end
      end

      # The constant reference an rvalue names, or nil when it names none. `AppConfig::MODE` renders
      # qualified; a path that renders no qualified name falls back to its own last segment, which is all
      # `Scope#published_constant?` can be asked about anyway.
      def constant_alias_source(rvalue)
        case rvalue
        when Prism::ConstantReadNode then rvalue.name.to_s
        when Prism::ConstantPathNode then Source::ConstantPath.qualified_name_or_nil(rvalue) || rvalue.name&.to_s
        end
      end

      # The frozen-scalar literal fold: `[value]` for a publishable rvalue, nil to decline. The one-element
      # Array is the presence wrapper (`false` is a legitimate published value), and the raw Ruby value is
      # what rides the ADR-85 seed bundle through `Marshal`.
      def constant_literal_value(rvalue)
        case rvalue
        when Prism::SymbolNode then symbol_literal_publication(rvalue)
        when Prism::IntegerNode, Prism::FloatNode then [rvalue.value]
        when Prism::TrueNode then [true]
        when Prism::FalseNode then [false]
        end
      end

      # `Prism::SymbolNode` is the STATIC symbol node (a dynamic `:"#{x}"` parses as
      # `InterpolatedSymbolNode` and never reaches here), so its unescaped text is the whole value.
      def symbol_literal_publication(node)
        text = node.unescaped
        text.is_a?(String) ? [text.to_sym] : nil
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
      # @return `[{name => Type}, {name => Set[path]}]`.
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
      # ({Analysis::Runner#publishable_pre_eval_constants}).
      def apply_dynamic_target_writes(values, sources, dynamic)
        return if dynamic.empty?

        sources.each do |name, paths|
          writers = dynamic[name.split("::").last]
          next if writers.nil?

          paths.merge(writers)
          values.delete(name)
        end
        dynamic.each { |segment, paths| sources[dynamic_target_key(segment)] = paths }
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

      # Cross-file counterpart of `record_declarations` — registers every `class` / `module` declaration under its
      # qualified name and descends into the body (so `module Foo; class Bar` registers both `Foo` and `Foo::Bar`).
      # `self_prefix` names a REBOUND self for `self::`-anchored declarations — see
      # {#record_declarations}.
      def collect_class_decls(node, qualified_prefix, accumulator, compacts = nil,
                              self_prefix = nil, singleton_cref: false)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          return if collect_decl_body?(node, qualified_prefix, accumulator, compacts,
                                       self_prefix, singleton_cref)
        when Prism::SingletonClassNode
          # The expression evaluates in the ENCLOSING cref — `class << (class D; self; end)`
          # still names `C::D` — while the body's cref is the unnameable singleton.
          collect_class_decls(node.expression, qualified_prefix, accumulator, compacts,
                              self_prefix, singleton_cref: singleton_cref)
          if node.body
            collect_class_decls(node.body, qualified_prefix, accumulator, compacts,
                                EMPTY_PREFIX, singleton_cref: true)
          end
          return
        when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode,
             Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode
          # `K = Class.new` under an unnameable cref lands on the singleton's own table;
          # a path write resolves its base lexically and stays nameable.
          record_class_new_constant_decl(node, qualified_prefix, accumulator,
                                         self_prefix: self_prefix, singleton_cref: singleton_cref)
          return if collect_meta_new_constant_decls?(node, qualified_prefix, accumulator, compacts,
                                                     self_prefix, singleton_cref)
        when Prism::CallNode
          return if collect_eval_class_decls?(node, qualified_prefix, accumulator, compacts,
                                              self_prefix, singleton_cref)
        end

        node.rigor_each_child do |child|
          collect_class_decls(child, qualified_prefix, accumulator, compacts,
                              self_prefix, singleton_cref: singleton_cref)
        end
      end

      # The class/module arm of {#collect_class_decls}. Under an unnameable cref a bare/`self::`
      # header opens `#<singleton>::Name` — a real class nothing can name — so it is declined
      # rather than published as `C::Name`; the body still walks (rooted headers below it
      # re-anchor). Returns whether the declaration was consumed.
      def collect_decl_body?(node, qualified_prefix, accumulator, compacts, self_prefix,
                             singleton_cref)
        self_decl = self_anchored_decl_prefix(node.constant_path, self_prefix)
        child_prefix = self_decl ||
                       Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
        return false unless child_prefix

        child_cref = unnameable_decl?(node, self_decl, singleton_cref)
        unless child_cref
          full = child_prefix.join("::")
          accumulator[full] = Type::Combinator.singleton_of(full)
          record_compact_header(compacts, qualified_prefix, node.constant_path, full) if compacts
        end
        return true unless node.body

        collect_class_decls(node.body, child_cref ? [] : child_prefix, accumulator, compacts,
                            nil, singleton_cref: child_cref)
        true
      end

      # The eval-family arm of {#collect_class_decls}: same dual context as
      # {#record_eval_declarations?} — `self::` headers anchor on the receiver, bare
      # headers stay lexical.
      def collect_eval_class_decls?(node, qualified_prefix, accumulator, compacts, self_prefix,
                                    singleton_cref)
        return false unless node.block.is_a?(Prism::BlockNode) &&
                            RECEIVER_EVAL_CALLS.include?(node.name)

        [node.receiver, *node.arguments&.arguments.to_a].compact.each do |part|
          collect_class_decls(part, qualified_prefix, accumulator, compacts, self_prefix,
                              singleton_cref: singleton_cref)
        end
        unnameable = unnameable_eval_self?(false, self_prefix, qualified_prefix, singleton_cref)
        eval_self = eval_receiver_prefix(node, self_prefix || qualified_prefix, qualified_prefix,
                                         unnameable_self: unnameable) || []
        if (body = node.block.body)
          collect_class_decls(body, qualified_prefix, accumulator, compacts, eval_self,
                              singleton_cref: singleton_cref)
        end
        true
      end

      # The meta-new arm of {#collect_class_decls}: the factory call's receiver and
      # arguments evaluate in the enclosing context; the block's `self` is the class the
      # write names (`[]` when it names nothing) while the cref stays lexical.
      def collect_meta_new_constant_decls?(node, qualified_prefix, accumulator, compacts,
                                           self_prefix, singleton_cref)
        call = meta_new_block_call(node)
        return false unless call

        child_prefix = meta_new_child_prefix(node, qualified_prefix, self_prefix)
        meta_self =
          if singleton_cref && !meta_new_path_target_nameable?(node, self_prefix)
            []
          else
            child_prefix || []
          end
        [call.receiver, *call.arguments&.arguments.to_a].compact.each do |part|
          collect_class_decls(part, qualified_prefix, accumulator, compacts,
                              self_prefix, singleton_cref: singleton_cref)
        end
        if (body = meta_new_block_body(node))
          collect_class_decls(body, qualified_prefix, accumulator, compacts,
                              meta_self, singleton_cref: singleton_cref)
        end
        true
      end

      # Issue [#722](https://github.com/rigortype/rigor/issues/722) residue 2 — records what a COMPACT header
      # written inside an enclosing namespace would name if its leading segment fell through to the top level.
      # `class Outer::Leaf` inside `module Wrap` is keyed `Wrap::Outer::Leaf` by the per-node
      # {Source::ConstantPath.declaration_prefix}, but Ruby resolves the leading `Outer` by ORDINARY constant
      # lookup: it reopens `::Outer::Leaf` unless `Wrap::Outer` exists. Whether it exists is a whole-project
      # fact, so the candidate is recorded here and adjudicated once the fold knows every declared name
      # ({#compact_header_renames}).
      #
      # @param compacts — `{recorded name => [namespace the header needs, name it falls through to]}`.
      def record_compact_header(compacts, qualified_prefix, constant_path, full)
        return if qualified_prefix.empty?
        return unless constant_path.is_a?(Prism::ConstantPathNode)
        return if Source::ConstantPath.rooted?(constant_path)

        rendered = Source::ConstantPath.qualified_name(constant_path)
        return unless rendered&.include?("::")

        compacts[full] = [(qualified_prefix + [rendered.split("::").first]).join("::"), rendered]
      end

      # Issue #722 residue 2 — the whole-project adjudication of {#record_compact_header}'s candidates:
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
      # ahead of `::Mixin`, and `Scope#compute_ancestor_class_name` takes the first known class as the sole
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

      # T1 (template-corpora survey) — record a class-creating constant write (`Const = Class.new(Super)`, the bare
      # `Class.new` / `Module.new`, and the `Data.define(*sym)` / `Struct.new(*sym)` forms, each with or without a
      # block) in the cross-file discovery table so a reference to `Const` from ANOTHER file under the same namespace
      # resolves to the project class instead of falling through to a same-named class elsewhere
      # (`Liquid::SyntaxError = Class.new(Error)` referenced in a sibling file's `rescue SyntaxError => e`, which
      # otherwise resolved to core `::SyntaxError`). Mirrors the single-file `in_source_constants` answer, which types
      # `Class.new(Super)` as `Singleton[Super]` (the constructed class answers method lookups through Super's chain)
      # and every other recognised form as `Singleton[Const]`.
      #
      # #271 — the Data/Struct forms are here because their absence was an ACTIVE false positive, not merely a missed
      # resolution: a nested `Const = Data.define(...)` invisible cross-file lets Ruby's lexical walk continue to the
      # PARENT namespace's same-named sibling, so `Analysis::PluginFactFingerprint.from_registry(...).opaque?` typed
      # its receiver as the unrelated `Rigor::Analysis::Result` and reported `call.undefined-method` on correct code.
      # Nested `Result` / `Entry` / `Config` Data constants shadowing a sibling are ordinary Ruby, and only the
      # DEFINING file's `in_source_constants` (never part of the project seed) knew about them.
      def record_class_new_constant_decl(node, qualified_prefix, accumulator, self_prefix: nil,
                                         singleton_cref: false)
        rvalue = meta_new_rvalue(node)
        return unless rvalue && meta_new_constant_rvalue?(rvalue)
        return if singleton_cref && !meta_new_path_target_nameable?(node, self_prefix)

        child_prefix = meta_new_child_prefix(node, qualified_prefix, self_prefix)
        return if child_prefix.nil? || child_prefix.empty?

        full = child_prefix.join("::")
        accumulator[full] = Type::Combinator.singleton_of(
          meta_new_constant_decl_name(rvalue, full, qualified_prefix, accumulator)
        )
      end

      # The four recognised class-creating rvalue shapes at constant-write position — the same set
      # {#meta_new_block_body} recognises, so the cross-file table and the per-file block-as-method walk agree on what
      # counts as a declaration.
      def meta_new_constant_rvalue?(rvalue)
        class_new_call?(rvalue) || module_new_call?(rvalue) ||
          data_define_call?(rvalue) || struct_new_call?(rvalue)
      end

      # The name the constant's `Singleton[...]` carries. Only a block-less `Class.new(Super)` borrows its superclass's
      # name (the constructed class answers lookups through `Super`'s chain and declares nothing of its own); every
      # other form — Data/Struct members, any block body — owns methods under its OWN qualified name, which is exactly
      # what the per-file `meta_new_constant_type` answers.
      def meta_new_constant_decl_name(rvalue, full, qualified_prefix, accumulator)
        return full if rvalue.block || data_define_call?(rvalue) || struct_new_call?(rvalue)

        class_new_superclass_name(rvalue, qualified_prefix, accumulator) || full
      end

      # Lexically-qualified name of a `Class.new(Super)` superclass argument, or nil when there is no positional
      # superclass (a bare `Class.new` / `Module.new`). When the unqualified super name is a class already discovered
      # under an enclosing-prefix segment, the qualified form is returned (so `Class.new(Error)` inside `module M`
      # resolves to `M::Error`); otherwise the literal name is returned (covering a core / RBS-known superclass spelled
      # bare).
      def class_new_superclass_name(call_node, qualified_prefix, accumulator)
        arg = call_node.arguments&.arguments&.first
        return nil if arg.nil?

        raw = Source::ConstantPath.qualified_name(arg)
        return nil if raw.nil?

        prefix = qualified_prefix.dup
        until prefix.empty?
          candidate = (prefix + [raw]).join("::")
          return candidate if accumulator.key?(candidate)

          prefix.pop
        end
        raw
      end

      # Walks the program once for `Prism::ModuleNode` and `Prism::ClassNode`, recording the `Singleton[<qualified>]`
      # type for the outermost `constant_path` node of each declaration. Inner segments of a `class Foo::Bar::Baz` path
      # remain real references (resolved through the ordinary lexical walk), so we annotate ONLY the topmost path node.
      # Nested declarations contribute their fully qualified path: `class A::B; class C; ...` produces `A::B` for the
      # outer and `A::B::C` for the inner.
      # @param declared_names — the project's RAW declared-class names, the oracle
      #   {#compact_header_renames} adjudicates this file's compact headers against.
      def build_declaration_artifacts(root, declared_names = nil)
        identity_table = {}.compare_by_identity
        discovered = {}
        record_declarations(root, [], identity_table, discovered,
                            file_compact_header_renames(root, declared_names))
        [identity_table.freeze, synthesize_namespace_prefixes(discovered).freeze]
      end

      # Issue #722 residue 2 — this file's share of the fold's re-anchoring, adjudicated against the project
      # names the fold has already settled. Empty (so the per-node answer stands) whenever the caller has no
      # project table to consult: a `Scope.empty` probe sees one file and cannot know what else declares
      # `Wrap::Outer`, and guessing there is the false positive the whole rule is bounded to avoid.
      def file_compact_header_renames(root, declared_names)
        return EMPTY_RENAMES if declared_names.nil? || declared_names.empty?

        compacts = {}
        collect_class_decls(root, [], {}, compacts)
        return EMPTY_RENAMES if compacts.empty?

        compact_header_renames(compacts, declared_names)
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

      # `self_prefix` names a REBOUND self for `self::`-anchored declarations — a meta-new
      # block's named class, or `[]` for a self nothing names. nil leaves `self` lexical.
      def record_declarations(node, qualified_prefix, identity_table, discovered, renames = EMPTY_RENAMES,
                              self_prefix = nil, singleton_cref: false)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ModuleNode, Prism::ClassNode
          return if record_class_or_module?(node, qualified_prefix, identity_table, discovered, renames,
                                            self_prefix, singleton_cref: singleton_cref)
        when Prism::SingletonClassNode
          # The expression evaluates in the enclosing cref; the body's cref is unnameable —
          # and `self` below it is the singleton class, which `self::` headers decline on.
          record_declarations(node.expression, qualified_prefix, identity_table, discovered, renames,
                              self_prefix, singleton_cref: singleton_cref)
          if node.body
            record_declarations(node.body, qualified_prefix, identity_table, discovered, renames,
                                EMPTY_PREFIX, singleton_cref: true)
          end
          return
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
             Prism::ConstantPathOrWriteNode
          return if record_meta_new_constant?(node, qualified_prefix, identity_table, discovered,
                                              self_prefix, singleton_cref: singleton_cref)
        when Prism::CallNode
          return if record_eval_declarations?(node, qualified_prefix, identity_table, discovered,
                                              renames, self_prefix, singleton_cref)
        end

        node.rigor_each_child do |child|
          record_declarations(child, qualified_prefix, identity_table, discovered, renames,
                              self_prefix, singleton_cref: singleton_cref)
        end
      end

      def record_class_or_module?(node, qualified_prefix, identity_table, discovered, renames = EMPTY_RENAMES,
                                  self_prefix = nil, singleton_cref: false)
        self_decl = self_anchored_decl_prefix(node.constant_path, self_prefix)
        child_prefix = self_decl ||
                       Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
        return false unless child_prefix

        if singleton_cref && !decl_nameable_under_cref?(node) && !self_decl&.any?
          # `class D` below `class <<` opens `#<singleton>::D` — a real class nothing can
          # name — so nothing is registered; the body still walks so nameable headers
          # below it re-anchor at a real cref.
          if node.body
            record_declarations(node.body, [], identity_table, discovered, renames,
                                nil, singleton_cref: true)
          end
          return true
        end

        # Issue #722 residue 2 — the per-file twin of the fold's re-anchoring. The file's own declaration
        # table merges OVER the project seed, so without this a compact header would re-publish the key the
        # fold already moved and a reference written INSIDE the enclosing namespace would resolve to it
        # again. The adjudication itself is the project's: `renames` arrives already settled.
        full = rename_compact_name(renames, child_prefix.join("::"))
        child_prefix = full.split("::")
        singleton = Type::Combinator.singleton_of(full)
        identity_table[node.constant_path] = singleton
        discovered[full] = singleton
        record_declarations(node.body, child_prefix, identity_table, discovered, renames) if node.body
        true
      end

      # Recognises class-creating meta calls at constant-write rvalue position and registers `Const` (qualified by the
      # surrounding class/module path) as a discovered class. `Const.new(...)` then resolves to a fresh `Nominal[Const]`
      # via `meta_new`, instead of the un-narrowed `Dynamic[top]` returned by the default `Class#new` envelope.
      #
      # The recognised meta forms are {#meta_new_constant_rvalue?}'s four —
      # `Data.define`, `Struct.new`, `Class.new`, `Module.new` — plus the
      # `Class.new(<factory>)` wrapper {#resolve_meta_factory_call} unwraps:
      #
      # - `Const = Data.define(*Symbol) [do ... end]`
      # - `Const = Struct.new(*Symbol [, keyword_init: ...]) [do ... end]`
      # - `Const = Class.new [(super)] [do ... end]` / `Const = Module.new [do ... end]`
      #
      # Issue [#703](https://github.com/rigortype/rigor/issues/703) — and their `Holder::Const = …` spellings, which
      # name a class just as unconditionally. Until this arm took them, `Holder::Thing.new(1)` fell to the default
      # `Class#new` envelope on `singleton(Struct)` and handed every reader a bare `Struct`.
      #
      # The block body, if present, is recursed into so any nested class/module declarations in the override block (rare
      # but legal) still feed the discovered table.
      def record_meta_new_constant?(node, qualified_prefix, identity_table, discovered,
                                    self_prefix = nil, singleton_cref: false)
        rvalue = meta_new_rvalue(node)
        factory_call = rvalue.is_a?(Prism::CallNode) &&
                       (resolve_meta_factory_call(rvalue) || meta_new_constant_rvalue?(rvalue))
        return false unless factory_call

        child_prefix = meta_new_child_prefix(node, qualified_prefix, self_prefix)
        return false if child_prefix.nil?
        # A bare write below `class <<` lands on the singleton's own constant table —
        # `#<singleton>::K` names nothing — so the discovered-class entry is declined.
        # A path write (`::K`, `C::K`, `Foo::F`) resolves its base lexically and stays nameable.
        return false if singleton_cref && !meta_new_path_target_nameable?(node, self_prefix)

        full = child_prefix.join("::")
        discovered[full] = Type::Combinator.singleton_of(full) unless full.empty?
        # The rvalue's receiver and arguments evaluate BEFORE the write lands — under the
        # enclosing self — while the block runs with `self` rebound to the class the write
        # names (`K = Class.new(class self::Y; self; end)` opens `C::Y`, not `C::K::Y`).
        [rvalue.receiver, *rvalue.arguments&.arguments.to_a].compact.each do |part|
          record_declarations(part, qualified_prefix, identity_table, discovered,
                              EMPTY_RENAMES, self_prefix, singleton_cref: singleton_cref)
        end
        if (body = rvalue.block&.body)
          record_declarations(body, qualified_prefix, identity_table, discovered,
                              EMPTY_RENAMES, child_prefix, singleton_cref: singleton_cref)
        end
        true
      end

      # The eval-family arm of {#record_declarations}: the receiver and arguments keep the
      # enclosing self; the block's `self` is the receiver for `self::` headers —
      # `Foo.class_eval { class self::Inner }` opens `Foo::Inner`, never `M::Inner` — while
      # `Module.nesting`, and so every bare header, stays lexical. `instance_eval` belongs
      # too: it rebinds `self` for constant anchoring even though its `def`s bind on the
      # receiver's singleton.
      def record_eval_declarations?(node, qualified_prefix, identity_table, discovered, renames,
                                    self_prefix, singleton_cref)
        return false unless node.block.is_a?(Prism::BlockNode) &&
                            RECEIVER_EVAL_CALLS.include?(node.name)

        [node.receiver, *node.arguments&.arguments.to_a].compact.each do |part|
          record_declarations(part, qualified_prefix, identity_table, discovered, renames,
                              self_prefix, singleton_cref: singleton_cref)
        end
        unnameable = unnameable_eval_self?(false, self_prefix, qualified_prefix, singleton_cref)
        eval_self = eval_receiver_prefix(node, self_prefix || qualified_prefix, qualified_prefix,
                                         unnameable_self: unnameable) || []
        if (body = node.block.body)
          record_declarations(body, qualified_prefix, identity_table, discovered, renames,
                              eval_self, singleton_cref: singleton_cref)
        end
        true
      end

      # Whether a `class` / `module` header still names its declaration when it sits below an
      # unnameable singleton cref. A BARE header (`class D`) lands on the singleton's own
      # namespace — `#<singleton>::D` names nothing — and so does a `self::`-anchored or
      # dynamic base. Every other path — `::T`, `C::D`, `Foo::Bar` — resolves its base
      # lexically and stays nameable under the same approximation
      # {Source::ConstantPath.declaration_prefix} uses everywhere else.
      def decl_nameable_under_cref?(node)
        path = node.constant_path
        !path.is_a?(Prism::ConstantReadNode) &&
          !Source::ConstantPath.qualified_name_or_nil(path).nil?
      end

      # Whether a class/module header's body walks under the unnameable-cref marker: the
      # header opens `#<singleton>::Name` when the enclosing cref is unnameable and the
      # header itself names nothing reachable — a bare `D`, or a `self::` path no
      # rebound self covers. An EMPTY `self_decl` is the decline form (a `self::`
      # header under a self nothing names); a non-empty one re-anchors the body at a
      # real cref even below an unnameable enclosure.
      def unnameable_decl?(node, self_decl, singleton_cref)
        return true if self_decl && self_decl.empty?
        return false if self_decl&.any?

        singleton_cref && !decl_nameable_under_cref?(node)
      end

      # The context a `class`/`module` header gives its body: `[self_decl, child_prefix,
      # child_cref]` — the `self::`-anchored prefix when the header rides a rebound
      # self (nil otherwise), the body's qualified prefix, and the unnameable-cref
      # marker. nil when the header renders no prefix, which a parsed header cannot
      # but keeps every caller total.
      def decl_body_context(node, qualified_prefix, self_base, singleton_cref)
        self_decl = self_anchored_decl_prefix(node.constant_path, self_base)
        child_prefix = self_decl ||
                       Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
        return nil unless child_prefix

        [self_decl, child_prefix, unnameable_decl?(node, self_decl, singleton_cref)]
      end

      # Whether a meta-new constant write's TARGET still names its class below an unnameable
      # The qualified prefix a `self::`-anchored declaration or write target names when
      # `self_base` names the REBOUND self — a `def_owner` override, a mixin `current_class`,
      # or a meta-new class prefix. nil `self_base` means `self` is the lexical class — the
      # lenient render of {Source::ConstantPath.declaration_prefix} already resolves it — and
      # `[]` marks a self no name exists for (an anonymous or singleton block), where the
      # path stays unnameable. nil return: not a `self::` path, or no override applies.
      def self_anchored_decl_prefix(path, self_base)
        return nil unless self_base && (tail = self_anchored_tail(path))
        return [] if self_base.empty?

        self_base + tail
      end

      # singleton cref — the path-write twin of {#decl_nameable_under_cref?}. `::K`, `C::K`,
      # `Foo::F` resolve their base lexically; a bare `K =` / `K ||=` lands on the singleton's
      # own constant table, and a `self::` or dynamic base names nothing reachable — unless
      # `self_base` names a rebound self (`K = Class.new { self::X = … }` writes `K::X`).
      def meta_new_path_target_nameable?(node, self_base = nil)
        target =
          case node
          when Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode then node.target
          else return false
          end
        return self_base.any? if self_base && self_anchored_tail(target)

        !Source::ConstantPath.qualified_name_or_nil(target).nil?
      end

      # The class name a meta-new write under an unnameable cref still assigns for the OWNER
      # tables (mixins, census) — only a definite `A::K = …` / `::K = …` write, matching
      # {#meta_new_block_owner}'s plain-write requirement for the same #963 reason (an `||=`
      # may never run the rvalue). Nil where the write names nothing.
      def meta_new_owner_under_cref(node, qualified_prefix, self_base = nil)
        return nil unless node.is_a?(Prism::ConstantPathWriteNode)
        return nil unless meta_new_path_target_nameable?(node, self_base)

        meta_new_child_prefix(node, qualified_prefix, self_base)&.join("::")
      end

      # The owner a meta-new write gives the block for the MIXIN tables — every definite
      # write form, including `||=` and path-or-write: an `||=` block still runs on the
      # class the write names when it runs, so `K ||= Class.new { include I }` mixes I
      # into K exactly the way its `def`s land `K#m`. The census keeps the narrower
      # {#meta_new_block_owner} / {#meta_new_owner_under_cref} pair because its `||=`
      # rows are unpublished (#963). Nil where the write names nothing below an
      # unnameable cref.
      def meta_new_mixin_owner(node, qualified_prefix, singleton_cref, self_base = nil)
        return nil if singleton_cref && !meta_new_path_target_nameable?(node, self_base)

        meta_new_child_prefix(node, qualified_prefix, self_base)&.join("::")
      end

      # Recognises `Data.define(*Symbol)` and `Data.define(*Symbol) do ... end` at constant-write rvalue position. The
      # receiver MUST be the bare `Data` constant (or `::Data`); other receivers (a local variable, a method call
      # return) are rejected because their identity is not statically known.
      def data_define_call?(node)
        return false unless node.is_a?(Prism::CallNode)
        return false unless node.name == :define
        return false unless meta_constant_receiver?(node.receiver, :Data)

        args = node.arguments&.arguments || []
        args.all?(Prism::SymbolNode)
      end

      # Recognises `Struct.new(*Symbol)` and `Struct.new(*Symbol, keyword_init: <expr>)` at constant-write rvalue
      # position. A trailing `KeywordHashNode` (the `keyword_init: ...` form) is accepted but does not contribute to
      # member discovery; every other argument MUST be a `Prism::SymbolNode`. At least one Symbol member is required —
      # `Struct.new()` is a degenerate form callers don't typically use.
      def struct_new_call?(node)
        return false unless meta_call_with_name?(node, :Struct, :new)

        args = node.arguments&.arguments || []
        positional = struct_new_positionals(args)
        return false if positional.nil? || positional.empty?

        positional.all?(Prism::SymbolNode)
      end

      # Recognises `Module.new` and `Module.new(&block)` / `Module.new do ... end` at constant-write rvalue position.
      # The block body is the anonymous module's `module_eval` body; defs inside it bind methods on the named constant
      # (`Const = Module.new do ...; def foo; ...; end; end`). Arguments are NOT inspected because `Module.new` accepts
      # no positionals — Ruby raises ArgumentError if any are passed — so a malformed call falls through the walker
      # without affecting analysis.
      def module_new_call?(node)
        meta_call_with_name?(node, :Module, :new)
      end

      # Recognises `Class.new`, `Class.new(super_class)`, and the block form `Class.new { ... }`. Like
      # `module_new_call?`, the block body is walked as the anonymous class's body. The optional `super_class`
      # positional is accepted but does NOT route through `ancestor` discovery in this slice — the synthesised class
      # still answers method lookups via its own body's defs, mirroring how `Struct.new` / `Data.define` are handled.
      def class_new_call?(node)
        meta_call_with_name?(node, :Class, :new)
      end

      def meta_call_with_name?(node, receiver_name, method_name)
        return false unless node.is_a?(Prism::CallNode)
        return false unless node.name == method_name

        meta_constant_receiver?(node.receiver, receiver_name)
      end

      def struct_new_positionals(args)
        args.last.is_a?(Prism::KeywordHashNode) ? args[0..-2] : args
      end

      def meta_constant_receiver?(node, expected_name)
        case node
        when Prism::ConstantReadNode
          node.name == expected_name
        when Prism::ConstantPathNode
          node.parent.nil? && node.name == expected_name
        end
      end

      # Walks `node`'s subtree DFS and fills in scope entries for every Prism node the StatementEvaluator did not visit
      # (i.e. expression- interior nodes like the receiver/args of a CallNode). Those nodes inherit their nearest
      # recorded ancestor's scope.
      #
      # `IfNode` / `UnlessNode` are special-cased: the truthy and falsey branches each get their predicate's narrowed
      # scope before recursing. This handles expression-position conditionals (e.g. `cache[k] = if cond; t; else; e;
      # end` and conditionals nested as call arguments) which are typed by ExpressionTyper without going through
      # `eval_if`'s narrowing path.
      #
      # A block or lambda the evaluator never entered is special-cased too ({#closure_scope}): its own locals shadow
      # the enclosing bindings of the same names. Such a block of a call {FreshFrameBlocks} names enters as the
      # evaluator enters it ({#propagate_call}).
      def propagate(node, table, parent_scope)
        return unless node.is_a?(Prism::Node)

        recorded = table.key?(node)
        current_scope =
          if recorded
            table[node]
          else
            table[node] = parent_scope
            parent_scope
          end

        case node
        when Prism::IfNode
          propagate_if_branches(node, table, current_scope)
        when Prism::UnlessNode
          propagate_unless_branches(node, table, current_scope)
        when Prism::BlockNode, Prism::LambdaNode
          # An entered block is recorded with its entry scope, parameters bound. An entered `->` is recorded with
          # the ENCLOSING scope ({StatementEvaluator#eval_lambda} enters only its body), so its parameter list
          # still needs the boundary: `f = ->(o, b = (o + 1)) { b }` reads the default's `o` as the parameter. A
          # `when ->(o) { … }` condition is recorded without being entered at all, body included.
          entered = recorded && node.is_a?(Prism::BlockNode)
          child_scope = entered ? current_scope : closure_scope(node, current_scope)
          node.rigor_each_child { |child| propagate(child, table, child_scope) }
        when Prism::CallNode
          propagate_call(node, table, current_scope)
        else
          node.rigor_each_child { |child| propagate(child, table, current_scope) }
        end
      end

      # Issue #1361 — the block of `Thread.new`, `Fiber.new`, `define_method` and the other calls
      # {FreshFrameBlocks.fresh_entry?} names does not read the match-global narrowing of the body it is written in.
      # The evaluator enters it as {FreshFrameBlocks.entry} gives ({MatchRebinding.block_entry}), but a block in a
      # value position — the receiver of `Thread.new { $1 }.value` — is not entered, and its body would read the
      # statement's narrowing.
      def propagate_call(node, table, current_scope)
        block = node.block
        fresh = block.is_a?(Prism::BlockNode) && !table.key?(block) &&
                FreshFrameBlocks.fresh_entry?(node, current_scope)
        unless fresh
          node.rigor_each_child { |child| propagate(child, table, current_scope) }
          return
        end

        entry = FreshFrameBlocks.entry(current_scope, node)
        node.rigor_each_child { |child| propagate(child, table, child.equal?(block) ? entry : current_scope) }
      end

      # The scope the children of an unentered block or lambda inherit. The evaluator enters a statement-level
      # call's block ({StatementEvaluator#evaluate_block_if_present}), an assignment's rvalue and a statement-level
      # `->`'s body, but not a closure in a value position — a call argument (`show(xs.map { |o| o + 1 })`), a
      # receiver chain (`xs.map { |o| o + 1 }.sum`), a literal element — nor a `super` call's block, so its body
      # falls to this walk and would inherit the enclosing statement's scope verbatim. That scope still binds an
      # outer `o` the block parameter shadows, and a read of the parameter typed as the outer local: `o = { x: 1 }`
      # made `o + 1` an undefined-method error.
      #
      # Every name in the closure's own local table (Prism's `locals`: its parameters, `;`-locals and the locals
      # its body introduces) is a new variable, and so is the implicit `it` of a block that uses it, which Prism
      # keeps out of `locals` although the binder binds it (`xs.each { show(it.map { it + 1 }) }` read the inner
      # `it` as the outer block's). An enclosing binding of such a name is replaced with `Dynamic[top]`. Not the
      # signature's parameter type: this walk evaluates nothing, and a body write to the name is never threaded,
      # so any narrower claim could be stale. A name the enclosing scope does not bind is left unbound, which
      # reads the same `Dynamic[top]`. Captured names — outer locals the body reads or rebinds without
      # redeclaring them — keep the enclosing binding.
      def closure_scope(closure, scope)
        scope = shadow_local(scope, :it) if closure.parameters.is_a?(Prism::ItParametersNode)
        closure.locals.reduce(scope) { |acc, name| shadow_local(acc, name) }
      end

      def shadow_local(scope, name)
        scope.local(name).nil? ? scope : scope.with_local(name, Type::Combinator.untyped)
      end

      def propagate_if_branches(node, table, current_scope)
        truthy_scope, falsey_scope = Narrowing.predicate_scopes(node.predicate, current_scope)
        propagate(node.predicate, table, current_scope) if node.predicate
        propagate(node.statements, table, truthy_scope) if node.statements
        propagate(node.subsequent, table, falsey_scope) if node.subsequent
      end

      def propagate_unless_branches(node, table, current_scope)
        truthy_scope, falsey_scope = Narrowing.predicate_scopes(node.predicate, current_scope)
        propagate(node.predicate, table, current_scope) if node.predicate
        propagate(node.statements, table, falsey_scope) if node.statements
        propagate(node.else_clause, table, truthy_scope) if node.else_clause
      end
    end
  end
end
