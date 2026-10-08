# frozen_string_literal: true

require "prism"

module Rigor
  module Inference
    module ScopeIndexer
      # ADR-119 WD3 — which of a file's method contributions are `possible`: the classifier the def-contribution
      # producers ({ScopeIndexer#build_methods_and_def_nodes}, {ScopeIndexer#build_discovered_singleton_def_nodes})
      # consult to fill `possible_discovered_methods` and the `contested_*` siblings.
      #
      # A contribution is `certain` when its statement executes whenever the file's top level executes. The certain
      # regions are:
      #
      # - the program's statements, and the bodies of `class`, `module` and `class << self` declarations that are
      #   themselves certain;
      # - the block of a meta-new constant write (`K = Class.new do … end`, `Module.new`, `Struct.new`,
      #   `Data.define`, {ScopeIndexer#meta_new_block_call}) and of a bare factory call
      #   ({AnonymousMetaClass.block_form_receiver}), when the write or the call is certain: Ruby runs the block once,
      #   as the new class's body (ADR-119 WD2, "Conditional definers");
      # - a `begin` WITHOUT a `rescue` clause: its main statements and its `ensure` clause;
      # - the receiver and arguments of a certain call, so `private def x` and `memoize def x` stay certain.
      #
      # Everything else is `possible`: the branches of `if` / `unless` / `case` and the modifiers, loop bodies, the
      # right operand of `&&` / `||`, every other block and every lambda, `BEGIN` / `END`, a `class X … end if Y`
      # reopening, and the WHOLE of a `begin` that has a `rescue` clause, its main statements included. That last
      # rule refines WD3's wording: a rescued raise skips every statement after the raising one, so the main body of
      # a rescuing `begin` is not certain either, while a `begin` with no rescue either runs its main statements
      # and `ensure` or propagates the raise out of the file's top level. A `def` inside a method body is never
      # recorded by the walks (they return at a `DefNode`), so the classifier does not descend there either.
      #
      # The answer is an identity Set of the POSSIBLE contribution nodes — the nodes a producer records from — and
      # {EMPTY} when the file has none, so a file written entirely in certain regions allocates nothing. It is
      # separate from {MixinAccumulator}, which answers a different question (whether an edge's POSITION is a fact).
      module Certainty
        # The answer for a file with no possible contribution.
        EMPTY = Set.new.compare_by_identity.freeze

        # The nodes a def-contribution producer records from: a `def`, an `alias` / `undef`, a call (`attr_*`,
        # `define_method`, `alias_method`, `module_function :x`, a factory's members), and the declarations whose
        # header records members (`class X < Struct.new(:a)`, `X = Struct.new(:a) do … end`).
        CONTRIBUTIONS = Set[
          Prism::DefNode, Prism::AliasMethodNode, Prism::UndefNode, Prism::CallNode, Prism::ClassNode,
          Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
          Prism::ConstantPathOrWriteNode
        ].freeze

        CONSTANT_WRITES = Set[
          Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
          Prism::ConstantPathOrWriteNode
        ].freeze

        # The nodes whose whole subtree is possible.
        POSSIBLE_ROOTS = Set[
          Prism::BlockNode, Prism::LambdaNode, Prism::PreExecutionNode, Prism::PostExecutionNode,
          Prism::RescueModifierNode
        ].freeze
        private_constant :CONSTANT_WRITES, :POSSIBLE_ROOTS

        module_function

        # The possible contribution nodes of the tree under `root`, an identity Set ({EMPTY} when none).
        def possible_nodes(root)
          classifier = Classifier.new
          classifier.certain(root)
          classifier.result
        end

        # Whether `node` was classified possible in `possible` (a {possible_nodes} answer).
        def possible?(possible, node)
          !possible.empty? && possible.include?(node)
        end

        # One classification walk. `certain` descends a certain region; `possible` marks every contribution in a
        # subtree, since nothing below a possible node is certain.
        class Classifier
          def initialize
            @possible = nil
          end

          def result
            @possible ? @possible.freeze : EMPTY
          end

          def certain(node) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
            return unless node.is_a?(Prism::Node)
            return possible(node) if POSSIBLE_ROOTS.include?(node.class)

            case node
            when Prism::DefNode then return
            when Prism::IfNode then return branch(node.predicate, node.statements, node.subsequent)
            when Prism::UnlessNode then return branch(node.predicate, node.statements, node.else_clause)
            when Prism::CaseNode, Prism::CaseMatchNode then return case_branches(node)
            when Prism::WhileNode, Prism::UntilNode then return branch(node.predicate, node.statements)
            when Prism::ForNode then return branch(node.collection, node.index, node.statements)
            when Prism::AndNode, Prism::OrNode then return branch(node.left, node.right)
            when Prism::BeginNode then return begin_block(node)
            when Prism::CallNode then return call(node)
            end
            return if CONSTANT_WRITES.include?(node.class) && meta_new_write?(node)

            node.rigor_each_child { |child| certain(child) }
          end

          # Marks every contribution of the subtree.
          def possible(node)
            return unless node.is_a?(Prism::Node)

            (@possible ||= Set.new.compare_by_identity) << node if CONTRIBUTIONS.include?(node.class)
            return if node.is_a?(Prism::DefNode)

            node.rigor_each_child { |child| possible(child) }
          end

          private

          # The first node runs whenever the construct does; the rest may not.
          def branch(first, *rest)
            certain(first)
            rest.each { |node| possible(node) }
          end

          def case_branches(node)
            certain(node.predicate)
            node.conditions.each { |clause| possible(clause) }
            possible(node.else_clause)
          end

          # Without a rescue the main statements run (or the raise leaves the file) and `ensure` runs; with one, a
          # rescued raise skips every statement after the raising one, so all of it is possible.
          def begin_block(node)
            return possible_children(node) if node.rescue_clause

            certain(node.statements)
            possible(node.else_clause)
            certain(node.ensure_clause)
          end

          def possible_children(node)
            node.rigor_each_child { |child| possible(child) }
          end

          # The receiver and arguments of a certain call run; its block runs as a class body only for a bare
          # factory call. A safe-navigation call may skip its arguments.
          def call(node)
            certain(node.receiver)
            if node.safe_navigation?
              possible(node.arguments)
              possible(node.block)
              return
            end
            certain(node.arguments)
            block = node.block
            if block.is_a?(Prism::BlockNode) && AnonymousMetaClass.block_form_receiver(node)
              certain(block.body)
            else
              certain(block)
            end
          end

          # A meta-new constant write: the factory's receiver and arguments, and its block as the class body.
          def meta_new_write?(node)
            call = ScopeIndexer.meta_new_block_call(node)
            return false unless call

            certain(call.receiver)
            certain(call.arguments)
            block = call.block
            certain(block.is_a?(Prism::BlockNode) ? block.body : block)
            true
          end
        end
      end
    end
  end
end
