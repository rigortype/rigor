# frozen_string_literal: true

require "prism"

require_relative "../scope"
require_relative "../type"
require_relative "mutation_widening"
require_relative "narrowing"
require_relative "statement_evaluator"
require_relative "struct_fold_safety"

module Rigor
  module Inference
    # Builds a per-node scope index for a Prism program by running
    # `Rigor::Inference::StatementEvaluator` over the root and recording
    # the entry scope visible at every node. Expression-interior nodes
    # the evaluator does not specialise (call receivers, arguments,
    # array/hash elements, ...) inherit their nearest statement-y
    # ancestor's recorded scope, so a downstream caller that looks up
    # the scope for any Prism node in the tree always gets the scope
    # that was effectively visible at that point.
    #
    # The CLI commands `rigor type-of` and `rigor type-scan` consume
    # the index so that local-variable bindings established earlier in
    # the program are visible to the typer when probing later nodes.
    # Without the index, both commands would type every node under an
    # empty scope and miss the constant-folding / dispatch precision
    # that Slice 3 phase 2's StatementEvaluator unlocks.
    #
    # The returned object is an identity-comparing Hash:
    #
    # ```ruby
    # index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Scope.empty)
    # index[some_prism_node] #=> the Rigor::Scope visible at that node
    # ```
    #
    # Nodes that are not part of the program subtree (e.g. synthesised
    # virtual nodes that the caller looks up after the fact) yield the
    # `default_scope`. The returned Hash is mutable in principle but
    # callers MUST treat it as read-only; the indexer itself never
    # exposes a way to update it past construction.
    # rubocop:disable Metrics/ModuleLength
    module ScopeIndexer
      module_function

      # Build the scope index for a Prism program subtree.
      #
      # @param root [Prism::Node] usually a `Prism::ProgramNode`, but any
      #   subtree the caller wants the indexer to walk works.
      # @param default_scope [Rigor::Scope] the scope used for the root,
      #   and the fallback returned for any Prism node not contained in
      #   `root`'s subtree.
      # @param converged_loop_recording [Boolean] display-path flag —
      #   when true the evaluator re-records fixpoint-tracked loop
      #   bodies from their CONVERGED bindings so per-line probes
      #   (`rigor annotate`) reflect the post-writeback state, not the
      #   cap-N intermediate constants. Off for the check path.
      # @return [Hash{Prism::Node => Rigor::Scope}] identity-comparing
      #   table whose default value is `default_scope`.
      def index(root, default_scope:, converged_loop_recording: false) # rubocop:disable Metrics/AbcSize
        # Slice A-declarations. Build the declaration overrides
        # first so every scope handed to the StatementEvaluator
        # already carries the table; structural sharing through
        # `Scope#with_local` / `#with_fact` / `#with_self_type`
        # propagates it across every derived scope.
        declared_types, discovered_classes = build_declaration_artifacts(root)
        # Merge the indexer's findings on top of whatever the
        # base scope already carries so callers that seed
        # cross-file class knowledge (e.g. the ADR-14
        # `SigGen::ObservationCollector` pre-walking project
        # `lib/` before scanning `spec/`) keep their seeds
        # alongside the per-file declarations the indexer
        # itself discovers. Indexer-found entries win on
        # collision — same-file declarations are the most
        # specific authority.
        merged_classes = default_scope.discovered_classes.merge(discovered_classes)
        seeded_scope = default_scope.with_discovery(
          default_scope.discovery.with(declared_types: declared_types,
                                       discovered_classes: merged_classes)
        )

        # Slice 7 phase 2. Pre-pass over every class/module body
        # to collect the per-class ivar accumulator. Seeded after
        # declared_types so the rvalue typer in the pre-pass can
        # see declaration overrides.
        class_ivars = build_class_ivar_index(root, seeded_scope)
        seeded_scope = seeded_scope.with_discovery(seeded_scope.discovery.with(class_ivars: class_ivars))

        # Slice 7 phase 6. Same pre-pass shape for cvars (per
        # class) and globals (program-wide). Globals are also
        # materialised into the top-level scope's `globals` map
        # so reads at the top level (and in CLI probes that do
        # not enter a method body) observe the precise type
        # without consulting the accumulator on every lookup.
        class_cvars = build_class_cvar_index(root, seeded_scope)
        seeded_scope = seeded_scope.with_discovery(seeded_scope.discovery.with(class_cvars: class_cvars))
        program_globals = build_program_global_index(root, seeded_scope)
        seeded_scope = seeded_scope.with_discovery(seeded_scope.discovery.with(program_globals: program_globals))
        program_globals.each { |name, type| seeded_scope = seeded_scope.with_global(name, type) }

        # Slice 7 phase 9. In-source constant value tracking.
        # Walks every ConstantWriteNode/ConstantPathWriteNode in
        # the program and types its rvalue under a scope that
        # carries the surrounding qualified prefix as
        # `self_type`, so the rvalue typer sees in-class
        # references resolve correctly. Multiple writes to the
        # same qualified name union via `Type::Combinator.union`.
        in_source_constants = build_in_source_constants(root, seeded_scope)
        seeded_scope = seeded_scope.with_discovery(
          seeded_scope.discovery.with(in_source_constants: in_source_constants)
        )

        # Slice 7 phase 12. In-source method discovery. Walks
        # every class/module body for `Prism::DefNode` and
        # recognised `define_method` calls and records the
        # introduced method names. `rigor check` consults the
        # table to suppress false positives for methods the
        # user has defined but no RBS sig describes. Merged
        # UNDER the cross-file pre-pass seed; details: merge_project_method_indexes.
        discovered_methods = deep_merge_class_methods(
          default_scope.discovered_methods, build_discovered_methods(root)
        )
        seeded_scope = seeded_scope.with_discovery(seeded_scope.discovery.with(discovered_methods: discovered_methods))

        # v0.0.2 #5 + ADR-24 slice 2 — record per-instance-method
        # def nodes, the class -> superclass map, and the
        # class/module -> included-modules map, each merged under
        # the cross-file pre-pass seed (see below).
        # v0.1.2 — per-class table of method visibilities
        # (`:public` / `:private` / `:protected`). The
        # `def.method-visibility-mismatch` and ADR-35
        # `def.override-visibility-reduced` CheckRules consult the
        # table. Seeded inside `merge_project_method_indexes` so the
        # per-file visibilities merge OVER the cross-file project seed
        # rather than overwriting it.
        seeded_scope = merge_project_method_indexes(seeded_scope, default_scope, root)

        table = {}.compare_by_identity
        table.default = seeded_scope

        # Last-visit-wins, not first: when `StatementEvaluator`
        # internally re-evaluates a subtree (notably `eval_begin`'s
        # retry-edge widening pass), the LATER visit carries the
        # corrected entry scope (e.g. a `tries` widened to
        # `Nominal[Integer]` after the rescue body's `tries += 1;
        # retry` is observed). The diagnostic layer reads
        # `table[node]` to type predicates; the second pass's
        # entry is the one that reflects all flow-derived
        # rebinds, so it MUST overwrite the first.
        # ADR-48 Struct slice 3 — install the top-level fold-safe-local set so
        # a member read off a mutation-free top-level struct binding folds.
        seeded_scope = seed_struct_fold_safe(seeded_scope, root)

        on_enter = ->(node, scope) { table[node] = scope }
        StatementEvaluator.new(scope: seeded_scope, on_enter: on_enter,
                               converged_loop_recording: converged_loop_recording).evaluate(root)

        propagate(root, table, seeded_scope)
        table
      end

      # ADR-48 Struct slice 3 — installs the top-level fold-safe-local set
      # ({Inference::StructFoldSafety}). Struct member layouts of constant
      # receivers are resolved through the side-table the seeded scope carries.
      def seed_struct_fold_safe(seeded_scope, root)
        seeded_scope.with_struct_fold_safe(
          StructFoldSafety.fold_safe_locals(
            root, ->(name) { seeded_scope.struct_member_layout(name)&.[](:members) }
          )
        )
      end

      # v0.0.2 #5 + ADR-24 slice 2 — seeds the three
      # project-method indexes onto `seeded_scope`: the
      # per-instance-method def-node table, the class ->
      # superclass map, and the class/module -> included-modules
      # map. Each per-file table is merged UNDER the cross-file
      # `discovered_def_index_for_paths` seed carried on
      # `default_scope` — same-file declarations win per entry,
      # the cross-file seed supplies sibling-file ancestors.
      def merge_project_method_indexes(seeded_scope, default_scope, root)
        def_nodes = default_scope.discovered_def_nodes.merge(
          build_discovered_def_nodes(root)
        ) { |_class, cross_file, per_file| cross_file.merge(per_file) }
        singleton_def_nodes = default_scope.discovered_singleton_def_nodes.merge(
          build_discovered_singleton_def_nodes(root)
        ) { |_class, cross_file, per_file| cross_file.merge(per_file) }
        superclasses = default_scope.discovered_superclasses.merge(
          build_discovered_superclasses(root)
        )
        includes = default_scope.discovered_includes.merge(
          build_discovered_includes(root)
        ) { |_class, cross_file, per_file| (cross_file + per_file).uniq }
        # ADR-35 — per-file visibilities merged OVER the cross-file
        # seed (the current file is authoritative for its own classes;
        # sibling-file ancestors are preserved from the project seed).
        method_visibilities = default_scope.discovered_method_visibilities.merge(
          build_discovered_method_visibilities(root)
        ) { |_class, cross_file, per_file| cross_file.merge(per_file) }
        # ADR-48 — per-file Data + Struct member layouts merged OVER the
        # cross-file seed (same-file declaration is authoritative).
        data_member_layouts, struct_member_layouts = merge_member_layouts(default_scope, root)

        seeded_scope.with_discovery(
          seeded_scope.discovery.with(
            discovered_def_nodes: def_nodes,
            discovered_singleton_def_nodes: singleton_def_nodes,
            discovered_superclasses: superclasses,
            discovered_includes: includes,
            discovered_method_visibilities: method_visibilities,
            data_member_layouts: data_member_layouts,
            struct_member_layouts: struct_member_layouts
          )
        )
      end

      # ADR-48 — the per-file Data + Struct member-layout tables, each merged
      # OVER the cross-file seed so a same-file declaration wins for its own
      # classes. Returned as a pair to keep {#merge_project_method_indexes}
      # under the method-size budget.
      def merge_member_layouts(default_scope, root)
        [
          default_scope.data_member_layouts.merge(build_data_member_layouts(root)),
          default_scope.struct_member_layouts.merge(build_struct_member_layouts(root))
        ]
      end

      # Slice 7 phase 2. Builds the class-level ivar accumulator
      # by walking every `Prism::ClassNode` / `Prism::ModuleNode`
      # body, descending into each nested `Prism::DefNode`, and
      # typing every `Prism::InstanceVariableWriteNode` rvalue
      # under a scope that carries the appropriate `self_type`
      # for that def (singleton vs instance). The rvalue is
      # typed with NO local bindings — the pre-pass lacks
      # statement-level threading — so `@x = 1` records
      # `Constant[1]` but `@x = some_local + 1` records
      # `Dynamic[Top]` (since `some_local` is unbound at
      # pre-pass time). Multiple writes to the same ivar union
      # via `Type::Combinator.union`.
      def build_class_ivar_index(root, default_scope)
        accumulator = {}
        mutated_ivars = {}
        read_before_write = {}
        init_writes = {}
        # WD3 — per-class summary of `{class_name => {method_name =>
        # Set<ivar names definitely assigned non-nil on every
        # completing path>}}`, consulted by `dead_transient_nil_writes`
        # so a ctor that reassigns `@x` indirectly through an
        # unconditional same-class method call (`mask!`) credits the
        # overwrite. Built once per program here, memoised by class.
        method_assign_effects = build_method_assign_effects(root)
        walk_class_ivars(root, [], default_scope, accumulator, mutated_ivars,
                         read_before_write, init_writes, method_assign_effects)
        widen_mutated_ivar_entries!(accumulator, mutated_ivars)
        contribute_read_before_write_nil!(accumulator, read_before_write, init_writes)
        accumulator.transform_values(&:freeze).freeze
      end

      # B2.3 — finalize the read-before-write nil contribution.
      # For each class, for each ivar where SOME method body
      # observed a read-before-write AND no `initialize` write
      # exists for that ivar, contribute `Constant[nil]` to the
      # class-wide accumulator.
      #
      # The `initialize` filter is the soundness gate: Ruby
      # semantics guarantee `initialize` runs first (via
      # `Class.new`), so a write there reaches every other
      # method body's read. Read-before-write in a non-init
      # method is then NOT a nil-at-runtime case — it's just
      # AST-order coincidence. Without this filter a normal
      # `def initialize; @x = ... end` / `def use; @x.foo end`
      # class would have `@x` widened with nil, producing FPs
      # at every `@x.foo` call.
      def contribute_read_before_write_nil!(accumulator, read_before_write, init_writes)
        nil_t = Type::Combinator.constant_of(nil)
        read_before_write.each do |class_name, ivar_set|
          init_set = init_writes[class_name] || EMPTY_GUARDED_IVARS
          per_class = accumulator[class_name]
          next if per_class.nil?

          ivar_set.each do |ivar_name|
            # Soundness gates (in order):
            # (1) `initialize` writes the ivar → it's set
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

      # Walks the post-collected accumulator and widens any Tuple
      # / HashShape entry for an ivar that observed a mutator call
      # anywhere in the same class body. The mutation evidence
      # comes from `gather_ivar_writes` recording every
      # `@ivar.<method>(...)` call whose method is in
      # `MutationWidening::ARRAY_MUTATORS` or `HASH_MUTATORS`.
      #
      # The widening uses `MutationWidening.widen_for_mutator` —
      # the same primitive `Inference::StatementEvaluator#eval_call`
      # applies for per-method-body widening on a local / ivar
      # receiver. The class-level pass extends that primitive's
      # reach so a `Tuple`-seeded ivar in `initialize` is observed
      # as `Nominal[Array]` at the entry of every OTHER method
      # body in the class — closing the cross-method gap noted in
      # ROADMAP § Future cycles / Type-language / engine
      # ("Tuple / HashShape widening for ivar-seeded literals
      # after mutation"; Redmine 6.1.2
      # `Redmine::Views::Builders::Structure` is the canonical
      # worked site).
      #
      # Always-safe: the widening can only LOSE precision; the
      # underlying nominal (`Array` / `Hash`) and the element
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

      # Walks a class-ivar accumulator entry (which may be a
      # `Union` of multiple write rvalues) and widens any
      # `Tuple` or `HashShape` member whose corresponding
      # mutator family was observed against the ivar somewhere
      # in the class. Class-level widening is more aggressive
      # than the per-method-body `MutationWidening` primitive:
      # it widens both the SHAPE carrier (Tuple → Array,
      # HashShape → Hash) AND the element types to
      # `Dynamic[Top]`. The justification — once any method
      # mutates the ivar, its post-mutation contents are
      # statically unknown across method boundaries, so
      # preserving the seed-write's element precision would be
      # an unsound over-claim (e.g. `@struct = [{}]; somewhere:
      # @struct << []` makes the next read's element no longer
      # `Constant[{}]`).
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
          return member unless observed_methods.any? { |m| MutationWidening::HASH_MUTATORS.include?(m) }

          Type::Combinator.nominal_of("Hash",
                                      type_args: [Type::Combinator.untyped, Type::Combinator.untyped])
        else
          member
        end
      end

      def walk_class_ivars(node, qualified_prefix, default_scope, accumulator, mutated_ivars, # rubocop:disable Metrics/CyclomaticComplexity,Metrics/ParameterLists
                           read_before_write = nil, init_writes = nil, method_assign_effects = nil)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = qualified_name_for(node.constant_path)
          if name
            child_prefix = qualified_prefix + [name]
            if node.body
              # Class-body level `@x = nil` writes don't
              # initialise instance ivars at runtime (the
              # class's own singleton ivars and the instance's
              # ivars are separate stores), but they signal
              # "the author KNOWS @x could be nil" and extend
              # the B2.3 soundness gate: an ivar with a
              # class-body write is exempted from the
              # read-before-write nil contribution because the
              # seed already reflects the author's acknowledged
              # nullability via the def-body writes' union.
              # Without this exemption, code that explicitly
              # `@x = nil`s at class-body level then writes
              # `@x = SomeClass.new` inside an instance method
              # gains an unjustified nil widening at every
              # read.
              collect_class_body_ivar_writes(node.body, child_prefix.join("::"), init_writes) if init_writes
              walk_class_ivars(node.body, child_prefix, default_scope, accumulator,
                               mutated_ivars, read_before_write, init_writes, method_assign_effects)
            end
            return
          end
        when Prism::DefNode
          collect_def_ivar_writes(node, qualified_prefix, default_scope, accumulator,
                                  mutated_ivars, read_before_write, init_writes, method_assign_effects)
          return
        when Prism::CallNode
          if init_writes && !qualified_prefix.empty? &&
             node.block.is_a?(Prism::BlockNode) &&
             block_initializer?(qualified_prefix.join("::"), node.name, default_scope)
            collect_block_ivar_writes(node.block, qualified_prefix, default_scope,
                                      accumulator, mutated_ivars, init_writes)
          end
        end

        node.compact_child_nodes.each do |child|
          walk_class_ivars(child, qualified_prefix, default_scope, accumulator,
                           mutated_ivars, read_before_write, init_writes, method_assign_effects)
        end
      end

      def collect_def_ivar_writes(def_node, qualified_prefix, default_scope, accumulator, mutated_ivars, # rubocop:disable Metrics/ParameterLists
                                  read_before_write = nil, init_writes = nil, method_assign_effects = nil)
        return if def_node.body.nil? || qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        singleton = def_node.receiver.is_a?(Prism::SelfNode) ||
                    def_receiver_targets_lexical_self?(def_node.receiver, qualified_prefix)
        self_type =
          if singleton
            Type::Combinator.singleton_of(class_name)
          else
            Type::Combinator.nominal_of(class_name)
          end
        body_scope = default_scope.with_self_type(self_type)

        # C2 — transient `@x = nil` dead-write elimination. When a
        # method body opens with an unconditional `@x = nil`
        # (defensive init) and then *definitely* reassigns `@x` to a
        # non-nil value on every completing path (a later
        # unconditional statement-level write, OR an `if/else` whose
        # both branches write `@x`), the opening nil is dead — it can
        # never be observed at method exit. Recording it anyway folds
        # a spurious `nil` constituent into the flow-insensitive
        # class-ivar union, which then poisons reads in OTHER methods
        # (e.g. ipaddr `IN4MASK ^ @mask_addr` rejects the resulting
        # `Integer | nil`). The set holds the `object_id`s of the
        # transient write nodes to skip; soundness is post-domination
        # at the top statement level, so dropping the nil never hides
        # a real runtime-nil read.
        dead_writes = dead_transient_nil_writes(def_node.body, class_name, method_assign_effects)
        gather_ivar_writes(def_node.body, body_scope, class_name, accumulator,
                           EMPTY_GUARDED_IVARS, mutated_ivars, dead_writes)

        # B2.3 — collect per-method evidence for the read-before-
        # write nil contribution. The accumulator-level decision
        # ("is this ivar truly read-before-write across the
        # class lifetime?") is finalised at
        # `contribute_read_before_write_nil!` after the whole
        # class body has been walked, using `init_writes` as
        # the soundness gate (an ivar written in `initialize`
        # is initialised before any other method body runs).
        collect_read_before_write_evidence(def_node, class_name, read_before_write, init_writes, default_scope)
      end

      # ADR-38 block-form: collects ivar writes from a CallNode's
      # block body (e.g. RSpec `before { @x = … }` / `let(:x) { … }`)
      # and folds them into `init_writes`, suppressing the
      # read-before-write nil contribution the same way a def-form
      # initializer does. The block body is always treated as an
      # initializer (the caller has already verified the method name
      # is declared as a block_method initializer), so there is no
      # read-before-write evidence collection step here.
      def collect_block_ivar_writes(block_node, qualified_prefix, default_scope, accumulator,
                                    mutated_ivars, init_writes)
        return if block_node.body.nil? || qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        self_type = Type::Combinator.nominal_of(class_name)
        body_scope = default_scope.with_self_type(self_type)

        gather_ivar_writes(block_node.body, body_scope, class_name, accumulator,
                           EMPTY_GUARDED_IVARS, mutated_ivars)

        seen_writes = Set.new
        read_first = Set.new
        detect_read_before_write(block_node.body, seen_writes, read_first)
        init_set = (init_writes[class_name] ||= Set.new)
        seen_writes.each { |name| init_set << name }
      end

      # ADR-38 block-form gate: true when a loaded plugin declares
      # `method_name` a block-form initializer for `class_name` (or
      # an ancestor). Mirrors `additional_initializer?` but queries
      # `covers_block_method?` instead of `covers_method?`.
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

      # Walks the method body in AST (== execution) order
      # tracking ivar names whose first reference is a read.
      # The set is unioned into the class-wide
      # `read_before_write` accumulator. For `initialize` def
      # bodies, every write target is unioned into
      # `init_writes` instead — used by the finalisation step
      # to suppress nil contribution for ivars the constructor
      # guarantees are initialised.
      def collect_read_before_write_evidence(def_node, class_name, read_before_write, init_writes, default_scope = nil)
        return if read_before_write.nil? || init_writes.nil?

        seen_writes = Set.new
        read_first = Set.new
        detect_read_before_write(def_node.body, seen_writes, read_first)

        # ADR-38 — `initialize` is the built-in initializer gate;
        # a plugin may declare additional `def`-form initializer
        # methods (minitest `setup`, Rails `after_initialize`, DI
        # setters) on a constrained class. Both fold their writes
        # into `init_writes`, suppressing the read-before-write nil
        # contribution for sibling readers.
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

      # ADR-38 — true when a loaded plugin declares `method_name` an
      # additional initializer for `class_name` (or an ancestor).
      # Reads the plugin registry off the pre-pass scope's
      # environment; the receiver-constraint match reuses
      # `Environment#class_ordering` (the same mechanism ADR-16
      # Tier A's `MacroBlockSelfType` uses). The whole lookup is
      # wrapped so any resolution failure degrades to "no match" —
      # since the gate only ever SUPPRESSES a nil contribution, a
      # missed match is false-positive-safe (it merely leaves the
      # existing nil widening in place).
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

      # Walks class-body level statements (i.e. NOT inside any
      # nested DefNode / ClassNode / ModuleNode) and records
      # every `@x = …` write target as a class-body init.
      # Consumed by `contribute_read_before_write_nil!` to
      # exempt ivars the author already knows might be nil
      # (the `@x = nil` at class-body level is the canonical
      # nullability acknowledgement; the instance @x is
      # technically a separate store, but the pragmatic intent
      # is unambiguous).
      def collect_class_body_ivar_writes(node, class_name, init_writes)
        return unless node.is_a?(Prism::Node)
        return if IVAR_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

        if node.is_a?(Prism::InstanceVariableWriteNode) ||
           node.is_a?(Prism::InstanceVariableOrWriteNode) ||
           node.is_a?(Prism::InstanceVariableAndWriteNode) ||
           node.is_a?(Prism::InstanceVariableOperatorWriteNode)
          (init_writes[class_name] ||= Set.new) << node.name
        end

        node.compact_child_nodes.each do |child|
          collect_class_body_ivar_writes(child, class_name, init_writes)
        end
      end

      def detect_read_before_write(node, seen_writes, read_first)
        return unless node.is_a?(Prism::Node)
        return if IVAR_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

        read_first << node.name if node.is_a?(Prism::InstanceVariableReadNode) && !seen_writes.include?(node.name)

        # Descend BEFORE recording a write — `@x = @x + 1`'s
        # RHS is an `InstanceVariableReadNode` that runs before
        # the write is committed; the read is therefore
        # read-before-write semantically. Prism's
        # `compact_child_nodes` returns the value child before
        # the lvalue target, matching this order.
        node.compact_child_nodes.each do |c|
          detect_read_before_write(c, seen_writes, read_first)
        end

        seen_writes << node.name if IVAR_WRITE_NODES.any? { |klass| node.is_a?(klass) }
      end

      IVAR_BARRIER_NODES = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode].freeze
      private_constant :IVAR_BARRIER_NODES

      EMPTY_GUARDED_IVARS = Set.new.freeze
      private_constant :EMPTY_GUARDED_IVARS

      def gather_ivar_writes(node, scope, class_name, accumulator, guarded_ivars = EMPTY_GUARDED_IVARS,
                             mutated_ivars = nil, dead_writes = nil)
        return unless node.is_a?(Prism::Node)

        if node.is_a?(Prism::InstanceVariableWriteNode) &&
           !(dead_writes && dead_writes.include?(node.object_id))
          record_ivar_write(node, scope, class_name, accumulator,
                            guarded: guarded_ivars.include?(node.name))
        end

        # N1 — parallel / multiple assignment (`old, @cb = @cb, block`,
        # `@i, @o, @e, @thr = Open3.popen3(cmd)`). A direct
        # `InstanceVariableWriteNode` is the only write form this
        # collector handled, so an ivar appearing as a `MultiWriteNode`
        # target was silently dropped from the class-ivar union — leaving
        # it to seed as pure `nil` (from a sibling `@cb = nil` ctor write,
        # or absent entirely) and false-fire `if @cb` always-falsey /
        # `@thr.alive?` undefined-for-nil. Record each ivar target with
        # its tuple-position RHS type where the RHS is array/tuple-shaped,
        # else the unanalyzable floor (the same `Dynamic[top]` a single
        # write to an unknown RHS records — an unanalyzable multi-write
        # means unknown, not nil).
        record_multi_write_ivars(node, scope, class_name, accumulator)

        record_ivar_mutator_call(node, class_name, mutated_ivars) if mutated_ivars && node.is_a?(Prism::CallNode)

        # Don't recurse into nested defs, classes, or modules; their
        # ivars belong to their own enclosing class.
        return if IVAR_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

        if node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)
          walk_conditional_ivar_writes(node, scope, class_name, accumulator, guarded_ivars,
                                       mutated_ivars, dead_writes)
          return
        end

        node.compact_child_nodes.each do |c|
          gather_ivar_writes(c, scope, class_name, accumulator, guarded_ivars, mutated_ivars, dead_writes)
        end
      end

      # Records `@ivar.<method>(...)` calls whose method is in
      # `MutationWidening::ARRAY_MUTATORS` or `HASH_MUTATORS`.
      # The class-ivar pre-pass uses the resulting set to widen
      # the post-collected accumulator entries (see
      # {.widen_mutated_ivar_entries!}). Always-safe to over-
      # collect: any name that the widening primitive declines
      # is ignored at finalization.
      def record_ivar_mutator_call(node, class_name, mutated_ivars)
        receiver = node.receiver
        return unless receiver.is_a?(Prism::InstanceVariableReadNode)
        return unless MutationWidening::ARRAY_MUTATORS.include?(node.name) ||
                      MutationWidening::HASH_MUTATORS.include?(node.name)

        per_class = (mutated_ivars[class_name] ||= {})
        per_ivar = (per_class[receiver.name] ||= Set.new)
        per_ivar << node.name
      end

      # Walk an `IfNode` / `UnlessNode` so writes inside the THEN body
      # that look like defensive ivar initialisation gain a `nil` union
      # in the seeded type. Without this, `@x = v unless @x` records
      # `Constant[v]` for `@x`, then the predicate folds to that same
      # constant and `flow.always-truthy-condition` fires against a
      # working program. Mirrors the existing skip for `@x ||= v`
      # (`Prism::InstanceVariableOrWriteNode`, which the pre-pass does
      # not seed at all).
      #
      # Polarity-aware on purpose: only the THEN body picks up the
      # guard. The ELSE branch of `if @x; ...; else; @x = init; end`
      # would otherwise be marked too — but that pattern (write @x in
      # the else of `if @x`) is a separate idiom whose surrounding
      # reads of `@x` would then surface a nil-receiver FP. The
      # ELSE branch is left ungarded so those reads continue to type
      # as they did before this fix.
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

      # Returns the set of ivar names that, in the THEN body of this
      # conditional, are statically known to be in a nil / unset state
      # — i.e. the body really IS the defensive-init half of the
      # idiom. Conservative on purpose: only the shapes that
      # idiomatically express "the ivar is missing" qualify.
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

      # C2 — returns a Set of `object_id`s for transient `@x = nil`
      # writes that a later statement in the same method body
      # *definitely* overwrites with a non-nil value on every
      # completing path. Such a nil can never be the ivar's value at
      # method exit, so it must not contribute a `nil` constituent to
      # the (flow-insensitive) class-ivar union.
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
      # WD3 — ADR-41-style hard cap on how deep the same-class-call
      # definite-assignment crediting recurses (the ctor calls
      # `mask!`, which could itself call another same-class helper).
      # Cycle-guarded independently; the cap bounds even acyclic
      # chains.
      SAME_CLASS_CALL_DEPTH_CAP = 3
      private_constant :SAME_CLASS_CALL_DEPTH_CAP

      # WD3 — builds the per-class definite-assignment summary
      # `{class_name => {method_name => Set<ivar names assigned
      # non-nil on every completing path>}}`. Used so a ctor's
      # `dead_transient_nil_writes` can credit an indirect overwrite
      # through an unconditionally-called same-class method (ipaddr's
      # `initialize` reassigns `@mask_addr` via `mask!`).
      #
      # Each method's set is computed by the same suffix
      # definite-assignment analysis used for the ctor seed, run from
      # the method body's first statement for every ivar the method
      # writes anywhere. Same-class calls inside a method are credited
      # transitively (depth-capped, cycle-guarded) so the resulting
      # FLAT table is correct at depth 0 for the ctor lookup.
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

      # Collects `{class_name => {method_name => DefNode}}` for every
      # instance-method def in the program. Singleton defs (`def
      # self.x`) are excluded — the ctor-call crediting only follows
      # instance-method calls on `self`. Last def wins on redefinition.
      def collect_class_method_defs(root, prefix = [], acc = {})
        return acc unless root.is_a?(Prism::Node)

        case root
        when Prism::ClassNode, Prism::ModuleNode
          name = qualified_name_for(root.constant_path)
          if name && root.body
            child = prefix + [name]
            collect_class_method_defs(root.body, child, acc)
          end
          return acc
        when Prism::DefNode
          (acc[prefix.join("::")] ||= {})[root.name] = root unless prefix.empty? || root.receiver
          return acc
        end

        root.compact_child_nodes.each { |c| collect_class_method_defs(c, prefix, acc) }
        acc
      end

      # Computes the definite-assignment set for one method, memoised
      # per def node. The `memo` cycle-guards: a method re-entered
      # while its own summary is in progress contributes nothing
      # (sound under-approximation), so mutual recursion terminates.
      def method_definite_assigns(class_name, _method_name, def_node, defs, effects, memo, depth)
        return Set.new if def_node.body.nil?
        return memo[def_node] if memo.key?(def_node)
        return Set.new if depth >= SAME_CLASS_CALL_DEPTH_CAP

        memo[def_node] = Set.new # in-progress sentinel (cycle guard)
        statements = top_level_statements(def_node.body)
        candidates = ivar_write_targets(def_node.body)
        # A transient `@x = nil` opener whose own method reassigns it
        # later must still count `@x` as assigned for callers, so the
        # crediting is computed at the BUILD-time depth.
        resolver = MethodEffectResolver.new(self, class_name, defs, effects, memo, depth)
        assigns = Set.new
        candidates.each do |ivar|
          assigns << ivar if suffix_definitely_assigns_with_resolver?(statements, 0, ivar, class_name, resolver, depth)
        end
        memo[def_node] = assigns
      end

      # Every ivar this body assigns a non-nil value to ANYWHERE (the
      # candidate set for the method's definite-assignment scan).
      def ivar_write_targets(node, acc = Set.new)
        return acc unless node.is_a?(Prism::Node)

        acc << node.name if node.is_a?(Prism::InstanceVariableWriteNode) && !nil_literal_value?(node.value)
        node.compact_child_nodes.each { |c| ivar_write_targets(c, acc) }
        acc
      end

      # Build-time variant of `suffix_definitely_assigns?` that resolves
      # same-class calls through the lazy `resolver` (which recurses
      # into `method_definite_assigns` for not-yet-computed callees)
      # rather than the finished flat table.
      def suffix_definitely_assigns_with_resolver?(statements, from, target, class_name, resolver, depth)
        statements[from..].each do |stmt|
          outcome = statement_assignment_outcome(stmt, target, class_name, resolver, depth, nil)
          return true if outcome == :assigned
          return false if outcome == :terminates_unassigned
        end
        false
      end

      # Adapts `effects.dig(class, method)` for build-time crediting:
      # when the callee summary is not yet in the flat table, compute
      # it on demand (depth+1) via `method_definite_assigns`.
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

          # The opening `@x = nil` is dead when every completing path
          # of the SUFFIX after it (normal end OR early `return`,
          # never a `raise`-terminated path) definitely reassigns
          # `@x` non-nil. The suffix analysis credits an
          # unconditionally-called same-class method's own definite
          # assignments via `method_assign_effects`.
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

      # True when, starting from `statements[from]`, EVERY path that
      # completes the method (falls off the end OR hits an early
      # `return`) definitely assigns `target` a non-nil value first.
      # Paths terminated by `raise` are not completing paths and are
      # ignored (they never observe the ivar at method exit). A path
      # that can fall through `statements` without assigning fails.
      def suffix_definitely_assigns?(statements, from, target, class_name, effects)
        statements[from..].each do |stmt|
          outcome = statement_assignment_outcome(stmt, target, class_name, effects, 0, nil)
          # The statement assigned on every continuing path -> the
          # suffix is satisfied no matter what follows.
          return true if outcome == :assigned
          # The statement terminates control here (return/raise) and
          # the value it carried did not assign on every path -> some
          # completing path reached exit without the assignment.
          return false if outcome == :terminates_unassigned
          # Otherwise (:falls_through_unassigned) keep scanning the
          # remaining statements.
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
          # Any other statement — including a bare `raise`/`fail`,
          # which terminates without a completing path that observes
          # the seed nil — is neutral: control either continues or the
          # path never reaches method exit. Keep scanning the suffix.
          :falls_through_unassigned
        end
      end

      # True when a branch body (a StatementsNode / single node)
      # definitely assigns `target` non-nil on every path that
      # completes the method through it, OR terminates every path by
      # raise (vacuously safe — no completing path observes the seed
      # nil). Returns false if any path can complete/return without the
      # assignment.
      def branch_definitely_assigns?(branch, target, class_name, effects, depth, visiting)
        stmts = top_level_statements(branch)
        return false if stmts.empty?

        stmts.each do |stmt|
          outcome = statement_assignment_outcome(stmt, target, class_name, effects, depth, visiting)
          return true if outcome == :assigned
          return false if outcome == :terminates_unassigned
        end
        # Reached the end of the branch without a definite assignment;
        # safe only if the branch's last statement always raises (no
        # completing path falls out of it).
        always_raises?(stmts.last)
      end

      # `if`/`unless` is a definite assignment of `target` only when
      # BOTH the then and else arms definitely assign (or raise-out).
      # A missing else arm means the fall-through path skips the
      # assignment -> not definite. Modifier-form `if`/`unless` (no
      # else, single predicate'd statement) likewise.
      def conditional_assignment_outcome(node, target, class_name, effects, depth, visiting)
        else_branch = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
        return :falls_through_unassigned unless else_branch.is_a?(Prism::ElseNode)
        return :falls_through_unassigned unless node.statements

        then_ok = branch_definitely_assigns?(node.statements, target, class_name, effects, depth, visiting)
        else_ok = branch_definitely_assigns?(else_branch.statements, target, class_name, effects, depth, visiting)
        then_ok && else_ok ? :assigned : :falls_through_unassigned
      end

      # `case` is a definite assignment only when there is a real
      # `else` clause AND every `when`/`in` body plus the else body
      # definitely assigns (or raises-out). A missing else lets an
      # unmatched subject fall through unassigned.
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

      # True when `node` (a single statement or its last statement) is
      # an unconditional `raise`/`fail` call that always terminates the
      # path — used to treat raise-terminated branches as
      # non-completing (they never observe the seed nil).
      def always_raises?(node)
        node = top_level_statements(node).last if node.is_a?(Prism::StatementsNode)
        return false unless node.is_a?(Prism::CallNode)
        return false unless node.receiver.nil?

        %i[raise fail].include?(node.name)
      end

      # True when `call` is an unconditional, statement-level,
      # implicit-self (or `self.`) call to a SAME-CLASS method whose
      # definite-assignment summary includes `target`. Calls through a
      # block, on another receiver, or to an unresolved name contribute
      # nothing (the seed nil stays).
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

        # `@x = nil unless @x` / `@y = false unless @y` —
        # follow-up to the polarity-aware defensive-init guard
        # fix (ROADMAP § Future cycles — "Defensive ivar-init
        # with nil / false rvalue"). When the rvalue is itself a
        # falsey Constant, `union(rvalue, Constant[nil])`
        # collapses (for `nil`) or doesn't widen the type's
        # truthiness profile (for `false`) — the predicate
        # `unless @x` then folds to a single `Constant[nil]` /
        # `Constant[false]` and the
        # `flow.always-truthy-condition` / `-always-falsey-`
        # rule false-fires on the no-op-but-documented-default
        # idiom. Skip the seed contribution for this write
        # (matches the existing skip for `@x ||= v`, which the
        # pre-pass also does not seed). Other writes to the
        # same ivar still contribute; the falsey-default write
        # carries no useful precision the predicate hasn't
        # already given us. See tdiary-core HEAD `ee40c2b`
        # `lib/tdiary/configuration.rb:157` for the worked site.
        return if guarded && falsey_constant?(rvalue_type)

        rvalue_type = Type::Combinator.union(rvalue_type, Type::Combinator.constant_of(nil)) if guarded
        accumulate_ivar_type(accumulator, class_name, node.name, rvalue_type)
      end

      # Unions `type` into the class-ivar accumulator for `(class_name,
      # ivar_name)`. Shared by the single-write and multi-write
      # (parallel-assignment) collectors.
      def accumulate_ivar_type(accumulator, class_name, ivar_name, type)
        accumulator[class_name] ||= {}
        existing = accumulator[class_name][ivar_name]
        accumulator[class_name][ivar_name] =
          existing ? Type::Combinator.union(existing, type) : type
      end

      # N1 — records each `InstanceVariableTargetNode` of a
      # `MultiWriteNode` (parallel / multiple assignment) into the
      # class-ivar union, with the best cheap per-slot type. When the RHS
      # is array/tuple-shaped (`Type::Tuple`) the ivar at position `i`
      # records the type of element `i`; otherwise — an unanalyzable RHS
      # such as `Open3.popen3(cmd)` typing to `Dynamic[top]` — every ivar
      # slot records that unanalyzable floor (NOT `nil`: a multi-write we
      # cannot decompose means the value is *unknown*, and `Dynamic[top]`
      # is the sound union constituent, mirroring what a single write to
      # an unknown RHS records). Nested targets (`(@a, @b), @c = …`)
      # recurse with the slot's type as the new RHS type.
      def record_multi_write_ivars(node, scope, class_name, accumulator)
        return unless node.is_a?(Prism::MultiWriteNode)

        rhs_type = scope.type_of(node.value)
        record_multi_target_ivars(node, rhs_type, class_name, accumulator)
      end

      # Walks a `MultiWriteNode` / `MultiTargetNode` target tree against
      # `rhs_type`, recording ivar targets per slot. Mirrors
      # `MultiTargetBinder`'s tuple decomposition but for ivar (rather
      # than local-variable) targets.
      def record_multi_target_ivars(node, rhs_type, class_name, accumulator)
        lefts = node.lefts || []
        rest = node.rest
        rights = node.rights || []
        fronts, rest_type, backs =
          decompose_multi_write_rhs(rhs_type, lefts.size, rights.size, rest_present: !rest.nil?)

        lefts.each_with_index { |t, i| record_multi_ivar_target(t, fronts[i], class_name, accumulator) }
        record_multi_ivar_rest(rest, rest_type, class_name, accumulator) if rest
        rights.each_with_index { |t, i| record_multi_ivar_target(t, backs[i], class_name, accumulator) }
      end

      def decompose_multi_write_rhs(rhs_type, front_count, back_count, rest_present:)
        if rhs_type.is_a?(Type::Tuple)
          elements = rhs_type.elements
          fronts = Array.new(front_count) { |i| multi_write_slot_type(elements, i) }
          if rest_present
            middle_end = [elements.size - back_count, front_count].max
            backs = Array.new(back_count) { |i| multi_write_slot_type(elements, middle_end + i) }
            [fronts, Type::Combinator.untyped, backs]
          else
            backs = Array.new(back_count) { |i| multi_write_slot_type(elements, front_count + i) }
            [fronts, nil, backs]
          end
        else
          # Unanalyzable / non-tuple RHS: every slot is the unknown floor.
          floor = Type::Combinator.untyped
          [Array.new(front_count) { floor }, rest_present ? floor : nil, Array.new(back_count) { floor }]
        end
      end

      # The per-slot type for index `i` of a tuple RHS. A missing slot
      # (over-destructure) is `nil` at runtime; a present slot keeps its
      # type. Unlike the local-variable binder we do NOT soften an
      # optional slot here — a class-ivar seed deliberately preserves a
      # genuine `T | nil`, and any spurious nil is removed by the
      # flow-side narrowing, not by dropping it at collection time.
      def multi_write_slot_type(elements, index)
        element = elements[index]
        return Type::Combinator.constant_of(nil) if element.nil?

        element
      end

      def record_multi_ivar_target(target, type, class_name, accumulator)
        case target
        when Prism::InstanceVariableTargetNode
          accumulate_ivar_type(accumulator, class_name, target.name, type)
        when Prism::MultiTargetNode
          record_multi_target_ivars(target, type, class_name, accumulator)
        end
      end

      def record_multi_ivar_rest(splat_node, _type, class_name, accumulator)
        return unless splat_node.is_a?(Prism::SplatNode)

        expression = splat_node.expression
        return unless expression.is_a?(Prism::InstanceVariableTargetNode)

        # A splat collects the middle slots into an Array; the precise
        # element type is not worth recovering here. Record the
        # unanalyzable floor (an Array of unknown), never nil.
        accumulate_ivar_type(accumulator, class_name, expression.name, Type::Combinator.untyped)
      end

      def falsey_constant?(type)
        type.is_a?(Type::Constant) && (type.value.nil? || type.value == false)
      end

      # Slice 7 phase 6 — class-cvar pre-pass. Same shape as the
      # ivar pre-pass but collects `Prism::ClassVariableWriteNode`
      # writes inside ANY def body (instance or singleton) of the
      # enclosing class, because Ruby cvars are shared across both
      # facets. The resulting table is seeded into both instance
      # and singleton method bodies through
      # `Scope#class_cvars_for`.
      def build_class_cvar_index(root, default_scope)
        accumulator = {}
        walk_class_cvars(root, [], default_scope, accumulator)
        accumulator.transform_values(&:freeze).freeze
      end

      def walk_class_cvars(node, qualified_prefix, default_scope, accumulator)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = qualified_name_for(node.constant_path)
          if name
            child_prefix = qualified_prefix + [name]
            walk_class_cvars(node.body, child_prefix, default_scope, accumulator) if node.body
            return
          end
        when Prism::DefNode
          collect_def_cvar_writes(node, qualified_prefix, default_scope, accumulator)
          return
        end

        node.compact_child_nodes.each do |child|
          walk_class_cvars(child, qualified_prefix, default_scope, accumulator)
        end
      end

      def collect_def_cvar_writes(def_node, qualified_prefix, default_scope, accumulator)
        return if def_node.body.nil? || qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        body_scope = default_scope.with_self_type(Type::Combinator.nominal_of(class_name))
        gather_cvar_writes(def_node.body, body_scope, class_name, accumulator)
      end

      def gather_cvar_writes(node, scope, class_name, accumulator)
        return unless node.is_a?(Prism::Node)

        record_cvar_write(node, scope, class_name, accumulator) if node.is_a?(Prism::ClassVariableWriteNode)
        return if IVAR_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

        node.compact_child_nodes.each { |c| gather_cvar_writes(c, scope, class_name, accumulator) }
      end

      def record_cvar_write(node, scope, class_name, accumulator)
        rvalue_type = scope.type_of(node.value)
        accumulator[class_name] ||= {}
        existing = accumulator[class_name][node.name]
        accumulator[class_name][node.name] =
          existing ? Type::Combinator.union(existing, rvalue_type) : rvalue_type
      end

      # Slice 7 phase 6 — program-global pre-pass. Globals are
      # process-wide so the accumulator is a flat
      # `Hash[Symbol, Type::t]` populated from every
      # `Prism::GlobalVariableWriteNode` in the program (top-level
      # AND inside method bodies). The same accumulator is
      # seeded into every method body and the top-level scope.
      def build_program_global_index(root, default_scope)
        accumulator = {}
        gather_global_writes(root, default_scope, accumulator)
        accumulator.freeze
      end

      def gather_global_writes(node, scope, accumulator)
        return unless node.is_a?(Prism::Node)

        record_global_write(node, scope, accumulator) if node.is_a?(Prism::GlobalVariableWriteNode)
        node.compact_child_nodes.each { |c| gather_global_writes(c, scope, accumulator) }
      end

      def record_global_write(node, scope, accumulator)
        rvalue_type = scope.type_of(node.value)
        existing = accumulator[node.name]
        accumulator[node.name] =
          existing ? Type::Combinator.union(existing, rvalue_type) : rvalue_type
      end

      # Slice 7 phase 9 — in-source constant value pre-pass.
      # Walks the entire program (top-level AND inside class /
      # module / def bodies) for `Prism::ConstantWriteNode` and
      # `Prism::ConstantPathWriteNode`, types each rvalue, and
      # accumulates by qualified name. Constants defined inside
      # a class body are qualified with the surrounding class
      # path; constants written via a path (`Foo::BAR = ...`)
      # use the rendered path as-is.
      def build_in_source_constants(root, default_scope)
        accumulator = {}
        walk_constant_writes(root, [], default_scope, accumulator)
        accumulator.freeze
      end

      def walk_constant_writes(node, qualified_prefix, default_scope, accumulator)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = qualified_name_for(node.constant_path)
          if name
            child_prefix = qualified_prefix + [name]
            walk_constant_writes(node.body, child_prefix, default_scope, accumulator) if node.body
            return
          end
        when Prism::ConstantWriteNode
          record_constant_write(node, qualified_prefix, default_scope, accumulator, node.name.to_s)
          return
        when Prism::ConstantPathWriteNode
          full = qualified_name_for(node.target)
          record_constant_write(node, [], default_scope, accumulator, full) if full
          return
        end

        node.compact_child_nodes.each do |child|
          walk_constant_writes(child, qualified_prefix, default_scope, accumulator)
        end
      end

      def record_constant_write(node, qualified_prefix, default_scope, accumulator, base_name)
        full = qualified_prefix.empty? ? base_name : "#{qualified_prefix.join('::')}::#{base_name}"
        body_scope = default_scope
        unless qualified_prefix.empty?
          body_scope = body_scope.with_self_type(Type::Combinator.singleton_of(qualified_prefix.join("::")))
        end
        rvalue_type = meta_new_constant_type(node, full) || body_scope.type_of(node.value)
        existing = accumulator[full]
        accumulator[full] = existing ? Type::Combinator.union(existing, rvalue_type) : rvalue_type
      end

      # Survey item (e): when the rvalue is a recognised
      # `Module.new do ... end` / `Class.new do ... end` /
      # `Struct.new(*sym) do ... end` / `Data.define(*sym) do
      # ... end` form, type the named constant as
      # `Singleton[<full>]` so the discovered-method table
      # registered under `full` becomes reachable through
      # singleton-side dispatch (`Const.[]=` etc.). Returns nil
      # for non-meta-new rvalues so the caller falls back to the
      # default `body_scope.type_of(node.value)` shape.
      def meta_new_constant_type(node, full)
        return nil unless meta_new_block_body(node)

        Type::Combinator.singleton_of(full)
      end

      # Slice 7 phase 12 — in-source method discovery pre-pass.
      # Walks every class/module body and records the methods
      # introduced via `Prism::DefNode` (instance + singleton)
      # and via recognised `define_method(:name) { ... }` calls.
      # The returned table maps qualified class name to a
      # `Hash[Symbol, :instance | :singleton]`.
      def build_discovered_methods(root)
        accumulator = {}
        walk_methods(root, [], false, accumulator)
        accumulator.transform_values(&:freeze).freeze
      end

      # Merges two `class_name => { method => kind }` tables, unioning
      # the per-class method maps (so a seeded cross-file table and the
      # current file's table combine instead of clobbering).
      def deep_merge_class_methods(base, overlay)
        return overlay if base.nil? || base.empty?
        return base if overlay.empty?

        base.merge(overlay) do |_class_name, base_methods, overlay_methods|
          base_methods.merge(overlay_methods)
        end
      end

      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/AbcSize, Metrics/PerceivedComplexity
      def walk_methods(node, qualified_prefix, in_singleton_class, accumulator)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = qualified_name_for(node.constant_path)
          if name
            child_prefix = qualified_prefix + [name]
            record_meta_superclass_members(node, child_prefix, accumulator) if node.is_a?(Prism::ClassNode)
            walk_methods(node.body, child_prefix, false, accumulator) if node.body
            return
          end
        when Prism::SingletonClassNode
          if node.body
            singleton_prefix = singleton_class_prefix(node, qualified_prefix)
            if singleton_prefix
              walk_methods(node.body, singleton_prefix, true, accumulator)
              return
            end
          end
        when Prism::ConstantWriteNode
          if meta_new_block_body(node)
            child_prefix = qualified_prefix + [node.name.to_s]
            walk_methods(meta_new_block_body(node), child_prefix, false, accumulator)
            return
          end
        when Prism::DefNode
          record_def_method(node, qualified_prefix, in_singleton_class, accumulator)
          return
        when Prism::AliasMethodNode
          record_alias_method(node, qualified_prefix, in_singleton_class, accumulator)
          return
        when Prism::CallNode
          record_define_method(node, qualified_prefix, in_singleton_class, accumulator) if node.name == :define_method
          if ATTR_MACROS.include?(node.name)
            record_attr_methods(node, qualified_prefix, in_singleton_class,
                                accumulator)
          end
        end

        node.compact_child_nodes.each do |child|
          walk_methods(child, qualified_prefix, in_singleton_class, accumulator)
        end
      end

      # Resolves a `class << X` body's qualified prefix.
      #   - `class << self` keeps `qualified_prefix` (the enclosing class).
      #   - `class << Foo` inside `class Foo` collapses to the same prefix
      #     (semantically `class << self`).
      #   - `class << Foo` not nested in `class Foo` returns `[Foo]`
      #     so methods defined inside register on Foo's singleton.
      #   - Any other expression (variable, method call) returns nil
      #     so the walker falls through and skips the body.
      def singleton_class_prefix(node, qualified_prefix)
        case node.expression
        when Prism::SelfNode
          qualified_prefix
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          rendered = qualified_name_for(node.expression)
          return nil unless rendered

          if !qualified_prefix.empty? && qualified_prefix.last == rendered
            qualified_prefix
          else
            rendered.split("::")
          end
        end
      end
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/AbcSize, Metrics/PerceivedComplexity

      # v0.1.2 — when a `Const = Data.define(*sym) do ... end`
      # / `Const = Struct.new(*sym) do ... end` constant write
      # carries a block, the block body holds method overrides
      # whose canonical class is `Const`. Survey item (e) extended
      # the recognition to `Const = Module.new do ... end` and
      # `Const = Class.new(?super) do ... end` — the
      # ADR-16 Tier A "block-as-method" idiom at constant-write
      # position. Returns the block body node (a
      # `Prism::StatementsNode`) when the rvalue matches; nil
      # otherwise. Used by `walk_methods` / `walk_def_nodes` to
      # push `Const` onto the qualified prefix before recursing.
      def meta_new_block_body(node)
        return nil unless node.is_a?(Prism::ConstantWriteNode)

        rvalue = node.value
        return nil unless data_define_call?(rvalue) ||
                          struct_new_call?(rvalue) ||
                          module_new_call?(rvalue) ||
                          class_new_call?(rvalue)

        rvalue.block&.body
      end

      # `class Foo < Data.define(:a, :b)` / `class Bar < Struct.new(:x)`
      # synthesizes reader methods (`a`, `b`, `x`) on the subclass that no
      # `def` / `attr_*` declares. Register them in the discovered-methods
      # existence table so an implicit-self read of a member inside the
      # class body is known to exist — both for the existing
      # undefined-method suppression and for the ADR-24 slice-4 self-call
      # recorder, which must treat a synthesized member as an existing
      # method, not an unresolved call. The block-form
      # (`Const = Data.define(:a) do ... end`) is handled by the
      # `ConstantWriteNode` branch's block recursion; its members type
      # `self` as `Object`, out of scope here.
      def record_meta_superclass_members(class_node, qualified_prefix, accumulator)
        superclass = class_node.superclass
        return unless data_define_call?(superclass) || struct_new_call?(superclass)

        members = meta_member_names(superclass)
        return if members.empty?

        class_name = qualified_prefix.join("::")
        table = (accumulator[class_name] ||= {})
        members.each { |member| table[member] ||= :instance }
      end

      # The Symbol member names of a `Data.define(*Symbol)` /
      # `Struct.new(*Symbol [, keyword_init:])` call. For `Struct.new` the
      # optional leading String name and trailing `keyword_init:` hash are
      # stripped by {#struct_new_positionals}; `Data.define` args are all
      # Symbols already.
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
        accumulator[class_name] ||= {}
        accumulator[class_name][def_node.name] = kind
      end

      # `def Foo.bar` inside `module Foo` (or `def Meta.init` inside
      # `module Meta`) is semantically equivalent to `def self.bar`:
      # at the def-site, the runtime value of the constant `Foo` is
      # the module itself (== `self`). Recognise the form so the
      # method registers as singleton on the enclosing class.
      #
      # The cross-class form `def Bar.baz` inside `module Foo` —
      # where the receiver names a constant other than the
      # enclosing class — is not supported at this slice; falls
      # through to `:instance` (current behaviour) rather than
      # silently re-routing the registration.
      def def_singleton?(def_node, qualified_prefix, in_singleton_class)
        return true if def_node.receiver.is_a?(Prism::SelfNode) || in_singleton_class

        def_receiver_targets_lexical_self?(def_node.receiver, qualified_prefix)
      end

      # Only `Prism::ConstantReadNode` is observed in real Ruby —
      # Prism mis-parses `def C::P.method` as `def C.P` (Ruby itself
      # rejects the form as a SyntaxError). The ConstantPathNode
      # branch stays defensive in case Prism's grammar widens.
      def def_receiver_targets_lexical_self?(receiver, qualified_prefix)
        return false if qualified_prefix.empty?

        case receiver
        when Prism::ConstantReadNode
          receiver.name.to_s == qualified_prefix.last
        when Prism::ConstantPathNode
          rendered = render_constant_path(receiver)
          return false unless rendered

          path = rendered.split("::")
          qualified_prefix.last(path.length) == path
        else
          false
        end
      end

      # v0.0.2 #5 — instance-side def-node recording. Walks
      # class bodies the same way as `build_discovered_methods`
      # but records the actual `Prism::DefNode` for each
      # **instance** method so `ExpressionTyper` can re-type
      # the body at the call site for inter-procedural return
      # inference. Singleton methods and `define_method` calls
      # are intentionally skipped: the inference path needs a
      # statically introspectable body, and singleton dispatch
      # has its own complications (Class / Module ancestry)
      # the first-iteration rule does not yet model.
      def build_discovered_def_nodes(root)
        accumulator = {}
        walk_def_nodes(root, [], false, accumulator)
        apply_alias_def_nodes(root, accumulator)
        accumulator.transform_values(&:freeze).freeze
      end

      def walk_def_nodes(node, qualified_prefix, in_singleton_class, accumulator)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = qualified_name_for(node.constant_path)
          if name
            child_prefix = qualified_prefix + [name]
            walk_def_nodes(node.body, child_prefix, false, accumulator) if node.body
            return
          end
        when Prism::SingletonClassNode
          if node.body
            singleton_prefix = singleton_class_prefix(node, qualified_prefix)
            if singleton_prefix
              walk_def_nodes(node.body, singleton_prefix, true, accumulator)
              return
            end
          end
        when Prism::ConstantWriteNode
          if meta_new_block_body(node)
            child_prefix = qualified_prefix + [node.name.to_s]
            walk_def_nodes(meta_new_block_body(node), child_prefix, false, accumulator)
            return
          end
        when Prism::DefNode
          record_def_node(node, qualified_prefix, in_singleton_class, accumulator)
          return
        end

        node.compact_child_nodes.each do |child|
          walk_def_nodes(child, qualified_prefix, in_singleton_class, accumulator)
        end
      end
      # v0.0.3 A — sentinel key under which `record_def_node`
      # files DefNodes that live outside any class / module
      # body (top-level helpers, `def`s nested inside DSL
      # blocks like `RSpec.describe ... do; def helper; end`).
      # Looked up by `Scope#top_level_def_for` to give
      # implicit-self calls priority over RBS dispatch when
      # the file defines a same-named local method.
      TOP_LEVEL_DEF_KEY = "<toplevel>"

      def record_def_node(def_node, qualified_prefix, in_singleton_class, accumulator)
        return if def_singleton?(def_node, qualified_prefix, in_singleton_class)

        class_name = qualified_prefix.empty? ? TOP_LEVEL_DEF_KEY : qualified_prefix.join("::")
        accumulator[class_name] ||= {}
        accumulator[class_name][def_node.name] = def_node
      end

      # Module-singleton call resolution (ADR-57 follow-up) — the
      # SINGLETON-side mirror of `build_discovered_def_nodes`. Records the
      # `Prism::DefNode` for every singleton-side method (`def self.x`,
      # `def Foo.x`, a `class << self` body, and a `module_function`
      # method) keyed by qualified class/module name → method → node, so
      # `ExpressionTyper` can re-type the body when a `Singleton[Foo]`
      # receiver dispatches `Foo.x`. The instance-side table is kept
      # singleton-free on purpose (its ancestor walk binds `self` as
      # `Nominal`), so the two never overlap except for `module_function`
      # defs, which are genuinely callable on both sides and so appear in
      # both tables. Top-level singleton defs (`def self.x` outside any
      # class — `self` is `main`) are not recorded; they have no constant
      # receiver to dispatch through.
      def build_discovered_singleton_def_nodes(root)
        accumulator = {}
        walk_singleton_def_nodes(root, [], false, accumulator)
        accumulator.transform_values(&:freeze).freeze
      end

      # Walks every node, entering class/module/singleton-class bodies via
      # {#walk_singleton_body} so a bare `module_function` toggle threads
      # correctly across the body's *sibling* statements (a child-by-child
      # recursion would reset it). At the top level / inside an arbitrary
      # node there is no `module_function` state to carry, so descent is a
      # plain per-child walk.
      def walk_singleton_def_nodes(node, qualified_prefix, in_singleton_class, accumulator)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = qualified_name_for(node.constant_path)
          if name
            walk_singleton_body(node.body, qualified_prefix + [name], false, accumulator) if node.body
            return
          end
        when Prism::SingletonClassNode
          if node.body
            singleton_prefix = singleton_class_prefix(node, qualified_prefix)
            if singleton_prefix
              walk_singleton_body(node.body, singleton_prefix, true, accumulator)
              return
            end
          end
        when Prism::ConstantWriteNode
          if meta_new_block_body(node)
            child_prefix = qualified_prefix + [node.name.to_s]
            walk_singleton_body(meta_new_block_body(node), child_prefix, false, accumulator)
            return
          end
        when Prism::DefNode
          record_singleton_def_node(node, qualified_prefix, in_singleton_class, false, accumulator)
          return
        end

        node.compact_child_nodes.each do |child|
          walk_singleton_def_nodes(child, qualified_prefix, in_singleton_class, accumulator)
        end
      end

      # Walks a class/module/singleton-class body's direct statements in
      # source order, threading the bare-`module_function` toggle: once a
      # bare `module_function` is seen, every subsequent `def` in the body
      # registers as a singleton method. Nested classes/modules/defs and
      # `module_function :a, :b` named forms recurse / record through the
      # general walker so the toggle stays scoped to its own body.
      def walk_singleton_body(body, qualified_prefix, in_singleton_class, accumulator)
        module_function_on = false
        statements_of(body).each do |stmt|
          if stmt.is_a?(Prism::CallNode) && module_function_toggle?(stmt)
            if bare_module_function?(stmt)
              module_function_on = true
            else
              record_module_function_names(stmt, qualified_prefix, body, accumulator)
            end
            next
          end
          if stmt.is_a?(Prism::DefNode)
            record_singleton_def_node(stmt, qualified_prefix, in_singleton_class, module_function_on, accumulator)
            next
          end
          walk_singleton_def_nodes(stmt, qualified_prefix, in_singleton_class, accumulator)
        end
      end

      # Direct statement children of a class/module body node (a
      # `Prism::StatementsNode`, a `Prism::BeginNode` wrapping one, or a
      # lone statement). Returns an empty list for an empty body.
      def statements_of(body)
        case body
        when Prism::StatementsNode then body.body
        when Prism::BeginNode then statements_of(body.statements)
        when nil then []
        else [body]
        end
      end

      def record_singleton_def_node(def_node, qualified_prefix, in_singleton_class, module_function_on, accumulator)
        singleton = def_singleton?(def_node, qualified_prefix, in_singleton_class) || module_function_on
        return unless singleton
        return if qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        (accumulator[class_name] ||= {})[def_node.name] = def_node
      end

      # A bare `module_function` (no arguments) flips every following `def`
      # in the module body to module-function (instance + singleton) mode.
      def module_function_toggle?(node)
        node.name == :module_function && node.receiver.nil?
      end

      def bare_module_function?(node)
        node.arguments.nil? || node.arguments.arguments.empty?
      end

      # `module_function :a, :b` retro-marks named siblings (defined
      # earlier OR later in the same body) as module-functions. Resolves
      # each symbol-literal argument against the body's own `def`s and
      # registers the matching `DefNode` on the module's singleton side.
      # Non-symbol arguments and names with no matching `def` are skipped
      # (a miss degrades to today's `Dynamic`, never a false resolution).
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

      # ADR-24 slice 2 — per-class table mapping a fully
      # qualified user class to its superclass name AS WRITTEN
      # at the `class Foo < Bar` declaration. Only constant
      # superclasses are recorded (`class Foo < Struct.new(...)`
      # and other non-constant superclasses produce no entry).
      # The as-written name is resolved to a qualified class at
      # the call site against the subclass's lexical nesting —
      # see `ExpressionTyper#resolve_ancestor_class_name`.
      def build_discovered_superclasses(root)
        accumulator = {}
        walk_class_superclasses(root, [], accumulator)
        accumulator.freeze
      end

      def walk_class_superclasses(node, qualified_prefix, accumulator)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode
          name = qualified_name_for(node.constant_path)
          if name
            full = (qualified_prefix + [name]).join("::")
            superclass = node.superclass && qualified_name_for(node.superclass)
            accumulator[full] = superclass if superclass
            walk_class_superclasses(node.body, qualified_prefix + [name], accumulator) if node.body
            return
          end
        when Prism::ModuleNode
          name = qualified_name_for(node.constant_path)
          if name
            walk_class_superclasses(node.body, qualified_prefix + [name], accumulator) if node.body
            return
          end
        end

        node.compact_child_nodes.each do |child|
          walk_class_superclasses(child, qualified_prefix, accumulator)
        end
      end

      # ADR-48 — per qualified class name -> ordered `Data.define`
      # member-name list, for both the named-subclass form
      # (`class Point < Data.define(:x, :y)`) and the constant-assigned
      # form (`Point = Data.define(:x, :y)`). Only `Data.define` is
      # recorded: `Struct.new` instances are mutable, so member-value
      # folding would be unsound (the Struct follow-up is deferred — see
      # ADR-48 § "Struct follow-up"). Consumed by
      # {Inference::MethodDispatcher::DataFolding} via
      # {Scope#data_member_layout}.
      def build_data_member_layouts(root)
        accumulator = {}
        walk_data_member_layouts(root, [], accumulator)
        accumulator.freeze
      end

      def walk_data_member_layouts(node, qualified_prefix, accumulator)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode
          name = qualified_name_for(node.constant_path)
          if name
            record_data_member_layout(accumulator, qualified_prefix + [name], node.superclass)
            walk_data_member_layouts(node.body, qualified_prefix + [name], accumulator) if node.body
            return
          end
        when Prism::ModuleNode
          name = qualified_name_for(node.constant_path)
          if name
            walk_data_member_layouts(node.body, qualified_prefix + [name], accumulator) if node.body
            return
          end
        when Prism::ConstantWriteNode
          record_data_member_layout(accumulator, qualified_prefix + [node.name.to_s], node.value)
        end

        node.compact_child_nodes.each do |child|
          walk_data_member_layouts(child, qualified_prefix, accumulator)
        end
      end

      # Records `qualified -> [members]` when `expr` is a
      # `Data.define(*Symbol)` call with at least one literal-Symbol member.
      def record_data_member_layout(accumulator, qualified_parts, expr)
        return unless data_define_call?(expr)

        members = meta_member_names(expr)
        return if members.empty?

        accumulator[qualified_parts.join("::")] = members.freeze
      end

      # ADR-48 Struct follow-up — the `Struct.new(...)` sibling of
      # {#build_data_member_layouts}. A separate, additive table so the
      # existing `Data.define` value-shape contract (a bare `[Symbol]`) is
      # untouched: a Struct entry carries `{ members:, keyword_init: }`
      # because the dispatcher needs the flag to fold the matching `.new`
      # call form (positional vs keyword) without manufacturing a wrong map.
      def build_struct_member_layouts(root)
        accumulator = {}
        walk_struct_member_layouts(root, [], accumulator)
        accumulator.freeze
      end

      def walk_struct_member_layouts(node, qualified_prefix, accumulator)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode
          name = qualified_name_for(node.constant_path)
          if name
            record_struct_member_layout(accumulator, qualified_prefix + [name], node.superclass)
            walk_struct_member_layouts(node.body, qualified_prefix + [name], accumulator) if node.body
            return
          end
        when Prism::ModuleNode
          name = qualified_name_for(node.constant_path)
          if name
            walk_struct_member_layouts(node.body, qualified_prefix + [name], accumulator) if node.body
            return
          end
        when Prism::ConstantWriteNode
          record_struct_member_layout(accumulator, qualified_prefix + [node.name.to_s], node.value)
        end

        node.compact_child_nodes.each do |child|
          walk_struct_member_layouts(child, qualified_prefix, accumulator)
        end
      end

      # Records `qualified -> { members:, keyword_init: }` when `expr` is a
      # `Struct.new(*Symbol [, keyword_init: <bool>])` call with at least one
      # literal-Symbol member.
      def record_struct_member_layout(accumulator, qualified_parts, expr)
        return unless struct_new_call?(expr)

        members = meta_member_names(expr)
        return if members.empty?

        accumulator[qualified_parts.join("::")] = {
          members: members.freeze,
          keyword_init: struct_new_keyword_init?(expr)
        }.freeze
      end

      # True when a `Struct.new` call carries `keyword_init: true` as a
      # literal in its trailing keyword hash. A non-literal value (or its
      # absence) reads as `false` — the conservative positional default.
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

      # ADR-24 slice 2 — per-class/module table mapping a fully
      # qualified user class or module to the list of module
      # names it `include`s / `prepend`s, AS WRITTEN at the
      # mixin call (`include Foo` / `include Foo::Bar`). Only
      # constant arguments are recorded; dynamic mixins
      # (`include some_method`) produce no entry. `prepend` is
      # bucketed with `include` — both contribute instance
      # methods to the ancestor chain. `extend` is NOT tracked
      # (it adds singleton methods; ADR-24 slice 2 resolves the
      # instance-side chain).
      def build_discovered_includes(root)
        accumulator = {}
        walk_class_includes(root, [], nil, accumulator)
        accumulator.transform_values { |mods| mods.uniq.freeze }.freeze
      end

      def walk_class_includes(node, qualified_prefix, current_class, accumulator)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = qualified_name_for(node.constant_path)
          if name
            full = (qualified_prefix + [name]).join("::")
            walk_class_includes(node.body, qualified_prefix + [name], full, accumulator) if node.body
            return
          end
        when Prism::CallNode
          record_mixin_call(node, current_class, accumulator)
        end

        node.compact_child_nodes.each do |child|
          walk_class_includes(child, qualified_prefix, current_class, accumulator)
        end
      end

      def record_mixin_call(node, current_class, accumulator)
        return unless current_class && node.receiver.nil?
        return unless MIXIN_CALL_NAMES.include?(node.name)

        node.arguments&.arguments&.each do |arg|
          mod = qualified_name_for(arg)
          (accumulator[current_class] ||= []) << mod if mod
        end
      end

      VISIBILITY_MODIFIERS = %i[public private protected].freeze

      # v0.1.2 — per-class method-visibility table for the
      # `def.method-visibility-mismatch` CheckRule.
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
      # Top-level (no surrounding class) defs do not contribute
      # — Ruby's top-level visibility nuances (private at
      # top-level marks the method on `Object`) are out of
      # scope for v0.1.2.
      def build_discovered_method_visibilities(root)
        accumulator = {}
        walk_method_visibilities(root, [], false, :public, accumulator)
        accumulator.transform_values(&:freeze).freeze
      end

      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Metrics/AbcSize
      def walk_method_visibilities(node, qualified_prefix, in_singleton_class, current_visibility, accumulator)
        return current_visibility unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = qualified_name_for(node.constant_path)
          if name
            child_prefix = qualified_prefix + [name]
            walk_method_visibilities(node.body, child_prefix, false, :public, accumulator) if node.body
            return current_visibility
          end
        when Prism::SingletonClassNode
          if node.body
            singleton_prefix = singleton_class_prefix(node, qualified_prefix)
            if singleton_prefix
              walk_method_visibilities(node.body, singleton_prefix, true, :public, accumulator)
              return current_visibility
            end
          end
        when Prism::ConstantWriteNode
          if meta_new_block_body(node)
            child_prefix = qualified_prefix + [node.name.to_s]
            walk_method_visibilities(meta_new_block_body(node), child_prefix, false, :public, accumulator)
            return current_visibility
          end
        when Prism::DefNode
          record_def_visibility(node, qualified_prefix, in_singleton_class, current_visibility, accumulator)
          return current_visibility
        when Prism::CallNode
          updated = apply_visibility_call(node, qualified_prefix, current_visibility, accumulator)
          return updated unless updated.equal?(current_visibility)
        end

        # Statement-position StatementsNode preserves
        # left-to-right visibility flow; everything else
        # recurses with the entry visibility unchanged.
        if node.is_a?(Prism::StatementsNode)
          local_visibility = current_visibility
          node.compact_child_nodes.each do |child|
            local_visibility = walk_method_visibilities(child, qualified_prefix, in_singleton_class,
                                                        local_visibility, accumulator)
          end
        else
          node.compact_child_nodes.each do |child|
            walk_method_visibilities(child, qualified_prefix, in_singleton_class, current_visibility, accumulator)
          end
        end
        current_visibility
      end
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Metrics/AbcSize

      def record_def_visibility(def_node, qualified_prefix, in_singleton_class, current_visibility, accumulator)
        return if def_node.receiver.is_a?(Prism::SelfNode) || in_singleton_class
        return if qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        accumulator[class_name] ||= {}
        accumulator[class_name][def_node.name] = current_visibility
      end

      # Recognises modifier calls on the implicit-self receiver
      # inside a class body. Returns the (possibly updated)
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

      # Registers the alias name in the `discovered_methods` table so
      # `undefined-method` diagnostics are not emitted for calls to the
      # aliased name. The kind mirrors the surrounding class context
      # (instance inside a regular class body, singleton inside
      # `class << self`).
      def record_alias_method(alias_node, qualified_prefix, in_singleton_class, accumulator)
        return if qualified_prefix.empty?
        return unless alias_node.new_name.is_a?(Prism::SymbolNode)

        class_name = qualified_prefix.join("::")
        new_name = alias_node.new_name.unescaped.to_sym
        kind = in_singleton_class ? :singleton : :instance
        (accumulator[class_name] ||= {})[new_name] = kind
      end

      # Post-pass over the `def_nodes` accumulator: for every `alias`
      # declaration inside a class body, if the original method name
      # maps to a `Prism::DefNode`, register the new name pointing to
      # the same node so inter-procedural return-type inference works
      # for the aliased name.
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

      # Builds a map `{class_name => {new_name_sym => old_name_sym}}` by
      # walking the tree for `AliasMethodNode` nodes inside class bodies.
      def collect_class_alias_map(node, qualified_prefix, accumulator)
        return accumulator unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = qualified_name_for(node.constant_path)
          if name
            collect_class_alias_map(node.body, qualified_prefix + [name], accumulator) if node.body
            return accumulator
          end
        when Prism::SingletonClassNode
          return accumulator
        when Prism::AliasMethodNode
          record_alias_map_entry(node, qualified_prefix, accumulator)
          return accumulator
        end

        node.compact_child_nodes.each { |child| collect_class_alias_map(child, qualified_prefix, accumulator) }
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
        accumulator[class_name] ||= {}
        accumulator[class_name][method_name] = in_singleton_class ? :singleton : :instance
      end

      # The `attr_*` accessor macros that introduce methods Rigor must
      # treat as source-declared. Without this, a class that defines an
      # accessor with `attr_reader :x` AND carries RBS that omits `x`
      # (a common gap — the project ships an incomplete `sig/`) fires a
      # false `call.undefined-method` on `obj.x`, because the
      # undefined-method rule only suppressed `def` / `define_method` /
      # `alias_method`-discovered methods. `attr_reader` defines
      # readers, `attr_writer` writers (`x=`), `attr_accessor` both.
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

          accumulator[class_name] ||= {}
          accumulator[class_name][base] = kind if reader
          accumulator[class_name][:"#{base}="] = kind if writer
        end
      end

      def literal_method_name(node)
        return nil unless node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)

        node.unescaped&.to_sym
      end

      # Walks every file in `paths` (each path is parsed once with
      # `Prism.parse_file`) and returns the unioned project-wide
      # `discovered_classes` Hash: `{qualified_name => Singleton[…]}`.
      # Used by `Analysis::Runner` to seed each file's
      # `default_scope.discovered_classes` so that lexical
      # constant lookup in one file resolves a `class Foo`
      # declared in a sibling file. Per-file collisions are
      # last-write-wins (matches the existing in-file merge
      # semantics). Parse failures fail-soft to an empty
      # contribution. The `buffer` argument, when present,
      # redirects reads for the bound logical path to the
      # buffer's physical path so editor-mode pre-passes see
      # the in-flight bytes.
      #
      # **Modules are intentionally excluded** from the
      # project-wide seed: a `module M; module_function; def x; end; end`
      # body, when surfaced as `singleton(M)` to the dispatcher,
      # falls through to `Kernel#x` (or any Module ancestor
      # method) when the project's per-file
      # `discovered_methods` doesn't know `M.x` — leading to
      # surprising types like `Kernel.select → Array[String]`.
      # Until cross-file `discovered_methods` follows the same
      # project-wide seed, registering modules here would
      # introduce regressions in modules-with-module_function
      # idioms that previously resolved to `Dynamic[Top]`.
      # Class declarations are safe because per-file
      # `discovered_methods` already tracks `def self.x` /
      # `def x` instance and singleton methods consistently.
      #
      # @param paths  [Array<String>] project file paths.
      # @param buffer [Rigor::Analysis::BufferBinding, nil]
      # @return [Hash{String => Rigor::Type::Singleton}]
      def discovered_classes_for_paths(paths, buffer: nil)
        accumulator = {}
        paths.each do |path|
          physical = buffer ? buffer.resolve(path) : path
          source = File.read(physical)
          root = Prism.parse(source, filepath: path).value
          collect_class_decls(root, [], accumulator)
        rescue StandardError
          # Skip files that fail to parse or read; the per-file
          # analyzer surfaces the parse error separately.
          next
        end
        accumulator.freeze
      end

      # ADR-24 slice 2 — cross-file companion to
      # `discovered_classes_for_paths`. Walks every project
      # file once and returns both the merged
      # `discovered_def_nodes` table (a class reopened across
      # files has its method tables merged) and the merged
      # class -> superclass-name map. The engine consults these
      # so an implicit-self call inside a subclass resolves
      # against a superclass `def` declared in a sibling file
      # (`Mastodon::CLI::Accounts` calling a helper defined in
      # `Mastodon::CLI::Base`).
      #
      # The returned `def_sources` map mirrors `def_nodes` but stores
      # a `"path:line"` String per `(class_name, method_name)` instead
      # of the `Prism::DefNode`. A `Prism::Location` does not expose
      # its source file through public API, so the source site is
      # captured here, in the pre-pass loop that still holds `path`.
      # `CheckRules#undefined_method_diagnostic` consults the seeded
      # copy to name the defining file when a project monkey-patch on
      # a core/stdlib/gem class is called cross-file (ADR-17). First
      # write wins, matching `def_nodes`' own merge order.
      #
      # @param paths  [Array<String>] project file paths.
      # @param buffer [Rigor::Analysis::BufferBinding, nil]
      # @return [Hash{Symbol => Hash}]
      #   `{ def_nodes:, def_sources:, superclasses:, includes:, class_sources: }`
      def discovered_def_index_for_paths(paths, buffer: nil)
        acc = { def_nodes: {}, singleton_def_nodes: {}, def_sources: {}, superclasses: {}, includes: {},
                method_visibilities: {}, methods: {}, class_sources: {}, data_member_layouts: {},
                struct_member_layouts: {} }
        paths.each do |path|
          physical = buffer ? buffer.resolve(path) : path
          root = Prism.parse(File.read(physical), filepath: path).value
          accumulate_project_index(acc, path, root)
        rescue StandardError
          # Skip files that fail to parse or read; the per-file
          # analyzer surfaces the parse error separately.
          next
        end
        # Cross-file method suppression is for the project's OWN
        # accessors (attr_* / define_method / alias) — NOT for plain
        # `def`s. A cross-file `def` on a class is exactly the ADR-17
        # monkey-patch case the undefined-method rule deliberately
        # surfaces (fire + def-site annotation, nudging `pre_eval:`),
        # so dropping the `def`-declared names keeps that contract
        # intact while still letting `attr_reader :x` in one file
        # suppress a false undefined-method for `obj.x` in another.
        acc[:methods] = subtract_def_methods(acc[:methods], acc[:def_nodes])
        %i[def_nodes singleton_def_nodes def_sources includes method_visibilities methods class_sources].each do |key|
          acc[key].each_value(&:freeze)
        end
        acc.transform_values(&:freeze)
      end

      # Removes, per class, the method names that have a project `def`
      # node, leaving only accessor/alias/define_method-introduced
      # methods in the cross-file suppression table.
      def subtract_def_methods(methods, def_nodes)
        methods.each_with_object({}) do |(class_name, table), out|
          defs = def_nodes[class_name] || {}
          kept = table.reject { |method_name, _kind| defs.key?(method_name) }
          out[class_name] = kept unless kept.empty?
        end
      end

      # Folds one file's class-keyed indexes into the cross-file
      # accumulator. `method_visibilities` (ADR-35) is collected here so
      # the override-visibility-reduced rule can read an ancestor's
      # visibility declared in a sibling file.
      def accumulate_project_index(acc, path, root)
        merge_discovered_defs(acc[:def_nodes], acc[:def_sources], path, root)
        build_discovered_singleton_def_nodes(root).each do |class_name, methods|
          (acc[:singleton_def_nodes][class_name] ||= {}).merge!(methods)
        end
        superclasses = build_discovered_superclasses(root)
        includes = build_discovered_includes(root)
        acc[:superclasses].merge!(superclasses)
        includes.each do |class_name, mods|
          acc[:includes][class_name] = ((acc[:includes][class_name] || []) + mods).uniq
        end
        record_class_sources(acc[:class_sources], path, root, superclasses, includes)
        merge_class_keyed_index_tables(acc, root)
        acc[:data_member_layouts].merge!(build_data_member_layouts(root))
        acc[:struct_member_layouts].merge!(build_struct_member_layouts(root))
      end

      # Folds the per-class method-visibility and method-existence tables of
      # one file into the cross-file accumulator (kept out of
      # {#accumulate_project_index} to hold its ABC budget).
      def merge_class_keyed_index_tables(acc, root)
        build_discovered_method_visibilities(root).each do |class_name, table|
          (acc[:method_visibilities][class_name] ||= {}).merge!(table)
        end
        build_discovered_methods(root).each do |class_name, table|
          (acc[:methods][class_name] ||= {}).merge!(table)
        end
      end

      # ADR-46 slice 1 — accumulates, per qualified user class/module
      # name, the set of files that declare it. A class's declaration
      # shape (its body `def`s, its `class Foo < Bar` superclass, its
      # `include`s) lives wherever the class is opened, so every file that
      # contributes a def / superclass / include for a name is a source of
      # that name's ancestry edges. {Scope#superclass_of} /
      # {Scope#includes_of} record this set when resolving the edge during
      # dependency recording (ADR-46). The class-declaration walk
      # (`collect_class_decls`) catches bodyless / def-less reopenings the
      # other three builders miss.
      def record_class_sources(class_sources, path, root, superclasses, includes)
        names = Set.new
        collect_class_decls(root, [], decls = {})
        names.merge(decls.keys)
        names.merge(superclasses.keys)
        names.merge(includes.keys)
        names.merge(build_discovered_def_nodes(root).keys)
        names.each { |name| (class_sources[name] ||= Set.new) << path }
      end

      # Merges one file's `class → method → DefNode` map into the
      # cross-file `def_nodes` index and records each method's first-
      # seen `"path:line"` definition site in `def_sources` (ADR-17 —
      # the un-registered-project-patch signal `call.undefined-method`
      # and `rigor triage` key on).
      def merge_discovered_defs(def_nodes, def_sources, path, root)
        build_discovered_def_nodes(root).each do |class_name, methods|
          (def_nodes[class_name] ||= {}).merge!(methods)
          sources = (def_sources[class_name] ||= {})
          methods.each do |method_name, def_node|
            sources[method_name] ||= "#{path}:#{def_node.location&.start_line || 1}"
          end
        end
      end

      # Class-only variant of `record_declarations` — descends
      # into nested module bodies (so `module Foo; class Bar`
      # registers `Foo::Bar`) but never registers the module
      # itself in `accumulator`.
      def collect_class_decls(node, qualified_prefix, accumulator)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode
          name = qualified_name_for(node.constant_path)
          if name
            full = (qualified_prefix + [name]).join("::")
            accumulator[full] = Type::Combinator.singleton_of(full)
            return collect_class_decls(node.body, qualified_prefix + [name], accumulator) if node.body
          end
        when Prism::ModuleNode
          name = qualified_name_for(node.constant_path)
          return collect_class_decls(node.body, qualified_prefix + [name], accumulator) if name && node.body
        when Prism::ConstantWriteNode
          record_class_new_constant_decl(node, qualified_prefix, accumulator)
        end

        node.compact_child_nodes.each { |child| collect_class_decls(child, qualified_prefix, accumulator) }
      end

      # T1 (template-corpora survey) — record a `Const = Class.new(Super)`
      # (and the bare `Class.new` / `Module.new`) class-creating constant
      # in the cross-file discovery table so a reference to `Const` from
      # ANOTHER file under the same namespace resolves to the project
      # class instead of falling through to a core same-named class
      # (`Liquid::SyntaxError = Class.new(Error)` referenced in a sibling
      # file's `rescue SyntaxError => e`, which otherwise resolved to core
      # `::SyntaxError`). Mirrors the single-file `in_source_constants`
      # answer, which types `Class.new(Super)` as `Singleton[Super]` (the
      # constructed class answers method lookups through Super's chain).
      # The superclass name is resolved lexically against the enclosing
      # prefix; a bare `Class.new` with no superclass (or `Module.new`)
      # types as `Singleton[Const]` itself. The block form is left to the
      # existing `meta_new_block_body` machinery — only the plain
      # `Class.new(Super)` constant (the namespaced-sibling-error idiom)
      # is added here.
      def record_class_new_constant_decl(node, qualified_prefix, accumulator)
        rvalue = node.value
        return unless class_new_call?(rvalue) || module_new_call?(rvalue)
        return if rvalue.block # block form: handled by meta_new_block_body walks

        full = (qualified_prefix + [node.name.to_s]).join("::")
        super_name = class_new_superclass_name(rvalue, qualified_prefix, accumulator)
        accumulator[full] = Type::Combinator.singleton_of(super_name || full)
      end

      # Lexically-qualified name of a `Class.new(Super)` superclass
      # argument, or nil when there is no positional superclass (a bare
      # `Class.new` / `Module.new`). When the unqualified super name is a
      # class already discovered under an enclosing-prefix segment, the
      # qualified form is returned (so `Class.new(Error)` inside `module M`
      # resolves to `M::Error`); otherwise the literal name is returned
      # (covering a core / RBS-known superclass spelled bare).
      def class_new_superclass_name(call_node, qualified_prefix, accumulator)
        arg = call_node.arguments&.arguments&.first
        return nil if arg.nil?

        raw = qualified_name_for(arg)
        return nil if raw.nil?

        prefix = qualified_prefix.dup
        until prefix.empty?
          candidate = (prefix + [raw]).join("::")
          return candidate if accumulator.key?(candidate)

          prefix.pop
        end
        raw
      end

      # Walks the program once for `Prism::ModuleNode` and
      # `Prism::ClassNode`, recording the `Singleton[<qualified>]`
      # type for the outermost `constant_path` node of each
      # declaration. Inner segments of a `class Foo::Bar::Baz`
      # path remain real references (resolved through the
      # ordinary lexical walk), so we annotate ONLY the topmost
      # path node. Nested declarations contribute their fully
      # qualified path: `class A::B; class C; ...` produces
      # `A::B` for the outer and `A::B::C` for the inner.
      def build_declaration_artifacts(root)
        identity_table = {}.compare_by_identity
        discovered = {}
        record_declarations(root, [], identity_table, discovered)
        [identity_table.freeze, discovered.freeze]
      end

      def record_declarations(node, qualified_prefix, identity_table, discovered)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ModuleNode, Prism::ClassNode
          return if record_class_or_module?(node, qualified_prefix, identity_table, discovered)
        when Prism::ConstantWriteNode
          return if record_meta_new_constant?(node, qualified_prefix, identity_table, discovered)
        end

        node.compact_child_nodes.each do |child|
          record_declarations(child, qualified_prefix, identity_table, discovered)
        end
      end

      def record_class_or_module?(node, qualified_prefix, identity_table, discovered)
        name = qualified_name_for(node.constant_path)
        return false unless name

        full = (qualified_prefix + [name]).join("::")
        singleton = Type::Combinator.singleton_of(full)
        identity_table[node.constant_path] = singleton
        discovered[full] = singleton
        child_prefix = qualified_prefix + [name]
        record_declarations(node.body, child_prefix, identity_table, discovered) if node.body
        true
      end

      # Recognises class-creating meta calls at constant-write rvalue
      # position and registers `Const` (qualified by the surrounding
      # class/module path) as a discovered class. `Const.new(...)`
      # then resolves to a fresh `Nominal[Const]` via `meta_new`,
      # instead of the un-narrowed `Dynamic[top]` returned by the
      # default `Class#new` envelope.
      #
      # Two recognised meta forms:
      #
      # - `Const = Data.define(*Symbol) [do ... end]`
      # - `Const = Struct.new(*Symbol [, keyword_init: ...]) [do ... end]`
      #
      # The block body, if present, is recursed into so any nested
      # class/module declarations in the override block (rare but legal)
      # still feed the discovered table.
      def record_meta_new_constant?(node, qualified_prefix, identity_table, discovered)
        return false unless data_define_call?(node.value) || struct_new_call?(node.value)

        full = (qualified_prefix + [node.name.to_s]).join("::")
        discovered[full] = Type::Combinator.singleton_of(full)
        record_declarations(node.value, qualified_prefix, identity_table, discovered)
        true
      end

      # Recognises `Data.define(*Symbol)` and `Data.define(*Symbol) do ... end`
      # at constant-write rvalue position. The receiver MUST be the bare
      # `Data` constant (or `::Data`); other receivers (a local variable, a
      # method call return) are rejected because their identity is not
      # statically known.
      def data_define_call?(node)
        return false unless node.is_a?(Prism::CallNode)
        return false unless node.name == :define
        return false unless meta_constant_receiver?(node.receiver, :Data)

        args = node.arguments&.arguments || []
        args.all?(Prism::SymbolNode)
      end

      # Recognises `Struct.new(*Symbol)` and
      # `Struct.new(*Symbol, keyword_init: <expr>)` at constant-write
      # rvalue position. A trailing `KeywordHashNode` (the
      # `keyword_init: ...` form) is accepted but does not contribute
      # to member discovery; every other argument MUST be a
      # `Prism::SymbolNode`. At least one Symbol member is required —
      # `Struct.new()` is a degenerate form callers don't typically use.
      def struct_new_call?(node)
        return false unless meta_call_with_name?(node, :Struct, :new)

        args = node.arguments&.arguments || []
        positional = struct_new_positionals(args)
        return false if positional.nil? || positional.empty?

        positional.all?(Prism::SymbolNode)
      end

      # Recognises `Module.new` and `Module.new(&block)` /
      # `Module.new do ... end` at constant-write rvalue
      # position. The block body is the anonymous module's
      # `module_eval` body; defs inside it bind methods on the
      # named constant (`Const = Module.new do ...; def foo; ...; end; end`).
      # Arguments are NOT inspected because `Module.new` accepts
      # no positionals — Ruby raises ArgumentError if any are
      # passed — so a malformed call falls through the walker
      # without affecting analysis.
      def module_new_call?(node)
        meta_call_with_name?(node, :Module, :new)
      end

      # Recognises `Class.new`, `Class.new(super_class)`, and the
      # block form `Class.new { ... }`. Like `module_new_call?`,
      # the block body is walked as the anonymous class's body.
      # The optional `super_class` positional is accepted but does
      # NOT route through `ancestor` discovery in this slice — the
      # synthesised class still answers method lookups via its
      # own body's defs, mirroring how `Struct.new` / `Data.define`
      # are handled.
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

      def qualified_name_for(constant_path_node)
        case constant_path_node
        when Prism::ConstantReadNode
          constant_path_node.name.to_s
        when Prism::ConstantPathNode
          render_constant_path(constant_path_node)
        end
      end

      def render_constant_path(node)
        prefix =
          case node.parent
          when Prism::ConstantReadNode then "#{node.parent.name}::"
          when Prism::ConstantPathNode then "#{render_constant_path(node.parent)}::"
          else ""
          end
        "#{prefix}#{node.name}"
      end

      # Walks `node`'s subtree DFS and fills in scope entries for every
      # Prism node the StatementEvaluator did not visit (i.e. expression-
      # interior nodes like the receiver/args of a CallNode). Those
      # nodes inherit their nearest recorded ancestor's scope.
      #
      # `IfNode` / `UnlessNode` are special-cased: the truthy and falsey
      # branches each get their predicate's narrowed scope before
      # recursing. This handles expression-position conditionals
      # (e.g. `cache[k] = if cond; t; else; e; end` and conditionals
      # nested as call arguments) which are typed by ExpressionTyper
      # without going through `eval_if`'s narrowing path.
      def propagate(node, table, parent_scope)
        return unless node.is_a?(Prism::Node)

        current_scope =
          if table.key?(node)
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
        else
          node.compact_child_nodes.each { |child| propagate(child, table, current_scope) }
        end
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
    # rubocop:enable Metrics/ModuleLength
  end
end
