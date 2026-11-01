# frozen_string_literal: true

module Rigor
  module Inference
    # Issue #2104 — the callee floor's census made transitive. A method that hands its parameter to another method
    # which mutates it (`def stripes(acc) = poke(acc)`, `def poke(acc) = (acc[0] = "x")`) mutates that parameter as
    # surely as one that writes it itself, so the caller's argument is floored after `stripes(acc)` too.
    #
    # This module is the closure over a parameter-flow graph, independent of how the graph is read. `own` answers a
    # def's own census, `{ name => slot }` (a slot is a positional index or a keyword symbol); `edges` answers the
    # {Edge}s along which a def hands one of its parameters to a resolved callee. A node is one parameter of one def
    # under one owner context, and the walk follows only the edges that hand on the parameter the node is, so a def's
    # hand-offs of its OTHER parameters cost nothing.
    #
    # ADR-127 — the answer is a property of that graph, not of a walk. A parameter `r` is mutated iff an own-mutated
    # node is reachable from `r` through nodes that are not themselves own-mutated, or more than {MAX_NODES} distinct
    # nodes are reachable from `r` (a cut: the walk did not see them, and a literal shape kept on evidence it never saw
    # reports a false positive on correct code). Nothing a walk concludes is kept, so what one walk did cannot change
    # another's answer; only graph facts are persisted (the successor `store`). Which label an answer carries (an
    # exact one, or a cut and its {BudgetTrace::CALLEE_CHAIN_CAP} hit) may vary with the order, the floor does not.
    module CalleeMutationChain
      # `name` and `slot` are the forwarding def's parameter, `callee` the def it is handed to, and `callee_names`
      # the callee's parameters it may bind there. Issue #2515 — `owner` is the evaluator the callee's own census and
      # hand-offs resolve in when the hand-off crosses classes (`Help.c(p, o)`, `Helper.new.c(p, o)`), nil for a
      # self-call, which stays in the evaluator the hop started in.
      Edge = Data.define(:name, :slot, :callee, :callee_names, :owner) do
        def initialize(name:, slot:, callee:, callee_names:, owner: nil) = super
      end

      # ADR-127 — the most distinct nodes one parameter may reach before the walk is cut and reads as mutated.
      MAX_NODES = 64

      NO_TRIPLES = [].freeze
      private_constant :NO_TRIPLES

      module_function

      # `own` and `edges` take the def and the owner evaluator its hop resolves in (nil: the closure's own). `store`
      # (nil: none) is the run's successor store, `{ def => { owner_key => { name => triples } } }`, and `ctx` the key
      # the nil owner is stored under (the side and class the closure runs in).
      def close(root, own:, edges:, store: nil, ctx: nil)
        census = own.call(root, nil)
        handed = edges.call(root, nil)
        return census if handed.empty?

        result = nil
        handed.each do |edge|
          name = edge.name
          next if census.key?(name) || result&.key?(name)
          next unless reaches_mutation?(root, name, own, edges, store, ctx)

          (result ||= census.dup)[name] = edge.slot
        end
        result || census
      end

      # Breadth first from `root`'s `name`, over a walk-local `seen`. A node counts when it is first discovered and its
      # own mutation is checked then, so more than {MAX_NODES} discovered nodes is decided without computing the
      # frontier's edges. The first own-mutated node proves the parameter mutated; it is reachable through nodes that
      # are not own-mutated by construction, since those are the only ones expanded.
      def reaches_mutation?(root, name, own, edges, store, ctx)
        seen = {}.compare_by_identity
        mark(seen, root, name, nil)
        queue = [root, name, nil]
        discovered = 1
        i = 0
        while i < queue.size
          triples = successors(queue[i], queue[i + 1], queue[i + 2], edges, store, ctx)
          i += 3
          j = 0
          while j < triples.size
            callee = triples[j]
            callee_name = triples[j + 1]
            owner = triples[j + 2]
            j += 3
            next unless mark(seen, callee, callee_name, owner)

            discovered += 1
            if discovered > MAX_NODES
              BudgetTrace.hit(BudgetTrace::CALLEE_CHAIN_CAP)
              return true
            end
            return true if own.call(callee, owner).key?(callee_name)

            queue.push(callee, callee_name, owner)
          end
        end
        false
      end

      # True when the node was not yet in the walk-local `seen`, which now holds it.
      def mark(seen, def_node, name, owner)
        by_name = ((seen[def_node] ||= {})[owner] ||= {})
        return false if by_name.key?(name)

        by_name[name] = true
      end

      # The flat `[callee, name, owner, ...]` triples the node `(def_node, name, owner)` hands itself to: a graph fact,
      # persisted in `store` when there is one. A node its def mutates is never asked.
      def successors(def_node, name, owner, edges, store, ctx)
        return compute_successors(def_node, name, owner, edges) if store.nil?

        by_name = ((store[def_node] ||= {})[owner.nil? ? ctx : owner] ||= {})
        if by_name.key?(name)
          return MemoAudit.check("successor", by_name[name], name, owner) do
            compute_successors(def_node, name, owner, edges)
          end
        end

        by_name[name] = compute_successors(def_node, name, owner, edges)
      end

      def compute_successors(def_node, name, owner, edges)
        triples = nil
        edges.call(def_node, owner).each do |edge|
          next unless edge.name == name

          edge.callee_names.each { |callee_name| (triples ||= []).push(edge.callee, callee_name, edge.owner || owner) }
        end
        triples.nil? ? NO_TRIPLES : triples.freeze
      end
    end
  end
end
