# frozen_string_literal: true

require "prism"

require_relative "../../source/constant_path"

module Rigor
  module Analysis
    module CheckRules
      # Walks a parse tree and collects every
      # `Prism::InstanceVariableWriteNode` inside an instance
      # method body of a `Prism::ClassNode` / `Prism::ModuleNode`,
      # grouped by (class qualified name, ivar name).
      #
      # The collector is the read-side companion to
      # `Inference::ScopeIndexer#build_class_ivar_index`. The
      # indexer unions the rvalue types into a single per-ivar
      # carrier; this collector preserves the per-write list so
      # the `def.ivar-write-mismatch` rule can compare each
      # write's concrete class against the first.
      #
      # Skipped on purpose:
      #
      # - Singleton-method bodies (`def self.foo`). Their ivars
      #   live on the class object, not on instances.
      # - Class-body ivar writes outside any def — the
      #   `Module#@var` surface is a separate slice the engine
      #   doesn't yet model.
      # - Nested classes / modules / defs inside a method body
      #   are barriers, mirroring the indexer's
      #   `IVAR_BARRIER_NODES` policy.
      class IvarWriteCollector
        BARRIER_NODES = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode].freeze
        private_constant :BARRIER_NODES

        # ADR-53 Track B — the node classes the shared {RuleWalk}
        # dispatches to this collector, and the context gate under which
        # the walk suppresses it. The legacy walk descends only through
        # class / module bodies and `return`s at the first `def` it meets,
        # so it collects ivar writes only from a `def` that sits directly
        # in a class / module body, never one nested in another `def`. On
        # the shared full DFS that prune becomes the `:inside_def` gate;
        # the enclosing class / module name stack the legacy walk threaded
        # as `qualified_prefix` is now `context.qualified_prefix`.
        NODE_CLASSES = [Prism::DefNode].freeze
        RULE_WALK_GATES = [:inside_def].freeze

        # Returns `Hash[class_name (String) => Hash[ivar_name
        # (Symbol) => Array<{node:, type:}>]]`. Empty when the
        # tree has no qualifying writes.
        def initialize(scope_index)
          @scope_index = scope_index
          @accumulator = {}
        end

        # Legacy single-collector walk — kept as the oracle the ADR-53
        # Track B equivalence harness compares {RuleWalk} against; deleted
        # when Track B completes.
        def collect(root)
          walk(root, [])
          @accumulator.transform_values(&:freeze).freeze
        end

        # {RuleWalk} entry point: the legacy walk's per-`def` logic,
        # invoked at each class-/module-body `def` under the shared
        # traversal contract. `collect_def_writes`' verbatim body reads the
        # enclosing class prefix from `context.qualified_prefix`.
        def visit(def_node, context)
          collect_def_writes(def_node, context.qualified_prefix)
        end

        # The accumulated result, frozen the same way `#collect` returns
        # it — used by {RuleWalk}-driven callers after the walk completes.
        def results
          @accumulator.transform_values(&:freeze).freeze
        end

        private

        def walk(node, qualified_prefix)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::ClassNode, Prism::ModuleNode
            name = Source::ConstantPath.qualified_name(node.constant_path)
            if name
              walk(node.body, qualified_prefix + [name]) if node.body
              return
            end
          when Prism::DefNode
            collect_def_writes(node, qualified_prefix)
            return
          end

          node.compact_child_nodes.each { |child| walk(child, qualified_prefix) }
        end

        def collect_def_writes(def_node, qualified_prefix)
          return if def_node.body.nil? || qualified_prefix.empty?
          return if def_node.receiver.is_a?(Prism::SelfNode)

          class_name = qualified_prefix.join("::")
          gather_writes(def_node.body, class_name)
        end

        def gather_writes(node, class_name)
          return unless node.is_a?(Prism::Node)

          record_write(node, class_name) if node.is_a?(Prism::InstanceVariableWriteNode)
          return if BARRIER_NODES.any? { |klass| node.is_a?(klass) }

          node.compact_child_nodes.each { |child| gather_writes(child, class_name) }
        end

        def record_write(node, class_name)
          scope = @scope_index[node]
          return if scope.nil?

          rvalue_type = scope.type_of(node.value)
          @accumulator[class_name] ||= {}
          @accumulator[class_name][node.name] ||= []
          @accumulator[class_name][node.name] << { node: node, type: rvalue_type }
        end
      end
    end
  end
end
