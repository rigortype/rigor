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
      # The per-node dispatch itself stays in `CheckRules` (the verbatim `case` from `diagnose`'s former inline
      # walk — only the traversal moved, ADR-53 WD4) and is handed in as a callable built in the `CheckRules`
      # module context, so its calls to the private diagnostic builders remain implicit-self. The collector
      # only owns the traversal hook and accumulation. Unlike the fact collectors its `#results` are the
      # accumulated {Diagnostic}s, in the same emission order the inline `NodeWalker.each` produced them (the
      # shared walk is the same visit-before-descend DFS over `compact_child_nodes`).
      class MainPassCollector
        # The node classes the former inline pass branched on. A plain `Prism::IfNode` covers ternaries and
        # postfix `if` too (the legacy `when Prism::IfNode, Prism::UnlessNode` arm did the same).
        NODE_CLASSES = [
          Prism::CallNode, Prism::DefNode, Prism::IfNode, Prism::UnlessNode
        ].freeze

        # @param node_diagnostics [#call] maps a `Prism::Node` to the array of diagnostics the main pass emits
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
