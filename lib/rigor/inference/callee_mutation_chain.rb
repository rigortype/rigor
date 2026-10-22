# frozen_string_literal: true

module Rigor
  module Inference
    # Issue #2104 — the callee floor's census made transitive. A method that hands its parameter to another method
    # which mutates it (`def stripes(acc) = poke(acc)`, `def poke(acc) = (acc[0] = "x")`) mutates that parameter as
    # surely as one that writes it itself, so the caller's argument is floored after `stripes(acc)` too.
    #
    # This module is the closure over a forwarding graph, independent of how the graph is read. `own` answers a def's
    # own census, `{ name => slot }` (a slot is a positional index or a keyword symbol); `edges` answers the
    # {Edge}s along which a def forwards one of its parameters to a resolved callee. The result is the least
    # fixpoint over the defs reachable from `root`, so a recursive or mutually recursive chain terminates and a
    # forwarding cycle with no mutation on it mutates nothing.
    #
    # The walk reads at most {MAX_DEFS} defs. An edge into a def it did not read counts as a mutation of the
    # forwarded parameter: losing the literal shape is the cheap error, a stale one is a false positive.
    module CalleeMutationChain
      # `name` and `slot` are the forwarding def's parameter, `callee` the def it is passed to, and `callee_slot`
      # the parameter it binds there.
      Edge = Data.define(:name, :slot, :callee, :callee_slot)

      MAX_DEFS = 16

      module_function

      def close(root, own:, edges:)
        root_edges = edges.call(root)
        return own.call(root) if root_edges.empty?

        mutated = { root => own.call(root).dup }.compare_by_identity
        graph = { root => root_edges }.compare_by_identity
        read_reachable(graph, mutated, own, edges)
        propagate(graph, mutated)
        mutated[root]
      end

      # Reads every def reachable from the graph's root, breadth first, up to {MAX_DEFS}. An edge into a def past the
      # cap marks its forwarded parameter mutated now, and the propagation never consults that def.
      def read_reachable(graph, mutated, own, edges)
        frontier = graph.keys
        until frontier.empty?
          frontier = frontier.flat_map do |def_node|
            graph[def_node].filter_map do |edge|
              next if mutated.key?(edge.callee)

              if mutated.size >= MAX_DEFS
                mutated[def_node][edge.name] = edge.slot
                next
              end

              mutated[edge.callee] = own.call(edge.callee).dup
              graph[edge.callee] = edges.call(edge.callee)
              edge.callee
            end
          end
        end
      end

      def propagate(graph, mutated)
        changed = true
        while changed
          changed = false
          graph.each do |def_node, def_edges|
            census = mutated[def_node]
            def_edges.each do |edge|
              next if census.key?(edge.name)

              callee = mutated[edge.callee]
              next unless callee&.value?(edge.callee_slot)

              census[edge.name] = edge.slot
              changed = true
            end
          end
        end
      end
    end
  end
end
