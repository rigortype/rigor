# frozen_string_literal: true

require "prism"

module Rigor
  module Source
    # Yields every `Prism::Node` reachable from a root in DFS pre-order.
    #
    # The walker is the source-positioning analogue to `NodeLocator`: where the
    # locator answers "what node is at this point?", the walker enumerates the
    # full set of Prism nodes for tooling that needs to operate on each one
    # (coverage probes, lint passes, IDE outlines).
    #
    # Non-Prism children (literals embedded in node attributes, virtual nodes,
    # or `nil` slots) are silently skipped so callers can rely on every yielded
    # value responding to the `Prism::Node` API.
    module NodeWalker
      module_function

      # @yieldparam node [Prism::Node]
      # @return [Enumerator] when no block is given.
      def each(root, &)
        return to_enum(__method__, root) unless block_given?

        walk(root, &)
        nil
      end

      def walk(node, &)
        return unless node.is_a?(Prism::Node)

        yield node
        node.compact_child_nodes.each { |child| walk(child, &) }
      end
    end
  end
end
