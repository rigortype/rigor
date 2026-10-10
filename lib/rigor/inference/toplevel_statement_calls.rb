# frozen_string_literal: true

require "prism"

require_relative "../source/node_children"

module Rigor
  module Inference
    # Issue #1715 — the receiverless calls of one file whose `self` is `main` by their place in the tree alone: a
    # top-level statement, or an expression nested only in other expressions of one (an argument, a right-hand
    # side, a branch of a top-level `if` / `while` / `case` / `begin`, an interpolation in a top-level string).
    #
    # Everything that may run with another `self`, or at another time, is left out, together with everything
    # inside it: a block or lambda (an `instance_eval` / `class_eval` block rebinds `self`, and which call does is
    # not decided here), a `def` body, a `class` / `module` / `class << …` body, and a `BEGIN` / `END` block.
    # `Scope#toplevel?` cannot stand in for this: it stays true inside a block whose `self` is not `main`.
    #
    # `RbsDispatch` reads it to type a bare call through a module the project mixes into `main` with a top-level
    # `include` ({ObjectMixins.sole_rbs_declaration}). `Inference::ScopeIndexer` keeps one per file on the
    # discovery index, so a callee body another file wrote finds none of its calls here and declines.
    #
    # Built lazily: the walk runs the first time a consumer asks, so a file nobody asks about pays one small object.
    class ToplevelStatementCalls
      # The nodes whose bodies may run with a `self` other than `main`, or not as part of the script body.
      BOUNDARIES = [
        Prism::BlockNode, Prism::LambdaNode, Prism::DefNode, Prism::ClassNode, Prism::ModuleNode,
        Prism::SingletonClassNode, Prism::PreExecutionNode, Prism::PostExecutionNode
      ].freeze
      private_constant :BOUNDARIES

      def initialize(root)
        @root = root
        @calls = nil
      end

      # Whether `call_node` is one of this file's receiverless calls in a top-level statement position.
      def include?(call_node) = calls.include?(call_node)

      private

      def calls
        @calls ||= begin
          found = Set.new.compare_by_identity
          visit(@root, found)
          found.freeze
        end
      end

      def visit(node, found)
        return if BOUNDARIES.any? { |boundary| node.is_a?(boundary) }

        found << node if node.is_a?(Prism::CallNode) && node.receiver.nil?
        node.rigor_each_child { |child| visit(child, found) }
      end
    end
  end
end
