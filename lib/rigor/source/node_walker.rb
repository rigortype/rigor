# frozen_string_literal: true

require "prism"

require_relative "node_children"

module Rigor
  module Source
    # Yields every `Prism::Node` reachable from a root in DFS pre-order.
    #
    # The walker is the source-positioning analogue to `NodeLocator`: where the locator answers "what node
    # is at this point?", the walker enumerates the full set of Prism nodes for tooling that needs to
    # operate on each one (coverage probes, lint passes, IDE outlines).
    #
    # Non-Prism children (literals embedded in node attributes, virtual nodes, or `nil` slots) are silently
    # skipped so callers can rely on every yielded value responding to the `Prism::Node` API.
    #
    # Issue #318 — a `Prism::DefinedNode`'s operand is never evaluated at runtime (`defined?` inspects the
    # expression statically; it does not run it), so the walk yields the `DefinedNode` itself but does NOT
    # descend into its `value` subtree. Every consumer of this walker treats a yielded node as "reachable,
    # evaluated code" (mutation/break/return scans, the check-rules main-pass oracle, coverage and precision
    # probes); walking into the operand would make them reason about code that can never run, which is
    # exactly the false-positive class the issue reports (`defined?(@x) && ...` flagging a call that is
    # actually inert).
    module NodeWalker
      module_function

      # @rbs return: Enumerator[untyped] -- When no block is given.
      def each(root, &)
        return to_enum(__method__, root) unless block_given?

        walk(root, &)
        nil
      end

      def walk(node, &)
        return unless node.is_a?(Prism::Node)

        yield node
        return if node.is_a?(Prism::DefinedNode)

        node.rigor_each_child { |child| walk(child, &) }
      end

      # Like {.each}, but also yields the node's lexical ancestor chain (outermost first, EXCLUDING the node
      # itself). The yielded `ancestors` array is the live descent stack — callers that retain it past the
      # block invocation MUST copy it (`Plugin::NodeContext` does). Used by the plugin engine to give
      # `node_rule` blocks their enclosing class / method / block context (ADR-37 slice 1d).
      #
      # @rbs return: Enumerator[untyped] -- When no block is given.
      def each_with_ancestors(root, &)
        return to_enum(__method__, root) unless block_given?

        walk_with_ancestors(root, [], &)
        nil
      end

      def walk_with_ancestors(node, ancestors, &block)
        return unless node.is_a?(Prism::Node)

        block.call(node, ancestors)
        return if node.is_a?(Prism::DefinedNode)

        ancestors.push(node)
        node.rigor_each_child { |child| walk_with_ancestors(child, ancestors, &block) }
        ancestors.pop
      end
    end
  end
end
