# frozen_string_literal: true

require "prism"

require_relative "../../source/node_children"

module Rigor
  module Analysis
    module CheckRules
      # ADR-100 WD2/WD3 — collects value-context uses of a `top` recovered from an author-declared `-> void`
      # return. The return-typing tier records the recovery on `Scope#void_origins` (keyed by the call node)
      # whenever an RBS `-> void` return widens to `top` on the direct-dispatch path (the receiver's own
      # resolvable class); this collector fires `static.value-use.void` when such a call node sits in a
      # *value* position, and stays silent when it is a bare statement.
      #
      # Value context is read top-down from the consumer node — the only nodes that place a sub-expression in
      # value position — so no parent tracking is needed and a bare-statement void call (a direct child of a
      # `StatementsNode`, never a consumer's value slot) is never reached:
      #
      # - an assignment's right-hand side (`x = logger.log(...)`, and the ivar / cvar / gvar / constant forms),
      # - a call's explicit receiver (`logger.log(...).inspect`),
      # - a call's positional argument (`store(logger.log(...))`).
      #
      # The recording is already FP-narrow (only an author-written `-> void`, only the direct-RBS path), so
      # the collector adds no further type reasoning: membership in `void_origins` is the whole gate. A
      # legitimate `top` value (an author-declared `-> top` return) never enters the table, so it stays
      # silent — the false-positive proof this rule rests on. The rule ships behind the `use-of-void-value`
      # bleeding-edge feature (authored `:warning`, resolved `:off` by every default profile).
      class VoidValueUseCollector
        # The assignment forms whose `value` slot is a value position. `MultiWriteNode` (destructuring) is
        # intentionally excluded — its `value` is a container the void call would have to be spread through,
        # not a direct use, so it is out of this slice's FP-narrow scope.
        WRITE_NODE_CLASSES = [
          Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode,
          Prism::ClassVariableWriteNode, Prism::GlobalVariableWriteNode,
          Prism::ConstantWriteNode, Prism::ConstantPathWriteNode
        ].freeze

        # ADR-53 Track B — the node classes the shared {RuleWalk} dispatches to this collector: the consumer
        # nodes whose slots are value positions. Prism node classes are leaves, so class-equality dispatch
        # matches the legacy walk's `case`. No context gate — a value-context void use is a use wherever the
        # DFS reaches it, loops and blocks included.
        NODE_CLASSES = [Prism::CallNode, *WRITE_NODE_CLASSES].freeze

        Result = Data.define(:void_node, :origin)

        def initialize(scope_index)
          @scope_index = scope_index
          @results = []
        end

        # Legacy single-collector walk — kept as the oracle the ADR-53 Track B equivalence harness compares
        # {RuleWalk} against. Walks the whole subtree once, checking each consumer node's value slots.
        # Returns one {Result} per value-context use of a recovered-`void` call.
        # @return [Array<Result>]
        def collect(root)
          walk(root)
          @results.freeze
        end

        # {RuleWalk} entry point: the legacy walk's per-node slot inspection, invoked at every consumer node
        # under the shared traversal contract. The `context` is unused — every consumer node is inspected.
        def visit(node, _context = nil)
          inspect_consumer(node)
        end

        # The accumulated result, frozen the same way `#collect` returns it — used by {RuleWalk}-driven
        # callers after the walk completes.
        def results
          @results.freeze
        end

        private

        def walk(node)
          return unless node.is_a?(Prism::Node)

          inspect_consumer(node)
          node.rigor_each_child { |child| walk(child) }
        end

        def inspect_consumer(node)
          case node
          when Prism::CallNode
            record_if_void(node.receiver)
            call_arguments(node).each { |arg| record_if_void(arg) }
          when *WRITE_NODE_CLASSES
            record_if_void(node.value)
          end
        end

        def call_arguments(call)
          args = call.arguments
          args.nil? ? [] : args.arguments
        end

        # A value node is a recovered-`void` use exactly when it is a call node the return-typing tier
        # recorded in `void_origins` (identity-keyed on that same node). Every other value slot — a literal, a
        # variable read, a non-void call — is absent from the table and stays silent.
        def record_if_void(value_node)
          return unless value_node.is_a?(Prism::CallNode)

          scope = @scope_index[value_node]
          origin = scope&.void_origins&.[](value_node)
          return if origin.nil?

          @results << Result.new(void_node: value_node, origin: origin)
        end
      end
    end
  end
end
