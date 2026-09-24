# frozen_string_literal: true

require "prism"

module Rigor
  module Inference
    # Issue #1256 — the later operands of one expression `StatementEvaluator` threads and types as a whole (a
    # call, a literal, a `rescue` modifier): the operands entered from a scope an earlier operand moved, rather
    # than from the one the whole expression is typed from. `puts(b.unshift("s"), b.first.upcase)` enters
    # `b.first.upcase` after the `unshift` widened `b`, and `[n += 1, n += 1]` its second element after the first
    # write.
    #
    # Each such operand is recorded into the per-node scope index with the scope it was entered from, so the
    # diagnostics read it there, and typed from that scope once, so the whole expression's value holds it
    # ({#types}). The operand holding a write is still typed from its own entry: `out << (n += 1)` appends `1`.
    #
    # The walk takes an operand before anything below it, and compares an operand's entry against the scope its
    # nearest taken ancestor is typed from, so each later operand is typed exactly once: from the bottom up, each
    # holding the values of the ones below it. A threaded call below the root is still not typed as a whole
    # (`StatementEvaluator#call_effects`); its later operands join the root's walk.
    class OperandWalk
      # Positions `ExpressionTyper` gives no value of their own: it reads their children directly, never the node,
      # so a later one is recorded but not typed, and its children are compared against its ancestor's scope.
      # A keyword hash is typed whole only as a plain hash: the `**h` form reads the splatted value itself
      # (`ExpressionTyper#double_splat_hash_shape`), so its children are taken instead.
      NON_VALUE_NODES = Set[
        Prism::ArgumentsNode, Prism::AssocNode, Prism::AssocSplatNode, Prism::BlockArgumentNode, Prism::SplatNode,
        Prism::KeywordHashNode
      ].freeze
      private_constant :NON_VALUE_NODES

      # The per-node scope index's `(node, scope) ->` recorder, or nil for an unrecorded pass.
      attr_reader :recorder

      def initialize(recorder)
        @recorder = recorder
        @entries = nil
        @types = nil
      end

      # The position the next taken operand lands at, for {#types}' `since:`.
      def mark
        @entries.nil? ? 0 : @entries.size
      end

      # Takes `node`, entered from `entry`. Answers the slot {#resolve} fills, or nil for a {NON_VALUE_NODES}
      # position.
      def later(node, entry)
        @recorder&.call(node, entry)
        return nil if NON_VALUE_NODES.include?(node.class)

        (@entries ||= []) << [node, entry, nil]
        @entries.size - 1
      end

      # The value the handler that evaluated the operand in `slot` typed it to, from its entry.
      def resolve(slot, type)
        @entries[slot][2] = type
      end

      # The identity-comparing table of every taken operand's value, for `ExpressionTyper`'s `operand_types:`, or
      # nil when the walk took none at or after `since` (a {#mark}). An operand the evaluator did not type is typed
      # from its entry here, after every operand below it. A threaded call below the root asks for the operands
      # taken under it once they are all taken; they are typed then and only then, and the table keeps growing,
      # so the root's own request types only what is left.
      def types(tracer, since: 0)
        return nil if @entries.nil? || @entries.size <= since

        @types ||= {}.compare_by_identity
        (@entries.size - 1).downto(since) do |index|
          node, entry, type = @entries[index]
          next if @types.key?(node)

          @types[node] = type || self.class.type_of(entry, node, tracer, @types)
        end
        @types
      end

      # `node`'s type from `scope`, answering each node `operand_types` holds with its value there. `Scope#type_of`
      # itself is plugin-facing and keeps its surface, so the table goes to the typer directly.
      def self.type_of(scope, node, tracer, operand_types)
        return scope.type_of(node, tracer: tracer) if operand_types.nil?

        ExpressionTyper.new(scope: scope, tracer: tracer, operand_types: operand_types).type_of(node)
      end
    end
  end
end
