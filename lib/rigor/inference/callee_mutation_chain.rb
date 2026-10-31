# frozen_string_literal: true

module Rigor
  module Inference
    # Issue #2104 — the callee floor's census made transitive. A method that hands its parameter to another method
    # which mutates it (`def stripes(acc) = poke(acc)`, `def poke(acc) = (acc[0] = "x")`) mutates that parameter as
    # surely as one that writes it itself, so the caller's argument is floored after `stripes(acc)` too.
    #
    # This module is the closure over a parameter-flow graph, independent of how the graph is read. `own` answers a
    # def's own census, `{ name => slot }` (a slot is a positional index or a keyword symbol); `edges` answers the
    # {Edge}s along which a def hands one of its parameters to a resolved callee. A node is one parameter of one def,
    # and the walk follows only the edges that hand on the parameter the node is, so a def's hand-offs of its OTHER
    # parameters cost nothing. A node is mutated when its def mutates it or it hands itself to a mutated node: the
    # least fixpoint, so a recursive or mutually recursive chain terminates and a cycle with no mutation on it mutates
    # nothing.
    #
    # The walk reads at most {MAX_NODES} nodes per parameter, so one parameter's walk cannot starve another's. A
    # hand-off to a node past the cap is read as a mutation (a {BudgetTrace::CALLEE_CHAIN_CAP} hit): the walk did not
    # see the callee, and a literal shape kept on evidence it never saw reports a false positive on correct code.
    module CalleeMutationChain
      # `name` and `slot` are the forwarding def's parameter, `callee` the def it is handed to, and `callee_names`
      # the callee's parameters it may bind there. Issue #2515 — `owner` is the evaluator the callee's own census and
      # hand-offs resolve in when the hand-off crosses classes (`Help.c(p, o)`, `Helper.new.c(p, o)`), nil for a
      # self-call, which stays in the evaluator the hop started in.
      Edge = Data.define(:name, :slot, :callee, :callee_names, :owner) do
        def initialize(name:, slot:, callee:, callee_names:, owner: nil) = super
      end

      MAX_NODES = 32

      module_function

      # `own` and `edges` take the def and the owner evaluator its hop resolves in (nil: the closure's own).
      def close(root, own:, edges:)
        census = own.call(root, nil)
        handed = edges.call(root, nil).reject { |edge| census.key?(edge.name) }
        return census if handed.empty?

        flow = Flow.new(own, edges)
        handed.each { |edge| flow.visit(root, edge.name, nil) }
        flow.settle
        handed.each_with_object(census.dup) do |edge, result|
          result[edge.name] = edge.slot if flow.mutated?(root, edge.name)
        end
      end

      # The parameter-flow graph one closure reads: per def, per parameter name, whether the node is mutated and the
      # nodes it hands itself on to.
      class Flow
        Node = Struct.new(:mutated, :successors)
        NO_SUCCESSORS = [].freeze

        def initialize(own, edges)
          @own = own
          @edges = edges
          @nodes = {}.compare_by_identity
        end

        def mutated?(def_node, name)
          node = @nodes.dig(def_node, name)
          !node.nil? && node.mutated
        end

        # Reads the nodes reachable from `def_node`'s `name`, breadth first, while fewer than {MAX_NODES} are read for
        # this parameter. A node still unread when the budget runs out is taken as mutated, so the cut answers "maybe
        # mutated" (the floor, the direction that cannot report a false positive) and records a
        # {BudgetTrace::CALLEE_CHAIN_CAP} hit.
        def visit(def_node, name, owner)
          queue = [[def_node, name, owner]]
          read = 0
          cut = false
          until queue.empty?
            current, parameter, current_owner = queue.shift
            next if known?(current, parameter)

            if read >= MAX_NODES
              cut = true
              (@nodes[current] ||= {})[parameter] = Node.new(true, NO_SUCCESSORS)
              next
            end

            read += 1
            queue.concat(add(current, parameter, current_owner))
          end
          BudgetTrace.hit(BudgetTrace::CALLEE_CHAIN_CAP) if cut
        end

        def settle
          changed = true
          while changed
            changed = false
            each_node do |node|
              next if node.mutated
              next unless node.successors.any? { |callee, name, _owner| mutated?(callee, name) }

              node.mutated = true
              changed = true
            end
          end
        end

        private

        def known?(def_node, name)
          by_name = @nodes[def_node]
          !by_name.nil? && by_name.key?(name)
        end

        # Records the node and answers its successors. A node its def mutates needs none.
        def add(def_node, name, owner)
          mutated = @own.call(def_node, owner).key?(name)
          successors = mutated ? [] : successors_of(def_node, name, owner)
          (@nodes[def_node] ||= {})[name] = Node.new(mutated, successors)
          successors
        end

        def successors_of(def_node, name, owner)
          @edges.call(def_node, owner).each_with_object([]) do |edge, successors|
            next unless edge.name == name

            edge.callee_names.each { |callee_name| successors << [edge.callee, callee_name, edge.owner || owner] }
          end
        end

        def each_node(&)
          @nodes.each_value { |by_name| by_name.each_value(&) }
        end
      end
    end
  end
end
