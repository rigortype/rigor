# frozen_string_literal: true

require "prism"

module Rigor
  module Analysis
    module CheckRules
      # ADR-53 Track B — the engine-owned AST walk that hosts CheckRules'
      # per-node collectors, so a file is traversed once for all of them
      # instead of once per collector (the ADR-52 WD4 model applied to
      # the built-in rules; this walk and {Plugin::NodeRuleWalk} converge
      # in slice B4).
      #
      # Slice B2 hosts the two flow collectors
      # ({AlwaysTruthyConditionCollector} / {UnreachableClauseCollector}),
      # whose hand-rolled walks shared this exact traversal contract:
      # visit-before-descend DFS over `compact_child_nodes`, with
      # collection suppressed anywhere inside a loop / block body
      # (mutation tracking through those is incomplete — each collector's
      # envelope documents why). A collector joins the walk by declaring
      # `NODE_CLASSES` and exposing `#visit(node)` with its per-node logic
      # transplanted verbatim; a collector with a different traversal
      # contract (class-nesting prefix, def-scoped scanning) stays on its
      # own walk until a later slice threads the context it needs.
      #
      # Equivalence is load-bearing: every hosted collector keeps its
      # legacy single-collector `#collect` walk as the oracle, compared
      # against this walk by the permanent `rule_walk_equivalence_spec`
      # and, over whole corpora, by `RIGOR_SHADOW_RULE_WALK=1`
      # (see `CheckRules.flow_collector_results`).
      module RuleWalk
        LOOP_OR_BLOCK_NODE_CLASSES = [
          Prism::WhileNode, Prism::UntilNode, Prism::ForNode, Prism::BlockNode
        ].freeze

        class << self
          # Walks `root` once, dispatching each visited node to every
          # collector whose `NODE_CLASSES` covers the node's class.
          # Dispatch keys on the exact node class — Prism node classes
          # are leaves, so this matches the collectors' `is_a?` gates.
          def run(root, collectors)
            hooks = {}
            collectors.each do |collector|
              collector.class::NODE_CLASSES.each do |node_class|
                (hooks[node_class] ||= []) << collector
              end
            end
            walk(root, hooks, in_loop_or_block: false)
            collectors
          end

          private

          def walk(node, hooks, in_loop_or_block:)
            return unless node.is_a?(Prism::Node)

            hooks[node.class]&.each { |collector| collector.visit(node) } unless in_loop_or_block

            child_in_loop_or_block =
              in_loop_or_block || LOOP_OR_BLOCK_NODE_CLASSES.any? { |klass| node.is_a?(klass) }
            node.compact_child_nodes.each { |child| walk(child, hooks, in_loop_or_block: child_in_loop_or_block) }
          end
        end
      end
    end
  end
end
