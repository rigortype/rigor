# frozen_string_literal: true

require "prism"

require_relative "../receiver_alias"

module Rigor
  module Inference
    # Issue #2335 — which locals a write through a receiver may reach ({AliasMutationFloor}), read off a frame body's
    # {AliasMutationFloor::Facts}.
    module AliasMutationFloor
      module_function

      # The locals aliased by the time `call_node`'s message runs, as `{ name => FULL | PART }`: those a site has handed
      # on, and those linked to one ({.reach}). A call inside a closure that may run later sees every site.
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

      # `seeds` closed over every link whose site may have run by `offset`: a copy keeps the kind it reached, an element
      # link makes it a part. A full reach outranks a part one.
      def reach(seeds, links, offset)
        changed = !seeds.empty?
        while changed
          changed = false
          links.each do |left, right, key, part|
            next if key > offset

            changed = true if spread(seeds, left, right, part) | spread(seeds, right, left, part)
          end
        end
        seeds
      end

      # Spreads the kind `from` reached across one link to `to`; answers whether `to` changed.
      def spread(seeds, from, to, part) # rubocop:disable Naming/PredicateMethod
        kind = seeds[from]
        return false if kind.nil?

        kind = PART if part
        return false if [FULL, kind].include?(seeds[to])

        seeds[to] = kind
        true
      end

      # The locals a write through `receiver` may reach, as {.aliased_at} answers them: through each local it may
      # evaluate to ({ReceiverAlias.candidates}: `(c ? a : b)`), or as through any other receiver.
      def receiver_targets(receiver, facts, call_node)
        reads = ReceiverAlias.candidates(receiver)
        aliased = aliased_at(facts, call_node)
        return targets(nil, facts, aliased, call_node) if reads.empty? || !reads.all?(Prism::LocalVariableReadNode)

        reads.map { |read| targets(read.name, facts, aliased, call_node) }.reduce { |acc, set| union(acc, set) }
      end

      def union(left, right)
        return ALL if left.equal?(ALL) || right.equal?(ALL)

        merged = left.dup
        right.each { |name, kind| merged[name] = kind == FULL ? FULL : merged[name] || kind }
        merged
      end

      # The locals a write through the local `name` (nil for any other receiver) may reach, as
      # `{ name => FULL | PART }`:
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
