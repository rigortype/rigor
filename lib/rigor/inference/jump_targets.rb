# frozen_string_literal: true

require "prism"

require_relative "../source/node_children"

module Rigor
  module Inference
    # The `break` / `next` nodes that target a construct: the ones reachable from its body without crossing a
    # construct that retargets them — a nested block, lambda, `def`, loop, or class body. `ExpressionTyper`'s
    # block-return passes (issues #841 and #853) and `StatementEvaluator`'s loop and block joins all key on this set,
    # and each used to carry its own copy of the scan with a different boundary list (issue #1198). The class-body
    # nodes are a boundary only nominally: Ruby rejects a `next` or `break` directly inside one.
    module JumpTargets
      BOUNDARY_NODES = Set[
        Prism::BlockNode, Prism::LambdaNode, Prism::DefNode,
        Prism::WhileNode, Prism::UntilNode, Prism::ForNode,
        Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode
      ].freeze

      module_function

      # True when `node` retargets the jumps below it.
      def boundary?(node)
        BOUNDARY_NODES.include?(node.class)
      end

      # True when a `jump_class` node targets the construct whose body is `node`. Allocation-free and early-exiting:
      # both typers ask it of every block body, and the overwhelming majority answer false.
      def any?(node, jump_class)
        return false if node.nil?
        return true if node.is_a?(jump_class)

        node.rigor_each_child do |child|
          next if boundary?(child)
          return true if any?(child, jump_class)
        end
        false
      end

      # Which of `jump_classes` target the construct whose body is `node`, found in one walk and answered as a bit
      # mask (bit `i` for `jump_classes[i]`), so a loop asks for its `next`, `break` and `redo` together without
      # allocating. The walk stops descending once every class is found.
      def kinds(node, jump_classes)
        kind_mask(node, jump_classes, 0, (1 << jump_classes.size) - 1)
      end

      def kind_mask(node, jump_classes, mask, full)
        return mask if node.nil? || mask == full

        index = jump_classes.index(node.class)
        mask |= 1 << index if index
        node.rigor_each_child do |child|
          mask = kind_mask(child, jump_classes, mask, full) unless boundary?(child)
        end
        mask
      end
      private_class_method :kind_mask

      # Every `jump_class` node that targets the construct whose body is `node`, as an identity-keyed Hash used as a
      # membership set: the jump sinks also collect jumps belonging to nested constructs, and their consumers filter
      # against this set.
      def of(node, jump_class)
        found = {}.compare_by_identity
        collect(node, jump_class, found)
        found
      end

      def collect(node, jump_class, found)
        return if node.nil?

        found[node] = true if node.is_a?(jump_class)
        node.rigor_each_child do |child|
          next if boundary?(child)

          collect(child, jump_class, found)
        end
      end
      private_class_method :collect
    end
  end
end
