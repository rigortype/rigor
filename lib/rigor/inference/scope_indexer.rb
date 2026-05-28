# frozen_string_literal: true

require "prism"

require_relative "../scope"
require_relative "../type"
require_relative "mutation_widening"
require_relative "narrowing"
require_relative "statement_evaluator"

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
      # @return [Hash{Prism::Node => Rigor::Scope}] identity-comparing
      #   table whose default value is `default_scope`.
      def index(root, default_scope:) # rubocop:disable Metrics/AbcSize
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
        seeded_scope = default_scope
                       .with_declared_types(declared_types)
                       .with_discovered_classes(merged_classes)

        # Slice 7 phase 2. Pre-pass over every class/module body
        # to collect the per-class ivar accumulator. Seeded after
        # declared_types so the rvalue typer in the pre-pass can
        # see declaration overrides.
        class_ivars = build_class_ivar_index(root, seeded_scope)
        seeded_scope = seeded_scope.with_class_ivars(class_ivars)

        # Slice 7 phase 6. Same pre-pass shape for cvars (per
        # class) and globals (program-wide). Globals are also
        # materialised into the top-level scope's `globals` map
        # so reads at the top level (and in CLI probes that do
        # not enter a method body) observe the precise type
        # without consulting the accumulator on every lookup.
        class_cvars = build_class_cvar_index(root, seeded_scope)
        seeded_scope = seeded_scope.with_class_cvars(class_cvars)
        program_globals = build_program_global_index(root, seeded_scope)
        seeded_scope = seeded_scope.with_program_globals(program_globals)
        program_globals.each { |name, type| seeded_scope = seeded_scope.with_global(name, type) }

        # Slice 7 phase 9. In-source constant value tracking.
        # Walks every ConstantWriteNode/ConstantPathWriteNode in
        # the program and types its rvalue under a scope that
        # carries the surrounding qualified prefix as
        # `self_type`, so the rvalue typer sees in-class
        # references resolve correctly. Multiple writes to the
        # same qualified name union via `Type::Combinator.union`.
        in_source_constants = build_in_source_constants(root, seeded_scope)
        seeded_scope = seeded_scope.with_in_source_constants(in_source_constants)

        # Slice 7 phase 12. In-source method discovery. Walks
        # every class/module body for `Prism::DefNode` and
        # recognised `define_method` calls and records the
        # introduced method names. `rigor check` consults the
        # table to suppress false positives for methods the
        # user has defined but no RBS sig describes.
        discovered_methods = build_discovered_methods(root)
        seeded_scope = seeded_scope.with_discovered_methods(discovered_methods)

        # v0.0.2 #5 + ADR-24 slice 2 — record per-instance-method
        # def nodes, the class -> superclass map, and the
        # class/module -> included-modules map, each merged under
        # the cross-file pre-pass seed (see below).
        seeded_scope = merge_project_method_indexes(seeded_scope, default_scope, root)

        # v0.1.2 — per-class table of method visibilities
        # (`:public` / `:private` / `:protected`). The
        # `def.method-visibility-mismatch` CheckRule consults
        # the table to flag explicit-non-self calls to a
        # private user method.
        discovered_method_visibilities = build_discovered_method_visibilities(root)
        seeded_scope = seeded_scope.with_discovered_method_visibilities(discovered_method_visibilities)

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
        on_enter = ->(node, scope) { table[node] = scope }
        StatementEvaluator.new(scope: seeded_scope, on_enter: on_enter).evaluate(root)

        propagate(root, table, seeded_scope)
        table
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
        superclasses = default_scope.discovered_superclasses.merge(
          build_discovered_superclasses(root)
        )
        includes = default_scope.discovered_includes.merge(
          build_discovered_includes(root)
        ) { |_class, cross_file, per_file| (cross_file + per_file).uniq }

        seeded_scope
          .with_discovered_def_nodes(def_nodes)
          .with_discovered_superclasses(superclasses)
          .with_discovered_includes(includes)
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
        walk_class_ivars(root, [], default_scope, accumulator, mutated_ivars,
                         read_before_write, init_writes)
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

      def walk_class_ivars(node, qualified_prefix, default_scope, accumulator, mutated_ivars,
                           read_before_write = nil, init_writes = nil)
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
                               mutated_ivars, read_before_write, init_writes)
            end
            return
          end
        when Prism::DefNode
          collect_def_ivar_writes(node, qualified_prefix, default_scope, accumulator,
                                  mutated_ivars, read_before_write, init_writes)
          return
        end

        node.compact_child_nodes.each do |child|
          walk_class_ivars(child, qualified_prefix, default_scope, accumulator,
                           mutated_ivars, read_before_write, init_writes)
        end
      end

      def collect_def_ivar_writes(def_node, qualified_prefix, default_scope, accumulator, mutated_ivars,
                                  read_before_write = nil, init_writes = nil)
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

        gather_ivar_writes(def_node.body, body_scope, class_name, accumulator, EMPTY_GUARDED_IVARS, mutated_ivars)

        # B2.3 — collect per-method evidence for the read-before-
        # write nil contribution. The accumulator-level decision
        # ("is this ivar truly read-before-write across the
        # class lifetime?") is finalised at
        # `contribute_read_before_write_nil!` after the whole
        # class body has been walked, using `init_writes` as
        # the soundness gate (an ivar written in `initialize`
        # is initialised before any other method body runs).
        collect_read_before_write_evidence(def_node, class_name, read_before_write, init_writes)
      end

      # Walks the method body in AST (== execution) order
      # tracking ivar names whose first reference is a read.
      # The set is unioned into the class-wide
      # `read_before_write` accumulator. For `initialize` def
      # bodies, every write target is unioned into
      # `init_writes` instead — used by the finalisation step
      # to suppress nil contribution for ivars the constructor
      # guarantees are initialised.
      def collect_read_before_write_evidence(def_node, class_name, read_before_write, init_writes)
        return if read_before_write.nil? || init_writes.nil?

        seen_writes = Set.new
        read_first = Set.new
        detect_read_before_write(def_node.body, seen_writes, read_first)

        if def_node.name == :initialize
          init_set = (init_writes[class_name] ||= Set.new)
          seen_writes.each { |name| init_set << name }
          return
        end

        return if read_first.empty?

        rbw_set = (read_before_write[class_name] ||= Set.new)
        read_first.each { |name| rbw_set << name }
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
                             mutated_ivars = nil)
        return unless node.is_a?(Prism::Node)

        if node.is_a?(Prism::InstanceVariableWriteNode)
          record_ivar_write(node, scope, class_name, accumulator,
                            guarded: guarded_ivars.include?(node.name))
        end
        record_ivar_mutator_call(node, class_name, mutated_ivars) if mutated_ivars && node.is_a?(Prism::CallNode)

        # Don't recurse into nested defs, classes, or modules; their
        # ivars belong to their own enclosing class.
        return if IVAR_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

        if node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)
          walk_conditional_ivar_writes(node, scope, class_name, accumulator, guarded_ivars, mutated_ivars)
          return
        end

        node.compact_child_nodes.each do |c|
          gather_ivar_writes(c, scope, class_name, accumulator, guarded_ivars, mutated_ivars)
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
      def walk_conditional_ivar_writes(node, scope, class_name, accumulator, guarded_ivars, mutated_ivars = nil)
        then_guards = then_body_guarded_ivars(node)
        then_guarded = then_guards.empty? ? guarded_ivars : (guarded_ivars | then_guards)

        gather_ivar_writes(node.predicate, scope, class_name, accumulator, guarded_ivars, mutated_ivars)
        if node.statements
          gather_ivar_writes(node.statements, scope, class_name, accumulator, then_guarded, mutated_ivars)
        end
        branch = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
        gather_ivar_writes(branch, scope, class_name, accumulator, guarded_ivars, mutated_ivars) if branch
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
        accumulator[class_name] ||= {}
        existing = accumulator[class_name][node.name]
        accumulator[class_name][node.name] =
          existing ? Type::Combinator.union(existing, rvalue_type) : rvalue_type
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

      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength
      def walk_methods(node, qualified_prefix, in_singleton_class, accumulator)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = qualified_name_for(node.constant_path)
          if name
            child_prefix = qualified_prefix + [name]
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
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength

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
      #   `{ def_nodes:, def_sources:, superclasses:, includes: }`
      def discovered_def_index_for_paths(paths, buffer: nil)
        def_nodes = {}
        def_sources = {}
        superclasses = {}
        includes = {}
        paths.each do |path|
          physical = buffer ? buffer.resolve(path) : path
          root = Prism.parse(File.read(physical), filepath: path).value
          merge_discovered_defs(def_nodes, def_sources, path, root)
          superclasses.merge!(build_discovered_superclasses(root))
          build_discovered_includes(root).each do |class_name, mods|
            includes[class_name] = ((includes[class_name] || []) + mods).uniq
          end
        rescue StandardError
          # Skip files that fail to parse or read; the per-file
          # analyzer surfaces the parse error separately.
          next
        end
        def_nodes.each_value(&:freeze)
        def_sources.each_value(&:freeze)
        includes.each_value(&:freeze)
        {
          def_nodes: def_nodes.freeze, def_sources: def_sources.freeze,
          superclasses: superclasses.freeze, includes: includes.freeze
        }
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
        end

        node.compact_child_nodes.each { |child| collect_class_decls(child, qualified_prefix, accumulator) }
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
