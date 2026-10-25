# frozen_string_literal: true

require "prism"

module Rigor
  module Analysis
    module CheckRules
      # ADR-53 Track B (slice B3c) — hosts the main per-node check-rule pass on the shared {RuleWalk} instead of
      # its own `Source::NodeWalker.each` traversal.
      #
      # The main pass is the stateless half of the catalogue: each rule reads only `scope_index[node]` and
      # decides, with NO loop / block suppression and NO threaded context — so the collector declares no
      # `RULE_WALK_GATES` and ignores the walk's `context`.
      #
      # The per-node dispatch stays in `CheckRules` (ADR-53 WD4) and is handed in as a callable built in the
      # `CheckRules` module context, so its calls to the private diagnostic builders remain implicit-self. The
      # collector only owns the traversal hook and accumulation; `#results` are the accumulated {Diagnostic}s in
      # the walk's emission order.
      class MainPassCollector
        # The node classes the main pass branches on. A plain `Prism::IfNode` covers ternaries and postfix `if`
        # too. The global-write classes and `MultiWriteNode` carry issue #1367's `global.*` rules.
        NODE_CLASSES = [
          Prism::CallNode, Prism::DefNode, Prism::IfNode, Prism::UnlessNode,
          Prism::GlobalVariableWriteNode, Prism::GlobalVariableOperatorWriteNode, Prism::MultiWriteNode
        ].freeze

        # @param node_diagnostics — maps a `Prism::Node` to the array of diagnostics the main pass emits
        #   for it.
        def initialize(node_diagnostics)
          @node_diagnostics = node_diagnostics
          @diagnostics = []
        end

        # {RuleWalk} entry point: the per-node logic of the former inline `NodeWalker.each` `case`, invoked
        # under the shared traversal.
        def visit(node, _context = nil)
          @diagnostics.concat(@node_diagnostics.call(node))
        end

        def results
          @diagnostics
        end
      end
    end
  end
end
