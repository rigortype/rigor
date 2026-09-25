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

      # Every `jump_class` node that targets the construct whose body is `node`, as an identity-keyed Hash used as a
      # membership set: the jump sinks also collect jumps belonging to nested constructs, and their consumers filter
      # against this set.
      # The jump classes among `jump_classes` that target the construct whose body is `node`, in one walk: a loop
      # asks for its `next`, `break` and `redo` together. Early-exiting once every class is found.
      def kinds(node, jump_classes)
        found = []
        collect_kinds(node, jump_classes, found)
        found
      end

      def collect_kinds(node, jump_classes, found)
        return if node.nil? || found.size == jump_classes.size

        found << node.class if jump_classes.include?(node.class) && !found.include?(node.class)
        node.rigor_each_child do |child|
          collect_kinds(child, jump_classes, found) unless boundary?(child)
        end
      end
      private_class_method :collect_kinds

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
