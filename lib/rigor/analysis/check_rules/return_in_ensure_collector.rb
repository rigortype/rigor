# frozen_string_literal: true

require "prism"

require_relative "../../source/node_children"

module Rigor
  module Analysis
    module CheckRules
      # Walks a parse tree and collects every explicit `ReturnNode` that sits lexically inside the `ensure`
      # clause of a `begin` / `def` / `class` body. In Ruby, `return` inside `ensure` silently discards
      # both the method's in-flight return value and any in-flight exception — the classic footgun RuboCop
      # ships as `Lint/EnsureReturn` and PHPStan as `OverwrittenExitPointByFinallyRule`.
      #
      # The check is purely syntactic (no type engine involved) with a frame-aware envelope so it only
      # flags a `return` that actually belongs to the frame whose `ensure` it sits in:
      #
      # - A `return` inside a nested `def`, a lambda (`-> {}` / `lambda {}`), or a `define_method` block
      #   within the ensure body is skipped — that `return` exits the inner frame, not the one whose
      #   in-flight exception the ensure guards.
      # - A `return` inside a *plain* block (`each do ... return ... end`) within the ensure body DOES
      #   belong to the enclosing method and fires.
      # - A nested `begin ... ensure ... end` *inside* an ensure body is not descended into at its own
      #   `ensure` clause — that inner `EnsureNode` is visited separately (every `BeginNode` is), so each
      #   offending `return` is collected exactly once.
      class ReturnInEnsureCollector
        # ADR-53 Track B — the node classes the shared {RuleWalk} dispatches to this collector. Prism
        # represents every construct that can carry an `ensure` clause — `begin ... end`, a `def` body with
        # `rescue` / `ensure`, a class / module body with them — as a `BeginNode`, so one dispatch class
        # covers all the syntactic hosts. No context gates: the footgun is frame-relative, not
        # position-relative, so a `begin/ensure` inside a loop, block, or lambda is checked the same way.
        NODE_CLASSES = [Prism::BeginNode].freeze

        # Receiver-less calls whose attached block opens a new return frame: a `return` inside their block
        # exits the lambda / defined method, not the method whose `ensure` we are scanning. `proc` is
        # deliberately absent — `return` inside a `Proc` block returns from the enclosing method, so it
        # stays in scope for the rule.
        FRAME_BARRIER_CALL_NAMES = %i[lambda define_method].freeze

        def initialize(scope_index)
          @scope_index = scope_index
          @results = []
        end

        # Legacy single-collector walk — the oracle the ADR-53 Track B equivalence harness compares
        # {RuleWalk} against.
        def collect(root)
          walk_for_begin_nodes(root)
          @results.freeze
        end

        # {RuleWalk} entry point: invoked at every `BeginNode` the shared traversal reaches. The `context`
        # is unused — this collector checks every ensure clause.
        def visit(begin_node, _context = nil)
          collect_ensure_returns(begin_node)
        end

        # Returns `Array<{return_node:}>` — one entry per offending `return`, frozen the same way
        # `#collect` returns it.
        def results
          @results.freeze
        end

        private

        def walk_for_begin_nodes(node)
          return unless node.is_a?(Prism::Node)

          collect_ensure_returns(node) if node.is_a?(Prism::BeginNode)
          node.rigor_each_child { |child| walk_for_begin_nodes(child) }
        end

        def collect_ensure_returns(begin_node)
          ensure_clause = begin_node.ensure_clause
          return if ensure_clause.nil?

          gather_returns(ensure_clause.statements)
        end

        def gather_returns(node)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::ReturnNode
            @results << { return_node: node }
          when Prism::DefNode, Prism::LambdaNode, Prism::EnsureNode
            # Def / lambda open a new return frame — a `return` below them exits the nested frame, not the
            # one whose ensure we are scanning. A nested `begin/ensure`'s own EnsureNode is skipped for a
            # different reason: its BeginNode is visited separately, which collects those returns once —
            # descending here would double-collect them.
            return
          when Prism::CallNode
            return gather_returns_around_barrier_block(node) if frame_barrier_call?(node)
          end

          node.rigor_each_child { |child| gather_returns(child) }
        end

        # `lambda { ... }` / `define_method(:x) { ... }`: the receiver and arguments stay in the current
        # frame (and may themselves contain an offending `return`), only the attached block opens a new
        # one — descend into everything except the block.
        def gather_returns_around_barrier_block(call_node)
          barrier_block = call_node.block
          call_node.rigor_each_child do |child|
            gather_returns(child) unless child.equal?(barrier_block)
          end
        end

        def frame_barrier_call?(call_node)
          call_node.receiver.nil? &&
            FRAME_BARRIER_CALL_NAMES.include?(call_node.name) &&
            call_node.block.is_a?(Prism::BlockNode)
        end
      end
    end
  end
end
