# frozen_string_literal: true

require "prism"

require_relative "../../source/constant_path"
require_relative "../../source/node_children"

module Rigor
  module Analysis
    module CheckRules
      # ADR-53 Track B — the engine-owned AST walk that hosts CheckRules' per-node collectors, so a file is
      # traversed once for all of them instead of once per collector (the ADR-52 WD4 model applied to the
      # built-in rules; this walk and {Plugin::NodeRuleWalk} converge in slice B4).
      #
      # The walk is a single visit-before-descend DFS over `compact_child_nodes`. It threads the union of the
      # context the hosted collectors need — the per-collector hand-rolled walks each tracked some subset of
      # it — in one immutable {Context} object, recomputed once per node during the single descent:
      #
      # - `in_loop_or_block` — whether the node is inside a loop / block body (the two flow collectors
      #   suppress collection there because mutation tracking through those is incomplete).
      # - `qualified_prefix` — the enclosing class / module name stack ({IvarWriteCollector} builds its
      #   `class_name` from it).
      # - `inside_def` — whether the node is lexically inside a `DefNode` ({IvarWriteCollector} collects only
      #   at a `def` that sits directly in a class / module body, never one nested in another `def`).
      #
      # A collector joins the walk by declaring `NODE_CLASSES` (the node classes it cares about — Prism node
      # classes are leaves, so a class-equality dispatch matches the collectors' `is_a?` gates), optionally
      # `RULE_WALK_GATES` (the {Context}-derived suppressions the walk applies before calling it), and
      # `#visit(node, context)` with its per-node logic transplanted verbatim. Only the *traversal* merges
      # here; each collector's gather / filter logic is unchanged from its legacy `#collect` walk (ADR-53
      # WD4).
      #
      # Equivalence is load-bearing: every hosted collector keeps its legacy single-collector `#collect` walk
      # as the oracle, compared against this walk by the permanent `rule_walk_equivalence_spec` and, over
      # whole corpora, by `RIGOR_SHADOW_RULE_WALK=1` (see `CheckRules.run_node_collectors`).
      module RuleWalk
        LOOP_OR_BLOCK_NODE_CLASSES = [
          Prism::WhileNode, Prism::UntilNode, Prism::ForNode, Prism::BlockNode
        ].freeze

        CLASS_OR_MODULE_NODE_CLASSES = [Prism::ClassNode, Prism::ModuleNode].freeze

        # The immutable per-node descent context. Recomputed for each child from its parent's context as the
        # walk descends; collectors read only the fields they declared a need for.
        Context = Data.define(:in_loop_or_block, :qualified_prefix, :inside_def) do
          def self.root
            new(in_loop_or_block: false, qualified_prefix: [], inside_def: false)
          end
        end

        # Suppression gates a collector may declare via `RULE_WALK_GATES`. The walk skips a collector's
        # `#visit` for a node when any of the collector's declared gates holds in that node's context —
        # exactly reproducing the per-collector legacy walk's traversal suppression. Each gate names the
        # {Context} predicate method that, when true, suppresses the visit:
        #
        # - `:loop_or_block` (`in_loop_or_block`) — inside a loop / block body, the two flow collectors'
        #   envelope.
        # - `:inside_def` (`inside_def`) — lexically inside a `DefNode`; IvarWrite collects only at a `def`
        #   that sits directly in a class / module body (its legacy walk `return`s at the first `def` it
        #   meets, so a nested def is never reached).
        GATE_CONTEXT_PREDICATES = {
          loop_or_block: :in_loop_or_block,
          inside_def: :inside_def
        }.freeze

        # A per-node driver over a fixed collector set: holds the compiled `node_class => [[collector,
        # gates], …]` hook table and applies the dispatch + context-descent that {RuleWalk.run} performs,
        # but one node at a time. This lets a foreign traversal (the converged {Plugin::NodeRuleWalk},
        # ADR-53 B4) drive the built-in collectors from inside its own single walk: it calls {#visit} on
        # each node with that node's {Context}, and derives a child's context with {#descend}. The dispatch
        # / gate / descend logic is identical to the standalone {RuleWalk.run} walk — only the traversal
        # driving it differs, keeping diagnostics byte-identical (ADR-53 WD4).
        class CollectorDriver
          def initialize(collectors)
            @hooks = RuleWalk.build_hooks(collectors)
            freeze
          end

          # Dispatch `node` (under its own `context`) to every matching, un-gated collector. Mirrors
          # {RuleWalk.dispatch}.
          def visit(node, context)
            matched = @hooks[node.class]
            return if matched.nil?

            matched.each do |collector, gates|
              next if gates.any? { |predicate| context.public_send(predicate) }

              collector.visit(node, context)
            end
          end

          # The context the children of `node` descend under. Mirrors {RuleWalk.descend}.
          def descend(node, context)
            RuleWalk.descend(node, context)
          end
        end

        class << self
          # Walks `root` once, dispatching each visited node to every collector whose `NODE_CLASSES` covers
          # the node's class and whose declared `RULE_WALK_GATES` do not suppress it in that node's context.
          def run(root, collectors)
            hooks = build_hooks(collectors)
            walk(root, hooks, Context.root)
            collectors
          end

          def build_hooks(collectors)
            hooks = {}
            collectors.each do |collector|
              gates = collector_gates(collector)
              collector.class::NODE_CLASSES.each do |node_class|
                (hooks[node_class] ||= []) << [collector, gates]
              end
            end
            hooks
          end

          # Computes the context the children of `node` descend under from the node's own context.
          # `in_loop_or_block` latches on once a loop / block is entered; `qualified_prefix` extends only on
          # a nameable class / module (an unnamed one descends with the same prefix, matching IvarWrite's
          # fall-through); `inside_def` latches on once a `DefNode` is entered.
          def descend(node, context)
            in_loop_or_block = context.in_loop_or_block ||
                               LOOP_OR_BLOCK_NODE_CLASSES.any? { |klass| node.is_a?(klass) }
            inside_def = context.inside_def || node.is_a?(Prism::DefNode)
            qualified_prefix = extend_prefix(node, context.qualified_prefix)

            Context.new(
              in_loop_or_block: in_loop_or_block,
              qualified_prefix: qualified_prefix,
              inside_def: inside_def
            )
          end

          private

          def collector_gates(collector)
            klass = collector.class
            return [] unless klass.const_defined?(:RULE_WALK_GATES)

            klass::RULE_WALK_GATES.map { |gate| GATE_CONTEXT_PREDICATES.fetch(gate) }
          end

          def walk(node, hooks, context)
            return unless node.is_a?(Prism::Node)

            dispatch(node, hooks, context)
            child_context = descend(node, context)
            node.rigor_each_child { |child| walk(child, hooks, child_context) }
          end

          def dispatch(node, hooks, context)
            matched = hooks[node.class]
            return if matched.nil?

            matched.each do |collector, gates|
              next if gates.any? { |predicate| context.public_send(predicate) }

              collector.visit(node, context)
            end
          end

          def extend_prefix(node, prefix)
            return prefix unless CLASS_OR_MODULE_NODE_CLASSES.any? { |klass| node.is_a?(klass) }

            name = Source::ConstantPath.qualified_name(node.constant_path)
            name ? prefix + [name] : prefix
          end
        end
      end
    end
  end
end
