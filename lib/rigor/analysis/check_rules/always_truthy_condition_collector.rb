# frozen_string_literal: true

require "prism"

module Rigor
  module Analysis
    module CheckRules
      # Walks a parse tree and collects every `IfNode` / `UnlessNode`
      # whose predicate folds to a `Type::Constant` AND is NOT
      # disqualified by the rule's conservative envelope.
      #
      # The companion rule (`flow.always-truthy-condition`) is
      # the inferred-constant counterpart to
      # `flow.unreachable-branch` (which only fires on syntactic
      # literals). The literal-only rule was the v0.1.2 first-cut
      # because Rigor's incomplete loop / mutation / RBS-strictness
      # modelling produces inferred constants that look real but
      # are pragmatically false-positives. This collector adds two
      # surgical skips to bring the inferred-constant case in
      # without resurfacing those false positives:
      #
      # - **Inside a loop / block**: predicates nested inside
      #   `WhileNode` / `UntilNode` / `ForNode` / `BlockNode`
      #   ancestors. Mutation tracking through loop bodies is
      #   incomplete (`shift = 0; loop { shift += 7 }` keeps
      #   `shift` at `Constant<7>` per the analyzer), so a
      #   `Constant<bool>` predicate inside the loop body is
      #   suspect.
      # - **Defensive predicate calls**: `.nil?` / `.empty?` /
      #   `.zero?` / `.any?` / `.none?` / `.all?`. These read
      #   like the user explicitly checking for a runtime
      #   condition that the type system already proves can't
      #   happen — Rigor's strict-on-returns RBS often disagrees
      #   with the user's defensive check (e.g. `Module#name`
      #   returns `String` per RBS but anonymous classes really
      #   do return `nil`). Skipping these forms keeps the rule
      #   useful for genuine logic errors without faulting
      #   defensive code.
      #
      # Also skipped (so the literal-only `unreachable-branch`
      # rule doesn't double-fire alongside this one):
      #
      # - Predicates whose direct AST shape is a literal
      #   (`TrueNode` / `FalseNode` / `NilNode` / numeric / string
      #   / symbol / regexp).
      class AlwaysTruthyConditionCollector
        DEFENSIVE_PREDICATES = %i[nil? empty? zero? any? none? all? respond_to?].freeze
        LOOP_OR_BLOCK_NODE_CLASSES = [
          Prism::WhileNode, Prism::UntilNode, Prism::ForNode, Prism::BlockNode
        ].freeze
        LITERAL_PREDICATE_NODE_CLASSES = [
          Prism::TrueNode, Prism::FalseNode, Prism::NilNode,
          Prism::IntegerNode, Prism::FloatNode,
          Prism::StringNode, Prism::SymbolNode, Prism::RegularExpressionNode
        ].freeze

        Result = Data.define(:node, :polarity)

        # @return [Array<Result>] one entry per qualifying
        #   predicate. Empty when the tree carries no firing
        #   predicates.
        def initialize(scope_index)
          @scope_index = scope_index
          @results = []
        end

        def collect(root)
          walk(root, in_loop_or_block: false)
          @results.freeze
        end

        private

        def walk(node, in_loop_or_block:)
          return unless node.is_a?(Prism::Node)

          collect_predicate(node) if conditional_node?(node) && !in_loop_or_block

          child_in_loop_or_block = in_loop_or_block || enters_loop_or_block?(node)
          node.compact_child_nodes.each { |child| walk(child, in_loop_or_block: child_in_loop_or_block) }
        end

        def conditional_node?(node)
          node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)
        end

        def enters_loop_or_block?(node)
          LOOP_OR_BLOCK_NODE_CLASSES.any? { |klass| node.is_a?(klass) }
        end

        def collect_predicate(node)
          predicate = node.predicate
          return if literal_predicate?(predicate)
          return if defensive_predicate?(predicate)

          scope = @scope_index[node]
          return if scope.nil?

          predicate_type = scope.type_of(predicate)
          return unless predicate_type.is_a?(Type::Constant)

          polarity = predicate_type.value.nil? || predicate_type.value == false ? :falsey : :truthy
          @results << Result.new(node: predicate, polarity: polarity)
        end

        def literal_predicate?(predicate)
          LITERAL_PREDICATE_NODE_CLASSES.any? { |klass| predicate.is_a?(klass) }
        end

        def defensive_predicate?(predicate)
          predicate.is_a?(Prism::CallNode) && DEFENSIVE_PREDICATES.include?(predicate.name)
        end
      end
    end
  end
end
