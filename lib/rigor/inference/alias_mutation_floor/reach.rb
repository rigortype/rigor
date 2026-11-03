# frozen_string_literal: true

require "prism"

require_relative "../receiver_alias"

module Rigor
  module Inference
    # Issue #2335 — which locals a write through a receiver may reach ({AliasMutationFloor}), read off a frame body's
    # {AliasMutationFloor::Facts}.
    module AliasMutationFloor
      module_function

      # The locals aliased by the time `call_node`'s message runs, as `{ name => depth }`: those a site has handed on,
      # and those linked to one ({.reach}). A call inside a closure that may run later sees every site.
      def aliased_at(facts, call_node)
        return ALL if facts.held.equal?(ALL)

        offset = offset_of(facts, call_node)
        seeds = {}
        facts.held.each { |name, key| seeds[name] = FULL if key <= offset }
        facts.held_part.each { |name, key| seeds[name] ||= PART if key <= offset }
        reach(seeds, facts.links, offset)
      end

      def offset_of(facts, call_node)
        offset = (call_node.message_loc || call_node.location).start_offset
        facts.deferred.any? { |from, to| offset >= from && offset < to } ? Float::INFINITY : offset
      end

      # `seeds` closed over every link whose site may have run by `offset`. A depth says how far inside a local's object
      # the mutated object may sit: 0 ({FULL}) is the object itself, 1 ({PART}) one of its elements, and so on. A copy
      # keeps the depth; across an element link (`x = a[i]`, `x = a[i][j]`) the parent sits as many levels further out
      # than the child as the read goes, and the child as many further in, so a mutation of the parent object itself
      # (depth 0) does not reach the child.
      # The least depth wins.
      def reach(seeds, links, offset)
        changed = !seeds.empty?
        while changed
          changed = false
          links.each do |child, parent, key, levels|
            next if key > offset

            changed = true if spread(seeds, child, parent, levels) | spread(seeds, parent, child, -levels)
          end
        end
        seeds
      end

      DEPTH_CAP = 8
      private_constant :DEPTH_CAP

      # Spreads the depth `from` reached across one link to `to`, `step` levels further out; answers whether `to`
      # changed.
      def spread(seeds, from, to, step) # rubocop:disable Naming/PredicateMethod
        depth = seeds[from]
        return false if depth.nil?

        depth += step
        return false if depth.negative? || depth > DEPTH_CAP
        return false if seeds[to] && seeds[to] <= depth

        seeds[to] = depth
        true
      end

      # The locals a write through `receiver` may reach, as {.aliased_at} answers them: through each local it may
      # evaluate to ({ReceiverAlias.candidates}: `(c ? a : b)`), through an element read's root ({.element_targets}), or
      # as through any other receiver.
      def receiver_targets(receiver, facts, call_node)
        reads = ReceiverAlias.candidates(receiver)
        aliased = aliased_at(facts, call_node)
        return element_targets(receiver, facts, aliased, call_node) if reads.empty?
        return targets(nil, facts, aliased, call_node) unless reads.all?(Prism::LocalVariableReadNode)

        reads.map { |read| targets(read.name, facts, aliased, call_node) }.reduce { |acc, set| union(acc, set) }
      end

      # Through an element read rooted at a local (`c[0] << x`, `h[:k].fetch(0) << x`), the root's own links as far
      # inside it as the read goes (`a = c[0]` is the mutated object itself), beside what any other receiver reaches.
      def element_targets(receiver, facts, aliased, call_node)
        others = targets(nil, facts, aliased, call_node)
        root, depth = element_root(receiver)
        return others if root.nil? || others.equal?(ALL)

        union(others, reach({ root.name => depth }, facts.links, offset_of(facts, call_node)))
      end

      def union(left, right)
        return ALL if left.equal?(ALL) || right.equal?(ALL)

        merged = left.dup
        right.each { |name, depth| merged[name] = [merged[name], depth].compact.min }
        merged
      end

      # The locals a write through the local `name` (nil for any other receiver) may reach, as `{ name => depth }`:
      #
      # - the locals linked to it ({.reach}): a copy of it, or what it copied (`b = a; b << x`), or the local it is an
      #   element of (`x = a[i]`);
      # - and every aliased local, through a receiver that may hold any object: an ivar, an index read, a call result,
      #   a block parameter, or a local some write binds to an object from elsewhere;
      # - or only the aliased locals that are foreign, through a local only ever written a new object or a method
      #   parameter the body never rebinds, once the body has handed it on: either is an object no new-object local
      #   can be, and only a holder it reached can hand it to another local.
      def targets(name, facts, aliased, call_node)
        return ALL if aliased.equal?(ALL)
        return aliased if name.nil? || NUMBERED_PARAMETER.match?(name)

        group = reach({ name => FULL }, facts.links, offset_of(facts, call_node))
        group.delete(name)
        return union(aliased, group) if facts.foreign.include?(name) && !facts.entry.include?(name)
        return group unless aliased.key?(name)

        union(group, aliased.slice(*facts.foreign))
      end
    end
  end
end
